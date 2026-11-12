#!/bin/bash
#
# 为 ChromeOS ARCVM 内核编译 KernelSU LKM（在 PC / WSL 上运行）
#
# 为什么不能直接用官方 Release 里的 lkm-*.ko？
#   官方 x86_64 GKI LKM 是按 GKI 配置编译的，和 ChromeOS ARCVM 内核的
#   config 不一致。实测（QEMU + 用户提供的 vmlinux）会缺符号：
#     pgdir_shift, ptrs_per_p4d, __list_add_valid,
#     __list_del_entry_valid, static_key_count
#   另外 KernelSU 3.3.x 的 x86 LKM 要求内核有
#   X86_FEATURE_INDIRECT_SAFE（间接系统调用 bypass 补丁），
#   而 ARCVM 内核没有。
#
# 本脚本用 ARCVM 内核自己的 config 重新编译 KernelSU，并绕过上述
# X86_FEATURE_INDIRECT_SAFE 检查（走 kretprobe 路径）。已在 QEMU 中
# 用 5.10.252-1009564-ged76cab4c76e 验证：模块加载成功，能执行真实 init。
#
# 依赖（Ubuntu/WSL）：
#   git curl tar make gzip gcc clang lld llvm-ar llvm-strip
#   flex bison bc python3
#
# 用法：
#   ./build-arcvm-kernelsu-ko.sh --vmlinux /path/to/vmlinux
#   ./build-arcvm-kernelsu-ko.sh --vmlinux vmlinux --ksu-tag v3.3.1
#   ./build-arcvm-kernelsu-ko.sh --kernel-src /tmp/ckernel --ksu-src /tmp/KernelSU ...
#
# 之后在 ChromeOS 上：
#   sudo bash install-arcvm-kernelsu.sh --ko-file kernelsu-5.10.252-x86_64.ko

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

VMLINUX=${VMLINUX:-}
KSU_TAG=${KSU_TAG:-v3.3.1}
WORK=${WORK:-/tmp/arcvm-ksu-build}
OUT=${OUT:-$(pwd)}
KERNEL_TAR=${KERNEL_TAR:-}
KERNEL_SRC=${KERNEL_SRC:-}
KSU_SRC=${KSU_SRC:-}
ARCH_OVERRIDE=
KEEP_DEBUG=false
KERNEL_VERSION=${KERNEL_VERSION:-}
CONFIG_FILE=${CONFIG_FILE:-}

usage() {
    cat <<'USAGE'
用法: build-arcvm-kernelsu-ko.sh [选项]

  -v, --vmlinux <文件>    ARCVM 的 vmlinux（必需，用来读取版本和 config）
  -t, --ksu-tag <tag>     KernelSU tag（默认 v3.3.1）
  -w, --work <目录>       构建目录（默认 /tmp/arcvm-ksu-build）
  -o, --out <目录>        输出目录（默认当前目录）
  -a, --arch <架构>       x86_64 / arm64（默认自动检测）
      --kernel-tar <文件> 使用本地内核源码 tar.gz（默认按 commit 下载）
      --kernel-src <目录> 使用已解压/已准备的内核源码
      --kernel-version <版本> 不读 vmlinux，直接指定 uname -r
      --config <文件>     直接用给定内核 config（source-only 构建）
      --ksu-src <目录>    使用已有的 KernelSU 源码
      --keep-debug        不 strip 调试信息
  -h, --help              显示帮助

输出:
  <out>/kernelsu-<内核版本>-<架构>.ko

说明:
  - 内核源码从 chromium.googlesource.com 按 vmlinux 里的 commit 下载。
  - KernelSU 从 github.com/tiann/KernelSU 克隆指定 tag（不使用 KernelSU-Next）。
  - 会对 kernel/core/init.c 做一处兼容补丁：跳过
    X86_FEATURE_INDIRECT_SAFE 检查，改用 kretprobe 路径。
  - 构建需要约 4 GB 磁盘和 5-15 分钟。
USAGE
}

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

