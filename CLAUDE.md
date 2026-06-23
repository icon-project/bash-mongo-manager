# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A single Bash script, `mongo_backup_manager.sh`, that backs up / restores a MongoDB
database running **inside a Docker container** and optionally syncs the backups to an
AWS S3 bucket. There is no build system, package manager, or test suite — the entire
project is this one script plus its `README.md`.

## Running

```bash
chmod +x mongo_backup_manager.sh          # once
./mongo_backup_manager.sh help            # usage (also the default with no args)
./mongo_backup_manager.sh backup          # dump → copy to host → upload to S3 → prune >7d
./mongo_backup_manager.sh list_backups_local
./mongo_backup_manager.sh list_backups_s3
./mongo_backup_manager.sh download_backup <file.gz>   # S3 → ./backups_temp/
./mongo_backup_manager.sh restore <file> [src_db src_coll dst_db dst_coll]
./mongo_backup_manager.sh verify <src_db src_coll dst_db dst_coll>   # post-restore parity check
```

Requires a `.env` file beside the script (the script exits if missing). Required keys:
`CONTAINER_NAME`, `MONGO_PORT`, `MONGO_DB_NAME`; plus `MONGO_USER`/`MONGO_PASSWORD`
unless `USE_CREDENTIALS=false`; plus `S3_BUCKET_NAME`/`AWS_PROFILE` unless `USE_REMOTE=false`.
See `README.md` for the full table and the required IAM policy.

There is no linter configured; if changing the script, validate manually with
`bash -n mongo_backup_manager.sh` and ideally `shellcheck`.

## Architecture / things that aren't obvious from a skim

- **`set -euo pipefail`** is on — any unset var or failed command aborts the run. Guard
  optional vars with `${VAR:-}` (the script does this consistently).
- **Two feature flags gate whole code paths**, normalized to lowercase at the top:
  - `USE_CREDENTIALS=false` → no `--username/--password/--authenticationDatabase` args
    are passed to `mongodump`/`mongorestore`, and they're dropped from `health_check`.
  - `USE_REMOTE=false` → all S3 upload/download/list calls are skipped, and
    `S3_BACKUP_PATH` is never even defined (so don't reference it unconditionally).
- **`health_check`** runs before every command (except `help`) and builds its required-var
  list dynamically from the two flags above. Adding a new required var means updating
  `REQUIRED_VARS` there.
- **Auth args are passed as a bash array** via `build_mongo_auth_args` (a nameref helper),
  never through `sh -c`. This is deliberate — it avoids shell-quoting/injection issues with
  passwords. Keep new docker exec args in arrays the same way.
- **Backup flow**: `mongodump --archive --gzip` writes *inside* the container to a bare
  filename, then `docker cp` pulls it to `./backups/`, then optional S3 upload, then a
  `find -mtime +7` prune of local `*.gz`. Filenames are `mongo_backup_<TIMESTAMP>.gz`.
- **Restore flow**: `docker cp` the archive into the container's `/tmp`, then `mongorestore
  --drop`. With no remap args it restores `--nsInclude=${MONGO_DB_NAME}.*`. With all four
  remap args it uses `--nsInclude/--nsFrom/--nsTo` to move `src_db.src_coll → dst_db.dst_coll`
  — and the remap args are **all-or-nothing** (validated; partial sets error out). The Mongo
  user needs `readWrite` on the *destination* DB or you get "listCollections requires
  authentication".
- **Verify flow**: `verify` runs entirely inside the container via `docker exec ... mongosh
  --eval`, reaching both namespaces with `getSiblingDB`. The JS canonicalizes each index
  (strips `v`/`ns`, recursively sorts object keys but preserves the order-sensitive `key`
  field; non-plain objects like BSON `Date`/`ObjectId` are serialized with `EJSON` so distinct
  scalar values stay distinct), compares the normalized index-set plus `countDocuments`, and
  `quit(1)`s on any mismatch — the bash wrapper turns that into a non-zero script exit. mongosh
  uses space-separated auth flags (`build_mongosh_auth_args`), unlike mongodump/mongorestore
  which take `--flag=val` (`build_mongo_auth_args`). The JS logic lives in a **quoted**
  (`<<'EOF'`) heredoc — so the shell does no expansion and the JS may use `$`/backticks freely —
  and the four namespace names are prepended as a prelude of JSON-encoded JS string literals
  (`json_str`), so a db/collection name containing a quote or backslash can't break or alter
  the script. Keep that split intact when editing: logic in the quoted heredoc, names via the
  escaped prelude — never interpolate raw names into the JS.
- **Directories**: `./backups` (local dumps, git-kept but contents gitignored), `./backups_temp`
  (S3 downloads land here), `./logs` (run separators appended per invocation; gitignored).
- `.env`, `*.gz`, and backup dir contents are all gitignored — never commit them.

## Adding a command

Define a function, then add a `case` branch in the dispatcher at the bottom that calls
`health_check` (if it touches Mongo/S3) and forwards positional args as `"${2:-}"` etc.
Also add a line to `help()`.
