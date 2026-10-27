#!/usr/bin/env bash
# Observe existing threads only. Never launch or signal the robot application.
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    echo 'Usage: sudo bash run-cpu-can-sched.sh CPU CAN_IRQ_TID USB_IRQ_TID CAN_RX_TID CAN_TX_TID [SECONDS=30] [THRESHOLD_US=5000]'
    echo 'Use current TIDs from ps -eLo pid,tid,psr,cls,rtprio,comm; IRQ arguments are thread IDs, not IRQ numbers.'
    echo 'OUTPUT_DIR selects output parent; BPFTRACE_BIN selects bpftrace; TRACER_CPU defaults to the highest allowed CPU other than CPU.'
    echo 'COMPILE_ONLY=1 checks compilation without attaching. Runtime overhead is not yet qualified for robot operation.'
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
(( $# >= 5 && $# <= 7 )) || { usage >&2; exit 1; }
capture_cpu=$1 can_tid=$2 usb_tid=$3 rx_tid=$4 tx_tid=$5 duration=${6:-30} threshold=${7:-5000}
[[ $capture_cpu =~ ^(0|[1-9][0-9]{0,5})$ && -d /sys/devices/system/cpu/cpu$capture_cpu ]] || die 'Invalid CPU'
for value in "$can_tid" "$usb_tid" "$rx_tid" "$tx_tid" "$duration" "$threshold"; do
    [[ $value =~ ^[1-9][0-9]{0,8}$ ]] || die 'TIDs, duration and threshold must be positive decimal integers'
done
(( duration <= 3600 )) || die 'Capture is limited to 3600 seconds'
(( EUID == 0 )) || die 'Run as root'
declare -A seen=()
for target_tid in "$can_tid" "$usb_tid" "$rx_tid" "$tx_tid"; do
    [[ -r /proc/$target_tid/stat && -z ${seen[$target_tid]:-} ]] || die 'Supply four distinct existing TIDs'
    seen[$target_tid]=1
done
for tool in timeout python3 ps taskset; do command -v "$tool" >/dev/null || die "Missing: $tool"; done
tracer_cpu=$(python3 - "$capture_cpu" "${TRACER_CPU:-auto}" <<'PY'
import os, sys
capture = int(sys.argv[1])
allowed = os.sched_getaffinity(0) - {capture}
value = max(allowed) if sys.argv[2] == 'auto' and allowed else sys.argv[2]
if not str(value).isdigit() or int(value) not in allowed:
    raise SystemExit('TRACER_CPU must be an allowed CPU other than the observed CPU')
print(value)
PY
) || die 'Cannot select a separate tracer CPU'
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
bpf=${BPFTRACE_BIN:-"$script_dir/bin/bpftrace"}
if [[ ! -x $bpf ]]; then
    [[ -z ${BPFTRACE_BIN:-} ]] || die "BPFTRACE_BIN is not executable: $bpf"
    bpf=$(command -v bpftrace) || die 'bpftrace is unavailable'
fi
compile_only=${COMPILE_ONLY:-0}
[[ $compile_only == 0 || $compile_only == 1 ]] || die 'COMPILE_ONLY must be 0 or 1'
export BPFTRACE_MAP_KEYS_MAX=8192
export BPFTRACE_MAX_MAP_KEYS=8192
output_root=${OUTPUT_DIR:-"$script_dir/results"}
mkdir -p -- "$output_root"
output=$(mktemp -d "$output_root/cpu-can-sched-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
snapshot() {
    local phase=$1 target_tid fd
    {
        python3 -c 'import time; print("realtime_ns=%d monotonic_ns=%d" % (time.time_ns(), time.monotonic_ns()))'
        uname -a
        "$bpf" --version
        printf 'boot_id=%s\n' "$(< /proc/sys/kernel/random/boot_id)"
        printf 'cpu=%s can_tid=%s usb_tid=%s rx_tid=%s tx_tid=%s duration=%s threshold_us=%s\n' "$capture_cpu" "$can_tid" "$usb_tid" "$rx_tid" "$tx_tid" "$duration" "$threshold"
        printf 'tracer_userspace_cpu=%s\n' "$tracer_cpu"
        ps -eLo pid,tid,psr,cls,rtprio,comm
        cat /proc/interrupts /proc/softirqs
        for fd in /sys/kernel/tracing/events/sched/sched_switch/format /sys/kernel/debug/tracing/events/sched/sched_switch/format; do
            if [[ -r $fd ]]; then cat "$fd"; break; fi
        done
        for target_tid in "$can_tid" "$usb_tid" "$rx_tid" "$tx_tid"; do
            printf '\nTID=%s\n' "$target_tid"
            for fd in stat status wchan syscall; do
                cat "/proc/$target_tid/$fd" || true
            done
            ls -l "/proc/$target_tid/fd" || true
        done
    } > "$output/$phase.txt" 2>&1
}
snapshot before
printf 'Output: %s\n' "$output"
if (( compile_only )); then
    taskset -c "$tracer_cpu" "$bpf" --mode codegen "$script_dir/trace-cpu-can-sched.bt" \
        "$capture_cpu" "$can_tid" "$usb_tid" "$rx_tid" "$tx_tid" "$threshold" \
        > "$output/compile.log" 2>&1 || die "Compilation failed: $output/compile.log"
    printf 'Compiled without attachment: %s\n' "$output"
    exit 0
fi
set +e
timeout --signal=INT --kill-after=15s "${duration}s" \
    taskset -c "$tracer_cpu" "$bpf" -B none "$script_dir/trace-cpu-can-sched.bt" \
    "$capture_cpu" "$can_tid" "$usb_tid" "$rx_tid" "$tx_tid" "$threshold" \
    > "$output/sched.log" 2>&1
status=$?
set -e
snapshot after
(( status == 0 || status == 124 )) || die "Tracer failed (status=$status): $output"
grep -q '^CPU_CAN_SCHED_READY ' "$output/sched.log" || die 'No READY marker'
grep -q '^CPU_CAN_SCHED_FINAL ' "$output/sched.log" || die 'No final marker'
if grep -Eiq 'lost [0-9]+ events|dropped [0-9]+|ERROR:|failed to attach' "$output/sched.log"; then
    die "Incomplete trace; do not interpret as a full CPU timeline: $output"
fi
grep -q '^@switch_ring\[' "$output/sched.log" || die 'No switch samples'
python3 - "$output/sched.log" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
rows = re.findall(r'^@switch_ring\[(\d+)\]: \((\d+),', text, re.M)
total = re.search(r'^@switch_seq: (\d+)$', text, re.M)
if not total:
    raise SystemExit('No switch sequence total; incomplete ring export')
total = int(total[1])
seq = sorted(int(n) for _, n in rows)
if seq != list(range(max(0, total - 8192), total)):
    raise SystemExit('Switch ring has missing/duplicate sequences; incomplete timeline')
if any(int(slot) != int(n) % 8192 for slot, n in rows):
    raise SystemExit('Switch ring slot/sequence mismatch')
print(f'Validated {len(rows)} retained switch records, total={total}; older records overwritten intentionally.')
PY
printf 'Finished: %s. Map rings overwrite old slots intentionally; inspect trigger, frozen and sequence boundaries.\n' "$output"
