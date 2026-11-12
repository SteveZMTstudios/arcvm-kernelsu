#!/bin/bash
#
# get.sh — 一行安装入口
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/get.sh | sudo bash -s -- -y
#
# 做的事：把 fetch/install 脚本下载到临时目录，然后原样把参数交给
# fetch-arcvm-kernelsu.sh。不会在系统里留下脚本文件。
#
# 环境变量：
#   REPO     GitHub 仓库（默认 OWNER/REPO）
#   BRANCH   分支（默认 main）
#   RAW_BASE 覆盖 raw 地址前缀（镜像/自建）

set -eu

RED=$'\e[1;31m'
BLUE=$'\e[1;34m'
RESET=$'\e[0m'

REPO=${REPO:-OWNER/REPO}
BRANCH=${BRANCH:-main}
RAW_BASE=${RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}

info() { printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行：curl ... | sudo bash -s -- -y"

command -v curl >/dev/null 2>&1 || die "缺少 curl。"

TMP=$(mktemp -d /tmp/arcvm-ksu.XXXXXX) || die "无法创建临时目录。"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

FILES="
scripts/fetch-arcvm-kernelsu.sh
scripts/install-arcvm-kernelsu.sh
scripts/install-arcvm-kernelsu-brunch.sh
"

info "下载脚本：$REPO@$BRANCH"
for f in $FILES; do
    mkdir -p "$TMP/$(dirname "$f")"
    curl -fsSL --retry 3 --connect-timeout 20 -o "$TMP/$f" "$RAW_BASE/$f" || \
        die "下载失败: $RAW_BASE/$f"
done
chmod 755 "$TMP"/scripts/*.sh

info "运行安装脚本"
set +e
bash "$TMP/scripts/fetch-arcvm-kernelsu.sh" "$@"
rc=$?
set -e

exit "$rc"
