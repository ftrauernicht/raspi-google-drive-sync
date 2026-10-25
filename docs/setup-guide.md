# Setup guide

Step-by-step guide to adopting this for your own Raspberry Pi and Google
account. Read [`docs/architecture.md`](architecture.md) first (or alongside)
for the reasoning behind each decision — this guide is the "how", that
document is the "why".

Copy [`config.env.example`](../config.env.example) to `config.env` and fill
in your own values as you go through the steps below; `config.env` is
gitignored, so your real values never get committed.

## Hardware assumptions

- Any Raspberry Pi that can run Raspberry Pi OS Lite. This project was
  originally built and tested on a first-generation **Raspberry Pi Model B**
  (single-core ARMv6, 512 MB RAM) — if it runs on that, it runs on anything
  newer. Adjust `--transfers`/`--checkers` in `scripts/drive-backup.sh` up
  if you have more RAM/CPU to spare.
- Two USB-attached drives in a dual-bay docking station with its own power
  supply (a Pi's own USB ports typically can't power two drives). Any two
  drives work; they don't need to be the same size or type.
- If your dock has a hardware clone/duplicate button: many dual-bay docks
  can offline-clone bay A onto bay B. An accidental press overwrites one of
  your backup drives completely. Physically disable it if possible (e.g.
  removing just the button cap so the switch underneath can't be pressed,
  then taping the housing) rather than relying on "I just won't press it".

## Step 1 — Install the OS headlessly

1. Flash **Raspberry Pi OS Lite** (32-bit if your board is ARMv6/ARMv7,
   64-bit for anything Pi 3 or newer) with Raspberry Pi Imager.
2. Before writing, open the advanced options (gear icon, or
   Ctrl+Shift+X/Cmd+Shift+X) and set: a hostname, a username + password for
   an initial setup account, and enable SSH. **Note:** current versions of
   Raspberry Pi Imager reject `root` as a username outright — use anything
   else (e.g. `setup`); you'll switch to root access in the next step.
   Leave the Wi-Fi fields empty if you're using Ethernet.
