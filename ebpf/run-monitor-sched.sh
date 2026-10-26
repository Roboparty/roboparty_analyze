#!/usr/bin/env bash
# Observe an existing main thread only; never launch or signal the target.
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help ]]; then
    echo 'Usage: sudo bash run-monitor-sched.sh TID [SECONDS=1800] [THRESHOLD_US=5000]'
    exit 0
fi
(( $# >= 1 && $# <= 3 )) || die 'Expected TID [SECONDS] [THRESHOLD_US]'
target_tid=$1 duration=${2:-1800} threshold=${3:-5000}
for value in "$target_tid" "$duration" "$threshold"; do
    [[ $value =~ ^[1-9][0-9]*$ && ${#value} -le 9 ]] || die 'Arguments must be positive decimal integers'
done
(( duration <= 21600 )) || die 'Limit captures to six hours'
(( EUID == 0 )) || die 'Run as root'
[[ -r /proc/$target_tid/stat ]] || die 'Target TID does not exist'
for tool in bpftrace timeout tee; do command -v "$tool" >/dev/null || die "Missing: $tool"; done
script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
output_dir=${OUTPUT_DIR:-"$script_dir/results"}
mkdir -p -- "$output_dir"
log=$(mktemp "$output_dir/monitor-sched-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.log")
{
    date -u --iso-8601=ns
    uname -a
    printf 'boot_id=%s\n' "$(< /proc/sys/kernel/random/boot_id)"
    printf 'target_stat=%s\n' "$(< "/proc/$target_tid/stat")"
    printf 'duration_s=%s threshold_us=%s\n' "$duration" "$threshold"
} | tee "$log"
set +e
timeout --signal=INT --kill-after=90s "${duration}s" \
    bpftrace -B none "$script_dir/trace-monitor-sched.bt" "$target_tid" "$threshold" 2>&1 | tee -a "$log"
pipeline_status=("${PIPESTATUS[@]}")
set -e
printf 'Log: %s\n' "$log"
(( pipeline_status[1] == 0 )) || die 'Trace log write failed'
status=${pipeline_status[0]}
(( status == 0 || status == 124 )) || exit "$status"
grep -q '^MONITOR_SCHED_READY' "$log" || die 'Probes did not become ready'
grep -q '^MONITOR_SCHED_FINAL' "$log" || die 'Trace did not finish with a summary'
if ! grep -q '^@switch_in:' "$log"; then
    echo 'No target switch-in samples; this is not a health verdict.' >&2
    exit 2
fi
