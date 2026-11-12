#!/bin/bash
#
# fetch-arcvm-kernelsu.sh — 设备端抓取并安装匹配当前 ARCVM 内核的 KernelSU vmlinux
#
# 依赖：curl、md5sum（ChromeOS 自带，不需要 python3/jq）
#
# 用法：
#   sudo bash fetch-arcvm-kernelsu.sh --repo OWNER/REPO
#   sudo bash fetch-arcvm-kernelsu.sh --repo OWNER/REPO -y
#   sudo bash fetch-arcvm-kernelsu.sh --repo OWNER/REPO --release-tag latest-5.10.252-...-x86_64
#   sudo bash fetch-arcvm-kernelsu.sh --repo OWNER/REPO --persistent
#   sudo bash fetch-arcvm-kernelsu.sh --restore
#   sudo bash fetch-arcvm-kernelsu.sh --restore --purge
#
# 说明：
#   - 从当前 /opt/.../vmlinux 读取内核版本（回退到 vmlinux.original）；
#   - 按 uname -m 选择架构；
#   - 默认下载滚动 release：latest-<内核版本>-<架构>；
#   - 默认使用 install-arcvm-kernelsu.sh：只替换 vmlinux，ChromeOS 更新后
#     需要手动重跑本脚本；
#   - --persistent 才使用 install-arcvm-kernelsu-brunch.sh，把 vmlinux 和
#     bootscripts 放进 stateful，开机自动重放（可选）；
#   - 不碰 system.raw.img / rootfs 验证。

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

REPO=${REPO:-OWNER/REPO}
VMLINUX=${VMLINUX:-/opt/google/vms/android/vmlinux}
BACKUP=${BACKUP:-/opt/google/vms/android/vmlinux.original}
RELEASE_TAG=
RESTORE=false
PURGE=false
PERSISTENT=false
ASSUME_YES=false

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)         REPO=${2:-}; shift 2 ;;
        --release-tag|--tag) RELEASE_TAG=${2:-}; shift 2 ;;
        --vmlinux)      VMLINUX=${2:-}; shift 2 ;;
        --backup)       BACKUP=${2:-}; shift 2 ;;
        --restore)      RESTORE=true; shift ;;
        --purge)        PURGE=true; shift ;;
        --persistent)   PERSISTENT=true; shift ;;
        -y|--yes)       ASSUME_YES=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "不支持的参数: $1" ;;
    esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALLER="$SCRIPT_DIR/install-arcvm-kernelsu.sh"
MODE=plain
if $PERSISTENT; then
    INSTALLER="$SCRIPT_DIR/install-arcvm-kernelsu-brunch.sh"
    MODE=brunch
fi
[ -f "$INSTALLER" ] || die "找不到安装脚本（install-arcvm-kernelsu*.sh）。"

if $RESTORE; then
    args=(--restore)
    if [ "$MODE" = "brunch" ] && $PURGE; then
        args+=(--purge)
    fi
    $ASSUME_YES && args+=(-y)
    exec bash "$INSTALLER" "${args[@]}"
fi

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行（crosh 里先 sudo -i）。"
[ -n "$REPO" ] && [ "$REPO" != "OWNER/REPO" ] || die "请用 --repo OWNER/REPO 指定仓库。"

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

# 优先当前 vmlinux（ChromeOS 更新后它就是新 stock）；再回退 .original
SRC="$VMLINUX"
[ -f "$SRC" ] || SRC="$BACKUP"
VERSION=$(read_kernel_version "$SRC" || true)
[ -n "$VERSION" ] || die "无法从 $SRC 读取内核版本。"
KBASE=${VERSION%%-*}

case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "不支持的架构: $(uname -m)" ;;
esac

TAG=${RELEASE_TAG:-latest-$VERSION-$ARCH}
ASSET="vmlinux-$KBASE-$ARCH"
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

info "仓库: $REPO"
info "内核: $VERSION"
info "架构: $ARCH"
info "release: $TAG"
info "安装模式: $MODE"

# 新 release 带 bootscripts + checksums.md5；旧 release 回退单文件 md5。
FILES=("$ASSET" "checksums.md5" "10-power-tune.sh" "20-ksu-vmlinux.sh")
if ! curl -fsSL --retry 2 --connect-timeout 20 -o "$TMP/checksums.md5" "$BASE/checksums.md5"; then
    rm -f "$TMP/checksums.md5"
    warn "release 没有 checksums.md5，回退单文件校验。"
    FILES=("$ASSET" "$ASSET.md5")
fi

for f in "${FILES[@]}"; do
    info "下载: $f"
    curl -fL --retry 3 --connect-timeout 20 -o "$TMP/$f" "$BASE/$f" || \
        die "下载失败: $BASE/$f"
done

if [ -f "$TMP/checksums.md5" ]; then
    ( cd "$TMP" && md5sum -c checksums.md5 ) || die "md5 校验失败。"
else
    ( cd "$TMP" && md5sum -c "$ASSET.md5" ) || die "md5 校验失败。"
fi
ok "下载并校验完成。"

if [ "$MODE" = "brunch" ]; then
    args=(--kernel-file "$TMP/$ASSET" --bootscript-dir "$TMP")
else
    args=(--kernel-file "$TMP/$ASSET")
fi
$ASSUME_YES && args+=(-y)
bash "$INSTALLER" "${args[@]}"
