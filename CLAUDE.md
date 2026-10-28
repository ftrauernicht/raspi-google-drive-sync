# CLAUDE.md

Guidance for Claude Code (or any AI coding agent) working in this repository.

## What this repo is

A reference implementation/template for a self-healing, unattended Google
Drive + Photos backup running on a Raspberry Pi, meant for other people to
adapt to their own hardware and Google account. The scripts are meant to be
copy-pasted and customized via `config.env`, not run against this repo's
own infrastructure.

## Hard rules

- **Never commit directly to `main`.** Always work on a branch and open a
  Pull Request. Branch protection enforces this for everyone including the
  repo owner — do not attempt to bypass it even if you technically have
  the access to do so.
- **Never hardcode real credentials, hostnames, IPs, or email addresses**
  anywhere in this repo — scripts, docs, examples, tests, commit messages.
  Everything sensitive is a placeholder or a `config.env` value. See
  `docs/architecture.md` for why (a real device's identity leaking here
  would defeat the whole point of a public template).
- Keep `docs/setup-guide.md` (and `docs/architecture.md`, where relevant)
  in sync with any change to `scripts/*.sh` in the same PR — this repo's
  only value is the docs matching the scripts exactly.
- Any example paths, folder names, or account details in docs/scripts must
  stay generic (e.g. `Documents/`, `Photos/`) — never a real person's real
  folder names or personal details.
- When changing `scripts/drive-backup.sh`, preserve the test hooks
  (`WARN_85`, `WARN_95`, `EXTRA_RCLONE_FLAGS`, `STALL_MINUTES`,
  `STALL_CHECK_INTERVAL`, `REBOOT_CMD`, `AUTO_REBOOT_ENABLED`) — they're
  what makes every failure branch safely testable against real hardware
  without triggering a multi-day sync or real mail spam. Don't remove or
  bypass them "for simplicity".
- Same for `scripts/dpkg-repair.sh` (`APT_CHECK_CMD`,
  `DPKG_CONFIGURE_CMD`, `COOLDOWN_HOURS`, `NOTIFY_COOLDOWN_HOURS`,
  `POSTPONE_MAX_HOURS`, `CMD_TIMEOUT`, `POOL`, `STATE_DIR`, `LOG_DIR`,
  `DPKG_STATUS`, `DPKG_UPDATES_DIR`, `BACKUP_UNIT`, `BACKUP_PATTERN`) —
  they're what lets every branch of an unattended repair be tested without
  breaking a real package database. `tests/test_dpkg_repair.sh` also stubs
  `systemctl`, `pgrep`, `mountpoint` and `msmtp` through `PATH`; keep it
  that way, or the tests start depending on what happens to run on the
  machine executing them.
- Same for `scripts/prune-rolling-backups.sh` (`POOL`, `LOCAL_ROOT`,
  `REMOTE`, `RULES_FILE`, `LOG_DIR`, `LOG_FILE`, `RCLONE_LSF_CMD`,
  `DRY_RUN`) and `PRUNE_SCRIPT` in `drive-backup.sh`. `RCLONE_LSF_CMD` is
  the important one: everything the retention rule knows about the source
  comes through it, which is what lets `tests/test_prune_rolling_backups.sh`
  exercise every branch — including an unreachable source — without a
  Google account.
- Same for `scripts/sample-conditions.sh` (`POOL`, `LOG_DIR`, `LOG_FILE`,
  `THERMAL_ZONE`, `LOADAVG`, `MEMINFO`, `UPTIME_FILE`,
  `SLOW_RUN_WARN_SECONDS`). The `/proc` paths are hooks on purpose:
  `tests/test_sample_conditions.sh` feeds fixtures through them and stubs
  `vcgencmd`, `pgrep` and `mountpoint` through `PATH`, so the expected
  output does not depend on the machine running the tests.
- **Deleting from the backup needs both conditions, always.**
  `scripts/prune-rolling-backups.sh` and the Takeout rule in
  `drive-backup.sh` are the only code here that deletes, and each deletes a
  copy only when it is (1) beyond its rule's keep count *and* (2) gone from
  the source. Condition 1 is what survives a wiped Drive; condition 2 is
  what stops `rclone copy` fetching the file straight back every night for
  ever. A failed source listing must delete nothing. Do not "simplify"
  either condition away, and keep
  `tests/test_prune_rolling_backups.sh` plus the Takeout checks in
  `tests/test_takeout_grouping.sh` covering both — the damage from getting
  this wrong is silent in both directions.
- **The update window must stay out of the backup window.** An update that
  configures packages while the sync is running starved PID 1 on real
  hardware until the watchdog reset the board mid-`dpkg`, twice, which
  silently ended all further updates. If you touch
  `systemd/drive-backup.timer`, the drop-in written by
  `scripts/01-setup-os-hardening.sh`, or the reboot time, keep all three
  apart and say so in `docs/architecture.md`.
- Run `shellcheck` on any changed script before opening a PR — the same
  check gates merging in CI.
- If you change the stall-watchdog, the takeout-grouping regex, the
  auto-reboot cooldown logic, or the dpkg-repair decisions (broken-package
  detection, cooldown, when a repair is attempted at all), add/update the
  corresponding test under
  `tests/` — these are exactly the pieces of pure logic that were
  originally validated by hand against real hardware failures and real
  Google Takeout output; keep them covered by an actual repeatable test
  instead of relying on manual verification again.

## Repo layout

- `scripts/01-setup-os-hardening.sh` — unattended-upgrades + SD-wear
  reduction.
- `scripts/02-setup-storage-pool.sh` — format + mergerfs pool setup.
- `scripts/03-setup-rclone-remote.sh` — read-only Google Drive OAuth setup.
- `scripts/04-setup-notifications.sh` — msmtp notification email setup.
- `scripts/drive-backup.sh` — the daily sync script (mount check, stall
  watchdog, auto-reboot, space/photo-freshness checks, dead-man-switch
  ping).
- `scripts/health-check.sh` — optional, read-only Nagios-format checks
  (storage, sync age, throttling, temperature, units, updates) for an
  external monitoring system; see `docs/monitoring.md`.
- `scripts/dpkg-repair.sh` — unattended repair of an interrupted dpkg run,
  wired in as `ExecStartPre` of `apt-daily-upgrade.service`. One attempt,
  then it mails and asks for a person; never while a sync is running.
- `scripts/sample-conditions.sh` — one line a minute to the pool (throttle
  bits, temperature, load, memory, which heavy job is running), because the
  journal is volatile and a reset would otherwise erase its own
  explanation.
- `scripts/prune-rolling-backups.sh` — retention for rolling full backups
  another device drops into Drive. Off unless
  `/etc/drive-backup/prune.rules` exists. Runs as step 2 of
  `drive-backup.sh`, before the space check.
- `systemd/drive-backup.service` / `.timer` — the daily schedule.
- `systemd/sample-conditions.service` / `.timer` — the condition log.
- `logrotate/drive-backup` — keeps the logs on the pool bounded.
- `config.env.example` — every value a user needs to customize.
- `docs/architecture.md` — the "why" behind every non-obvious decision,
  including the real bugs found while testing.
- `docs/setup-guide.md` — step-by-step adoption guide + verification
  checklist.
- `docs/monitoring.md` — optional external monitoring via `health-check.sh`.
- `tests/` — unit tests for the deterministic pure-logic pieces (Takeout
  grouping, stall detection, reboot cooldown math) that don't require real
  hardware to exercise.
- `.github/workflows/validate.yml` — CI (`shellcheck` + `tests/`), required
  by branch protection before merge.
