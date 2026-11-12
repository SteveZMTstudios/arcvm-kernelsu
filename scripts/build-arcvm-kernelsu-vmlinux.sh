#!/bin/bash
#
# 为 ChromeOS ARCVM 构建“只替换 vmlinux”的 KernelSU 内核
#
# 在 PC / WSL 上运行。产物是一个带内嵌 initramfs 的 vmlinux：
#   /init      = 自定义 ksuinit（加载 /kernelsu.ko）
#   /init.real = switchroot（挂载 /dev/vda，切到 Android /init）
#   /kernelsu.ko = 按 ARCVM 内核 config 编译的 KernelSU LKM
#
# 只会替换目标设备的 /opt/google/vms/android/vmlinux；
# 不修改 system.raw.img / vendor.raw.img / rootfs 验证。
#
# 代价：KernelSU 升级需要重新构建并刷这个 vmlinux（ko 内嵌在 initramfs 里）。
# 好处：持久化、无镜像改动、可通过 vmlinux.original 完整恢复。
#
# 依赖（Ubuntu/WSL）：
#   git curl tar make gzip gcc clang lld llvm-ar llvm-strip
#   flex bison bc python3 rustc cargo rustup
#   arm64 交叉编译还需要 aarch64-linux-gnu-gcc
#
# 用法：
#   ./build-arcvm-kernelsu-vmlinux.sh --vmlinux /path/to/stock-vmlinux
#   ./build-arcvm-kernelsu-vmlinux.sh --vmlinux vmlinux.original -j 16

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

VMLINUX=${VMLINUX:-}
KSU_TAG=${KSU_TAG:-v3.3.1}
WORK=${WORK:-/tmp/arcvm-ksu-vmlinux}
OUT=${OUT:-$(pwd)}
KERNEL_SRC=${KERNEL_SRC:-}
KSU_SRC=${KSU_SRC:-}
ARCH_OVERRIDE=
JOBS=$(nproc 2>/dev/null || echo 4)
KERNEL_VERSION=${KERNEL_VERSION:-}
CONFIG_FILE=${CONFIG_FILE:-}

usage() {
    cat <<'USAGE'
用法: build-arcvm-kernelsu-vmlinux.sh [选项]

  -v, --vmlinux <文件>  官方/stock vmlinux（source-only 构建时可省略）
  -t, --ksu-tag <tag>   KernelSU tag（默认 v3.3.1）
  -w, --work <目录>     构建目录（默认 /tmp/arcvm-ksu-vmlinux）
  -o, --out <目录>      输出目录（默认当前目录）
  -j, --jobs <N>        并行编译数（默认 nproc）
  -a, --arch <架构>     x86_64 / arm64（默认自动检测）
      --kernel-version <uname -r>  source-only 构建时指定内核 release
      --config <文件>      source-only 构建时指定内核 config
      --kernel-src <目录> 使用已有内核源码
      --ksu-src <目录>    使用已有 KernelSU 源码
  -h, --help            显示帮助

输出:
  <out>/vmlinux-<内核版本>-<架构>

说明:
  - 会先调用 build-arcvm-kernelsu-ko.sh 生成 ko 和 ksuinit；
  - 内核源码按 vmlinux 里的 commit 下载；
  - 自动下载 CONFIG_EXTRA_FIRMWARE 需要的固件；
  - 设置 CONFIG_LOCALVERSION，使内核 release 与 stock 完全一致；
  - 构建 bzImage（x86_64）或 Image（arm64）。
USAGE
}

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

while getopts ":-:v:t:w:o:j:a:h" opt; do
    case "$opt" in
        v) VMLINUX=$OPTARG ;;
        t) KSU_TAG=$OPTARG ;;
        w) WORK=$OPTARG ;;
        o) OUT=$OPTARG ;;
        j) JOBS=$OPTARG ;;
        a) ARCH_OVERRIDE=$OPTARG ;;
        h) usage; exit 0 ;;
        -)
            case "$OPTARG" in
                vmlinux|ksu-tag|work|out|jobs|arch|kernel-src|ksu-src|kernel-version|config)
                    val="${!OPTIND:-}"
                    [ -n "$val" ] || die "选项 --$OPTARG 需要一个参数"
                    case "$OPTARG" in
                        vmlinux) VMLINUX=$val ;;
                        ksu-tag) KSU_TAG=$val ;;
                        work) WORK=$val ;;
                        out) OUT=$val ;;
                        jobs) JOBS=$val ;;
                        arch) ARCH_OVERRIDE=$val ;;
                        kernel-src) KERNEL_SRC=$val ;;
                        ksu-src) KSU_SRC=$val ;;
                        kernel-version) KERNEL_VERSION=$val ;;
                        config) CONFIG_FILE=$val ;;
                    esac
                    OPTIND=$((OPTIND + 1))
                    ;;
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

