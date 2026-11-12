#!/bin/bash
#
# patch_android.sh — 给 KernelSU 源码打 ARCVM 兼容补丁（最小集合）
#
# 补丁内容（仅 3 处，不碰 SELinux 规则、不碰 core/init.c、不加额外 kprobe）：
#   1) userspace/ksuinit
#      官方 ksuinit 会 unlink("/init") 并 symlink 到 /init.real，假设
#      每次启动都有独立 ramdisk。ARCVM 的 /init 在 EROFS root 上，
#      initramfs 里加载模块后直接 exec /init.real（switchroot）。
#   2) kernel/hook/x86_64/syscall_hook.c
#      ARCVM 5.10.252 的 do_syscall_64(unsigned long nr, struct pt_regs *regs)
#      参数顺序是 (nr, regs)，而上游 KernelSU < 5.16 分支假设的是 (regs, nr)。
#      开启 CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y 时修正该签名即可让
#      官方全部 syscall hook（init second_stage、zygote、ksud、sucompat、setresuid）
#      原生工作，无需任何 SELinux 规则或 kprobe 兜底补丁。
#   3) kernel/hook/tp_marker.c
#      其它 tracepoint 用户注册/注销时，KernelSU 在 irqsave 自旋锁内扫描全部线程；
#      ARCVM 的 console=ttyS0 会因逐线程 pr_info 阻塞数秒。把逐线程日志降为 pr_debug。

set -eu

RED=$'\e[1;31m'
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

KSU_SRC=${KSU_SRC:-}
KSU_TAG=${KSU_TAG:-v3.3.1}
WORK=${WORK:-/tmp/KernelSU}
OUT=${OUT:-$(pwd)}
VMLINUX=${VMLINUX:-}
ARCH_OVERRIDE=
MODE=patch

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ksu-src)  KSU_SRC=${2:-}; shift 2 ;;
        --tag)      KSU_TAG=${2:-}; shift 2 ;;
        --work)     WORK=${2:-}; shift 2 ;;
        --out)      OUT=${2:-}; shift 2 ;;
        --vmlinux)  VMLINUX=${2:-}; shift 2 ;;
        --arch)     ARCH_OVERRIDE=${2:-}; shift 2 ;;
        --check)    MODE=check; shift ;;
        --revert)   MODE=revert; shift ;;
        --build)    MODE=build; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "不支持的参数: $1（--help 查看用法）" ;;
    esac
done

[ -n "$KSU_SRC" ] || KSU_SRC="$WORK/KernelSU-$KSU_TAG"

if [ ! -d "$KSU_SRC" ]; then
    [ "$MODE" = "revert" ] && die "KernelSU 源码不存在，无法 revert: $KSU_SRC"
    command -v git >/dev/null 2>&1 || die "缺少 git，无法克隆 KernelSU。"
    info "克隆 KernelSU $KSU_TAG -> $KSU_SRC"
    mkdir -p "$(dirname "$KSU_SRC")"
    git clone --depth 1 --branch "$KSU_TAG" https://github.com/tiann/KernelSU.git "$KSU_SRC" || \
        die "KernelSU 克隆失败。"
fi

INIT_RS="$KSU_SRC/userspace/ksuinit/src/init.rs"
MAIN_RS="$KSU_SRC/userspace/ksuinit/src/main.rs"
TPMARKER_C="$KSU_SRC/kernel/hook/tp_marker.c"
X86HOOK_C="$KSU_SRC/kernel/hook/x86_64/syscall_hook.c"

[ -f "$INIT_RS" ] || die "缺 userspace/ksuinit/src/init.rs: $KSU_SRC"
[ -f "$MAIN_RS" ] || die "缺 userspace/ksuinit/src/main.rs: $KSU_SRC"
[ -f "$TPMARKER_C" ] || die "缺 kernel/hook/tp_marker.c: $KSU_SRC"
[ -f "$X86HOOK_C" ] || die "缺 kernel/hook/x86_64/syscall_hook.c: $KSU_SRC"

check_patches() {
    local missing=0
    grep -Fq 'init is /init.real' "$INIT_RS" || { warn "ksuinit init.rs 未打补丁"; missing=1; }
    grep -Fq 'execve(cstr!("/init.real")' "$MAIN_RS" || { warn "ksuinit main.rs 未打补丁"; missing=1; }
    grep -Fq 'my_do_syscall_64(unsigned long nr, struct pt_regs *regs)' "$X86HOOK_C" || { warn "x86 do_syscall_64 签名未修正"; missing=1; }
    grep -Fq 'pr_debug("tp_marker: unmark process' "$TPMARKER_C" || { warn "tp_marker.c 逐线程日志未降级"; missing=1; }
    [ "$missing" -eq 0 ]
}

