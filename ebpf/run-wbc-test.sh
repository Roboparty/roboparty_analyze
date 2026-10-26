#!/usr/bin/env bash
# Run the existing WBC launcher as its normal user, with a bounded observer.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: bash run-wbc-test.sh [options] [-- WBC_OPTIONS...]
  --workspace PATH   WBC workspace (default: $HOME/rp1_deploy_wbc)
  --output PATH      Parent of a new, unique run directory
  --seconds N        Observation window, including builds (default: 1800)
  --threshold-us N   Slow event threshold (default: 5000)
  --can-irq N        Override automatic native IMU CAN IRQ discovery
  --usb-irq N        Override automatic HPM EHCI IRQ discovery
  --imu-iface NAME   Native CAN interface (default: can_hipnuc)
  --check            Read-only preflight and print plan; do not start anything
  --help
Run as the application user, not root. Observation uses sudo -n.
WBC defaults are preserved: both hands on, EGO and capture off.
The original launcher builds code and closes its existing named screen sessions.
This wrapper refuses those existing sessions before starting observation.
Ctrl-C/failure stops only this run's observer; background robot components may
still be running. Stopping observation is NOT an emergency stop.
USAGE
}

script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
workspace=${WBC_WORKSPACE:-"$HOME/rp1_deploy_wbc"}
output_root=${OUTPUT_DIR:-"$script_dir/results"}
duration=1800 threshold=5000 can_irq= usb_irq= iface=${IMU_IFACE:-can_hipnuc}
check=0
wbc_args=()
while (( $# )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --check) check=1; shift ;;
        --workspace|--output|--seconds|--threshold-us|--can-irq|--usb-irq|--imu-iface)
            (( $# >= 2 )) || die "Missing value for $1"
            case "$1" in
                --workspace) workspace=$2 ;; --output) output_root=$2 ;;
                --seconds) duration=$2 ;; --threshold-us) threshold=$2 ;;
                --can-irq) can_irq=$2 ;; --usb-irq) usb_irq=$2 ;; --imu-iface) iface=$2 ;;
            esac
            shift 2 ;;
        --) shift; wbc_args=("$@"); break ;;
        *) die "Unknown option: $1 (pass WBC options after --)" ;;
    esac
