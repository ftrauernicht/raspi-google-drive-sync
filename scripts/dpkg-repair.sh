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
#   * a backup run is in progress -> do nothing and leave it for the next
#                                    attempt
#
# That last point is not politeness, it is the actual root cause of both
# incidents: on weak hardware the configure phase of a package and a running
# sync starve PID 1 long enough for the hardware watchdog to reset the board
# mid-dpkg — which is what left dpkg interrupted in the first place. See
# docs/architecture.md.
set -euo pipefail

RECIPIENTS_FILE=${RECIPIENTS_FILE:-/etc/drive-backup/recipients.txt}
STATE_DIR=${STATE_DIR:-/etc/drive-backup/state}
LOG_DIR=${LOG_DIR:-/mnt/backup/logs}
LOG_FILE="$LOG_DIR/dpkg-repair.log"
DPKG_STATUS=${DPKG_STATUS:-/var/lib/dpkg/status}

# One automatic attempt, then hold off: if the configure run did not fix it,
# retrying every day only buries the mail that asks for a person. Same
# reasoning as the reboot cooldown in drive-backup.sh.
COOLDOWN_HOURS=${COOLDOWN_HOURS:-24}
REPAIR_MARKER="$STATE_DIR/.dpkg-repair-attempted"

# Test hooks (override via environment variable; defaults = real operation).
# Overriding these lets every branch be exercised without actually breaking
# a package database — see tests/test_dpkg_repair.sh.
APT_CHECK_CMD=${APT_CHECK_CMD:-apt-get check}
DPKG_CONFIGURE_CMD=${DPKG_CONFIGURE_CMD:-dpkg --configure -a}
BACKUP_UNIT=${BACKUP_UNIT:-drive-backup.service}

log() {
	# "|| true": the log lives on the backup pool, which is exactly the
	# thing that may be unreachable. A failed write must never be what
	# ends this script — that bug cost a whole watchdog kill once, see
	# docs/architecture.md.
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || true
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
		} | msmtp "$recipient" || log "WARNING: sending mail to $recipient failed"
	done < "$RECIPIENTS_FILE"
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

# True while an earlier attempt is still "recent". Boundary belongs to the
# expired side: with a 24 h cooldown, an attempt exactly 24 h ago may be
# retried, so a daily timer is never skipped by a second of clock jitter.
cooldown_active() {  # cooldown_active <marker epoch> <now epoch> <hours>
	local marker="$1" now="$2" hours="$3"
	[ "$(hours_since "$marker" "$now")" -lt "$hours" ]
}

backup_running() {
	systemctl is-active --quiet "$BACKUP_UNIT" 2>/dev/null && return 0
	pgrep -x rclone >/dev/null 2>&1
}

# --- Main ---------------------------------------------------------------

main() {
	mkdir -p "$STATE_DIR" 2>/dev/null || true
	mkdir -p "$LOG_DIR" 2>/dev/null || true

	# The authoritative test, not a guess from the status file: this is the
	# very call that apt itself refuses to continue past.
	if $APT_CHECK_CMD >/dev/null 2>&1; then
		rm -f "$REPAIR_MARKER"
		exit 0
	fi

	local broken now marker_epoch waited
	broken=$(broken_packages "$DPKG_STATUS")
	broken=${broken% }
	now=$(date +%s)

	if backup_running; then
		log "dpkg is interrupted (${broken:-unknown}), but a backup run is in progress - postponed"
		exit 0
	fi

	if [ -f "$REPAIR_MARKER" ]; then
		marker_epoch=$(stat -c %Y "$REPAIR_MARKER" 2>/dev/null || echo 0)
		if cooldown_active "$marker_epoch" "$now" "$COOLDOWN_HOURS"; then
			waited=$(hours_since "$marker_epoch" "$now")
			log "ERROR: still interrupted (${broken:-unknown}) ${waited}h after an automatic attempt - asking for a person"
			send_mail "[dpkg-repair] Still interrupted, needs a person" \
"An interrupted dpkg run was already repaired automatically about ${waited} hour(s) ago, and the package database is interrupted again or still:

  $broken

While this lasts, the device installs no updates at all, and apt's daily job keeps reporting success. Automatic repair is on hold for ${COOLDOWN_HOURS} hours so this mail does not get buried.

How to fix this by hand:
1. Log in and run 'apt-get check' to see the current state.
2. Run 'dpkg --configure -a' as root. Do it in its own systemd unit
   ('systemd-run --unit=dpkg-repair --wait dpkg --configure -a') so a
   dropped SSH session cannot interrupt it again.
3. If it fails, read its output: a package's configure step is failing for
   a reason of its own, which is a different problem from the one this
   script handles.
4. Check the log for what was tried: $LOG_FILE"
			exit 1
		fi
	fi

	touch "$REPAIR_MARKER"
	log "dpkg is interrupted (${broken:-unknown}) - running: $DPKG_CONFIGURE_CMD"

	local output status=0
	output=$(DEBIAN_FRONTEND=noninteractive $DPKG_CONFIGURE_CMD 2>&1) || status=$?
	echo "$output" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true

	if $APT_CHECK_CMD >/dev/null 2>&1; then
		rm -f "$REPAIR_MARKER"
		log "repaired automatically, apt-get check is clean again"
		send_mail "[dpkg-repair] Repaired automatically" \
"The package database was interrupted and has been repaired automatically:

  $broken

'apt-get check' is clean again, so unattended updates work from here on. No action needed.

Worth a look anyway, because an interrupted dpkg run means the machine went down mid-configure. On this hardware the known cause is the configure phase of a package competing with a running backup until the hardware watchdog resets the board. If that keeps happening, check that the update window and the backup window really are apart (see docs/architecture.md), and look at the condition log next to this one.

Exit status of the configure run: $status
Log: $LOG_FILE"
		exit 0
	fi

	log "ERROR: still interrupted after the attempt (exit $status)"
	send_mail "[dpkg-repair] Automatic repair did not help" \
"The package database is interrupted:

  $broken

An automatic 'dpkg --configure -a' was attempted and did not fix it (exit status $status). While this lasts, the device installs no updates at all, and apt's daily job keeps reporting success.

Last lines of the attempt:

$(echo "$output" | tail -20)

How to fix this by hand:
1. Run 'dpkg --configure -a' as root and read the error it prints.
2. A package whose configure step fails for its own reason needs that
   reason fixed - this script only handles the plain interrupted case.
3. Log: $LOG_FILE"
	exit 1
}

# Only run when executed, not when sourced by the tests. BASH_SOURCE is
# empty when the script is fed through stdin (bash -s), hence the fallback.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
	main "$@"
fi
