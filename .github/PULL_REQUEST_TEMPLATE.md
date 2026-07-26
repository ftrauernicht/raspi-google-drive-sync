## What does this PR change?

<!-- e.g. "Add a config option for the mail subject prefix", "Fix the stall watchdog's byte-parsing regex" -->

## Checklist

- [ ] I ran `shellcheck scripts/*.sh` and `bash tests/run.sh` locally and both passed
- [ ] No real hostnames, IPs, credentials, or personal details were added anywhere (scripts, docs, tests, commit messages)
- [ ] If I changed `scripts/*.sh`, I updated `docs/setup-guide.md` (and `docs/architecture.md` if the change affects the reasoning) in the same PR
- [ ] If I changed the stall-watchdog, Takeout-grouping, or reboot-cooldown logic, I added/updated a test under `tests/`
- [ ] I preserved `scripts/drive-backup.sh`'s test hooks (`WARN_85`, `WARN_95`, `EXTRA_RCLONE_FLAGS`, `STALL_MINUTES`, `STALL_CHECK_INTERVAL`, `REBOOT_CMD`, `AUTO_REBOOT_ENABLED`) rather than removing or bypassing them