apply_patches() {
    command -v python3 >/dev/null 2>&1 || die "缺少 python3。"

    # 先确保之前实验留下的非必要改动已还原，保证 SELinux 规则与核心逻辑 100% 官方原版
    if git -C "$KSU_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$KSU_SRC" checkout -- \
            kernel/core/init.c \
            kernel/runtime/ksud_integration.c \
            kernel/selinux/rules.c \
            kernel/hook/setuid_hook.c 2>/dev/null || true
    fi

    info "补丁 1/3: userspace/ksuinit（加载后直接 exec /init.real）"
    python3 - "$KSU_SRC" <<'PY'
import pathlib, sys
base = pathlib.Path(sys.argv[1]) / "userspace/ksuinit/src"
init = base / "init.rs"
main = base / "main.rs"

t = init.read_text()
if 'init is /init.real' not in t:
    t = t.replace("use rustix::fs::{Mode, symlink, unlink};", "use rustix::fs::Mode;")
    marker = "    // And now we should prepare the real init to transfer control to it"
    if marker in t:
        start = t.index(marker)
        end = t.index("    Ok(())", start)
        t = t[:start] + '    log::info!("init is /init.real");\n\n' + t[end:]
        init.write_text(t)

m = main.read_text()
if 'cstr!("/init.real")' not in m:
    main.write_text(m.replace('cstr!("/init")', 'cstr!("/init.real")'))
PY
    grep -Fq 'init is /init.real' "$INIT_RS" || die "ksuinit init.rs 补丁失败。"
    grep -Fq 'execve(cstr!("/init.real")' "$MAIN_RS" || die "ksuinit main.rs 补丁失败。"

    info "补丁 2/3: hook/x86_64/syscall_hook.c（do_syscall_64 参数顺序）"
    python3 - "$X86HOOK_C" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "static void __nocfi my_do_syscall_64(struct pt_regs *regs, int nr)"
new = ("/* ARCVM 5.10.x: do_syscall_64(unsigned long nr, struct pt_regs *regs).\n"
       " * Upstream KernelSU assumes (regs, nr), which swaps both arguments and\n"
       " * crashes in syscall_enter_from_user_mode(). */\n"
       "static void __nocfi my_do_syscall_64(unsigned long nr, struct pt_regs *regs)")
if "my_do_syscall_64(unsigned long nr, struct pt_regs *regs)" not in s:
    if old not in s:
        raise SystemExit("x86_64/syscall_hook.c: my_do_syscall_64 anchor not found")
    s = s.replace(old, new, 1)
p.write_text(s)
PY
    grep -Fq 'my_do_syscall_64(unsigned long nr, struct pt_regs *regs)' "$X86HOOK_C" || die "x86 syscall hook 补丁失败。"

    info "补丁 3/3: hook/tp_marker.c（逐线程 printk 降为 pr_debug）"
    python3 - "$TPMARKER_C" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
pairs = [
    ('pr_info("tp_marker: mark process: pid:%d, uid: %d, comm:%s\\n"',
     'pr_debug("tp_marker: mark process: pid:%d, uid: %d, comm:%s\\n"'),
    ('pr_info("tp_marker: unmark process: pid:%d, uid: %d, comm:%s\\n"',
     'pr_debug("tp_marker: unmark process: pid:%d, uid: %d, comm:%s\\n"'),
]
for old, new in pairs:
    s = s.replace(old, new)
p.write_text(s)
PY
    grep -Fq 'pr_debug("tp_marker: unmark process' "$TPMARKER_C" || die "tp_marker.c 补丁失败。"

    ok "补丁已应用: $KSU_SRC"
}

do_revert() {
    command -v git >/dev/null 2>&1 || die "缺少 git。"
    git -C "$KSU_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
        die "不是 git 工作树，无法自动 revert: $KSU_SRC"
    info "还原 KernelSU 源码..."
    git -C "$KSU_SRC" checkout -- \
        kernel/core/init.c \
        kernel/runtime/ksud_integration.c \
        kernel/selinux/rules.c \
        kernel/hook/setuid_hook.c \
        kernel/hook/tp_marker.c \
        kernel/hook/x86_64/syscall_hook.c \
        userspace/ksuinit/src/init.rs \
        userspace/ksuinit/src/main.rs
    ok "已还原。"
}

case "$MODE" in
    check)
        info "检查补丁: $KSU_SRC"
        if check_patches; then
            ok "三个补丁都已应用。"
        else
            die "补丁不完整。"
        fi
        ;;
    revert)
        do_revert
        ;;
    patch|build)
        apply_patches
        if [ "$MODE" = "build" ]; then
            [ -n "$VMLINUX" ] || die "--build 需要同时指定 --vmlinux。"
            BUILD_SCRIPT="$(cd "$(dirname "$0")" && pwd)/build-arcvm-kernelsu-ko.sh"
            [ -f "$BUILD_SCRIPT" ] || die "找不到 build-arcvm-kernelsu-ko.sh（应与本脚本同目录）。"
            info "调用 build-arcvm-kernelsu-ko.sh 编译..."
            args=(--vmlinux "$VMLINUX" --ksu-src "$KSU_SRC" --out "$OUT")
            [ -n "$ARCH_OVERRIDE" ] && args+=(--arch "$ARCH_OVERRIDE")
            exec bash "$BUILD_SCRIPT" "${args[@]}"
        fi
        echo
        info "下一步（编译 ko + ksuinit）："
        printf '  bash build-arcvm-kernelsu-ko.sh --vmlinux /path/to/vmlinux --ksu-src %s\n' "$KSU_SRC"
        info "或一次性构建可启动 vmlinux："
        printf '  bash build-arcvm-kernelsu-vmlinux.sh --vmlinux /path/to/vmlinux\n'
        ;;
esac
