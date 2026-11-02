#!/bin/sh
# Copyright (C) 2026 wentywenty
# SPDX-License-Identifier: GPL-3.0
# Clean up expired seven-dimension session directories.
#
# Rules:
#   1. Remove sessions older than SESSION_RETENTION_DAYS (default 7);
#   2. Cap the total on-disk size at SESSION_MAX_TOTAL_MB (default 8000):
#      scanning newest-first, once the running total would exceed the
#      budget every session from that point on (older) is removed,
#      regardless of its own individual size. A byte/count-based cap was
#      tried first but the "keep N sessions" proxy breaks once sessions
#      can auto-rotate on a timer — N sessions might be 5 hours or 5 days
#      depending on how fast they are produced. Sizing directly in the
#      same unit as the actual constraint (disk space) is robust to that.
#   3. The newest session per root is never removed — it may still be
#      the one being written. Its size still counts toward the budget.
#
# Default scope covers three roots: the current primary location
# /home/robo/robopi-logs, the old /var/log/robopi (47MB zram, easiest
# to fill up), and its persistent mirror /var/log.hdd/robopi (cleaning
# only the zram copy would have armbian-ramlog sync the old ones back
# after a reboot).
#
# Called by robopi-seven-capture before each new session; every removal
# is logged to stderr (journal) for audit. --dry-run prints without deleting.

set -eu

RETENTION_DAYS=${SESSION_RETENTION_DAYS:-7}
MAX_TOTAL_KB=$(( ${SESSION_MAX_TOTAL_MB:-8000} * 1024 ))
ROOTS=${SESSION_CLEANUP_ROOTS:-/home/robo/robopi-logs /var/log/robopi /var/log.hdd/robopi}
DRY_RUN=no
[ "${1:-}" = "--dry-run" ] && DRY_RUN=yes

log() { echo "robopi-session-cleanup: $*" >&2; }

list=
cleanup() { [ -z "$list" ] || rm -f "$list" "$list.sorted"; }
trap cleanup EXIT

remove()
{
    if [ "$DRY_RUN" = yes ]; then
        log "dry-run: would remove $1 (${2:-?} KiB)"
    else
        rm -rf -- "$1"
        log "removed $1 (${2:-?} KiB)"
    fi
}

for root in $ROOTS; do
    [ -d "$root" ] || continue

    # Collect each session's timestamp and on-disk size: timestamp prefers
    # manifest's started_at_unix, falls back to directory mtime (manifest
    # can be 0 bytes when the disk was full).
    list=$(mktemp)
    for dir in "$root"/seven-*; do
        [ -d "$dir" ] || continue
        stamp=$(sed -n 's/^  "started_at_unix": \([0-9][0-9.]*\),$/\1/p' \
                "$dir/manifest.json" 2>/dev/null | head -n 1)
        stamp=${stamp%%.*}
        [ -n "$stamp" ] || stamp=$(stat -c %Y "$dir" 2>/dev/null || echo 0)
        size=$(du -sk "$dir" 2>/dev/null | cut -f1)
        [ -n "$size" ] || size=0
        echo "$stamp $size $dir" >> "$list"
    done

    if [ ! -s "$list" ]; then
        rm -f "$list"
        continue
    fi

    # Sort newest first; row 1 is protected, the rest go through both rules.
    sort -rn "$list" > "$list.sorted"
    cutoff=$(( $(date +%s) - RETENTION_DAYS * 86400 ))
    index=0
    cumulative_kb=0
    over_budget=no
    while read -r stamp size dir; do
        index=$((index + 1))
        if [ "$index" -eq 1 ]; then
            cumulative_kb=$((cumulative_kb + size))
            [ "$cumulative_kb" -le "$MAX_TOTAL_KB" ] || over_budget=yes
            continue
        fi
        if [ "$stamp" -lt "$cutoff" ]; then
            remove "$dir" "$size"
            continue
        fi
        if [ "$over_budget" = yes ]; then
            remove "$dir" "$size"
            continue
        fi
        cumulative_kb=$((cumulative_kb + size))
        if [ "$cumulative_kb" -gt "$MAX_TOTAL_KB" ]; then
            over_budget=yes
            remove "$dir" "$size"
        fi
    done < "$list.sorted"

    rm -f "$list" "$list.sorted"
done
