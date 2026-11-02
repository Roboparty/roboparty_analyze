#!/bin/sh
# Copyright (C) 2026 wentywenty
# SPDX-License-Identifier: GPL-3.0
# 检查 USB-CAN 快照中的 PCAP 文件和辅助日志是否完整、可读取。
set -eu

snapshot=${1:-}
[ -n "$snapshot" ] || {
    echo "Usage: $0 SNAPSHOT_DIR" >&2
    exit 2
}
[ -d "$snapshot" ] || {
    echo "Snapshot directory not found: $snapshot" >&2
    exit 1
}
command -v capinfos >/dev/null 2>&1 || {
    echo "Missing capinfos; install wireshark-common" >&2
    exit 1
}

set -- "$snapshot"/usbcan.pcap*
[ -f "$1" ] || {
    echo "No usbcan.pcap* files in $snapshot" >&2
    exit 1
}

echo "Snapshot: $snapshot"
echo "Filesystem:"
df -h "$snapshot"
echo
echo "Capture files:"

total_bytes=0
failed=0
for capture do
    bytes=$(wc -c <"$capture")
    total_bytes=$((total_bytes + bytes))
    if info=$(capinfos -c -a -e -u -o "$capture" 2>&1); then
        printf '\n%s (%s bytes)\n' "$capture" "$bytes"
        printf '%s\n' "$info"
    else
        printf '\nBROKEN: %s\n%s\n' "$capture" "$info" >&2
        failed=1
    fi
done

echo
printf 'Total capture bytes: %s\n' "$total_bytes"
echo "Auxiliary files:"
for name in lsusb.txt lsusb-tree.txt can-interfaces.txt \
    usbcan-capture-journal.txt dmesg-live.txt
do
    if [ -s "$snapshot/$name" ]; then
        printf '  OK      %s\n' "$name"
    elif [ -e "$snapshot/$name" ]; then
        printf '  EMPTY   %s\n' "$name"
    else
        printf '  MISSING %s\n' "$name"
    fi
done

echo
echo "Next commands:"
printf '  mergecap -F pcap -w %s/usbcan-merged.pcap %s/usbcan.pcap\*\n' \
    "$snapshot" "$snapshot"
printf '  analyze-ethercan-pcap %s --top 50\n' "$snapshot"

[ "$failed" -eq 0 ] || exit 1
