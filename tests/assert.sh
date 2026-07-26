#!/bin/bash
# Minimal assertion helpers shared by the test scripts in this directory.
# No test framework dependency on purpose — this is a small shell-script
# project, a couple of `assert_eq`/`assert_ne` calls are enough.

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $msg (expected '$expected', got '$actual')"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo "PASS: $msg"
  fi
}

assert_summary() {
  echo "--- $TESTS_RUN checks, $TESTS_FAILED failed ---"
  [ "$TESTS_FAILED" -eq 0 ]
}
