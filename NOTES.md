# NOTES

## 最终形态

- **LKM 模式**：内核本体不含 KernelSU（`nm vmlinux` 无 `ksu_*`），
  `ksuinit` 在 switchroot 前加载内嵌的 `kernelsu.ko`；
- 只替换 `/opt/google/vms/android/vmlinux`，保留 `vmlinux.original`；
- `patch_android.sh` 只有 3 处平台适配，SELinux 规则为 KernelSU 官方原版。

## 三处补丁

| 文件 | 原因 |
|---|---|
| `userspace/ksuinit` | ARCVM 的 `/init` 在持久 EROFS 上，官方“unlink + symlink”方案第二次启动失效；改为加载后直接 `exec /init.real` |
| `kernel/hook/x86_64/syscall_hook.c` | ARCVM 5.10.252 是 `do_syscall_64(unsigned long nr, struct pt_regs *regs)`，上游假设 `(regs, nr)`；开 `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER` 时会因参数交换 panic |
| `kernel/hook/tp_marker.c` | 全线程扫描时逐线程 `pr_info`；`console=ttyS0` 下每行约 3 ms，2000 线程 = 数秒中断关闭 + 串口输出，整机冻结 |

## 两个关键根因（实测）

### 1. 5–7 秒全系统卡顿 - 解决

`dmesg` 在 225 秒里出现 2341 条 `tp_marker: mark process` + 2183 条
`unmark process`；同样时间窗内 `system_server` 的 main looper 出现
6007 / 7438 / 6073 / 6239 ms 的 `Slow dispatch`。
`ksu_mark_running_process_locked()` 在 `spin_lock_irqsave` 内遍历全部线程并逐条
printk，这就是根因。

修复后（`pr_debug`）：`tp_marker` 0 条，`Slow dispatch` 最大 162 ms
（开机媒体扫描另有一次 10 s，来自 `ModernMediaScanner` 扫描宿主共享目录）。

### 2. `su` 完全不工作 - 解决

症状：`ls /system/bin/su` → ENOENT，`test -e` → rc=1，`su -c id` → not found。
不是 allowlist、也不是 erofs：内核在 `execve` 里把 `/system/bin/su` 换成
`/data/adb/ksud`，不需要真实文件。

真实原因：x86 的 syscall hook 靠 `sys_enter` tracepoint 改写 `orig_ax`，
5.10 的 `do_syscall_64` 用 `syscall_enter_from_user_mode()` 的返回值，改写被忽略；
所有 hook（execve/execveat/newfstatat/faccessat）静默失效。

开启 `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y`（上游 x86 LKM 也是这么编的，
见 KernelSU `.github/workflows/ddk-lkm.yml`）并修正 `my_do_syscall_64` 参数顺序后，
真机日志：

```
KernelSU: /system/bin/init second_stage executed
KernelSU: escape to root for init executing ksud: 339
KernelSU: post-fs-data triggered
KernelSU: load_allow_uid, name: com.android.shell, uid: 2000, allow: 1
KernelSU: exec zygote, /data prepared, second_stage: 1
```

`su -c id` → `uid=0(root) ... context=u:r:ksu:s0`。

## 已验证环境

- ChromeOS R156-16836.32.0 / zork / Ryzen 7 8840U
- 内核 `5.10.252-1009564-ged76cab4c76e`，`uname` 已对齐 stock：
  `(cros-kernel@chromium.org) ... #1 SMP PREEMPT Wed, 21 Oct 2026 19:12:41 -0700`
- `/proc/modules`：`kernelsu 143360 2 - Live ... (O)`
- 管理器：`LKM: true`；SELinux Enforcing；`su`、模块、`ksud post-fs-data` 均正常

## 构建模式的坑

`drivers/kernelsu -> KernelSU/kernel` 符号链接 + KernelSU Kconfig `default y`
会让 `make olddefconfig` 在内核里悄悄打开 `CONFIG_KSU=y`，此时 initramfs 里的
LKM 会被 ksuinit 跳过（`KernelSU may be already loaded in kernel, skip!`），
管理器显示 `LKM: false` / “GKI”。

