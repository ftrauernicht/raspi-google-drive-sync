#!/bin/bash
# Tests the stall-detection accounting used in scripts/drive-backup.sh's
# watchdog loop: given a sequence of observed byte/check counts, does the
# STALLED_FOR counter correctly reset on progress and correctly accumulate
# (and eventually trip) when NEITHER count changes?
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

# Mirrors the accounting in scripts/drive-backup.sh's watchdog loop body.
step() {
  local current_bytes="$1"
  local current_checks="$2"
  CURRENT_BYTES=${current_bytes:-$LAST_BYTES}
  CURRENT_CHECKS=${current_checks:-$LAST_CHECKS}
  if [ "$CURRENT_BYTES" = "$LAST_BYTES" ] && [ "$CURRENT_CHECKS" = "$LAST_CHECKS" ]; then
    STALLED_FOR=$(( STALLED_FOR + STALL_CHECK_INTERVAL ))
  else
    STALLED_FOR=0
  fi
  LAST_BYTES="$CURRENT_BYTES"
  LAST_CHECKS="$CURRENT_CHECKS"
}

STALL_CHECK_INTERVAL=60
STALL_MINUTES=3
STALL_SECONDS=$(( STALL_MINUTES * 60 ))

# A real, progressing transfer: bytes keep growing, must never trip.
LAST_BYTES=-1; LAST_CHECKS=-1
STALLED_FOR=0
MAX_STALLED_SEEN=0
for bytes in 1000 5000 12000 20000 31000; do
  step "$bytes" 0
  [ "$STALLED_FOR" -gt "$MAX_STALLED_SEEN" ] && MAX_STALLED_SEEN=$STALLED_FOR
done
assert_eq "$([ "$MAX_STALLED_SEEN" -lt "$STALL_SECONDS" ] && echo yes || echo no)" "yes" "a continuously progressing transfer is never flagged as stalled"

# A genuinely stalled transfer: identical byte AND check count on every
# check. Must trip once STALLED_FOR reaches STALL_SECONDS (3 checks at
# 60s = 180s = STALL_SECONDS).
LAST_BYTES=-1; LAST_CHECKS=-1
STALLED_FOR=0
step "50000" "10"   # first observation, always counts as "changed" from -1
TRIPPED=no
for _ in 1 2 3; do
  step "50000" "10"  # unchanged on both counters
  [ "$STALLED_FOR" -ge "$STALL_SECONDS" ] && TRIPPED=yes
done
assert_eq "$TRIPPED" "yes" "a transfer stuck at the same byte AND check count trips the stall threshold"

# A brief plateau that then resumes must NOT trip (progress resets the counter).
LAST_BYTES=-1; LAST_CHECKS=-1
STALLED_FOR=0
step "1000" "0"
step "1000" "0"   # one stalled check (60s)
step "2000" "0"   # byte progress again - resets STALLED_FOR to 0
assert_eq "$([ "$STALLED_FOR" -ge "$STALL_SECONDS" ] && echo yes || echo no)" "no" "a brief plateau followed by renewed byte progress does not trip the stall threshold"

# Regression test for a real false positive seen in production: after the
# actual data transfer finishes (bytes stop changing - nothing left to
# transfer), rclone can spend a long time purely verifying already-copied
# files against a very large library. "checks" keeps advancing the whole
# time even though "bytes" is flat. This must NOT be flagged as stalled.
LAST_BYTES=-1; LAST_CHECKS=-1
STALLED_FOR=0
step "342491291601" "100000"  # data transfer just completed
MAX_STALLED_SEEN=0
for checks in 105000 112000 121817 125177 130500; do
  step "342491291601" "$checks"  # bytes flat, checks still climbing
  [ "$STALLED_FOR" -gt "$MAX_STALLED_SEEN" ] && MAX_STALLED_SEEN=$STALLED_FOR
done
assert_eq "$([ "$MAX_STALLED_SEEN" -lt "$STALL_SECONDS" ] && echo yes || echo no)" "yes" "a post-transfer verification pass with advancing checks (but flat bytes) is never flagged as stalled"

assert_summary