[ -n "$VMLINUX" ] || [ -n "$KERNEL_VERSION" ] || die "请用 --vmlinux 或 --kernel-version 指定内核版本。"
[ -z "$VMLINUX" ] || [ -f "$VMLINUX" ] || die "找不到 vmlinux: $VMLINUX"
[ -z "$CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ] || die "找不到 config: $CONFIG_FILE"
[ -n "$CONFIG_FILE" ] || [ -n "$VMLINUX" ] || die "source-only 构建请用 --config 指定内核 config。"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
KO_SCRIPT="$SCRIPT_DIR/build-arcvm-kernelsu-ko.sh"
[ -x "$KO_SCRIPT" ] || [ -f "$KO_SCRIPT" ] || die "找不到 build-arcvm-kernelsu-ko.sh（应与本脚本同目录）。"

for c in curl tar gzip gcc make python3; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done
mkdir -p "$WORK" "$OUT"

read_kernel_version() {
    local f=$1 magic kv_off abs raw
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

if [ -n "$KERNEL_VERSION" ]; then
    KVERSION=$KERNEL_VERSION
else
    KVERSION=$(read_kernel_version "$VMLINUX" || true)
    [ -n "$KVERSION" ] || die "无法从 $VMLINUX 读取内核版本。"
fi
KBASE=${KVERSION%%-*}
LOCALVERSION_SUFFIX=${KVERSION#"$KBASE"}
KCOMMIT=$(printf '%s' "$KVERSION" | sed -n 's/.*-g\([0-9a-f]\{7,\}\).*/\1/p')
[ -n "$KCOMMIT" ] || die "无法从 \"$KVERSION\" 解析 commit。"

if [ -n "$ARCH_OVERRIDE" ]; then
    case "$ARCH_OVERRIDE" in
        x86_64|amd64) ARCH=x86_64; KSU_ARCH=x86_64 ;;
        arm64|aarch64) ARCH=arm64; KSU_ARCH=aarch64 ;;
        *) die "未知架构: $ARCH_OVERRIDE" ;;
    esac
