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
  04:00 — deliberately *after* the 03:00 daily sync window, so a reboot
  never kills a sync mid-run.
- A codename jump (e.g. to whatever Debian release eventually replaces the
  one you're on) never happens automatically — `apt`/`unattended-upgrades`
  never changes the configured suite/codename on their own.

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
