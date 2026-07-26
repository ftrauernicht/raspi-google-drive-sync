# Tests

Plain bash unit tests for the deterministic, pure-logic pieces of
`scripts/drive-backup.sh` that don't require real hardware to exercise —
Takeout export grouping, stall-detection accounting, and the auto-reboot
cooldown arithmetic. No test framework dependency; see `assert.sh` for the
handful of helpers used.

Run everything:

```bash
bash tests/run.sh
```

Run a single suite:

```bash
bash tests/test_takeout_grouping.sh
```

These are deliberately *not* a substitute for testing against real
hardware — see `docs/architecture.md` for what was actually verified
end-to-end (real drive failures mid-sync, real power loss, a real
automatic reboot). They exist to keep the small, easy-to-regress pieces of
logic (a regex, an arithmetic comparison, a variable name that happens to
collide with a bash builtin) covered by something that runs in CI on every
PR.
