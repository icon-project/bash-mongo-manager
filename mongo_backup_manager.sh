#!/usr/bin/env bash
set -euo pipefail

# This script needs bash 4.3+: it uses namerefs (local -n) and loads .env via
# `source <(...)` process substitution. macOS ships bash 3.2 as /bin/bash, where
# BOTH break — the nameref syntax errors and, worse, the process-substitution
# source silently reads *nothing*, so every var falls back to its default. That
# turns USE_REMOTE into "true" and the run dies later with a baffling
# "S3_BUCKET_NAME: unbound variable". Fail fast here with an actionable message
# instead. (The guard itself uses only 3.2-safe syntax.)
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
  echo "Error: this script requires bash 4.3 or newer (found ${BASH_VERSION:-non-bash shell})." >&2
  echo "       macOS ships bash 3.2 as /bin/bash. Install a newer bash and run under it:" >&2
  echo "         brew install bash                 # puts bash 5.x first on PATH" >&2
  echo "         ./mongo_backup_manager.sh ...     # uses #!/usr/bin/env bash" >&2
  exit 1
fi

# Get the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define log file
LOG_FILE="${SCRIPT_DIR}/logs/mongo_backup_manager.log"

# Ensure logs dir exists
mkdir -p "$(dirname "$LOG_FILE")"

# Mirror everything this run prints (stdout + stderr) into the log while still
# showing it on the terminal / journal. Previously only the run separators were
# written here, so the "log" recorded timestamps but none of the actual output;
# tee makes it a real record however the script is invoked. Using a process
# substitution (not a `| tee` pipe) keeps the script's own exit status intact.
exec > >(tee -a "$LOG_FILE") 2>&1

# Always close the run out with an end separator and the exit code — even on an
# early exit or a failure under `set -e`. The trap fires on every exit path; the
# old end-of-file block was skipped whenever the script exited early, so a failed
# run looked like it never finished.
log_run_end() {
  local ec=$?
  echo "-----------------------------------"
  echo "Run ended at $(date '+%Y-%m-%d %H:%M:%S') (exit $ec)"
  echo "-----------------------------------"
}
trap log_run_end EXIT

# Add a separator for each run
echo "==================================="
echo "Run started at $(date '+%Y-%m-%d %H:%M:%S')"
echo "==================================="

# Load environment variables from .env file
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # Source with carriage returns stripped so a .env saved with Windows (CRLF)
  # line endings can't break us. Stripping at source time (not after) is what
  # matters: a blank CRLF line would otherwise make bash try to run $'\r' as a
  # command and abort under `set -e`, and values would carry a trailing "\r"
  # that silently breaks docker exec, auth, and the S3 path. Removing only CR
  # never touches meaningful whitespace inside a value (e.g. a password).
  # shellcheck disable=SC1090
  source <(tr -d '\r' < "$ENV_FILE")
  set +a
else
  echo "Error: The .env file is missing. Please create the .env file with the required environment variables."
  exit 1
fi

# Normalize feature flags with defaults
USE_CREDENTIALS=$(echo "${USE_CREDENTIALS:-true}" | tr '[:upper:]' '[:lower:]')
USE_REMOTE=$(echo "${USE_REMOTE:-true}" | tr '[:upper:]' '[:lower:]')

# Function to check if the required environment variables are set correctly
health_check() {
  echo "Performing health check..."

  # Base required variables
  REQUIRED_VARS=("CONTAINER_NAME" "MONGO_PORT" "MONGO_DB_NAME")

  # Only require credentials when enabled
  if [ "$USE_CREDENTIALS" != "false" ]; then
    REQUIRED_VARS+=("MONGO_USER" "MONGO_PASSWORD")
  fi

  # Only require remote settings when remote operations are enabled
  if [ "$USE_REMOTE" != "false" ]; then
    REQUIRED_VARS+=("S3_BUCKET_NAME" "AWS_PROFILE")
  fi

  # Check if each variable is set
  for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
      echo "Error: $var is not set in the .env file."
      exit 1
    fi
  done

  echo "Health check passed! All required variables are set."
}

