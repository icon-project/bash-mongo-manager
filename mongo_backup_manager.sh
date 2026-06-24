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

  # Determine the database the restore will write into.
  local TARGET_DB
  if [ -n "$RESTORE_DEST_DB" ]; then
    TARGET_DB="$RESTORE_DEST_DB"
  else
    TARGET_DB="$MONGO_DB_NAME"
  fi

  # Preflight: fail fast with a clear message if the configured credentials
  # can't reach the destination database, instead of failing partway through
  # mongorestore with a confusing "listCollections requires authentication".
  # DB names can't contain quotes/backslashes, so interpolating TARGET_DB into
  # the eval is safe. Skipped when mongosh isn't available in the container.
  if docker exec "$CONTAINER_NAME" sh -c 'command -v mongosh >/dev/null 2>&1'; then
    echo "Preflight: checking auth against destination database '${TARGET_DB}'..."
    local PREFLIGHT_AUTH=()
    if [ "$USE_CREDENTIALS" != "false" ]; then
      PREFLIGHT_AUTH=( --username "$MONGO_USER" --password "$MONGO_PASSWORD" --authenticationDatabase admin )
    fi
    if docker exec "$CONTAINER_NAME" mongosh --quiet "${PREFLIGHT_AUTH[@]}" \
        --eval "quit((db.getSiblingDB('${TARGET_DB}').runCommand({ listCollections: 1 }).ok === 1) ? 0 : 1)" >/dev/null 2>&1; then
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
