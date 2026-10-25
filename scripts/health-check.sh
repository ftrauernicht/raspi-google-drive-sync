#!/bin/bash
# Nagios/Icinga-compatible health checks for the backup Pi.
#
#   health-check.sh storage | sync | throttle | temperature | units | updates
#
# Each check prints one status line ("OK - ...", "WARNING - ...", ...) with
# performance data and exits 0/1/2/3, so any monitoring system that speaks
# the Nagios plugin format can use it - typically via check_by_ssh from a
# machine on the same LAN. See docs/monitoring.md.
#
# Meant to run as an SSH forced command for a dedicated, unprivileged user:
# the requested check then arrives in $SSH_ORIGINAL_COMMAND and is matched
# against a fixed whitelist. Nothing the caller sends is ever executed.
#
# Read-only by design: it never writes, restarts or repairs anything. The
# backup script heals itself; this only makes its state visible.
#
# Configuration (all optional) in /etc/drive-backup/health.env, or the file
# named by HEALTH_CONFIG. Defaults match the setup guide.
set -u

HEALTH_CONFIG=${HEALTH_CONFIG:-/etc/drive-backup/health.env}
# shellcheck source=/dev/null
[ -r "$HEALTH_CONFIG" ] && . "$HEALTH_CONFIG"

POOL=${POOL:-/mnt/backup}
MEMBER_DISKS=${MEMBER_DISKS:-"/mnt/disk1 /mnt/disk2"}
DISK_WARN=${DISK_WARN:-85}
DISK_CRIT=${DISK_CRIT:-95}
SYNC_UNIT=${SYNC_UNIT:-drive-backup.service}
# The line drive-backup.sh logs at the very end of a successful run. If you
# translated the script's messages, set your own wording here.
SYNC_SUCCESS_MARKER=${SYNC_SUCCESS_MARKER:-"=== Sync run finished successfully ==="}
# drive-backup.sh keeps its own log on the storage pool. That file is the
# primary source here, because the journal does not survive a reboot on a Pi
# set up the way scripts/01-setup-os-hardening.sh sets it up: reducing SD-card
# wear means Storage=volatile, so journalctl starts empty after every boot.
SYNC_LOG=${SYNC_LOG:-$POOL/logs/drive-backup.log}
SYNC_WARN_HOURS=${SYNC_WARN_HOURS:-30}
SYNC_CRIT_HOURS=${SYNC_CRIT_HOURS:-54}
# The Pi's SoC starts soft-throttling at 80 degrees and hard-throttles at 85.
TEMP_WARN=${TEMP_WARN:-70}
TEMP_CRIT=${TEMP_CRIT:-80}
UPGRADE_STAMP=${UPGRADE_STAMP:-/var/lib/apt/periodic/unattended-upgrades-stamp}
UPGRADE_MAX_HOURS=${UPGRADE_MAX_HOURS:-48}
REBOOT_MAX_HOURS=${REBOOT_MAX_HOURS:-48}

STATE_NAMES=(OK WARNING CRITICAL UNKNOWN)

finish() {  # finish <code> <text> [perfdata]
	local code="$1" text="$2" perf="${3:-}"
	if [ -n "$perf" ]; then
		echo "${STATE_NAMES[$code]} - $text | $perf"
	else
		echo "${STATE_NAMES[$code]} - $text"
	fi
	exit "$code"
}

worst() {  # worst <a> <b> -> the more severe state; UNKNOWN (3) only wins over OK
	local a="$1" b="$2"
	if [ "$a" -eq 3 ] && [ "$b" -eq 0 ]; then echo 3; return; fi
	if [ "$b" -eq 3 ] && [ "$a" -eq 0 ]; then echo 3; return; fi
	if [ "$a" -eq 3 ]; then a=0; fi
	if [ "$b" -eq 3 ]; then b=0; fi
	if [ "$a" -gt "$b" ]; then echo "$a"; else echo "$b"; fi
}

# --- pure logic, covered by tests/test_health_check.sh ---------------------

join_parts() {  # join_parts <a> <b> ... -> "a, b, ..."
	local out="" part
	for part in "$@"; do
		out="${out:+$out, }$part"
	done
	echo "$out"
}

threshold_state() {  # threshold_state <value> <warn> <crit>: higher is worse
	local value="$1" warn="$2" crit="$3"
	if [ "$value" -ge "$crit" ]; then echo 2
	elif [ "$value" -ge "$warn" ]; then echo 1
	else echo 0
	fi
}