done
(( EUID != 0 )) || die 'Run as the normal WBC application user, not root'
for value in "$duration" "$threshold" ${can_irq:+"$can_irq"} ${usb_irq:+"$usb_irq"}; do
    [[ $value =~ ^[1-9][0-9]*$ && ${#value} -le 9 ]] || die 'Numeric options must be positive decimal integers'
done
(( duration <= 3600 )) || die '--seconds must be at most 3600'
[[ $iface =~ ^[a-zA-Z0-9_.:-]+$ ]] || die 'Invalid IMU interface name'
[[ -d $workspace ]] || die "Workspace missing: $workspace"
workspace=$(cd -- "$workspace" && pwd)
launcher=$workspace/tools/start_rp1_teleop.sh
[[ -r $launcher && -r $script_dir/run-link-stall.sh ]] || die 'WBC launcher or observer missing'
for tool in sudo python3 awk screen tee timeout bpftrace ethtool ip ps; do
    command -v "$tool" >/dev/null || die "Missing dependency: $tool"
done
if ! { [[ -r /sys/kernel/realtime && $(< /sys/kernel/realtime) == 1 ]] ||
       grep -qs '^CONFIG_PREEMPT_RT=y$' "/boot/config-$(uname -r)" ||
       { [[ -r /proc/config.gz ]] && zgrep -q '^CONFIG_PREEMPT_RT=y$' /proc/config.gz; }; }; then
    die 'Requires PREEMPT_RT'
fi
[[ -r /sys/kernel/btf/vmlinux ]] || die 'Running-kernel BTF missing'
[[ -d /sys/class/net/$iface ]] || die "IMU interface missing: $iface"
driver=$(basename -- "$(readlink -f -- "/sys/class/net/$iface/device/driver")")
[[ $driver == rockchip_canfd ]] || die "Expected rockchip_canfd, found $driver"

devices=()
for device in /sys/bus/usb/devices/*; do
    [[ -r $device/idVendor && -r $device/idProduct ]] || continue
    [[ $(< "$device/idVendor") == 1209 && $(< "$device/idProduct") == 2323 ]] || continue
    devices+=("$device")
done
(( ${#devices[@]} == 1 )) || die "Expected one HPM 1209:2323, found ${#devices[@]}"
device=${devices[0]}
bus=$((10#$(< "$device/busnum")))
dev=$((10#$(< "$device/devnum")))
mapfile -t can_candidates < <(awk -v name="$iface" '$1 ~ /^[0-9]+:$/ { for (i=2;i<=NF;i++) if ($i==name) {gsub(":", "", $1); print $1; break} }' /proc/interrupts)
mapfile -t usb_candidates < <(awk -v bus="usb$bus" '$1 ~ /^[0-9]+:$/ && /ehci/ { for (i=2;i<=NF;i++) if ($i ~ ("(^|:)" bus "$")) {gsub(":", "", $1); print $1; break} }' /proc/interrupts)
if [[ -z $can_irq ]]; then
    (( ${#can_candidates[@]} == 1 )) || die 'CAN IRQ ambiguous or missing; inspect /proc/interrupts and use --can-irq'
    can_irq=${can_candidates[0]}
fi
if [[ -z $usb_irq ]]; then
    (( ${#usb_candidates[@]} == 1 )) || die 'USB IRQ ambiguous or missing; inspect /proc/interrupts and use --usb-irq'
    usb_irq=${usb_candidates[0]}
fi
[[ $can_irq != "$usb_irq" ]] || die 'CAN and USB IRQ must differ'
can_line=$(awk -v key="$can_irq:" '$1==key' /proc/interrupts)
usb_line=$(awk -v key="$usb_irq:" '$1==key' /proc/interrupts)
[[ $can_line == *"$iface"* ]] || die 'Selected CAN IRQ does not match interface'
[[ $usb_line == *ehci* && $usb_line =~ usb${bus}([^0-9]|$) ]] || die 'Selected USB IRQ does not match HPM bus/EHCI'
sessions=$(screen -ls 2>/dev/null || true)
if grep -Eq '[0-9]+\.(inference_session|joy_session|dexhand_session|ego_session|capture_session)[[:space:]]' <<< "$sessions"; then
    die 'Existing WBC screen sessions found; stop them normally before this test (the original launcher would close them)'
fi

printf 'Application user: %s (uid=%s)\nWorkspace: %s\n' "$(id -un)" "$EUID" "$workspace"
printf 'CAN IRQ: %s\nUSB IRQ: %s; bus=%s device=%s\n' "$can_irq" "$usb_irq" "$bus" "$dev"
printf 'Observer: %ss, threshold=%sus, FIFO iteration probe disabled. Build time is INCLUDED.\n' "$duration" "$threshold"
printf 'WBC command: bash %q' "$launcher"; printf ' %q' "${wbc_args[@]}"; printf '\n'
printf 'Default WBC flow: hands on; EGO/capture off unless overridden after --.\n'
printf 'Checks above do not validate ROS builds, sudo access, kprobe attachment, or robot readiness.\n'
if (( check )); then
    printf 'CHECK ONLY: no observer, WBC, service, build, or output directory started.\n'
    exit 0
fi

mkdir -p -- "$output_root"
output=$(mktemp -d "$output_root/wbc-test-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
output=$(cd -- "$output" && pwd)
ready=$output/observer-ready.json
stop=$output/observer-stop
observer_pid=
launcher_started=0
observer_alive() {
    local state
    state=$(ps -o stat= -p "$observer_pid" 2>/dev/null) || return 1
    [[ -n $state && $state != Z* ]]
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n $observer_pid ]]; then
        : > "$stop"
        wait "$observer_pid" 2>/dev/null || true
    fi
    if (( launcher_started )); then
        printf 'WARNING: WBC/background robot components may still be running. Only this observer was stopped; no screen/session/robot shutdown was requested.\n' >&2
    fi
    printf 'Logs: %s\n' "$output"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot() {
    python3 - "$workspace" "$output/$1.json" "$launcher" "${wbc_args[@]}" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, time
root, target, launcher = map(pathlib.Path, sys.argv[1:4])
files = {launcher}
for base in (root / 'tools', root / 'src/inference', root / 'src/motors',
             root / 'src/imu', root / 'src/roboparty_dexhand/ros2',
             root / 'src/ego_driver/config', root / 'src/capture_recorder/config',
             root / 'assets', root / 'install'):
    if base.exists():
        for path in base.rglob('*'):
            if path.is_file() and path.suffix in ('.yaml', '.yml', '.json', '.xml', '.sh', '.bash',
                                                  '.onnx', '.cpp', '.hpp', '.c', '.h', '.py'):
                files.add(path)
hashes = {}
for path in sorted(files):
    try:
        with path.open('rb') as stream:
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
            hashes[str(path)] = digest.hexdigest()
    except OSError as exc:
        hashes[str(path)] = {'error': str(exc)}
def read(path):
    try:
        return pathlib.Path(path).read_text().strip().strip('\0')
    except OSError:
        return None
git = subprocess.run(['git', '-C', str(root), 'rev-parse', 'HEAD'], capture_output=True, text=True)
data = dict(realtime_ns=time.time_ns(), monotonic_ns=time.monotonic_ns(),
            boottime_ns=time.clock_gettime_ns(time.CLOCK_BOOTTIME), uid=os.getuid(),
            kernel=os.uname().release, boot_id=read('/proc/sys/kernel/random/boot_id'),
            board_serial=read('/proc/device-tree/serial-number'), workspace=str(root),
            git_head=git.stdout.strip() if git.returncode == 0 else None,
            command=['bash', str(launcher), *sys.argv[4:]], sha256=hashes)
target.write_text(json.dumps(data, indent=2) + '\n')
PY
}
snapshot before

# The root supervisor owns only the observer. A unique stop file lets the normal
# user request cleanup without signalling unrelated privileged processes.
sudo -n env OUTPUT_DIR="$output/ebpf" READY_FILE="$ready" IMU_IFACE="$iface" TRACE_RX_ITERATIONS=0 \
    bash -c '
set -u
stop=$1; parent=$2; shift 2
child=
finish() {
    trap - EXIT INT TERM
    if [[ -n $child ]]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
}
trap finish EXIT
trap "exit 143" TERM
bash "$@" & child=$!
while kill -0 "$child" 2>/dev/null; do
    [[ ! -e $stop ]] && kill -0 "$parent" 2>/dev/null || exit 130
    sleep 0.2
done
rc=0; wait "$child" || rc=$?
child=
printf "%s\n" "$rc" > "$stop.done"
exit "$rc"
' _ "$stop" "$$" "$script_dir/run-link-stall.sh" "$can_irq" "$usb_irq" "$duration" "$threshold" \
    > "$output/observer.log" 2>&1 &
observer_pid=$!
for (( attempt=0; attempt<200; attempt++ )); do
    observer_alive || die "Observer exited before readiness; see $output/observer.log"
    [[ ! -s $ready ]] || break
    sleep 0.2
done
[[ -s $ready ]] || die 'Observer readiness timed out after 40 seconds; WBC was not started'
python3 - "$ready" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    ready = json.load(stream)
if not isinstance(ready, dict) or not ready.get('output'):
    raise SystemExit('Invalid observer readiness marker')
print('Observer ready:', ready['output'])
PY
observer_alive || die 'Observer exited at the readiness boundary'
printf 'Observation is ready. Starting the original WBC launcher; builds count toward the window.\n'
launcher_started=1
launch_status=0
bash "$launcher" "${wbc_args[@]}" 2>&1 | tee "$output/wbc-launch.log" || launch_status=$?
coverage_incomplete=0
[[ ! -e $stop.done ]] || coverage_incomplete=1
snapshot after-launch
(( launch_status == 0 )) || die "WBC launcher failed (status=$launch_status); background components may still run"
(( coverage_incomplete == 0 )) || die 'Observation ended before WBC startup finished; build/startup exhausted or interrupted the monitored window'
printf 'WBC launcher returned. Waiting for the bounded observer; Ctrl-C stops observation only.\n'
observer_status=0
wait "$observer_pid" || observer_status=$?
observer_pid=
printf 'Observer finished: status=%s\n' "$observer_status"
exit "$observer_status"
