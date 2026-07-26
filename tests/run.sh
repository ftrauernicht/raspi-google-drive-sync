#!/bin/bash
# Runs every test_*.sh in this directory and reports overall pass/fail.
# No test framework dependency — plain bash, see assert.sh.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

OVERALL=0
for test_file in test_*.sh; do
  echo "=== $test_file ==="
  if ! bash "$test_file"; then
    OVERALL=1
  fi
  echo
done

if [ "$OVERALL" -eq 0 ]; then
  echo "All test suites passed."
else
  echo "One or more test suites failed."
fi
exit "$OVERALL"