# Set the rest of the variables
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
# Anchor the backup dirs to the script's own location (like LOG_FILE / ENV_FILE
# above), not the caller's CWD. A relative "./backups" would otherwise land
# wherever the process was started from — e.g. $HOME under cron/systemd — silently
# splitting dumps from the logs and pruning the wrong directory. SCRIPT_DIR is
# absolute, so backups always live beside the script no matter who invokes it.
BACKUP_DIR="${SCRIPT_DIR}/backups"
S3_BACKUP_DIR_TEMP="${SCRIPT_DIR}/backups_temp"
BACKUP_FILE_NAME="mongo_backup_${TIMESTAMP}.gz"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE_NAME}"
if [ "$USE_REMOTE" != "false" ]; then
  S3_BACKUP_PATH="s3://${S3_BUCKET_NAME}/mongodb-backups/"
fi

# Helper: build mongo auth args as an array (prevents shell-quoting issues)
build_mongo_auth_args() {
  local -n _out=$1
  _out=()
  if [ "$USE_CREDENTIALS" != "false" ]; then
    _out+=( "--username=$MONGO_USER" "--password=$MONGO_PASSWORD" "--authenticationDatabase=admin" )
  fi
}

# Helper: split a comma-separated collection list into the named array, skipping
# empty fields (so trailing/duplicate commas are tolerated). Uses read -ra so no
# glob expansion happens — a collection name containing '*' is taken literally.
# Names are not trimmed: a leading/trailing space is part of the name, so the
# list must not contain spaces around the commas.
split_csv() {
  local -n _csv_out=$1
  _csv_out=()
  local IFS=',' _field
  local -a _fields
  read -ra _fields <<< "$2"
  for _field in "${_fields[@]}"; do
    if [ -n "$_field" ]; then _csv_out+=("$_field"); fi
  done
  # Always succeed: a trailing empty field would otherwise leave the loop's
  # status at 1 (the failed test) and abort the caller under `set -e`.
  return 0
}

# Helper: build mongosh auth args as an array. mongosh uses space-separated
# flags (its CLI parser differs from mongodump/mongorestore which accept --flag=val).
build_mongosh_auth_args() {
  local -n _out=$1
  _out=()
  if [ "$USE_CREDENTIALS" != "false" ]; then
    _out+=( "--username" "$MONGO_USER" "--password" "$MONGO_PASSWORD" "--authenticationDatabase" "admin" )
  fi
}

