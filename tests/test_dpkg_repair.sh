#!/bin/bash
# Tests scripts/dpkg-repair.sh: the package-state detection, the cooldown
# arithmetic, every decision main() can reach, and the text of the mails it
# sends.
#
# This script repairs the one failure that otherwise ends every further OS
# update on the device, and it does so unattended. Getting the "already
# tried, ask a person" branch wrong would either bury that mail under a
# daily retry or stop retrying something that would have fixed itself, and
# neither shows up until the day it matters.
#
# The tests are hermetic: systemctl, pgrep, mountpoint and msmtp are all
# stubbed through PATH. Without that, "is a backup running?" would depend on
# whatever happens to run on the machine executing the tests - a developer
# box with rclone open would send every case down the postponed path and the
# failures would make no sense.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

SCRIPT=../scripts/dpkg-repair.sh

# Source without running main(): the pure helpers are checked directly.
# shellcheck source=../scripts/dpkg-repair.sh
. "$SCRIPT"

# --- Pure helpers --------------------------------------------------------

# broken_packages: must find exactly what dpkg considers unfinished. Same
# fixture as test_health_check.sh uses on purpose - what the monitor reports
# and what this script repairs must not drift apart.
assert_eq "$(broken_packages fixtures/dpkg-status-interrupted)" "example-sys-mods initramfs-tools " \
	"half-configured and triggers-pending packages are found"
printf 'Package: bash\nStatus: install ok installed\n\nPackage: x\nStatus: deinstall ok config-files\n' > "/tmp/dpkg-clean.$$"
assert_eq "$(broken_packages "/tmp/dpkg-clean.$$")" "" "a healthy database reports nothing"
rm -f "/tmp/dpkg-clean.$$"

NOW=1785100000
assert_eq "$(hours_since $(( NOW - 25*3600 )) "$NOW")" "25" "25 hours apart"
assert_eq "$(hours_since $(( NOW - 59*60 )) "$NOW")" "0" "59 minutes round down to 0 hours"
assert_eq "$(hours_since $(( NOW + 3600 )) "$NOW")" "0" "a marker from the future is clamped to 0, not negative"

# cooldown_active: the boundary belongs to the expired side, so a daily
# timer is never skipped by a second of clock jitter.
cooldown_active $(( NOW - 23*3600 )) "$NOW" 24 && r=yes || r=no
assert_eq "$r" "yes" "23 h into a 24 h cooldown is still holding"
cooldown_active $(( NOW - 24*3600 )) "$NOW" 24 && r=yes || r=no
assert_eq "$r" "no" "exactly 24 h is expired, so the retry happens"

assert_eq "$(or_placeholder "text" "fallback")" "text" "text wins over the placeholder"
assert_eq "$(or_placeholder "" "fallback")" "fallback" "an empty value falls back"
assert_eq "$(or_placeholder "$(printf '\n\n')" "fallback")" "fallback" "so do blank lines"

assert_eq "$(repair_outcome 1 | cut -c1-32)" "The configure run itself failed," "a non-zero status blames the configure run"
assert_eq "$(repair_outcome 0 | cut -c1-34)" "The configure run reported success" "a zero status says the check still refuses"

# broken_label: the distinction that decides whether the advice in the mail
# is right. dpkg naming no package means something completely different
# depending on whether an interrupted run is recorded.
assert_eq "$(broken_label "foo bar" 0)" "foo bar" "a package list is passed through unchanged"
assert_eq "$(broken_label "foo" 2 | grep -c 'interrupted-run record')" "1" \
	"with both, the records are mentioned alongside the packages"
assert_eq "$(broken_label "" 3 | grep -c 'a configure run does fix it')" "1" \
	"no package but recorded interruptions: the plain case, and the mail says a repair helps"
assert_eq "$(broken_label "" 0 | grep -c 'cannot fix')" "1" \
	"no package and no records: the mail says a repair will not help"
