#!/bin/bash
# Self-repair for the one failure mode on this device that produces no error
# of its own: an interrupted dpkg run.
#
# Why this exists. When a dpkg run is interrupted, `apt-get check` starts
# failing, and from then on apt's daily job exits 0 without doing anything
# at all — systemd reports success, no mail is sent, and the machine simply
# stops receiving updates. On the device this was written for that happened
# twice: once undetected for 39 days, and once more eight days after the
# first repair. Both times the state was found by an external monitor
# (docs/monitoring.md), never by the device itself. A box that is supposed
# to run unattended for years has to get itself out of this.
#
# How. Run as ExecStartPre of apt-daily-upgrade.service (see
# 01-setup-os-hardening.sh), so the check happens immediately before every
# update attempt, including the catch-up run after a boot:
#
#   * dpkg is fine                -> exit quietly, no mail, no log line
#   * dpkg is interrupted         -> one `dpkg --configure -a`, then mail
#                                    what happened
#   * still interrupted afterwards-> mail and ask for a person
#   * a backup run is in progress -> leave it for the next attempt, but
#                                    mail once it has been broken for
#                                    POSTPONE_MAX_HOURS anyway
#
# That fourth point is not politeness, it is the actual root cause of both
# incidents: on weak hardware the configure phase of a package and a running
# sync starve PID 1 long enough for the hardware watchdog to reset the board
# mid-dpkg — which is what left dpkg interrupted in the first place. See
# docs/architecture.md.
#
# Every mail this script can send is capped at one per
# NOTIFY_COOLDOWN_HOURS, and the text says so. The thing being reported is
# invisible by design, so it must not be buried under a daily retry either.
set -euo pipefail

POOL=${POOL:-/mnt/backup}
RECIPIENTS_FILE=${RECIPIENTS_FILE:-/etc/drive-backup/recipients.txt}
STATE_DIR=${STATE_DIR:-/etc/drive-backup/state}
LOG_DIR=${LOG_DIR:-$POOL/logs}
LOG_FILE="$LOG_DIR/dpkg-repair.log"
DPKG_STATUS=${DPKG_STATUS:-/var/lib/dpkg/status}
# dpkg records an interrupted run as files here. That is the plain case, the
# one a configure run really does fix - worth telling apart from a check
# that fails over unmet dependencies, which it cannot.
DPKG_UPDATES_DIR=${DPKG_UPDATES_DIR:-/var/lib/dpkg/updates}

# One automatic attempt, then hold off: if the configure run did not fix it,
# retrying every hour only buries the mail that asks for a person. Same
# reasoning as the reboot cooldown in drive-backup.sh.
COOLDOWN_HOURS=${COOLDOWN_HOURS:-24}
NOTIFY_COOLDOWN_HOURS=${NOTIFY_COOLDOWN_HOURS:-24}
# How long a backup run may keep postponing the repair before a person is
# told anyway. A first sync legitimately runs for days, and staying silent
# through that is how the 39-day outage happened.
POSTPONE_MAX_HOURS=${POSTPONE_MAX_HOURS:-48}

REPAIR_MARKER="$STATE_DIR/.dpkg-repair-attempted"
SINCE_MARKER="$STATE_DIR/.dpkg-interrupted-since"
NOTIFY_MARKER="$STATE_DIR/.dpkg-repair-notified"

# Test hooks (override via environment variable; defaults = real operation).
# Overriding these lets every branch be exercised without actually breaking
# a package database — see tests/test_dpkg_repair.sh.
APT_CHECK_CMD=${APT_CHECK_CMD:-apt-get check}
DPKG_CONFIGURE_CMD=${DPKG_CONFIGURE_CMD:-dpkg --configure -a}
BACKUP_UNIT=${BACKUP_UNIT:-drive-backup.service}
BACKUP_PATTERN=${BACKUP_PATTERN:-drive-backup.sh}

# A hanging command here is worse than a failing one: this script runs as
# ExecStartPre of a Type=oneshot unit, whose start timeout is disabled by
# default, so a black-holed SMTP connection would block every future update
# forever. Deliberately NOT applied to the configure run below - killing
# dpkg half way through is the very damage this script exists to repair.
CMD_TIMEOUT=${CMD_TIMEOUT:-120}

log() {
	# The log lives on the backup pool, which is exactly the thing that may
	# be unreachable - and if it is, the line still has to reach the
	# journal. A failed write must never be what ends this script: that bug
	# once cost a whole watchdog kill, see docs/architecture.md.
	local line
	line="$(date '+%Y-%m-%d %H:%M:%S') $*"
	echo "$line"
	if [ -n "$LOG_FILE" ]; then
		echo "$line" >>"$LOG_FILE" 2>/dev/null || true
	fi
}

