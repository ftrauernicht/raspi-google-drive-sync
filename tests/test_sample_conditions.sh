#!/bin/bash
# Tests scripts/sample-conditions.sh: the one-line-per-sample format that
# every reader of conditions.log depends on, and the report that tells a
# busy pool apart from a wedged recorder.
#
# Why this deserves a test. This file is the only witness left after a hard
# reset on a device whose journal lives in RAM (docs/architecture.md). A
# recorder that silently stops, or a line with a space in the wrong field,
# is not noticed until the next unexplained reset - which is precisely the
# moment when nobody can go back and fix it. It has already happened twice
# that the explanation was missing afterwards; that is the whole reason this
# script exists.
#
# Hermetic: vcgencmd, pgrep and mountpoint are stubbed through PATH, and the
# /proc files come from fixtures. Without that, "which heavy job is running"
# would depend on whatever happens to run on the machine executing the
# tests, and a developer box with rclone open would fail the busy= checks.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

SCRIPT=$(cd .. && pwd)/scripts/sample-conditions.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/pool/logs"

cat > "$WORK/bin/mountpoint" <<'STUB'
#!/bin/bash
[ "${FAKE_MOUNTED:-yes}" = yes ]
STUB

cat > "$WORK/bin/vcgencmd" <<'STUB'
#!/bin/bash
printf '%s\n' "${FAKE_VCGENCMD:-throttled=0x0}"
STUB

# Reports a process as running only when its name appears in FAKE_RUNNING,
# matched against the last argument - which is the pattern in every pgrep
# call this script makes, whether -x or -f. Colon-separated and not
# whitespace-separated, because one of the patterns under test contains a
# space of its own: 'unattended-upgrade( |$)'.
cat > "$WORK/bin/pgrep" <<'STUB'
#!/bin/bash
last="${*: -1}"
IFS=':' read -ra wants <<< "${FAKE_RUNNING:-}"
for want in "${wants[@]}"; do
	[ "$last" = "$want" ] && exit 0
done
exit 1
STUB

chmod +x "$WORK/bin"/*
PATH="$WORK/bin:$PATH"

printf '41234\n' > "$WORK/thermal"
printf '0.42 0.31 0.25 1/100 1234\n' > "$WORK/loadavg"
printf 'MemTotal:         437124 kB\nMemAvailable:     255000 kB\nSwapFree:         393216 kB\n' > "$WORK/meminfo"
printf '359937.69 1234.56\n' > "$WORK/uptime"

LOG="$WORK/pool/logs/conditions.log"

# Runs the script with the fixtures wired in. Extra arguments are env
# assignments for the case under test. Leaves the exit status in RC, stderr
# in $WORK/err and the sample in $LOG.
run() {
	: > "$LOG"
	RC=0
	env POOL="$WORK/pool" LOG_DIR="$WORK/pool/logs" LOG_FILE="$LOG" \
		THERMAL_ZONE="$WORK/thermal" LOADAVG="$WORK/loadavg" \
		MEMINFO="$WORK/meminfo" UPTIME_FILE="$WORK/uptime" \
		"$@" bash "$SCRIPT" >"$WORK/out" 2>"$WORK/err" || RC=$?
}

field() {  # field <name> -> the value of that name= field in the sample
	sed -n "1s/.*[ ]$1=\([^ ]*\).*/\1/p" "$LOG"
}

# --- The format every reader assumes ------------------------------------

run
assert_eq "$RC" "0" "a normal sample exits successfully"
assert_eq "$(wc -l < "$LOG")" "1" "one run writes exactly one line"
assert_eq "$(wc -w < "$LOG")" "9" "the line carries date, time and seven name=value fields"
assert_eq "$(field throttled)" "0x0" "the throttle word is passed through verbatim"
assert_eq "$(field temp)" "41.2" "millidegrees are reported as degrees with one decimal"
assert_eq "$(field load)" "0.42" "the one-minute load average is the first field of loadavg"
assert_eq "$(field memavail)" "249M" "MemAvailable is reported in whole megabytes"
assert_eq "$(field swapfree)" "384M" "SwapFree is reported in whole megabytes"
# Uptime is the field that decides the open question from the second
# incident - a watchdog reset and an under-voltage reset look identical in
# this file except that uptime goes backwards. Losing it would quietly
# retire the measurement the log was extended for.
assert_eq "$(field up)" "359937.69" "uptime is recorded, clock-independent proof of a restart"

# --- Which heavy job was running ----------------------------------------

assert_eq "$(field busy)" "none" "an idle device reports busy=none"
run FAKE_RUNNING="rclone:dpkg"
assert_eq "$(field busy)" "rclone,dpkg," "every heavy job that runs is named"
# -f, not -x, for this one: comm is truncated to 15 characters, so the
# single heaviest job on this device would otherwise be missed - and it is
# the one named in both incidents.
run FAKE_RUNNING="update-initramfs|mkinitramfs"
assert_eq "$(field busy)" "initramfs," "an initramfs rebuild is seen through the truncated comm name"
# unattended-upgrades.service permanently runs
# "unattended-upgrade-shutdown --wait-for-signal". If that counted, every
# single line of the file would claim an update was in progress.
run FAKE_RUNNING='unattended-upgrade( |$)'
assert_eq "$(field busy)" "u-u," "a real unattended-upgrade run counts"

# --- vcgencmd misbehaving ------------------------------------------------

# vcgencmd prints "error=1 error_msg=..." when the firmware mailbox is
# unhappy. A space in that value would push every later field one place to
# the right and break every reader of this file.
run FAKE_VCGENCMD='error=1 error_msg="unknown command"'
assert_eq "$(wc -l < "$LOG")" "1" "a vcgencmd error still writes exactly one line"
assert_eq "$(wc -w < "$LOG")" "9" "a vcgencmd error does not shift the fields"

# --- The pool being gone is not this script's failure -------------------

run FAKE_MOUNTED=no
assert_eq "$RC" "0" "a missing pool is the backup script's problem to report, not this one's"
assert_eq "$(wc -c < "$LOG")" "0" "a missing pool writes nothing at all"

# --- Busy pool versus wedged recorder -----------------------------------

# The unit's TimeoutStartSec is the "wedged" limit; this is the "merely
# slow" report. Conflating the two cost three failed units and three
# monitoring alarms on 2026-10-28 on a device that was only syncing.
run
assert_eq "$(wc -c < "$WORK/err")" "0" "a sample within the mark says nothing"
run SLOW_RUN_WARN_SECONDS=0
assert_eq "$(grep -c 'sample took' "$WORK/err" || true)" "1" "a slow sample is reported once"
# The prefix is not decoration: the unit sets LogLevelMax=warning, and
# without <4> systemd files this at info and drops it on the floor.
assert_eq "$(cut -c1-3 < "$WORK/err")" "<4>" "the report is filed at warning level, the one level the unit lets through"
assert_eq "$(grep -c 'sample took' "$LOG" || true)" "0" "the report goes to the journal, never to the pool that just blocked"
assert_eq "$(wc -l < "$LOG")" "1" "a slow sample is still a recorded sample"

assert_summary
