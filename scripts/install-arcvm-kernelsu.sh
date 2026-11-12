#!/bin/bash
#
# ChromeOS ARCVM KernelSU 安装脚本（只替换 vmlinux）
#
# 使用 build-arcvm-kernelsu-vmlinux.sh 生成的 vmlinux：
#   - 内核里内嵌 initramfs：ksuinit + kernelsu.ko + switchroot
#   - 开机时加载 LKM，再切到 Android 的 /init
#
# 安全约束：
#   - 只写 /opt/google/vms/android/vmlinux；
#   - 不修改 system.raw.img / vendor.raw.img；
#   - 不修改 rootfs 挂载，不执行 make_dev_ssd.sh，不碰 rootfs 验证；
#   - 目标目录不可写时直接退出；
#   - 修改前保留 vmlinux.original，可用 --restore 完整恢复。
#
# 代价：
#   KernelSU 升级需要重新构建 vmlinux 并再次替换（ko 内嵌在 initramfs）。
#
# 用法：
#   sudo bash install-arcvm-kernelsu.sh --kernel-file vmlinux-5.10.252-x86_64
#   sudo bash install-arcvm-kernelsu.sh --restore
#   sudo bash install-arcvm-kernelsu.sh -n --kernel-file ...

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

KERNEL_DIR=${KERNEL_DIR:-/opt/google/vms/android}
TARGET=${TARGET:-$KERNEL_DIR/vmlinux}
BACKUP=${BACKUP:-}
KERNEL_FILE=
ARCH_OVERRIDE=
ASSUME_YES=false
RESTORE=false
DRY_RUN=false

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
    cat <<'USAGE'
用法: install-arcvm-kernelsu.sh [选项]

  -f, --kernel-file <文件>  build 脚本生成的 vmlinux
  -t, --target <路径>       目标 vmlinux（默认 /opt/google/vms/android/vmlinux）
  -b, --backup <路径>       备份路径（默认 /opt/google/vms/android/vmlinux.original）
  -r, --restore             从 vmlinux.original 恢复
  -n, --dry-run             只检查，不写文件
  -y, --yes                 跳过 PATCH 确认
  -a, --arch <架构>         覆盖架构检测: x86_64 / arm64
  -h, --help                显示帮助

说明:
  - 只替换 vmlinux；不碰 system.raw.img / vendor.raw.img。
  - 不会修改 rootfs 挂载或 rootfs 验证；目标目录不可写时直接退出。
  - 首次修改前会把现有 vmlinux 备份到 vmlinux.original（如果还没有）。
  - 已存在 vmlinux.original 时不会覆盖它。
USAGE
}

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

while getopts ":-:f:t:b:rnya:h" opt; do
    case "$opt" in
        f) KERNEL_FILE=$OPTARG ;;
        t) TARGET=$OPTARG ;;
        b) BACKUP=$OPTARG ;;
        r) RESTORE=true ;;
        n) DRY_RUN=true ;;
        y) ASSUME_YES=true ;;
        a) ARCH_OVERRIDE=$OPTARG ;;
        h) usage; exit 0 ;;
        -)
            case "$OPTARG" in
                kernel-file|target|backup|arch)
                    val="${!OPTIND:-}"
                    [ -n "$val" ] || die "选项 --$OPTARG 需要一个参数"
                    case "$OPTARG" in
                        kernel-file) KERNEL_FILE=$val ;;
                        target) TARGET=$val ;;
                        backup) BACKUP=$val ;;
                        arch) ARCH_OVERRIDE=$val ;;
                    esac
                    OPTIND=$((OPTIND + 1))
                    ;;
                restore) RESTORE=true ;;
                dry-run) DRY_RUN=true ;;
                yes) ASSUME_YES=true ;;
                help) usage; exit 0 ;;
                *) die "不支持的参数: --$OPTARG" ;;
            esac
            ;;
        \?) die "不支持的参数: -$OPTARG" ;;
        :) die "选项 -$OPTARG 需要一个参数" ;;
    esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || die "不支持的参数: $*"

[ -n "$BACKUP" ] || BACKUP="$(dirname "$TARGET")/vmlinux.original"

if [ "$(id -u)" -ne 0 ] && ! $DRY_RUN; then
    die "请使用 root 运行（crosh 里先 sudo -i）。"
fi

if [ -r /etc/lsb-release ]; then
    CHROMEOS_VERSION=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /etc/lsb-release | head -n1)
else
    CHROMEOS_VERSION=""
fi

detect_arch() {
    if [ -n "$ARCH_OVERRIDE" ]; then
        case "$ARCH_OVERRIDE" in
            x86_64|amd64) ARCH=x86_64 ;;
            arm64|aarch64) ARCH=arm64 ;;
            *) die "未知架构: $ARCH_OVERRIDE" ;;
        esac
        return
    fi
    case "$(uname -m)" in
        x86_64|amd64) ARCH=x86_64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}
detect_arch

