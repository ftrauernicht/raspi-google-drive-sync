#!/bin/bash
# Daily sync: pull Google Drive (read-only) down onto the local mergerfs
# pool, via `rclone copy` — never `rclone sync` — so nothing is ever
# deleted from the backup even if it's deleted from Drive. See
# docs/architecture.md for the full design rationale and the real bugs
# found and fixed while testing this script against actual hardware
# failures.
set -euo pipefail

# --- Configuration ---
POOL=/mnt/backup
DISK1_MARKER=/mnt/disk1/.disk1-online
DISK2_MARKER=/mnt/disk2/.disk2-online
DRIVE_TARGET="$POOL/drive"
TAKEOUT_DIR="$DRIVE_TARGET/Takeout"
LOG_DIR="$POOL/logs"
LOG_FILE="$LOG_DIR/drive-backup.log"
RECIPIENTS_FILE=/etc/drive-backup/recipients.txt
STATE_DIR=/etc/drive-backup/state
WARN_85_MARKER="$STATE_DIR/.warned-85"
WARN_95_MARKER="$STATE_DIR/.warned-95"
PHOTO_STALE_DAYS=75
TAKEOUT_KEEP=2
HEALTHCHECK_URL_FILE=/etc/drive-backup/healthcheck-url

# Test hooks (override via environment variable; defaults = normal operation).
# Overriding these lets every branch of this script be exercised safely
# against real hardware without waiting for a real failure or triggering a
# multi-day real transfer — see docs/architecture.md for the test approach.
WARN_85=${WARN_85:-85}
WARN_95=${WARN_95:-95}
EXTRA_RCLONE_FLAGS=${EXTRA_RCLONE_FLAGS:-}

# Stall watchdog: rclone gets killed if it shows no real byte progress for
# STALL_MINUTES — deliberately NOT a fixed total-duration timeout, so a
# legitimately long initial sync (which can take days on a slow LAN/CPU)
# never gets killed just for taking a while. Background: in testing, rclone
# hung indefinitely (8+ minutes and counting, never recovering on its own)
# when the destination disk failed mid-write — rclone's own --timeout flag
# only covers network/source stalls, not local write failures at the
# destination.
STALL_MINUTES=${STALL_MINUTES:-30}
STALL_CHECK_INTERVAL=${STALL_CHECK_INTERVAL:-60}

# Automatic reboot on mount problems: after the backup drives are unplugged
# and replugged (or lose power briefly), the pool does NOT recover on its
# own — a replugged drive can come back under a new device name (e.g. sdc
# instead of sdb), leaving the old mounts stale. A reboot reliably fixes
# this. Goal: as little manual intervention as possible — only ask a human
# to check the hardware after an automatic reboot attempt has already
# failed to fix it, not on the first occurrence.
REBOOT_MARKER="$STATE_DIR/.auto-reboot-attempted"
REBOOT_COOLDOWN_HOURS=${REBOOT_COOLDOWN_HOURS:-6}
AUTO_REBOOT_ENABLED=${AUTO_REBOOT_ENABLED:-1}
REBOOT_CMD=${REBOOT_CMD:-reboot}

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() {
  # "|| true": if the log file can't be written (e.g. because the backup
  # drives it lives on have just failed — exactly the case we most need to
  # report), `tee` returns a non-zero exit code. Without "|| true", "set -e"
  # would abort the whole script right at this log line, before the actual
  # error handling below ever runs. Found empirically while testing the
  # stall watchdog against a real mid-sync drive failure.
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || true
}

send_mail() {
  local subject="$1"
  local body="$2"
  local msgid
  msgid="<$(date +%s%N).drive-backup@$(hostname)>"
  if [ ! -f "$RECIPIENTS_FILE" ]; then
    log "WARNING: recipients file $RECIPIENTS_FILE is missing, mail not sent: $subject"
    return
  fi
  while IFS= read -r recipient; do
    [ -z "$recipient" ] && continue
    {
      printf 'Subject: %s\n' "$subject"
      printf 'To: %s\n' "$recipient"
      printf 'Date: %s\n' "$(date -R)"
      printf 'Message-ID: %s\n' "$msgid"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf '\n%s\n' "$body"
    } | msmtp "$recipient" || log "WARNING: sending mail to $recipient failed"
  done < "$RECIPIENTS_FILE"
}

