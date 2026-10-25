#!/bin/bash
# Tests scripts/dpkg-repair.sh: the package-state detection, the cooldown
# arithmetic, and all four decisions main() can reach.
#
# This script repairs the one failure that otherwise ends every further OS
# update on the device, and it does so unattended. Getting the "already
# tried, ask a person" branch wrong would either bury that mail under a
# daily retry or stop retrying something that would have fixed itself, and
# neither shows up until the day it matters. Hence a real test rather than
# "ran it once on the Pi".
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

SCRIPT=../scripts/dpkg-repair.sh

# Source without running main(): the pure helpers are checked directly.
# shellcheck source=../scripts/dpkg-repair.sh
. "$SCRIPT"

# --- broken_packages: must find exactly what dpkg considers unfinished.
# Same fixture as test_health_check.sh uses on purpose - what the monitor
# reports and what this script repairs must not drift apart.
assert_eq "$(broken_packages fixtures/dpkg-status-interrupted)" "example-sys-mods initramfs-tools " \
	"half-configured and triggers-pending packages are found"
printf 'Package: bash\nStatus: install ok installed\n\nPackage: x\nStatus: deinstall ok config-files\n' > "/tmp/dpkg-clean.$$"
assert_eq "$(broken_packages "/tmp/dpkg-clean.$$")" "" "a healthy database reports nothing"
rm -f "/tmp/dpkg-clean.$$"

# --- hours_since
NOW=1785100000
assert_eq "$(hours_since $(( NOW - 25*3600 )) "$NOW")" "25" "25 hours apart"
assert_eq "$(hours_since $(( NOW - 59*60 )) "$NOW")" "0" "59 minutes round down to 0 hours"
assert_eq "$(hours_since $(( NOW + 3600 )) "$NOW")" "0" "a marker from the future is clamped to 0, not negative"

# --- cooldown_active: the boundary belongs to the expired side, so a daily
# timer is never skipped by a second of clock jitter.
cooldown_active $(( NOW - 23*3600 )) "$NOW" 24 && r=yes || r=no
assert_eq "$r" "yes" "23 h into a 24 h cooldown is still holding"
cooldown_active $(( NOW - 24*3600 )) "$NOW" 24 && r=yes || r=no
assert_eq "$r" "no" "exactly 24 h is expired, so the retry happens"
cooldown_active $(( NOW - 48*3600 )) "$NOW" 24 && r=yes || r=no
assert_eq "$r" "no" "two days later it is long expired"

# --- The four decisions of main(), as subprocesses with the command hooks
# pointing at stubs. No package database is touched.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# "apt-get check" stands in as: fails while the sentinel exists.
cat > "$WORK/apt-check" <<EOF
#!/bin/bash
[ -f "$WORK/broken" ] && exit 1
exit 0
EOF
# A configure run that works: clears the sentinel, like the real one would.
cat > "$WORK/configure-ok" <<EOF
#!/bin/bash
touch "$WORK/configure-ran"
rm -f "$WORK/broken"
echo "Setting up example-sys-mods ..."
EOF
# A configure run that does not help.
cat > "$WORK/configure-fail" <<EOF
#!/bin/bash
touch "$WORK/configure-ran"
echo "dpkg: error processing package example-sys-mods"
exit 1
EOF
chmod +x "$WORK"/apt-check "$WORK"/configure-ok "$WORK"/configure-fail

run_repair() {  # run_repair <configure stub> -> exit code, state left in $WORK
	local configure="$1" code=0
	env STATE_DIR="$WORK/state" LOG_DIR="$WORK/logs" \
		RECIPIENTS_FILE="$WORK/recipients.txt" \
		DPKG_STATUS=fixtures/dpkg-status-interrupted \
		APT_CHECK_CMD="$WORK/apt-check" \
		DPKG_CONFIGURE_CMD="$WORK/$configure" \
		COOLDOWN_HOURS=24 \
		bash "$SCRIPT" >"$WORK/out" 2>&1 || code=$?
	echo "$code"
}

# No recipients file: mail is skipped with a warning instead of failing, so
# the repair itself still happens. (A real device has one; this also covers
# the case where the pool holding it is unreachable.)

# 1. Nothing wrong -> silent success, nothing written.
rm -f "$WORK/broken" "$WORK/configure-ran"
assert_eq "$(run_repair configure-ok)" "0" "a healthy package database exits 0"
assert_eq "$([ -f "$WORK/configure-ran" ] && echo ran || echo quiet)" "quiet" \
	"a healthy database never runs dpkg --configure"
assert_eq "$([ -f "$WORK/logs/dpkg-repair.log" ] && echo noisy || echo quiet)" "quiet" \
	"a healthy database writes no log line at all"

# 2. Interrupted, and the repair works -> exit 0, marker cleared again.
touch "$WORK/broken"
rm -f "$WORK/configure-ran"
assert_eq "$(run_repair configure-ok)" "0" "a successful repair exits 0"
assert_eq "$([ -f "$WORK/configure-ran" ] && echo ran || echo quiet)" "ran" \
	"an interrupted database does run dpkg --configure"
assert_eq "$([ -f "$WORK/state/.dpkg-repair-attempted" ] && echo kept || echo cleared)" "cleared" \
	"the attempt marker is cleared after a successful repair, so the next one may try again"
assert_eq "$(grep -c 'repaired automatically' "$WORK/logs/dpkg-repair.log")" "1" \
	"the successful repair is logged"

# 3. Interrupted, and the repair does not help -> exit 1, marker kept.
touch "$WORK/broken"
rm -f "$WORK/configure-ran" "$WORK/state/.dpkg-repair-attempted"
assert_eq "$(run_repair configure-fail)" "1" "a repair that did not help exits non-zero"
assert_eq "$([ -f "$WORK/state/.dpkg-repair-attempted" ] && echo kept || echo cleared)" "kept" \
	"the marker is kept, so tomorrow's run escalates instead of retrying"

# 4. Still interrupted with a fresh marker -> escalate, and do NOT retry.
touch "$WORK/broken" "$WORK/state/.dpkg-repair-attempted"
rm -f "$WORK/configure-ran"
assert_eq "$(run_repair configure-ok)" "1" "a fresh marker means the run reports instead of repairing"
assert_eq "$([ -f "$WORK/configure-ran" ] && echo ran || echo quiet)" "quiet" \
	"within the cooldown, dpkg --configure is not run again"
assert_eq "$(grep -c 'asking for a person' "$WORK/logs/dpkg-repair.log")" "1" \
	"the escalation is logged"

# 5. Same, but the marker has aged past the cooldown -> try once more.
touch -d "@$(( $(date +%s) - 25*3600 ))" "$WORK/state/.dpkg-repair-attempted"
rm -f "$WORK/configure-ran"
assert_eq "$(run_repair configure-ok)" "0" "once the cooldown expired, the repair is attempted again"
assert_eq "$([ -f "$WORK/configure-ran" ] && echo ran || echo quiet)" "ran" \
	"an expired cooldown does allow another dpkg --configure"

assert_summary
