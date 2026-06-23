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
  # shellcheck disable=SC1090
  source "$ENV_FILE"
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
backup() {
  echo "Starting MongoDB backup at $TIMESTAMP..."

  mkdir -p "$BACKUP_DIR"

  # Build auth args safely
  local AUTH_ARGS=()
  build_mongo_auth_args AUTH_ARGS

  # Run the MongoDB dump command inside the container (NO sh -c; pass args directly)
  docker exec "$CONTAINER_NAME" mongodump \
    --archive="$BACKUP_FILE_NAME" \
    --gzip \
    "${AUTH_ARGS[@]}" \
    --db="$MONGO_DB_NAME"

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
# Usage: restore <backup_file> [source_db] [source_collection] [dest_db] [dest_collection]
# When all four namespace args are provided, restores that collection from the archive
# (source_db.source_collection) into the destination namespace (dest_db.dest_collection).
restore() {
  if [ -z "${1:-}" ]; then
    echo "Error: Please provide the backup file to restore."
    exit 1
  fi

  local RESTORE_FILE=$1
  local RESTORE_SOURCE_DB=${2:-}
  local RESTORE_SOURCE_COLLECTION=${3:-}
  local RESTORE_DEST_DB=${4:-}
  local RESTORE_DEST_COLLECTION=${5:-}

  if [ ! -e "$RESTORE_FILE" ]; then
    echo "Error: Backup file $RESTORE_FILE not found in the host."
    exit 1
  fi

  # Validate namespace remapping: all four must be set together or none
  if [ -n "$RESTORE_SOURCE_DB" ] || [ -n "$RESTORE_SOURCE_COLLECTION" ] || [ -n "$RESTORE_DEST_DB" ] || [ -n "$RESTORE_DEST_COLLECTION" ]; then
    if [ -z "$RESTORE_SOURCE_DB" ] || [ -z "$RESTORE_SOURCE_COLLECTION" ] || [ -z "$RESTORE_DEST_DB" ] || [ -z "$RESTORE_DEST_COLLECTION" ]; then
      echo "Error: For namespace remapping you must specify all four: source_db source_collection dest_db dest_collection."
      exit 1
    fi
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

  # If remapping, use nsInclude/nsFrom/nsTo (avoids deprecated --db/--collection behavior)
  if [ -n "$RESTORE_SOURCE_DB" ]; then
    local SRC_NS="${RESTORE_SOURCE_DB}.${RESTORE_SOURCE_COLLECTION}"
    local DST_NS="${RESTORE_DEST_DB}.${RESTORE_DEST_COLLECTION}"
    echo "Remapping namespace: $SRC_NS -> $DST_NS"
    echo "Note: MongoDB user must have readWrite on destination database '${RESTORE_DEST_DB}'."

    RESTORE_ARGS+=(
      "--nsInclude=$SRC_NS"
      "--nsFrom=$SRC_NS"
      "--nsTo=$DST_NS"
    )
  else
    # Default behavior: restore only the configured DB
    RESTORE_ARGS+=("--nsInclude=${MONGO_DB_NAME}.*")
  fi

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
}

# Function to display help information
help() {
  echo "MongoDB Backup and Restore Script"
  echo
  echo "Usage: ./mongo_backup_manager.sh [command] [options]"
  echo
  echo "Commands:"
  echo "  backup                 Perform a MongoDB backup and upload it to S3."
  echo "  restore [file] [source_db] [source_collection] [dest_db] [dest_collection]"
  echo "                         Restore a MongoDB backup. Optionally remap a namespace (all four required)."
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
  echo "  ./mongo_backup_manager.sh restore ./backups/mongo_backup_2026-02-09_08-56-18.gz"
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
    health_check
    backup
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
  verify)
    health_check
    verify "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    ;;
  download_backup)
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

{
  echo "-----------------------------------"
  echo "Run ended at $(date '+%Y-%m-%d %H:%M:%S')"
  echo "-----------------------------------"
} >> "$LOG_FILE"