现在脚本强制显式模式：

```sh
KSU_MODE=lkm      # 默认；构建后校验 vmlinux 无 ksu_* 符号
KSU_MODE=builtin  # 显式 built-in
```

## 新增一个内核版本

CI 不需要 stock vmlinux：按 `uname -r` 里的 commit 检出
`chromeos-5.10-arcvm`，用 `x86_64_arcvm_defconfig` / `arm64_arcvm_defconfig`
生成 config（同 KernelSU v2.1.2 的 `build-kernel-arcvm.yml`），再用
`kernel/arcvm-fragment.config` 补回 defconfig 缺的 console 选项。

实测 5.10.252 的 defconfig 与真机 stock config 差异：11 项 stock-only、
1 项 defconfig-only、6 项取值差异，基本都是工具链/元数据
（`CONFIG_CLANG_VERSION`、`CONFIG_BUILD_SALT`、`CONFIG_EXTRA_FIRMWARE`）。
`CONFIG_EXTRA_FIRMWARE`（stock 的 amdgpu 固件）在 ARCVM 上用不到，未补。

release 按 KMI 滚动，不按精确 `uname -r`：

1. workflow_dispatch 的 `kernel_version` 可空（跟随分支 tip），也可填 commit
   或完整 release 来固定源码；`arch` 选 `both` / 单架构；
2. CI 构建 `latest-<KMI>-<架构>`（滚动）和 `build-<ksu>-<版本>-<架构>`（不可变），
   资产名 `vmlinux-<KMI>-<架构>`；
3. 设备端 `install.sh` 从本机内核取 major.minor，下载 `latest-<KMI>-<架构>`，
   再校验产物的 major.minor 与本机一致。

已验证（2026-11-13）：镜像入口 `https://stevezmt.top/arcvm-kernelsu/install.sh`
取到的脚本与仓库 SHA256 一致；假目标（`5.10.252-1009564-ged76cab4c76e`）
走完整下载路径装 `latest-5.10-x86_64`，md5 通过，QEMU 启动到
`KernelSU: patching do_syscall_64` + `init is /init.real`。

只按 KMI 匹配的理由：

- GKI 的前提就是同一 KMI 内 ABI 冻结，sublevel 升降（`5.10.252` ↔ `5.10.269`）
  不改变导出符号和结构布局；
- 我们替换的是整颗内核，`kernelsu.ko` 由同一棵树、同一份 config 编译并内嵌进
  initramfs，vermagic 与内核天然自洽，不存在“模块对着别的内核编译”的问题；
- stock ARCVM 内核的 `=m` 模块在启动路径上不加载，换内核不会因模块缺失起不来；
- 同一 ACK 5.10 分支 + `*_arcvm_defconfig` 足以覆盖同 KMI 的 ChromeOS 版本。

`build-<ksu>-<版本>-<架构>` 保留精确版本，需要逐字节复刻时用 `--release-tag` 指定。

`kernel/stock-vmlinux.json` 仍保留，用于“要 100% 复刻 stock config”的可选本地
构建路径（`build-arcvm-kernelsu-vmlinux.sh --vmlinux ...`）。

## 已知遗留

- `selinux_hide` 当前为 0（日志：`selinux_hide: set to 0`），
  `context`/`access`/`status` 探测未伪装；`/sys/fs/selinux/policy` 对 shell 都不可读。
- 内核编译器串是 `Ubuntu clang version 22.1.8`（CI 用 apt.llvm.org 的 22；
  stock 是 Chromium OS clang 22.0.0git，无法公开获取）。
- 开机媒体扫描扫到宿主共享目录里的 `.cargo`/`.themes`/`.wine` 小文件时会有一次
  约 10 s 的 `Slow dispatch`，与 KernelSU 无关。
