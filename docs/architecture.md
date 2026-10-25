# Architecture and design rationale

This document explains the *why* behind every non-obvious decision in this
project, including the real bugs found and fixed while testing it against
actual hardware failures. If you're adapting this for your own setup, read
this before changing any of the defaults.

## Why a weak, old Raspberry Pi at all?

The point of this project is a cheap, always-on, physically-local backup of
a Google account — insurance against the cloud account itself becoming
unreachable or getting locked out, not a performance system. An old
single-core ARMv6 board with 512 MB RAM is genuinely sufficient for
"trickle-copy a few GB a day"; the constraints it imposes (weak CPU, slow
100 Mbit LAN, worn-out SD card as the only "always was going to fail
eventually" component) are exactly what shaped most of the decisions below.

## Why mergerfs instead of RAID

Two drives are pooled with [mergerfs](https://github.com/trapexit/mergerfs)
using the `mfs` (most-free-space) create policy, **not** RAID 0/1 and not
LVM. Every file lives entirely on one physical disk. The trade-off this
buys: either drive can be pulled out and plugged into any ordinary PC, and
the files on it are directly readable — no RAID controller, no array
metadata, no rebuild. For a home backup meant to survive "the Pi itself is
now also broken", that property matters more than the extra capacity
efficiency or redundancy RAID would give you. `moveonenospc=true` lets
mergerfs relocate a file to the other branch if the chosen one fills up
mid-write, and `minfreespace=10G` keeps a safety margin per branch.

## Why `rclone copy`, never `rclone sync`, and why the OAuth scope is `drive.readonly`

The entire backup strategy is **additive only**: nothing is ever deleted
from the backup, even if it's deleted from Drive. That's `rclone copy`'s
actual behavior (verified in testing: delete the source, run copy again,
the destination copy is untouched) — `rclone sync` would instead mirror
deletions.

The Google OAuth client is scoped to `drive.readonly`. The device never
needs to write back to Drive, so it never gets permission to. Consequences
worth knowing:
- Even a fully leaked client secret + refresh token only grants read access.
- Google refresh tokens expire if unused for 6 months — irrelevant here
  since the daily sync exercises the token constantly.
- Publishing the OAuth consent screen as "In production" (rather than
  leaving it in "Testing") is required — Testing-mode refresh tokens expire
  after 7 days regardless of use. An unverified production app is capped at
  100 users, which is a non-issue for a single-account personal tool.

### A note on `--drive-acknowledge-abuse`

Google flags some files as malware/spam and refuses to serve them without
this flag, regardless of read-only scope. The default here is to set the
flag and back them up anyway: this is a **personal backup of files the
account owner already possesses**, not a public file-sharing surface, and
Google's automated scanner can and does flag legitimate old files (compiled
`.exe`/`.dll` binaries from personal dev projects, old archives) as a false
positive. Skipping the flag instead means those files — and any destination
directory whose *entire* contents were skipped files — are silently absent
from the backup, which defeats the point of a backup tool for exactly the
files someone is least likely to remember to check for. If you'd rather not
acknowledge Google's abuse flag automatically, drop `--drive-acknowledge-abuse`
from `scripts/drive-backup.sh` — the sync still works, it just skips those
files (and logs a `cannotDownloadAbusiveFile` error for each one, every run,
for as long as they remain flagged).

## Why a separate Gmail account for notifications

The notification emails are sent from a **dedicated** Google account,
deliberately decoupled from the Google account being backed up. Two
independent reasons:

1. If the backed-up account itself becomes locked or inaccessible (the
   exact scenario this whole project exists to protect against), you don't
   want your alerting channel to go down with it.
2. Google deletes personal accounts after **2 years of inactivity**, and
   "activity" is explicitly defined as something done *while signed in* —
   Google's own documentation states that simply receiving mail doesn't
   count, and sending mail via an automated SMTP app-password session isn't
   officially confirmed to count either. A notification-only account that's
   never logged into interactively risks being auto-deleted years down the
   line, silently breaking your alerting.

   Mitigation: configure that account's **Inactive Account Manager**
   (`myaccount.google.com/inactive`) with a ~6–12 month timeout and the
   action set to "notify only", pointed at your real address. This doesn't
   generate real activity, but it automates the *reminder* to go log in and
   read something once a year — bundle that with an annual restore drill
   (see the setup guide's verification checklist).

Since May 2025, Google requires either an App Password (which itself
requires 2-Step Verification) or OAuth for SMTP — a plain account password
no longer works at all, confirmed while setting this up.

## SD card wear reduction

An SD card under constant write load is the most likely single point of
failure for a long-running Pi appliance, so:

- `noatime` on the root filesystem (often already the vendor default —
  check before assuming you need to add it).
- `systemd-journald` set to `Storage=volatile` with a `RuntimeMaxUse` cap —
  logs live in RAM only; this script's own logs go to the USB backup pool
  instead of the SD card.
- No `rsyslog` — avoids duplicate plain-text logging alongside journald.
- `man-db.timer` disabled — a periodic reindex of man pages that a headless
  single-purpose device will never use.

**Don't disable `rpi-zram-writeback.timer`.** It's tempting to see "a timer
that periodically writes to the SD card" and turn it off for wear reasons —
resist that. Per `man 5 swap.conf`, this mechanism only writes genuinely
idle zram (compressed RAM swap) pages back to a disk-backed file, and the
vendor documentation states this *reduces* SD wear compared to the
alternative (the kernel having to reclaim memory more aggressively under
real pressure). This was checked deliberately during testing — it stays on.

## Unattended upgrades, tuned for "runs for years, nobody's watching"

Raspberry Pi OS ("Raspbian") does not have a separate `-security` suite the
way plain Debian does — both configured package origins are a mixed
security+feature stream under a single `stable` suite. Because of that:

- `Allowed-Origins` explicitly lists both real repo origins (verify yours
  with `apt-cache policy` — don't assume the values in this repo's script
  match your image).
- Automatic package/kernel removal is disabled, so `unattended-upgrades`
  never prunes something this project manually installed (mergerfs, rclone
  dependencies) as "unused".
- Automatic reboots (when a kernel update needs one) are scheduled for
  13:00 — far away from the 03:00 daily sync window. The first version
  used 04:00, and a large sync that was still running at 04:00 was killed
  by the reboot (see the comment in `scripts/01-setup-os-hardening.sh`).
- The update window itself is moved to 20:00 (+30 min random), away from
  both the sync and the reboot time. That one is not about tidiness; it is
  the fix for the failure described next.
- A codename jump (e.g. to whatever Debian release eventually replaces the
  one you're on) never happens automatically — `apt`/`unattended-upgrades`
  never changes the configured suite/codename on their own.

### The trap: an interrupted dpkg run silently ends all updates

If a `dpkg` run is ever interrupted, `apt-get check` fails from then on,
and `/usr/lib/apt/apt.systemd.daily` answers that by exiting with status 0
without doing anything. The apt timers keep firing and systemd records
every run as a success. On a real device of this project that went
unnoticed for 39 days. The optional health checks catch it — see
[monitoring.md](monitoring.md).

### Why dpkg got interrupted in the first place: the watchdog

The 39-day outage above was repaired by hand, and eight days later the same
device was interrupted again. Twice in eight days is not bad luck, so the
second time the logs were read instead of just the symptom being cleared.
Both incidents have the same signature:

```
Log started: 2026-09-09  06:19:29        Log started: 2026-10-24  06:15:15
  Setting up raspberrypi-sys-mods ...      Setting up rpi-eeprom ...
  [file ends — no "Log ended"]             [file ends — no "Log ended"]
```

In the second case `uptime -s` puts the next boot at 06:16:46 — about one
minute after the configure step began. One minute is exactly what Raspberry
Pi OS gives systemd to pet the hardware watchdog:

```
RuntimeWatchdogSec=1m
  from /usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf
```

So the board was reset mid-`dpkg` by the BCM2835 watchdog, because PID 1
did not get scheduled for a full minute. A hard reset leaves exactly the
observed state: a half-configured package, a pending trigger, no log line,
no mail.

What starved PID 1 was the project's own backup. The daily sync starts at
03:00 and runs for three to nine hours; the shipped update window is 06:00
plus up to 60 minutes of random delay, so the two overlapped **every single
day**. Light maintainer scripts survive that competition — `cifs-utils` in
36 s, `ca-certificates` in 3 minutes — but the two that didn't were the
expensive ones: an initramfs rebuild, and a
`dpkg-maintscript-helper dir_to_symlink` conversion over a 41 MB firmware
tree plus the `man-db` trigger. For scale: the same configure work, run on
an idle machine afterwards, finished in **43 seconds**.

Hence two changes, in this order of importance:

1. **Keep the windows apart.** `apt-daily-upgrade.timer` gets a drop-in
   putting it at 20:00 (+30 min), where neither a sync nor the automatic
   reboot runs. This addresses the cause; everything below is about
   surviving it anyway.
2. **Repair it unattended.** `scripts/dpkg-repair.sh` runs as
   `ExecStartPre=-` of `apt-daily-upgrade.service`, so every update attempt
   — including the catch-up run after a boot — first checks `apt-get check`
   and, if it fails, runs one `dpkg --configure -a` and mails what it did.
   If that doesn't fix it, it says so and asks for a person. Every mail it
   can send is capped at one per 24 hours, because the thing being reported
   is invisible by design and must not be buried under a daily retry
   either.

Four details of that script are less obvious than they look, and each one
is there because the straightforward version was wrong:

- **"Is a backup running?" cannot be asked with `systemctl is-active`.**
  `drive-backup.service` is `Type=oneshot` with `RemainAfterExit=no`, so
  for the entire duration of a run its state is `activating`, and
  `is-active --quiet` exits 3 — measured on the device, not assumed. A
  check written that way sees an idle machine throughout a nine-hour sync
  and goes ahead with the configure run: exactly the collision that caused
  all of this. The script asks for `ActiveState` and accepts `activating`,
  and additionally matches the process name, which also catches a run
  started by hand with no unit at all.
- **Postponing cannot be silent forever.** A first sync legitimately runs
  for days, and a repair postponed every day for a week with only a log
  line to show for it reproduces the original 39-day outage in slow motion.
  After `POSTPONE_MAX_HOURS` (48 by default) a mail goes out anyway,
  explaining that nothing was repaired *because* a backup kept running.
- **A lock held by another apt is not a broken dpkg.** `apt-get check`
  itself does not take the dpkg lock (verified by holding
  `/var/lib/dpkg/lock-frontend` and running it), but `dpkg --configure -a`
  does. A concurrent `apt-daily` download run would therefore turn into a
  mail claiming the repair failed, and burn the retry cooldown on a healthy
  machine. Lock messages are recognised and the run simply retries next
  time.
- **"No package named" means two opposite things.** `apt-get check` fails
  both on an interrupted run and on unmet dependencies, and in the first
  case the status file may name nothing. The distinguishing evidence is
  whether `/var/lib/dpkg/updates/` holds records: with them it is the plain
  case and a configure run does fix it, without them it does not. The mail
  says which, and quotes `apt-get check`'s own output, because that is the
  authoritative error and the earlier version threw it away.

Deliberately *not* done: disabling the `man-db` trigger via
`/etc/dpkg/dpkg.cfg.d/01_nodoc`. That was the cheap fix on the table, and
it treats the symptom — the next expensive maintainer script would reset
the board just the same.

Still open on that device, and the reason for the condition log below:
whether the reset came from the watchdog or from a brown-out under load.
`vcgencmd get_throttled` only reports the state *now*, and a reset clears
its sticky bits, so after the fact the two are indistinguishable.

### The condition log: a flight recorder, because the journal is volatile

`health-check.sh` answers "is this device healthy right now", which is the
right question for a monitor and the wrong one after an unexplained reset.
This project deliberately keeps the journal in RAM to spare the SD card
(see below), so a reboot erases the kernel's own account of what happened.
That is what made the incident above take an afternoon of log archaeology
instead of one lookup.

`scripts/sample-conditions.sh` writes one line a minute to the pool:

```
2026-10-25 15:30:10 up=123456.78 throttled=0x0 temp=43.3 load=1.30 memavail=306M swapfree=393M busy=none
```

The last line before a gap in that file is the state just before the
machine went down: `throttled` other than `0x0` points at the power
supply, while `0x0` at high load and low free memory points at starvation,
i.e. the watchdog. `busy=` is the deciding column — it distinguishes "idle
box browned out" from "sync and package configure ran into each other".

`up=` is there because the wall clock cannot be trusted across the very
event this file exists to explain. There is no RTC on this board, so after
a hard reset the clock is whatever `fake-hwclock` last saved until NTP
steps it — which can make the first line *after* a reset look older than
the last line before it, and "the last line before the gap" then means
nothing. Uptime going backwards is clock-independent proof of a restart,
and it also makes the length of the gap readable.

Three details that matter more than they look:

- It writes to the **pool**, never the SD card, and runs with `Nice=10` and
  `IOSchedulingClass=idle`. A recorder that contributes to the load it is
  supposed to measure is worse than none.
- It calls `sync -d` on its own log file afterwards. Without that, the last
  few lines before a hard reset — the only ones that matter — can still be
  sitting in the page cache. `sync -d <file>`, not a bare `sync`, so the SD
  card isn't flushed along with it.
- Its unit sets `LogLevelMax=warning`, which is not tidiness either. At the
  default level, a per-minute oneshot unit writes a "Starting", a
  "Deactivated", a "Finished" and a "Consumed … CPU time" line every time:
  212 journal lines in 55 minutes when it was measured, about 5800 a day.
  The journal here is in RAM and capped at 20 MB, so that noise alone
  evicts everything worth having within hours — a recorder that destroys
  the other evidence is a bad trade. It also sets `TimeoutStartSec=30`,
  because a oneshot service has no start timeout by default and
  `OnUnitActiveSec=` does not re-arm while the unit is still running: a
  `vcgencmd` blocked on a wedged mailbox would otherwise stop the recording
  silently and for good.

One line a minute is roughly 55 MB a year, which is why there is now also a
`logrotate` config.

### Nothing may grow without bound

`logrotate/drive-backup` caps every log on the pool at 20 MB with four
generations. Three details are deliberate:

- **`copytruncate`**, not `create`: rclone holds its `--log-file` open for
  the whole run, which can be days on the first sync. A plain rename would
  leave it writing into the rotated inode while the live log stays empty.
- **`nocompress`**: gzipping a 20 MB file on a single-core ARMv6 board is a
  minutes-long CPU spike, and a CPU spike competing with a backup run is
  precisely the failure described above. On a pool with terabytes free,
  space is the cheap resource and CPU is not.
- **Size, not time**: a weekly rotation would cut the sync log into pieces
  that each cover part of a run, which is what makes a long incident hard
  to read afterwards.

Rotation has one consequence worth spelling out, because it would otherwise
undo the fix in `health-check.sh`: right after a rotation the live log is
empty, so the last "finished successfully" line exists only in
`drive-backup.log.1`. The `sync` check therefore reads one rotated
generation as well, oldest first so the newest match still wins. Without
that it would fall through to the journal — volatile here — and report "no
successful run" on a perfectly healthy device, which is the exact false
alarm that check was rewritten to end.

### Mail addressed to `root` has to go somewhere real

Everything on a Debian box that reports by mail the Unix way —
`apt-listchanges`, cron, `logrotate`, `unattended-upgrades` — addresses
`root`, and a real SMTP provider rejects that outright:

```
553-5.1.3 The recipient address <root> is not a valid RFC 5321 address
```

On the device this was written for, that had been happening unnoticed: the
only trace is a single line in `/var/log/msmtp.log`. So `msmtprc` gets an
`aliases /etc/aliases` line and `/etc/aliases` maps both `root` and
`default` to the real recipient. The backup script's own mails never went
through that path — it addresses recipients directly — which is exactly why
nobody noticed the other channel was dead.

## The stall watchdog, and the two real bugs found while building it

The daily sync script wraps the `rclone copy` call with a watchdog loop
that polls rclone's own `--rc` live-stats HTTP interface (`/core/stats`,
the real cumulative `bytes` field — not log-file size, which for a single
large file only grows on completion and would misclassify a legitimately
long transfer as stalled) every `STALL_CHECK_INTERVAL` seconds. If the byte
count hasn't moved for `STALL_MINUTES`, the process is killed and a
specific error mail is sent. This is deliberately a *stall* detector, not a
fixed total-duration timeout — a hard timeout would eventually kill the
legitimately multi-day initial sync.

This exists because of a real, reproduced failure mode: when a destination
USB drive disappears mid-write (power loss to the dock, or a cable fault),
rclone can hang indefinitely — 8+ minutes and counting, never recovering on
its own, in testing. rclone's own `--timeout` flag only governs
network/source stalls, not local write failures at the destination.

Two real bugs surfaced while testing this against an actual simulated (and
then a real physical) drive failure mid-sync:

1. **`log()`'s own write can crash the error handler.** The script's
   logging function writes to a log file that lives on the same pool that
   just failed. When that write fails, `tee` returns a non-zero exit code —
   under `set -e`, that aborted the *entire script* at the very log line
   meant to report the problem, before the process-killing/mail-sending
   logic ever ran. Fixed by making the log write itself failure-tolerant
   (`|| true`). Without this fix, the watchdog would detect the stall but
   never actually act on it.
2. **`GROUPS` is a bash special variable — don't use it as a regular array
   name.** The Takeout-cleanup step originally read the grouped export
   names into an array called `GROUPS`. `GROUPS` is bash's own builtin
   variable holding the shell's group-ID list; assigning to it — even via
   `mapfile -t GROUPS < file` — silently fails (non-zero exit) *and leaves
   the array unchanged*, i.e. it does not actually load the file's data at
   all. This was first misdiagnosed as a generic "`mapfile` returns exit
   code 1 on some Bash 5.2 builds even though it read the data correctly"
   quirk and papered over with `|| true` — which silenced the exit code but
   left the array populated with the shell's own group IDs instead of the
   real Takeout data, meaning the retention logic was operating on the
   wrong information (see `tests/test_takeout_grouping.sh`, which
   reproduces both the broken and the fixed behavior directly). The actual
   fix was renaming the array to `TAKEOUT_GROUPS`, after which no `|| true`
   is needed at all — it's a real, unrelated-to-Bash-version bug, not a
   version quirk to work around.

After both fixes, the failure path was verified end-to-end multiple times:
twice via a software-simulated USB disconnect (`echo 0 >
/sys/bus/usb/devices/<bus-id>/authorized`, which reproduces the kernel-level
effect of a real unplug — unlike a graceful `mount -o remount,ro`, which the
kernel refuses with "mount point is busy" while a write is actually in
flight), and once via physically cutting power to the dock mid-transfer.
All three runs: stall detected within roughly the configured window, rclone
process confirmed killed, correct specific error mail delivered, no
orphaned processes left behind.

**Known residual risk:** in rare cases a process can sit briefly in the
kernel's uninterruptible "D state" — immune to every signal, including
`SIGKILL`, until the underlying I/O operation itself times out at the
driver level. This was observed once before the fixes above and did not
reproduce afterward. If it ever happens in practice, the dead-man switch
(below) is the final safety net: if a run genuinely never completes, no
"/start"-scoped ping arrives, and healthchecks.io eventually alerts anyway
— just without the specific diagnosis.

**A real false positive, found by the actual initial sync itself:** after
running for 4.5 days, the initial sync's data transfer genuinely finished —
0 bytes left to move. rclone then spent 30+ minutes purely *verifying*
roughly 280,000 already-copied files against the source (pure CPU work, no
new bytes). The watchdog, watching only `bytes`, misread that as a stall
and killed a fully-successful run — twice in a row, because the queued
daily-timer run immediately took over (per the overlap protection above)
and hit the exact same wall. Fix: the watchdog now also polls the `checks`
field from `/core/stats` and only treats a run as stalled when **neither**
`bytes` **nor** `checks` has moved for `STALL_MINUTES`. General lesson: a
watchdog for a multi-phase job needs to watch every phase's own progress
signal, not just the one that happens to dominate most of the run.

**A worse bug introduced by the fix above:** the new line that fetches
`/core/stats` was missing its own `|| true`, unlike the two field-extraction
lines right below it. Under `set -e`, a single failed `curl` call (exit 7,
"couldn't connect" — plausible right as rclone's RC server is shutting down
at the very end of a run) killed the **entire script instantly and
silently**: no error mail, no log line, nothing — worse than the bug it was
meant to fix. Found in production: a real run finished 2.5 hours of
verification work on ~900k files and then simply vanished. Fixed by adding
the missing `|| true`, reproduced in isolation first (the unpatched line
provably dies silently on a real connection failure; the patched one
survives), and guarded with a static test that greps the script for the
fallback rather than relying on remembering it. General lesson: when a fix
touches error-handling-sensitive code under `set -e`, every new command
substitution needs the same defensive pattern as its neighbors — "add one
line, forget the safety net on it" is an easy way to make a watchdog fix
introduce a worse, fully silent failure mode.

## Deploying a script update while a run might be in progress

Updating `drive-backup.sh` looks harmless — copy the new version over the
old one, done. But this script's own runs can last for days (the initial
sync), so "copy the new version over the old one" can happen *while an
instance of the old version is still executing*.

That interacts badly with how the shell reads a script file. Bash doesn't
necessarily slurp an entire long script into memory up front — for a script
that runs for hours, it re-reads chunks from the file as execution reaches
them. If the file's contents on disk change underneath a running process —
different byte offsets because lines were added or edited — the interpreter's
read position loses its correspondence to the new content. The running
process doesn't error out cleanly; it starts parsing garbage from whatever
byte offset it lands on next, producing confusing, unrelated-looking syntax
errors (e.g. a stray `break: only meaningful in a 'for', 'while', or 'until'
loop` followed by `syntax error near unexpected token 'fi'`) instead of a
clean failure. `bash -n` on the file — before *or* after the edit — reports
no problem at all, because both versions are individually valid; the defect
only exists in the act of swapping one for the other mid-execution.

This happened in production: a script update was copied directly onto
`/usr/local/bin/drive-backup.sh` while the previous day's run was still in
its watchdog loop. The running process hit exactly this failure a couple of
hours later, exiting with a cryptic status instead of a clean error report.

**The fix is to never overwrite the live file in place.** Deploy by writing
the new version to a temporary file *in the same directory* (so it's on the
same filesystem — `/tmp` is commonly a separate `tmpfs` mount, which would
make the next step non-atomic), verify it with `bash -n`, then `mv` it over
the target path:

```sh
scp drive-backup.sh pi-host:/usr/local/bin/.drive-backup.sh.new
ssh pi-host '
  bash -n /usr/local/bin/.drive-backup.sh.new &&
  chmod +x /usr/local/bin/.drive-backup.sh.new &&
  mv -f /usr/local/bin/.drive-backup.sh.new /usr/local/bin/drive-backup.sh
'
```

A rename within the same filesystem is atomic: a process that already has
the old file open keeps reading its old inode undisturbed to completion,
while any new invocation resolves the filename to the new inode from that
point on. It's also worth checking `ps aux | grep drive-backup.sh` before
deploying, but the atomic-rename pattern is what actually makes the update
safe regardless — it doesn't depend on remembering to check.

## Automatic reboot on mount problems, with a cooldown

A drive that loses and regains power mid-run does **not** self-heal: it can
come back under a new kernel device name (e.g. `sdc` instead of `sdb`),
leaving the old mount points stale — verified repeatedly in testing. A
reboot reliably fixes this (also verified). So rather than a mount-check
failure immediately asking a human to intervene, the script attempts
**one** automatic reboot first, tracked with a marker file. If the same
failure recurs within `REBOOT_COOLDOWN_HOURS` (default 6h), it does *not*
reboot again — at that point it's more likely a genuine hardware fault than
a transient stale-mount state, so it asks for a manual check instead. The
marker clears itself automatically the next time a mount check succeeds.

This was tested through all four relevant scenarios: first failure (reboot
attempted), immediate repeat failure (no second reboot, escalates to a
manual-check mail instead), problem resolved (marker clears on the next
successful run), and — critically — an actual full reboot cycle with the
real `reboot` command (not a test stub), confirming the device really does
come back up cleanly and remount everything on its own.

## The dead-man switch, and its `/start` signal

A local error mail is useless if the device itself has died (dead SD card,
failed power supply, etc.) — there's nothing left to send the mail. A free
[healthchecks.io](https://healthchecks.io) check is pinged after every
successful run; if no ping arrives within the configured period + grace
time, healthchecks.io alerts on its own, independent of anything running on
the device.

One easy-to-miss subtlety: the daily script only pings on **success**, at
the very end. A legitimately long run (the multi-day initial sync, or any
unusually slow day) would otherwise exceed the grace period and trigger a
false alarm. Sending healthchecks.io's `/start` signal right after the
mount check passes helps, but **does not pause detection indefinitely** —
we initially assumed it did, and got a real false alarm ~14 hours into the
actual initial sync as a result. What `/start` actually does: healthchecks.io
expects the final "success" ping within the **configured Grace Time**,
counted from the `/start` timestamp, not from the last successful run. With
Grace Time set to 12h (correct for the few-minutes-long daily runs), a
multi-day initial sync blows straight through it and triggers exactly the
alarm the switch is supposed to avoid.

**Practical fix during the initial sync:** raise Grace Time manually (up to
365 days is allowed) for its duration, then set it back to a normal value
(e.g. 12h) once daily incremental runs take over. A cleaner fix — detecting
the very first run (empty backup target) and setting a longer Grace Time via
the healthchecks.io API automatically, then reverting it — is a natural next
step but not implemented yet.

## systemd timer instead of cron

A daily `systemd` timer runs the sync, not cron — deliberately. systemd
will not start a second instance of the same unit while one is already
active: verified in testing by starting the service, then issuing a second
`systemctl start` mid-run — no second process spawned, the second call just
attached to the same running job. This matters because the initial sync
can legitimately take days; cron would happily spawn a second, overlapping
copy of the same job every day it's still running.