# Helper: emit a value as a JSON/JS string literal (quoted, with backslashes and
# double quotes escaped). Used so a db/collection name containing a quote or
# backslash can't break or alter the JS we hand to mongosh. Order matters:
# escape backslashes before quotes. (Mongo namespaces can't contain control
# characters, so escaping \ and " is sufficient.)
json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# Function to perform backup
# Usage: backup [collections]
# collections: optional comma-separated list of collections in MONGO_DB_NAME to
# back up (e.g. "users,tasks"). When omitted, the whole database is dumped.
backup() {
  # An argument is present only if the caller actually passed one, so an
  # explicitly empty selector (e.g. backup "" from an unset variable) is
  # rejected rather than silently backing up the whole DB.
  local COLLECTIONS_CSV=""
  if [ "$#" -ge 1 ]; then
    if [ -z "$1" ]; then
      echo "Error: empty collection list. Pass a non-empty comma-separated list, or omit it to back up the whole DB."
      exit 1
    fi
    COLLECTIONS_CSV="$1"
  fi

  echo "Starting MongoDB backup at $TIMESTAMP..."

  mkdir -p "$BACKUP_DIR"

  # Build auth args safely
  local AUTH_ARGS=()
  build_mongo_auth_args AUTH_ARGS

  local DUMP_ARGS=( "--archive=$BACKUP_FILE_NAME" "--gzip" "${AUTH_ARGS[@]}" )
  # Set to the collection name when we use --collection, so we can detect that
  # mongodump reported the namespace missing (it exits 0 in that case).
  local SINGLE_COLLECTION=""

  if [ -n "$COLLECTIONS_CSV" ]; then
    local -a COLLECTIONS
    split_csv COLLECTIONS "$COLLECTIONS_CSV"
    if [ "${#COLLECTIONS[@]}" -eq 0 ]; then
      echo "Error: no collection names found in '$COLLECTIONS_CSV'."
      exit 1
    fi
    echo "Backing up collections from ${MONGO_DB_NAME}: ${COLLECTIONS[*]}"

    if [ "${#COLLECTIONS[@]}" -eq 1 ]; then
      # A single collection is dumped directly with --collection, which needs no
      # mongosh. mongodump exits 0 even when the collection is missing (it logs
      # "does not exist"), so we validate via the dump output after running it.
      DUMP_ARGS+=( "--db=$MONGO_DB_NAME" "--collection=${COLLECTIONS[0]}" )
      SINGLE_COLLECTION="${COLLECTIONS[0]}"
    else
      # mongodump can't include multiple specific collections in one pass, so
      # dump the whole DB minus everything not requested. Building that exclude
      # list needs the full collection list, which we read with mongosh.
      if ! docker exec "$CONTAINER_NAME" sh -c 'command -v mongosh >/dev/null 2>&1'; then
        echo "Error: backing up more than one collection needs mongosh inside container '${CONTAINER_NAME}'."
        echo "       Back them up one at a time, or use a container image that includes mongosh."
        exit 1
      fi

      local MONGOSH_AUTH=()
      if [ "$USE_CREDENTIALS" != "false" ]; then
        MONGOSH_AUTH=( --username "$MONGO_USER" --password "$MONGO_PASSWORD" --authenticationDatabase admin )
      fi
      # JSON-escape the DB name into a JS string literal (see restore preflight).
      local DB_ESC="${MONGO_DB_NAME//\\/\\\\}"
      DB_ESC="${DB_ESC//\"/\\\"}"

      local ALL_COLLECTIONS
      ALL_COLLECTIONS=$(docker exec "$CONTAINER_NAME" mongosh --quiet "${MONGOSH_AUTH[@]}" \
        --eval "db.getSiblingDB(\"${DB_ESC}\").getCollectionNames().forEach(function (n) { print(n); })")

      # Warn about requested collections that don't exist.
      local req
      for req in "${COLLECTIONS[@]}"; do
        if ! printf '%s\n' "$ALL_COLLECTIONS" | grep -qxF -- "$req"; then
          echo "Warning: requested collection '$req' not found in ${MONGO_DB_NAME}; skipping."
        fi
      done

      # Exclude every existing collection that wasn't requested.
      DUMP_ARGS+=( "--db=$MONGO_DB_NAME" )
      local kept=0 existing want
      while IFS= read -r existing; do
        [ -z "$existing" ] && continue
        local keep=0
        for want in "${COLLECTIONS[@]}"; do
          if [ "$existing" = "$want" ]; then keep=1; break; fi
        done
        if [ "$keep" -eq 1 ]; then
          kept=$((kept + 1))
        else
          DUMP_ARGS+=( "--excludeCollection=$existing" )
        fi
      done <<< "$ALL_COLLECTIONS"

      if [ "$kept" -eq 0 ]; then
        echo "Error: none of the requested collections exist in ${MONGO_DB_NAME}."
        exit 1
      fi
    fi
  else
    DUMP_ARGS+=( "--db=$MONGO_DB_NAME" )
  fi

  # Run the MongoDB dump command inside the container (NO sh -c; pass args
  # directly). Capture output so we can detect a missing single collection,
  # which mongodump reports without a non-zero exit. Capture the exit status
  # without letting set -e abort first, so the mongodump diagnostics are always
  # printed before we exit on a real failure (bad creds, unreachable, disk full).
  local DUMP_OUTPUT DUMP_STATUS=0
  DUMP_OUTPUT=$(docker exec "$CONTAINER_NAME" mongodump "${DUMP_ARGS[@]}" 2>&1) || DUMP_STATUS=$?
  printf '%s\n' "$DUMP_OUTPUT"
  if [ "$DUMP_STATUS" -ne 0 ]; then
    echo "Error: mongodump failed (exit $DUMP_STATUS); see output above."
    exit 1
  fi
  if [ -n "$SINGLE_COLLECTION" ] && printf '%s\n' "$DUMP_OUTPUT" | grep -q "does not exist"; then
    echo "Error: collection '${SINGLE_COLLECTION}' does not exist in ${MONGO_DB_NAME}; nothing was backed up."
    exit 1
  fi

  echo "MongoDB dump completed successfully."

  # Copy the backup from the container to the host
  docker cp "$CONTAINER_NAME:$BACKUP_FILE_NAME" "$BACKUP_FILE"

  # Remove the in-container archive now that it's safely on the host. mongodump
  # wrote it to the container's working directory and nothing else cleans it up,
  # so without this every run would leave another dump inside the container and
  # grow its writable layer without bound. Mirrors the /tmp cleanup in restore.
  docker exec "$CONTAINER_NAME" rm -f "$BACKUP_FILE_NAME" || true

  # Upload the backup to S3
  if [ "$USE_REMOTE" != "false" ]; then
    aws s3 cp "$BACKUP_FILE" "$S3_BACKUP_PATH" --profile "$AWS_PROFILE"
    echo "Backup uploaded to S3 successfully."

    # Prune S3 backups older than 7 days (mirrors the local find -mtime +7 below).
    # S3 has no server-side age filter, so list the keys under the prefix and
    # compare the timestamp embedded in each backup's name against a cutoff built
    # the same way the names are (host-local time, like TIMESTAMP above). The name
    # layout mongo_backup_YYYY-MM-DD_HH-MM-SS.gz sorts lexicographically, so a plain
    # string "<" is a valid time comparison — no per-object date parsing needed.
    # `date +%s` is portable; formatting an epoch back differs by platform, so try
    # BSD's `-r` (macOS) first, then fall back to GNU's `-d @` (Linux). This is
    # best-effort: the dump already uploaded, so a transient S3 error warns rather
    # than failing the run. Needs s3:ListBucket + s3:DeleteObject (see README).
    local cutoff_epoch cutoff_ts s3_keys s3_key s3_name s3_ts
    cutoff_epoch=$(( $(date +%s) - 7 * 86400 ))
    cutoff_ts=$(date -r "$cutoff_epoch" +%Y-%m-%d_%H-%M-%S 2>/dev/null \
             || date -d "@$cutoff_epoch" +%Y-%m-%d_%H-%M-%S)
    if s3_keys=$(aws s3api list-objects-v2 \
                   --bucket "$S3_BUCKET_NAME" --prefix "mongodb-backups/" \
                   --query 'Contents[].Key' --output text --profile "$AWS_PROFILE"); then
      while IFS= read -r s3_key; do
        [ -n "$s3_key" ] && [ "$s3_key" != "None" ] || continue
        s3_name=${s3_key##*/}
        case "$s3_name" in mongo_backup_*.gz) ;; *) continue ;; esac
        s3_ts=${s3_name#mongo_backup_}; s3_ts=${s3_ts%.gz}
        if [[ "$s3_ts" < "$cutoff_ts" ]]; then
          echo "Deleting old S3 backup: $s3_key"
          aws s3 rm "s3://${S3_BUCKET_NAME}/${s3_key}" --profile "$AWS_PROFILE" \
            || echo "Warning: failed to delete s3://${S3_BUCKET_NAME}/${s3_key}" >&2
        fi
      done <<< "$(printf '%s' "$s3_keys" | tr '\t' '\n')"
    else
      echo "Warning: could not list S3 objects for retention; skipping remote prune." >&2
    fi
  else
    echo "Skipping S3 upload because USE_REMOTE=false."
  fi

  # Cleanup old backups (keep last 7 days)
  find "$BACKUP_DIR" -type f -mtime +7 -name "*.gz" \
    -exec echo "Deleting old backup file: " {} \; -exec rm {} \;

  echo "Backup completed successfully at $TIMESTAMP and saved to $BACKUP_FILE."
}

