#!/bin/bash
# Tests the pure decision logic of scripts/health-check.sh: thresholds, the
# vcgencmd throttle bit field, and combining several states into one. These
# are the parts that decide whether someone gets woken up, so they get a
# repeatable test instead of "looked right on my Pi once".
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

# Source without running main(); no real config file.
HEALTH_CONFIG=/dev/null
# shellcheck source=../scripts/health-check.sh
. ../scripts/health-check.sh

# --- threshold_state: higher is worse, boundaries belong to the worse state
assert_eq "$(threshold_state 50 85 95)" "0" "50% is below an 85% warning"
assert_eq "$(threshold_state 85 85 95)" "1" "exactly the warning threshold warns"
assert_eq "$(threshold_state 94 85 95)" "1" "94% is still only a warning"
assert_eq "$(threshold_state 95 85 95)" "2" "exactly the critical threshold is critical"
assert_eq "$(threshold_state 100 85 95)" "2" "a full disk is critical"

# --- throttle_state: current events are critical, past ones only warn
assert_eq "$(throttle_state 0x0)" "0 no throttling" "0x0 means a healthy power supply"
assert_eq "$(throttle_state 0x50000 | cut -d' ' -f1)" "1" "under-voltage and throttling since boot only warn"
assert_eq "$(throttle_state 0x50005 | cut -d' ' -f1)" "2" "under-voltage right now is critical"
assert_eq "$(throttle_state 0x2 | cut -d' ' -f1)" "2" "frequency capped right now is critical"
assert_eq "$(throttle_state 0x10000)" "1 under-voltage since boot" "the text names what happened"
# Bit 3/19 (soft temperature limit) belongs to the temperature check, not here
assert_eq "$(throttle_state 0x80008 | cut -d' ' -f1)" "0" "soft temperature limit alone does not trip the throttle check"

# --- worst: combining several sub-results into one state
assert_eq "$(worst 0 1)" "1" "OK and WARNING give WARNING"
assert_eq "$(worst 2 1)" "2" "CRITICAL beats WARNING"
assert_eq "$(worst 0 3)" "3" "UNKNOWN beats OK"
assert_eq "$(worst 3 1)" "1" "a real WARNING beats UNKNOWN"
assert_eq "$(worst 2 3)" "2" "a real CRITICAL beats UNKNOWN"

# --- broken_packages: an interrupted dpkg run makes unattended-upgrades
# silently do nothing, so this must catch it from the status file alone
assert_eq "$(broken_packages fixtures/dpkg-status-interrupted)" "example-sys-mods initramfs-tools " \
	"half-configured and triggers-pending packages are reported"
printf 'Package: bash\nStatus: install ok installed\n\nPackage: x\nStatus: deinstall ok config-files\n' > /tmp/dpkg-status-clean.$$
assert_eq "$(broken_packages /tmp/dpkg-status-clean.$$)" "" "installed and removed-with-config packages are fine"
rm -f /tmp/dpkg-status-clean.$$

# --- last_success_from_log: must survive a reboot-wiped journal, and must
# not be fooled by rclone's control characters in the same file.
# The fixture is named .txt on purpose: .gitignore excludes *.log so that a
# real backup log can never be committed by accident.
assert_eq "$(last_success_from_log fixtures/drive-backup-log.txt '=== Sync run finished successfully ===')" \
	"2026-01-03 06:32:29" "the LAST successful run is picked, not the first"
assert_eq "$(last_success_from_log fixtures/drive-backup-log.txt 'no such marker' || echo leer)" "leer" \
	"an unknown marker reports failure instead of a wrong time"
assert_eq "$(last_success_from_log /nonexistent/file '=== Sync run finished successfully ===' || echo leer)" "leer" \
	"a missing log reports failure, so the journal fallback can run"

# --- the rotated generation has to be read too. logrotate truncates the
# live log in place (copytruncate, because rclone holds it open for days),
# so between a rotation and the next finished run the last success line
# exists only in <log>.1. Missing that means a CRITICAL "no successful run"
# on a healthy device - the same false alarm this function exists to end.
MARKER='=== Sync run finished successfully ==='
ROT=/tmp/rotated-log.$$
printf '2026-01-02 03:04:05 %s\n' "$MARKER" > "$ROT.1"
: > "$ROT"
assert_eq "$(last_success_from_log "$ROT" "$MARKER")" "2026-01-02 03:04:05" \
	"a freshly truncated live log falls back to the rotated one"
printf '2026-01-04 05:06:07 %s\n' "$MARKER" > "$ROT"
assert_eq "$(last_success_from_log "$ROT" "$MARKER")" "2026-01-04 05:06:07" \
	"with both present the newer entry from the live log wins"
rm -f "$ROT"
assert_eq "$(last_success_from_log "$ROT" "$MARKER")" "2026-01-02 03:04:05" \
	"a missing live log alone is no reason to give up"