while getopts ":-:v:t:w:o:a:h" opt; do
    case "$opt" in
        v) VMLINUX=$OPTARG ;;
        t) KSU_TAG=$OPTARG ;;
        w) WORK=$OPTARG ;;
        o) OUT=$OPTARG ;;
        a) ARCH_OVERRIDE=$OPTARG ;;
        h) usage; exit 0 ;;
        -)
            case "$OPTARG" in
                vmlinux|ksu-tag|work|out|arch|kernel-tar|kernel-src|ksu-src|kernel-version|config)
                    val="${!OPTIND:-}"
                    [ -n "$val" ] || die "选项 --$OPTARG 需要一个参数"
                    case "$OPTARG" in
                        vmlinux) VMLINUX=$val ;;
                        ksu-tag) KSU_TAG=$val ;;
                        work) WORK=$val ;;
                        out) OUT=$val ;;
                        arch) ARCH_OVERRIDE=$val ;;
                        kernel-tar) KERNEL_TAR=$val ;;
                        kernel-src) KERNEL_SRC=$val ;;
                        ksu-src) KSU_SRC=$val ;;
                        kernel-version) KERNEL_VERSION=$val ;;
                        config) CONFIG_FILE=$val ;;
                    esac
                    OPTIND=$((OPTIND + 1))
                    ;;
                keep-debug) KEEP_DEBUG=true ;;
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

for c in curl tar make gzip gcc clang ld.lld llvm-ar llvm-strip flex bison bc python3 rustc cargo rustup git; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done

mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)

# ---------------------------------------------------------------- 版本/架构

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

detect_arch() {
    if [ -n "$ARCH_OVERRIDE" ]; then
        case "$ARCH_OVERRIDE" in
            x86_64|amd64) ARCH=x86_64 ;;
            arm64|aarch64) ARCH=arm64 ;;
            *) die "未知架构: $ARCH_OVERRIDE" ;;
        esac
        return
    fi
    [ -n "$VMLINUX" ] || die "source-only 构建请用 --arch 指定架构。"
    if [ "$(dd if="$VMLINUX" bs=1 skip=56 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "41524d64" ]; then
        ARCH=arm64
    else
        ARCH=x86_64
    fi
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
[ -n "$KCOMMIT" ] || die "无法从 \"$KVERSION\" 解析 commit；请用 --kernel-tar 指定源码。"
detect_arch

info "内核版本: $KVERSION"
info "内核 commit: $KCOMMIT"
info "架构: $ARCH"
info "KernelSU tag: $KSU_TAG"
info "构建目录: $WORK"

avail=$(df -Pk "$WORK" | awk 'NR==2 {print $4}')
[ -z "$avail" ] || [ "$avail" -gt 4000000 ] || die "构建目录空间不足 4 GB（可用 $((avail/1024)) MiB）。"

# ---------------------------------------------------------------- config

CONFIG="$WORK/config-$KBASE"
if [ -n "$CONFIG_FILE" ]; then
    CONFIG="$CONFIG_FILE"
    info "使用指定 config: $CONFIG"
elif [ ! -s "$CONFIG" ]; then
    info "从 vmlinux 提取内核 config..."
    CONFIG_SRC="$VMLINUX"
    # 如果是 bzImage，先解压出内部 ELF（config 在压缩载荷里）
    if [ "$(dd if="$VMLINUX" bs=1 skip=514 count=4 2>/dev/null || true)" = "HdrS" ]; then
        info "解压 bzImage 载荷..."
        setup_sects=$(od -An -tu1 -j 497 -N 1 "$VMLINUX" | tr -dc '0-9')
        poff=$(od -An -tu4 -j 584 -N 4 "$VMLINUX" | tr -dc '0-9')
        plen=$(od -An -tu4 -j 588 -N 4 "$VMLINUX" | tr -dc '0-9')
        [ -n "$setup_sects" ] && [ -n "$poff" ] && [ -n "$plen" ] || die "无法读取 bzImage setup header。"
        pstart=$(( (setup_sects + 1) * 512 + poff ))
        CONFIG_SRC="$WORK/vmlinux-$KBASE.elf"
        if [ ! -s "$CONFIG_SRC" ]; then
            first=$(tail -c +$((pstart + 1)) "$VMLINUX" | head -c 6 | od -An -tx1 | tr -d ' \n')
            case "$first" in
                1f8b*)   dec="gzip -dc" ;;
                fd377a585a00*) dec="xz -dc" ;;
                425a68*) dec="bzip2 -dc" ;;
                04224d18*) dec="lz4 -dc" ;;
                28b52ffd*) dec="zstd -dc" ;;
                *) die "未知的内核压缩格式: $first" ;;
            esac
            tail -c +$((pstart + 1)) "$VMLINUX" | head -c "$plen" | $dec > "$CONFIG_SRC" 2>/dev/null || true
            [ -s "$CONFIG_SRC" ] || die "解压 bzImage 载荷失败（$dec）。"
        fi
    fi
    off=$(LC_ALL=C grep -abo 'IKCFG_ST' "$CONFIG_SRC" | head -n1 | cut -d: -f1 || true)
    [ -n "$off" ] || die "vmlinux 里没有 IKCFG_ST，无法提取 config。"
    dd if="$CONFIG_SRC" bs=1 skip=$((off + 8)) 2>/dev/null | gzip -dc >"$CONFIG" 2>/dev/null || true
    [ -s "$CONFIG" ] || die "config 解压失败。"
