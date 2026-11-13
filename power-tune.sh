#!/bin/bash
#
# power-tune.sh — ChromeOS / Brunch 主机节电策略（单文件安装器）
#
#   curl -fsSL https://stevezmt.top/arcvm-kernelsu/power-tune.sh | sudo bash -s -- -y
#   curl -fsSL https://stevezmt.top/arcvm-kernelsu/power-tune.sh | sudo bash -s -- -y --profile eco
#   sudo bash power-tune.sh --status
#   sudo bash power-tune.sh --uninstall
#
# 三个档位（实测 Ryzen 7 8840U，8 核满载 RAPL package power）：
#   balanced     boost=0，EPP=balance_performance          ~12.4 W
#   eco          boost=0，EPP=balance_power，max=3.6GHz    ~11.7 W
#   performance  boost=1，EPP=balance_performance          ~28 W
#
# 持久化：写 /mnt/stateful_partition/brunch/bootscripts/10-power-tune.sh，
# 由 Brunch 每次开机执行；ChromeOS rootfs 更新不会清除 stateful。
# 同时写 /etc/udev/rules.d/99-power-tune.rules，让 AC/电池切换后重新应用。
#
# 与 KernelSU 完全独立：不读写 /opt/google/vms，不依赖 install.sh。
#
# 选项：
#   -p, --profile <档位>   balanced（默认）/ eco / performance
#       --max <kHz>        覆盖 eco 的频率上限
#       --no-persist       只立即生效，不写 bootscript/udev
#       --status           只打印当前状态
#       --uninstall        移除 bootscript 与 udev 规则，恢复 performance
#       --bootscripts <目录>  覆盖 bootscripts 目录
#   -y, --yes              跳过确认
#   -h, --help

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

BOOTSCRIPTS=${BOOTSCRIPTS:-/mnt/stateful_partition/brunch/bootscripts}
BOOTSCRIPT=
UDEV_RULE=${UDEV_RULE:-/etc/udev/rules.d/99-power-tune.rules}
BOOST=/sys/devices/system/cpu/cpufreq/boost
EPP_GLOB='/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference'
MAX_GLOB='/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq'
CPUINFO_MAX=/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq

PROFILE=balanced
MAX_OVERRIDE=
PERSIST=true
ASSUME_YES=false
ACTION=install

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -p|--profile)     PROFILE=${2:-}; shift 2 ;;
        --max)            MAX_OVERRIDE=${2:-}; shift 2 ;;
        --bootscripts)    BOOTSCRIPTS=${2:-}; shift 2 ;;
        --no-persist)     PERSIST=false; shift ;;
        --status)         ACTION=status; shift ;;
        --uninstall)      ACTION=uninstall; shift ;;
        -y|--yes)         ASSUME_YES=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "不支持的参数: $1（--help 查看用法）" ;;
    esac
done

BOOTSCRIPT="$BOOTSCRIPTS/10-power-tune.sh"

cpu_max() { cat "$CPUINFO_MAX" 2>/dev/null || echo 0; }
cur_epp() { cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a; }
cur_boost() { cat "$BOOST" 2>/dev/null || echo n/a; }
cur_max() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo n/a; }

status() {
    printf '%-9s %s\n' 'governor' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    printf '%-9s %s\n' 'EPP' "$(cur_epp)"
    printf '%-9s %s\n' 'boost' "$(cur_boost)"
    printf '%-9s %s kHz\n' 'max freq' "$(cur_max)"
    if [ -f "$BOOTSCRIPT" ]; then
        printf '%-9s %s\n' 'persist' "$BOOTSCRIPT"
    else
        printf '%-9s %s\n' 'persist' '未安装'
    fi
}

apply() {
    local epp=$1 boost=$2 maxfreq=$3 f
    for f in $EPP_GLOB; do [ -e "$f" ] && echo "$epp" > "$f" 2>/dev/null || true; done
    [ -e "$BOOST" ] && echo "$boost" > "$BOOST" 2>/dev/null || true
    if [ "$maxfreq" -gt 0 ] 2>/dev/null; then
        for f in $MAX_GLOB; do [ -e "$f" ] && echo "$maxfreq" > "$f" 2>/dev/null || true; done
    fi
}

