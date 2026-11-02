#!/bin/bash
# HPM BOOT 和 RESET 控制脚本
# 适用于 RK3588 Linux
# 需要 root 权限运行

set -eu

BOOT="/sys/class/leds/hpm_boot_enable/brightness"
RESET="/sys/class/leds/hpm_reset/brightness"

# 检查控制节点是否存在
if [ ! -e "$BOOT" ]; then
    echo "错误：找不到 BOOT 控制节点：$BOOT"
    exit 1
fi

if [ ! -e "$RESET" ]; then
    echo "错误：找不到 RESET 控制节点：$RESET"
    exit 1
fi

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本"
    echo "示例：sudo $0"
    exit 1
fi

if [ "${1:-}" = "--reset" ]; then
    echo "HPM 正常启动复位：BOOT 拉低，产生复位脉冲"
    echo 0 > "$BOOT"
    sleep 0.1

    echo 0 > "$RESET"
    sleep 0.1

    echo 1 > "$RESET"
    echo "复位完成：BOOT=0 RESET=1"
    exit 0
fi

if [ "${1:-}" = "--monitor" ]; then
    echo "开机复位：BOOT 拉低，从内部 Flash 正常启动"
    echo 0 > "$BOOT"
    sleep 0.1

    echo 0 > "$RESET"
    sleep 0.1

    echo 1 > "$RESET"
    echo "开机复位完成：BOOT=0 RESET=1"
    echo

    echo "开始监视 HPM USB 设备 1209:2323"
    while :; do
        if lsusb -d 1209:2323 >/dev/null 2>&1; then
            sleep 5
            continue
        fi

        echo "未找到 HPM USB 设备，执行复位"
        "$0" --reset || true
        sleep 10
    done
fi

echo "========================================"
echo "第一阶段：BOOT 拉高，复位 HPM"
echo "========================================"

# 1. 拉高 BOOT1
echo 1 > "$BOOT"
echo "BOOT = 1"
sleep 0.1

# 2. 拉低复位引脚
echo 0 > "$RESET"
echo "RESET = 0"
sleep 0.1

# 3. 拉高复位引脚，释放复位
echo 1 > "$RESET"
echo "RESET = 1"

echo
echo "第一阶段 GPIO 状态："
cat /sys/kernel/debug/gpio | grep -i hpm || true

echo
echo "========================================"
echo "第二阶段：BOOT 拉低，再次复位 HPM"
echo "========================================"

# 1. 拉低 BOOT1
echo 0 > "$BOOT"
echo "BOOT = 0"
sleep 0.1

# 2. 拉低复位引脚
echo 0 > "$RESET"
echo "RESET = 0"
sleep 0.1

# 3. 拉高复位引脚，释放复位
echo 1 > "$RESET"
echo "RESET = 1"

echo
echo "第二阶段 GPIO 状态："
cat /sys/kernel/debug/gpio | grep -i hpm || true

echo
echo "========================================"
echo "USB 设备信息"
echo "========================================"

lsusb -v -d 1209:2323 2>&1 | grep -E 'bcdUSB|bcdDevice' || \
    echo "未找到 USB 设备 1209:2323，或无法读取详细信息。"



echo
echo "========================================"
echo "脚本执行完成"
echo "========================================"
