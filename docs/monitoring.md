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
| `sync` | last successful run ≥ 30 h ago | ≥ 54 h ago, or none in 14 days |
| `throttle` | under-voltage / capping / throttling **since boot** | the same **right now** |
| `temperature` | SoC ≥ 70 °C | ≥ 80 °C |
| `units` | — | any failed systemd unit |
| `updates` | a required reboot held back ≥ 48 h | unattended-upgrades not run in 48 h, or **an interrupted dpkg run** |

Every threshold is a variable at the top of the script and can be overridden
in `/etc/drive-backup/health.env`.

### Why `updates` looks at dpkg first

If a `dpkg` run is ever interrupted — power loss, out of memory, a reboot in
the middle of an upgrade — `apt-get check` fails from then on. The script
behind the apt timers, `/usr/lib/apt/apt.systemd.daily`, reacts to exactly
that by **exiting with status 0 without doing anything**. The timers keep
firing, systemd records every run as successful, and the device stops
receiving security updates without a single error anywhere.

This was found on a real device of this project after 39 days. The check
reads `/var/lib/dpkg/status` directly, because `apt-get check` and
`dpkg --audit` only see the problem when run as root. The fix is one command
as root: `dpkg --configure -a`.

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
