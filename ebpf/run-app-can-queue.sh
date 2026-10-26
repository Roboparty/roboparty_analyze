#!/usr/bin/env bash
# Only observes existing threads. Does not start, stop or configure the robot.
set -euo pipefail
if (( $# < 3 || $# > 5 )); then
    echo 'Usage: bash run-app-can-queue.sh PID RX_TID IFACE [SECONDS=20] [--compile-only]' >&2
    exit 1
fi
app_pid=$1 rx_tid=$2 iface=$3 duration=${4:-20} mode=${5:-run}
for number in "$app_pid" "$rx_tid" "$duration"; do
    [[ $number =~ ^[1-9][0-9]{0,8}$ ]] || exit 1
done
(( duration <= 60 )) || { echo 'Maximum capture: 60 seconds' >&2; exit 1; }
[[ $mode == run || $mode == --compile-only ]] || exit 1
[[ -r /proc/$app_pid/task/$rx_tid/stat && $iface =~ ^[a-zA-Z0-9_.:-]+$ ]] || exit 1
[[ -r /sys/class/net/$iface/ifindex && $(< /sys/class/net/$iface/type) == 280 ]] || exit 1
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
bpf=${BPFTRACE_BIN:-"$script_dir/bin/bpftrace"}
[[ -x $bpf ]] || bpf=$(command -v bpftrace)
trace_cpu=$(python3 -c 'import os; print(max(os.sched_getaffinity(0)))')
output_root=${OUTPUT_DIR:-"$script_dir/results"}
mkdir -p -- "$output_root"
output=$(mktemp -d "$output_root/app-can-queue-XXXXXXXX")
{
    date -u +%FT%TZ
    cat /proc/sys/kernel/random/boot_id
    cat "/proc/$app_pid/task/$rx_tid/stat" "/proc/$app_pid/task/$rx_tid/status"
    "$bpf" --version
    python3 -c 'import time; print("monotonic_ns", time.monotonic_ns(), "realtime_ns", time.time_ns())'
} > "$output/metadata.txt"
echo "OUTPUT=$output"
export BPFTRACE_MAX_MAP_KEYS=32768 BPFTRACE_MAP_KEYS_MAX=32768
args=()
[[ $mode != --compile-only ]] || args+=(--mode codegen --emit-elf "$output/program.o")
timeout --signal=INT --kill-after=10s "$((duration + 60))s" \
    taskset -c "$trace_cpu" "$bpf" "${args[@]}" "$script_dir/trace-app-can-queue.bt" \
    "$app_pid" "$rx_tid" "$(< /sys/class/net/$iface/ifindex)" "$duration" > "$output/trace.log" 2>&1
if [[ $mode == run ]]; then
    grep -q '^APP_CAN_QUEUE_FINAL ' "$output/trace.log"
    ! grep -Eiq 'ERROR:|lost [0-9]+ events|failed to attach|Map full|retcode: -' "$output/trace.log"
fi
