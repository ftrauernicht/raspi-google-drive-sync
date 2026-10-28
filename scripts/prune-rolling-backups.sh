#!/bin/bash
# Retention for rolling full backups that another device drops into Drive.
#
# Why this exists. This project copies and never deletes (see
# docs/architecture.md): a file removed from Drive stays on the pool, which
# is the whole point - ransomware or a mistaken delete must not propagate
# into the backup. That is exactly right for documents, and wrong for a
# device that writes one full backup of itself into Drive every single day.
# Home Assistant does: a 3.7 GB tar every morning, of which Drive keeps the
# ten newest and silently drops the rest. The pool kept all of them. By
# 2026-10-28 that was 102 files and 269 GB - 40 % of everything the device
# had stored - growing by 3.7 GB a day, and nothing in the design would ever
# have stopped it.
#
# So this is the deliberate, narrow exception, and it deletes a local copy
# only when BOTH of these hold:
#
#   1. it is not among the newest KEEP files of its rule, and
#   2. the source does not have it any more.
#
# Condition 1 is the safety floor: whatever happens in Drive, the pool keeps
# KEEP generations. Wipe the entire Drive folder and this script still
# deletes nothing, because the newest KEEP are never candidates. That is
# what keeps the copy-only guarantee intact for the retention window.
#
# Condition 2 is not a nicety, it is what makes the rule terminate. Deleting
# a file the source still has means the next `rclone copy` fetches it
# straight back: delete, download, delete, download, for as many gigabytes
# as the rule covers, every single day, over a link that does 200 KiB/s.
# KEEP should therefore be at least as large as whatever the source keeps,
# or the rule simply has nothing it is allowed to do.
#
# Fail-safe in both directions: if the source cannot be listed, nothing is
# deleted this run.
set -uo pipefail

POOL=${POOL:-/mnt/backup}
# The local copy of the remote's root. $LOCAL_ROOT/<dir> and $REMOTE<dir>
# are the same folder seen from the two sides, which is what lets a rule
# name one path and have both checked.
LOCAL_ROOT=${LOCAL_ROOT:-$POOL/drive}
REMOTE=${REMOTE:-gdrive:}
RULES_FILE=${RULES_FILE:-/etc/drive-backup/prune.rules}
LOG_DIR=${LOG_DIR:-$POOL/logs}
LOG_FILE=${LOG_FILE:-$LOG_DIR/drive-backup.log}
# A test hook, and the reason this script can be exercised without a Google
# account: everything about the source comes through this one command.
RCLONE_LSF_CMD=${RCLONE_LSF_CMD:-rclone lsf --max-depth 1}
DRY_RUN=${DRY_RUN:-0}

log() {
	# Shares the sync's log file on purpose: what was deleted and what the
	# pool looked like that morning belong in one place, and logrotate
	# already bounds it.
	printf '%s [prune] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

human() {  # human <bytes> -> a size a person can read
	awk -v b="$1" 'BEGIN {
		split("B KB MB GB TB", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
	}'
}

# Applies one rule. Prints nothing; logs what it did.
prune_rule() {  # prune_rule <keep> <glob relative to LOCAL_ROOT>
	local keep=$1 glob=$2
	local dir base local_dir remote_dir remote_names
	local -a entries=()
	local entry path name size
	local index=0 deleted=0 freed=0 kept_at_source=0

	# The directory part has to be literal and only the file name may be a
	# pattern. Not a limitation worth removing: it is what makes the mapping
	# to the source folder exact, so the script never has to guess which
	# remote listing decides a file's fate.
	case "$glob" in
		*/*) dir=${glob%/*}; base=${glob##*/} ;;
		*)   dir=""; base=$glob ;;
	esac
	case "$dir" in
		*[*?[]*)
			log "ERROR: rule '$keep $glob' has a wildcard in its directory part, which is not supported - skipped"
			return 0
			;;
	esac

	if [ -n "$dir" ]; then
		local_dir="$LOCAL_ROOT/$dir"
		remote_dir="$REMOTE$dir"
	else
		local_dir="$LOCAL_ROOT"
		remote_dir="$REMOTE"
	fi

	[ -d "$local_dir" ] || return 0

	# Newest first, by modification time, null-delimited so that a space in
	# a name - "Home Assistant" is one - cannot split a path in half.
	mapfile -d '' -t entries < <(
		find "$local_dir" -maxdepth 1 -type f -name "$base" -printf '%T@\t%p\0' 2>/dev/null \
			| sort -z -rn
	)
	[ "${#entries[@]}" -gt "$keep" ] || return 0

	# Everything about the source comes from this one listing, and if it
	# fails nothing is deleted. A rule that guesses here would either delete
	# a file Drive still has - and re-download it tomorrow - or stop working
	# silently the first time the network is down.
	# shellcheck disable=SC2086  # the command is a configurable hook, see above
	if ! remote_names=$($RCLONE_LSF_CMD "$remote_dir" 2>/dev/null); then
		log "WARNING: could not list $remote_dir - deleting nothing for '$base' this run"
		return 0
	fi

	for entry in "${entries[@]}"; do
		index=$((index + 1))
		[ "$index" -le "$keep" ] && continue
		path=${entry#*$'\t'}
		name=${path##*/}
		if printf '%s\n' "$remote_names" | grep -qxF -- "$name"; then
			kept_at_source=$((kept_at_source + 1))
			continue
		fi
		size=$(stat -c %s -- "$path" 2>/dev/null) || size=0
		if [ "$DRY_RUN" = 1 ]; then
			log "would delete $name ($(human "$size"))"
			deleted=$((deleted + 1))
			freed=$((freed + size))
		elif rm -f -- "$path"; then
			deleted=$((deleted + 1))
			freed=$((freed + size))
		else
			log "WARNING: could not delete $path"
		fi
	done

	if [ "$deleted" -gt 0 ]; then
		log "$([ "$DRY_RUN" = 1 ] && printf 'would keep' || printf 'kept') the newest $keep of ${#entries[@]} '$base' in $local_dir, $([ "$DRY_RUN" = 1 ] && printf 'would remove' || printf 'removed') $deleted ($(human "$freed"))"
	fi
	if [ "$kept_at_source" -gt 0 ]; then
		log "$kept_at_source older '$base' kept because $remote_dir still has them - deleting those would only fetch them again"
	fi
}

main() {
	# Nothing to do and nothing worth failing over: an unmounted pool is the
	# backup script's problem to report, and it does.
	mountpoint -q "$POOL" || exit 0
	[ -r "$RULES_FILE" ] || exit 0

	local keep glob
	# The keep count is the first field and the glob is all the rest, so a
	# folder name with spaces needs no quoting in the rules file.
	while read -r keep glob; do
		case "$keep" in
			''|'#'*) continue ;;
		esac
		[ -n "$glob" ] || continue
		case "$keep" in
			*[!0-9]*|0|'')
				log "ERROR: rule '$keep $glob' does not start with a keep count of 1 or more - skipped"
				continue
				;;
		esac
		prune_rule "$keep" "$glob"
	done < "$RULES_FILE"
}

main "$@"
