# MongoDB Backup Manager Script

This script automates the process of backing up a MongoDB database running in a Docker container. It also uploads the backups to an AWS S3 bucket for safe storage and retention.

---

## Features
- Creates compressed backups of your MongoDB database using `mongodump`, optionally limited to a subset of collections.
- Stores backups locally in a specified directory.
- Uploads backups to an AWS S3 bucket.
- Automatically cleans up old backups from the local directory (optional).
- Restores a backup to the MongoDB database.
---

## Prerequisites

### **1. MongoDB in Docker**
- Ensure Docker is installed on the host machine and The MongoDB instance must be running in a Docker container.

### **2. AWS CLI**
- Install the AWS CLI by following the instructions [here](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
- Configure the AWS CLI with your AWS credentials:
  ```bash
  aws configure
  ```
  Provide:
  - AWS Access Key ID
  - AWS Secret Access Key
  - Default region (e.g., `us-east-1`)
  - Default output format (e.g., `json`)


### **3. Permissions**
Ensure the IAM user associated with the AWS credentials has the correct permission, the following JSON policy can be attached to the IAM user:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::ACCOUNT:user/USER"
            },
            "Action": [
                "s3:GetBucketLocation",
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::BUCKET"
        },
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::ACCOUNT:user/USER"
            },
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::BUCKET"
        }
    ]
}
```
### **4. Misc installations**
* `sudo apt install dotenv`

---

## Environment Variables.

Create a `.env` file in the same directory as the script and add the following environment variables:

```bash
# Set variables
CONTAINER_NAME="name-of-your-mongo-container"
S3_BUCKET_NAME="name-of-your-s3-bucket"
MONGO_PORT="27017"
MONGO_USER="user"
MONGO_PASSWORD="password"
MONGO_DB_NAME="test"
USE_CREDENTIALS="true" # set to false if the DB has no auth
USE_REMOTE="true"      # set to false to skip all S3 interactions
```
| Variable           | Description                                                                |
|--------------------|----------------------------------------------------------------------------|
| `CONTAINER_NAME`   | Name of the MongoDB container.                                             |
| `S3_BUCKET_NAME`   | Name of the AWS S3 bucket where backups will be stored (required only when `USE_REMOTE=true`).                   |
| `MONGO_PORT`       | Port number of the MongoDB instance.|
| `MONGO_USER`       | MongoDB username (required only when `USE_CREDENTIALS=true`).|
| `MONGO_PASSWORD`   | MongoDB password (required only when `USE_CREDENTIALS=true`).|
| `MONGO_DB_NAME`    | Name of the MongoDB database to backup.|
| `USE_CREDENTIALS`  | When `false`, skips MongoDB username/password in dump/restore commands. Defaults to `true`.|
| `USE_REMOTE`       | When `false`, skips all S3 upload/download/list actions. Defaults to `true`.|

> If your `.env` is saved with Windows (CRLF) line endings, the script strips the trailing carriage return from these values automatically, so a stray `\r` won't break the container name, port, or S3 path. Only the CR is removed — other whitespace (e.g. inside a password) is preserved as-is.

---

## How to Use

The script can be run manually or scheduled to run at regular intervals using cron jobs.

The following commands can be used to run the script manually:

First Make the script executable:
```bash
chmod +x mongo_backup_manager.sh
```

The `help` command can be used to display the script's usage information:
```bash
./mongo_backup_manager.sh help
```

The `backup` command can be used to create a backup of the MongoDB database:
```bash
./mongo_backup_manager.sh backup
```

To back up only a subset of collections, pass a comma-separated list (no spaces around the commas):
```bash
./mongo_backup_manager.sh backup users,tasks
```
Backing up **more than one** collection requires `mongosh` inside the container — `mongodump` can't include multiple specific collections in one pass, so the script dumps the whole database minus everything you didn't request (a single collection is dumped directly via `--collection` and needs no `mongosh`). Names not present in the database are skipped with a warning.

The `list_backups_local` command can be used to list all backups stored locally:
```bash
./mongo_backup_manager.sh list_backups_local
```

The `list_backups_s3` command can be used to list all backups stored in the S3 bucket:
```bash
./mongo_backup_manager.sh list_backups_s3
```

When running locally-only without S3, set `USE_REMOTE=false` in `.env` to bypass S3 upload, download, and listing.

### Downloading a Backup from S3

If you have a backup in the S3 bucket and you want to download it to your local machine, you can use the `download_backup` command by specifying the backup file name (the backup file name can be obtained from the `list_backups_s3` command).

For example, first list the backups in the S3 bucket:

```bash
./mongo_backup_manager.sh list_backups_s3
Performing health check...
Health check passed! All required variables are set.
Listing MongoDB backups in S3...
2024-11-20 13:29:01       1383 mongodb-backups/mongo_backup_2024-11-20_13-28-59.gz
```

Then download the backup file:
```bash
./mongo_backup_manager.sh download_backup mongo_backup_2024-11-20_13-28-59.gz
Performing health check...
Health check passed! All required variables are set.
Downloading MongoDB backup from S3...
download: s3://hana-rewards-db-backups/mongodb-backups/mongo_backup_2024-11-20_13-28-59.gz to backups_temp/mongo_backup_2024-11-20_13-28-59.gz
Backup downloaded from S3 successfully.
Download completed successfully.
```

The backup file will be downloaded to the `backups_temp` directory.

### Restoring a Backup

To restore a backup, you can use the `restore_backup` command by specifying the backup file name, this backup can either be in the folder with the local backups or if you want to restore a backup from S3, you can download the backup file first and then restore it.

The following command showcases how to restore a backup:
```bash
./mongo_backup_manager.sh restore backups_temp/mongo_backup_2024-11-20_13-28-59.gz
```

To restore only a subset of collections (into `MONGO_DB_NAME`), pass a comma-separated list (no spaces around the commas) as the single extra argument:
```bash
./mongo_backup_manager.sh restore backups_temp/mongo_backup_2024-11-20_13-28-59.gz users,tasks
```
Only the listed collections are restored from the archive (via `mongorestore --nsInclude`); `--drop` only affects the collections being restored, so the rest of the database is left untouched. A single name (e.g. `users`) restores just that one collection in place.

You can optionally remap a namespace by specifying source database and collection, then destination database and collection (all four arguments are required together):
```bash
./mongo_backup_manager.sh restore backups_temp/mongo_backup_2024-11-20_13-28-59.gz new-world users my-app stateful_users
```
This restores the collection `new-world.users` from the archive into `my-app.stateful_users` on the destination. The script will show: `Remapping namespace: new-world.users -> my-app.stateful_users`. The MongoDB user in `.env` must have **readWrite** (or at least `listCollections` and insert) on the **destination** database (e.g. `my-app`), or you will get "Command listCollections requires authentication".

Before copying or restoring anything, `restore` runs a **preflight auth check**: it uses `mongosh` to confirm the configured credentials can reach the destination database (the remap target, or `MONGO_DB_NAME` for a plain restore) and aborts with a clear message if they can't — so a permissions problem fails fast instead of partway through `mongorestore`. The preflight is skipped automatically if `mongosh` isn't available inside the container.

Example output:
```
Performing health check...
Health check passed! All required variables are set.
Copying MongoDB backup file to the container...
Successfully copied 3.07kB to mongodb-prod:/tmp/mongo_backup_2024-11-20_13-28-59.gz
Restoring MongoDB backup from backups_temp/mongo_backup_2024-11-20_13-28-59.gz...
2024-11-20T13:59:11.468+0000	The --db and --collection flags are deprecated for this use-case; please use --nsInclude instead, i.e. with --nsInclude=${DATABASE}.${COLLECTION}
2024-11-20T13:59:11.485+0000	preparing collections to restore from
2024-11-20T13:59:11.497+0000	reading metadata for test.user_tasks from archive '/tmp/mongo_backup_2024-11-20_13-28-59.gz'
....
....
2024-11-20T14:00:19.170+0000	8 document(s) restored successfully. 0 document(s) failed to restore.
MongoDB restore completed successfully.
Cleaning up temporary backup file in the container...
Restore completed successfully.
```

## Setting up backups with cron

To schedule the script to run at regular intervals, you can use cron jobs. Here's how you can set up a cron job to run the script every hour:

1. Open the crontab file for editing:
   ```bash
   crontab -e
   ```
2. Add the following line to the crontab file:
   ```bash
    0 * * * * /path/to/mongo_backup_manager.sh >> /var/log/mongo_backup_manager.log 2>&1
    ```
