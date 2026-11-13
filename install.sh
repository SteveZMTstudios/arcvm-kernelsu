#!/bin/bash
#
# install.sh — ARCVM KernelSU 单文件安装器（抓取 + 安装一体）
#
#   curl -fsSL https://stevezmt.top/arcvm-kernelsu/install.sh | sudo bash -s -- -y
#   curl -fsSL https://raw.githubusercontent.com/SteveZMTstudios/arcvm-kernelsu/main/install.sh | sudo bash -s -- -y
#
# 本地构建产物：
#   sudo bash install.sh --kernel-file vmlinux-5.10-x86_64
#
# 做的事：
#   1. 从当前 vmlinux 读出 ARCVM 内核版本，取 major.minor（KMI，如 5.10）；
#   2. 下载 release `latest-<KMI>-<arch>` 里的 `vmlinux-<KMI>-<arch>`；
#   3. 校验 md5、校验内核版本 KMI 与本机一致；
#   4. 只替换 /opt/google/vms/android/vmlinux，保留 vmlinux.original。
#
# 环境变量：
#   REPO        GitHub 仓库（默认 SteveZMTstudios/arcvm-kernelsu）
#   ASSET_BASE  release 资产前缀，可重复，用空格分隔；
#               默认 GitHub，可指向任意同布局镜像
#   TARGET      目标内核（默认 /opt/google/vms/android/vmlinux）
#
# 不会做的事：不碰 system.raw.img / vendor.raw.img / rootfs 验证。

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

REPO=${REPO:-SteveZMTstudios/arcvm-kernelsu}
TARGET=${TARGET:-/opt/google/vms/android/vmlinux}
BACKUP=${BACKUP:-}
KSU_DIR=${KSU_DIR:-/mnt/stateful_partition/brunch/ksu}
BOOTSCRIPTS=${BOOTSCRIPTS:-/mnt/stateful_partition/brunch/bootscripts}

KERNEL_FILE=
RELEASE_TAG=
ASSET_NAME=
ARCH_OVERRIDE=
ASSUME_YES=false
RESTORE=false
PURGE=false
PERSISTENT=false
DRY_RUN=false
ASSET_BASE_LIST=${ASSET_BASE:-}

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --kernel-file|-f)   KERNEL_FILE=${2:-}; shift 2 ;;
        --release-tag|--tag) RELEASE_TAG=${2:-}; shift 2 ;;
        --asset)            ASSET_NAME=${2:-}; shift 2 ;;
        --asset-base)       ASSET_BASE_LIST="${ASSET_BASE_LIST:+$ASSET_BASE_LIST }${2:-}"; shift 2 ;;
        --repo)             REPO=${2:-}; shift 2 ;;
        --target|-t)        TARGET=${2:-}; shift 2 ;;
        --backup|-b)        BACKUP=${2:-}; shift 2 ;;
        --arch|-a)          ARCH_OVERRIDE=${2:-}; shift 2 ;;
        --persistent)       PERSISTENT=true; shift ;;
        --restore|-r)       RESTORE=true; shift ;;
        --purge)            PURGE=true; shift ;;
        --dry-run|-n)       DRY_RUN=true; shift ;;
        -y|--yes)           ASSUME_YES=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "不支持的参数: $1（--help 查看用法）" ;;
    esac
done

[ -n "$BACKUP" ] || BACKUP="$(dirname "$TARGET")/vmlinux.original"

if [ "$(id -u)" -ne 0 ] && ! $DRY_RUN; then
    die "请使用 root 运行：curl ... | sudo bash -s -- -y"
fi

command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v md5sum >/dev/null 2>&1 || die "缺少 md5sum。"

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

# 从 bzImage / Image 里读内核 release
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

# 5.10.252-1009564-ged76cab4c76e -> 5.10
kmi_of() { printf '%s\n' "$1" | sed 's/-.*//' | cut -d. -f1,2; }

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
    if [ "$ARCH" = "arm64" ]; then is_arm64_image "$f"; else is_x86_bzimage "$f"; fi
}

ensure_writable() {
    local dir
    dir=$(dirname "$TARGET")
    [ -w "$dir" ] || die "目标目录不可写: $dir。脚本不会修改 rootfs 挂载/验证；请自行处理后重试。"
}

get_context() { ls -Zd "$TARGET" 2>/dev/null | awk '{print $1}' || true; }
apply_context() { local ctx; ctx=$(get_context); [ -n "$ctx" ] && chcon "$ctx" "$1" >/dev/null 2>&1 || true; }

confirm() {
    local prompt=$1
    $ASSUME_YES && return 0
    printf '%s（输入 PATCH 确认）: ' "$prompt"
    read -r answer < /dev/tty || answer=""
    [ "$answer" = "PATCH" ] || die "已取消。"
}

