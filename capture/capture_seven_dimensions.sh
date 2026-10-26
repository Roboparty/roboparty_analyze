#!/bin/bash
# Copyright (C) 2026 wentywenty
# Orchestrates the seven capture dimensions: session lifecycle, service
# state and manifest. Does not implement any capture logic itself.
# SPDX-License-Identifier: GPL-3.0
set -euo pipefail

interfaces=(can0 can1 can2 can3)

session_root=${SESSION_ROOT:-/home/robo/robopi-logs}
first_output=${1:-$session_root/seven-$(date +%Y%m%d-%H%M%S)}
# Subsequent auto-rotated sessions are named the same way, under this
# directory, regardless of whether the first session's path was explicit.
rotate_root=$(dirname "$first_output")
# 0 disables rotation: a single session runs until stopped, matching the
# pre-rotation behavior exactly.
rotate_secs=${SESSION_MAX_DURATION_SECS:-1800}
hpm_service=${HPM_LOG_CAPTURE_SERVICE:-hpm-log-capture.service}
bms_service=${BMS_SERVICE:-bms.service}
capture_dir=${USBCAN_CAPTURE_DIR:-/run/usbcan}
interval=${CAN_DETAILS_INTERVAL:-1}
screen_session=${INFERENCE_SCREEN_SESSION:-inference_session}
# Board identity: serial from the device tree (raw bytes, strip \0 and
# keep only JSON-safe chars), falling back to machine-id; boot_id ties the
# session to this boot (matches journalctl --list-boots).
board_serial=$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\0' | tr -cd 'a-zA-Z0-9-' || true)
[[ -n $board_serial ]] || board_serial=$(tr -cd 'a-zA-Z0-9-' < /etc/machine-id 2>/dev/null || true)
boot_id=$(tr -cd 'a-zA-Z0-9-' < /proc/sys/kernel/random/boot_id 2>/dev/null || true)

die() { echo "robopi-seven-capture: $*" >&2; exit 1; }
now() { date +%s.%6N; }

if [[ ${SEVEN_ALLOW_NON_ROOT:-no} != yes && $EUID -ne 0 ]]; then die "run with sudo"; fi
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"
[[ $interval =~ ^[0-9]+([.][0-9]+)?$ && $interval != 0 ]] || die "CAN_DETAILS_INTERVAL must be positive"
[[ $rotate_secs =~ ^[0-9]+$ ]] || die "SESSION_MAX_DURATION_SECS must be a non-negative integer"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dimension_dir=${SEVEN_DIMENSIONS_DIR:-$script_dir/../dimensions}
if [[ ! -x $dimension_dir/01_bms_status.sh && -x /opt/roboparty/lib/roboparty-analyze/dimensions/01_bms_status.sh ]]; then
    dimension_dir=/opt/roboparty/lib/roboparty-analyze/dimensions
fi
[[ -x $dimension_dir/01_bms_status.sh ]] || die "dimension scripts not found: $dimension_dir"
ring_capture=${USBCAN_RING_CAPTURE_COMMAND:-$script_dir/capture_usbcan_ring.sh}
if [[ ! -x $ring_capture && -x /opt/roboparty/bin/usbcan-capture ]]; then
    ring_capture=/opt/roboparty/bin/usbcan-capture
fi
[[ -x $ring_capture ]] || die "USB-CAN ring capture command not found: $ring_capture"
cleanup_command=${SESSION_CLEANUP_COMMAND:-$script_dir/cleanup_sessions.sh}
if [[ ! -x $cleanup_command && -x /opt/roboparty/bin/robopi-session-cleanup ]]; then
    cleanup_command=/opt/roboparty/bin/robopi-session-cleanup
fi

# stop_requested is set only by a real external signal (systemctl stop,
# Ctrl-C); rotate_requested is set only by our own internal timer (SIGUSR1).
# Session rotation reuses the exact same teardown as a real stop, then
# loops back for a fresh session instead of letting the script exit.
stop_requested=no
rotate_requested=no
trap 'stop_requested=yes' INT TERM
trap 'rotate_requested=yes' USR1