fi
grep -q '^CONFIG_MODULES=y' "$CONFIG" || die "config 里 CONFIG_MODULES 不是 y。"
grep -q '^CONFIG_KPROBES=y' "$CONFIG" || die "config 里 CONFIG_KPROBES 不是 y。"
ok "config: $CONFIG"

# ---------------------------------------------------------------- 源码

KSRC="$KERNEL_SRC"
if [ -z "$KSRC" ]; then
    KSRC="$WORK/kernel-$KCOMMIT"
    if [ ! -d "$KSRC" ]; then
        mkdir -p "$KSRC"
        if [ -n "$KERNEL_TAR" ]; then
            [ -f "$KERNEL_TAR" ] || die "找不到 --kernel-tar: $KERNEL_TAR"
            info "解压内核源码: $KERNEL_TAR"
            tar -xzf "$KERNEL_TAR" -C "$KSRC"
        else
            url="https://chromium.googlesource.com/chromiumos/third_party/kernel/+archive/$KCOMMIT.tar.gz"
            tgz="$WORK/kernel-$KCOMMIT.tar.gz"
            info "下载内核源码: $url"
            curl -fL --retry 3 -# -o "$tgz" "$url" || die "内核源码下载失败。"
            tar -xzf "$tgz" -C "$KSRC"
        fi
    fi
fi
[ -f "$KSRC/Makefile" ] || die "内核源码目录无效: $KSRC"

KSUSRC="$KSU_SRC"
if [ -z "$KSUSRC" ]; then
    KSUSRC="$WORK/KernelSU-$KSU_TAG"
    if [ ! -d "$KSUSRC" ]; then
        info "克隆 KernelSU $KSU_TAG ..."
        git clone --depth 1 --branch "$KSU_TAG" https://github.com/tiann/KernelSU.git "$KSUSRC" || \
            die "KernelSU 克隆失败。"
    fi
fi
[ -f "$KSUSRC/kernel/core/init.c" ] || die "KernelSU 源码目录无效: $KSUSRC"

# ARCVM 兼容补丁统一由 patch_android.sh 负责：
#   1) 跳过 X86_FEATURE_INDIRECT_SAFE 检查；
#   2) ksuinit 加载后直接 exec /init.real；
#   3) init 读 init.rc 时提前应用 SELinux 规则（ARCVM 必须）。
info "应用 ARCVM 兼容补丁..."
KO_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
[ -f "$KO_SCRIPT_DIR/patch_android.sh" ] || die "找不到 patch_android.sh（应与本脚本同目录）。"
bash "$KO_SCRIPT_DIR/patch_android.sh" --ksu-src "$KSUSRC"
ok "补丁已应用"

# ---------------------------------------------------------------- 编译

info "准备内核构建树（olddefconfig + modules_prepare）..."
cd "$KSRC"
# 源码树位于外层 git 仓库里（CI 的 kernel-src）或从 tar 解压而来时，
# setlocalversion 会把树判成 dirty 并追加 "+"，导致 vermagic 与 stock 不一致。
# 空 .scmversion 让 setlocalversion 直接返回空。
: > "$KSRC/.scmversion"
cp "$CONFIG" .config
make LLVM=1 ARCH="$ARCH" olddefconfig >"$WORK/prepare.log" 2>&1
# 让模块的 vermagic 与目标内核完全一致（包括 -1009564-g... 后缀）
if [ -x "$KSRC/scripts/config" ]; then
    "$KSRC/scripts/config" --file "$KSRC/.config" --set-str LOCALVERSION "$LOCALVERSION_SUFFIX"
    "$KSRC/scripts/config" --file "$KSRC/.config" --disable LOCALVERSION_AUTO
    make LLVM=1 ARCH="$ARCH" olddefconfig >>"$WORK/prepare.log" 2>&1
