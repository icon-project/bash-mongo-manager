#!/usr/bin/env bash
set -euo pipefail

# setup_schedule.sh — one command to automate `mongo_backup_manager.sh backup`.
#
# Installs a scheduler for you and fills in every detail automatically — the
# script path, the run user, and a bash 4.3+ interpreter. No editing unit files
# by hand. It picks the right mechanism for your OS:
#   • Linux  → a systemd timer + service (installed to /etc/systemd/system, sudo)
#   • macOS  → a launchd agent (~/Library/LaunchAgents, no sudo)
#
# Usage — run it from wherever this repo lives; it schedules THAT copy in place:
#   ./setup_schedule.sh            # daily at 03:00 (default)
#   ./setup_schedule.sh hourly     # every hour, on the hour
#   ./setup_schedule.sh 02:30      # daily at 02:30 (24h HH:MM)
#   ./setup_schedule.sh status     # is it scheduled? when did it last run?
#   ./setup_schedule.sh uninstall  # remove the scheduler
#
# Prereqs: docker + aws (+ mongosh for verify) installed, and a .env beside the
# script. On Linux the run user must be able to reach Docker and own the AWS
# profile named in .env. On macOS a laptop only runs the job while logged in;
# if it's asleep at the scheduled time, launchd runs it shortly after it wakes.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TARGET="${SCRIPT_DIR}/mongo_backup_manager.sh"
LABEL="com.mongo-backup"          # launchd label
UNIT="mongo-backup"               # systemd unit basename
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

die() { echo "Error: $*" >&2; exit 1; }