install_kernel() {
    local src=$1 ctx tmp="$TARGET.new"
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

    warn "即将替换: $TARGET"
    warn "只修改 vmlinux；不会碰 system.raw.img / vendor.raw.img / rootfs 验证。"
    confirm "确认安装"

    info "安装内核: $src -> $TARGET"
    cp -f "$src" "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    chown 0:0 "$tmp" 2>/dev/null || true
    [ -n "$ctx" ] && chcon "$ctx" "$tmp" >/dev/null 2>&1 || true
    sync

    # vmlinux 可能是旧脚本留下的符号链接；直接删掉再 mv。
    rm -f "$TARGET"
    mv -f "$tmp" "$TARGET"
    sync
    ok "安装完成。"
}

restore_kernel() {
    [ -f "$BACKUP" ] || die "找不到备份: $BACKUP"
    kernel_ok "$BACKUP" || die "备份不是有效的 $ARCH 内核: $BACKUP"
    ensure_writable
    confirm "确认从备份恢复 $TARGET"
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
}

# release 资产前缀：用户指定的优先，GitHub 兜底
asset_bases() {
    local b
    for b in $ASSET_BASE_LIST; do printf '%s\n' "${b%/}"; done
    printf '%s\n' "https://github.com/$REPO/releases/download"
}

# 依次尝试所有前缀下载一个文件
fetch_asset() {
    local url_name=$1 dest=$2 tag=$3 base url
    for base in $(asset_bases); do
        url="$base/$tag/$url_name"
        if curl -fsSL --retry 2 --connect-timeout 20 -o "$dest" "$url" 2>/dev/null; then
            printf '%s\n' "$url" > "$dest.url"
            return 0
        fi
    done
    return 1
}

expected_md5() {
    local file=$1 sums=$2
    awk -v f="$file" '$2 == f { print $1; exit }' "$sums" 2>/dev/null
}

# ---------------- 恢复 ----------------
if $RESTORE; then
    detect_arch
    if $PERSISTENT; then
        info "移除 KSU bootscript..."
        rm -f "$BOOTSCRIPTS/20-ksu-vmlinux.sh"
        if $PURGE; then
            info "移除电源 bootscript 与 stateful KSU 文件..."
            rm -f "$BOOTSCRIPTS/10-power-tune.sh"
            rm -f "$KSU_DIR/vmlinux" "$KSU_DIR/meta" "$KSU_DIR/boot.log"
        fi
    fi
    if $DRY_RUN; then
        info "dry-run: 从 $BACKUP 恢复 $TARGET"
        exit 0
    fi
    restore_kernel
    warn "重启 ChromeOS 后生效。"
    exit 0
fi

detect_arch
info "ChromeOS: ${CHROMEOS_VERSION:-未知}"
info "架构: $ARCH"
info "目标: $TARGET"

# ---------------- 取内核文件 ----------------
TMP=$(mktemp -d /tmp/arcvm-ksu.XXXXXX) || die "无法创建临时目录。"
trap 'rm -rf "$TMP"' EXIT INT TERM

KSU_KERNEL=
if [ -n "$KERNEL_FILE" ]; then
    [ -f "$KERNEL_FILE" ] || die "找不到内核文件: $KERNEL_FILE"
    KSU_KERNEL=$KERNEL_FILE
else
    SRC="$TARGET"
    [ -f "$SRC" ] || SRC="$BACKUP"
    [ -f "$SRC" ] || die "找不到 $TARGET，也没有备份 $BACKUP；请用 --kernel-file 指定。"
    DEV_VER=$(read_kernel_version "$SRC" || true)
    [ -n "$DEV_VER" ] || die "无法从 $SRC 读取内核版本。"
    KMI=$(kmi_of "$DEV_VER")

    TAG=${RELEASE_TAG:-latest-$KMI-$ARCH}
    ASSET=${ASSET_NAME:-vmlinux-$KMI-$ARCH}

    info "本机内核: $DEV_VER（KMI $KMI）"
    info "release: $TAG"
    info "资产: $ASSET"

    fetch_asset checksums.md5 "$TMP/checksums.md5" "$TAG" || die "下载失败: $TAG/checksums.md5"
    fetch_asset "$ASSET" "$TMP/$ASSET" "$TAG" || die "下载失败: $TAG/$ASSET（该 KMI/架构可能还没有构建产物）"

    want=$(expected_md5 "$ASSET" "$TMP/checksums.md5")
    if [ -n "$want" ]; then
        got=$(md5sum "$TMP/$ASSET" | awk '{print $1}')
        [ "$got" = "$want" ] || die "md5 校验失败: $ASSET（期望 $want，实际 $got）"
        ok "md5 校验通过。"
    else
        warn "checksums.md5 里没有 $ASSET，跳过校验。"
    fi

    KSU_VER=$(read_kernel_version "$TMP/$ASSET" || true)
    [ -n "$KSU_VER" ] || die "下载的文件不是有效的 $ARCH 内核镜像。"
    [ "$(kmi_of "$KSU_VER")" = "$KMI" ] || \
        die "KMI 不匹配：本机 $KMI，产物 $(kmi_of "$KSU_VER")。请换用匹配的 --release-tag。"
    info "产物内核: $KSU_VER"
    KSU_KERNEL="$TMP/$ASSET"

    if $PERSISTENT; then
        for f in 10-power-tune.sh 20-ksu-vmlinux.sh; do
            fetch_asset "$f" "$TMP/$f" "$TAG" || die "下载失败: $TAG/$f"
            want=$(expected_md5 "$f" "$TMP/checksums.md5")
            if [ -n "$want" ]; then
                got=$(md5sum "$TMP/$f" | awk '{print $1}')
                [ "$got" = "$want" ] || die "md5 校验失败: $f"
            fi
        done
    fi