fail() {
  log "ERROR: $1"
  send_mail "[drive-backup] Error: $1" "$2"
  exit 1
}

# For mount problems specifically: instead of immediately asking for manual
# intervention, try ONE automatic reboot first (proven to reliably fix the
# known failure mode). Guarded by a cooldown marker so a persistent real
# hardware fault doesn't cause an endless reboot loop.
mount_fail() {
  local reason="$1"
  local details="$2"

  if [ "$AUTO_REBOOT_ENABLED" -eq 1 ] && [ -f "$REBOOT_MARKER" ]; then
    local last_epoch now_epoch hours_since
    last_epoch=$(stat -c %Y "$REBOOT_MARKER" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    hours_since=$(( (now_epoch - last_epoch) / 3600 ))
    if [ "$hours_since" -lt "$REBOOT_COOLDOWN_HOURS" ]; then
      fail "$reason (automatic reboot ${hours_since}h ago didn't help)" "$details

An automatic reboot was already attempted about ${hours_since} hour(s) ago but didn't fix the problem. That points to a real hardware/cabling issue rather than a transient stale-mount state. Please check the dock, cables, and power supply in person."
    fi
  fi

  if [ "$AUTO_REBOOT_ENABLED" -eq 1 ]; then
    log "ERROR: $reason - attempting an automatic reboot to recover"
    touch "$REBOOT_MARKER"
    send_mail "[drive-backup] Automatic reboot to recover" "$reason

$details

This device is now rebooting itself automatically — testing has shown this reliably fixes exactly this failure mode. If the problem persists after the reboot, you'll get a follow-up mail asking you to check it in person."
    # shellcheck disable=SC2086
    $REBOOT_CMD
    exit 0
  else
    fail "$reason" "$details"
  fi
}

log "=== Sync run started ==="

# 1. Mount check
if ! mountpoint -q "$POOL"; then
  mount_fail "Backup pool not mounted" "The backup storage at $POOL is not reachable. Possible cause: the docking station briefly lost power or its connection. If the automatic reboot doesn't fix it:
1. Check that the docking station has power.
2. Check that the USB cable to the device is properly seated.
3. Log in via SSH and run 'mount -a'.
4. If that doesn't help, investigate the hardware."
fi

if [ ! -f "$DISK1_MARKER" ] || [ ! -f "$DISK2_MARKER" ]; then
  mount_fail "A backup drive is missing" "At least one of the two backup drives is currently unreachable. If the automatic reboot doesn't fix it:
1. Check that both drives are firmly seated in the docking station.
2. Check that the docking station's power supply is connected.
3. Log in via SSH and run 'lsblk' - two drives must show up."
fi

log "Mount check OK (pool + both marker files present)"

# healthchecks.io "/start" signal: pauses their lateness detection for the
# duration of this run — important for the multi-day initial sync, or any
# unusually long day-to-day run. Without this, a legitimately long (but
# healthy) run would trigger a false dead-man alarm once the grace period
# elapses.
if [ -f "$HEALTHCHECK_URL_FILE" ]; then
  HC_URL=$(cat "$HEALTHCHECK_URL_FILE")
  curl -fsS -m 10 --retry 3 "$HC_URL/start" >/dev/null 2>&1 || log "WARNING: dead-man-switch start signal failed"
fi
rm -f "$REBOOT_MARKER"

# 2. Gather status
DRIVE_ABOUT=$(rclone about gdrive: 2>&1) || DRIVE_ABOUT="(rclone about failed)"
POOL_USAGE=$(df --output=pcent "$POOL" | tail -1 | tr -d ' %')
POOL_DF=$(df -h "$POOL" | tail -1)
LATEST_TAKEOUT=""
if [ -d "$TAKEOUT_DIR" ]; then
  LATEST_TAKEOUT=$(find "$TAKEOUT_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
fi

STATUS_BLOCK="Google Drive:
$DRIVE_ABOUT

Backup pool: $POOL_DF
Latest Google Photos export: ${LATEST_TAKEOUT:-none found yet}"

log "Status gathered: pool usage ${POOL_USAGE}%"

# 3. Space check (thresholds overridable via WARN_85/WARN_95, see above)
if [ "$POOL_USAGE" -ge "$WARN_95" ]; then
  if [ ! -f "$WARN_95_MARKER" ]; then
    send_mail "[drive-backup] CRITICAL: storage ${POOL_USAGE}% full" "The backup storage is ${POOL_USAGE}% full. The sync keeps running regardless, until the disks are truly full. How to fix this:
1. Buy a new SATA drive (at least 4 TB).
2. Copy the contents of one of the current drives onto the new one from a PC.
3. Swap that drive in the docking station for the new one.

$STATUS_BLOCK"
    touch "$WARN_95_MARKER"
  fi
elif [ "$POOL_USAGE" -ge "$WARN_85" ]; then
  if [ ! -f "$WARN_85_MARKER" ]; then
    send_mail "[drive-backup] Warning: storage ${POOL_USAGE}% full" "The backup storage is ${POOL_USAGE}% full. How to fix this:
1. Buy a new SATA drive (at least 4 TB).
2. Copy the contents of one of the current drives onto the new one from a PC.
3. Swap that drive in the docking station for the new one.

$STATUS_BLOCK"
    touch "$WARN_85_MARKER"
  fi
  rm -f "$WARN_95_MARKER"
else
  rm -f "$WARN_85_MARKER" "$WARN_95_MARKER"
fi

# 4. Photo-freshness check
NEEDS_PHOTO_REMINDER=0
PHOTO_REASON=""
if [ -z "$LATEST_TAKEOUT" ]; then
  NEEDS_PHOTO_REMINDER=1
  PHOTO_REASON="No Google Photos export (Takeout) has ever been found in the backup."
else
  LATEST_EPOCH=$(stat -c %Y "$LATEST_TAKEOUT")
  NOW_EPOCH=$(date +%s)
  AGE_DAYS=$(( (NOW_EPOCH - LATEST_EPOCH) / 86400 ))
  if [ "$AGE_DAYS" -ge "$PHOTO_STALE_DAYS" ]; then
    NEEDS_PHOTO_REMINDER=1
    PHOTO_REASON="The latest Google Photos export is $AGE_DAYS days old (threshold: $PHOTO_STALE_DAYS days)."
  fi
fi
if [ "$NEEDS_PHOTO_REMINDER" -eq 1 ]; then
  send_mail "[drive-backup] Reminder: Google Photos backup is stale" "$PHOTO_REASON How to set up a new export:
1. Open takeout.google.com.
2. Select only \"Google Photos\".
3. Destination \"Add to Drive\", frequency \"Every 2 months for 1 year\".

$STATUS_BLOCK"
fi

# 5. Sync (with the stall watchdog, via rclone's --rc live-stats interface)
RC_ADDR=127.0.0.1:5572
log "Starting rclone copy (EXTRA_RCLONE_FLAGS='$EXTRA_RCLONE_FLAGS', stall limit ${STALL_MINUTES}min)..."
# shellcheck disable=SC2086
rclone copy gdrive: "$DRIVE_TARGET" \
    --transfers 2 --checkers 4 \
    --drive-export-formats docx,xlsx,pptx \
    --log-file "$LOG_FILE" --log-level INFO \
    --rc --rc-addr "$RC_ADDR" --rc-no-auth \
    $EXTRA_RCLONE_FLAGS &
RCLONE_PID=$!

STALL_SECONDS=$(( STALL_MINUTES * 60 ))
LAST_BYTES=-1
STALLED_FOR=0
WAS_KILLED_FOR_STALL=0
while kill -0 "$RCLONE_PID" 2>/dev/null; do
  sleep "$STALL_CHECK_INTERVAL"
  # Real byte progress, not log-file size — a single large file only logs
  # on completion, which would otherwise misclassify a legitimately long
  # transfer as "stalled".
  CURRENT_BYTES=$(curl -s -m 5 -X POST -d '{}' "http://$RC_ADDR/core/stats" 2>/dev/null | grep -o '"bytes": *[0-9]*' | head -1 | grep -o '[0-9]*' || true)
  CURRENT_BYTES=${CURRENT_BYTES:-$LAST_BYTES}
  if [ "$CURRENT_BYTES" = "$LAST_BYTES" ]; then
    STALLED_FOR=$(( STALLED_FOR + STALL_CHECK_INTERVAL ))
  else
    STALLED_FOR=0
  fi
  LAST_BYTES="$CURRENT_BYTES"
  if [ "$STALLED_FOR" -ge "$STALL_SECONDS" ]; then
    log "WARNING: rclone has shown no byte progress for ${STALL_MINUTES} minutes - killing PID $RCLONE_PID"
    kill -9 "$RCLONE_PID" 2>/dev/null || true
    WAS_KILLED_FOR_STALL=1
    break
  fi
done

if wait "$RCLONE_PID"; then
  log "Sync successful"
elif [ "$WAS_KILLED_FOR_STALL" -eq 1 ]; then
  fail "rclone sync got stuck (no progress for ${STALL_MINUTES} min.)" "The Google Drive sync showed no progress for ${STALL_MINUTES} minutes and was aborted - typically because a backup drive failed mid-write. How to fix this:
1. Check the log excerpt: $LOG_FILE
2. Check that both drives are still firmly seated in the dock and powered.
3. Log in via SSH and run 'lsblk' - both drives must show up.
4. If a drive got a new device name (e.g. sdc instead of sdb): rebooting reliably fixes this.

$STATUS_BLOCK"
else
  fail "rclone sync failed" "The Google Drive sync failed. How to fix this:
1. Check the log excerpt: $LOG_FILE
2. If it mentions 'invalid_grant' or 'token expired': re-authorize rclone's Google access (see docs/setup-guide.md).
3. Check the device's internet connection.

$STATUS_BLOCK"
fi

# 6. Takeout cleanup rule (the one deliberate exception to "never delete" —
# without it, a full photo-library export every 2 months would eventually
# fill the pool)
if [ -d "$TAKEOUT_DIR" ]; then
  # Via a temp file rather than "mapfile < <(...)" - the process-substitution
  # form isn't wrong per se (the real bug turned out to be the variable name
  # below, not this), but a temp file avoids subshell-scoping surprises in
  # general and is easy to reason about.
  TAKEOUT_GROUPS_TMP=$(mktemp)
  # Google Takeout groups files as "takeout-<date>T<time>Z-<part>.zip"; a
  # failed first attempt can produce a second batch a few seconds later
  # (e.g. "...T172606Z-001.zip" vs "...T172607Z-2-001.zip") that's really
  # the same logical export. Group by calendar day, not exact timestamp, so
  # such retries count as one export rather than two.
  find "$TAKEOUT_DIR" -maxdepth 1 -type f -name 'takeout-*' -printf '%f\n' 2>/dev/null \
    | sed -E 's/^takeout-([0-9]{8})T[0-9]{6}Z-.*/\1/' | sort -u > "$TAKEOUT_GROUPS_TMP"
  # IMPORTANT: the array must NOT be named "GROUPS" — that's a bash special
  # variable (the shell's own group-ID list), and assigning to it (even via
  # `mapfile -t GROUPS`) silently fails with exit code 1 while leaving the
  # array unchanged, i.e. NOT populated with this script's data at all. An
  # earlier version of this script used that name, misdiagnosed the exit
  # code as a generic Bash 5.2 `mapfile` quirk, and papered over it with
  # `|| true` — which silenced the symptom but left the underlying group
  # data wrong. Found via `tests/test_takeout_grouping.sh`; always use a
  # non-reserved array name here.
  mapfile -t TAKEOUT_GROUPS < "$TAKEOUT_GROUPS_TMP"
  rm -f "$TAKEOUT_GROUPS_TMP"
  TAKEOUT_GROUP_COUNT=${#TAKEOUT_GROUPS[@]}
  if [ "$TAKEOUT_GROUP_COUNT" -gt "$TAKEOUT_KEEP" ]; then
    KEEP_FROM=$(( TAKEOUT_GROUP_COUNT - TAKEOUT_KEEP ))
    for ((i=0; i<KEEP_FROM; i++)); do
      g="${TAKEOUT_GROUPS[$i]}"
      log "Deleting old Takeout archives for $g"
      find "$TAKEOUT_DIR" -maxdepth 1 -type f -name "takeout-${g}T*" -delete
    done
  fi
fi

# 7. Result
log "=== Sync run finished successfully ==="
if [ -f "$HEALTHCHECK_URL_FILE" ]; then
  HC_URL=$(cat "$HEALTHCHECK_URL_FILE")
  curl -fsS -m 10 --retry 3 "$HC_URL" >/dev/null 2>&1 || log "WARNING: dead-man-switch ping failed"
else
  log "Note: no healthchecks.io URL configured ($HEALTHCHECK_URL_FILE missing) - dead-man switch not active yet"
fi
