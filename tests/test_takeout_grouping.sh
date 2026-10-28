#!/bin/bash
# Tests the Takeout filename grouping-by-calendar-day logic used in
# scripts/drive-backup.sh's cleanup step. Keep this in sync with the sed
# pattern and array variable name there if either ever changes.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./assert.sh

group_by_day() {
  # Mirrors the sed pattern in scripts/drive-backup.sh's Takeout cleanup step.
  sed -E 's/^takeout-([0-9]{8})T[0-9]{6}Z-.*/\1/'
}

# Case 1: a failed attempt (1 tiny file) + a retry a second later (7 real
# archives) — same calendar day, must group as ONE export. This exact
# scenario happened with a real Google Takeout export while building this
# project: a failed first attempt followed by an automatic retry a second
# later produces two filenames with slightly different timestamps for what
# is really the same logical export.
GROUP_COUNT=$(cat <<'EOF' | group_by_day | sort -u | wc -l
takeout-20260726T172606Z-001.zip
takeout-20260726T172607Z-2-001.zip
takeout-20260726T172607Z-2-002.zip
takeout-20260726T172607Z-2-003.zip
takeout-20260726T172607Z-2-004.zip
takeout-20260726T172607Z-2-005.zip
takeout-20260726T172607Z-2-006.zip
takeout-20260726T172607Z-2-007.zip
EOF
)
assert_eq "$GROUP_COUNT" "1" "same-day retry counts as one export group"

# Case 2: two exports on genuinely different days must still count as two.
GROUP_COUNT2=$(cat <<'EOF' | group_by_day | sort -u | wc -l
takeout-20260601T090000Z-001.zip
takeout-20260801T090000Z-001.zip
EOF
)
assert_eq "$GROUP_COUNT2" "2" "different-day exports count as two export groups"

# Regression test: the actual array that holds the grouped values in
# scripts/drive-backup.sh must NOT be named "GROUPS" — that's a bash
# special variable (the shell's own group-ID list). Assigning to it, even
# via `mapfile -t GROUPS < file`, silently fails (non-zero exit, array left
# unchanged) instead of actually loading the file's contents. An earlier
# version of this script used that name, misdiagnosed the resulting exit
# code as an unrelated "Bash 5.2 mapfile quirk", and papered over it with
# `|| true` — which hid the symptom but left the array populated with the
# shell's own group IDs instead of the real Takeout data. This test proves
# both halves of that story: the broken name silently fails, the fixed
# name (matching what scripts/drive-backup.sh actually uses) works cleanly.
printf 'a\nb\n' > /tmp/test_takeout_groups_$$.txt
BROKEN_EXIT=0
mapfile -t GROUPS < /tmp/test_takeout_groups_$$.txt || BROKEN_EXIT=$?
assert_eq "$BROKEN_EXIT" "1" "mapfile into the reserved name 'GROUPS' fails (exit 1) as expected — never use that name"

FIXED_EXIT=0
mapfile -t TAKEOUT_GROUPS < /tmp/test_takeout_groups_$$.txt || FIXED_EXIT=$?
assert_eq "$FIXED_EXIT" "0" "mapfile into 'TAKEOUT_GROUPS' (the name actually used in scripts/drive-backup.sh) succeeds"
assert_eq "${#TAKEOUT_GROUPS[@]}" "2" "mapfile into 'TAKEOUT_GROUPS' actually loads the file's 2 lines"
rm -f /tmp/test_takeout_groups_$$.txt

# Regression test: scripts/drive-backup.sh itself must not reintroduce the
# reserved name in its Takeout-cleanup section. Strip comment lines first —
# this file's own explanatory comment deliberately mentions the broken
# pattern as an example of what NOT to do.
if grep -vE '^\s*#' ../scripts/drive-backup.sh | grep -qE '(mapfile|readarray) +-t +GROUPS\b'; then
  echo "FAIL: scripts/drive-backup.sh reads into the reserved 'GROUPS' variable again"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "PASS: scripts/drive-backup.sh does not use the reserved 'GROUPS' variable name"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# The Takeout rule is one of the two deliberate exceptions to "never
# delete", and since 2026-10-28 it obeys the same second condition as
# scripts/prune-rolling-backups.sh: a group beyond TAKEOUT_KEEP is deleted
# only once Drive no longer has it. Deleting one Drive still holds would
# make the next `rclone copy` fetch tens of gigabytes straight back, on
# every run, for ever - and nothing would report a fault while it happened.
remote_still_has() {  # remote_still_has <group> <listing>
  printf '%s\n' "$2" | grep -q "^takeout-${1}T"
}

LISTING='takeout-20260726T172606Z-001.zip
takeout-20260726T172607Z-2-001.zip'
remote_still_has 20260726 "$LISTING" && r=yes || r=no
assert_eq "$r" "yes" "a group Drive still has is recognised, and must therefore be kept"
remote_still_has 20260601 "$LISTING" && r=yes || r=no
assert_eq "$r" "no" "a group Drive has dropped is free to delete"
# The literal T after the date is what stops a shorter date from matching a
# longer one and sparing a group for ever by accident.
remote_still_has 2026072 "$LISTING" && r=yes || r=no
assert_eq "$r" "no" "a partial date does not match a longer one"

# The guard has to stay wired in: without it the rule quietly goes back to
# deleting exports Drive still has, and the first symptom is a sync that
# transfers the same photo library every night.
if grep -vE '^\s*#' ../scripts/drive-backup.sh | grep -q 'TAKEOUT_REMOTE_LISTED'; then
  echo "PASS: the Takeout cleanup consults the source listing before deleting"
else
  echo "FAIL: the Takeout cleanup deletes without asking the source"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))

# And the fail-safe direction: a listing that could not be fetched must keep
# everything, not delete everything.
if grep -vE '^\s*#' ../scripts/drive-backup.sh | grep -q 'TAKEOUT_REMOTE_LISTED" -eq 0'; then
  echo "PASS: a source listing that failed keeps every local export"
else
  echo "FAIL: a failed source listing no longer protects the local exports"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))

assert_summary
