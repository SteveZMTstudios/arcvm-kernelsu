#!/bin/bash
#
# install-arcvm-kernelsu-brunch.sh — 持久化安装（Brunch bootscripts 层）
#
# 除了替换 /opt/google/vms/android/vmlinux，还把 KSU vmlinux 和 bootscripts
# 放到 /mnt/stateful_partition/brunch/：
#
#   /mnt/stateful_partition/brunch/ksu/vmlinux
#   /mnt/stateful_partition/brunch/ksu/meta
#   /mnt/stateful_partition/brunch/bootscripts/10-power-tune.sh
#   /mnt/stateful_partition/brunch/bootscripts/20-ksu-vmlinux.sh
#
# Brunch 每次启动会执行 bootscripts；ChromeOS rootfs 周更不会动 stateful，
# 所以 KSU vmlinux 和电源策略都能保留。若 ARCVM 内核版本变了，bootscript
# 会跳过并在 boot.log 里提示，需要重新构建匹配的 vmlinux。
#
# 用法：
#   sudo bash install-arcvm-kernelsu-brunch.sh \
#       --kernel-file vmlinux-5.10.252-x86_64 \
#       --bootscript-dir .
#   sudo bash install-arcvm-kernelsu-brunch.sh --restore
#   sudo bash install-arcvm-kernelsu-brunch.sh --restore --purge
#
# 仍然只替换 vmlinux；不碰 system.raw.img / vendor.raw.img / rootfs 验证。

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

KSU_DIR=${KSU_DIR:-/mnt/stateful_partition/brunch/ksu}
BOOTSCRIPTS=${BOOTSCRIPTS:-/mnt/stateful_partition/brunch/bootscripts}
TARGET=${TARGET:-/opt/google/vms/android/vmlinux}
STOCK=${STOCK:-/opt/google/vms/android/vmlinux.original}
KERNEL_FILE=
BOOTSCRIPT_DIR=
ASSUME_YES=false
RESTORE=false
PURGE=false

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --kernel-file|-f)   KERNEL_FILE=${2:-}; shift 2 ;;
        --bootscript-dir)   BOOTSCRIPT_DIR=${2:-}; shift 2 ;;
        --stock-file)       STOCK=${2:-}; shift 2 ;;
        --target)           TARGET=${2:-}; shift 2 ;;
        --restore|-r)       RESTORE=true; shift ;;
        --purge)            PURGE=true; shift ;;
        -y|--yes)           ASSUME_YES=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "不支持的参数: $1" ;;
    esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALLER="$SCRIPT_DIR/install-arcvm-kernelsu.sh"
[ -f "$INSTALLER" ] || die "找不到 install-arcvm-kernelsu.sh（应与本脚本同目录）。"