# 档位 -> EPP / boost / max
profile_values() {
    local cpuinfo
    cpuinfo=$(cpu_max)
    [ "$cpuinfo" -gt 0 ] 2>/dev/null || cpuinfo=0
    case "$PROFILE" in
        balanced)
            EPP=balance_performance; BOOST_V=0; MAXF=$cpuinfo ;;
        eco)
            EPP=balance_power; BOOST_V=0; MAXF=${MAX_OVERRIDE:-3600000}
            if [ "$cpuinfo" -gt 0 ] && [ "$MAXF" -gt "$cpuinfo" ]; then MAXF=$cpuinfo; fi ;;
        performance)
            EPP=balance_performance; BOOST_V=1; MAXF=$cpuinfo ;;
        *) die "未知档位: $PROFILE（balanced / eco / performance）" ;;
    esac
}

gen_bootscript() {
    local tpl
    tpl=$(mktemp) || die "无法创建临时文件。"
    cat > "$tpl" <<'TPL'
#!/bin/bash
# 由 power-tune.sh 生成，开机锁定主机 CPU 策略。
# 手工修改会在下次 `power-tune.sh --profile ...` 时被覆盖。
set -u

for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [ -e "$f" ] && echo '@EPP@' > "$f" 2>/dev/null || true
done
[ -e /sys/devices/system/cpu/cpufreq/boost ] && \
    echo @BOOST@ > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
if [ @MAX@ -gt 0 ] 2>/dev/null; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [ -e "$f" ] && echo @MAX@ > "$f" 2>/dev/null || true
    done
fi

# rootfs 更新后 udev 规则会丢，开机重建；AC/电池切换后重新应用。
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-power-tune.rules <<'RULE'
ACTION=="change", SUBSYSTEM=="power_supply", RUN+="/bin/sh -c 'echo @BOOST@ > /sys/devices/system/cpu/cpufreq/boost; for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo @EPP@ > $f 2>/dev/null; done'"
RULE
udevadm control --reload-rules 2>/dev/null || true
TPL
    sed -i "s/@EPP@/$EPP/g; s/@BOOST@/$BOOST_V/g; s/@MAX@/$MAXF/g" "$tpl"
    install -d "$BOOTSCRIPTS"
    install -m 0755 "$tpl" "$BOOTSCRIPT"
    rm -f "$tpl"
}

gen_udev() {
    install -d "$(dirname "$UDEV_RULE")"
    cat > "$UDEV_RULE" <<EOF
ACTION=="change", SUBSYSTEM=="power_supply", RUN+="/bin/sh -c 'echo $BOOST_V > /sys/devices/system/cpu/cpufreq/boost; for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo $EPP > \$f 2>/dev/null; done'"
EOF
    udevadm control --reload-rules 2>/dev/null || true
}

[ "$(id -u)" -eq 0 ] || [ "$ACTION" = status ] || die "请用 root 运行：curl ... | sudo bash -s -- -y"

case "$ACTION" in
    status)
        status
        exit 0
        ;;
    uninstall)
        if [ ! -e "$BOOTSCRIPT" ] && [ ! -e "$UDEV_RULE" ]; then
            warn "没有找到已安装的规则，仍然恢复 performance。"
        fi
        if ! $ASSUME_YES; then
            printf '移除 %s 和 %s，并恢复 boost=1？输入 PATCH 确认: ' "$BOOTSCRIPT" "$UDEV_RULE"
            read -r answer < /dev/tty || answer=""
            [ "$answer" = "PATCH" ] || die "已取消。"
        fi
        rm -f "$BOOTSCRIPT" "$UDEV_RULE"
        udevadm control --reload-rules 2>/dev/null || true
        PROFILE=performance
        profile_values
        apply "$EPP" "$BOOST_V" "$MAXF"
        ok "已移除节电规则，恢复 performance（boost=1）。"
        status
        exit 0
        ;;
esac

profile_values
info "档位: $PROFILE（EPP=$EPP, boost=$BOOST_V, max=${MAXF}kHz）"
apply "$EPP" "$BOOST_V" "$MAXF"
ok "已立即生效。"

if $PERSIST; then
    gen_bootscript
    ok "开机策略: $BOOTSCRIPT"
    gen_udev
    ok "udev 规则: $UDEV_RULE"
else
    warn "--no-persist：重启后失效。"
fi

status