send_mail() {  # send_mail <subject> <body>
	local subject="$1" body="$2" recipient msgid
	msgid="<$(date +%s%N).dpkg-repair@$(hostname)>"
	if [ ! -r "$RECIPIENTS_FILE" ]; then
		log "WARNING: recipients file $RECIPIENTS_FILE is missing, mail not sent: $subject"
		return 0
	fi
	while read -r recipient; do
		[ -n "$recipient" ] || continue
		{
			echo "To: $recipient"
			echo "Subject: $subject"
			echo "Message-ID: $msgid"
			echo
			echo "$body"
		} | timeout "$CMD_TIMEOUT" msmtp "$recipient" \
			|| log "WARNING: sending mail to $recipient failed"
	done < "$RECIPIENTS_FILE"
	touch "$NOTIFY_MARKER" 2>/dev/null || true
}

# --- Pure helpers, unit-tested ------------------------------------------

# Packages dpkg itself considers unfinished. Read from the status file
# rather than from `dpkg --audit` so the same logic can be tested against a
# fixture. Same states as health-check.sh looks for, on purpose: what the
# monitor reports and what this script repairs must not drift apart.
broken_packages() {  # broken_packages <dpkg status file> -> names, space separated
	awk '
		/^Package: / { pkg = $2 }
		/^Status: / && $NF ~ /^(half-configured|half-installed|unpacked|triggers-awaited|triggers-pending)$/ { printf "%s ", pkg }
	' "$1"
}

hours_since() {  # hours_since <epoch> <now epoch> -> whole hours, never negative
	local then="$1" now="$2" diff
	diff=$(( now - then ))
	[ "$diff" -lt 0 ] && diff=0
	echo "$(( diff / 3600 ))"
}

# True while an earlier event is still "recent". Boundary belongs to the
# expired side: with a 24 h cooldown, something exactly 24 h old may happen
# again, so a daily timer is never skipped by a second of clock jitter.
cooldown_active() {  # cooldown_active <marker epoch> <now epoch> <hours>
	local marker="$1" now="$2" hours="$3"
	[ "$(hours_since "$marker" "$now")" -lt "$hours" ]
}

# A mail with a blank line where the explanation belongs is worse than no
# mail: the reader cannot tell whether nothing was found or the script broke.
or_placeholder() {  # or_placeholder <text> <placeholder>
	if [ -n "${1//[[:space:]]/}" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# dpkg naming no package is not by itself an error, and what it means
# differs sharply - so say which case it is instead of guessing. With files
# in dpkg's updates directory it is the plain interrupted case, which a
# configure run does fix; without them the check is failing over something
# else (unmet dependencies, most likely) that it cannot.
broken_label() {  # broken_label <names> <number of files in updates dir>
	if [ -n "${1//[[:space:]]/}" ]; then
		printf '%s' "$1"
		[ "${2:-0}" -gt 0 ] && printf ' (and %s interrupted-run record(s) in %s)' "$2" "$DPKG_UPDATES_DIR"
		return 0
	fi
	if [ "${2:-0}" -gt 0 ]; then
		printf '(no package named, but %s file(s) in %s record an interrupted run - that is the plain case, and a configure run does fix it)' "$2" "$DPKG_UPDATES_DIR"
	else
		printf '(no package named and no interrupted run recorded - so the check is failing over something else, most likely unmet dependencies, which a configure run cannot fix; its own output below says which)'
	fi
}

# "did not fix it (exit status 0)" reads like a contradiction. It isn't, but
# the two cases behind it need different words, and different next steps.
repair_outcome() {  # repair_outcome <exit status of the configure run>
	if [ "$1" -ne 0 ]; then
		printf 'The configure run itself failed, with exit status %s.' "$1"
	else
		printf 'The configure run reported success, yet apt-get check still refuses - so something other than a plain interruption is wrong.'
	fi
}

# Another apt or dpkg holding the lock is transient and not this script's
# business. Without this, a concurrent apt-daily download run turns into a
# mail claiming the repair failed.
looks_like_lock() {  # looks_like_lock <text>
	case "$1" in
		*"Could not get lock"*|*"dpkg frontend lock"*|*"is held by"*|*"being used by"*|*"Resource temporarily unavailable"*) return 0 ;;
	esac
	return 1
}

count_updates_records() {  # count_updates_records <dir> -> number of files
	local dir="$1" n
	n=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l) || n=0
	echo "${n:-0}"
}