elif [ -n "$VMLINUX" ] && [ "$(dd if="$VMLINUX" bs=1 skip=56 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "41524d64" ]; then
    ARCH=arm64; KSU_ARCH=aarch64
else
    ARCH=x86_64; KSU_ARCH=x86_64
fi

KSRC=${KERNEL_SRC:-$WORK/kernel-$KCOMMIT}
info "内核版本: $KVERSION"
info "内核 commit: $KCOMMIT"
info "架构: $ARCH（KernelSU 资产: $KSU_ARCH）"
info "构建目录: $WORK"
info "输出目录: $OUT"

# ---------------------------------------------------------------- 先生成 ko + ksuinit

KO_ARGS=(--ksu-tag "$KSU_TAG" --work "$WORK" --out "$OUT" --arch "$ARCH" --kernel-version "$KVERSION")
[ -n "$VMLINUX" ] && KO_ARGS+=(--vmlinux "$VMLINUX")
[ -n "$CONFIG_FILE" ] && KO_ARGS+=(--config "$CONFIG_FILE")
[ -n "$KERNEL_SRC" ] && KO_ARGS+=(--kernel-src "$KERNEL_SRC")
[ -n "$KSU_SRC" ] && KO_ARGS+=(--ksu-src "$KSU_SRC")
info "调用 build-arcvm-kernelsu-ko.sh ..."
KSU_VMLINUX_MODE=1 bash "$KO_SCRIPT" "${KO_ARGS[@]}"

KO="$OUT/kernelsu-$KBASE-$ARCH.ko"
KSUINIT="$OUT/ksuinit-$KSU_ARCH-custom"
[ -f "$KO" ] || die "没有生成 $KO"
[ -f "$KSUINIT" ] || die "没有生成 $KSUINIT"

[ -d "$KSRC" ] || die "内核源码目录不存在: $KSRC（ko 脚本应已下载/准备）"
[ -f "$KSRC/.config" ] || die "内核源码没有 .config: $KSRC"

# ---------------------------------------------------------------- switchroot

SWITCHROOT_SRC="$WORK/switchroot.c"
cat > "$SWITCHROOT_SRC" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>

static int wait_device(const char *path, int seconds) {
    for (int i = 0; i < seconds * 10; i++) {
        int fd = open(path, O_RDONLY);
        if (fd >= 0) { close(fd); return 0; }
        usleep(100000);
    }
    return -1;
}

int main(void) {
    const char *root = "/dev/vda";
    mkdir("/dev", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mkdir("/newroot", 0755);

    if (wait_device(root, 20) != 0) {
        fprintf(stderr, "switchroot: %s not found\n", root);
        return 1;
    }
    const char *types[] = { "erofs", "ext4", "f2fs", NULL };
    int mounted = 0;
    for (int i = 0; types[i]; i++) {
        if (mount(root, "/newroot", types[i], MS_RDONLY, "") == 0) {
            mounted = 1;
            break;
        }
    }
    if (!mounted) {
        fprintf(stderr, "switchroot: mount %s failed (erofs/ext4/f2fs): %s\n", root, strerror(errno));
        return 1;
    }
    /* 把 devtmpfs 移进新 root，保证 /dev/console、/dev/kmsg 等在 exec /init 前可用。 */
    mkdir("/newroot/dev", 0755);
    mount("/dev", "/newroot/dev", NULL, MS_MOVE, NULL);
    if (chdir("/newroot") != 0) { perror("chdir /newroot"); return 1; }
    if (mount("/newroot", "/", NULL, MS_MOVE, NULL) != 0) { perror("move mount"); return 1; }
    if (chroot(".") != 0) { perror("chroot"); return 1; }

    char *argv[] = { "/init", NULL };
    char *envp[] = { "PATH=/sbin:/bin:/usr/sbin:/usr/bin", "HOME=/", NULL };
    execve("/init", argv, envp);
    fprintf(stderr, "switchroot: exec /init failed: %s\n", strerror(errno));
    return 1;
}
EOF

case "$ARCH" in
    x86_64) CC=${CC:-gcc} ;;
    arm64) CC=${CC:-aarch64-linux-gnu-gcc} ;;
esac
command -v "$CC" >/dev/null 2>&1 || die "缺少编译器: $CC"
info "编译 switchroot（$CC）..."
"$CC" -static -Os -o "$WORK/init.real" "$SWITCHROOT_SRC" || die "switchroot 编译失败。"

# ---------------------------------------------------------------- initramfs

INITRAMFS="$WORK/initramfs"
rm -rf "$INITRAMFS"
mkdir -p "$INITRAMFS"/{dev,proc,sys,tmp}
cp "$KSUINIT" "$INITRAMFS/init"
cp "$WORK/init.real" "$INITRAMFS/init.real"
cp "$KO" "$INITRAMFS/kernelsu.ko"
chmod 755 "$INITRAMFS/init" "$INITRAMFS/init.real"
chmod 644 "$INITRAMFS/kernelsu.ko"
chmod 755 "$INITRAMFS"/{dev,proc,sys,tmp}

# ---------------------------------------------------------------- config / firmware

cd "$KSRC"
CONFIG="$KSRC/.config"

"$KSRC/scripts/config" --file "$CONFIG" --set-str INITRAMFS_SOURCE "$INITRAMFS"
"$KSRC/scripts/config" --file "$CONFIG" --set-str LOCALVERSION "$LOCALVERSION_SUFFIX"
"$KSRC/scripts/config" --file "$CONFIG" --disable LOCALVERSION_AUTO

# built-in / LKM 必须显式选择：内核树里可能有 drivers/kernelsu 符号链接，
# KernelSU 的 Kconfig 又是 default y，olddefconfig 会悄悄把 KSU 编进内核。
KSU_MODE=${KSU_MODE:-lkm}
case "$KSU_MODE" in
    builtin)
        info "KernelSU 模式: built-in（CONFIG_KSU=y）"
        "$KSRC/scripts/config" --file "$CONFIG" --enable KSU
        ;;
    lkm)
        info "KernelSU 模式: LKM（CONFIG_KSU 关闭，模块由 initramfs 加载）"
        "$KSRC/scripts/config" --file "$CONFIG" --disable KSU
        ;;
    *) die "KSU_MODE 只能是 builtin 或 lkm: $KSU_MODE" ;;