assert_eq "$(broken_label "   " 0 | grep -c 'no package named')" "1" "whitespace counts as empty"

# looks_like_lock: a lock held by another apt is transient, and must not
# turn into a mail claiming the repair failed.
for text in "E: Could not get lock /var/lib/dpkg/lock-frontend" \
	"dpkg: error: dpkg frontend lock was locked by another process" \
	"It is held by process 1234" \
	"Resource temporarily unavailable"; do
	looks_like_lock "$text" && r=yes || r=no
	assert_eq "$r" "yes" "recognised as a lock: ${text:0:28}"
done
looks_like_lock "dpkg: error processing package foo (--configure)" && r=yes || r=no
assert_eq "$r" "no" "a real configure error is not mistaken for a lock"

# --- main(), as subprocesses with everything external stubbed ------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/pool/logs"

# A stand-in for msmtp that keeps the mail instead of sending it, so the
# text a person would actually read can be asserted. The real one going out
# with a blank line where the package list belongs is a defect that shipped
# once - see the "no empty section" checks below.
cat > "$WORK/msmtp" <<EOF
#!/bin/bash
cat >> "$WORK/mail.txt"
EOF

# "apt-get check" stands in as: fails while the sentinel exists.
cat > "$WORK/apt-check" <<EOF
#!/bin/bash
if [ -f "$WORK/broken" ]; then
	echo "E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem."
	exit 100
fi
exit 0
EOF

# A configure run that works: clears the sentinel, like the real one would.
cat > "$WORK/configure-ok" <<EOF
#!/bin/bash
touch "$WORK/configure-ran"
rm -f "$WORK/broken"
echo "Setting up example-sys-mods ..."
EOF
# A configure run that does not help and says why.
cat > "$WORK/configure-fail" <<EOF
#!/bin/bash
touch "$WORK/configure-ran"
echo "dpkg: error processing package example-sys-mods"
exit 1
EOF
# The nastiest real case, and the one that was actually received by mail:
# the configure run exits 0 and prints nothing, yet the check still fails.
cat > "$WORK/configure-noop" <<EOF
#!/bin/bash
touch "$WORK/configure-ran"
exit 0
EOF
# Another apt holds the lock.
cat > "$WORK/configure-lock" <<EOF
#!/bin/bash
touch "$WORK/configure-ran"
echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 999"
exit 2
EOF

# systemctl: reports whatever state the test asks for, so the "oneshot
# service shows up as activating for its whole run" case is covered. That
# is a real bug this suite caught once: is-active --quiet exits 3 there, so
# the original check never saw a running backup at all.
cat > "$WORK/systemctl" <<EOF
#!/bin/bash
cat "$WORK/unit-state" 2>/dev/null || echo inactive
EOF
# pgrep: a backup process exists only when the test says so.
cat > "$WORK/pgrep" <<EOF
#!/bin/bash
[ -f "$WORK/backup-process" ] && exit 0
exit 1
EOF
# mountpoint: the pool is mounted unless the test says otherwise.
cat > "$WORK/mountpoint" <<EOF
#!/bin/bash
[ -f "$WORK/pool-gone" ] && exit 1
exit 0
EOF

chmod +x "$WORK"/msmtp "$WORK"/apt-check "$WORK"/configure-ok "$WORK"/configure-fail \
	"$WORK"/configure-noop "$WORK"/configure-lock "$WORK"/systemctl "$WORK"/pgrep "$WORK"/mountpoint
echo "someone@example.invalid" > "$WORK/recipients.txt"
echo inactive > "$WORK/unit-state"

STATE="$WORK/state"
LOGS="$WORK/pool/logs"
MARKER="$STATE/.dpkg-repair-attempted"
SINCE="$STATE/.dpkg-interrupted-since"
NOTIFIED="$STATE/.dpkg-repair-notified"