# Function to list backups in S3
list_backups_s3() {
  echo "Listing MongoDB backups in S3..."
  if [ "$USE_REMOTE" == "false" ]; then
    echo "Skipping S3 listing because USE_REMOTE=false."
    return 0
  fi
  aws s3 ls "$S3_BACKUP_PATH" --recursive --profile "$AWS_PROFILE"
}

# Function to list backups in the local directory
list_backups_local() {
  echo "Listing MongoDB backups in $BACKUP_DIR..."
  ls -lh "$BACKUP_DIR"
}

# Function to restore a given backup
# Usage: restore <backup_file> [collections | source_db source_collection dest_db dest_collection]
# - No extra args: restore the whole configured database.
# - A single comma-separated list (e.g. "users,tasks"): restore only those
#   collections from the archive into MONGO_DB_NAME.
# - All four namespace args: restore that one collection from the archive
#   (source_db.source_collection) into the destination namespace
#   (dest_db.dest_collection).
restore() {
  if [ -z "${1:-}" ]; then
    echo "Error: Please provide the backup file to restore."
    exit 1
  fi

  local RESTORE_FILE=$1
  # Mode is selected by the *count* of arguments after the file, which the caller
  # preserves by forwarding the real args. This distinguishes "no selector" from
  # an explicitly empty one (e.g. restore <file> "" from an unset variable): the
  # latter is rejected rather than silently restoring/dropping the whole DB.
  local nmode=$(( $# - 1 ))

  # Resolve the backup path independently of the caller's CWD. An absolute path,
  # or one that exists relative to CWD, is used as-is; otherwise we look for it
  # (by the given path and by basename) under the script's own backup dirs. This
  # lets a `download_backup` result be restored from anywhere — the dirs are
  # SCRIPT_DIR-anchored, but under cron/systemd CWD is usually $HOME, so
  # `restore backups_temp/foo.gz` would otherwise not be found.
  if [ ! -e "$RESTORE_FILE" ]; then
    local cand
    for cand in "${S3_BACKUP_DIR_TEMP}/${RESTORE_FILE}" "${BACKUP_DIR}/${RESTORE_FILE}" \
                "${S3_BACKUP_DIR_TEMP}/$(basename "$RESTORE_FILE")" "${BACKUP_DIR}/$(basename "$RESTORE_FILE")"; do
      if [ -e "$cand" ]; then RESTORE_FILE=$cand; break; fi
    done
  fi

  if [ ! -e "$RESTORE_FILE" ]; then
    echo "Error: Backup file '$1' not found (looked relative to CWD, and in $S3_BACKUP_DIR_TEMP and $BACKUP_DIR)."
    exit 1
  fi

  # Restore mode by argument count after the file:
  #   0 args                                  -> restore the whole configured DB
  #   1 arg  <collections>                    -> restore a comma-separated subset
  #                                              of collections from MONGO_DB_NAME
  #   4 args <src_db> <src_col> <dst_db> <dst_col> -> restore one collection,
  #                                              remapping its namespace
  local RESTORE_MODE
  local RESTORE_SOURCE_DB="" RESTORE_SOURCE_COLLECTION="" RESTORE_DEST_DB="" RESTORE_DEST_COLLECTION=""
  local -a COLLECTIONS=()
  if [ "$nmode" -eq 0 ]; then
    RESTORE_MODE="all"
  elif [ "$nmode" -eq 1 ]; then
    RESTORE_MODE="collections"
    if [ -z "${2:-}" ]; then
      echo "Error: empty collection list. Pass a non-empty comma-separated list, or omit it to restore the whole DB."
      exit 1
    fi
    split_csv COLLECTIONS "$2"
    if [ "${#COLLECTIONS[@]}" -eq 0 ]; then
      echo "Error: no collection names found in '$2'."
      exit 1
    fi
  elif [ "$nmode" -eq 4 ]; then
    RESTORE_MODE="remap"
    RESTORE_SOURCE_DB="$2"
    RESTORE_SOURCE_COLLECTION="$3"
    RESTORE_DEST_DB="$4"
    RESTORE_DEST_COLLECTION="$5"
    if [ -z "$RESTORE_SOURCE_DB" ] || [ -z "$RESTORE_SOURCE_COLLECTION" ] || [ -z "$RESTORE_DEST_DB" ] || [ -z "$RESTORE_DEST_COLLECTION" ]; then
      echo "Error: remap arguments must all be non-empty: source_db source_collection dest_db dest_collection."
      exit 1
    fi
  else
    echo "Error: restore takes the backup file plus either nothing (whole DB), a single"
    echo "       comma-separated collection list, or four remap args: source_db source_collection dest_db dest_collection."
    exit 1
  fi

  # Determine the database the restore will write into.
  local TARGET_DB
  if [ "$RESTORE_MODE" = "remap" ]; then
    TARGET_DB="$RESTORE_DEST_DB"
  else
    TARGET_DB="$MONGO_DB_NAME"
  fi

  # Preflight: fail fast with a clear message if the configured credentials
  # can't reach the destination database, instead of failing partway through
  # mongorestore with a confusing "listCollections requires authentication".
  # Skipped when mongosh isn't available in the container.
  if docker exec "$CONTAINER_NAME" sh -c 'command -v mongosh >/dev/null 2>&1'; then
    echo "Preflight: checking auth against destination database '${TARGET_DB}'..."
    local PREFLIGHT_AUTH=()
    if [ "$USE_CREDENTIALS" != "false" ]; then
      PREFLIGHT_AUTH=( --username "$MONGO_USER" --password "$MONGO_PASSWORD" --authenticationDatabase admin )
    fi
    # JSON-escape the DB name into a JS string literal so a name containing a
    # single quote (valid in MongoDB DB names) can't build malformed --eval JS.
    # Escape backslash first, then double quote (both forbidden in DB names, but
    # handled defensively), and embed inside double quotes.
    local TARGET_DB_ESC="${TARGET_DB//\\/\\\\}"
    TARGET_DB_ESC="${TARGET_DB_ESC//\"/\\\"}"
    if docker exec "$CONTAINER_NAME" mongosh --quiet "${PREFLIGHT_AUTH[@]}" \
        --eval "quit((db.getSiblingDB(\"${TARGET_DB_ESC}\").runCommand({ listCollections: 1 }).ok === 1) ? 0 : 1)" >/dev/null 2>&1; then
      echo "Preflight auth check passed."
    else
      echo "Error: preflight auth check failed for database '${TARGET_DB}'."
      echo "The MongoDB user in .env needs readWrite (or at least listCollections) on '${TARGET_DB}'."
      exit 1
    fi
  else
    echo "Preflight: mongosh not found in container; skipping auth preflight."
  fi

  echo "Copying MongoDB backup file to the container..."
  docker cp "$RESTORE_FILE" "$CONTAINER_NAME:/tmp/$(basename "$RESTORE_FILE")"
  echo "Restoring MongoDB backup from $RESTORE_FILE..."

  # Build args safely (NO sh -c)
  local AUTH_ARGS=()
  build_mongo_auth_args AUTH_ARGS

  local RESTORE_ARGS=(
    "--archive=/tmp/$(basename "$RESTORE_FILE")"
    "--gzip"
    "--drop"
  )

  case "$RESTORE_MODE" in
    remap)
      # Restore one collection, remapping its namespace via nsInclude/nsFrom/nsTo
      # (avoids deprecated --db/--collection behavior).
      local SRC_NS="${RESTORE_SOURCE_DB}.${RESTORE_SOURCE_COLLECTION}"
      local DST_NS="${RESTORE_DEST_DB}.${RESTORE_DEST_COLLECTION}"
      echo "Remapping namespace: $SRC_NS -> $DST_NS"
      echo "Note: MongoDB user must have readWrite on destination database '${RESTORE_DEST_DB}'."
      RESTORE_ARGS+=(
        "--nsInclude=$SRC_NS"
        "--nsFrom=$SRC_NS"
        "--nsTo=$DST_NS"
      )
      ;;
    collections)
      # Restore only the named collections from the configured DB (one
      # --nsInclude each). --drop only drops the collections being restored.
      echo "Restoring collections into ${MONGO_DB_NAME}: ${COLLECTIONS[*]}"
      local col col_esc
      for col in "${COLLECTIONS[@]}"; do
        # --nsInclude is a namespace *pattern* where '*' is a wildcard and '\'
        # escapes it. Escape '\' then '*' in the collection name so a name like
        # 'foo*' matches only itself, not 'foo1'/'foobar'. (DB names can't
        # contain these characters, so only the collection part needs escaping.)
        col_esc="${col//\\/\\\\}"
        col_esc="${col_esc//\*/\\*}"
        RESTORE_ARGS+=( "--nsInclude=${MONGO_DB_NAME}.${col_esc}" )
      done
      ;;
    *)
      # Default behavior: restore only the configured DB
      RESTORE_ARGS+=( "--nsInclude=${MONGO_DB_NAME}.*" )
      ;;
  esac

  docker exec "$CONTAINER_NAME" mongorestore \
    "${AUTH_ARGS[@]}" \
    "${RESTORE_ARGS[@]}"

  echo "MongoDB restore completed successfully."

  echo "Cleaning up temporary backup file in the container..."
  docker exec "$CONTAINER_NAME" rm -f "/tmp/$(basename "$RESTORE_FILE")" || true

  echo "Restore completed successfully."
}

