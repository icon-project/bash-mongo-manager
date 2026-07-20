#!/usr/bin/env bash
set -euo pipefail

# This script needs bash 4.3+: it uses namerefs (local -n) and loads .env via
# `source <(...)` process substitution. macOS ships bash 3.2 as /bin/bash, where
# BOTH break — the nameref syntax errors and, worse, the process-substitution
# source silently reads *nothing*, so every var falls back to its default and
# the run misbehaves later with a baffling error (e.g. a missing CONTAINER_NAME
# surfacing as an "unbound variable"). Fail fast here with an actionable message
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

# Mirror everything this run prints (stdout + stderr) into the log while still
# showing it on the terminal / journal. Previously only the run separators were
# written here, so the "log" recorded timestamps but none of the actual output;
# tee makes it a real record however the script is invoked. Using a process
# substitution (not a `| tee` pipe) keeps the script's own exit status intact.
#
# EXCEPT for the `alert` command: it's a notifier invoked by systemd's OnFailure
# hook, so its natural sink is the journal (via stdout), not the backup's on-disk
# log. Skipping file logging here also keeps it robust to who runs it: the shipped
# mongo-backup-alert.service runs as the same unprivileged user as the backup, but
# if an operator overrides it to run as root, a root-created logs/ (or log file)
# would then be un-appendable by the non-root backup — silently breaking backup
# logging. So the alert path skips on-disk logging entirely; only non-alert
# commands mkdir logs/ and tee to the file.
if [ "${1:-}" != "alert" ]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# Track which stage of a run is executing so a failure is attributable — did the
# backup die in mongodump, the S3 upload, or a prune? `stage` records the name
# and echoes a marker into the log/journal; the end-of-run separator and the
# failure alert (mongo-backup-alert.service, via journalctl) both read it, so an
# unattended run's alert is unambiguous. Defined before the EXIT trap so it's
# always set when the trap fires (guarded with :- for the earliest failures).
CURRENT_STAGE="starting"
stage() {
  CURRENT_STAGE="$1"
  echo ">>> STAGE: $1"
}