run_repair() {  # run_repair <configure stub> [dpkg status file] -> exit code
	local configure="$1" status_file="${2:-fixtures/dpkg-status-interrupted}" code=0
	rm -f "$WORK/mail.txt" "$WORK/configure-ran"
	env PATH="$WORK:$PATH" \
		POOL="$WORK/pool" \
		STATE_DIR="$STATE" LOG_DIR="$LOGS" \
		RECIPIENTS_FILE="$WORK/recipients.txt" \
		DPKG_STATUS="$status_file" \
		DPKG_UPDATES_DIR="$WORK/updates" \
		APT_CHECK_CMD="$WORK/apt-check" \
		DPKG_CONFIGURE_CMD="$WORK/$configure" \
		COOLDOWN_HOURS=24 NOTIFY_COOLDOWN_HOURS=24 POSTPONE_MAX_HOURS=48 \
		bash "$SCRIPT" >"$WORK/out" 2>&1 || code=$?
	echo "$code"
}

ran()      { [ -f "$WORK/configure-ran" ] && echo ran || echo quiet; }
mailed()   { [ -s "$WORK/mail.txt" ] && echo mail || echo still; }
exists()   { [ -f "$1" ] && echo da || echo weg; }
log_has()  { grep -q "$1" "$LOGS/dpkg-repair.log" && echo ja || echo nein; }
mail_has() { grep -q "$1" "$WORK/mail.txt" && echo ja || echo nein; }

# Does the mail have an empty section, i.e. a heading ending in ":" with
# nothing but blank lines under it? That is what makes a 3 a.m. mail
# useless.
leere_abschnitte() {  # leere_abschnitte <mail file>
	awk '
		/:$/ { heading = $0; blanks = 0; next }
		heading != "" {
			if ($0 ~ /^[[:space:]]*$/) { blanks++; if (blanks > 1) { print heading; heading = "" } }
			else { heading = "" }
		}
	' "$1" | wc -l | tr -d ' '
}

# 1. Nothing wrong -> silent success, nothing written, state cleared.
rm -f "$WORK/broken"
mkdir -p "$STATE"
rm -f "$SINCE" "$NOTIFIED"
touch "$MARKER"   # a leftover from an earlier incident, must be cleaned up
assert_eq "$(run_repair configure-ok)" "0" "a healthy package database exits 0"
assert_eq "$(ran)" "quiet" "a healthy database never runs dpkg --configure"
assert_eq "$(exists "$MARKER")" "weg" "a healthy database clears a leftover attempt marker"
assert_eq "$([ -f "$LOGS/dpkg-repair.log" ] && echo noisy || echo quiet)" "quiet" \
	"a healthy database writes no log line at all"

# 2. A backup is running as a systemd oneshot unit: state "activating" for
# the whole run. THIS is the regression test for the bug where
# `systemctl is-active --quiet` exits 3 there and the repair went ahead
# right next to the sync - the exact collision that broke dpkg twice.
touch "$WORK/broken"
echo activating > "$WORK/unit-state"
rm -f "$MARKER" "$SINCE" "$NOTIFIED"
assert_eq "$(run_repair configure-ok)" "0" "a run during an activating oneshot unit exits 0"
assert_eq "$(ran)" "quiet" "and does not touch dpkg while the backup runs"
assert_eq "$(log_has 'postponed')" "ja" "the postponement is logged"
assert_eq "$(mailed)" "still" "no mail for a freshly postponed repair"
echo inactive > "$WORK/unit-state"

# 3. Same via the process name, which also covers a run started by hand
# with no unit at all.
touch "$WORK/backup-process"
rm -f "$MARKER" "$SINCE" "$NOTIFIED"
assert_eq "$(run_repair configure-ok)" "0" "a backup process found by name also postpones"
assert_eq "$(ran)" "quiet" "and still does not touch dpkg"