fi

kernel_ok "$KSU_KERNEL" || die "不是有效的 $ARCH 内核镜像: $KSU_KERNEL"
KSU_VER=$(read_kernel_version "$KSU_KERNEL" || true)
[ -n "$KSU_VER" ] || die "无法从 $KSU_KERNEL 读取内核版本。"
info "内核文件: $KSU_KERNEL"

if $DRY_RUN; then
    info "dry-run: 将安装 $KSU_KERNEL -> $TARGET"
    info "dry-run: 备份 $TARGET -> $BACKUP（如果不存在）"
    exit 0
fi

# ---------------- 持久化（Brunch bootscripts） ----------------
if $PERSISTENT; then
    STOCK_FILE=$BACKUP
    [ -f "$STOCK_FILE" ] || STOCK_FILE=$TARGET
    [ -f "$STOCK_FILE" ] || die "找不到 stock vmlinux: $STOCK_FILE"
    STOCK_VER=$(read_kernel_version "$STOCK_FILE" || true)
    [ -n "$STOCK_VER" ] || die "无法从 $STOCK_FILE 读取内核版本。"
    STOCK_MD5=$(md5sum "$STOCK_FILE" | awk '{print $1}')
    KSU_MD5=$(md5sum "$KSU_KERNEL" | awk '{print $1}')

    [ "$STOCK_MD5" = "$KSU_MD5" ] && die "$STOCK_FILE 已经是 KSU vmlinux，找不到 stock 备份。"

    mkdir -p "$KSU_DIR" "$BOOTSCRIPTS"
    info "写入 stateful KSU 文件..."
    cp -f "$KSU_KERNEL" "$KSU_DIR/vmlinux.tmp"
    mv -f "$KSU_DIR/vmlinux.tmp" "$KSU_DIR/vmlinux"
    cat > "$KSU_DIR/meta" <<EOF
stock_version=$STOCK_VER
stock_md5=$STOCK_MD5
ksu_md5=$KSU_MD5
ksu_kmi=$(kmi_of "$KSU_VER")
EOF

    info "安装 Brunch bootscripts..."
    BSDIR=$TMP
    if [ ! -f "$BSDIR/20-ksu-vmlinux.sh" ]; then
        for d in "$(dirname "$0")" "$(dirname "$0")/host/bootscripts" "$PWD/host/bootscripts"; do
            if [ -f "$d/20-ksu-vmlinux.sh" ] && [ -f "$d/10-power-tune.sh" ]; then
                BSDIR=$d
                break
            fi
        done
    fi
    [ -f "$BSDIR/20-ksu-vmlinux.sh" ] || die "找不到 bootscripts（--persistent 需要 release 资产或仓库 host/bootscripts）。"
    install -m 0755 "$BSDIR/10-power-tune.sh" "$BOOTSCRIPTS/10-power-tune.sh"
    install -m 0755 "$BSDIR/20-ksu-vmlinux.sh" "$BOOTSCRIPTS/20-ksu-vmlinux.sh"
fi

install_kernel "$KSU_KERNEL"

if $PERSISTENT; then
    ok "持久化安装完成。"
    info "stateful: $KSU_DIR/vmlinux"
    info "bootscripts: $BOOTSCRIPTS/10-power-tune.sh, 20-ksu-vmlinux.sh"
    warn "ChromeOS 更新后由 bootscript 自动重放（KMI 变化时跳过）。"
fi
info "备份: $BACKUP"
info "恢复: sudo bash install.sh --restore$($PERSISTENT && printf ' --persistent --purge')"
warn "重启 ChromeOS 后生效。"