# Escape a path/value for a systemd setting that is parsed with command-line
# quoting rules (ExecStart=, Environment=). These split on unquoted whitespace
# and treat '%' as a specifier — so a checkout path with a space (or '%', '"',
# '\') would break the generated unit. Double any '%', then wrap in double
# quotes with backslashes/quotes escaped so the value survives both specifier
# expansion and command-line splitting.
systemd_escape_path() {
  local s=$1
  s=${s//%/%%}       # literal percent -> escaped specifier
  s=${s//\\/\\\\}    # backslash -> escaped backslash
  s=${s//\"/\\\"}    # double quote -> escaped quote
  printf '"%s"' "$s"
}

# Escape a value for a systemd setting parsed as a single literal path
# (WorkingDirectory=). These are NOT command-line-unquoted, so a quoted value
# like "/path" is read verbatim and rejected as non-absolute — internal spaces
# are already fine unquoted, and only '%' (a specifier) needs doubling.
systemd_escape_specifier() {
  printf '%s' "${1//%/%%}"
}

[ -f "$TARGET" ] || die "mongo_backup_manager.sh not found next to this installer ($TARGET)."

# Pick a bash >= 4.3 to run the backup with. macOS ships 3.2 as /bin/bash, where
# the backup script's namerefs and `source <(...)` break — so we hunt for a newer
# one (Homebrew's, usually) and pin the scheduler to it explicitly.
find_bash() {
  local b
  for b in "$(command -v bash || true)" /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    [ -n "$b" ] && [ -x "$b" ] || continue
    if "$b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }' 2>/dev/null; then
      printf '%s\n' "$b"; return 0
    fi
  done
  return 1
}

ARG="${1:-daily}"
OS="$(uname -s)"

# ---------- status / uninstall (handled before we need a schedule) -----------
case "$ARG" in
  status)
    if [ "$OS" = "Darwin" ]; then
      launchctl list 2>/dev/null | grep -q "$LABEL" \
        && echo "Scheduled (launchd agent $LABEL). Logs: ${SCRIPT_DIR}/logs/launchd.*.log" \
        || echo "Not scheduled."
    else
      systemctl list-timers "${UNIT}.timer" 2>/dev/null || echo "Not scheduled."
    fi
    exit 0 ;;
  uninstall)
    if [ "$OS" = "Darwin" ]; then
      launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
      rm -f "$PLIST" && echo "Removed launchd agent ${LABEL}."
    else
      sudo systemctl disable --now "${UNIT}.timer" 2>/dev/null || true
      sudo rm -f "/etc/systemd/system/${UNIT}.timer" "/etc/systemd/system/${UNIT}.service"
      sudo systemctl daemon-reload
      echo "Removed systemd unit ${UNIT}."
    fi
    exit 0 ;;
esac

# ---------- parse the schedule argument --------------------------------------
SCHED_HOUR=3; SCHED_MIN=0; HOURLY=0
case "$ARG" in
  daily) ;;
  hourly) HOURLY=1 ;;
  [0-2][0-9]:[0-5][0-9])
    # 10# forces base-10 so a leading zero isn't parsed as octal.
    SCHED_HOUR=$((10#${ARG%%:*})); SCHED_MIN=$((10#${ARG##*:}))
    [ "$SCHED_HOUR" -le 23 ] || die "hour out of range in '$ARG' (use 00:00–23:59)." ;;
  *) die "unknown argument '$ARG' — use: daily | hourly | HH:MM | status | uninstall" ;;
esac

BASH_BIN="$(find_bash)" || die "need bash >= 4.3 to run backups. On macOS: 'brew install bash'."
echo "Backup script : $TARGET"
echo "Interpreter   : $BASH_BIN ($("$BASH_BIN" -c 'echo "$BASH_VERSION"'))"
[ -f "${SCRIPT_DIR}/.env" ] || echo "Warning: no .env beside the script yet — create it before the first run."
mkdir -p "${SCRIPT_DIR}/logs"

# ================= macOS: launchd agent ======================================
if [ "$OS" = "Darwin" ]; then
  if [ "$HOURLY" -eq 1 ]; then
    CAL="    <key>Minute</key><integer>0</integer>"          # every hour at :00
  else
    CAL="    <key>Hour</key><integer>${SCHED_HOUR}</integer>
    <key>Minute</key><integer>${SCHED_MIN}</integer>"
  fi
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BASH_BIN}</string>
    <string>${TARGET}</string>
    <string>backup</string>
  </array>
  <key>WorkingDirectory</key><string>${SCRIPT_DIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(dirname "$BASH_BIN"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
${CAL}
  </dict>
  <key>StandardOutPath</key><string>${SCRIPT_DIR}/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>${SCRIPT_DIR}/logs/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$PLIST" >/dev/null || die "generated plist failed validation ($PLIST)."
  uid="$(id -u)"
  launchctl bootout "gui/${uid}/${LABEL}" 2>/dev/null || true   # reload if already present
  launchctl bootstrap "gui/${uid}" "$PLIST"
  launchctl enable "gui/${uid}/${LABEL}" 2>/dev/null || true
  echo
  echo "✅ Scheduled via launchd — $( [ "$HOURLY" -eq 1 ] && echo 'every hour' || printf 'daily at %02d:%02d' "$SCHED_HOUR" "$SCHED_MIN")."
  echo "   run now : launchctl start ${LABEL}"
  echo "   output  : ${SCRIPT_DIR}/logs/launchd.{out,err}.log (and logs/mongo_backup_manager.log)"
  echo "   status  : ./setup_schedule.sh status"
  echo "   remove  : ./setup_schedule.sh uninstall"
  exit 0
fi

# ================= Linux: systemd timer ======================================
if [ "$HOURLY" -eq 1 ]; then
  ONCAL="hourly"
else
  ONCAL="$(printf '*-*-* %02d:%02d:00' "$SCHED_HOUR" "$SCHED_MIN")"
fi
RUN_USER="$(id -un)"; RUN_GROUP="$(id -gn)"
BASH_DIR="$(dirname "$BASH_BIN")"

# Quote/escape every path-bearing unit value so spaces or specifiers in the
# checkout path (SCRIPT_DIR/TARGET/BASH_BIN) don't corrupt the generated unit.
SVC_WORKDIR="$(systemd_escape_specifier "$SCRIPT_DIR")"
SVC_EXECSTART="$(systemd_escape_path "$BASH_BIN") $(systemd_escape_path "$TARGET") backup"
SVC_ENV_PATH="$(systemd_escape_path "PATH=${BASH_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")"

SVC_TMP="$(mktemp)"; TMR_TMP="$(mktemp)"
cat > "$SVC_TMP" <<SVC_EOF
[Unit]
Description=MongoDB backup via mongo_backup_manager.sh
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${SVC_WORKDIR}
ExecStart=${SVC_EXECSTART}
Environment=${SVC_ENV_PATH}
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=1h
SVC_EOF

cat > "$TMR_TMP" <<TMR_EOF
[Unit]
Description=Schedule MongoDB backup (${UNIT}.service)

[Timer]
OnCalendar=${ONCAL}
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
TMR_EOF

echo "Installing systemd unit '${UNIT}' (needs sudo)…"
sudo cp "$SVC_TMP" "/etc/systemd/system/${UNIT}.service"
sudo cp "$TMR_TMP" "/etc/systemd/system/${UNIT}.timer"
rm -f "$SVC_TMP" "$TMR_TMP"
sudo systemctl daemon-reload
sudo systemctl enable --now "${UNIT}.timer"
echo
echo "✅ Scheduled via systemd — OnCalendar=${ONCAL}, running as ${RUN_USER}."
echo "   run now : sudo systemctl start ${UNIT}.service"
echo "   output  : journalctl -u ${UNIT}.service -e"
echo "   status  : ./setup_schedule.sh status"
echo "   remove  : ./setup_schedule.sh uninstall"
