#!/bin/bash
# Copyright (C) 2026 wentywenty
# SPDX-License-Identifier: GPL-3.0
# Capture raw CAN logs; convert an existing log only on explicit request.
set -euo pipefail

interfaces=(can0 can1 can2 can3)
first=${1:-}
input=
output=
capture_pid=
interrupted=no

die() { echo "robopi-can-capture: $*" >&2; exit 1; }
if [[ $first == --convert ]]; then
    session=${2:?Usage: robopi-can-capture --convert SESSION_DIR}
    [[ -f $session/can.log ]] || die "can.log not found: $session"
    command -v log2asc >/dev/null 2>&1 || die "log2asc not found; install can-utils"
    log2asc -I "$session/can.log" -O "$session/can.asc.tmp" "${interfaces[@]}"
    mv -f "$session/can.asc.tmp" "$session/can.asc"
    exit 0
fi
command -v candump >/dev/null 2>&1 || die "candump not found; install can-utils"

if [[ -d $first ]]; then
    input=$first/can.log
    output=$first/can.asc
elif [[ -n $first ]]; then
    output=$first
    input=$(mktemp --tmpdir robopi-can-capture.XXXXXX.log)
else
    output=${SESSION_ROOT:-/home/robo/robopi-logs}/can-$(date +%Y%m%d-%H%M%S).asc
    input=$(mktemp --tmpdir robopi-can-capture.XXXXXX.log)
fi
if [[ ! -d $first ]]; then
    command -v log2asc >/dev/null 2>&1 || die "log2asc not found; install can-utils"
fi

mkdir -p "$(dirname "$output")"
[[ ! -e $output || -d $first ]] || die "output already exists: $output"

if [[ -s $input && -d $first ]]; then
    command -v log2asc >/dev/null 2>&1 || die "log2asc not found; install can-utils"
    log2asc -I "$input" -O "$output" "${interfaces[@]}"
    exit 0
fi

finish() {
    set +e
    [[ -n ${capture_pid:-} ]] && kill -INT "$capture_pid" 2>/dev/null
    wait 2>/dev/null
    if [[ -s $input && ! -d $first ]]; then
        log2asc -I "$input" -O "$output" "${interfaces[@]}"
        echo "ASC written to $output"
    fi
    [[ -d $first ]] || rm -f "$input"
}
trap 'interrupted=yes; finish; exit 0' INT TERM
trap '[[ -d $first ]] || rm -f "$input"' EXIT

# Listen on "any" instead of naming interfaces: EtherCANFD's can0-can3 often
# appear well after boot, and "any" binds current and future interfaces, so
# late arrivals are captured with no wait/retry logic needed. Frames from
# the native buses (can_top/can_hipnuc/can_bottom) end up in can.log too,
# but log2asc below only converts the `interfaces` list, so they are
# filtered out and the ASC output matches listening on can0-can3 alone.
echo "Capturing all CAN interfaces (any) to $input; session ASC conversion is offline."
set +e
candump -L -t a any > "$input" & capture_pid=$!
wait "$capture_pid"
capture_status=$?
set -e
if [[ $capture_status -ne 0 && $interrupted != yes && $capture_status -ne 130 && $capture_status -ne 143 ]]; then
    echo "robopi-can-capture: candump failed with status $capture_status" >&2
    exit "$capture_status"
fi
finish
