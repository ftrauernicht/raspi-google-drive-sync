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
- Run `shellcheck` on any changed script before opening a PR — the same
  check gates merging in CI.
- If you change the stall-watchdog, the takeout-grouping regex, or the
  auto-reboot cooldown logic, add/update the corresponding test under
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
- `systemd/drive-backup.service` / `.timer` — the daily schedule.
- `config.env.example` — every value a user needs to customize.
- `docs/architecture.md` — the "why" behind every non-obvious decision,
  including the real bugs found while testing.
- `docs/setup-guide.md` — step-by-step adoption guide + verification
  checklist.
- `tests/` — unit tests for the deterministic pure-logic pieces (Takeout
  grouping, stall detection, reboot cooldown math) that don't require real
  hardware to exercise.
- `.github/workflows/validate.yml` — CI (`shellcheck` + `tests/`), required
  by branch protection before merge.