# Function to verify count + full index-spec parity between a source and a
# (restored) target namespace, both reachable from CONTAINER_NAME's mongod.
# Usage: verify <src_db> <src_col> <dst_db> <dst_col>
# Exits non-zero if document counts differ or any index spec differs.
# Index comparison strips the cosmetic `v` and `ns` fields (ns legitimately
# differs across DBs) and compares the full remaining spec: name, key,
# unique, sparse, partialFilterExpression, collation, TTL (expireAfterSeconds).
verify() {
  if [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ] || [ -z "${4:-}" ]; then
    echo "Error: verify requires all four arguments: <src_db> <src_col> <dst_db> <dst_col>."
    exit 1
  fi

  local SRC_DB=$1
  local SRC_COL=$2
  local DST_DB=$3
  local DST_COL=$4

  echo "Verifying ${SRC_DB}.${SRC_COL} -> ${DST_DB}.${DST_COL}..."

  local AUTH_ARGS=()
  build_mongosh_auth_args AUTH_ARGS

  # JSON-encode the four names into JS string literals so that names containing
  # quotes or backslashes can't break or alter the script (JSON strings are
  # valid JS string literals). The prelude is assembled separately and prepended
  # to the logic body, which lives in a *quoted* heredoc — no shell expansion,
  # so the JS may use '$'/backticks freely and the names are never re-expanded.
  local SRC_DB_JS SRC_COL_JS DST_DB_JS DST_COL_JS
  SRC_DB_JS=$(json_str "$SRC_DB")
  SRC_COL_JS=$(json_str "$SRC_COL")
  DST_DB_JS=$(json_str "$DST_DB")
  DST_COL_JS=$(json_str "$DST_COL")

  # The eval script runs inside the container's mongosh. Both namespaces are
  # reached via getSiblingDB on the same connection. It prints a summary and
  # quit()s non-zero on any mismatch.
  local JS_BODY
  JS_BODY=$(cat <<'EOF'

// Canonical stringify: sort object keys recursively so field order never
// produces false mismatches. The index "key" field is order-sensitive
// (compound indexes), so preserve its insertion order. Only *plain* objects
// are recursed into; BSON scalar wrappers (Date, ObjectId, Long, Decimal128,
// etc.) carry their value in a non-enumerable form and would collapse to "{}"
// if recursed, so serialize them with EJSON (falling back to JSON) to keep
// distinct values distinct in e.g. a partialFilterExpression Date threshold.
function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    && Object.getPrototypeOf(v) === Object.prototype;
}
function rawKey(o) {
  return "{" + Object.keys(o).map(function (k) {
    return JSON.stringify(k) + ":" + canon(o[k]);
  }).join(",") + "}";
}
function canon(v) {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(canon).join(",") + "]";
  if (isPlainObject(v)) {
    return "{" + Object.keys(v).sort().map(function (k) {
      return JSON.stringify(k) + ":" + (k === "key" ? rawKey(v[k]) : canon(v[k]));
    }).join(",") + "}";
  }
  return (typeof EJSON !== "undefined") ? EJSON.stringify(v) : JSON.stringify(v);
}
function normIndexes(idxs) {
  return idxs.map(function (i) {
    const c = {};
    Object.keys(i).forEach(function (k) { if (k !== "v" && k !== "ns") c[k] = i[k]; });
    return c;
  }).map(canon).sort();
}

const srcCount = srcDb.getCollection(srcCol).countDocuments({});
const dstCount = dstDb.getCollection(dstCol).countDocuments({});
const srcIdx = normIndexes(srcDb.getCollection(srcCol).getIndexes());
const dstIdx = normIndexes(dstDb.getCollection(dstCol).getIndexes());

const problems = [];
if (srcCount !== dstCount) {
  problems.push("count mismatch: source=" + srcCount + " target=" + dstCount);
}
const dstSet = new Set(dstIdx);
const srcSet = new Set(srcIdx);
srcIdx.forEach(function (s) { if (!dstSet.has(s)) problems.push("index on source missing/differs on target: " + s); });
dstIdx.forEach(function (d) { if (!srcSet.has(d)) problems.push("index on target absent/differs on source: " + d); });

print("source " + srcDb.getName() + "." + srcCol + ": count=" + srcCount + " indexes=" + srcIdx.length);
print("target " + dstDb.getName() + "." + dstCol + ": count=" + dstCount + " indexes=" + dstIdx.length);

if (problems.length) {
  print("VERIFY FAILED:");
  problems.forEach(function (p) { print("  - " + p); });
  quit(1);
}
print("VERIFY OK: document counts and full index specs match.");
quit(0);
EOF
)

  # Prepend the namespace bindings (JSON literals) to the logic body.
  local JS="const srcDb = db.getSiblingDB(${SRC_DB_JS});