# vcgencmd get_throttled returns a bit field. Bits 0-2 describe right now
# (under-voltage, frequency capped, throttled), bits 16-18 the same events
# at any time since boot. Bit 3/19 (soft temperature limit) is covered by
# the temperature check. Under-voltage is the classic silent killer on an
# old Pi powering USB disks: corrupt writes, not crashes.
throttle_state() {  # throttle_state <hex> -> "<code> <text>"
	local value=$(( $1 ))
	local now=$(( value & 0x7 )) past=$(( (value >> 16) & 0x7 ))
	local parts=()
	(( value & 0x1 )) && parts+=("under-voltage now")
	(( value & 0x2 )) && parts+=("frequency capped now")
	(( value & 0x4 )) && parts+=("throttled now")
	(( value & 0x10000 )) && parts+=("under-voltage since boot")
	(( value & 0x20000 )) && parts+=("frequency capped since boot")
	(( value & 0x40000 )) && parts+=("throttled since boot")
	local text="no throttling"
	[ "${#parts[@]}" -gt 0 ] && text=$(IFS=,; echo "${parts[*]}")
	if [ "$now" -ne 0 ]; then echo "2 $text"
	elif [ "$past" -ne 0 ]; then echo "1 $text"
	else echo "0 $text"
	fi
}

# Packages left in an unfinished state by an interrupted dpkg run, read
# straight from the status database. Works without root - "dpkg --audit"
# and "apt-get check" need root to see this.
broken_packages() {  # broken_packages <dpkg status file> -> names, space separated
	awk '
		/^Package: / { pkg = $2 }
		/^Status: / && $NF ~ /^(half-configured|half-installed|unpacked|triggers-awaited|triggers-pending)$/ { printf "%s ", pkg }
	' "$1"
}

# Timestamp of the last successful run, read from drive-backup.sh's own log.
# Lines look like "2026-01-02 03:04:05 === Sync run finished successfully ===".
# -a because the log also carries rclone's progress output, which contains
# control characters - without it grep calls the file binary and prints nothing.
last_success_from_log() {  # last_success_from_log <logfile> <marker> -> "YYYY-MM-DD HH:MM:SS"
	local datei="$1" marker="$2" zeile stempel
	local dateien=()
	# One rotated generation is read as well, oldest first so that the last
	# match is still the newest. logrotate truncates the live log in place
	# (copytruncate, because rclone holds its --log-file open for days), so
	# in the window between a rotation and the next finished run the last
	# success line exists only in <log>.1. Without this the check falls
	# through to the journal, which is volatile here, and then reports "no
	# successful run" on a device that is perfectly healthy - the same
	# class of false alarm this function was written to end.
	[ -r "$datei.1" ] && dateien+=("$datei.1")
	[ -r "$datei" ] && dateien+=("$datei")
	[ "${#dateien[@]}" -gt 0 ] || return 1
	zeile=$(grep -a -h -F -- "$marker" "${dateien[@]}" | tail -1)
	[ -n "$zeile" ] || return 1
	stempel=${zeile:0:19}
	case "$stempel" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	echo "$stempel"
}

hours_between() {  # hours_between <then_epoch> <now_epoch>
	echo $(( ($2 - $1) / 3600 ))
}

# --- checks ------------------------------------------------------------------

check_storage() {
	local code=0 parts=() perf=() mnt use
	for mnt in "$POOL" $MEMBER_DISKS; do
		if ! mountpoint -q "$mnt"; then
			parts+=("$mnt NOT MOUNTED")
			code=2
			continue
		fi
		use=$(df --output=pcent "$mnt" | tail -1 | tr -dc '0-9')
		parts+=("$mnt ${use}%")
		perf+=("'$mnt'=${use}%;$DISK_WARN;$DISK_CRIT;0;100")
		code=$(worst "$code" "$(threshold_state "$use" "$DISK_WARN" "$DISK_CRIT")")
	done
	finish "$code" "$(join_parts "${parts[@]}")" "${perf[*]}"
}