# Always close the run out with an end separator and the exit code — even on an
# early exit or a failure under `set -e`. The trap fires on every exit path; the
# old end-of-file block was skipped whenever the script exited early, so a failed
# run looked like it never finished. On a non-zero exit it also names the stage
# that was running, so the journal tail an alert forwards points at the culprit.
log_run_end() {
  local ec=$?
  echo "-----------------------------------"
  if [ "$ec" -ne 0 ]; then
    echo "Run FAILED during stage: ${CURRENT_STAGE:-unknown} (exit $ec)"
  fi
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
  # Fail fast if the file exists but we can't read it (e.g. wrong owner/mode
  # under a cron/systemd run user). Otherwise the `tr` below would produce an
  # empty stream that `source` reads successfully, silently falling back to
  # every default and dying later with a misleading "X is not set".
  if [ ! -r "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE exists but is not readable by user '$(id -un)'." >&2
    exit 1
  fi
  # If we're running as root, refuse to `source` a .env that a non-root user
  # could have written: sourcing EXECUTES the file, so a non-root-owned or
  # group/other-writable .env would let that user inject arbitrary code that then
  # runs as root — a local privilege escalation. (This matters most for the
  # OnFailure alert path if it's configured to run as root; the shipped unit runs
  # as the unprivileged backup user instead.) Require root-owned and not
  # group/other-writable; the fix is a one-liner shown in the message.
  if [ "$(id -u)" -eq 0 ]; then
    env_uid=$(stat -c '%u' "$ENV_FILE" 2>/dev/null || stat -f '%u' "$ENV_FILE" 2>/dev/null || echo "")
    env_perm=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo "")
    if [ "$env_uid" != "0" ] || { [ -n "$env_perm" ] && [ $(( 8#$env_perm & 022 )) -ne 0 ]; }; then
      echo "Error: refusing to source $ENV_FILE as root — it must be root-owned and not group/other-writable" >&2
      echo "       (owner uid=${env_uid:-unknown}, perms=${env_perm:-unknown}). Sourcing executes the file, so a" >&2
      echo "       non-root-writable .env would run as root (privilege escalation)." >&2
      echo "       Fix: sudo chown root:root '$ENV_FILE' && sudo chmod 600 '$ENV_FILE'  — or run as the non-root backup user." >&2
      exit 1
    fi
  fi
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
  # `set -a` above auto-exported every .env value, so the secrets would be
  # inherited by every child process (curl, docker, aws, mongodump) and exposed
  # via /proc/<pid>/environ (readable by the same UID / root) for that child's
  # lifetime. Nothing spawned by this script needs any of these in its
  # environment: MONGO_PASSWORD is passed to mongodump/mongorestore/mongosh as a
  # command-line flag (built in build_mongo*_auth_args), and alert() hands the
  # webhook/bot URL to curl through a stdin config — all as shell variables, which
  # survive un-exporting. So drop the export attribute while keeping the values
  # in-process. (export -n on an unset name is a harmless no-op; keep this list in
  # sync with the secret-bearing vars.)
  export -n MONGO_PASSWORD DISCORD_WEBHOOK_URL TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID 2>/dev/null || true
else
  echo "Error: The .env file is missing. Please create the .env file with the required environment variables."
  exit 1
fi

# Normalize feature flags with defaults
USE_CREDENTIALS=$(echo "${USE_CREDENTIALS:-true}" | tr '[:upper:]' '[:lower:]')
USE_REMOTE=$(echo "${USE_REMOTE:-false}" | tr '[:upper:]' '[:lower:]')
# When true, failure alerting is active: health_check validates that at least one
# alert destination (Discord and/or Telegram) is configured, and the `alert`
# command (invoked by mongo-backup-alert.service on failure) actually sends.
# Off by default so existing deployments are unaffected.
USE_ALERTS=$(echo "${USE_ALERTS:-false}" | tr '[:upper:]' '[:lower:]')

# TLS for the mongo tool connections (mongodump/mongorestore/mongosh). Off by
# default so existing deployments are unaffected. Set to true when the target
# mongod runs net.tls.mode=requireTLS — a plaintext client is otherwise rejected
# mid-handshake ("socket was unexpectedly closed: EOF" / "server selection timeout").
USE_TLS=$(echo "${USE_TLS:-false}" | tr '[:upper:]' '[:lower:]')
# When true, skip validation of the server's certificate chain AND hostname. The
# connection is still encrypted, just not authenticated. This is the usual setting
# here because the tools connect to `localhost` *inside the container*, so the
# server cert (whose SAN is the service hostname, not "localhost") won't validate;
# a self-signed cert won't either. Prefer setting MONGO_TLS_CA_FILE instead when
# the CA is available in the container. mongodump/mongorestore get --tlsInsecure;
# mongosh gets --tlsAllowInvalidCertificates --tlsAllowInvalidHostnames.
MONGO_TLS_ALLOW_INVALID=$(echo "${MONGO_TLS_ALLOW_INVALID:-false}" | tr '[:upper:]' '[:lower:]')

# Number of days after which S3 backups are pruned. Default 7 (unchanged from the
# hard-coded value it replaces, so existing deployments are unaffected). 0 skips
# the S3 prune entirely, delegating retention to an S3 lifecycle policy on the
# bucket (one source of truth). Validated in health_check before use.
S3_RETENTION_DAYS="${S3_RETENTION_DAYS:-7}"

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

    # S3_RETENTION_DAYS gates the S3 prune, so a typo must not silently disable
    # pruning *and* skip the lifecycle rule. Require a non-negative integer.
    if ! [[ "$S3_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
      echo "Error: S3_RETENTION_DAYS must be a non-negative integer (got '$S3_RETENTION_DAYS')."
      exit 1
    fi
    # Normalize to base 10 up front. Bash arithmetic (both the `-eq 0` test and
    # the cutoff below) treats a leading-zero value as octal, so a valid-looking
    # `08` would abort with "value too great for base" and `010` would prune at 8
    # days, not 10. Canonicalizing here fixes both use sites at once.
    S3_RETENTION_DAYS=$((10#$S3_RETENTION_DAYS))
  fi

  # Validate alert configuration up front when alerting is enabled, so a run that
  # relies on being notified on failure can't silently have no working
  # destination. A destination is usable if Discord's webhook URL is set, or if
  # BOTH Telegram vars are set. A half-configured Telegram (token without chat id
  # or vice versa) is flagged as an error rather than silently ignored — it's
  # almost always a typo, and PR-#7-style "a typo can't silently disable the
  # safety net" reasoning applies. Secret *values* are never echoed here.
  if [ "$USE_ALERTS" != "false" ]; then
    local tg_token="${TELEGRAM_BOT_TOKEN:-}" tg_chat="${TELEGRAM_CHAT_ID:-}"
    if { [ -n "$tg_token" ] && [ -z "$tg_chat" ]; } || { [ -z "$tg_token" ] && [ -n "$tg_chat" ]; }; then
      echo "Error: Telegram alerting is half-configured — set BOTH TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID, or neither."
      exit 1
    fi
    local have_discord=0 have_telegram=0
    [ -n "${DISCORD_WEBHOOK_URL:-}" ] && have_discord=1
    { [ -n "$tg_token" ] && [ -n "$tg_chat" ]; } && have_telegram=1
    if [ "$have_discord" -eq 0 ] && [ "$have_telegram" -eq 0 ]; then
      echo "Error: USE_ALERTS=true but no alert destination is configured."
      echo "       Set DISCORD_WEBHOOK_URL and/or TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID in .env, or set USE_ALERTS=false."
      exit 1
    fi
    # A configured destination is useless without curl to POST to it: alert()
    # would only warn and return 0, leaving scheduled backups with a silently
    # nonfunctional safety net discovered only after a real failure. Since both
    # transports need curl, require it here so the misconfig is caught up front.
    if ! command -v curl >/dev/null 2>&1; then
      echo "Error: USE_ALERTS=true with a configured destination, but 'curl' is not on PATH — alerts could not be sent."
      echo "       Install curl on the backup host (and ensure it's on the systemd unit's PATH), or set USE_ALERTS=false."
      exit 1
    fi
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
  # Use ${S3_BUCKET_NAME:-} (not a bare ${S3_BUCKET_NAME}) so this top-level line
  # can't abort under `set -u` when USE_REMOTE=true but S3_BUCKET_NAME is unset.
  # Two reasons: (1) health_check gives a friendly "S3_BUCKET_NAME is not set"
  # message a few lines later — a bare ref would instead abort here with a cryptic
  # "unbound variable" before health_check ever runs; (2) more importantly, this
  # line runs for EVERY command, so a bare ref would take down the `alert` command
  # too — meaning the OnFailure alert couldn't even notify about a remote
  # misconfiguration (the exact failure it exists to report). alert never uses
  # S3_BACKUP_PATH, and the S3 commands all gate on health_check first, so an empty
  # value here is harmless.
  S3_BACKUP_PATH="s3://${S3_BUCKET_NAME:-}/mongodb-backups/"
fi

# Helper: build mongo auth args as an array (prevents shell-quoting issues)
build_mongo_auth_args() {
  # shellcheck disable=SC2178  # _out is a nameref to an array; the string assignment is the ref target, not a value
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
  # shellcheck disable=SC2178  # _csv_out is a nameref to an array; the string assignment is the ref target, not a value
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
  # shellcheck disable=SC2178  # _out is a nameref to an array; the string assignment is the ref target, not a value
  local -n _out=$1
  _out=()
  if [ "$USE_CREDENTIALS" != "false" ]; then
    _out+=( "--username" "$MONGO_USER" "--password" "$MONGO_PASSWORD" "--authenticationDatabase" "admin" )
  fi
}

# Helper: build mongodump/mongorestore TLS args as an array (--flag=val form, like
# build_mongo_auth_args). Empty unless USE_TLS is enabled. CA/cert paths are paths
# *inside the container* (the tools run via docker exec). mongodump/mongorestore
# take the combined --tlsInsecure to bypass cert-chain + hostname validation.
build_mongo_tls_args() {
  # shellcheck disable=SC2178  # _out is a nameref to an array; the string assignment is the ref target, not a value
  local -n _out=$1
  _out=()
  if [ "$USE_TLS" != "false" ]; then
    _out+=( "--tls" )
    if [ -n "${MONGO_TLS_CA_FILE:-}" ]; then _out+=( "--tlsCAFile=$MONGO_TLS_CA_FILE" ); fi
    if [ -n "${MONGO_TLS_CERT_KEY_FILE:-}" ]; then _out+=( "--tlsCertificateKeyFile=$MONGO_TLS_CERT_KEY_FILE" ); fi
    if [ "$MONGO_TLS_ALLOW_INVALID" != "false" ]; then _out+=( "--tlsInsecure" ); fi
  fi
}

# Helper: build mongosh TLS args as an array (space-separated flags, like
# build_mongosh_auth_args). mongosh exposes the granular --tlsAllowInvalid* flags
# rather than mongodump's combined --tlsInsecure.
build_mongosh_tls_args() {
  # shellcheck disable=SC2178  # _out is a nameref to an array; the string assignment is the ref target, not a value
  local -n _out=$1
  _out=()
  if [ "$USE_TLS" != "false" ]; then
    _out+=( "--tls" )
    if [ -n "${MONGO_TLS_CA_FILE:-}" ]; then _out+=( "--tlsCAFile" "$MONGO_TLS_CA_FILE" ); fi
    if [ -n "${MONGO_TLS_CERT_KEY_FILE:-}" ]; then _out+=( "--tlsCertificateKeyFile" "$MONGO_TLS_CERT_KEY_FILE" ); fi
    if [ "$MONGO_TLS_ALLOW_INVALID" != "false" ]; then
      _out+=( "--tlsAllowInvalidCertificates" "--tlsAllowInvalidHostnames" )
    fi
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

# Helper: emit a value as the *inside* of a JSON string (no surrounding quotes),
# escaping backslash, double quote, and the control chars that show up in a
# journal tail (tab/CR/newline). Unlike json_str (single-line Mongo names) this
# must survive multi-line text, so it handles newlines too. Order matters:
# backslashes first. Used to build the Discord webhook payload without jq.
json_escape_body() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  # JSON forbids raw control characters (0x00–0x1F) inside a string. The
  # substitutions above turned tab/CR/LF into escape sequences; strip any *other*
  # control bytes that might appear in the journal tail (e.g. ESC 0x1b from
  # ANSI-colored output) so this no-jq fallback still produces valid JSON and the
  # Discord POST doesn't fail. Best-effort alert → drop the noise rather than
  # \u-escaping it. (The jq path handles these correctly on its own.)
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Resolve CONTAINER_NAME to the single running container it names, then rewrite
# the global so backup/restore/verify all use the resolved value.
#
# Coolify (and similar orchestrators) regenerate the container's full name on
# every redeploy — e.g. sodax-stateful-mongo-<stackhash>-<timestamp> — so a
# hard-coded full name in .env silently breaks every `docker exec`/`docker cp`
# after the first redeploy. To survive that, CONTAINER_NAME may be EITHER:
#   * an exact container name (backward-compatible: it's the sole match), or
#   * a stable name prefix (e.g. "sodax-stateful-mongo").
# We resolve it at run time via `docker ps` (RUNNING containers only — no -a, so
# stale stopped containers from prior deploys are ignored). Docker's `name`
# filter matches "all or part" of a name (an unanchored substring), which is
# exactly the prefix behavior we want. But that substring match also means an
# EXACT name that happens to be a substring of another running container's name
# (e.g. "mongo" alongside "mongo-express", or "sodax-stateful-mongo" alongside an
# old sidecar carrying that substring) would come back as >1 and wrongly abort as
# ambiguous — regressing a previously valid exact-name config. So we prefer an
# EXACT `{{.Names}}` match when one is running, and only fall back to the
# prefix/substring path when there's no exact hit. On the prefix path we insist
# on EXACTLY one live match: 0 (nothing running) and >1 (ambiguous) are hard
# errors rather than a guess, because picking the wrong container would back up —
# or, on restore, overwrite — the wrong database.
resolve_container() {
  stage "resolve container"
  local matches count
  # Run docker ps inside an `if` so a Docker-side failure (daemon down,
  # permission denied) doesn't hard-exit via `set -e` with only Docker's raw
  # error — we add an actionable hint and still exit non-zero. Docker's own error
  # is left on stderr (so it's in the journal/log the alert forwards); only stdout
  # (the names) is captured.
  if ! matches=$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}'); then
    echo "Error: 'docker ps' failed while resolving CONTAINER_NAME '${CONTAINER_NAME}' (see the Docker error above)." >&2
    echo "       Is the Docker daemon running and reachable by user '$(id -un)' (in the docker group, or root)?" >&2
    exit 1
  fi

  # Exact name wins: if the configured value is itself one of the running
  # containers, use it as-is (backward-compatible) regardless of any other
  # containers whose names merely contain it as a substring.
  if printf '%s\n' "$matches" | grep -qxF -- "$CONTAINER_NAME"; then
    return 0
  fi

  # No exact match — treat CONTAINER_NAME as a PREFIX. Docker's `name=` filter
  # matches the string *anywhere* in the name, not just at the start, so without
  # this step `CONTAINER_NAME=sodax-stateful-mongo` could resolve to an unrelated
  # `old-sodax-stateful-mongo-sidecar` while the real DB container is down —
  # backing up (or, on restore, overwriting) the wrong container. Post-filter the
  # results to names that actually *begin* with the configured value. The case
  # glob quotes "$CONTAINER_NAME" so it's a literal prefix (no pattern chars) and
  # only the trailing * is a wildcard.
  local prefixed="" m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    case "$m" in "$CONTAINER_NAME"*) prefixed+="${m}"$'\n' ;; esac
  done <<< "$matches"
  matches="${prefixed%$'\n'}"

  # Count non-empty lines. `grep -c .` returns 0 (and exit 1) on empty input, so
  # guard with `|| true` to keep `set -e` from aborting on the no-match case.
  count=$(printf '%s\n' "$matches" | grep -c . || true)

  if [ "$count" -eq 0 ]; then
    echo "Error: CONTAINER_NAME '${CONTAINER_NAME}' matches no running container by exact name or name prefix." >&2
    echo "       Check the container is up ('docker ps') and that CONTAINER_NAME is its exact" >&2
    echo "       name or a stable name prefix (e.g. 'sodax-stateful-mongo')." >&2
    exit 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "Error: CONTAINER_NAME '${CONTAINER_NAME}' is ambiguous — it prefix-matches $count running containers:" >&2
    while IFS= read -r m; do [ -n "$m" ] && echo "         - $m" >&2; done <<< "$matches"
    echo "       Use the exact container name or a longer, unique prefix." >&2
    exit 1
  fi

  # Exactly one prefix match (and no exact match, or we'd have returned above).
  echo "Resolved container name prefix '${CONTAINER_NAME}' -> '${matches}'."
  CONTAINER_NAME="$matches"
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

  # Mark the pre-dump work (including the collection-listing mongosh preflight
  # below) so that if it fails under `set -e` — bad Mongo auth, or a
  # multi-collection request without mongosh — the failure alert attributes it to
  # this step instead of the stale "resolve container" stage. The actual dump
  # re-stamps the stage to "mongodump" just before running mongodump.
  stage "prepare dump"

  mkdir -p "$BACKUP_DIR"

  # Build auth + TLS args safely
  local AUTH_ARGS=()
  build_mongo_auth_args AUTH_ARGS
  local TLS_ARGS=()
  build_mongo_tls_args TLS_ARGS

  # Empty arrays are expanded with the ${arr[@]+"${arr[@]}"} idiom throughout:
  # on bash 4.3 (which the guard admits) a bare "${arr[@]}" on an *empty* array
  # aborts under `set -u` with "unbound variable" (only fixed in 4.4). AUTH_ARGS
  # is empty whenever USE_CREDENTIALS=false; TLS_ARGS whenever USE_TLS=false.
  local DUMP_ARGS=( "--archive=$BACKUP_FILE_NAME" "--gzip" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} ${TLS_ARGS[@]+"${TLS_ARGS[@]}"} )
  # Set to the collection name only on the no-mongosh single-collection path,
  # where we can't preflight and must instead detect a missing namespace from
  # mongodump's output (it exits 0 in that case).
  local SINGLE_COLLECTION=""

  if [ -n "$COLLECTIONS_CSV" ]; then
    local -a COLLECTIONS
    split_csv COLLECTIONS "$COLLECTIONS_CSV"
    if [ "${#COLLECTIONS[@]}" -eq 0 ]; then
      echo "Error: no collection names found in '$COLLECTIONS_CSV'."
      exit 1
    fi
    echo "Backing up collections from ${MONGO_DB_NAME}: ${COLLECTIONS[*]}"

    # When mongosh is available, fetch the DB's real collection list once and use
    # it to (a) fail fast on a missing/typo'd collection instead of silently
    # dumping an empty archive, and (b) build the exclude list for the
    # multi-collection case. Only multi-collection strictly needs mongosh; a
    # single collection can still fall back to --collection + output check.
    local have_mongosh=0
    if docker exec "$CONTAINER_NAME" sh -c 'command -v mongosh >/dev/null 2>&1'; then
      have_mongosh=1
    fi

    if [ "$have_mongosh" -eq 1 ]; then
      local MONGOSH_AUTH=()
      build_mongosh_auth_args MONGOSH_AUTH
      local MONGOSH_TLS=()
      build_mongosh_tls_args MONGOSH_TLS
      # JSON-encode the DB name into a JS string literal so a name containing a
      # quote or backslash can't alter the --eval script (see verify / json_str).
      local DB_JS
      DB_JS=$(json_str "$MONGO_DB_NAME")
      local ALL_COLLECTIONS
      ALL_COLLECTIONS=$(docker exec "$CONTAINER_NAME" mongosh --quiet ${MONGOSH_AUTH[@]+"${MONGOSH_AUTH[@]}"} ${MONGOSH_TLS[@]+"${MONGOSH_TLS[@]}"} \
        --eval "db.getSiblingDB(${DB_JS}).getCollectionNames().forEach(function (n) { print(n); })")

      if [ "${#COLLECTIONS[@]}" -eq 1 ]; then
        # Fail fast if the single collection doesn't exist: mongodump would exit
        # 0 and write an empty archive that then masquerades as a good backup.
        if ! printf '%s\n' "$ALL_COLLECTIONS" | grep -qxF -- "${COLLECTIONS[0]}"; then
          echo "Error: collection '${COLLECTIONS[0]}' does not exist in ${MONGO_DB_NAME}; nothing to back up." >&2
          exit 1
        fi
        DUMP_ARGS+=( "--db=$MONGO_DB_NAME" "--collection=${COLLECTIONS[0]}" )
      else
        # Warn about requested collections that don't exist.
        local req
        for req in "${COLLECTIONS[@]}"; do
          if ! printf '%s\n' "$ALL_COLLECTIONS" | grep -qxF -- "$req"; then
            echo "Warning: requested collection '$req' not found in ${MONGO_DB_NAME}; skipping."
          fi
        done
        # mongodump can't include multiple specific collections in one pass, so
        # dump the whole DB minus every existing collection that wasn't requested.
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
      # No mongosh in the container: multi-collection can't build its exclude
      # list, so require it; a single collection still works via --collection,
      # validated from the dump output afterward.
      if [ "${#COLLECTIONS[@]}" -ne 1 ]; then
        echo "Error: backing up more than one collection needs mongosh inside container '${CONTAINER_NAME}'."
        echo "       Back them up one at a time, or use a container image that includes mongosh."
        exit 1
      fi
      DUMP_ARGS+=( "--db=$MONGO_DB_NAME" "--collection=${COLLECTIONS[0]}" )
      SINGLE_COLLECTION="${COLLECTIONS[0]}"
    fi
  else
    DUMP_ARGS+=( "--db=$MONGO_DB_NAME" )
  fi

  # Run the MongoDB dump command inside the container (NO sh -c; pass args
  # directly). Capture output so we can detect a missing single collection,
  # which mongodump reports without a non-zero exit. Capture the exit status
  # without letting set -e abort first, so the mongodump diagnostics are always
  # printed before we exit on a real failure (bad creds, unreachable, disk full).
  stage "mongodump"
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
  stage "copy dump to host"
  docker cp "$CONTAINER_NAME:$BACKUP_FILE_NAME" "$BACKUP_FILE"

  # Remove the in-container archive now that it's safely on the host. mongodump
  # wrote it to the container's working directory and nothing else cleans it up,
  # so without this every run would leave another dump inside the container and
  # grow its writable layer without bound. Mirrors the /tmp cleanup in restore.
  docker exec "$CONTAINER_NAME" rm -f "$BACKUP_FILE_NAME" || true

  # Upload the backup to S3
  if [ "$USE_REMOTE" != "false" ]; then
    stage "S3 upload"
    aws s3 cp "$BACKUP_FILE" "$S3_BACKUP_PATH" --profile "$AWS_PROFILE"
    echo "Backup uploaded to S3 successfully."

    # Prune S3 backups older than S3_RETENTION_DAYS (default 7, mirroring the local
    # find -mtime +7 below). S3_RETENTION_DAYS=0 skips this block entirely, handing
    # retention to an S3 lifecycle policy on the bucket (see README) so the tool and
    # the lifecycle rule don't compete over the same objects.
    # S3 has no server-side age filter, so list the keys under the prefix and
    # compare the timestamp embedded in each backup's name against a cutoff built
    # the same way the names are (host-local time, like TIMESTAMP above). The name
    # layout mongo_backup_YYYY-MM-DD_HH-MM-SS.gz reduces to a fixed-width 14-digit
    # number once punctuation is stripped, so compare those as integers — a string
    # "<" would be locale-dependent (a non-C LC_COLLATE could reorder them and
    # prune the wrong keys), while an integer compare is deterministic.
    # `date +%s` is portable; formatting an epoch back differs by platform, so try
    # BSD's `-r` (macOS) first, then fall back to GNU's `-d @` (Linux). This is
    # best-effort: the dump already uploaded, so a transient S3 error warns rather
    # than failing the run. Needs s3:ListBucket + s3:DeleteObject (see README).
    stage "S3 prune"
    local cutoff_epoch cutoff_ts cutoff_digits s3_keys s3_key s3_name s3_ts s3_digits
    if [ "$S3_RETENTION_DAYS" -eq 0 ]; then
      echo "S3_RETENTION_DAYS=0 -> skipping S3 prune (lifecycle policy owns retention)."
    else
      cutoff_epoch=$(( $(date +%s) - S3_RETENTION_DAYS * 86400 ))
      cutoff_ts=$(date -r "$cutoff_epoch" +%Y-%m-%d_%H-%M-%S 2>/dev/null \
               || date -d "@$cutoff_epoch" +%Y-%m-%d_%H-%M-%S)
      cutoff_digits=${cutoff_ts//[^0-9]/}
      if s3_keys=$(aws s3api list-objects-v2 \
                     --bucket "$S3_BUCKET_NAME" --prefix "mongodb-backups/" \
                     --query 'Contents[].Key' --output text --profile "$AWS_PROFILE"); then
        while IFS= read -r s3_key; do
          [ -n "$s3_key" ] && [ "$s3_key" != "None" ] || continue
          s3_name=${s3_key##*/}
          case "$s3_name" in mongo_backup_*.gz) ;; *) continue ;; esac
          s3_ts=${s3_name#mongo_backup_}; s3_ts=${s3_ts%.gz}
          s3_digits=${s3_ts//[^0-9]/}
          # Require a full YYYYMMDDHHMMSS (14 digits): a glob-matching but
          # malformed key (e.g. mongo_backup_2026.gz) would otherwise reduce to a
          # tiny number that always sorts below the cutoff and gets deleted.
          [ "${#s3_digits}" -eq 14 ] || continue
          if [ "$s3_digits" -lt "$cutoff_digits" ]; then
            echo "Deleting old S3 backup: $s3_key"
            aws s3 rm "s3://${S3_BUCKET_NAME}/${s3_key}" --profile "$AWS_PROFILE" \
              || echo "Warning: failed to delete s3://${S3_BUCKET_NAME}/${s3_key}" >&2
          fi
        done <<< "$(printf '%s' "$s3_keys" | tr '\t' '\n')"
      else
        echo "Warning: could not list S3 objects for retention; skipping remote prune." >&2
      fi
    fi
  else
    echo "Skipping S3 upload because USE_REMOTE=false."
  fi

  # Cleanup old backups (keep last 7 days). Restrict to this tool's own
  # mongo_backup_*.gz names (matching the S3 prune) so an unrelated .gz a user
  # placed in the backups dir is never deleted.
  stage "local prune"
  find "$BACKUP_DIR" -type f -mtime +7 -name "mongo_backup_*.gz" \
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

  # Resolve the backup path independently of the caller's CWD, without ever
  # letting a typo silently select a *different* archive — mongorestore --drop
  # below would otherwise overwrite the target with the wrong data:
  #   * an existing path (absolute, or relative to CWD) is used as-is;
  #   * an absolute path that doesn't exist fails fast — no fallback;
  #   * a relative path with a directory part is re-anchored at SCRIPT_DIR,
  #     preserving its structure, so `restore backups_temp/foo.gz` works from any
  #     CWD (e.g. under cron/systemd where CWD is $HOME);
  #   * a bare filename is looked up in the script's own backup dirs — the form
  #     `download_backup` prints.
  if [ ! -e "$RESTORE_FILE" ]; then
    case "$RESTORE_FILE" in
      /*) : ;;                                             # absolute + missing -> fail fast
      */*) [ -e "${SCRIPT_DIR}/${RESTORE_FILE}" ] && RESTORE_FILE="${SCRIPT_DIR}/${RESTORE_FILE}" ;;
      *)  # Bare name: look in the local dumps dir and the S3-download dir. Prefer
          # backups/ (locally produced) over backups_temp/ (a download that may be
          # stale or partial), and refuse to guess when both hold the same name —
          # restore uses mongorestore --drop, so picking the wrong file is
          # destructive. Pass an explicit path to disambiguate.
          local in_backups="${BACKUP_DIR}/${RESTORE_FILE}" in_temp="${S3_BACKUP_DIR_TEMP}/${RESTORE_FILE}"
          if [ -e "$in_backups" ] && [ -e "$in_temp" ]; then
            echo "Error: '$RESTORE_FILE' exists in both $BACKUP_DIR and $S3_BACKUP_DIR_TEMP; pass an explicit path to choose one." >&2
            exit 1
          elif [ -e "$in_backups" ]; then RESTORE_FILE=$in_backups
          elif [ -e "$in_temp" ]; then RESTORE_FILE=$in_temp
          fi ;;
    esac
  fi

  if [ ! -e "$RESTORE_FILE" ]; then
    echo "Error: Backup file '$1' not found (looked relative to CWD; for a bare name, also in $S3_BACKUP_DIR_TEMP and $BACKUP_DIR)."
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

  # Update the stage off the "resolve container" value so a failure from here on
  # is attributed to the restore, not to the (already-succeeded) name resolution.
  stage "restore preflight"

  # Preflight: fail fast with a clear message if the configured credentials
  # can't reach the destination database, instead of failing partway through
  # mongorestore with a confusing "listCollections requires authentication".
  # Skipped when mongosh isn't available in the container.
  if docker exec "$CONTAINER_NAME" sh -c 'command -v mongosh >/dev/null 2>&1'; then
    echo "Preflight: checking auth against destination database '${TARGET_DB}'..."
    local PREFLIGHT_AUTH=()
    build_mongosh_auth_args PREFLIGHT_AUTH
    local PREFLIGHT_TLS=()
    build_mongosh_tls_args PREFLIGHT_TLS
    # JSON-encode the DB name into a JS string literal so a name containing a
    # quote or backslash can't build malformed --eval JS (see verify / json_str).
    local TARGET_DB_JS
    TARGET_DB_JS=$(json_str "$TARGET_DB")
    if docker exec "$CONTAINER_NAME" mongosh --quiet ${PREFLIGHT_AUTH[@]+"${PREFLIGHT_AUTH[@]}"} ${PREFLIGHT_TLS[@]+"${PREFLIGHT_TLS[@]}"} \
        --eval "quit((db.getSiblingDB(${TARGET_DB_JS}).runCommand({ listCollections: 1 }).ok === 1) ? 0 : 1)" >/dev/null 2>&1; then
      echo "Preflight auth check passed."
    else
      echo "Error: preflight auth check failed for database '${TARGET_DB}'."
      echo "The MongoDB user in .env needs readWrite (or at least listCollections) on '${TARGET_DB}'."
      exit 1
    fi
  else
    echo "Preflight: mongosh not found in container; skipping auth preflight."
  fi

  stage "copy archive to container"
  echo "Copying MongoDB backup file to the container..."
  docker cp "$RESTORE_FILE" "$CONTAINER_NAME:/tmp/$(basename "$RESTORE_FILE")"
  echo "Restoring MongoDB backup from $RESTORE_FILE..."
  stage "mongorestore"

  # Build args safely (NO sh -c)
  local AUTH_ARGS=()
  build_mongo_auth_args AUTH_ARGS
  local TLS_ARGS=()
  build_mongo_tls_args TLS_ARGS

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
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    ${TLS_ARGS[@]+"${TLS_ARGS[@]}"} \
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

  # Move off the "resolve container" stage so a verify failure isn't misattributed
  # to name resolution in the EXIT trap.
  stage "verify"

  echo "Verifying ${SRC_DB}.${SRC_COL} -> ${DST_DB}.${DST_COL}..."

  local AUTH_ARGS=()
  build_mongosh_auth_args AUTH_ARGS
  local TLS_ARGS=()
  build_mongosh_tls_args TLS_ARGS

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

  if docker exec "$CONTAINER_NAME" mongosh --quiet ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} ${TLS_ARGS[@]+"${TLS_ARGS[@]}"} --eval "$JS"; then
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

# Send a best-effort failure alert to Discord and/or Telegram.
# Usage: alert [systemd-unit]   (unit defaults to mongo-backup.service)
#
# Invoked by systemd's `OnFailure=mongo-backup-alert.service` when a scheduled
# backup exits non-zero. It reads the tail of the failed unit's journal — which
# carries the ">>> STAGE: ..." markers and the "Run FAILED during stage:" line —
# so the notification shows *which* stage died (mongodump vs S3 upload vs prune).
#
# Contract: best-effort and non-fatal. The real backup failure is already
# recorded by systemd; this only notifies, so it must never itself abort the
# OnFailure unit in a way that looks alarming. Each destination is attempted
# independently (one being down must not suppress the other) and the function
# always returns 0. Secret values (webhook URL, bot token) are never echoed, and
# curl output is discarded so a URL/token can't leak into the log/journal.
alert() {
  local unit="${1:-mongo-backup.service}"

  if [ "$USE_ALERTS" == "false" ]; then
    echo "Alerting disabled (USE_ALERTS=false); not sending a failure alert."
    return 0
  fi

  # Gather the failed run's output. Primary source is the on-disk run log that
  # every non-alert run mirrors via `tee` ($LOG_FILE): each run is bracketed by a
  # "Run started at …" header and, via the EXIT trap, a "Run FAILED during
  # stage: … / Run ended … (exit N)" trailer. Slicing from the LAST "Run started
  # at" to EOF yields exactly the run that just failed — no systemd-journal
  # coupling (no `--invocation` version gate, no post-exit InvocationID lookup, no
  # `systemd-journal` group / journal-read permission) and no bleed from a prior
  # successful run. Bounded to the last $lines lines here; the per-destination
  # char cap below keeps the *tail* so the "Run FAILED during stage" line survives.
  local lines="${ALERT_JOURNAL_LINES:-40}"
  local tail_text=""
  if [ -r "$LOG_FILE" ]; then
    # Trust the log only if THIS failure just wrote it — two signals, both required:
    #   (1) Freshness: the file was modified within ALERT_LOG_MAX_AGE_SECS (default
    #       300s) of now. A block the run could no longer append to (read-only /
    #       permission-broken / rotated-away log) keeps an OLD mtime — even when that
    #       stale block itself ended in an *earlier* "Run FAILED", so the marker
    #       alone (below) isn't enough to tell it apart from the current failure.
    #   (2) Marker: the last block carries "Run FAILED during stage: …", which the
    #       EXIT trap writes on every non-zero exit (a fresh but markerless block =
    #       a run killed before the trap, e.g. SIGKILL/OOM).
    # Either miss → discard and fall through to the journal, so the alert always
    # reports the current failed run, never a stale one.
    local max_age="${ALERT_LOG_MAX_AGE_SECS:-300}" now_epoch mtime_epoch
    now_epoch=$(date +%s 2>/dev/null || echo 0)
    mtime_epoch=$(stat -c %Y "$LOG_FILE" 2>/dev/null || stat -f %m "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$now_epoch" -gt 0 ] && [ "$mtime_epoch" -gt 0 ] && [ "$(( now_epoch - mtime_epoch ))" -le "$max_age" ]; then
      tail_text=$(awk '/^Run started at /{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' "$LOG_FILE" 2>/dev/null | tail -n "$lines")
      case "$tail_text" in
        *"Run FAILED during stage"*) : ;;   # fresh + the failed run's own block — use it
        *) tail_text="" ;;                    # fresh but markerless (killed pre-trap) — fall back
      esac
    fi
  fi
  # Fallback: if the run log is missing/empty/stale (e.g. a SIGKILL/OOM before the
  # run could write, an unwritable log, or a misconfigured path), fall back to a
  # plain journal tail so we still report the failed run rather than the wrong one.
  if [ -z "$tail_text" ] && command -v journalctl >/dev/null 2>&1; then
    tail_text=$(journalctl -u "$unit" -n "$lines" --no-pager -o cat 2>/dev/null || true)
  fi
  [ -n "$tail_text" ] || tail_text="(no run log at ${LOG_FILE} and no journal output for ${unit} — is the backup writing its log?)"

  local host when
  host=$(hostname 2>/dev/null || echo "unknown-host")
  when=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown-time")
  local title="🔴 MongoDB backup FAILED on ${host} at ${when} (systemd unit: ${unit})"

  local any_dest=0

  # --- Discord ---
  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    any_dest=1
    if command -v curl >/dev/null 2>&1; then
      # Discord caps message `content` at 2000 chars; keep the fenced journal
      # tail comfortably under that. Prefer jq to build the JSON (correct for any
      # bytes); fall back to the in-script escaper when jq isn't installed OR when
      # it errors (e.g. invalid UTF-8 in the journal tail, OOM). The jq call is in
      # the `if` condition so its failure short-circuits to the fallback instead of
      # aborting under `set -e` — this function must stay best-effort and reach its
      # `return 0`, or the OnFailure notifier would itself fail noisily.
      local dmsg payload dtail
      # Keep the TAIL of the journal excerpt (the "Run FAILED during stage: …"
      # line is always last), leaving room for the title + code fences, so a
      # verbose late-stage failure isn't truncated down to just its progress
      # output. Discord caps `content` at 2000; stay under 1900.
      local dbudget=$(( 1900 - ${#title} - 12 ))
      # Only tail when the budget is positive: `${dtail: -0}` would return the
      # WHOLE excerpt (offset 0), which the head-clamp below could then chop,
      # dropping the failure line. A non-positive budget (pathologically long
      # title) → title-only alert instead.
      dtail=""
      if [ "$dbudget" -gt 0 ]; then
        dtail=$tail_text
        [ "${#dtail}" -gt "$dbudget" ] && dtail=${dtail: -dbudget}
      fi
      # shellcheck disable=SC2016  # single quotes are intentional: this is a printf FORMAT string — %s are consumed by printf and the backticks must stay literal (double quotes would command-substitute them)
      dmsg=$(printf '%s\n```\n%s\n```' "$title" "$dtail")
      dmsg=${dmsg:0:1900}
      if command -v jq >/dev/null 2>&1 && payload=$(printf '%s' "$dmsg" | jq -Rs '{content: .}' 2>/dev/null); then
        : # payload built by jq
      else
        payload=$(printf '{"content":"%s"}' "$(json_escape_body "$dmsg")")
      fi
      # Pass the webhook URL via a curl config on stdin (-K -) instead of as an
      # argv argument, so the secret can't be read from `ps`/`/proc` on a
      # multi-user host for the curl process's lifetime. The -d payload is just
      # the journal tail (not secret) so it stays on argv. Output is discarded so
      # nothing leaks into the log. -f fails on HTTP errors, -m bounds the hang.
      # Strip any CR/LF from the URL first: a newline would let a crafted or
      # fat-fingered value inject extra directives into the single-line curl
      # config (the .env loader strips CR, but a multi-line quoted value or an
      # env-provided one could still carry a newline).
      local hook_url="${DISCORD_WEBHOOK_URL//$'\r'/}"; hook_url="${hook_url//$'\n'/}"
      if printf 'url = %s\n' "$hook_url" \
         | curl -fsS -m 15 -K - -X POST -H "Content-Type: application/json" \
           -d "$payload" >/dev/null 2>&1; then
        echo "Failure alert sent to Discord."
      else
        echo "Warning: Discord alert failed to send." >&2
      fi
    else
      echo "Warning: curl not found; cannot send Discord alert." >&2
    fi
  fi

  # --- Telegram ---
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    any_dest=1
    if command -v curl >/dev/null 2>&1; then
      # Telegram caps `text` at 4096 chars. --data-urlencode lets curl handle all
      # escaping, so no JSON building is needed. The bot token is a secret (it's
      # embedded in the API URL), so pass the URL via a curl config on stdin
      # (-K -) rather than as an argv argument — otherwise the token would be
      # visible in `ps`/`/proc` on a multi-user host. chat_id is an identifier,
      # not a credential, so it's fine on argv. curl output is discarded.
      local tmsg ttail
      # Keep the TAIL of the journal excerpt (same rationale as Discord), leaving
      # room for the title. Telegram caps `text` at 4096; stay under 3900.
      local tbudget=$(( 3900 - ${#title} - 6 ))
      # Same positive-budget guard as Discord (avoid the `${ttail: -0}` whole-string trap).
      ttail=""
      if [ "$tbudget" -gt 0 ]; then
        ttail=$tail_text
        [ "${#ttail}" -gt "$tbudget" ] && ttail=${ttail: -tbudget}
      fi
      tmsg=$(printf '%s\n\n%s' "$title" "$ttail")
      tmsg=${tmsg:0:3900}
      # Strip CR/LF from the token before interpolating it into the single-line
      # curl config, so a stray newline can't inject extra curl directives (same
      # reasoning as the Discord webhook URL above).
      local bot_token="${TELEGRAM_BOT_TOKEN//$'\r'/}"; bot_token="${bot_token//$'\n'/}"
      if printf 'url = https://api.telegram.org/bot%s/sendMessage\n' "$bot_token" \
         | curl -fsS -m 15 -K - -X POST \
           --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
           --data-urlencode "text=${tmsg}" >/dev/null 2>&1; then
        echo "Failure alert sent to Telegram."
      else
        echo "Warning: Telegram alert failed to send." >&2
      fi
    else
      echo "Warning: curl not found; cannot send Telegram alert." >&2
    fi
  fi

  if [ "$any_dest" -eq 0 ]; then
    echo "Warning: USE_ALERTS=true but no alert destination is configured; nothing sent." >&2
    echo "         Set DISCORD_WEBHOOK_URL and/or TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID in .env." >&2
  fi

  # Always succeed: alerting is best-effort and must not turn a send hiccup into
  # a scary secondary failure on top of the backup failure it's reporting.
  return 0
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
  echo "  alert [unit]           Send a best-effort failure alert (Discord/Telegram) with the"
  echo "                         tail of [unit]'s journal (default mongo-backup.service)."
  echo "                         Meant for systemd OnFailure=, not day-to-day use."
  echo "  help                   Display this help message."
  echo
  echo "Environment Flags:"
  echo "  USE_CREDENTIALS=false  Skip MongoDB username/password when dumping/restoring."
  echo "  USE_REMOTE=false       Skip all S3 uploads/downloads/list operations."
  echo "  USE_ALERTS=true        Enable failure alerting (needs DISCORD_WEBHOOK_URL and/or"
  echo "                         TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID)."
  echo
  echo "  CONTAINER_NAME may be an exact container name or a stable prefix (e.g."
  echo "  sodax-stateful-mongo); it's resolved at run time to the single running match."
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
    # Resolve CONTAINER_NAME (exact name or stable prefix) to the single running
    # container once here, so the whole backup shares the resolved name even
    # after a Coolify redeploy regenerated the container's suffix.
    resolve_container
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
    resolve_container
    shift
    restore "$@"
    ;;
  verify)
    health_check
    resolve_container
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
  alert)
    # Failure-notification path, normally invoked by mongo-backup-alert.service's
    # OnFailure hook. Deliberately does NOT run health_check or resolve_container:
    # it fires precisely when the backup broke (maybe because the container is
    # gone), so it must stay independent of Mongo/Docker/S3 config and only needs
    # the alert secrets. Optional arg: the systemd unit whose journal to tail.
    if [ "$#" -gt 2 ]; then
      echo "Error: too many arguments for alert. Pass at most one systemd unit name."
      exit 1
    fi
    alert "${2:-}"
    ;;
  help|-h|--help)
    help
    ;;
  *)
    echo "Usage: $0 {backup|restore|verify|list_backups_s3|list_backups_local|download_backup|alert|help} [args]"
    exit 1
    ;;
esac