const dstDb = db.getSiblingDB(${DST_DB_JS});
const srcCol = ${SRC_COL_JS};
const dstCol = ${DST_COL_JS};
${JS_BODY}"

  if docker exec "$CONTAINER_NAME" mongosh --quiet "${AUTH_ARGS[@]}" --eval "$JS"; then
    echo "Verification passed."
  else
    echo "Verification failed."
    exit 1
  fi
}

# Function to download a backup from S3 and put it in the S3_BACKUP_DIR_TEMP
download_backup() {
  if [ -z "${1:-}" ]; then
    echo "Error: Please provide the backup file to download."
    exit 1
  fi

  local DOWNLOAD_FILE=$1

  if [ "$USE_REMOTE" == "false" ]; then
    echo "Skipping S3 download because USE_REMOTE=false."
    return 0
  fi

  # Check if the backup file exists in S3
  aws s3 ls "${S3_BACKUP_PATH}${DOWNLOAD_FILE}" --profile "$AWS_PROFILE" > /dev/null

  # Ensure the temporary backup directory exists
  mkdir -p "$S3_BACKUP_DIR_TEMP"

  echo "Downloading MongoDB backup from S3..."
  aws s3 cp "${S3_BACKUP_PATH}${DOWNLOAD_FILE}" "$S3_BACKUP_DIR_TEMP" --profile "$AWS_PROFILE"

  echo "Download completed successfully."
  echo "Saved to: ${S3_BACKUP_DIR_TEMP}/$(basename "$DOWNLOAD_FILE")"
  echo "Restore it from anywhere with: $0 restore $(basename "$DOWNLOAD_FILE")"
}

