#!/bin/bash
set -euo pipefail

# Get the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define log file
LOG_FILE="${SCRIPT_DIR}/logs/mongo_backup_manager.log"

# Ensure logs dir exists
mkdir -p "$(dirname "$LOG_FILE")"

# Add a separator for each run
{
  echo "==================================="
  echo "Run started at $(date '+%Y-%m-%d %H:%M:%S')"
  echo "==================================="
} >> "$LOG_FILE"

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
BACKUP_DIR="./backups"
S3_BACKUP_DIR_TEMP="./backups_temp"
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
    [ -n "$_field" ] && _csv_out+=("$_field")
  done
}

# Function to perform backup
# Usage: backup [collections]
# collections: optional comma-separated list of collections in MONGO_DB_NAME to
# back up (e.g. "users,tasks"). When omitted, the whole database is dumped.
backup() {
  local COLLECTIONS_CSV=${1:-}

  echo "Starting MongoDB backup at $TIMESTAMP..."

  mkdir -p "$BACKUP_DIR"

  # Build auth args safely
  local AUTH_ARGS=()
  build_mongo_auth_args AUTH_ARGS

  local DUMP_ARGS=( "--archive=$BACKUP_FILE_NAME" "--gzip" "${AUTH_ARGS[@]}" )

  if [ -n "$COLLECTIONS_CSV" ]; then
    local -a COLLECTIONS
    split_csv COLLECTIONS "$COLLECTIONS_CSV"
    if [ "${#COLLECTIONS[@]}" -eq 0 ]; then
      echo "Error: no collection names found in '$COLLECTIONS_CSV'."
      exit 1
    fi
    echo "Backing up collections from ${MONGO_DB_NAME}: ${COLLECTIONS[*]}"

    # mongodump can't include multiple specific collections in one pass, and a
    # single --collection silently "succeeds" (empty archive) when the name is
    # missing. So for any subset, enumerate the DB's collections with mongosh,
    # validate the requested names, and dump the whole DB minus everything not
    # requested.
    if ! docker exec "$CONTAINER_NAME" sh -c 'command -v mongosh >/dev/null 2>&1'; then
      echo "Error: backing up a collection subset needs mongosh inside container '${CONTAINER_NAME}'."
      echo "       Use a container image that includes mongosh, or back up the whole DB."
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
  else
    DUMP_ARGS+=( "--db=$MONGO_DB_NAME" )
  fi

  # Run the MongoDB dump command inside the container (NO sh -c; pass args directly)
  docker exec "$CONTAINER_NAME" mongodump "${DUMP_ARGS[@]}"

  echo "MongoDB dump completed successfully."

  # Copy the backup from the container to the host
  docker cp "$CONTAINER_NAME:$BACKUP_FILE_NAME" "$BACKUP_FILE"

  # Upload the backup to S3
  if [ "$USE_REMOTE" != "false" ]; then
    aws s3 cp "$BACKUP_FILE" "$S3_BACKUP_PATH" --profile "$AWS_PROFILE"
    echo "Backup uploaded to S3 successfully."
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
  local A2=${2:-} A3=${3:-} A4=${4:-} A5=${5:-}

  if [ ! -e "$RESTORE_FILE" ]; then
    echo "Error: Backup file $RESTORE_FILE not found in the host."
    exit 1
  fi

  # Determine restore mode from the trailing arguments:
  #   (none)                                  -> restore the whole configured DB
  #   <collections>                           -> restore a comma-separated subset
  #                                              of collections from MONGO_DB_NAME
  #   <src_db> <src_col> <dst_db> <dst_col>   -> restore one collection, remapping
  #                                              its namespace
  local RESTORE_MODE
  local RESTORE_SOURCE_DB="" RESTORE_SOURCE_COLLECTION="" RESTORE_DEST_DB="" RESTORE_DEST_COLLECTION=""
  local -a COLLECTIONS=()
  if [ -z "$A2" ] && [ -z "$A3" ] && [ -z "$A4" ] && [ -z "$A5" ]; then
    RESTORE_MODE="all"
  elif [ -n "$A2" ] && [ -z "$A3" ] && [ -z "$A4" ] && [ -z "$A5" ]; then
    RESTORE_MODE="collections"
    split_csv COLLECTIONS "$A2"
    if [ "${#COLLECTIONS[@]}" -eq 0 ]; then
      echo "Error: no collection names found in '$A2'."
      exit 1
    fi
  elif [ -n "$A2" ] && [ -n "$A3" ] && [ -n "$A4" ] && [ -n "$A5" ]; then
    RESTORE_MODE="remap"
    RESTORE_SOURCE_DB="$A2"
    RESTORE_SOURCE_COLLECTION="$A3"
    RESTORE_DEST_DB="$A4"
    RESTORE_DEST_COLLECTION="$A5"
  else
    echo "Error: restore takes either no extra args (whole DB), a single comma-separated"
    echo "       collection list, or all four remap args: source_db source_collection dest_db dest_collection."
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
}

# Call the help function if the script is run without arguments or with the 'help' command
if [ $# -eq 0 ] || [[ "${1:-}" == "help" ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  help
  exit 0
fi

# Main logic to parse arguments and call the corresponding function
case "$1" in
  backup)
    health_check
    backup "${2:-}"
    ;;
  list_backups_s3)
    health_check
    list_backups_s3
    ;;
  list_backups_local)
    health_check
    list_backups_local
    ;;
  restore)
    health_check
    restore "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    ;;
  download_backup)
    health_check
    download_backup "${2:-}"
    ;;
  help|-h|--help)
    help
    ;;
  *)
    echo "Usage: $0 {backup|restore|list_backups_s3|list_backups_local|download_backup|help} [args]"
    exit 1
    ;;
esac

{
  echo "-----------------------------------"
  echo "Run ended at $(date '+%Y-%m-%d %H:%M:%S')"
  echo "-----------------------------------"
} >> "$LOG_FILE"
