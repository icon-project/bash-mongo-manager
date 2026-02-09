#!/bin/bash

# Get the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define log file
LOG_FILE="${SCRIPT_DIR}/logs/mongo_backup_manager.log"

# Add a separator for each run
echo "===================================" >> "$LOG_FILE"
echo "Backup started at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "===================================" >> "$LOG_FILE"

# Load environment variables from .env file
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
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
    if [ -z "${!var}" ]; then
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
  S3_BACKUP_PATH=s3://${S3_BUCKET_NAME}/mongodb-backups/
fi


# Function to perform backup
backup() {
  echo "Starting MongoDB backup at $TIMESTAMP..."

  # Ensure the backup directory exists, handle errors gracefully
  if ! mkdir -p $BACKUP_DIR; then
    echo "Warning: Could not create or access backup directory $BACKUP_DIR. Proceeding..."
  fi

  # Run the MongoDB dump command inside the container
  MONGO_AUTH_ARGS=""
  if [ "$USE_CREDENTIALS" != "false" ]; then
    MONGO_AUTH_ARGS="--username=$MONGO_USER --password=$MONGO_PASSWORD --authenticationDatabase admin"
  fi
  docker exec "$CONTAINER_NAME" sh -c "mongodump --archive=$BACKUP_FILE_NAME --gzip $MONGO_AUTH_ARGS --db=$MONGO_DB_NAME"

  if [ $? -eq 0 ]; then
    echo "MongoDB dump completed successfully."
  else
    echo "Error: Failed to dump MongoDB data."
    exit 1
  fi

  # Copy the backup from the container to the host
  docker cp $CONTAINER_NAME:$BACKUP_FILE_NAME $BACKUP_FILE

  # Upload the backup to S3
  if [ "$USE_REMOTE" != "false" ]; then
    aws s3 cp $BACKUP_FILE $S3_BACKUP_PATH --profile $AWS_PROFILE

    if [ $? -eq 0 ]; then
      echo "Backup uploaded to S3 successfully."
    else
      echo "Error: Failed to upload backup to S3."
      exit 1
    fi
  else
    echo "Skipping S3 upload because USE_REMOTE=false."
  fi

  # Cleanup old backups (optional: keep last 7 days)
  # find $BACKUP_DIR -type f -mtime +7 -name "*.gz" -exec rm {} \;
  find $BACKUP_DIR -type f -mtime +7 -name "*.gz" -exec echo "Deleting old backup file: " {} \; -exec rm {} \;

  echo "Backup completed successfully at $TIMESTAMP and saved to $BACKUP_FILE."
}

# Function to list backups in S3
list_backups_s3() {
  echo "Listing MongoDB backups in S3..."
  if [ "$USE_REMOTE" == "false" ]; then
    echo "Skipping S3 listing because USE_REMOTE=false."
    return 0
  fi
  aws s3 ls $S3_BACKUP_PATH --recursive --profile $AWS_PROFILE
}

# Function to list backups in the local directory
list_backups_local() {
  echo "Listing MongoDB backups in $BACKUP_DIR..."
  ls -lh $BACKUP_DIR
}

# Function to restore a given backup
# Usage: restore <backup_file> [source_collection] [dest_collection]
# When source_collection and dest_collection are both provided, restores the named
# collection from the archive into the destination collection name in MONGO_DB_NAME.
restore() {
  if [ -z "$1" ]; then
    echo "Error: Please provide the backup file to restore."
    exit 1
  fi

  RESTORE_FILE=$1
  RESTORE_COLLECTION_SOURCE=$2
  RESTORE_COLLECTION_DEST=$3

  if [ ! -e "$RESTORE_FILE" ]; then
    echo "Error: Backup file $RESTORE_FILE not found in the host."
    exit 1
  fi

  if [ -n "$RESTORE_COLLECTION_DEST" ] && [ -z "$RESTORE_COLLECTION_SOURCE" ]; then
    echo "Error: When specifying a destination collection, you must also specify the source collection name (as in the backup)."
    exit 1
  fi
  if [ -n "$RESTORE_COLLECTION_SOURCE" ] && [ -z "$RESTORE_COLLECTION_DEST" ]; then
    echo "Error: When specifying a source collection, you must also specify the destination collection name."
    exit 1
  fi

  echo "Copying MongoDB backup file to the container..."

  # Copy the backup file to the container
  docker cp "$RESTORE_FILE" "$CONTAINER_NAME:/tmp/$(basename $RESTORE_FILE)"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to copy backup file to the container."
    exit 1
  fi

  echo "Restoring MongoDB backup from $RESTORE_FILE..."

  # Run the MongoDB restore command inside the container

  MONGO_AUTH_ARGS=""
  if [ "$USE_CREDENTIALS" != "false" ]; then
    MONGO_AUTH_ARGS="--username=$MONGO_USER --password=$MONGO_PASSWORD --authenticationDatabase admin"
  fi

  NS_REMAP_ARGS=""
  if [ -n "$RESTORE_COLLECTION_SOURCE" ] && [ -n "$RESTORE_COLLECTION_DEST" ]; then
    NS_REMAP_ARGS="--nsFrom=\"${MONGO_DB_NAME}.${RESTORE_COLLECTION_SOURCE}\" --nsTo=\"${MONGO_DB_NAME}.${RESTORE_COLLECTION_DEST}\""
    echo "Remapping collection: ${MONGO_DB_NAME}.${RESTORE_COLLECTION_SOURCE} -> ${MONGO_DB_NAME}.${RESTORE_COLLECTION_DEST}"
  fi

  docker exec "$CONTAINER_NAME" sh -c "mongorestore --archive=/tmp/$(basename $RESTORE_FILE) --gzip --drop $MONGO_AUTH_ARGS --db=$MONGO_DB_NAME $NS_REMAP_ARGS"

  if [ $? -eq 0 ]; then
    echo "MongoDB restore completed successfully."
  else
    echo "Error: Failed to restore MongoDB data."
    exit 1
  fi

  echo "Cleaning up temporary backup file in the container..."
  docker exec "$CONTAINER_NAME" sh -c "rm /tmp/$(basename $RESTORE_FILE)"

  if [ $? -ne 0 ]; then
    echo "Warning: Failed to clean up temporary backup file in the container."
  fi

  echo "Restore completed successfully."
}