3. Boot the Pi, connect via `ssh <your-setup-user>@<hostname>.local`
   (Windows needs Bonjour/mDNS support installed for `.local` resolution;
   otherwise find the IP via your router's DHCP client list).
4. Optional: this project's scripts assume root SSH access on a LAN-only
   device, which is a deliberate deviation from the Debian/Raspberry Pi OS
   default (`PermitRootLogin no`). If you want that too:
   ```
   sudo passwd root
   sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
   sudo systemctl restart ssh
   ```
   Only do this on a device that's never exposed beyond your own LAN.
5. `sudo apt update && sudo apt full-upgrade`.

## Step 2 — OS hardening for long-term unattended operation

1. Copy [`scripts/dpkg-repair.sh`](../scripts/dpkg-repair.sh) to
   `/usr/local/bin/dpkg-repair.sh` and `chmod +x` it. Step 2's script wires
   it in as a pre-step of every update attempt, so it should be in place
   first. (If it isn't, nothing breaks — the hook is prefixed with `-` and
   simply does nothing — but you lose the self-repair.)
2. Run
   [`scripts/01-setup-os-hardening.sh`](../scripts/01-setup-os-hardening.sh)
   as root.

This sets up safe unattended upgrades, moves the update window out of the
backup window, hooks in the dpkg self-repair, and reduces SD card write
load. Read the script's comments and
[`docs/architecture.md`](architecture.md) — in particular, verify your
distro's actual package origins with `apt-cache policy` before trusting the
`Allowed-Origins` values baked into the script; they matched a specific
Raspberry Pi OS build at the time this was written and could differ for
you.

**If you change the backup schedule, change the update window with it.** An
update that configures packages while the sync is running is what reset one
real device mid-`dpkg`, twice, which silently stopped all further updates
(the full story is in [`architecture.md`](architecture.md)). The two
windows have to stay apart, and the sync is the one that can run for hours.

## Step 3 — Storage pool

1. Check your two drives' device paths: `lsblk -o NAME,SIZE,TYPE,TRAN,MODEL`.
2. Edit `DISK1_DEV`/`DISK2_DEV` at the top of
   [`scripts/02-setup-storage-pool.sh`](../scripts/02-setup-storage-pool.sh)
   to match, then run it as root. This formats both drives as ext4 and
   pools them with mergerfs at `/mnt/backup`.

## Step 4 — Google Drive access (read-only)

1. In the [Google Cloud Console](https://console.cloud.google.com/): create
   a project, enable the Google Drive API, create OAuth credentials of type
   "Desktop app".
2. Configure the OAuth consent screen: user type "External", fill in the
   required fields, and **publish it to production** (not "Testing" —
   Testing-mode tokens expire after 7 days). As an unverified app you'll see
   a "Google hasn't verified this app" warning during consent — that's
   expected for a personal-use app; click through it.
3. Install rclone (the official ARM binary from rclone.org tends to be more
   current than the distro package).
4. On a machine with a browser (not the Pi), run:
   ```
   rclone authorize "drive" --drive-scope drive.readonly "<CLIENT_ID>" "<CLIENT_SECRET>"
   ```
   Complete the browser login/consent; copy the printed token JSON.
5. On the Pi, follow
   [`scripts/03-setup-rclone-remote.sh`](../scripts/03-setup-rclone-remote.sh)
   to create the `gdrive` remote non-interactively with that token.
6. Verify: `rclone about gdrive:` and `rclone lsd gdrive: --max-depth 1`.

## Step 5 — Google Photos via Takeout

Google Photos isn't reachable via the Drive API for third-party tools
(Google restricted this in 2025) — the only remaining path to back it up is
a scheduled Google Takeout export straight into Drive, which this project's
sync then picks up automatically.

1. At [takeout.google.com](https://takeout.google.com): select only
   "Google Photos", destination "Add to Drive", frequency "Every 2 months
   for 1 year", archive size 10 GB or 50 GB.
2. This schedule **expires after a year** — `scripts/drive-backup.sh`
   already reminds you by email once the newest export it can find is
   older than `PHOTO_STALE_DAYS` (default 75), well before a full year
   elapses on a healthy schedule.
3. Exports count against your Drive storage quota (Photos content ends up
   twice: once in Photos itself, once as a Takeout archive in Drive). Older
   archives can be deleted from Drive once the Pi has backed them up — the
   backup pool keeps them regardless (per the never-delete principle), with
   its own separate cleanup rule keeping only the newest 2 export batches
   on the pool itself.

## Step 6 — Notification email

Follow
[`scripts/04-setup-notifications.sh`](../scripts/04-setup-notifications.sh)
and the notes in `config.env.example` and
[`docs/architecture.md`](architecture.md) (in particular: use a separate
Google account, not the one being backed up, and consider that account's
Inactive Account Manager settings).

The script sends **two** test mails, and the second one is the point: it is
addressed to `root`, the way the rest of the system addresses its own mail.
Without the `/etc/aliases` mapping the script installs, a real provider
rejects that with `553 ... <root> is not a valid RFC 5321 address`, and
everything reporting the Unix way — `apt-listchanges`, cron, `logrotate`,
`unattended-upgrades` — is quietly lost. Confirm both arrived, and check
`/var/log/msmtp.log` for two `exitcode=EX_OK` lines.

## Step 7 — The sync script and its schedule

1. Copy [`scripts/drive-backup.sh`](../scripts/drive-backup.sh) to
   `/usr/local/bin/drive-backup.sh` on the Pi, `chmod +x` it. Same for
   [`scripts/sample-conditions.sh`](../scripts/sample-conditions.sh), the
   one-line-a-minute condition log that explains the next unexplained
   reset (see [`architecture.md`](architecture.md)).
2. Install the [`systemd/`](../systemd/) unit files, then:
   ```
   systemctl daemon-reload
   systemctl enable --now drive-backup.timer
   systemctl enable --now sample-conditions.timer
   ```
3. Install [`logrotate/drive-backup`](../logrotate/drive-backup) as
   `/etc/logrotate.d/drive-backup`, so the logs on the pool stay bounded.
   Debian's daily `logrotate.timer` picks it up from there; check it with
   `logrotate --debug /etc/logrotate.d/drive-backup`.
4. Before trusting this in production, exercise the test hooks documented
   at the top of `drive-backup.sh` (`WARN_85`, `WARN_95`,
   `EXTRA_RCLONE_FLAGS`, `STALL_MINUTES`, `STALL_CHECK_INTERVAL`,
   `REBOOT_CMD`, `AUTO_REBOOT_ENABLED`) to safely exercise every branch —
   see [`docs/architecture.md`](architecture.md) for what was actually
   tested and how.

## Step 8 — Dead-man switch

1. Create a free check at [healthchecks.io](https://healthchecks.io).
   Suggested schedule: period 1 day, grace time 12 hours (generous, to
   account for the timer's randomized delay).
2. Put the ping URL in `/etc/drive-backup/healthcheck-url` (readable only by
   root: `chmod 600`).
3. `scripts/drive-backup.sh` already sends the `/start` signal at the
   beginning of a run and the completion ping at the end — see
   [`docs/architecture.md`](architecture.md) for why both matter.

## Step 9 — The initial sync

The first run copies everything currently in Drive — depending on how much
you have and your connection/CPU speed, this can realistically take
multiple days on weak hardware (e.g. an old Pi 1 on 100 Mbit LAN). That's
expected and by design: the stall watchdog only kills a run that shows *no
progress*, not one that's simply taking a long time (see
`docs/architecture.md`).

Consider triggering this first run manually and deliberately (rather than
letting the timer's next 03:00 slot start it unattended) so you can watch
it briefly and confirm it's actually making progress:
```
systemctl start --no-block drive-backup.service
```
This runs independent of your SSH session either way (it's a systemd
service, not a foreground shell job), so there's no need for `screen`/`tmux`
to survive a disconnect.

## Optional — external monitoring

If another machine on your LAN runs Icinga, Nagios or similar, install
`scripts/health-check.sh` and a forced-command SSH user as described in
[monitoring.md](monitoring.md). It adds what the backup cannot see about
itself between runs: pool fill level, under-voltage, temperature, failed
units, and whether OS updates are still being installed at all.

## Verification checklist

Before considering this "done", it's worth actually exercising these, not
just assuming they work:

- [ ] Fresh headless boot + SSH access works on the first try.
- [ ] A real file synced from Drive appears in the pool with correct
      content (and a Google-native Doc/Sheet arrives as `.docx`/`.xlsx`).
- [ ] Deleting a file from Drive does **not** remove it from the backup.
- [ ] Mail actually arrives for a storage-threshold warning (temporarily
      lower `WARN_85`/`WARN_95` to test, then reset).
- [ ] Pulling a drive mid-run: the sync fails cleanly with a mail, nothing
      gets corrupted.
- [ ] A single drive, disconnected and plugged into any other PC, is
      directly readable (it's plain ext4 with a subset of your files).
- [ ] Your first Takeout export lands in the backup automatically.
- [ ] The dead-man switch actually alerts if pings stop (temporarily shorten
      the healthchecks.io period/grace to confirm, then reset).
- [ ] A hard power cut recovers on its own after power returns.
- [ ] A mail addressed to `root` arrives (`printf 'Subject: t\n\nt\n' |
      msmtp root`). If it doesn't, every report the system writes about
      itself is being thrown away.
- [ ] The dpkg self-repair works end to end: `touch
      /etc/drive-backup/state/.dpkg-repair-attempted` is *not* the test —
      instead run `dpkg-repair.sh` with its hooks
      (`APT_CHECK_CMD=false DPKG_CONFIGURE_CMD=true /usr/local/bin/dpkg-repair.sh`)
      and confirm a mail arrives and `dpkg-repair.log` names what it tried.
- [ ] The update window and the backup window really are apart:
      `systemctl show -p TimersCalendar apt-daily-upgrade.timer` against
      `systemctl list-timers drive-backup.timer` and a look at how long
      your own runs actually take in `drive-backup.log`.
- [ ] The condition log is filling: `tail /mnt/backup/logs/conditions.log`
      shows a line a minute, and `busy=rclone` appears during a sync.
- [ ] Once a year: plug a drive into another PC and actually open a sample
      of files plus one Takeout archive, to confirm the backup is truly
      restorable, not just "present".