next_output_path() {
    # Defensively guard against a same-second collision with an existing
    # directory (only plausible in rapid-rotation testing, not production
    # with the 1800s default), instead of failing the whole capture.
    local candidate
    candidate="$rotate_root/seven-$(date +%Y%m%d-%H%M%S)"
    while [[ -e $candidate ]]; do
        sleep 1
        candidate="$rotate_root/seven-$(date +%Y%m%d-%H%M%S)"
    done
    printf '%s\n' "$candidate"
}

run_session() {
    local output=$1
    local capture_pid= dimension_pids=() rotate_timer_pid=
    local can_pid= failed_child= failure=0 capture_status=0 can_status=0 pid
    local -A critical_names=() signalled=()

    [[ ! -e $output ]] || die "session directory already exists: $output"

    # Clean up expired sessions (age/total size) before checking space and
    # creating the new session directory.
    if [[ -x $cleanup_command ]]; then
        "$cleanup_command" || echo "robopi-seven-capture: session cleanup failed, continuing" >&2
    fi

    local session_parent
    session_parent=$(dirname "$output")
    mkdir -p "$session_parent"
    # Preflight: the target partition must fit the ring cap plus a margin.
    # Fail loudly here rather than let dimensions silently write 0-byte files.
    local need_kb have_kb
    need_kb=$(( (${USBCAN_FILE_SIZE_MB:-64} * ${USBCAN_FILE_COUNT:-8} + 512) * 1024 ))
    have_kb=$(df -Pk "$session_parent" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    [[ -n $have_kb && $have_kb -ge $need_kb ]] || \
        die "insufficient space in $session_parent: need ${need_kb} KiB, available ${have_kb:-unknown} KiB"

    mkdir -p "$output"
    local start_unix
    start_unix=$(now)
    printf '{\n  "started_at_unix": %s,\n  "boot_id": "%s",\n  "board_serial": "%s",\n  "interfaces": ["can0", "can1", "can2", "can3"],\n  "capture_dir": "%s",\n  "capture_service": "usbcan-capture.service",\n  "hpm_service": "%s",\n  "bms_service": "%s",\n  "inference_screen_session": "%s"\n}\n' \
        "$start_unix" "$boot_id" "$board_serial" "$capture_dir" "$hpm_service" "$bms_service" "$screen_session" > "$output/manifest.json"

    # Create the fixed session layout up front; dimensions stay empty when
    # their hardware or tool is unavailable.
    : > "$output/bms-status.txt"
    : > "$output/can-details.jsonl"
    : > "$output/dmesg-live.txt"
    : > "$output/hpm-uart-live.txt"
    : > "$output/can.log"
    : > "$output/inference-session.txt"
    : > "$output/thermal.txt"

    systemctl start "$hpm_service" || true

    # Closed PCAP segments stay in persistent storage without mirroring.
    # The session guard bounds the active session's size.
    mkdir -p "$capture_dir"
    output=$(realpath "$output")
    ln -sfn "$output" "$capture_dir/current-session"
    CAPTURE_DIR="$output" CAPTURE_ROLLING=no USBCAN_ALLOW_NON_RUN_CAPTURE_DIR=yes \
        "$ring_capture" > "$output/usb-capture.txt" 2>&1 & capture_pid=$!
    critical_names[$capture_pid]=usb
    "$dimension_dir/01_bms_status.sh" > "$output/bms-status.txt" 2>&1 & dimension_pids+=("$!")
    critical_names[$!]=bms
    "$dimension_dir/02_can_details.sh" "$output/can-details.jsonl" "$interval" & dimension_pids+=("$!")
    critical_names[$!]=can-details
    "$dimension_dir/03_kernel_dmesg.sh" > "$output/dmesg-live.txt" 2>&1 & dimension_pids+=("$!")
    critical_names[$!]=kernel
    "$dimension_dir/04_hpm_uart.sh" "$hpm_service" > "$output/hpm-uart-live.txt" 2>&1 & dimension_pids+=("$!")
    critical_names[$!]=hpm
    "$dimension_dir/06_can_asc.sh" "$output" & dimension_pids+=("$!")
    can_pid=$!
    critical_names[$can_pid]=can
    INFERENCE_SCREEN_SESSION="$screen_session" "$dimension_dir/07_inference_screen.sh" "$output/inference-session.txt" & dimension_pids+=("$!")
    "$dimension_dir/08_thermal.sh" "$output/thermal.txt" "$interval" & dimension_pids+=("$!")
    critical_names[$!]=thermal

    if [[ $rotate_secs -gt 0 ]]; then
        ( sleep "$rotate_secs"; kill -USR1 $$ 2>/dev/null ) & rotate_timer_pid=$!
    fi

    echo "Seven-dimensional capture started: $output"
    if [[ $rotate_secs -gt 0 ]]; then
        echo "Capturing seven dimensions; rotates automatically after ${rotate_secs}s, or press Ctrl-C to finish."
    else
        echo "Capturing seven dimensions; press Ctrl-C to finish."
    fi

    # Block until an external stop signal or our own rotation timer fires.
    # `wait` on a background job is interrupted promptly by a trapped
    # signal, unlike a foreground `sleep`.
    while [[ $stop_requested == no && $rotate_requested == no ]]; do
        for pid in "${!critical_names[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                failed_child=${critical_names[$pid]}
                echo "robopi-seven-capture: critical recorder exited: $failed_child (pid=$pid)" >&2
                failure=1
                break
            fi
        done
        (( failure == 0 )) || break
        sleep 1 & wait $! 2>/dev/null || true
    done

    set +e
    if [[ -n $rotate_timer_pid ]]; then
        kill "$rotate_timer_pid" 2>/dev/null
        wait "$rotate_timer_pid" 2>/dev/null
    fi
    for pid in "$capture_pid" "${dimension_pids[@]}"; do
        # systemd may signal the entire control group before this trap runs.
        if [[ $stop_requested == yes && $failure == 0 ]]; then
            signalled[$pid]=yes
        fi
        if kill -0 "$pid" 2>/dev/null; then
            signalled[$pid]=yes
            # Background jobs may inherit ignored SIGINT; TERM is handled
            # by tcpdump and the CAN wrapper and flushes their buffers.
            kill -TERM "$pid" 2>/dev/null
        fi
    done
    # Preserve raw exit statuses, but distinguish requested shutdown from
    # unexpected termination when deciding the service result.
    printf 'recorder\tpid\texit_status\tshutdown_requested\n' > "$output/recorder-status.tsv"
    for pid in "$capture_pid" "${dimension_pids[@]}"; do
        local status=0
        wait "$pid"; status=$?
        [[ $pid != "$capture_pid" ]] || capture_status=$status
        [[ $pid != "$can_pid" ]] || can_status=$status
        printf '%s\t%s\t%s\t%s\n' "${critical_names[$pid]:-screen-setup}" "$pid" "$status" "${signalled[$pid]:-no}" >> "$output/recorder-status.tsv"
        if [[ -n ${critical_names[$pid]:-} ]]; then
            if [[ ${signalled[$pid]:-no} != yes ]] ||
               [[ $status != 0 && $status != 130 && $status != 143 ]]; then
                failure=1
                [[ -n $failed_child ]] || failed_child=${critical_names[$pid]}
            fi
        fi
    done
    screen -S "$screen_session" -X log off 2>/dev/null || true
    local end_unix
    end_unix=$(now)
    sed -i '$d' "$output/manifest.json"
    printf ',  "ended_at_unix": %s,\n  "candump_status": %s,\n  "usb_capture_status": %s,\n  "capture_failed": %s,\n  "failed_recorder": "%s",\n  "asc_mode": "offline",\n  "pcap_mode": "direct-session",\n  "session_started_capture": true\n}\n' \
        "$end_unix" "$can_status" "$capture_status" "$([[ $failure == 0 ]] && echo false || echo true)" "$failed_child" >> "$output/manifest.json"
    echo "Seven-dimensional capture written to $output"
    set -e

    rotate_requested=no
    return "$failure"
}

output=$first_output
while :; do
    run_session "$output"
    # Only our own timer causes a new session to start; an external stop
    # signal, or every dimension dying on its own for an unrelated reason,
    # ends the whole script (letting systemd's own Restart= policy decide
    # what happens next, rather than looping tightly in here).
    [[ $rotate_secs -gt 0 && $stop_requested == no ]] || break
    output=$(next_output_path)
done
