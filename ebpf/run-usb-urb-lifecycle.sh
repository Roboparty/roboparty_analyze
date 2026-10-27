#!/usr/bin/env bash
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
(( $# >= 2 && $# <= 4 )) || { printf 'Usage: sudo bash %s BUS DEV [SECONDS=120] [THRESHOLD_US=5000]\n' "$0" >&2; exit 2; }
bus=$1; dev=$2; duration=${3:-120}; threshold=${4:-5000}
for value in "$bus" "$dev" "$duration" "$threshold"; do [[ $value =~ ^[0-9]+$ ]] || die "numeric argument required: $value"; done
command -v bpftrace >/dev/null || die 'bpftrace not found'
probes=$(bpftrace -l 'kprobe:*usb_submit_urb*'); grep -Eq '^kprobe:([^:]+:)?usb_submit_urb$' <<< "$probes" || die 'usb_submit_urb probe unavailable'
probes=$(bpftrace -l 'kprobe:*usb_hcd_giveback_urb*'); grep -Eq '^kprobe:([^:]+:)?usb_hcd_giveback_urb$' <<< "$probes" || die 'usb_hcd_giveback_urb probe unavailable'
root=${OUTPUT_DIR:-"$script_dir/results"}; mkdir -p "$root"
out=$(mktemp -d "$root/usb-urb-lifecycle-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
trace=$script_dir/trace-usb-urb-lifecycle.bt
timeout --signal=TERM --kill-after=10s "${duration}s" bpftrace -B none -e "$(<"$trace")" "$bus" "$dev" "$threshold" >"$out/trace.log" 2>&1 || rc=$?
rc=${rc:-0}; grep -q USB_URB_FINAL "$out/trace.log" || rc=1
printf 'Finished: %s (status=%s)\n' "$out" "$rc"; exit "$rc"
