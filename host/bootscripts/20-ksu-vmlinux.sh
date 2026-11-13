#!/bin/bash
# Brunch bootscript: re-apply the KernelSU vmlinux after ChromeOS rootfs updates.
# Installed at /mnt/stateful_partition/brunch/bootscripts/20-ksu-vmlinux.sh
# The stateful partition survives ChromeOS rootfs rebuilds.
set -u

KSU_DIR=/mnt/stateful_partition/brunch/ksu
KSU_VMLINUX=$KSU_DIR/vmlinux
META=$KSU_DIR/meta
TARGET=/opt/google/vms/android/vmlinux
STOCK=/opt/google/vms/android/vmlinux.original
LOG=$KSU_DIR/boot.log

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null || true; }

[ -f "$KSU_VMLINUX" ] || { log "no $KSU_VMLINUX"; exit 0; }
[ -f "$META" ] || { log "no $META"; exit 0; }
[ -f "$TARGET" ] || { log "no $TARGET"; exit 0; }

# shellcheck disable=SC1090
. "$META"

read_version() {
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

cur_md5=$(md5sum "$TARGET" | awk '{print $1}')
if [ -n "${ksu_md5:-}" ] && [ "$cur_md5" = "${ksu_md5}" ]; then
    log "KSU vmlinux already installed"
    exit 0
fi

kmi() { printf '%s' "${1%%-*}" | cut -d. -f1,2; }

cur_ver=$(read_version "$TARGET" || true)
# 按 KMI（major.minor）判断是否还能重放；同一 KMI 内的补丁升级不影响。
if [ -n "${ksu_kmi:-}" ]; then
    if [ -z "$cur_ver" ] || [ "$(kmi "$cur_ver")" != "$ksu_kmi" ]; then
        log "ARCVM KMI changed: current=$cur_ver expected=$ksu_kmi; skip (rebuild KSU vmlinux)"
        exit 0
    fi
elif [ -n "${stock_version:-}" ] && [ "$cur_ver" != "${stock_version}" ]; then
    log "ARCVM kernel changed: current=$cur_ver expected=$stock_version; skip (rebuild KSU vmlinux)"
    exit 0
fi

# Preserve the current stock vmlinux if .original is missing or stale.
if [ ! -f "$STOCK" ] || { [ -n "${stock_md5:-}" ] && [ "$(md5sum "$STOCK" | awk '{print $1}')" != "${stock_md5}" ]; }; then
    cp -f "$TARGET" "$STOCK" 2>/dev/null || log "backup stock failed"
fi

tmp="$TARGET.ksu.new"
cp -f "$KSU_VMLINUX" "$tmp" || { log "copy KSU vmlinux failed"; exit 1; }
ctx=$(ls -Zd "$TARGET" 2>/dev/null | awk '{print $1}')
[ -n "$ctx" ] && chcon "$ctx" "$tmp" >/dev/null 2>&1 || true
chown 0:0 "$tmp" 2>/dev/null || true
chmod 0644 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$TARGET"
sync
log "installed KSU vmlinux ($cur_ver)"
