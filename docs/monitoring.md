# Monitoring the Pi from another machine (optional)

The backup already watches itself: every failure in the README's table ends
in a mail or in silence towards healthchecks.io. What that cannot see is the
state of the machine *between* runs — a slowly filling pool, a power supply
that browns out under USB load, or an update mechanism that quietly stopped.

[`scripts/health-check.sh`](../scripts/health-check.sh) makes that visible to
any monitoring system that speaks the Nagios plugin format (Icinga, Nagios,
Naemon, Checkmk, Zabbix with a plugin wrapper, …). It is read-only: it never
repairs, restarts or writes anything.

## The checks

| Check | WARNING | CRITICAL |
|---|---|---|
| `storage` | pool or a member disk ≥ 85 % full | ≥ 95 % full, or not mounted |
| `sync` | last successful run ≥ 30 h ago | ≥ 54 h ago, or none found at all |
| `throttle` | under-voltage / capping / throttling **since boot** | the same **right now** |
| `temperature` | SoC ≥ 70 °C | ≥ 80 °C |
| `units` | — | any failed systemd unit |
| `updates` | a required reboot held back ≥ 48 h | unattended-upgrades not run in 48 h, or **an interrupted dpkg run** |

Every threshold is a variable at the top of the script and can be overridden
in `/etc/drive-backup/health.env`. The most likely ones to need changing:

| Variable | Default | When to change it |
|---|---|---|
| `SYNC_SUCCESS_MARKER` | `=== Sync run finished successfully ===` | you translated the log messages |
| `SYNC_LOG` | `$POOL/logs/drive-backup.log` | your log lives elsewhere |
| `POOL`, `MEMBER_DISKS` | `/mnt/backup`, `/mnt/disk1 /mnt/disk2` | different mount points |

### Why `sync` reads the log file, and one rotated generation of it

`scripts/01-setup-os-hardening.sh` reduces SD-card wear, and part of that is
`Storage=volatile` for systemd-journald: the journal lives in RAM and starts
empty after every boot. A check that asks `journalctl` for the last successful
run therefore reports "nothing in 14 days" after an unattended reboot — while
the backup itself is perfectly healthy.

Observed on a real device: the Pi rebooted at 13:00 for a kernel update, and
the check went CRITICAL although the sync had finished successfully at 06:32
the same morning.

`drive-backup.sh` writes its own log to `$POOL/logs/drive-backup.log`, on the
storage pool rather than the SD card, so that file survives reboots. The check
reads it first and falls back to the journal only if the log is missing or
holds no success line. The output names which source it used.

Two details that matter when reading that file: it also carries rclone's
progress output, which contains control characters, so `grep` needs `-a` or it
treats the whole file as binary and silently matches nothing. And the
timestamp is the first 19 characters of the line, in local time.

A third one that only appears once the log is being rotated: `logrotate`
truncates the live file in place (`copytruncate`, because rclone holds it
open for the whole run), so immediately after a rotation the last success
line exists only in `drive-backup.log.1`. The check therefore reads that
generation as well, oldest first so the newest match still wins. Otherwise
the very false alarm described above comes back by a different route — an
empty live log plus a journal wiped by the last reboot, on a device that is
perfectly fine.

### Why `updates` looks at dpkg first

If a `dpkg` run is ever interrupted — power loss, out of memory, a reboot in
the middle of an upgrade — `apt-get check` fails from then on. The script
behind the apt timers, `/usr/lib/apt/apt.systemd.daily`, reacts to exactly
that by **exiting with status 0 without doing anything**. The timers keep
firing, systemd records every run as successful, and the device stops
receiving security updates without a single error anywhere.

This was found on a real device of this project after 39 days, and again
eight days after that repair. The check reads `/var/lib/dpkg/status`
directly, because `apt-get check` and `dpkg --audit` only see the problem
when run as root. The fix is one command as root: `dpkg --configure -a`.

Since then the device repairs this itself — `scripts/dpkg-repair.sh` runs
before every update attempt and mails what it did
([`architecture.md`](architecture.md) has the root cause, which turned out
to be the update window overlapping the backup window until the hardware
watchdog reset the board mid-`dpkg`). This check stays, for two reasons.
It is the outside view: if the self-repair itself stops working, or the
device cannot send mail at all, the monitor is what still says so. And it
covers the second half of the same question — not just "is dpkg healthy"
but "did `unattended-upgrades` actually run in the last 48 hours", which a
repair script cannot answer about itself.

## Setup: a forced-command SSH user

The monitoring machine connects over SSH as a dedicated user that can do
nothing except run this script. Replace the placeholders.

On the Pi, as root:

```bash
install -m 755 scripts/health-check.sh /usr/local/bin/health-check.sh

# A user without a password, allowed to read the journal (sync check) and
# to query the firmware (throttle check). Nothing else.
useradd --system --create-home --shell /bin/bash monitor
usermod -a -G systemd-journal,video monitor
passwd -l monitor

install -d -m 700 -o monitor -g monitor /home/monitor/.ssh
# One line: the forced command ignores whatever the client asks to run and
# hands it to the script as $SSH_ORIGINAL_COMMAND, which is matched against
# a fixed list of check names.
echo 'restrict,command="/usr/local/bin/health-check.sh" ssh-ed25519 AAAA...your-monitoring-key... monitor@your-monitoring-host' \
  > /home/monitor/.ssh/authorized_keys
chown monitor:monitor /home/monitor/.ssh/authorized_keys
chmod 600 /home/monitor/.ssh/authorized_keys
```

If you translated the log messages of `drive-backup.sh`, tell the sync check
what a successful run looks like:

```bash
install -d /etc/drive-backup
echo 'SYNC_SUCCESS_MARKER="=== your translated success line ==="' > /etc/drive-backup/health.env
```

From the monitoring machine:

```bash
ssh -i ~/.ssh/pi-monitor monitor@your-pi sync
# OK - last successful run 14 h ago (2026-01-01 06:52) | age=14h;30;54;0
```

## Icinga 2 example

The ITL already ships `by_ssh`:

```text
object Service "backup-sync" {
  host_name = "drive-backup-pi"
  check_command = "by_ssh"
  vars.by_ssh_logname = "monitor"
  vars.by_ssh_identity = "/var/lib/nagios/.ssh/pi-monitor"
  vars.by_ssh_command = "sync"
  check_interval = 30m
}
```

Use one service per check name. Keep the intervals modest — this is a
single-core ARMv6 board, and `updates` runs an `apt-get` simulation.