read_kernel_version() {
    local f=$1 magic kv_off abs raw
    [ -s "$f" ] || return 1
    magic=$(dd if="$f" bs=1 skip=514 count=4 2>/dev/null || true)
    if [ "$magic" = "HdrS" ]; then
        kv_off=$(od -An -tu2 -j 526 -N 2 "$f" 2>/dev/null | tr -dc '0-9')
        [ -n "$kv_off" ] || return 1
        abs=$((512 + kv_off))
        raw=$(dd if="$f" bs=1 skip="$abs" count=192 2>/dev/null | tr -d '\000' | head -n1 || true)
        raw=${raw%% *}
        [ -n "$raw" ] && { printf '%s\n' "$raw"; return 0; }
        return 1
    fi
    raw=$(LC_ALL=C grep -a -m1 -o 'Linux version [0-9][^ ]*' "$f" 2>/dev/null | head -n1 || true)
    raw=${raw#Linux version }
    [ -n "$raw" ] && { printf '%s\n' "$raw"; return 0; }
    return 1
}

if $RESTORE; then
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
    info "移除 KSU bootscript..."
    rm -f "$BOOTSCRIPTS/20-ksu-vmlinux.sh"
    if $PURGE; then
        info "移除电源 bootscript 与 stateful KSU 文件..."
        rm -f "$BOOTSCRIPTS/10-power-tune.sh"
        rm -f "$KSU_DIR/vmlinux" "$KSU_DIR/meta" "$KSU_DIR/boot.log"
    fi
    args=(--restore)
    $ASSUME_YES && args+=(-y)
    bash "$INSTALLER" "${args[@]}"
    ok "已恢复 stock vmlinux（bootscript 已移除）。"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
[ -n "$KERNEL_FILE" ] || die "请用 --kernel-file 指定 KSU vmlinux。"
[ -f "$KERNEL_FILE" ] || die "找不到 KSU vmlinux: $KERNEL_FILE"

KSU_VER=$(read_kernel_version "$KERNEL_FILE" || true)
[ -n "$KSU_VER" ] || die "无法从 $KERNEL_FILE 读取内核版本。"
KSU_MD5=$(md5sum "$KERNEL_FILE" | awk '{print $1}')

# 选择 stock vmlinux：优先 vmlinux.original；否则用当前 target（如果它还是 stock）。
if [ -f "$STOCK" ]; then
    STOCK_FILE=$STOCK
else
    STOCK_FILE=$TARGET
fi
[ -f "$STOCK_FILE" ] || die "找不到 stock vmlinux: $STOCK_FILE"
STOCK_VER=$(read_kernel_version "$STOCK_FILE" || true)
[ -n "$STOCK_VER" ] || die "无法从 $STOCK_FILE 读取内核版本。"
STOCK_MD5=$(md5sum "$STOCK_FILE" | awk '{print $1}')

if [ "$STOCK_MD5" = "$KSU_MD5" ]; then
    die "$STOCK_FILE 已经是 KSU vmlinux，找不到 stock 备份。请先恢复或指定 --stock-file。"
fi
if [ "$KSU_VER" != "$STOCK_VER" ]; then
    die "版本不匹配：KSU=$KSU_VER stock=$STOCK_VER。请为当前 ARCVM 内核重新构建。"
fi

# bootscripts 来源：--bootscript-dir，或脚本同目录，或仓库 host/bootscripts
if [ -z "$BOOTSCRIPT_DIR" ]; then
    for d in "$SCRIPT_DIR" "$SCRIPT_DIR/../host/bootscripts"; do
        if [ -f "$d/10-power-tune.sh" ] && [ -f "$d/20-ksu-vmlinux.sh" ]; then
            BOOTSCRIPT_DIR=$d
            break
        fi
    done
fi
[ -n "$BOOTSCRIPT_DIR" ] || die "找不到 bootscripts（请用 --bootscript-dir 指定）。"
[ -f "$BOOTSCRIPT_DIR/10-power-tune.sh" ] || die "缺少 10-power-tune.sh。"
[ -f "$BOOTSCRIPT_DIR/20-ksu-vmlinux.sh" ] || die "缺少 20-ksu-vmlinux.sh。"

mkdir -p "$KSU_DIR" "$BOOTSCRIPTS"

info "写入 stateful KSU 文件..."
cp -f "$KERNEL_FILE" "$KSU_DIR/vmlinux.tmp"
mv -f "$KSU_DIR/vmlinux.tmp" "$KSU_DIR/vmlinux"
cat > "$KSU_DIR/meta" <<EOF
stock_version=$STOCK_VER
stock_md5=$STOCK_MD5
ksu_md5=$KSU_MD5
EOF

info "安装 Brunch bootscripts..."
install -m 0755 "$BOOTSCRIPT_DIR/10-power-tune.sh" "$BOOTSCRIPTS/10-power-tune.sh"
install -m 0755 "$BOOTSCRIPT_DIR/20-ksu-vmlinux.sh" "$BOOTSCRIPTS/20-ksu-vmlinux.sh"

info "立即应用 KSU vmlinux（只替换 $TARGET）..."
args=(--kernel-file "$KERNEL_FILE")
$ASSUME_YES && args+=(-y)
bash "$INSTALLER" "${args[@]}"

ok "持久化安装完成。"
info "stateful: $KSU_DIR/vmlinux"
info "bootscripts: $BOOTSCRIPTS/10-power-tune.sh, 20-ksu-vmlinux.sh"
warn "重启后生效；ChromeOS rootfs 周更后 bootscript 会自动重放。"
warn "如果 ARCVM 内核版本变化，bootscript 会跳过，需要重新构建 vmlinux。"
