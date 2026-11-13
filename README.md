# arcvm-kernelsu

为 ChromeOS **ARCVM** 提供持久化的 [KernelSU](https://github.com/tiann/KernelSU)（LKM 模式）。

只替换 `/opt/google/vms/android/vmlinux`，不改 `system.raw.img`、`vendor.raw.img`，
不碰 rootfs 验证；保留 `vmlinux.original`，可随时恢复。


## 要求

- ChromeOS（或 Brunch）已开启开发者模式；
- 设备使用 ARCVM（`/opt/google/vms/android/vmlinux` 存在）；
- KernelSU 管理器 APK：<https://github.com/tiann/KernelSU/releases>

## 安装

一条命令（设备端，root）：

```sh
curl -fsSL https://stevezmt.top/arcvm-kernelsu/install.sh | sudo bash -s -- -y
```

GitHub 直连也可以，脚本是同一个：

```sh
curl -fsSL https://raw.githubusercontent.com/SteveZMTstudios/arcvm-kernelsu/main/install.sh | sudo bash -s -- -y
```

安装器只有一个文件，不会再去下载别的脚本。它会读出你机器上的内核 KMI（比如 `5.10`），下载对应的 `vmlinux-5.10-<架构>`，校验 md5 和内嵌版本，然后替换掉。第一次安装时会把原厂内核备份成 `vmlinux.original`。

如果你希望 ChromeOS 更新后也能自己跟上，就多加一个 `--persistent`。它会往 Brunch 的 bootscripts 里塞一个开机脚本，每次开机检查 KMI，对得上就什么都不做，KMI 变了才跳过：

```sh
curl -fsSL https://stevezmt.top/arcvm-kernelsu/install.sh | sudo bash -s -- -y --persistent
```

恢复原厂内核：

```sh
curl -fsSL https://stevezmt.top/arcvm-kernelsu/install.sh | sudo bash -s -- --restore
```

不带参数直接运行会交互式确认：

```sh
curl -fsSL https://stevezmt.top/arcvm-kernelsu/install.sh | sudo bash
```

镜像/自建资产站：用 `REPO`、`ASSET_BASE` 覆盖，多个前缀空格分隔，GitHub 始终兜底。

```sh
curl -fsSL https://stevezmt.top/arcvm-kernelsu/install.sh | \
  sudo ASSET_BASE=https://mirror.example.com/arcvm bash -s -- -y
```

## 特性

- **LKM 模式**：KernelSU 以模块形式加载，内核本体保持 stock ARCVM 配置；
- **KMI 匹配**：产物按 `(KMI, 架构)` 发布，同一 `5.10` 内所有 ChromeOS 版本通用；
- **一条命令**：设备端只需在 crosh 里执行一次，不需要 SSH；
- **可选自动跟随**：Brunch bootscript 在 ChromeOS 更新后自动重放；
- **x86_64 / arm64** 同一套脚本。

## 工作原理

1. 从 stock vmlinux 读取内核版本、源码 commit 和 config；
2. 用该版本的内核源码编译 KernelSU LKM 与 `ksuinit`；
3. 生成内嵌 initramfs 的 `bzImage`：
   - `/init` = ksuinit，加载 `/kernelsu.ko`
   - `/init.real` = switchroot，挂载 Android root 后执行真正的 `/init`
4. 每次开机都会重新加载，因此升级/更新都不会丢失。

`vmlinux` 与 KMI 绑定：`5.10` 的产物适用于所有 `5.10.x` ARCVM，换大版本（如 `6.1`）才需要重新构建。

## 支持情况

| 架构 | 内核 | 状态 |
|---|---|---|
| x86_64 | 5.10.x ARCVM | 真机跑过，没问题 |
| arm64 | 5.10.x ARCVM | CI 构建通过，QEMU 启动通过，未上真机 |

## 自己构建

CI（GitHub Actions）按架构矩阵构建，配置在 `.github/workflows/build.yml`。`kernel_version` 可以不填：留空时跟随 `chromeos-5.10-arcvm` 分支 tip，版本从源码 `Makefile` 读。填 commit（如 `ed76cab4c76e`）或完整 release（如 `5.10.252-1009564-ged76cab4c76e`）则固定源码。

想本地跑的话：

```sh
./scripts/build-arcvm-kernelsu-vmlinux.sh \
  --kernel-version 5.10.252-1009564-ged76cab4c76e \
  --config kernel.config \
  --kernel-src /path/to/kernel-src \
  --out dist
```

如果你手上就有原厂 vmlinux，也可以直接拿它当输入，config 会自动从里面的 `IKCFG_ST` 段提取出来：

```sh
./scripts/build-arcvm-kernelsu-vmlinux.sh \
  --vmlinux /path/to/vmlinux.original \
  --out dist
```

需要的依赖：clang/lld/llvm、make、gcc、flex、bison、bc、python3、rustup、curl、tar、gzip。交叉编译 arm64 的话，还得额外装 `aarch64-linux-gnu-gcc`。

## 目录

```
install.sh                          # 单文件安装器（抓取 + 安装 + 恢复）
scripts/
  build-arcvm-kernelsu-vmlinux.sh   # 构建 vmlinux
  build-arcvm-kernelsu-ko.sh        # 构建 KernelSU LKM + ksuinit
  patch_android.sh                  # ARCVM 平台适配
  stock_meta.py                     # CI 用来读 stock-vmlinux.json
host/
  bootscripts/20-ksu-vmlinux.sh     # 可选：开机自动跟随 KSU 版本
kernel/
  arcvm-fragment.config             # CI 做 source-only 构建时补上的 config
  stock-vmlinux.json                # 可选：按内核版本索引 stock vmlinux
.github/workflows/build.yml         # CI 构建与发版
NOTES.md                            # 实测数据与踩坑记录
```

## 恢复与安全

- 安装脚本只写 `vmlinux`，目标目录不可写时直接退出；
- 首次安装保留 `vmlinux.original`；
- `--restore` 整文件恢复；
- `system.raw.img` / `vendor.raw.img` / rootfs 验证均不修改。

## License

内核源码和 KernelSU 本身遵循它们自己的许可证（GPL-3.0 等）。本仓库里的脚本按 [GPL-3.0](LICENSE) 发布。