# 4. Postponed for longer than POSTPONE_MAX_HOURS -> mail anyway. Staying
# silent through a multi-day sync is how the 39-day outage happened.
touch -d "@$(( $(date +%s) - 50*3600 ))" "$SINCE"
rm -f "$NOTIFIED"
assert_eq "$(run_repair configure-ok)" "0" "a long postponement still exits 0"
assert_eq "$(mailed)" "mail" "but after 48 h it does send a mail"
assert_eq "$(mail_has 'a backup keeps running')" "ja" "the mail says why nothing was repaired"
assert_eq "$(leere_abschnitte "$WORK/mail.txt")" "0" "that mail has no empty section"
assert_eq "$(ran)" "quiet" "and it still does not touch dpkg"

# 5. The mail cooldown holds: same situation one run later, no second mail.
touch -d "@$(( $(date +%s) - 50*3600 ))" "$SINCE"
assert_eq "$(run_repair configure-ok)" "0" "the next run exits 0 as well"
assert_eq "$(mailed)" "still" "but sends no second mail within the cooldown"
assert_eq "$(log_has 'mail suppressed')" "nein" "the postponed path logs its own reason, not 'suppressed'"
rm -f "$WORK/backup-process" "$SINCE" "$NOTIFIED"

# 6. Interrupted, idle, and the repair works.
touch "$WORK/broken"
rm -f "$MARKER" "$NOTIFIED"
assert_eq "$(run_repair configure-ok)" "0" "a successful repair exits 0"
assert_eq "$(ran)" "ran" "an interrupted database does run dpkg --configure"
assert_eq "$(exists "$MARKER")" "weg" "the attempt marker is cleared after a successful repair"
assert_eq "$(exists "$SINCE")" "weg" "and so is the 'interrupted since' marker"
assert_eq "$(log_has 'clean again')" "ja" "the successful repair is logged"
assert_eq "$(mail_has 'example-sys-mods initramfs-tools')" "ja" "the mail names the packages"
assert_eq "$(leere_abschnitte "$WORK/mail.txt")" "0" "the success mail has no empty section"

# 7. The configure run itself fails.
touch "$WORK/broken"
rm -f "$MARKER" "$NOTIFIED" "$SINCE"
assert_eq "$(run_repair configure-fail)" "1" "a repair that did not help exits non-zero"
assert_eq "$(exists "$MARKER")" "da" "the marker is kept, so the next run escalates instead of retrying"
assert_eq "$(mail_has 'The configure run itself failed, with exit status 1')" "ja" \
	"a non-zero exit is named as the configure run's own failure"
assert_eq "$(mail_has 'dpkg: error processing package')" "ja" "the configure output is quoted"
assert_eq "$(mail_has 'E: dpkg was interrupted')" "ja" \
	"and so is what apt-get check itself says, which is the authoritative error"
assert_eq "$(leere_abschnitte "$WORK/mail.txt")" "0" "that mail has no empty section either"

# 8. The configure run exits 0, prints nothing, and the check still fails -
# exactly the mail that was received and misread.
printf 'Package: bash\nStatus: install ok installed\n' > "$WORK/status-clean"
touch "$WORK/broken"
rm -f "$MARKER" "$NOTIFIED" "$SINCE"
assert_eq "$(run_repair configure-noop "$WORK/status-clean")" "1" \
	"a check that keeps failing is a failure even when the configure run exits 0"
assert_eq "$(mail_has 'reported success, yet apt-get check still refuses')" "ja" \
	"exit status 0 is described as what it is"
assert_eq "$(grep -c 'did not fix it (exit status 0)' "$WORK/mail.txt")" "0" \
	"the contradictory wording is gone"
assert_eq "$(mail_has 'no package named and no interrupted run recorded')" "ja" \
	"with nothing named and nothing recorded, the mail says a repair will not help"
assert_eq "$(grep -cx '(it printed nothing)' "$WORK/mail.txt")" "1" \
	"a silent configure run says so instead of leaving the section blank"
assert_eq "$(leere_abschnitte "$WORK/mail.txt")" "0" "and that mail has no empty section"