# A sync in progress must be detected for its whole run, not just while
# rclone happens to be transferring. drive-backup.service is Type=oneshot
# with RemainAfterExit=no, which means `systemctl is-active` reports
# "activating" (exit 3) for the entire run - measured on the device, not
# assumed. So ask for the state itself, and fall back to the process name,
# which also catches a run started by hand with no unit at all.
backup_running() {
	case "$(systemctl show -p ActiveState --value "$BACKUP_UNIT" 2>/dev/null)" in
		active|activating|deactivating|reloading) return 0 ;;
	esac
	pgrep -f "$BACKUP_PATTERN" >/dev/null 2>&1 && return 0
	pgrep -x rclone >/dev/null 2>&1
}

may_notify() {  # true when the mail cooldown has expired
	local now="$1" marker_epoch
	[ -f "$NOTIFY_MARKER" ] || return 0
	marker_epoch=$(stat -c %Y "$NOTIFY_MARKER" 2>/dev/null || echo 0)
	cooldown_active "$marker_epoch" "$now" "$NOTIFY_COOLDOWN_HOURS" && return 1
	return 0
}

clear_state() {
	rm -f "$REPAIR_MARKER" "$SINCE_MARKER" "$NOTIFY_MARKER" 2>/dev/null || true
}

mail_footer() {
	printf 'You will not get this mail again for %s hours; the log keeps every attempt: %s' \
		"$NOTIFY_COOLDOWN_HOURS" "${LOG_FILE:-(pool unreachable, journal only)}"
}

# --- Main ---------------------------------------------------------------

