#!/bin/bash
# Tests scripts/prune-rolling-backups.sh: the only code in this project that
# deliberately deletes from the backup.
#
# Both of its conditions have to keep holding, and neither is self-evident
# from the call site:
#
#   - the newest KEEP files are never candidates, whatever the source says,
#     because that floor is what preserves the copy-only guarantee inside
#     the retention window;
#   - a file the source still has is never deleted, because `rclone copy`
#     would fetch it straight back and the rule would churn gigabytes a day
#     for ever.
#
# Get either wrong and the damage is quiet: the first loses backups, the
# second burns the link and the disks without ever reporting a fault. So the
# source listing is stubbed here and every branch gets exercised.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

SCRIPT=$(cd .. && pwd)/scripts/prune-rolling-backups.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/mountpoint" <<'STUB'
#!/bin/bash
[ "${FAKE_MOUNTED:-yes}" = yes ]
STUB

# Stands in for "rclone lsf --max-depth 1 <dir>": prints the names the
# source is pretending to still have. FAKE_LSF_FAIL makes it fail, which is
# how the "network is down" branch gets tested without a network.
cat > "$WORK/bin/fake-lsf" <<'STUB'
#!/bin/bash
[ -n "${FAKE_LSF_FAIL:-}" ] && exit 1
cat "${FAKE_REMOTE_LIST:-/dev/null}"
STUB

