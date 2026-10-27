#!/usr/bin/env bash
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
iface=${1:-can_hipnuc}; duration=${2:-120}; [[ $duration =~ ^[0-9]+$ ]] || die 'duration must be numeric'
[[ -d /sys/class/net/$iface ]] || die "interface not found: $iface"
ifindex=$(<"/sys/class/net/$iface/ifindex"); command -v bpftrace >/dev/null || die 'bpftrace not found'
probes=$(bpftrace -l 'kprobe:*can_bus_off*'); grep -Eq '^kprobe:([^:]+:)?can_bus_off$' <<< "$probes" || die 'can_bus_off probe unavailable'
probes=$(bpftrace -l 'kprobe:*can_restart*'); grep -Eq '^kprobe:([^:]+:)?can_restart$' <<< "$probes" || die 'can_restart probe unavailable'
root=${OUTPUT_DIR:-"$script_dir/results"}; mkdir -p "$root"; out=$(mktemp -d "$root/can-state-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
trace=$script_dir/trace-can-state.bt
timeout --signal=TERM --kill-after=10s "${duration}s" bpftrace -B none -e "$(<"$trace")" "$ifindex" >"$out/trace.log" 2>&1 || rc=$?
rc=${rc:-0}; grep -q CAN_STATE_FINAL "$out/trace.log" || rc=1
printf 'Finished: %s iface=%s ifindex=%s (status=%s)\n' "$out" "$iface" "$ifindex" "$rc"; exit "$rc"