fi
make LLVM=1 ARCH="$ARCH" modules_prepare >>"$WORK/prepare.log" 2>&1
# 生成 security/selinux/flask.h
make LLVM=1 ARCH="$ARCH" security/selinux/ >>"$WORK/prepare.log" 2>&1

info "编译 KernelSU LKM..."
KSU_MAKE_ARGS=(CONFIG_KSU=m)
[ "$ARCH" = "x86_64" ] && KSU_MAKE_ARGS+=(CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y)
make LLVM=1 ARCH="$ARCH" M="$KSUSRC/kernel" "${KSU_MAKE_ARGS[@]}" modules >"$WORK/build.log" 2>&1 || {
    tail -40 "$WORK/build.log" >&2
    die "KernelSU 模块编译失败。"
}

KO="$KSUSRC/kernel/kernelsu.ko"
[ -f "$KO" ] || die "没有生成 kernelsu.ko。"
etype=$(od -An -tu2 -j 16 -N 2 "$KO" | tr -dc '0-9')
[ "$etype" = "1" ] || die "生成的 ko 不是 ET_REL（type=$etype）。"
grep -a -q '\.modinfo' "$KO" || die "生成的 ko 缺少 .modinfo。"

if ! $KEEP_DEBUG; then
    llvm-strip --strip-debug "$KO"
fi

OUTFILE="$OUT/kernelsu-${KBASE}-${ARCH}.ko"
cp -f "$KO" "$OUTFILE"
chmod 0644 "$OUTFILE"

# ---------------------------------------------------------------- ksuinit

# ksuinit 的持久化补丁（加载后直接 exec /init.real）已经由
# patch_android.sh 在编译前完成，这里只负责构建。
info "构建自定义 ksuinit..."

case "$ARCH" in
    x86_64) RUST_ARCH=x86_64 ;;
    arm64) RUST_ARCH=aarch64 ;;
    *) die "不支持的 Rust 目标架构: $ARCH" ;;
esac
RUST_TARGET="${RUST_ARCH}-unknown-linux-musl"
rustup target add "$RUST_TARGET" >"$WORK/rust-target.log" 2>&1 || {
    tail -20 "$WORK/rust-target.log" >&2
    die "无法安装 Rust target: $RUST_TARGET"
}
(cd "$KSUSRC" && cargo build --release --target "$RUST_TARGET" -p ksuinit) >"$WORK/ksuinit-build.log" 2>&1 || {
    tail -40 "$WORK/ksuinit-build.log" >&2
    die "ksuinit 编译失败。"
}
KSUINIT_BIN="$KSUSRC/target/$RUST_TARGET/release/ksuinit"
[ -f "$KSUINIT_BIN" ] || die "没有生成 ksuinit。"
KSUINIT_OUT="$OUT/ksuinit-${RUST_ARCH}-custom"
cp -f "$KSUINIT_BIN" "$KSUINIT_OUT"
chmod 0755 "$KSUINIT_OUT"

echo
ok "构建完成: $OUTFILE（$(du -h "$OUTFILE" | awk '{print $1}')）"
ok "构建完成: $KSUINIT_OUT（$(du -h "$KSUINIT_OUT" | awk '{print $1}')）"
info "内核版本: $KVERSION / 架构: $ARCH"
info "KernelSU: $KSU_TAG（模块版本见 QEMU/管理器）"
if [ "${KSU_VMLINUX_MODE:-0}" = "0" ]; then
    echo
    info "在 ChromeOS 上安装（system.raw.img 注入方式，可选）:"
    printf '  sudo bash install-arcvm-kernelsu-image.sh --ko-file %s --ksuinit %s\n' "$OUTFILE" "$KSUINIT_OUT"
fi
warn "ChromeOS/ARCVM 内核更新后，请用新的 vmlinux 重新运行本脚本。"
