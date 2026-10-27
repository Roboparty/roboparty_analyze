#!/usr/bin/env bash
# Read-only tracing. Does not configure CAN, submit CAN frames, or reset USB.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
if (( $# > 2 )); then
    die 'Usage: bash run-usb-giveback.sh [SECONDS=120] [THRESHOLD_US=5000]'
fi
duration=${1:-120}
threshold=${2:-5000}
[[ $duration =~ ^[1-9][0-9]*$ ]] || die 'SECONDS must be a positive integer'
[[ $threshold =~ ^[1-9][0-9]*$ ]] || die 'THRESHOLD_US must be a positive integer'
(( EUID == 0 )) || die 'Run as root (sudo bash run-usb-giveback.sh)'
command -v bpftrace >/dev/null || die 'Install bpftrace first: apt-get install bpftrace'
command -v timeout >/dev/null || die 'GNU timeout is required'
[[ -r /sys/kernel/btf/vmlinux ]] || die 'Running-kernel BTF is unavailable'
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")

devices=()
for device in /sys/bus/usb/devices/*; do
    [[ -r $device/idVendor && -r $device/idProduct ]] || continue
    [[ $(< "$device/idVendor") == 1209 && $(< "$device/idProduct") == 2323 ]] || continue
    devices+=("$device")
done
(( ${#devices[@]} == 1 )) || die "Expected one 1209:2323 device, found ${#devices[@]}"
device=${devices[0]}
bus=$((10#$(< "$device/busnum")))
dev=$((10#$(< "$device/devnum")))

probes=$(bpftrace -l 'kprobe:*usb_hcd_giveback_urb*')
for symbol in usb_hcd_giveback_urb __usb_hcd_giveback_urb; do
    grep -Fxq "kprobe:$symbol" <<< "$probes" || die "Unavailable kprobe: $symbol"
done

output_dir=${OUTPUT_DIR:-"$script_dir/results"}
mkdir -p -- "$output_dir"
log=$(mktemp "$output_dir/usb-giveback-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.log")
{
    date -u --iso-8601=ns
    uname -a
    bpftrace --version
    printf 'boot_id=%s\n' "$(< /proc/sys/kernel/random/boot_id)"
    printf 'usb_path=%s bus=%d dev=%d duration_s=%s threshold_us=%s\n' \
        "$(readlink -f -- "$device")" "$bus" "$dev" "$duration" "$threshold"
    printf 'Clock used by this bpftrace version: default nsecs (not wall-clock).\n'
} | tee "$log"

set +e
timeout --signal=INT --kill-after=15s "${duration}s" \
    bpftrace "$script_dir/trace-usb-giveback.bt" "$bus" "$dev" "$threshold" 2>&1 | tee -a "$log"
pipeline_status=("${PIPESTATUS[@]}")
set -e
printf 'Log: %s\n' "$log"
(( pipeline_status[1] == 0 )) || die 'Failed to write trace log'
status=${pipeline_status[0]}
if (( status != 0 && status != 124 )); then
    exit "$status"
fi
grep -q 'Final maps:' "$log" || die 'Trace did not finish with a summary'
if ! grep -q '^@paired_count\[' "$log"; then
    printf 'WARNING: probes ran, but no matching completions were measured.\n' >&2
    exit 2
fi
