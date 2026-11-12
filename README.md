# arcvm-kernelsu

为 ChromeOS **ARCVM** 提供持久化的 [KernelSU](https://github.com/tiann/KernelSU)（LKM 模式）。

只替换 `/opt/google/vms/android/vmlinux`，不改 `system.raw.img`、`vendor.raw.img`，
不碰 rootfs 验证；保留 `vmlinux.original`，可随时恢复。

## 特性

- **LKM 模式**：KernelSU 以模块形式加载，内核本体保持 stock ARCVM 配置；
- **版本匹配**：每个产物绑定 `(内核 release, 架构)`，不会刷错版本；
- **一条命令**：设备端只需在 crosh 里执行一次，不需要 SSH；
- **可选自动跟随**：Brunch bootscript 在 ChromeOS 更新后自动重装；
- **x86_64 / arm64** 同一套脚本。

## 要求

- ChromeOS（或 Brunch）已开启开发者模式，能拿到 root；
- 设备使用 ARCVM（`/opt/google/vms/android/vmlinux` 存在）；
- KernelSU 管理器 APK：<https://github.com/tiann/KernelSU/releases>

## 安装

一条命令（设备端，root）：

```sh
curl -fsSL https://raw.githubusercontent.com/SteveZMTstudios/arcvm-kernelsu/main/get.sh | sudo bash -s -- -y
```

脚本会读取本机内核版本，下载完全匹配的 `vmlinux`，校验 md5 后替换。
首次安装会保留 `vmlinux.original`。

ChromeOS 更新后自动跟随（写入 Brunch stateful bootscripts，版本一致时不做任何事）：

```sh
curl -fsSL https://raw.githubusercontent.com/SteveZMTstudios/arcvm-kernelsu/main/get.sh | sudo bash -s -- -y --persistent
```

恢复原厂内核：

```sh
curl -fsSL https://raw.githubusercontent.com/SteveZMTstudios/arcvm-kernelsu/main/get.sh | sudo bash -s -- --restore
```

不带参数直接运行会交互式确认：

```sh
curl -fsSL https://raw.githubusercontent.com/SteveZMTstudios/arcvm-kernelsu/main/get.sh | sudo bash
```

## 工作原理

1. 从 stock vmlinux 读取内核版本、源码 commit 和 config；
2. 用该版本的内核源码编译 KernelSU LKM 与 `ksuinit`；
3. 生成内嵌 initramfs 的 `bzImage`：
   - `/init` = ksuinit，加载 `/kernelsu.ko`
   - `/init.real` = switchroot，挂载 Android root 后执行真正的 `/init`
4. 每次开机都会重新加载，因此升级/更新都不会丢失。

`vmlinux` 与设备的 ARCVM 内核 release 强绑定，不存在跨版本通用包。

## 支持矩阵

| 架构 | 内核 | 状态 |
|---|---|---|
| x86_64 | 5.10.252-1009564-ged76cab4c76e | 已实机验证 |
| arm64 | 5.10.x ARCVM | 脚本支持，未实机验证 |

## 构建

CI（GitHub Actions）按 `kernel_version` + 架构矩阵构建，见
`.github/workflows/build.yml`。本地构建：

```sh
./scripts/build-arcvm-kernelsu-vmlinux.sh \
  --kernel-version 5.10.252-1009564-ged76cab4c76e \
  --config kernel.config \
  --kernel-src /path/to/kernel-src \
  --out dist
```

也可以直接用 stock vmlinux 作为输入（config 从其 `IKCFG_ST` 提取）：

```sh
./scripts/build-arcvm-kernelsu-vmlinux.sh \
  --vmlinux /path/to/vmlinux.original \
  --out dist
```

依赖：clang/lld/llvm、make、gcc、flex、bison、bc、python3、rustup、curl、tar、gzip；
arm64 交叉编译需要 `aarch64-linux-gnu-gcc`。

## 目录

```
get.sh                              # 一行安装入口（下载脚本并执行）
scripts/
  build-arcvm-kernelsu-vmlinux.sh   # 构建 vmlinux
  build-arcvm-kernelsu-ko.sh        # 构建 KernelSU LKM + ksuinit
  patch_android.sh                  # ARCVM 平台适配
  install-arcvm-kernelsu.sh         # 设备端安装/恢复
  install-arcvm-kernelsu-brunch.sh  # 持久化安装（Brunch bootscripts）
  fetch-arcvm-kernelsu.sh           # 按内核版本抓取并安装
  stock_meta.py                     # CI 读取 stock-vmlinux.json
host/
  power_tune.sh                     # balanced/eco/performance 切换
  bootscripts/10-power-tune.sh      # 开机锁定 boost=0 / EPP
  bootscripts/20-ksu-vmlinux.sh     # 可选：开机自动跟随 KSU 版本
kernel/
  arcvm-fragment.config             # CI source-only 构建补充的 config
  stock-vmlinux.json                # 可选：按内核版本索引 stock vmlinux
.github/workflows/build.yml         # CI 构建与发版
NOTES.md                            # 实测数据与排查记录
```

## 恢复与安全

- 安装脚本只写 `vmlinux`，目标目录不可写时直接退出；
- 首次安装保留 `vmlinux.original`；
- `--restore` 整文件恢复；
- `system.raw.img` / `vendor.raw.img` / rootfs 验证均不修改。

## License

内核源码与 KernelSU 遵循其原始许可证（GPL-3.0 等）。本仓库脚本按 (GPL-3.0)[LICENSE] 发布。
