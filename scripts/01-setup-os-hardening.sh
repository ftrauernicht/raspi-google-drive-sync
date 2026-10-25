#!/bin/bash
# Long-term OS hardening for an unattended Raspberry Pi OS (Debian-based)
# appliance: safe automatic updates, and SD-card wear reduction.
#
# Tested on: Raspberry Pi OS Lite 32-bit ("Raspbian"), Debian 13 "trixie".
set -e

echo "=== Installing unattended-upgrades ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades

# Raspberry Pi OS ("Raspbian") does NOT have a separate "-security" suite
# like plain Debian does — both configured repos are mixed security+feature
# updates in a single "stable" suite. Confirm the actual Origin/Suite for
# your repos before relying on this (`apt-cache policy`, or inspect the
# Release files under /var/lib/apt/lists/) — the values below matched a
# fresh Raspberry Pi OS Lite install as of mid-2026.
cat > /etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
// Local override, kept separate from the package-shipped 50unattended-upgrades
// so it survives package upgrades cleanly.
Unattended-Upgrade::Allowed-Origins {
    "Raspbian:stable";
    "Raspberry Pi Foundation:stable";
};

// Never remove "unused" packages/kernels automatically — protects manually
// installed packages (mergerfs, rclone dependencies) from being pruned.
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";

// Only reboot when actually required (kernel update), at a fixed time far
// enough away from the daily backup sync window (03:00 + up to 15min random
// offset, see systemd/drive-backup.timer) that a reboot never kills a sync
// mid-run. An earlier version of this used "04:00" (just one hour of
// margin) on the assumption that daily delta syncs are quick — that broke
// in practice: a run with one large newly-added file took nearly an hour
// and was still 94% done when the 04:00 reboot killed it outright. Pick a
// time with a wide margin instead of a tight one tied to typical-case
// duration.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "13:00";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "=== Keeping updates out of the backup window ==="
# This is not a tidiness preference, it is the fix for the worst failure
# mode this device had. The shipped schedule is 06:00 with up to 60 minutes
# of random delay; the daily sync starts at 03:00 and takes hours, so the
# two overlapped every single day. Twice, the overlap hit the configure
# phase of a package with expensive maintainer scripts (an initramfs
# rebuild, a directory-to-symlink conversion over a 41 MB firmware tree,
# plus the man-db trigger) and the board reset mid-dpkg: on this hardware
# systemd arms the BCM2835 watchdog with RuntimeWatchdogSec=1m, and under
# that much competition for one ARMv6 core, PID 1 misses its deadline. The
# result is an interrupted dpkg run, which silently ends all further
# updates. Measured afterwards: the same configure work took 43 seconds on
# an idle machine.
#
# So: put the update window where nothing else runs. Keep it away from
# Automatic-Reboot-Time as well, so an update and the reboot it asks for
# are not the same busy minute.
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/10-outside-backup-window.conf <<'EOF'
# The empty OnCalendar= is required: it clears the package default,
# otherwise the timer fires at both times.
[Timer]
OnCalendar=
OnCalendar=*-*-* 20:00
RandomizedDelaySec=30m
EOF

# Second half of the same fix: repair an interrupted dpkg run before each
# update attempt instead of waiting for a human or an external monitor to
# notice that updates stopped. "-" prefix: if the script is missing or
# fails, the update attempt still goes ahead exactly as before.
mkdir -p /etc/systemd/system/apt-daily-upgrade.service.d
cat > /etc/systemd/system/apt-daily-upgrade.service.d/10-dpkg-repair.conf <<'EOF'
[Service]
ExecStartPre=-/usr/local/bin/dpkg-repair.sh
EOF

systemctl daemon-reload
systemctl restart apt-daily-upgrade.timer

echo "=== Reducing SD card writes ==="
# journald: RAM-only instead of persisted to the SD card, with a size cap.
sed -i 's/^Storage=.*/Storage=volatile/; t; s/^\[Journal\]/[Journal]\nStorage=volatile/' /etc/systemd/journald.conf
sed -i 's/^RuntimeMaxUse=.*/RuntimeMaxUse=20M/; t; s/^\[Journal\]/[Journal]\nRuntimeMaxUse=20M/' /etc/systemd/journald.conf
rm -rf /var/log/journal
systemctl restart systemd-journald

# man-db's periodic reindex timer is pointless on a headless, single-purpose
# appliance nobody will ever run `man` on.
systemctl disable --now man-db.timer 2>/dev/null || true

# Note on purpose: some guides suggest disabling zram's writeback timer
# (rpi-zram-writeback.timer) for "SD wear" reasons. Don't — per `man 5
# swap.conf`, that mechanism only writes genuinely idle swap pages back to
# disk, which the vendor documentation states REDUCES SD wear compared to
# the kernel having to reclaim memory more aggressively under pressure. It
# was tested and left enabled deliberately; see docs/architecture.md.

echo "=== Verification ==="
echo "--- 20auto-upgrades ---"
cat /etc/apt/apt.conf.d/20auto-upgrades
echo "--- 51unattended-upgrades-local ---"
grep -v '^//' /etc/apt/apt.conf.d/51unattended-upgrades-local | grep -v '^$'
echo "--- journald.conf ---"
grep -v '^#' /etc/systemd/journald.conf | grep -v '^$'
echo "--- update window actually in effect (not just the file) ---"
systemctl show -p TimersCalendar -p RandomizedDelayUSec apt-daily-upgrade.timer
echo "--- dpkg self-repair hooked in ---"
systemctl show -p ExecStartPre apt-daily-upgrade.service | grep -o 'dpkg-repair.sh' || echo "MISSING - copy scripts/dpkg-repair.sh to /usr/local/bin first"
echo "--- dry-run test (can take 20+ minutes on a weak single-core ARMv6 board — that's normal) ---"
unattended-upgrade --dry-run --debug 2>&1 | grep -E "Allowed origins|Checking|pkgs that look|packages that will|Option --dry-run" | head -20
