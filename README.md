# MongoDB Backup Manager Script

This script automates the process of backing up a MongoDB database running in a Docker container. It also uploads the backups to an AWS S3 bucket for safe storage and retention.

---

## Features
- Creates compressed backups of your MongoDB database using `mongodump`, optionally limited to a subset of collections.
- Stores backups locally in a specified directory.
- Uploads backups to an AWS S3 bucket.
- Automatically cleans up old backups from the local directory (optional).
- Restores a backup to the MongoDB database.
- Verifies count and full index-spec parity between two namespaces after a restore/migration.
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
A **single** collection is dumped directly with `mongodump --collection` and needs no `mongosh`; if the name is misspelled the script detects mongodump's "does not exist" report and errors instead of writing an empty archive. Backing up **more than one** collection requires `mongosh` inside the container — `mongodump` can't include multiple specific collections in one pass, so the script enumerates the database's collections and dumps the whole database minus everything you didn't request (names not present are skipped with a warning, and it errors if none of the requested collections exist).

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

### Verifying a Restore

After a restore — especially a namespace remap during a migration — use the `verify` command to **prove** that the target namespace matches the source rather than trusting that `mongorestore` recreated everything correctly:

```bash
./mongo_backup_manager.sh verify <source_db> <source_collection> <dest_db> <dest_collection>
```

The argument order mirrors the `restore` remap, so you can run the same source/dest pair you just restored:

```bash
./mongo_backup_manager.sh verify sodax-registration users new-world stateful_users
```

`verify` connects to the running MongoDB via `mongosh` inside the container and compares:

- **Document count** (`countDocuments`) of both collections.
- **The full index spec** of every index — name, key, `unique`, `sparse`, `partialFilterExpression`, `collation`, and TTL (`expireAfterSeconds`). The cosmetic `v` (index version) and `ns` (namespace, which legitimately differs across DBs) fields are stripped before comparison, and field ordering is normalized so only meaningful differences are reported.

This catches mismatches a names-only check would miss — for example a `unique` index on `stateful_partner_naming.name` that lost its `sparse: true`, which would otherwise pass review and later throw duplicate-key errors on rows whose `name` is `null`.

The command **exits non-zero on any mismatch**, so it can gate a migration script or run in CI. Example output on success:

```
Performing health check...
Health check passed! All required variables are set.
Verifying sodax-registration.users -> new-world.stateful_users...
source sodax-registration.users: count=8 indexes=3
target new-world.stateful_users: count=8 indexes=3
VERIFY OK: document counts and full index specs match.
Verification passed.
```

And on a mismatch (note identical counts and index *names* — only the spec differs):

```
target new-world.stateful_users: count=8 indexes=3
VERIFY FAILED:
  - index on source missing/differs on target: {"key":{"name":1},"name":"name_1","sparse":true,"unique":true}
  - index on target absent/differs on source: {"key":{"name":1},"name":"name_1","unique":true}
Verification failed.
```

> The MongoDB user in `.env` needs read access (e.g. `read`) on **both** the source and destination databases. `verify` requires `mongosh` to be available inside the container (included in the official `mongo` images from 5.0+).

## Scheduling automated backups

The `backup` command runs to completion and exits non-zero on failure, so it schedules cleanly. Two options; a systemd timer is recommended on Linux hosts.

### Option A — systemd timer (recommended)

Ready-to-edit unit files live in [`systemd/`](systemd/). They run `backup` on a schedule, order after Docker and the network, and send output to the journal.

1. Put the script somewhere stable (e.g. `/opt/mongo-backup`) with its `.env` beside it, then edit the marked lines in `systemd/mongo-backup.service` — `User`/`Group`, `WorkingDirectory`, and `ExecStart` — so they point at that location and at a user who can reach Docker and your AWS profile.
2. Install and enable:
   ```bash
   sudo cp systemd/mongo-backup.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now mongo-backup.timer
   ```
3. Verify:
   ```bash
   systemctl list-timers mongo-backup.timer   # next / last run
   sudo systemctl start mongo-backup.service  # run one backup right now
   journalctl -u mongo-backup.service -e      # read its output
   ```

The default schedule is daily at 03:00 (`OnCalendar` in `mongo-backup.timer`); change it to `hourly` or any [`OnCalendar`](https://www.freedesktop.org/software/systemd/man/systemd.time.html) expression. `Persistent=true` means a run missed while the machine was off fires at the next boot.

### Option B — cron

```bash
crontab -e
```
```cron
# docker/aws/mongosh are not on cron's minimal PATH — set one explicitly.
PATH=/usr/local/bin:/usr/bin:/bin
# Daily at 03:00. Pass the `backup` command (the whole point) and redirect output
# so a failure is captured somewhere you can read it.
0 3 * * * /path/to/mongo_backup_manager.sh backup >> /var/log/mongo_backup.log 2>&1
```

The cron user must be able to run `docker` (member of the `docker` group, or root) and must own the `~/.aws` profile named by `AWS_PROFILE` in `.env` (or the host must use an EC2 instance role).

### Retention

Every `backup` run prunes backups older than 7 days from **both** locations:

- **Local** — `find -mtime +7` removes old `*.gz` files under `backups/`.
- **S3** — objects under the `mongodb-backups/` prefix whose embedded timestamp is more than 7 days old are deleted (requires `s3:ListBucket` + `s3:DeleteObject`, both in the IAM policy above). This is best-effort: a transient S3 error warns but does not fail an otherwise-successful backup.

For defence-in-depth you can *also* add an S3 **lifecycle rule** on the `mongodb-backups/` prefix to expire (or transition to Glacier) old objects, so retention still happens even if a scheduled run is skipped for a long stretch.