is_x86_bzimage() {
    local f=$1
    [ "$(dd if="$f" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "55aa" ] && \
    [ "$(dd if="$f" bs=1 skip=514 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "48647253" ]
}

is_arm64_image() {
    local f=$1
    [ "$(dd if="$f" bs=1 skip=56 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "41524d64" ]
}

kernel_ok() {
    local f=$1
    [ -s "$f" ] || return 1
    if [ "$ARCH" = "arm64" ]; then
        is_arm64_image "$f"
    else
        is_x86_bzimage "$f"
    fi
}

find_kernel_file() {
    local c
    local candidates=()
    [ -n "$KERNEL_FILE" ] && candidates+=("$KERNEL_FILE")
    candidates+=("$SCRIPT_DIR/vmlinux-$(uname -r 2>/dev/null || true)" "$SCRIPT_DIR/arcvm-research/vmlinux-$(uname -r 2>/dev/null || true)")
    for c in "$SCRIPT_DIR"/vmlinux-*-"$ARCH" "$SCRIPT_DIR"/arcvm-research/vmlinux-*-"$ARCH"; do
        candidates+=("$c")
    done
    for c in "${candidates[@]}"; do
        [ -n "$c" ] || continue
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

ensure_writable() {
    local dir
    dir=$(dirname "$TARGET")
    [ -w "$dir" ] || die "目标目录不可写: $dir。脚本不会修改 rootfs 挂载/验证；请自行处理后重试。"
}

get_context() {
    ls -Zd "$TARGET" 2>/dev/null | awk '{print $1}' || true
}

apply_context() {
    local ctx
    ctx=$(get_context)
    [ -n "$ctx" ] && chcon "$ctx" "$1" >/dev/null 2>&1 || true
}

install_kernel() {
    local src=$1
    local ctx tmp="$TARGET.new"
    kernel_ok "$src" || die "输入文件不是有效的 $ARCH 内核镜像: $src"

    ensure_writable
    ctx=$(get_context)

    if [ ! -e "$BACKUP" ]; then
        info "备份当前 vmlinux -> $BACKUP"
        cp --sparse=always -a "$TARGET" "$BACKUP" 2>/dev/null || cp -a "$TARGET" "$BACKUP"
        ok "备份完成。"
    else
        info "已存在备份，保持不动: $BACKUP"
    fi

    if ! $ASSUME_YES; then
        echo
        warn "即将替换: $TARGET"
        warn "备份: $BACKUP"
        warn "只修改 vmlinux；不会碰 system.raw.img / vendor.raw.img / rootfs 验证。"
        printf '输入 PATCH 确认: '
        read -r answer < /dev/tty || answer=""
        [ "$answer" = "PATCH" ] || die "已取消。"
    fi

    info "安装内核: $src -> $TARGET"
    cp -f "$src" "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    chown 0:0 "$tmp" 2>/dev/null || true
    [ -n "$ctx" ] && chcon "$ctx" "$tmp" >/dev/null 2>&1 || true
    sync

    # vmlinux 可能是旧 KSU 脚本留下的符号链接；直接删掉再 mv。
    rm -f "$TARGET"
    mv -f "$tmp" "$TARGET"
    sync

    ok "安装完成。"
    info "备份: $BACKUP"
    info "恢复: sudo bash $0 --restore"
    warn "重启 ChromeOS 后生效。"
}

restore_kernel() {
    [ -f "$BACKUP" ] || die "找不到备份: $BACKUP"
    kernel_ok "$BACKUP" || die "备份不是有效的 $ARCH 内核: $BACKUP"
    ensure_writable
    if ! $ASSUME_YES; then
        printf '确认从备份恢复 %s？输入 PATCH: ' "$TARGET"
        read -r answer < /dev/tty || answer=""
        [ "$answer" = "PATCH" ] || die "已取消。"
    fi
    info "恢复: $BACKUP -> $TARGET"
    cp -f "$BACKUP" "$TARGET.new"
    chmod 0644 "$TARGET.new" 2>/dev/null || true
    chown 0:0 "$TARGET.new" 2>/dev/null || true
    apply_context "$TARGET.new"
    sync
    rm -f "$TARGET"
    mv -f "$TARGET.new" "$TARGET"
    sync
    ok "已恢复原 vmlinux。"
    warn "重启 ChromeOS 后生效。"
}

info "ChromeOS: ${CHROMEOS_VERSION:-未知}"
info "架构: $ARCH"
info "目标: $TARGET"
info "备份: $BACKUP"

if $RESTORE; then
    if $DRY_RUN; then
        info "dry-run: 从 $BACKUP 恢复 $TARGET"
        exit 0
    fi
    restore_kernel
    exit 0
fi

SRC=$(find_kernel_file || true)
[ -n "$SRC" ] || die "找不到 vmlinux-*-$ARCH。请用 --kernel-file 指定 build 脚本的输出。"
info "内核文件: $SRC"

if $DRY_RUN; then
    kernel_ok "$SRC" || die "内核文件无效: $SRC"
    info "dry-run: 将安装 $SRC -> $TARGET"
    info "dry-run: 备份 $TARGET -> $BACKUP（如果不存在）"
    info "dry-run: 只修改 vmlinux，不碰 system.raw.img / rootfs 验证。"
    exit 0
fi

install_kernel "$SRC"
