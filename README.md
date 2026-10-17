# raspi-google-drive-sync

[![Validate](https://github.com/ftrauernicht/raspi-google-drive-sync/actions/workflows/validate.yml/badge.svg)](https://github.com/ftrauernicht/raspi-google-drive-sync/actions/workflows/validate.yml)
[![Security](https://github.com/ftrauernicht/raspi-google-drive-sync/actions/workflows/security.yml/badge.svg)](https://github.com/ftrauernicht/raspi-google-drive-sync/actions/workflows/security.yml)
[![Link Check](https://github.com/ftrauernicht/raspi-google-drive-sync/actions/workflows/link-check.yml/badge.svg)](https://github.com/ftrauernicht/raspi-google-drive-sync/actions/workflows/link-check.yml)
[![License: MIT](https://img.shields.io/github/license/ftrauernicht/raspi-google-drive-sync)](LICENSE)

A local, self-healing backup of a Google Drive (+ Google Photos, via
Takeout) account onto a Raspberry Pi with two USB drives — built to run
unattended for years on genuinely weak, old hardware (originally a
single-core ARMv6 Pi 1 Model B with 512 MB RAM), not just a modern Pi 4/5.

## Why this exists

Insurance against the cloud account itself becoming unreachable or locked
out: a plain, unencrypted, uncompressed copy on disks you can plug into any
PC and read directly — no proprietary backup format, no vendor lock-in on
the restore side.

## Key design decisions

```
            Google Drive + Google Photos (cloud)
                             |
  read-only OAuth (drive.readonly) -- can never write back
                             v
             +--------------------------------+
             |          Raspberry Pi          |
             |    rclone copy (never sync)    |
             | + stall watchdog + auto-reboot |
             +--------------------------------+
                             |
                  mergerfs pool (not RAID)
                             |
   +--------------------------+-------------------------+
   |                          |                         |
   +-----------------------+    +-----------------------+
   |         Disk A        |    |         Disk B        |
   | plain files, readable |    | plain files, readable |
   |  standalone in any PC |    |  standalone in any PC |
   +-----------------------+    +-----------------------+

(each file lives entirely on ONE disk -- either drive keeps
 working standalone in any other computer if the Pi dies)
```

- **mergerfs pool, not RAID** — two drives merged into one pool, but every
  file lives entirely on a single physical disk. Either drive keeps working
  standalone in any other computer; no array to rebuild if the Pi itself
  dies.
- **Read-only Google Drive access** (`drive.readonly` OAuth scope) — this
  device can never write back to your Drive, even if its credentials leak.
- **Copy, never delete** (`rclone copy`, never `sync`) — nothing removed
  from Drive is ever removed from the backup. Verified in testing.
- **Self-healing.** A drive that briefly loses power and comes back under a
  different device name doesn't just get emailed about — the device
  attempts one automatic reboot first (proven to reliably fix that exact
  failure mode), and only asks a human to check the hardware if that
  doesn't help.
- **A stall watchdog that actually works.** rclone can hang indefinitely if
  a destination drive fails mid-write; this project polls rclone's live
  transfer stats (not log size) to detect *no progress*, kills the stuck
  process, and alerts — tested against both simulated and real physical
  drive failures mid-sync. Two real bugs found and fixed along the way are
  documented in [`docs/architecture.md`](docs/architecture.md).
- **A dead-man switch** for the case the Pi itself dies, with a `/start`
  signal so a legitimately multi-day initial sync never triggers a false
  alarm.

See [`docs/architecture.md`](docs/architecture.md) for the full reasoning
behind every one of these, including the separate-notification-account
rationale and the SD-card-wear-reduction notes.

## What breaks, and what happens

Every row here is a failure that produces no error of its own. That is the
whole reason the project exists in this shape: a backup that stops working
quietly is worse than no backup, because you only find out on the day you
need it.

| What goes wrong | How it is noticed | What happens |
|---|---|---|
| The backup pool is not mounted | Checked before anything else runs | One automatic reboot, which reliably fixes the known stale-mount case. Only if that did not help does a mail ask for a person. A six-hour cooldown stops a reboot loop on real hardware faults. |
| One of the two drives is missing | Same check | Same path as above |
| rclone stops making progress mid-write | rclone's live transfer stats are polled every 60 s. Not the log file, which keeps growing while the write side is dead, and not rclone's own `--timeout`, which covers the network side only | After 30 minutes without a byte and without a check, the process is killed and a mail goes out with the next steps |
| rclone exits with an error | Exit status | Mail with what to do about it |
| The Google Photos export has gone stale | Newest Takeout group older than 75 days | Reported, because a silently stopped export looks exactly like a finished one |
| Old Takeout exports pile up | More than two groups present | Everything but the newest two is pruned |
| The Pi itself dies | Nothing pings healthchecks.io at the end of a run | The external service raises the alarm. A `/start` signal at the beginning keeps a legitimately multi-day first sync from tripping it |
| The notification mail cannot be sent | msmtp exits non-zero | Logged, and the run still fails. Since a failed run never pings the dead-man switch, the silence itself becomes the alarm |
| An interrupted `dpkg` run stops all OS updates | Nothing — apt's daily script exits 0 and systemd calls it a success | Only the optional health checks see it ([`docs/monitoring.md`](docs/monitoring.md)), together with a filling pool, under-voltage and overheating between runs |

The deterministic parts of that are covered by [`tests/`](tests/): the stall
accounting, the reboot cooldown arithmetic, the Takeout grouping, and the
health-check decisions. The
reasoning behind each decision, including the two real bugs found while
building the stall watchdog, is in
[`docs/architecture.md`](docs/architecture.md).

## Setup

See [`docs/setup-guide.md`](docs/setup-guide.md) for the full step-by-step
guide, from flashing the SD card through the first multi-day sync, plus a
verification checklist worth actually running through rather than just
trusting.

The scripts live under [`scripts/`](scripts/), the systemd units under
[`systemd/`](systemd/). Copy [`config.env.example`](config.env.example) to
`config.env` and fill in your own values — nothing in this repo hardcodes a
real hostname, address, or credential; see `docs/architecture.md` if you're
wondering why a particular value is structured the way it is.

## Contributing

All changes land via Pull Request — direct pushes to `main` are blocked,
for everyone including the maintainer. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).

---

Another self-contained home-infrastructure project of mine:
[ha-sun-blind-automation](https://github.com/ftrauernicht/ha-sun-blind-automation)
(unrelated domain — Home Assistant blind automation, not backups — but the
same "generic, documented, testable template" approach).
