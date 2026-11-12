#!/bin/bash
# Brunch bootscript: lock host CPU power policy.
# Installed at /mnt/stateful_partition/brunch/bootscripts/10-power-tune.sh
# Survives ChromeOS rootfs updates (stateful partition is preserved).
set -u

for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [ -e "$f" ] && echo balance_performance > "$f" 2>/dev/null || true
done
[ -e /sys/devices/system/cpu/cpufreq/boost ] && \
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

# Recreate the udev rule on the (possibly updated) rootfs, so AC/battery
# transitions re-apply the policy even if powerd resets EPP.
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-power-tune.rules <<'EOF'
ACTION=="change", SUBSYSTEM=="power_supply", RUN+="/bin/sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost; for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo balance_performance > $f 2>/dev/null || true; done'"
EOF
udevadm control --reload-rules 2>/dev/null || true
