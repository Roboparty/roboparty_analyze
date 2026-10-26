#!/bin/bash
# Copyright (C) 2026 wentywenty
# SPDX-License-Identifier: GPL-3.0
# 让 HPM5E00 进入 USB BootROM，擦除并写入固件，然后恢复正常启动模式。
#==============================================================================
# HPM Firmware Flasher — RoboParty
#
# Puts the HPM5E00 in USB BootROM mode, erases its flash, writes the firmware,
# then restores normal boot mode and resets the controller.
#
# Usage:
#   flash_hpm.sh <firmware.bin>
#
# Options (overridable via environment):
#   HPMTOOL       path to hpmtool.py (default: hpmtool on PATH)
#   HPM_CHIP      target chip      (default: hpm5e00)
#   HPM_ADDR      flash address    (default: 0x400)
#   HPM_RESET_LED reset brightness (default: /sys/class/leds/hpm_reset/brightness)
#   HPM_BOOT_LED  boot brightness  (default: /sys/class/leds/hpm_boot_enable/brightness)
#   HPM_RESET_SERVICE systemd unit paused during flashing
#                     (default: hpm-sreset.service)
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${HPMTOOL:-}" ]; then
    HPMTOOL="$HPMTOOL"
elif [ -x "$SCRIPT_DIR/hpmtool" ]; then
    HPMTOOL="$SCRIPT_DIR/hpmtool"
elif [ -x "$SCRIPT_DIR/hpmtool.py" ]; then
    HPMTOOL="$SCRIPT_DIR/hpmtool.py"
else
    HPMTOOL="hpmtool"
fi

HPM_CHIP="${HPM_CHIP:-hpm5e00}"
HPM_ADDR="${HPM_ADDR:-0x400}"
HPM_RESET_LED="${HPM_RESET_LED:-/sys/class/leds/hpm_reset/brightness}"
HPM_BOOT_LED="${HPM_BOOT_LED:-/sys/class/leds/hpm_boot_enable/brightness}"
HPM_RESET_HOLD_TIME="${HPM_RESET_HOLD_TIME:-0.1}"
HPM_BOOT_WAIT_TIME="${HPM_BOOT_WAIT_TIME:-2}"
HPM_RESET_SERVICE="${HPM_RESET_SERVICE:-hpm-sreset.service}"

FIRMWARE="${1:-}"

usage() {
    echo "Usage: $0 <firmware.bin>" >&2
    echo "  Flashes firmware to HPM chip via USB HID (chip=${HPM_CHIP}, addr=${HPM_ADDR})" >&2
    exit 1
}

if [ -z "$FIRMWARE" ]; then
    usage
fi

if [ ! -f "$FIRMWARE" ]; then
    echo "Error: firmware file not found: $FIRMWARE" >&2
    exit 1
fi

if ! command -v "$HPMTOOL" >/dev/null 2>&1; then
    echo "Error: hpmtool not found. Set HPMTOOL to the hpmtool.py path." >&2
    exit 1
fi

for led in "$HPM_RESET_LED" "$HPM_BOOT_LED"; do
    if [ ! -w "$led" ]; then
        echo "Error: HPM control is not writable: $led" >&2
        echo "Run this command as root and check the board device tree." >&2
        exit 1
    fi
done

write_led() {
    printf '%s\n' "$2" > "$1"
}

reset_service_stopped=no
reset_service_stop() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl is-active --quiet "$HPM_RESET_SERVICE" || return 0
    echo "Stopping $HPM_RESET_SERVICE for flashing..."
    if ! systemctl stop "$HPM_RESET_SERVICE"; then
        echo "Error: failed to stop $HPM_RESET_SERVICE" >&2
        return 1
    fi
    reset_service_stopped=yes
    return 0
}

reset_service_restart() {
    [ "$reset_service_stopped" = yes ] || return 0
    echo "Restarting $HPM_RESET_SERVICE..."
    if ! systemctl start "$HPM_RESET_SERVICE"; then
        echo "Warning: failed to restart $HPM_RESET_SERVICE" >&2
        return 1
    fi
    reset_service_stopped=no
    return 0
}

recovery_required=no
restore_normal_boot() {
    status=$?
    if [ "$recovery_required" = yes ]; then
        set +e
        write_led "$HPM_BOOT_LED" 0
        write_led "$HPM_RESET_LED" 0
        sleep "$HPM_RESET_HOLD_TIME"
        write_led "$HPM_RESET_LED" 1
        set -e
    fi
    if ! reset_service_restart; then
        [ "$status" -eq 0 ] && status=1
    fi
    return "$status"
}
trap restore_normal_boot EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! reset_service_stop; then
    exit 1
fi

echo "Holding HPM in reset..."
recovery_required=yes
write_led "$HPM_RESET_LED" 0
write_led "$HPM_BOOT_LED" 1
sleep "$HPM_RESET_HOLD_TIME"
write_led "$HPM_RESET_LED" 1
sleep "$HPM_BOOT_WAIT_TIME"

echo "Erasing flash on $HPM_CHIP (USB HID)..."
"$HPMTOOL" -u -c "$HPM_CHIP" erase_flash

echo "Flashing $FIRMWARE to $HPM_CHIP @ $HPM_ADDR (USB HID)..."
"$HPMTOOL" -u -c "$HPM_CHIP" write_flash "$HPM_ADDR" "$FIRMWARE"

echo "Returning HPM to normal boot mode..."
write_led "$HPM_BOOT_LED" 0
write_led "$HPM_RESET_LED" 0
sleep "$HPM_RESET_HOLD_TIME"
write_led "$HPM_RESET_LED" 1
recovery_required=no
if ! reset_service_restart; then
    trap - EXIT HUP INT TERM
    echo "Error: firmware flashed, but $HPM_RESET_SERVICE was not restarted" >&2
    exit 1
fi
trap - EXIT HUP INT TERM
echo "Done."