main() {
	# Never write the log to the SD card: /mnt/backup/logs would be created
	# on the bare mount point, the next mount would hide it, and the one
	# persistent trace of a repair would be gone. Without the pool, the
	# journal has to do - which is why log() always writes there too.
	if mountpoint -q "$POOL" 2>/dev/null; then
		mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE=""
	else
		LOG_FILE=""
	fi
	# Non-fatal on purpose: a read-only root (this hardware does get SD
	# errors) must not stop the repair before it has even looked.
	mkdir -p "$STATE_DIR" 2>/dev/null || true

	# The authoritative test, not a guess from the status file: this is the
	# very call that apt itself refuses to continue past.
	# shellcheck disable=SC2086  # the hook holds a command with arguments
	if timeout "$CMD_TIMEOUT" $APT_CHECK_CMD >/dev/null 2>&1; then
		clear_state
		exit 0
	fi

	local broken now updates label
	# "|| true": awk exits 2 on an unreadable status file, and an
	# interrupted dpkg write is a plausible reason for exactly that. Dying
	# here would mean no log, no mail and no repair.
	broken=$(broken_packages "$DPKG_STATUS" 2>/dev/null || true)
	broken=${broken% }
	updates=$(count_updates_records "$DPKG_UPDATES_DIR")
	label=$(broken_label "$broken" "$updates")
	now=$(date +%s)

	[ -f "$SINCE_MARKER" ] || touch "$SINCE_MARKER" 2>/dev/null || true
	local since_epoch broken_for
	since_epoch=$(stat -c %Y "$SINCE_MARKER" 2>/dev/null || echo "$now")
	broken_for=$(hours_since "$since_epoch" "$now")

	if backup_running; then
		# The label can begin with "(" of its own, so it goes last rather
		# than into brackets - "interrupted ((no package named ...))" is
		# not what anyone wants to read at three in the morning.
		log "dpkg is interrupted, but a backup run is in progress - postponed after ${broken_for}h: $label"
		if [ "$broken_for" -ge "$POSTPONE_MAX_HOURS" ] && may_notify "$now"; then
			send_mail "[dpkg-repair] Interrupted for ${broken_for}h, and a backup keeps running" \
"The package database has been interrupted for about ${broken_for} hour(s):

  $label

Every repair attempt so far was postponed because a backup run was in progress each time. That is deliberate - running a package configure next to a sync is what broke dpkg here in the first place - but it cannot go on silently, because no updates are installed in the meantime and apt's daily job keeps reporting success.

What to do:
1. Check whether a sync really is running that long: 'systemctl status $BACKUP_UNIT' and the tail of the backup log. A first sync legitimately takes days; a stuck one does not.
2. When the device is idle, run 'dpkg --configure -a' as root, in its own
   unit: 'systemd-run --unit=dpkg-repair --wait dpkg --configure -a'.
3. $(mail_footer)"
		fi
		exit 0
	fi

	if [ -f "$REPAIR_MARKER" ]; then
		local marker_epoch waited
		marker_epoch=$(stat -c %Y "$REPAIR_MARKER" 2>/dev/null || echo 0)
		if cooldown_active "$marker_epoch" "$now" "$COOLDOWN_HOURS"; then
			waited=$(hours_since "$marker_epoch" "$now")
			log "ERROR: still interrupted ${waited}h after an automatic attempt, no retry before ${COOLDOWN_HOURS}h: $label"
			if may_notify "$now"; then
				send_mail "[dpkg-repair] Still interrupted, needs a person" \
"An automatic repair was already attempted about ${waited} hour(s) ago - attempted, not necessarily achieved - and the package database is interrupted again or still:

  $label

While this lasts, the device installs no updates at all, and apt's daily job keeps reporting success. The next automatic attempt happens once ${COOLDOWN_HOURS} hours have passed since that one.

How to fix this by hand:
1. Run 'apt-get check' and read what it says.
2. Then 'dpkg --configure -a' as root, in its own unit, so a dropped SSH
   session cannot interrupt it again:
   'systemd-run --unit=dpkg-repair --wait dpkg --configure -a'
3. If it fails, read its output: a package whose configure step fails for a
   reason of its own is a different problem from the one this script
   handles.
4. $(mail_footer)"
			else
				log "mail suppressed: one was already sent within ${NOTIFY_COOLDOWN_HOURS}h"
			fi
			exit 1
		fi
	fi

	touch "$REPAIR_MARKER" 2>/dev/null || true
	log "dpkg is interrupted, running: $DPKG_CONFIGURE_CMD - unfinished: $label"

	local output status=0
	output=$(DEBIAN_FRONTEND=noninteractive $DPKG_CONFIGURE_CMD 2>&1) || status=$?
	if [ -n "$LOG_FILE" ]; then
		echo "$output" >>"$LOG_FILE" 2>/dev/null || true
	fi

	# A lock held by another apt or dpkg is transient. Reporting it as a
	# failed repair would mail a false alarm and burn the cooldown on a
	# machine that is fine, so retry on the next run instead.
	if [ "$status" -ne 0 ] && looks_like_lock "$output"; then
		rm -f "$REPAIR_MARKER" 2>/dev/null || true
		log "another apt or dpkg process holds the lock - retrying on the next run, no mail"
		exit 0
	fi

	local check_output
	# shellcheck disable=SC2086  # the hook holds a command with arguments
	if check_output=$(timeout "$CMD_TIMEOUT" $APT_CHECK_CMD 2>&1); then
		clear_state
		log "apt-get check is clean again (configure run exited $status)"
		local verdict
		if [ "$status" -eq 0 ]; then
			verdict="The configure run succeeded and 'apt-get check' is clean again, so unattended updates work from here on. No action needed."
		else
			# Honest about an outcome that looks contradictory: the check
			# passing is what counts, but claiming a clean repair after a
			# failed command would be a lie in the subject line.
			verdict="Careful: the configure run itself reported exit status $status, yet 'apt-get check' is clean now. The most likely explanation is that another apt or dpkg process was involved and the state resolved anyway. Worth one look at the output below."
		fi
		send_mail "[dpkg-repair] Repaired automatically" \
"The package database was interrupted and has been repaired automatically:

  $label

$verdict

Worth a look regardless, because an interrupted dpkg run means the machine went down mid-configure. On this hardware the known cause is the configure phase of a package competing with a running backup until the hardware watchdog resets the board. If that keeps happening, check that the update window and the backup window really are apart (see docs/architecture.md), and look at the condition log next to this one.

Output of the configure run:

$(or_placeholder "$(echo "$output" | tail -20)" "(it printed nothing)")

Log: ${LOG_FILE:-(pool unreachable, journal only)}"
		exit 0
	fi

	log "ERROR: still interrupted after the attempt ($(repair_outcome "$status"))"
	if may_notify "$now"; then
		send_mail "[dpkg-repair] Automatic repair did not help" \
"Packages dpkg considers unfinished:

  $label

An automatic 'dpkg --configure -a' was attempted and did not help. $(repair_outcome "$status")

While this lasts, the device installs no updates at all, and apt's daily job keeps reporting success.

What apt-get check says now:

$(or_placeholder "$check_output" "(it printed nothing, which is unusual for a failing check - see the log)")

Last lines of the configure run:

$(or_placeholder "$(echo "$output" | tail -20)" "(it printed nothing)")

How to fix this by hand:
1. Run 'apt-get check' and read it, then 'dpkg --configure -a' as root.
2. If no package is named above, the check is failing for another reason -
   unmet dependencies, most likely - and a configure run cannot fix that.
   'apt-get -f install' is the usual next step there.
3. A package whose configure step fails for its own reason needs that
   reason fixed; this script only handles the plain interrupted case.
4. $(mail_footer)"
	else
		log "mail suppressed: one was already sent within ${NOTIFY_COOLDOWN_HOURS}h"
	fi
	exit 1
}

# Only run when executed, not when sourced by the tests. BASH_SOURCE is
# empty when the script is fed through stdin (bash -s), hence the fallback.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
	main "$@"
fi