check_sync() {
	local stempel line epoch now hours quelle
	# The log on the pool survives reboots; the journal does not (volatile).
	if stempel=$(last_success_from_log "$SYNC_LOG" "$SYNC_SUCCESS_MARKER"); then
		epoch=$(date -d "$stempel" +%s 2>/dev/null) || epoch=""
		quelle="log"
	fi
	if [ -z "${epoch:-}" ]; then
		line=$(journalctl -u "$SYNC_UNIT" --since "-14 days" --no-pager -o short-unix 2>/dev/null \
			| grep -F -- "$SYNC_SUCCESS_MARKER" | tail -1)
		epoch=${line%%.*}
		quelle="journal"
	fi
	if [ -z "${epoch:-}" ]; then
		finish 2 "no successful run found in $SYNC_LOG, and none in the journal for the last 14 days"
	fi
	now=$(date +%s)
	hours=$(hours_between "$epoch" "$now")
	finish "$(threshold_state "$hours" "$SYNC_WARN_HOURS" "$SYNC_CRIT_HOURS")" \
		"last successful run $hours h ago ($(date -d "@$epoch" '+%F %H:%M'), from $quelle)" \
		"age=${hours}h;$SYNC_WARN_HOURS;$SYNC_CRIT_HOURS;0"
}

check_throttle() {
	local raw result
	raw=$(vcgencmd get_throttled 2>/dev/null) || finish 3 "vcgencmd not usable (is this user in group 'video'?)"
	raw=${raw#*=}
	result=$(throttle_state "$raw")
	finish "${result%% *}" "${result#* } ($raw)" "throttled=$(( raw ))"
}

check_temperature() {
	local milli deg
	milli=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) || finish 3 "no thermal zone"
	deg=$(( milli / 1000 ))
	finish "$(threshold_state "$deg" "$TEMP_WARN" "$TEMP_CRIT")" "SoC ${deg} C" "temp=$deg;$TEMP_WARN;$TEMP_CRIT"
}

check_units() {
	local failed count
	failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
	count=$(echo "$failed" | wc -w)
	if [ "$count" -gt 0 ]; then
		finish 2 "failed units: $failed" "failed=$count"
	fi
	finish 0 "no failed units" "failed=0"
}

# Pending updates on their own are normal - unattended-upgrades installs
# them overnight. What matters is whether the automation still runs and
# whether a required reboot is being held back.
#
# The first test is the important one. If a dpkg run was ever interrupted
# (power loss, OOM, a reboot mid-upgrade), "apt-get check" fails - and
# /usr/lib/apt/apt.systemd.daily then exits 0 WITHOUT doing anything. The
# timers keep firing, systemd reports every run as successful, and the
# device silently stops receiving security updates. Found exactly like that
# on a real device: 39 days without an update, nothing in any log.
#
# Both "apt-get check" and "dpkg --audit" only see this as root, so the
# status database is read directly (see broken_packages).
DPKG_STATUS=${DPKG_STATUS:-/var/lib/dpkg/status}

check_updates() {
	local code=0 parts=() now pending stamp_age=-1 reboot_age=-1 broken
	now=$(date +%s)
	broken=$(broken_packages "$DPKG_STATUS")
	if [ -n "$broken" ]; then
		parts+=("DPKG INTERRUPTED (${broken% }): unattended-upgrades silently does nothing - run 'dpkg --configure -a' as root")
		code=2
	fi
	pending=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)
	parts+=("$pending pending")
	if [ -e "$UPGRADE_STAMP" ]; then
		stamp_age=$(hours_between "$(stat -c %Y "$UPGRADE_STAMP")" "$now")
		parts+=("unattended-upgrades ran ${stamp_age} h ago")
		[ "$stamp_age" -ge "$UPGRADE_MAX_HOURS" ] && code=2
	else
		parts+=("unattended-upgrades never ran")
		code=2
	fi
	if [ -e /run/reboot-required ]; then
		reboot_age=$(hours_between "$(stat -c %Y /run/reboot-required)" "$now")
		parts+=("reboot required for ${reboot_age} h")
		[ "$reboot_age" -ge "$REBOOT_MAX_HOURS" ] && code=$(worst "$code" 1)
	fi
	finish "$code" "$(join_parts "${parts[@]}")" "pending=$pending"
}

main() {
	local check="${1:-${SSH_ORIGINAL_COMMAND:-}}"
	case "$check" in
		storage)     check_storage ;;
		sync)        check_sync ;;
		throttle)    check_throttle ;;
		temperature) check_temperature ;;
		units)       check_units ;;
		updates)     check_updates ;;
		*) finish 3 "usage: $(basename "$0") storage|sync|throttle|temperature|units|updates" ;;
	esac
}

# Only run when executed, not when sourced by the tests. BASH_SOURCE is
# empty when the script is fed through stdin (bash -s), hence the fallback.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
	main "$@"
fi
