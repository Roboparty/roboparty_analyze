#!/usr/bin/env bash
# Observe the existing CAN workload. No device configuration or transmission.
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: sudo bash %s [SECONDS=120] [THRESHOLD_US=5000] [IFACE=all]\n' "$0"
    printf 'Environment: BPFTRACE_BIN=/path/to/bpftrace OUTPUT_DIR=/path/to/results\n'
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
(( $# <= 3 )) || { usage >&2; exit 1; }
duration=${1:-120} threshold=${2:-5000} iface=${3:-all}
for number in "$duration" "$threshold"; do
    [[ $number =~ ^[1-9][0-9]*$ && ${#number} -le 9 ]] || die 'Numbers must be positive decimal integers (at most 9 digits)'
done
(( duration <= 3600 )) || die 'Limit each capture to 3600 seconds'
(( EUID == 0 )) || die 'Run as root'
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
bpf=${BPFTRACE_BIN:-"$script_dir/bin/bpftrace"}
if [[ ! -x $bpf ]]; then
    [[ -z ${BPFTRACE_BIN:-} ]] || die "BPFTRACE_BIN is not executable: $bpf"
    bpf=$(command -v bpftrace) || die 'bpftrace is unavailable'
fi
version=$("$bpf" --version)
[[ $version =~ v([0-9]+)\.([0-9]+) ]] || die "Unrecognized version: $version"
(( BASH_REMATCH[1] > 0 || BASH_REMATCH[2] >= 27 )) || die 'This tracer requires bpftrace >= 0.27; see README.md (system bpftrace need not be replaced)'
for tool in timeout ip python3; do command -v "$tool" >/dev/null || die "Missing: $tool"; done
for module in vmlinux can can_dev can_raw gs_usb rockchip_canfd; do
    [[ -r /sys/kernel/btf/$module ]] || die "Missing running-kernel/module BTF: $module"
done
ifindex=0
if [[ $iface != all ]]; then
    [[ $iface =~ ^[a-zA-Z0-9_.:-]+$ && -r /sys/class/net/$iface/ifindex ]] || die "Unknown interface: $iface"
    [[ $(< "/sys/class/net/$iface/type") == 280 ]] || die "$iface is not CAN"
    ifindex=$(< "/sys/class/net/$iface/ifindex")
fi
devices=()
for device in /sys/bus/usb/devices/*; do
    [[ -r $device/idVendor && -r $device/idProduct ]] || continue
    [[ $(< "$device/idVendor") == 1209 && $(< "$device/idProduct") == 2323 ]] || continue
    devices+=("$device")
done
(( ${#devices[@]} == 1 )) || die "Expected one HPM 1209:2323 device, found ${#devices[@]}"
device=${devices[0]}
bus=$((10#$(< "$device/busnum")))
dev=$((10#$(< "$device/devnum")))
output_root=${OUTPUT_DIR:-"$script_dir/results"}
mkdir -p -- "$output_root"
output=$(mktemp -d "$output_root/can-path-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
snapshot() {
    {
        python3 -c 'import time; print("realtime_ns=%d monotonic_ns=%d boottime_ns=%d" % (time.time_ns(), time.monotonic_ns(), time.clock_gettime_ns(time.CLOCK_BOOTTIME)))'
        uname -a
        printf '%s\n' "$version"
        printf 'boot_id=%s\n' "$(< /proc/sys/kernel/random/boot_id)"
        printf 'bus=%s dev=%s usb_path=%s iface=%s ifindex=%s\n' "$bus" "$dev" "$(readlink -f -- "$device")" "$iface" "$ifindex"
        timeout 3s ip -details -statistics link show type can || true
        cat /proc/interrupts /proc/softirqs
        for profile in /sys/kernel/tracing/kprobe_profile /sys/kernel/debug/tracing/kprobe_profile; do
            if [[ -r $profile ]]; then cat "$profile"; break; fi
        done
    } > "$output/$1.txt" 2>&1
}
snapshot before
printf 'Output: %s\n' "$output"
child=''
interrupted=0
cleanup() {
    if [[ -n $child ]]; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'interrupted=1; cleanup' INT TERM
# Compilation/attachment is outside the capture duration; the BPF timer exits
# after BEGIN. The outer timeout is only a startup/shutdown watchdog.
timeout --signal=INT --kill-after=15s "$((duration + 90))s" \
    "$bpf" -B none -k "$script_dir/trace-can-path.bt" "$bus" "$dev" "$threshold" "$ifindex" "$duration" > "$output/trace.log" 2>&1 &
child=$!
rc=0
wait "$child" || rc=$?
child=''
snapshot after
status=0
(( rc == 0 )) || status=1
grep -q 'CAN_PATH_FINAL:' "$output/trace.log" || status=1
if grep -Eiq 'ERROR:|failed to attach|lost [0-9]+ events|dropped [0-9]+|WARNING:.*(helper|probe_read|map_update)' "$output/trace.log"; then status=1; fi
if [[ ! -r $device/devnum ]] || (( 10#$(< "$device/devnum") != dev )); then
    printf 'WARNING: HPM identity changed during capture.\n' >&2
    status=1
fi
if [[ $iface != all ]] && { [[ ! -r /sys/class/net/$iface/ifindex ]] || [[ $(< "/sys/class/net/$iface/ifindex") != "$ifindex" ]]; }; then
    printf 'WARNING: selected CAN interface identity changed during capture.\n' >&2
    status=1
fi
if ! grep -q '^@function_pairs\[' "$output/trace.log"; then
    printf 'WARNING: no paired CAN path samples.\n' >&2
    (( status != 0 )) || status=2
fi
(( interrupted == 0 )) || status=130
grep -E '^@(ifname|function_pairs|function_max_us|queue_delivered|queue_to_delivery_max_us|napi_wait_max_us|socket_drop_reason|native_fifo_overruns)\[' "$output/trace.log" || true
printf 'Finished: %s (status=%s). Missing stages remain unverified.\n' "$output" "$status"
exit "$status"
