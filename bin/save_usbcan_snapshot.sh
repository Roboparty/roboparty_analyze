#!/bin/sh
# Copyright (C) 2026 wentywenty
# SPDX-License-Identifier: GPL-3.0
# 紧急保存七维日志快照，并恢复 USB-CAN 抓包服务原来的状态。
set -eu

service=${USBCAN_CAPTURE_SERVICE:-usbcan-capture.service}
hpm_log_service=${HPM_LOG_CAPTURE_SERVICE:-hpm-log-capture.service}
bms_service=${BMS_SERVICE:-bms.service}
inference_session=${INFERENCE_SCREEN_SESSION:-inference_session}
source_dir=${USBCAN_CAPTURE_DIR:-/run/usbcan}
# The seven-dimensional recorder writes PCAP directly into its session.
if [ -L "$source_dir/current-session" ]; then
    source_dir=$(readlink -f "$source_dir/current-session")
fi
snapshot_root=${USBCAN_SNAPSHOT_DIR:-/home/robo/usbcan-snapshots}
lock_file=${USBCAN_SNAPSHOT_LOCK:-/run/lock/usbcan-debug-snapshot.lock}
timestamp=$(date +%Y%m%d-%H%M%S)
destination=$snapshot_root/$timestamp
archive=$destination.zip
was_active=no
destination_created=no
snapshot_complete=no
archive_complete=no

if [ "${USBCAN_ALLOW_NON_ROOT:-no}" != yes ] && [ "$(id -u)" -ne 0 ]; then
    echo "usbcan-debug-snapshot: run as root" >&2
    exit 1
fi

exec 9>"$lock_file"
flock -n 9 || {
    echo "usbcan-debug-snapshot: another snapshot is running" >&2
    exit 1
}

cleanup()
{
    if [ "$destination_created" = yes ] && [ "$snapshot_complete" != yes ]; then
        rm -rf -- "$destination"
    fi
    if [ "$archive_complete" != yes ]; then
        rm -f -- "$archive"
    fi
    if [ "$was_active" = yes ]; then
        systemctl start "$service" || true
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ -d "$source_dir" ] || {
    echo "usbcan-debug-snapshot: capture directory not found: $source_dir" >&2
    exit 1
}
set -- "$source_dir"/usbcan.pcap*
[ -e "$1" ] || {
    echo "usbcan-debug-snapshot: no usbcan.pcap files in $source_dir" >&2
    exit 1
}

[ -d "$snapshot_root" ] || install -d -m 0750 "$snapshot_root"
[ -x "$(command -v zip 2>/dev/null || true)" ] || {
    echo "usbcan-debug-snapshot: zip not found; install the zip package" >&2
    exit 1
}
[ ! -e "$destination" ] || {
    echo "usbcan-debug-snapshot: destination already exists: $destination" >&2
    exit 1
}

# Refuse the snapshot before pausing capture if the persistent filesystem
# cannot hold all current ring files plus a small allowance for diagnostics.
source_kb=$(du -sk "$source_dir"/usbcan.pcap* | awk '{ total += $1 } END { print total + 0 }')
available_kb=$(df -Pk "$snapshot_root" | awk 'NR == 2 { print $4 }')
required_kb=$((source_kb + 1024))
[ -n "$available_kb" ] && [ "$available_kb" -ge "$required_kb" ] || {
    echo "usbcan-debug-snapshot: insufficient space in $snapshot_root" >&2
    echo "usbcan-debug-snapshot: need ${required_kb} KiB, available ${available_kb:-unknown} KiB" >&2
    exit 1
}

if systemctl is-active --quiet "$service"; then
    was_active=yes
    systemctl stop "$service"
fi

install -d -m 0750 "$destination"
destination_created=yes
captured_at=$(date +%s.%N)
printf '{\n  "started_at_unix": %s,\n  "ended_at_unix": %s,\n  "capture_mode": "emergency-snapshot",\n  "interfaces": ["can0", "can1", "can2", "can3"],\n  "capture_dir": "%s",\n  "capture_service": "%s",\n  "hpm_service": "%s",\n  "bms_service": "%s",\n  "inference_screen_session": "%s"\n}\n' \
    "$captured_at" "$captured_at" "$source_dir" "$service" "$hpm_log_service" \
    "$bms_service" "$inference_session" > "$destination/manifest.json"
cp -a "$source_dir"/usbcan.pcap* "$destination"/

lsusb > "$destination/lsusb.txt" 2>&1 || true
lsusb -t > "$destination/lsusb-tree.txt" 2>&1 || true
printf '# captured_at_unix=%s\n' "$captured_at" > "$destination/bms-status.txt"
systemctl status "$bms_service" --no-pager >> "$destination/bms-status.txt" 2>&1 || true
printf '{"captured_at_unix":%s,"interfaces":' "$captured_at" > "$destination/can-details.jsonl"
ip -j -details -statistics link show type can >> "$destination/can-details.jsonl" 2>/dev/null || printf '[]' >> "$destination/can-details.jsonl"
printf '}\n' >> "$destination/can-details.jsonl"
ip -details -statistics link show type can \
    > "$destination/can-interfaces.txt" 2>&1 || true
: > "$destination/can.log"
: > "$destination/can.asc"
journalctl -u "$service" -b --no-pager \
    > "$destination/usbcan-capture-journal.txt" 2>&1 || true
journalctl -u "$hpm_log_service" -b --no-pager -o short-unix \
    > "$destination/hpm-uart-journal.txt" 2>&1 || true
journalctl -u "$hpm_log_service" -b --no-pager -o short-unix \
    > "$destination/hpm-uart-live.txt" 2>&1 || true
dmesg --time-format iso > "$destination/dmesg-live.txt" 2>&1 || true
if command -v screen >/dev/null 2>&1 && screen -list | grep -q "[.]$inference_session"; then
    screen -S "$inference_session" -X hardcopy -h "$destination/inference-session.txt" || true
else
    : > "$destination/inference-session.txt"
fi

snapshot_complete=yes
if [ "$was_active" = yes ]; then
    systemctl start "$service"
fi
was_active=no

# Compress only after the capture service has been restored, so compression does
# not extend the period in which the live PCAP recorder is paused.
(cd "$snapshot_root" && zip -qr -X "$archive" "$(basename "$destination")")
printf '%s  %s\n' "$(sha256sum "$archive" | awk '{print $1}')" "$(basename "$archive")" > "$archive.sha256"
archive_complete=yes
trap - EXIT HUP INT TERM

echo "$destination"
echo "$archive"
echo "$archive.sha256"