# Function to display help information
help() {
  echo "MongoDB Backup and Restore Script"
  echo
  echo "Usage: ./mongo_backup_manager.sh [command] [options]"
  echo
  echo "Commands:"
  echo "  backup [collections]   Perform a MongoDB backup and upload it to S3."
  echo "                         Optionally pass a comma-separated collection list to back up a subset."
  echo "  restore [file] [collections | source_db source_collection dest_db dest_collection]"
  echo "                         Restore a MongoDB backup. With a comma-separated collection list,"
  echo "                         restore only those collections; with all four namespace args, remap one."
  echo "  verify [source_db] [source_collection] [dest_db] [dest_collection]"
  echo "                         Compare counts and full index specs between two namespaces; exits non-zero on mismatch."
  echo "  list_backups_s3        List all backups available in the S3 bucket."
  echo "  list_backups_local     List all backups in the local backup directory."
  echo "  download_backup [file] Download a backup from S3 and store it locally."
  echo "  help                   Display this help message."
  echo
  echo "Environment Flags:"
  echo "  USE_CREDENTIALS=false  Skip MongoDB username/password when dumping/restoring."
  echo "  USE_REMOTE=false       Skip all S3 uploads/downloads/list operations."
  echo
  echo "Examples:"
  echo "  ./mongo_backup_manager.sh backup"
  echo "  ./mongo_backup_manager.sh backup users,tasks"
  echo "  ./mongo_backup_manager.sh restore ./backups/mongo_backup_2026-02-09_08-56-18.gz"
  echo "  ./mongo_backup_manager.sh restore ./backups/mongo_backup_2026-02-09_08-56-18.gz users,tasks"
  echo "  ./mongo_backup_manager.sh restore ./backups/mongo_backup_2026-02-09_08-56-18.gz sodax-registration users new-world stateful_users"
  echo "  ./mongo_backup_manager.sh verify sodax-registration users new-world stateful_users"
}