esac

# x86_64 上 syscall hook 需要 patch do_syscall_64；
# 不打开时 tracepoint 改写的 syscall 号不会被内核采用，hook 全部静默失效。
if [ "$ARCH" = "x86_64" ] && [ "${KSU_X86_SYSCALL_DISPATCHER:-0}" = "1" ]; then
    info "启用 CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER"
    "$KSRC/scripts/config" --file "$CONFIG" --enable KSU_X86_PATCH_SYSCALL_DISPATCHER
fi

FW=$(sed -n 's/^CONFIG_EXTRA_FIRMWARE="\(.*\)"/\1/p' "$CONFIG" || true)
if [ -n "$FW" ]; then
    FWDIR="$WORK/firmware"
    mkdir -p "$FWDIR"
    info "准备 CONFIG_EXTRA_FIRMWARE 固件..."
    for f in $FW; do
        dest="$FWDIR/$f"
        mkdir -p "$(dirname "$dest")"
        if [ -s "$dest" ]; then continue; fi
        curl -fsSL --retry 3 -o "$dest" \
            "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/$f" \
            || die "固件下载失败: $f"
    done
    "$KSRC/scripts/config" --file "$CONFIG" --set-str EXTRA_FIRMWARE_DIR "$FWDIR"
fi

make LLVM=1 ARCH="$ARCH" olddefconfig >"$WORK/kbuild-config.log" 2>&1

KSU_CFG=$(sed -n 's/^CONFIG_KSU=\([ym]\)$/\1/p' "$CONFIG" | head -n1 || true)
if [ "$KSU_MODE" = "builtin" ]; then
    [ "$KSU_CFG" = "y" ] || die "KSU_MODE=builtin 但 .config 里 CONFIG_KSU 不是 y（当前: ${KSU_CFG:-未设置}）。"
else
    [ "$KSU_CFG" = "y" ] && die "KSU_MODE=lkm 但 .config 里仍是 CONFIG_KSU=y，内核会把 KernelSU 编进去。"
fi
REL=$(make -s LLVM=1 ARCH="$ARCH" kernelrelease 2>/dev/null || true)
info "内核 release: $REL"
[ "$REL" = "$KVERSION" ] || warn "内核 release ($REL) 与 stock ($KVERSION) 不一致；vendor 模块可能加载失败。"

PKG="bzImage"
[ "$ARCH" = "arm64" ] && PKG="Image"

info "编译内核（$PKG，-j$JOBS）..."
KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-cros-kernel} \
KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-chromium.org} \
KBUILD_BUILD_VERSION=${KBUILD_BUILD_VERSION:-1} \
KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-"Wed, 21 Oct 2026 19:12:41 -0700"} \
make LLVM=1 ARCH="$ARCH" -j"$JOBS" "$PKG" >"$WORK/kbuild.log" 2>&1 || {
    tail -60 "$WORK/kbuild.log" >&2
    die "内核编译失败。"
}

case "$ARCH" in
    x86_64) KERNEL_BIN="$KSRC/arch/x86/boot/bzImage" ;;
    arm64) KERNEL_BIN="$KSRC/arch/arm64/boot/Image" ;;
esac
[ -f "$KERNEL_BIN" ] || die "没有生成内核镜像: $KERNEL_BIN"

if [ "$KSU_MODE" = "lkm" ]; then
    if nm "$KSRC/vmlinux" 2>/dev/null | grep -q ' ksu_syscall_hook_init$'; then
        die "KSU_MODE=lkm 但 vmlinux 符号表里仍有 ksu_syscall_hook_init（built-in 泄漏）。"
    fi
fi

OUTFILE="$OUT/vmlinux-$KBASE-$ARCH"
cp -f "$KERNEL_BIN" "$OUTFILE"
chmod 0644 "$OUTFILE"

echo
ok "构建完成: $OUTFILE（$(du -h "$OUTFILE" | awk '{print $1}')）"
info "内核: $KVERSION / $ARCH"
info "KernelSU: $KSU_TAG（ko 内嵌在 initramfs）"
echo
info "在 ChromeOS 上安装（只替换 vmlinux）："
printf '  sudo bash install-arcvm-kernelsu.sh --kernel-file %s\n' "$OUTFILE"
warn "KernelSU 升级需要重新构建并刷 vmlinux；system.raw.img 不会被改动。"
