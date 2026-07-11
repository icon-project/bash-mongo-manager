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
./mongo_backup_manager.sh alert [unit]   # best-effort failure alert; for systemd OnFailure=
```

Requires a `.env` file beside the script (the script exits if missing); `.env-example`
is the committed template (placeholders only — real secrets never committed). Required keys:
`CONTAINER_NAME`, `MONGO_PORT`, `MONGO_DB_NAME`; plus `MONGO_USER`/`MONGO_PASSWORD`
unless `USE_CREDENTIALS=false`; plus `S3_BUCKET_NAME`/`AWS_PROFILE` only when `USE_REMOTE=true`
(remote is **off by default** — `USE_REMOTE` defaults to `false`); plus at least one alert
destination (`DISCORD_WEBHOOK_URL`, and/or `TELEGRAM_BOT_TOKEN`+`TELEGRAM_CHAT_ID`) only when
`USE_ALERTS=true` (alerting is **off by default**).
See `README.md` for the full table and the required IAM policy.

There is no linter configured; if changing the script, validate manually with
`bash -n mongo_backup_manager.sh` and ideally `shellcheck`.

## Architecture / things that aren't obvious from a skim

- **`set -euo pipefail`** is on — any unset var or failed command aborts the run. Guard
  optional vars with `${VAR:-}` (the script does this consistently).
- **Three feature flags gate whole code paths**, normalized to lowercase at the top:
  - `USE_CREDENTIALS=false` → no `--username/--password/--authenticationDatabase` args
    are passed to `mongodump`/`mongorestore`, and they're dropped from `health_check`.
  - `USE_REMOTE=false` → all S3 upload/download/list/prune calls are skipped, and
    `S3_BACKUP_PATH` is never even defined (so don't reference it unconditionally).
  - `USE_ALERTS=false` (default) → the `alert` command sends nothing, and `health_check`
    skips alert-config validation. When `true`, `health_check` requires a usable
    destination and the `alert` command actually posts (see the alerting bullet below).
- **`health_check`** runs before every command (except `help` and `alert`) and builds its
  required-var list dynamically from the flags above. Adding a new required var means updating
  `REQUIRED_VARS` there. It also validates `S3_RETENTION_DAYS` (when remote) and the alert
  config (when alerting): a half-configured Telegram (only one of token/chat-id) or
  `USE_ALERTS=true` with no destination is rejected — never echoing any secret value.
- **Container-name resolution** (`resolve_container`): `CONTAINER_NAME` may be an exact name
  (backward-compatible) *or* a stable prefix (Coolify regenerates the full
  `sodax-stateful-mongo-<hash>-<ts>` name on every redeploy). Resolved at run time via
  `docker ps --filter name=` (running only). Docker's `name=` is an *unanchored substring* match,
  so the results are post-processed: an **exact** `{{.Names}}` match wins if one is running (so an
  exact name that's also a substring of another container — `mongo` vs `mongo-express` — isn't
  wrongly rejected as ambiguous); otherwise the results are **filtered to names that actually
  start with** the configured value (a bare substring like `old-<prefix>-sidecar` is *not* a
  prefix match, so it can't be silently picked when the real container is down), and **exactly
  one** must remain — 0 (nothing up) or >1 (ambiguous) is a hard error, never a guess (wrong
  container = wrong backup, or on restore a destructive overwrite). It
  mutates the global `CONTAINER_NAME` in place and is called once from the dispatcher, right
  after `health_check`, for **backup/restore/verify only** — the list/download/alert commands
  don't touch the container and must not require one to be running.
- **Auth args are passed as a bash array** via `build_mongo_auth_args` (a nameref helper),
  never through `sh -c`. This is deliberate — it avoids shell-quoting/injection issues with
  passwords. Keep new docker exec args in arrays the same way.
- **Backup flow**: `mongodump --archive --gzip` writes *inside* the container to a bare
  filename, then `docker cp` pulls it to `./backups/`, then `docker exec rm -f` deletes the
  in-container copy (nothing else would — otherwise dumps pile up in the container's writable
  layer), then optional S3 upload, then a `find -mtime +7` prune of local `mongo_backup_*.gz`
  (name-restricted so an unrelated `.gz` in the dir is never deleted). Filenames
  are `mongo_backup_<TIMESTAMP>.gz`.
  **Retention runs on both sides**: after upload (when remote is on) it also prunes S3 —
  `list-objects-v2` under the `mongodb-backups/` prefix, then deletes any `mongo_backup_*.gz`
  whose name-embedded timestamp is older than `S3_RETENTION_DAYS` (env var, default `7`). S3
  has no age filter, so it strips each name to
  its 14-digit `YYYYMMDDHHMMSS` and integer-compares it against a host-local cutoff built the
  same way as `TIMESTAMP` — an integer compare, *not* a string `<` (that would be
  locale-dependent), and names without a full 14-digit stamp are skipped. The S3 prune is
  best-effort (warns, doesn't abort) since the dump already uploaded; it needs `s3:ListBucket`
  + `s3:DeleteObject`. `S3_RETENTION_DAYS=0` skips the S3 prune entirely (an S3 lifecycle
  policy owns retention instead); `health_check` validates it as a non-negative integer when
  `USE_REMOTE=true`. Only the S3 side is configurable — the local `find -mtime +7` is still
  fixed at 7 days.
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
- **Directories** are all anchored to the script's own location via `SCRIPT_DIR` (like
  `LOG_FILE`/`ENV_FILE`), *not* the caller's CWD — so they resolve correctly under cron/systemd
  where CWD is usually `$HOME`. `backups/` (local dumps, git-kept but contents gitignored),
  `backups_temp/` (S3 downloads land here), `logs/` (gitignored). Keep new paths
  `SCRIPT_DIR`-anchored too.
- **Run logging**: near the top the script does `exec > >(tee -a "$LOG_FILE") 2>&1`, so *all*
  stdout+stderr for the run is mirrored into `logs/mongo_backup_manager.log` (not just the
  separators) while still reaching the terminal/journal; a process substitution is used (not
  `| tee`) to preserve the script's own exit status. A `trap log_run_end EXIT` writes the
  end separator + exit code on every exit path, so early/failed exits are still recorded.
- **Scheduling**: `systemd/mongo-backup.{service,timer}` are ready-to-edit units that run
  `backup` on a timer (see README "Scheduling automated backups"). The service is `Type=oneshot`
  and sets an explicit `PATH` (cron/systemd start with a minimal one, so `docker`/`aws`/`mongosh`
  wouldn't otherwise resolve).
- **Failure alerting**: `mongo-backup.service` has `OnFailure=mongo-backup-alert.service`; that
  companion oneshot runs `mongo_backup_manager.sh alert mongo-backup.service`, which tails the
  failed unit's journal (`journalctl -u … -o cat`) and posts it to Discord and/or Telegram.
  The tail is scoped to the unit's **most recent invocation** by matching its invocation ID
  (`systemctl show -p InvocationID --value` → `journalctl _SYSTEMD_INVOCATION_ID=…`, portable back
  to systemd v232 — *not* `--invocation=0`, which is v257+ only and would silently no-op on the
  common v254–256), with a fallback to a plain across-history tail when the ID is unavailable — so
  a short failure right after a chatty successful run isn't buried under the previous run's output.
  The per-destination char-cap truncation keeps the **tail** of the excerpt (not the head), so the
  `Run FAILED during stage: …` line — always last — survives even a verbose late-stage failure.
  (Both truncations only tail when the char budget is positive, so a pathologically long title
  can't trip the `${var: -0}` whole-string return.)
  It runs as the **same unprivileged user** as the backup (in the `systemd-journal` group so it
  can read the unit journal), **not root** — the script `source`s `.env`, so a root alert + a
  backup-user-writable `.env` would be a local privilege escalation. As a backstop the script
  refuses to source a non-root-owned or group/other-writable `.env` when it *is* run as root
  (`id -u`==0 check before the `source`).
  A **stage marker** makes the alert unambiguous: `stage "<name>"` sets a global `CURRENT_STAGE`
  and echoes `>>> STAGE: <name>` into the log/journal at each transition. The dispatcher runs
  `resolve container` first (shared by backup/restore/verify); then each command advances it —
  backup: `prepare dump → mongodump → copy dump to host → S3 upload → S3 prune → local prune`;
  restore: `restore preflight → copy archive to container → mongorestore`; verify: `verify`. The
  `log_run_end` EXIT trap prints `Run FAILED during stage: <CURRENT_STAGE>` on a non-zero exit,
  so the journal tail the alert forwards names the culprit (every path advances past
  `resolve container`, so a failure is never misattributed to name resolution). The `alert` command is **best-effort by contract**: it never
  runs `health_check`/`resolve_container` (it fires *because* the backup broke, maybe because the
  container is gone), each destination is attempted independently, a failed send only warns, and
  it **always returns 0** — an alert hiccup must not add a scary secondary failure. Secrets are
  never echoed and curl output is discarded so the webhook URL / bot token can't leak into the
  log. Discord JSON is built with `jq` when present, else the in-script `json_escape_body` (which,
  unlike `json_str`, also escapes newlines/tabs); Telegram uses `curl --data-urlencode`, no JSON.
- `.env`, `*.gz`, and backup dir contents are all gitignored — never commit them.
  `.env-example` (placeholders only) **is** committed as the template; keep it in sync when
  adding/removing env vars, but never put a real secret in it.

## Adding a command

Define a function, then add a `case` branch in the dispatcher at the bottom that calls
`health_check` (if it touches Mongo/S3) and forwards positional args as `"${2:-}"` etc.
Also add a line to `help()`.