# Call the help function if the script is run without arguments or with the 'help' command
if [ $# -eq 0 ] || [[ "${1:-}" == "help" ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  help
  exit 0
fi

# Main logic to parse arguments and call the corresponding function
case "$1" in
  backup)
    # At most one extra arg (the collection list). Reject extras so a list
    # mistyped with spaces (e.g. "users, tasks") fails fast instead of silently
    # backing up only the first collection.
    if [ "$#" -gt 2 ]; then
      echo "Error: too many arguments for backup. Pass at most one comma-separated collection list with no spaces (e.g. users,tasks)."
      exit 1
    fi
    health_check
    shift
    backup "$@"
    ;;
  list_backups_s3)
    if [ "$#" -gt 1 ]; then
      echo "Error: list_backups_s3 takes no arguments."
      exit 1
    fi
    health_check
    list_backups_s3
    ;;
  list_backups_local)
    if [ "$#" -gt 1 ]; then
      echo "Error: list_backups_local takes no arguments."
      exit 1
    fi
    health_check
    list_backups_local
    ;;
  restore)
    # restore <file> plus at most four mode args (collection list, or remap).
    if [ "$#" -gt 6 ]; then
      echo "Error: too many arguments for restore. Pass a comma-separated collection list with no spaces, or the four remap args."
      exit 1
    fi
    health_check
    shift
    restore "$@"
    ;;
  verify)
    health_check
    verify "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    ;;
  download_backup)
    if [ "$#" -gt 2 ]; then
      echo "Error: too many arguments for download_backup. Pass a single backup file name."
      exit 1
    fi
    health_check
    download_backup "${2:-}"
    ;;
  help|-h|--help)
    help
    ;;
  *)
    echo "Usage: $0 {backup|restore|verify|list_backups_s3|list_backups_local|download_backup|help} [args]"
    exit 1
    ;;
esac