chmod +x "$WORK/bin"/*
PATH="$WORK/bin:$PATH"

POOLDIR="$WORK/pool"
HA="$POOLDIR/drive/Home Assistant"
LOG="$WORK/drive-backup.log"
RULES="$WORK/prune.rules"
REMOTE_LIST="$WORK/remote.txt"

# Six rolling backups, oldest to newest, plus the kind of file that shares
# that folder on the real device and must never be touched: an emergency
# kit, a one-off image under a different name, and a directory whose name
# also matches the pattern.
fixture() {
	rm -rf "$POOLDIR"
	mkdir -p "$HA"
	local i
	for i in 1 2 3 4 5 6; do
		head -c "$((i * 100))" /dev/zero > "$HA/Automatic_backup_day$i.tar"
		touch -d "@$((1790000000 + i * 86400))" "$HA/Automatic_backup_day$i.tar"
	done
	printf 'keep me\n' > "$HA/emergency_kit.txt"
	printf 'keep me\n' > "$HA/Raspberry_PI_Neuinstallation.tar"
	mkdir -p "$HA/Automatic_backup_directory.tar"
	: > "$LOG"
}

# Runs the script over the fixture. Extra arguments are env assignments.
run() {
	RC=0
	env POOL="$POOLDIR" LOCAL_ROOT="$POOLDIR/drive" REMOTE="fakeremote:" \
		RULES_FILE="$RULES" LOG_FILE="$LOG" \
		RCLONE_LSF_CMD="$WORK/bin/fake-lsf" FAKE_REMOTE_LIST="$REMOTE_LIST" \
		"$@" bash "$SCRIPT" >"$WORK/out" 2>"$WORK/err" || RC=$?
}

remaining() {  # how many rolling backups are left
	find "$HA" -maxdepth 1 -type f -name 'Automatic_backup_*.tar' | wc -l
}

there() {  # there <path> -> yes/no, so a missing file reads as a value
	[ -e "$1" ] && echo yes || echo no
}

count_in_log() {  # count_in_log <text> -> how many log lines contain it
	grep -c -- "$1" "$LOG" || true
}

# --- The source has dropped everything old ------------------------------

printf '2 Home Assistant/Automatic_backup_*.tar\n' > "$RULES"
: > "$REMOTE_LIST"
fixture
run
assert_eq "$RC" "0" "a normal run exits successfully"
assert_eq "$(remaining)" "2" "the newest two are kept, the other four are gone"
assert_eq "$(there "$HA/Automatic_backup_day6.tar")" "yes" "the newest survives"
assert_eq "$(there "$HA/Automatic_backup_day5.tar")" "yes" "the second newest survives"
assert_eq "$(there "$HA/Automatic_backup_day1.tar")" "no" "the oldest is deleted"
# These neighbours are the real folder's situation, not a hypothetical: an
# emergency kit and a one-off reinstall image live next to the rolling ones
# and neither is replaceable.
assert_eq "$(there "$HA/emergency_kit.txt")" "yes" "a file outside the pattern is untouched"
assert_eq "$(there "$HA/Raspberry_PI_Neuinstallation.tar")" "yes" "a differently named tar is untouched"
assert_eq "$(there "$HA/Automatic_backup_directory.tar")" "yes" "a directory matching the pattern is not a candidate"
assert_eq "$(count_in_log 'removed 4')" "1" "the log says how many went and how much that freed"

# --- Newest means newest by time, not by name ---------------------------

fixture
touch -d '@1800000000' "$HA/Automatic_backup_day1.tar"
run
assert_eq "$(there "$HA/Automatic_backup_day1.tar")" "yes" "the newest by mtime survives even with the oldest name"
assert_eq "$(there "$HA/Automatic_backup_day5.tar")" "no" "an older file does not survive on the strength of its name"

# --- What the source still has is never deleted -------------------------

# Deleting it would only mean downloading it again on the next sync, daily.
fixture
printf 'Automatic_backup_day2.tar\nAutomatic_backup_day3.tar\n' > "$REMOTE_LIST"
run
assert_eq "$(remaining)" "4" "files the source still has are kept, even beyond the keep count"
assert_eq "$(there "$HA/Automatic_backup_day2.tar")" "yes" "a file still in the source survives"
assert_eq "$(there "$HA/Automatic_backup_day4.tar")" "no" "a file the source dropped is still deleted"
assert_eq "$(count_in_log 'still has them')" "1" "the log explains why those were spared"

# --- A source that cannot be reached deletes nothing --------------------

fixture
: > "$REMOTE_LIST"
run FAKE_LSF_FAIL=1
assert_eq "$RC" "0" "an unreachable source is not a failure of this script"
assert_eq "$(remaining)" "6" "an unreachable source deletes nothing at all"
assert_eq "$(count_in_log 'could not list')" "1" "and it says so"

# --- Nothing to do ------------------------------------------------------

fixture
printf '6 Home Assistant/Automatic_backup_*.tar\n' > "$RULES"
run
assert_eq "$(remaining)" "6" "a keep count equal to the file count deletes nothing"
assert_eq "$(wc -c < "$LOG")" "0" "and logs nothing"

fixture
printf '20 Home Assistant/Automatic_backup_*.tar\n' > "$RULES"
run
assert_eq "$(remaining)" "6" "a keep count above the file count deletes nothing"

fixture
printf '2 Home Assistant/no_such_pattern_*.tar\n' > "$RULES"
run
assert_eq "$(remaining)" "6" "a pattern that matches nothing deletes nothing"

fixture
printf '2 No Such Folder/Automatic_backup_*.tar\n' > "$RULES"
run
assert_eq "$(remaining)" "6" "a rule for a folder that does not exist is harmless"

# --- Dry run ------------------------------------------------------------

fixture
printf '2 Home Assistant/Automatic_backup_*.tar\n' > "$RULES"
run DRY_RUN=1
assert_eq "$(remaining)" "6" "a dry run deletes nothing"
assert_eq "$(count_in_log 'would delete')" "4" "a dry run names every file it would have deleted"
assert_eq "$(count_in_log 'would remove 4')" "1" "a dry run reports the total it would have freed"

# --- Rules that are not rules -------------------------------------------

# One bad line must not take the other rules down with it: a rules file is
# hand-edited, and the failure would otherwise be silent.
fixture
printf '# a comment\n\nzero Home Assistant/Automatic_backup_*.tar\n0 Home Assistant/Automatic_backup_*.tar\n2 Home Assistant/Automatic_backup_*.tar\n' > "$RULES"
run
assert_eq "$(remaining)" "2" "a valid rule after a comment, a blank line and two broken rules still applies"
assert_eq "$(count_in_log 'does not start with a keep count')" "2" "both broken rules are reported"

fixture
printf '2 Home */Automatic_backup_*.tar\n' > "$RULES"
run
assert_eq "$(remaining)" "6" "a wildcard in the directory part is refused, not guessed at"
assert_eq "$(count_in_log 'wildcard in its directory part')" "1" "and reported"

# --- Guards -------------------------------------------------------------

fixture
printf '2 Home Assistant/Automatic_backup_*.tar\n' > "$RULES"
run FAKE_MOUNTED=no
assert_eq "$RC" "0" "an unmounted pool is the backup script's problem to report, not this one's"
assert_eq "$(remaining)" "6" "an unmounted pool deletes nothing"

fixture
rm -f "$RULES"
run
assert_eq "$RC" "0" "no rules file is the normal, switched-off state"
assert_eq "$(remaining)" "6" "no rules file deletes nothing"

assert_summary
