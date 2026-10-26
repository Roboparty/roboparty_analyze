#!/usr/bin/env bash
# Observe only: no CAN configuration/transmission or USB reset.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: sudo bash %s CAN_IRQ USB_IRQ [SECONDS=120] [THRESHOLD_US=5000]\n' "$0"
    printf 'Obtain current IRQ numbers from /proc/interrupts; do not reuse historical IRQ 77 blindly.\n'
    printf 'Environment: IMU_IFACE=can_hipnuc OUTPUT_DIR=... TRACE_RX_ITERATIONS=0|1\n'
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
(( $# >= 2 && $# <= 4 )) || { usage >&2; exit 1; }
can_irq=$1 usb_irq=$2 duration=${3:-120} threshold=${4:-5000}
for number in "$can_irq" "$usb_irq" "$duration" "$threshold"; do
    [[ $number =~ ^[1-9][0-9]*$ && ${#number} -le 9 ]] || die 'Arguments must be positive decimal integers (at most 9 digits)'
done
[[ $can_irq != "$usb_irq" ]] || die 'CAN and USB must have distinct IRQs'
(( duration <= 3600 )) || die 'Limit each capture to 3600 seconds'
(( EUID == 0 )) || die 'Run as root'
for tool in bpftrace timeout python3 ethtool ip ps; do
    command -v "$tool" >/dev/null || die "Missing dependency: $tool"
done
[[ -r /sys/kernel/btf/vmlinux ]] || die 'Running-kernel BTF is unavailable'
if ! { [[ -r /sys/kernel/realtime && $(< /sys/kernel/realtime) == 1 ]] ||
       grep -qs '^CONFIG_PREEMPT_RT=y$' "/boot/config-$(uname -r)" ||
       { [[ -r /proc/config.gz ]] && zgrep -q '^CONFIG_PREEMPT_RT=y$' /proc/config.gz; }; }; then
    die 'This runner requires PREEMPT_RT (threaded device IRQs)'
fi
selftest=$(timeout --signal=TERM --kill-after=2s 10s bpftrace -e 'BEGIN { printf("BPFTRACE_SELFTEST_OK\n"); exit(); }' 2>&1) || die "bpftrace self-test failed: $selftest"
grep -Fxq 'BPFTRACE_SELFTEST_OK' <<< "$selftest" || die "bpftrace BEGIN probe failed: $selftest"
iface=${IMU_IFACE:-can_hipnuc}
[[ $iface =~ ^[a-zA-Z0-9_.:-]+$ && -d /sys/class/net/$iface ]] || die "Invalid or missing IMU interface: $iface"
driver=$(basename -- "$(readlink -f -- "/sys/class/net/$iface/device/driver")")
[[ $driver == rockchip_canfd ]] || die "Expected rockchip_canfd for $iface, found $driver"
iterations=${TRACE_RX_ITERATIONS:-0}
[[ $iterations == 0 || $iterations == 1 ]] || die 'TRACE_RX_ITERATIONS must be 0 or 1'
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ready_file=${READY_FILE:-}
[[ -z $ready_file || ( $ready_file == /* && ! -e $ready_file ) ]] || die 'READY_FILE must be a new absolute path'

irq_tid() {
    local irq=$1 comm_file name found=()
    for comm_file in /proc/[0-9]*/comm; do
        [[ -r $comm_file ]] || continue
        IFS= read -r name < "$comm_file" || continue
        if [[ $name == "irq/$irq-"* ]]; then
            name=${comm_file%/comm}; found+=("${name##*/}")
        fi
    done
    (( ${#found[@]} == 1 )) || die "Expected one IRQ thread for IRQ $irq, found ${#found[@]}"
    printf '%s\n' "${found[0]}"
}
can_tid=$(irq_tid "$can_irq")
usb_tid=$(irq_tid "$usb_irq")
can_line=$(awk -v irq="$can_irq:" '$1 == irq' /proc/interrupts)
usb_line=$(awk -v irq="$usb_irq:" '$1 == irq' /proc/interrupts)
[[ $can_line == *"$iface"* ]] || die "IRQ $can_irq is not labelled $iface in /proc/interrupts"
[[ $usb_line == *ehci* ]] || die "IRQ $usb_irq is not labelled EHCI in /proc/interrupts"

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
[[ $usb_line =~ usb${bus}([^0-9]|$) ]] || die "IRQ $usb_irq does not name USB bus $bus"
usb_probes=$(bpftrace -l 'kprobe:*usb_hcd_giveback_urb*')
for symbol in usb_hcd_giveback_urb __usb_hcd_giveback_urb; do
    grep -Eq "^kprobe:([^:]+:)?$symbol$" <<< "$usb_probes" || die "Unavailable kprobe: $symbol"
done

probes=$(bpftrace -l 'kprobe:*rkcanfd_handle_rx_int*')
grep -Eq '^kprobe:([^:]+:)?rkcanfd_handle_rx_int$' <<< "$probes" || die 'rkcanfd_handle_rx_int is not probeable (module loaded? symbol inlined?)'
can_program=$(< "$script_dir/trace-can-irq.bt")
if (( iterations )); then
    grep -Eq '^kprobe:([^:]+:)?rkcanfd_handle_rx_int_one$' <<< "$probes" || die 'Iteration probe unavailable; rerun with TRACE_RX_ITERATIONS=0'
    can_program+=$'\n'
    can_program+=$(< "$script_dir/trace-can-iterations.bt")
fi
can_program+=$'\ninterval:s:1 /!@wrapper_ready/ { @wrapper_ready = 1; printf("LINK_STALL_PROBE_READY can nsecs=%llu\\n", nsecs); }\n'
usb_program=$(< "$script_dir/trace-usb-giveback.bt")
usb_program+=$'\ninterval:s:1 /!@wrapper_ready/ { @wrapper_ready = 1; printf("LINK_STALL_PROBE_READY usb nsecs=%llu\\n", nsecs); }\n'

output_root=${OUTPUT_DIR:-"$script_dir/results"}
mkdir -p -- "$output_root"
output=$(mktemp -d "$output_root/link-stall-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
snapshot() {
    local phase=$1
    {
        python3 -c 'import time; print("realtime_ns=%d monotonic_ns=%d boottime_ns=%d" % (time.time_ns(), time.monotonic_ns(), time.clock_gettime_ns(time.CLOCK_BOOTTIME)))'
        uname -a
        bpftrace --version
        printf 'boot_id=%s\n' "$(< /proc/sys/kernel/random/boot_id)"
        printf 'iface=%s can_irq=%s usb_irq=%s can_tid=%s usb_tid=%s iterations=%s\n' "$iface" "$can_irq" "$usb_irq" "$can_tid" "$usb_tid" "$iterations"
        printf 'usb_path=%s bus=%s dev=%s\n' "$(readlink -f -- "$device")" "$bus" "$dev"
        printf 'sched_rt_period_us=%s sched_rt_runtime_us=%s\n' "$(< /proc/sys/kernel/sched_rt_period_us)" "$(< /proc/sys/kernel/sched_rt_runtime_us)"
        cat /proc/interrupts /proc/softirqs
        for irq in "$can_irq" "$usb_irq"; do
            printf 'IRQ %s affinity: ' "$irq"
            cat "/proc/irq/$irq/smp_affinity_list" || true
        done
        ps -eLo pid,tid,psr,cls,rtprio,comm
        for tid in "$can_tid" "$usb_tid"; do
            cat "/proc/$tid/status" || true
        done
        timeout 3s ip -details -statistics link show dev "$iface" || true
        timeout 3s ethtool -S "$iface" || true
    } > "$output/$phase.txt" 2>&1
}
snapshot before
printf 'Output: %s\n' "$output"
pids=()
interrupted=0
stop_children() {
    local child
    for child in "${pids[@]}"; do kill -TERM "$child" 2>/dev/null || true; done
    for child in "${pids[@]}"; do wait "$child" 2>/dev/null || true; done
}
trap stop_children EXIT
trap 'interrupted=1; trap "" INT TERM; stop_children' INT TERM

# GNU timeout relays TERM to its process group. bpftrace handles TERM by dumping END/maps.
timeout --signal=TERM --kill-after=10s "${duration}s" \
    bpftrace -B none -e "$can_program" "$can_tid" "$usb_tid" "$threshold" "$iterations" > "$output/can-irq.log" 2>&1 &
pids+=("$!")
timeout --signal=TERM --kill-after=10s "${duration}s" \
    bpftrace -B none -e "$usb_program" "$bus" "$dev" "$threshold" > "$output/usb-giveback.log" 2>&1 &
pids+=("$!")
status=0
capture_start=$SECONDS
ready=0
while (( SECONDS - capture_start < duration && interrupted == 0 )); do
    alive=1
    for child in "${pids[@]}"; do kill -0 "$child" 2>/dev/null || alive=0; done
    if (( alive == 0 )); then
        (( SECONDS - capture_start >= duration - 2 )) || status=1
        break
    fi
    if grep -Eiq 'ERROR:|failed to attach|lost [0-9]+ events' "$output/can-irq.log" "$output/usb-giveback.log"; then
        status=1; break
    fi
    if (( ready == 0 )); then
        if grep -q '^LINK_STALL_PROBE_READY can ' "$output/can-irq.log" &&
           grep -q '^LINK_STALL_PROBE_READY usb ' "$output/usb-giveback.log"; then
            ready=1
            if [[ -n $ready_file ]]; then
                python3 - "$ready_file" "$output" <<'PY'
import json, os, sys, tempfile, time
path, output = sys.argv[1:]
data = dict(output=output, pid=os.getppid(), realtime_ns=time.time_ns(),
            monotonic_ns=time.monotonic_ns(), boottime_ns=time.clock_gettime_ns(time.CLOCK_BOOTTIME))
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".ready-")
try:
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
            fi
            printf 'LINK_STALL_READY: %s\n' "$output"
        elif (( SECONDS - capture_start >= 30 )); then
            printf 'ERROR: probes did not become ready within 30 seconds\n' >&2
            status=1; break
        fi
    fi
    sleep 0.2 & wait $! || true
done
(( ready == 1 )) || status=1
if (( status != 0 || interrupted )); then stop_children; fi
for child in "${pids[@]}"; do
    rc=0
    wait "$child" || rc=$?
    if (( rc != 0 && rc != 124 )); then status=1; fi
done
pids=()
snapshot after
if [[ ! -r $device/devnum ]] || (( 10#$(< "$device/devnum") != dev )); then
    printf 'WARNING: USB device disappeared or changed address; capture identity is no longer valid.\n' >&2
    status=1
fi
for tid in "$can_tid" "$usb_tid"; do
    [[ -r /proc/$tid/comm ]] || { printf 'WARNING: IRQ thread %s disappeared.\n' "$tid" >&2; status=1; }
done
grep -q 'CAN_IRQ_FINAL:' "$output/can-irq.log" || status=1
if grep -q 'NO_CAN_SAMPLES:' "$output/can-irq.log"; then status=1; fi
grep -q 'Final maps:' "$output/usb-giveback.log" || status=1
if ! grep -q '^@paired_count\[' "$output/usb-giveback.log"; then status=1; fi
if grep -Eiq 'lost [0-9]+ events|dropped [0-9]+|ERROR:|failed to attach' "$output/can-irq.log" "$output/usb-giveback.log"; then status=1; fi
(( interrupted == 0 )) || status=130
printf 'Finished: %s (status=%s). Read logs and before/after snapshots together.\n' "$output" "$status"
exit "$status"
