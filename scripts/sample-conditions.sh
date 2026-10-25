#!/bin/bash
# One line per minute about the conditions this device is running under.
# Timestamp, power-supply throttle bits, SoC temperature, load, available
# memory and swap, and which of the heavy jobs are running right now.
#
# Why. The checks in health-check.sh answer "is it healthy *now*", which is
# the right question for a monitor and the wrong one after the fact. On this
# device a hard reset wiped the one value that would have explained it:
# `vcgencmd get_throttled` reports the state *now*, its sticky bits are
# cleared by the reset, and the journal is deliberately volatile
# (docs/architecture.md, SD card wear). So after an unexplained reset in the
# middle of a package's configure step there was nothing left to tell
# under-voltage apart from a watchdog reset caused by a starved PID 1.
#
# This is the flight recorder for the next one. The last line before a gap
# in the file is the state just before the machine went down:
#
#   throttled != 0x0  -> the power supply
#   throttled == 0x0 at high load and low memory -> starvation, i.e. the
#                        hardware watchdog (RuntimeWatchdogSec, 1 minute on
#                        Raspberry Pi OS by default) bit first
#
# Cost: one line of about 110 bytes per minute, roughly 55 MB per year, on
# the backup pool - never on the SD card, which this project goes out of its
# way not to write to. logrotate/drive-backup keeps it bounded.
set -uo pipefail

POOL=${POOL:-/mnt/backup}
LOG_DIR=${LOG_DIR:-$POOL/logs}
LOG_FILE=${LOG_FILE:-$LOG_DIR/conditions.log}
THERMAL_ZONE=${THERMAL_ZONE:-/sys/class/thermal/thermal_zone0/temp}

# Nothing to write to, and nothing worth failing over: the pool being gone
# is the backup script's problem to report, not this one's.
mountpoint -q "$POOL" || exit 0
[ -d "$LOG_DIR" ] || exit 0

throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
temp=$(awk '{printf "%.1f", $1/1000}' "$THERMAL_ZONE" 2>/dev/null)
load=$(cut -d' ' -f1 /proc/loadavg)
memavail=$(awk '/^MemAvailable:/{printf "%dM", $2/1024}' /proc/meminfo)
swapfree=$(awk '/^SwapFree:/{printf "%dM", $2/1024}' /proc/meminfo)

# Which heavy job was running matters more than the bare numbers: it is what
# distinguishes "idle box browned out" from "sync and package configure ran
# into each other", which is the failure this device actually had.
busy=""
pgrep -x rclone >/dev/null 2>&1 && busy="${busy}rclone,"
pgrep -x dpkg >/dev/null 2>&1 && busy="${busy}dpkg,"
pgrep -x apt-get >/dev/null 2>&1 && busy="${busy}apt-get,"
pgrep -x mandb >/dev/null 2>&1 && busy="${busy}mandb,"
# Not a bare "unattended-upgrade": unattended-upgrades.service permanently
# runs "unattended-upgrade-shutdown --wait-for-signal", which would mark
# every single line as an update in progress. Only a real run counts.
pgrep -f 'unattended-upgrade( |$)' >/dev/null 2>&1 && busy="${busy}u-u,"

printf '%s throttled=%s temp=%s load=%s memavail=%s swapfree=%s busy=%s\n' \
	"$(date '+%Y-%m-%d %H:%M:%S')" "${throttled:-?}" "${temp:-?}" "$load" \
	"$memavail" "$swapfree" "${busy:-none}" >>"$LOG_FILE" 2>/dev/null || exit 0

# Push this one file to disk. Without it the last few lines before a hard
# reset - the only ones that matter - may still be sitting in the page
# cache. Deliberately "sync -d <file>" and not a bare "sync", which would
# flush the SD card too.
sync -d "$LOG_FILE" 2>/dev/null || true
