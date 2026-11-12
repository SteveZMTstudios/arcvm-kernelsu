#!/bin/bash
#
# power_tune.sh — ChromeOS/Brunch AMD APU 功耗模式切换
#
# 实测（Ryzen 7 8840U，8 核满载 RAPL package power）：
#   boost=1                         ~28 W
#   boost=0                         ~12.4 W
#   boost=0 + max=3.2GHz            ~11.7 W
#   boost=0 之后换 EPP(power/balance_power) 几乎没有额外收益。
#
# 用法：
#   ./power_tune.sh balanced     # 推荐：boost=0，EPP=balance_performance
#   ./power_tune.sh eco          # 最省电：boost=0，EPP=balance_power，max=3.6GHz
#   ./power_tune.sh performance  # 恢复默认：boost=1，EPP=balance_performance
#   ./power_tune.sh status
#
# 锁定方法（见 host/）：
#   安装到 /usr/local/bin/power_tune.sh，
#   配合 /etc/init/power-tune.conf 和 /etc/udev/rules.d/99-power-tune.rules。

set -eu

BOOST=/sys/devices/system/cpu/cpufreq/boost
EPP_GLOB='/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference'
MAX_GLOB='/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq'
DEFAULT_MAX=5132000

apply() {
    local epp=$1 boost=$2 maxfreq=$3 f
    for f in $EPP_GLOB; do [ -e "$f" ] && echo "$epp" > "$f" 2>/dev/null || true; done
    [ -e "$BOOST" ] && echo "$boost" > "$BOOST" 2>/dev/null || true
    for f in $MAX_GLOB; do [ -e "$f" ] && echo "$maxfreq" > "$f" 2>/dev/null || true; done
}

status() {
    printf 'governor : %s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    printf 'EPP      : %s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a)"
    printf 'boost    : %s\n' "$(cat "$BOOST" 2>/dev/null || echo n/a)"
    printf 'max freq : %s kHz\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo n/a)"
}

case "${1:-status}" in
    balanced)
        apply balance_performance 0 "$DEFAULT_MAX"
        echo "已切换: balanced（boost=0，EPP=balance_performance）"
        status
        ;;
    eco)
        apply balance_power 0 3600000
        echo "已切换: eco（boost=0，EPP=balance_power，max=3.6GHz）"
        status
        ;;
    performance)
        apply balance_performance 1 "$DEFAULT_MAX"
        echo "已切换: performance（boost=1，EPP=balance_performance）"
        status
        ;;
    status)
        status
        ;;
    *)
        echo "用法: $0 {balanced|eco|performance|status}" >&2
        exit 1
        ;;
esac