# 9. Interrupted, but dpkg's updates directory records it: the plain case,
# where a configure run genuinely does help - and the mail must say so.
mkdir -p "$WORK/updates"
touch "$WORK/updates/0001" "$WORK/updates/0002"
touch "$WORK/broken"
rm -f "$MARKER" "$NOTIFIED" "$SINCE"
assert_eq "$(run_repair configure-noop "$WORK/status-clean")" "1" "still reports a failure"
assert_eq "$(mail_has 'a configure run does fix it')" "ja" \
	"with interrupted-run records, the mail says the plain case applies"
assert_eq "$(count_updates_records "$WORK/updates")" "2" "the records are counted"
assert_eq "$(count_updates_records "$WORK/nonexistent")" "0" "a missing directory counts as zero"
rm -rf "$WORK/updates"

# 10. A fresh attempt marker: escalate, and do NOT retry.
touch "$WORK/broken" "$MARKER"
rm -f "$NOTIFIED"
assert_eq "$(run_repair configure-ok)" "1" "a fresh marker means the run reports instead of repairing"
assert_eq "$(ran)" "quiet" "within the cooldown, dpkg --configure is not run again"
assert_eq "$(log_has 'no retry before')" "ja" "the escalation is logged"
assert_eq "$(mail_has 'attempted, not necessarily achieved')" "ja" \
	"the mail does not claim a repair happened when only an attempt did"

# 11. Same again right away: the mail cooldown suppresses the second one.
touch "$WORK/broken" "$MARKER"
assert_eq "$(run_repair configure-ok)" "1" "the next run still reports a failure"
assert_eq "$(mailed)" "still" "but does not mail twice inside the cooldown"
assert_eq "$(log_has 'mail suppressed')" "ja" "and says so in the log instead"

# 12. Marker aged past the cooldown -> try once more.
touch -d "@$(( $(date +%s) - 25*3600 ))" "$MARKER"
rm -f "$NOTIFIED"
touch "$WORK/broken"
assert_eq "$(run_repair configure-ok)" "0" "once the cooldown expired, the repair is attempted again"
assert_eq "$(ran)" "ran" "an expired cooldown does allow another dpkg --configure"

# 13. Another apt holds the lock: transient, so no alarm and no burnt
# cooldown - the next run has to be free to try again.
touch "$WORK/broken"
rm -f "$MARKER" "$NOTIFIED" "$SINCE"
assert_eq "$(run_repair configure-lock)" "0" "a lock held by another process is not a failure"
assert_eq "$(mailed)" "still" "and raises no alarm"
assert_eq "$(exists "$MARKER")" "weg" "the attempt marker is removed, so the next run retries"
assert_eq "$(log_has 'holds the lock')" "ja" "the lock is logged"

# 14. An unreadable status file must not kill the script before it has even
# tried - an interrupted dpkg write is a plausible cause of exactly that.
touch "$WORK/broken"
rm -f "$MARKER" "$NOTIFIED" "$SINCE"
assert_eq "$(run_repair configure-ok "$WORK/does-not-exist")" "0" \
	"an unreadable status file still leads to a repair attempt"
assert_eq "$(ran)" "ran" "the repair is attempted anyway"

# 15. The pool is gone: the log cannot be written, but the repair and the
# mail still happen, and nothing is created on the SD card under the mount
# point.
touch "$WORK/broken" "$WORK/pool-gone"
rm -rf "$LOGS"
rm -f "$MARKER" "$NOTIFIED" "$SINCE"
assert_eq "$(run_repair configure-fail)" "1" "without the pool the run still reports"
assert_eq "$(mailed)" "mail" "and still mails"
assert_eq "$([ -d "$LOGS" ] && echo da || echo weg)" "weg" \
	"no log directory is created on the mount point while the pool is unmounted"
assert_eq "$(grep -c 'pool unreachable' "$WORK/mail.txt")" "1" \
	"the mail says where the log is not"
rm -f "$WORK/pool-gone"
mkdir -p "$LOGS"

assert_summary
