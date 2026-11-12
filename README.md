# arcvm-kernelsu

在 ChromeOS **ARCVM** 上以 **LKM 模式**运行 [KernelSU](https://github.com/tiann/KernelSU)：
只替换 `/opt/google/vms/android/vmlinux`，不改 `system.raw.img` / `vendor.raw.img`，
不碰 rootfs 验证。

- 内核本体保持 stock ARCVM 内核（只重新编译，配置不变）；
- KernelSU 以官方 LKM 形式放在内嵌 initramfs 里，由 `ksuinit` 在 switchroot 前加载；
- 系统里看到的 `/proc/version` 与 stock 一致（构建用户名/主机/build 号/时间戳对齐）。

## 已验证（x86_64 / 5.10.252-1009564-ged76cab4c76e）

```
/proc/version  : ... (cros-kernel@chromium.org) ... #1 SMP PREEMPT Wed, 21 Oct 2026 19:12:41 -0700
/proc/modules  : kernelsu 143360 2 - Live ... (O)      # 纯 LKM
管理器          : LKM: true
su -c id       : uid=0(root) ... context=u:r:ksu:s0
tp_marker 刷屏  : 0 行
Slow dispatch  : 无 5–7 秒级停顿（仅开机媒体扫描有一次 10s）
```

启动链（`/data/adb/ksu/log/dmesg.log`）：

```
ksuinit[1]: Loading kernelsu.ko..
KernelSU: welcome to KernelSU version 32680
KernelSU: patching do_syscall_64
ksuinit[1]: init is /init.real
KernelSU: /system/bin/init second_stage executed
init: starting service 'exec 11 (/data/adb/ksud post-fs-data)'
KernelSU: escape to root for init executing ksud: 339
KernelSU: post-fs-data triggered
KernelSU: load_allow_uid, name: com.android.shell, uid: 2000, allow: 1
KernelSU: exec zygote, /data prepared, second_stage: 1
```

## 为什么需要补丁

`patch_android.sh` 只做三件事，其余全部是 KernelSU 官方逻辑：

1. **ksuinit 持久化**：官方 ksuinit 假设每次都有新 ramdisk（unlink `/init` 并
   symlink 到 `/init.real`）。ARCVM 的 `/init` 在持久 EROFS root 上，第二次启动
   就不会再执行。改成加载模块后直接 `exec /init.real`。
2. **x86_64 syscall dispatcher**：ARCVM 5.10.252 的
   `do_syscall_64(unsigned long nr, struct pt_regs *regs)` 参数顺序与上游
   KernelSU `<5.16` 分支假设的 `(regs, nr)` 相反。启用
   `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER` 时会让
   `syscall_enter_from_user_mode()` 拿到交换过的参数并 panic。修正这一步之后，
   init second_stage / zygote / ksud / sucompat / setresuid 全部原生工作。
3. **tp_marker 日志**：别的 tracepoint 用户注册/注销时，KernelSU 会在
   irqsave 自旋锁内扫描全部线程并逐线程 `pr_info`。ARCVM 的 console 是
   `console=ttyS0`，几千行 printk 会让整个 guest 冻结数秒。逐线程日志降为
   `pr_debug`。

因此 **SELinux 规则是官方原版**（0 条自定义 allow），也没有额外的 kprobe 兜底。

## 构建

需要 stock vmlinux 作为输入：它提供内核版本、源码 commit 和完整 config。

```sh
./scripts/build-arcvm-kernelsu-vmlinux.sh \
  --vmlinux /path/to/vmlinux.original \
  --ksu-tag v3.3.1 \
  --out dist
```

- 架构自动识别，`--arch x86_64|arm64` 可覆盖；
- 默认 `KSU_MODE=lkm`（内核里不含 KernelSU，模块在 initramfs 中）；
  `KSU_MODE=builtin` 会把 KernelSU 编进内核（管理器显示 `LKM: false` / “GKI”）；
- 构建后校验 `nm vmlinux` 不含 `ksu_*` 符号，防止 built-in 泄漏；
- 依赖：clang/lld/llvm、make、gcc、flex、bison、bc、python3、rustup、
  curl、tar、gzip；arm64 交叉编译需要 `aarch64-linux-gnu-gcc`。

## 推荐的安装方式

前提：`vmlinux` 必须和设备的 **ARCVM 内核 release** 完全一致（vermagic、vendor
模块、EROFS root、`init` 路径都绑定在同一个内核上），不存在跨版本通用的
vmlinux。因此方案是「**按内核版本构建**」而不是「一个包通吃」。

**默认推荐：CI 按内核版本构建 + 设备端一条命令（方式 2 为主，方式 1 兜底）。**

- CI 复用了 KernelSU 官方 LKM 构建的做法：x86_64 同样使用
  `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y`（见上游
  `.github/workflows/ddk-lkm.yml`），只是额外修正了 ARCVM 5.10.252 的
  `do_syscall_64` 参数顺序；两个架构矩阵并行构建（`strategy.matrix.arch`）。
- 内核源码按 `uname -r` 里的 commit 拉取 `chromeos-5.10-arcvm` 分支并用
  `*_arcvm_defconfig` 生成 config（同 KernelSU v2.1.2 的
  `build-kernel-arcvm.yml`），不需要上传 stock vmlinux。
- 产物按 `(内核版本, 架构)` 命名，滚动 tag `latest-<版本>-<架构>`，
  不可变 tag `build-<ksu>-<版本>-<架构>`。
- CI 只在出现新 KernelSU release、或 `kernel/stock-vmlinux.json` 新增内核版本时
  才需要跑；固定每周重编没有意义（内核版本不变，产物也不变）。

设备端（ChromeOS dev mode，crosh 里一条命令，不需要 SSH）：

```sh
sudo bash fetch-arcvm-kernelsu.sh --repo OWNER/REPO -y
```

脚本会读本机内核版本 → 只下载完全匹配的产物 → `md5sum -c` → 只替换
`/opt/google/vms/android/vmlinux`。匹配不到就退出并提示，绝不会拿错版本。

如果想连这条命令都省掉，`fetch-arcvm-kernelsu.sh --persistent` 会安装
`20-ksu-vmlinux.sh` 到 Brunch stateful bootscripts：每次开机比对内核版本，
缺失或版本不匹配时自动下载安装（版本一致则不做任何事），ChromeOS 更新后
无需人工介入。

**兜底：本地构建（方式 1）**，用于 CI 还没有的内核版本：

```sh
./scripts/build-arcvm-kernelsu-vmlinux.sh --vmlinux vmlinux.original --out dist
sudo bash scripts/install-arcvm-kernelsu.sh --kernel-file dist/vmlinux-<版本>-x86_64
```

这也是把新内核版本加入 `kernel/stock-vmlinux.json` 的方式：把该版本的 stock
vmlinux 作为 release 资产上传一次即可。

### CI 的 config 从哪来

沿用 KernelSU v2.1.2 的 `build-kernel-arcvm.yml` 做法：ChromeOS 分支
`chromeos-5.10-arcvm` 的源码树里自带 `arch/x86/configs/x86_64_arcvm_defconfig`
和 `arch/arm64/configs/arm64_arcvm_defconfig`，CI 直接用它生成 config，**不需要
用户上传 stock vmlinux**。

实测（5.10.252）这套 defconfig 和真机 stock config 的差异只有 17 项：
11 项 stock-only、1 项 defconfig-only、6 项取值差异，且基本是工具链/元数据
（`CONFIG_CLANG_VERSION`、`CONFIG_BUILD_SALT`、`CONFIG_EXTRA_FIRMWARE` 等）。
功能相关的缺口用 `kernel/arcvm-fragment.config` 补回：

```
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_CORE_CONSOLE=y
CONFIG_SERIAL_EARLYCON=y
```

`CONFIG_EXTRA_FIRMWARE`（stock 里内嵌的 amdgpu 固件）在 ARCVM 上用不到，
不补。CI 构建时仍然用 `--kernel-version` 把 `CONFIG_LOCALVERSION` 固定成设备
的 `uname -r` 后缀，保证 vermagic 完全一致。

## 目录

```
scripts/
  build-arcvm-kernelsu-vmlinux.sh   # 构建内嵌 initramfs 的 vmlinux
  build-arcvm-kernelsu-ko.sh        # 构建 KernelSU LKM + ksuinit
  patch_android.sh                  # 三处平台适配
  install-arcvm-kernelsu.sh         # 设备端安装/恢复（只替换 vmlinux）
  install-arcvm-kernelsu-brunch.sh  # 持久化安装（Brunch stateful bootscripts）
  fetch-arcvm-kernelsu.sh           # 设备端按内核版本抓取匹配的 release
  stock_meta.py                     # CI 读取 stock-vmlinux.json
host/
  power_tune.sh                     # balanced/eco/performance 手动切换
  bootscripts/10-power-tune.sh      # Brunch 开机锁定 boost=0 / EPP
  bootscripts/20-ksu-vmlinux.sh     # 可选：开机重放 KSU vmlinux
kernel/stock-vmlinux.json           # 各内核版本的 stock vmlinux URL / md5
.github/workflows/build.yml         # 手动 / 定时缓存构建
NOTES.md                            # 排查记录与实测数据
```

## 安全/恢复

- 安装脚本只写 `vmlinux`，目标目录不可写时直接退出；
- 首次安装保留 `vmlinux.original`；
- `--restore` 整文件恢复；
- `system.raw.img` / `vendor.raw.img` / rootfs 验证均不修改。

## Host 电源策略（可选）

Brunch bootscript，不写 `/etc/init`、`/etc/udev`（周更会丢）：

```sh
sudo install -m755 host/bootscripts/10-power-tune.sh \
  /mnt/stateful_partition/brunch/bootscripts/10-power-tune.sh
```

Ryzen 7 8840U 8 核满载实测：`boost=1` 约 28 W，`boost=0` 约 12.4 W。

## License

内核源码与 KernelSU 遵循其原始许可证（GPL-2.0 等）。本仓库脚本按 GPL-2.0 发布。