# Function to download a backup from S3 and put it in the S3_BACKUP_DIR_TEMP
download_backup() {
  if [ -z "$1" ]; then
    echo "Error: Please provide the backup file to download."
    exit 1
  fi

  DOWNLOAD_FILE=$1

  if [ "$USE_REMOTE" == "false" ]; then
    echo "Skipping S3 download because USE_REMOTE=false."
    return 0
  fi

  # Check if the backup file exists in S3
  aws s3 ls $S3_BACKUP_PATH$DOWNLOAD_FILE --profile $AWS_PROFILE > /dev/null
  if [ $? -ne 0 ]; then
    echo "Error: Backup file $DOWNLOAD_FILE not found in S3."
    exit 1
  fi

  # Ensure the temporary backup directory exists
  if [ ! -d "$S3_BACKUP_DIR_TEMP" ]; then
    mkdir -p "$S3_BACKUP_DIR_TEMP"
  fi

  echo "Downloading MongoDB backup from S3..."
  aws s3 cp $S3_BACKUP_PATH$DOWNLOAD_FILE $S3_BACKUP_DIR_TEMP --profile $AWS_PROFILE

  if [ $? -eq 0 ]; then
    echo "Backup downloaded from S3 successfully."
  else
    echo "Error: Failed to download backup from S3."
    exit 1
  fi

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
  echo "  restore [file] [source_collection] [dest_collection]"
  echo "                         Restore a MongoDB backup. Optionally remap a collection to a new name."
  echo "  list_backups_s3        List all backups available in the S3 bucket."
  echo "  list_backups_local     List all backups in the local backup directory."
  echo "  download_backup [file] Download a backup from S3 and store it locally."
  echo "  help                   Display this help message."
  echo
  echo "Options:"
  echo "  -h, --help          Display this help message."
  echo "  [file]              The name of the backup file (e.g., mongo_backup_2024-11-20.gz)."
  echo
  echo "Environment Flags:"
  echo "  USE_CREDENTIALS=false  Skip MongoDB username/password when dumping/restoring."
  echo "  USE_REMOTE=false       Skip all S3 uploads/downloads/list operations."
  echo
  echo "Examples:"
  echo "  ./mongo_backup_manager.sh backup"
  echo "    Performs a backup and uploads it to S3."
  echo
  echo "  ./mongo_backup_manager.sh restore mongo_backup_2024-11-20.gz"
  echo "    Restores the backup 'mongo_backup_2024-11-20.gz' from the local directory or S3."
  echo
  echo "  ./mongo_backup_manager.sh restore mongo_backup_2024-11-20.gz users users_restored"
  echo "    Restores the backup and writes collection 'users' from the archive into collection 'users_restored' on the destination database."
  echo
  echo "  ./mongo_backup_manager.sh list_backups_s3"
  echo "    Lists all backups available in the S3 bucket."
  echo
  echo "  ./mongo_backup_manager.sh download mongo_backup_2024-11-20.gz"
  echo "    Downloads the backup 'mongo_backup_2024-11-20.gz' from S3 to the local directory."
  echo
  echo "Note:"
  echo "  Ensure the .env file is present in the same directory for environment variable configuration."
  echo "  You can configure the backup directory, S3 bucket name, and MongoDB connection details in the .env file."
}

# Call the help function if the script is run without arguments or with the 'help' command
if [ $# -eq 0 ] || [[ "$1" == "help" ]] || [[ "$1" == "-h" ]]; then
  help
  exit 0
fi

# Main logic to parse arguments and call the corresponding function
if [ "$1" == "backup" ]; then
  # Call the backup function
  health_check
  backup
elif [ "$1" == "list_backups_s3" ]; then
  # Call the list_backups_s3 function
  health_check
  list_backups_s3
elif [ "$1" == "list_backups_local" ]; then
  # Call the list_backups_local function
  health_check
  list_backups_local
elif [ "$1" == "restore" ]; then
  # Call the restore function (file, optional source collection, optional dest collection)
  health_check
  restore "$2" "$3" "$4"
elif [ "$1" == "download_backup" ]; then
  # Call the download_backup function
  health_check
  download_backup "$2"
elif [ "$1" == "help" ]; then
  # Call the help function
  help
else
  # If the command is invalid, print usage
  echo "Usage: $0 {backup|restore|download} [file]"
  exit 1
fi

# At the end of the script
echo "-----------------------------------" >> "$LOG_FILE"
echo "Backup ended at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "-----------------------------------" >> "$LOG_FILE"