printf 'nothing of interest\n' > "$ROT"
printf 'nothing here either\n' > "$ROT.1"
assert_eq "$(last_success_from_log "$ROT" "$MARKER" || echo leer)" "leer" \
	"no marker in either generation still reports failure"
rm -f "$ROT" "$ROT.1"

# --- join_parts
assert_eq "$(join_parts "a" "b c" "d")" "a, b c, d" "parts are joined with a comma and a space"
assert_eq "$(join_parts "only")" "only" "a single part stays as it is"

# --- hours_between
NOW=1785100000
assert_eq "$(hours_between $(( NOW - 30*3600 )) "$NOW")" "30" "30 hours apart"
assert_eq "$(hours_between $(( NOW - 59*60 )) "$NOW")" "0" "59 minutes round down to 0 hours"


# --- the success stamp: a number, because a sentence can be translated.
# This is the regression test for four days of CRITICAL on a device that was
# working perfectly: its drive-backup.sh had been swapped from a translated
# copy to the upstream English one, SYNC_SUCCESS_MARKER still named the old
# wording, and the check could not tell that apart from a backup that had
# genuinely stopped on Wednesday.
STAMP=/tmp/sync-stamp.$$
printf '1785100000\n' > "$STAMP"
assert_eq "$(last_success_from_stamp "$STAMP")" "1785100000" "a plain epoch stamp is read"
printf '  1785100000  \n' > "$STAMP"
assert_eq "$(last_success_from_stamp "$STAMP")" "1785100000" "surrounding whitespace is ignored"
# A truncated or half-written stamp must be refused, not coerced: turning it
# into 1970 would report a 500,000-hour-old backup with total confidence.
printf 'not a number\n' > "$STAMP"
assert_eq "$(last_success_from_stamp "$STAMP" || echo leer)" "leer" "a non-numeric stamp is refused, not coerced"
printf '17851x00\n' > "$STAMP"
assert_eq "$(last_success_from_stamp "$STAMP" || echo leer)" "leer" "digits with rubbish in them are refused too"
: > "$STAMP"
assert_eq "$(last_success_from_stamp "$STAMP" || echo leer)" "leer" "an empty stamp is refused"
assert_eq "$(last_success_from_stamp /nonexistent/stamp || echo leer)" "leer" \
	"a missing stamp reports failure, so the log fallback can run"
rm -f "$STAMP"

# --- check_sync: which source wins, and what it says when it cannot tell
SLOG=/tmp/sync-log.$$
MARKER='=== Sync run finished successfully ==='
run_sync() {  # run_sync <stamp> <log> -> "<exit> <first line of output>"
	local out rc=0
	out=$(
		SYNC_STAMP="$1"
		SYNC_LOG="$2"
		SYNC_SUCCESS_MARKER="$MARKER"
		SYNC_WARN_HOURS=36
		SYNC_CRIT_HOURS=54
		check_sync
	) || rc=$?
	printf '%s %s' "$rc" "$out"
}

# The stamp wins even when the log's newest marker is days older - that is
# precisely the case that was misreported.
STAMP=/tmp/sync-stamp2.$$
date +%s > "$STAMP"
printf '2026-01-02 03:04:05 %s\n' "$MARKER" > "$SLOG"
assert_eq "$(run_sync "$STAMP" "$SLOG" | cut -d' ' -f1)" "0" "a current stamp beats a stale log marker"
assert_eq "$(run_sync "$STAMP" "$SLOG" | grep -c 'from state file')" "1" "and it says which source it used"

# Without a stamp the log still works, exactly as before.
assert_eq "$(run_sync /nonexistent/stamp "$SLOG" | grep -c 'from log')" "1" \
	"with no stamp the log marker is still used"

# A corrupt stamp must not shadow a perfectly good log.
printf 'garbage\n' > "$STAMP"
assert_eq "$(run_sync "$STAMP" "$SLOG" | grep -c 'from log')" "1" \
	"a corrupt stamp falls through to the log instead of winning"

# No stamp, no marker, but the log is being written: that is a wrong marker
# or a first run still going - not "the backup has stopped". UNKNOWN, and the
# message has to name the suspect, or the next person loses four days too.
printf 'nothing of interest\n' > "$SLOG"
rm -f "$STAMP"
assert_eq "$(run_sync /nonexistent/stamp "$SLOG" | cut -d' ' -f1)" "3" \
	"a current log without the marker is UNKNOWN, not CRITICAL"
assert_eq "$(run_sync /nonexistent/stamp "$SLOG" | grep -c 'SYNC_SUCCESS_MARKER')" "1" \
	"and the message names the setting to look at"

# Nothing at all to go on stays CRITICAL.
rm -f "$SLOG"
assert_eq "$(run_sync /nonexistent/stamp /nonexistent/log | cut -d' ' -f1)" "2" \
	"no stamp, no log and no journal is still critical"

assert_summary
