#!/bin/bash
# Tests the auto-reboot cooldown arithmetic used in scripts/drive-backup.sh's
# mount_fail() function: given a marker file's age, does it correctly decide
# "attempt another reboot" vs. "cooldown still active, ask a human instead"?
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

# Mirrors the hours-since calculation in scripts/drive-backup.sh's
# mount_fail(). Takes a marker epoch and "now" epoch (both injectable, so
# this is testable without waiting real hours or touching the wall clock).
hours_since() {
  local marker_epoch="$1" now_epoch="$2"
  echo $(( (now_epoch - marker_epoch) / 3600 ))
}

NOW=1785100000

# Marker from 30 minutes ago: well within any reasonable cooldown, must NOT
# be old enough to allow a new reboot attempt.
MARKER_30MIN_AGO=$(( NOW - 30*60 ))
HOURS=$(hours_since "$MARKER_30MIN_AGO" "$NOW")
COOLDOWN=6
assert_eq "$([ "$HOURS" -lt "$COOLDOWN" ] && echo yes || echo no)" "yes" "a marker 30 minutes old is still within a 6h cooldown"

# Marker from exactly 6 hours ago with a 6h cooldown: cooldown has elapsed,
# a new attempt is allowed (matches the script's "-lt" comparison, i.e. the
# boundary itself is NOT considered "still cooling down").
MARKER_6H_AGO=$(( NOW - 6*3600 ))
HOURS2=$(hours_since "$MARKER_6H_AGO" "$NOW")
assert_eq "$([ "$HOURS2" -lt "$COOLDOWN" ] && echo yes || echo no)" "no" "a marker exactly 6h old has cleared a 6h cooldown"

# Marker from 10 hours ago with a 6h cooldown: definitely cleared.
MARKER_10H_AGO=$(( NOW - 10*3600 ))
HOURS3=$(hours_since "$MARKER_10H_AGO" "$NOW")
assert_eq "$([ "$HOURS3" -lt "$COOLDOWN" ] && echo yes || echo no)" "no" "a marker 10h old has cleared a 6h cooldown"

# No marker file at all (epoch defaults to 0, as in the real script's
# `stat ... || echo 0` fallback): must never be mistaken for "just rebooted".
HOURS4=$(hours_since 0 "$NOW")
assert_eq "$([ "$HOURS4" -lt "$COOLDOWN" ] && echo yes || echo no)" "no" "a missing marker (epoch 0) is treated as long expired, not as a recent reboot"

assert_summary
