#!/bin/sh
# Idempotent update for fresh images and existing Debian Pocket disks.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run this as root.'; exit 1; }
mkdir -p /etc/apt/apt.conf.d /etc/sysctl.d /usr/local/bin /etc/profile.d
cat > /etc/apt/apt.conf.d/80-pocket-network <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "15";
Acquire::https::Timeout "15";
EOF
# Keep kernel warnings/errors in the journal; hide informational console spam.
printf 'kernel.printk = 3 4 1 3\n' > /etc/sysctl.d/80-pocket-console.conf
# Never alter the build host's kernel from inside its chroot.
if [ "${POCKET_IMAGE_BUILD:-0}" != 1 ]; then dmesg -n 3 || true; fi
# QEMU's host-backed RTC supplies UTC; the iPhone supplies the display timezone.
mkdir -p /etc/systemd/system
cat > /usr/local/bin/pocket-clock <<'EOF'
#!/bin/sh
set -eu
zone=${POCKET_TIMEZONE:-}
if [ -z "$zone" ]; then
 for arg in $(cat /proc/cmdline); do
  case "$arg" in pocket.timezone=*) zone=${arg#pocket.timezone=} ;; esac
 done
fi
case "$zone" in *..*|/*|*[!A-Za-z0-9_+/-]*) zone= ;; esac
if [ -n "$zone" ] && [ -f "/usr/share/zoneinfo/$zone" ]; then
 ln -sf "/usr/share/zoneinfo/$zone" /etc/localtime
 printf '%s\n' "$zone" > /etc/timezone
fi
if [ -n "${POCKET_EPOCH:-}" ]; then
 date -s "@$POCKET_EPOCH" >/dev/null
elif [ -r /sys/class/rtc/rtc0/since_epoch ]; then
 rtc=$(cat /sys/class/rtc/rtc0/since_epoch)
 now=$(date +%s)
 delta=$((rtc - now))
 # Avoid needless clock steps; correct drift after iOS suspension.
 if [ "$delta" -gt 5 ] || [ "$delta" -lt -5 ]; then date -s "@$rtc" >/dev/null; fi
else
 echo 'Host RTC unavailable; clock synchronization failed.' >&2
 exit 1
fi
EOF
chmod 755 /usr/local/bin/pocket-clock
cat > /etc/systemd/system/pocket-clock.service <<'EOF'
[Unit]
Description=Synchronize Debian with the phone RTC and timezone
After=local-fs.target
Before=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/pocket-clock
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/pocket-clock.timer <<'EOF'
[Unit]
Description=Correct guest clock drift after suspension
[Timer]
OnBootSec=60
OnUnitActiveSec=60
[Install]
WantedBy=timers.target
EOF
systemctl enable pocket-clock.service pocket-clock.timer
if [ "${POCKET_IMAGE_BUILD:-0}" != 1 ]; then
 systemctl daemon-reload
 pocket-clock
 systemctl start pocket-clock.timer
fi
cat > /usr/local/bin/pocket-status <<'EOF'
#!/bin/sh
printf '\nDebian Pocket\n'
printf '  Linux       active (%s)\n' "$(uname -r)"
for svc in containerd docker systemd-networkd; do
 state=$(systemctl is-active "$svc" 2>/dev/null || true)
 printf '  %-11s %s\n' "$svc" "${state:-unknown}"
done
addr=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}')
printf '  IPv4        %s\n' "${addr:-not configured}"
route=$(ip -4 route show default 2>/dev/null | head -n 1)
printf '  Route       %s\n' "${route:-missing}"
printf '  Time        %s\n' "$(date '+%F %T %Z')"
printf '  Internet    run pocket-net to test DNS and HTTPS\n\n'
printf 'Commands: apt update | pocket-net | pocket-status\n'
EOF
cat > /usr/local/bin/pocket-net <<'EOF'
#!/bin/sh
set -eu
printf '\nNetwork checks (IPv4)\n'
date -Is
printf '\nInterface and default route:\n'
ip -4 -brief addr show eth0
ip -4 route show default
printf '\nDNS configuration:\n'
cat /etc/resolv.conf
printf '\nDNS lookup: deb.debian.org\n'
if timeout 8 getent ahostsv4 deb.debian.org; then
 printf 'DNS: active\n'
else
 printf 'DNS: FAILED or timed out\n'
 exit 1
fi
printf '\nHTTP: Debian mirror\n'
curl -4 --noproxy '*' -fLsS --connect-timeout 5 --max-time 15 -o /dev/null -w 'HTTP %{http_code}\n' http://deb.debian.org/debian/
printf '\nHTTPS: Debian mirror\n'
if curl -4 --noproxy '*' -fLsS --connect-timeout 5 --max-time 15 \
 -o /dev/null -w 'HTTP %{http_code}\n' https://deb.debian.org/debian/; then
 printf 'Internet HTTPS: active\n'
else
 printf 'Internet HTTPS: FAILED. Save this output; this does not identify the cause alone.\n'
 exit 1
fi
printf '\nAPT uses IPv4 with bounded connection timeouts. Run apt update.\n'
EOF
chmod 755 /usr/local/bin/pocket-status /usr/local/bin/pocket-net
cat > /etc/profile.d/pocket-status.sh <<'EOF'
case $- in
 *i*) case "$(tty 2>/dev/null)" in /dev/ttyAMA0) pocket-status ;; esac ;;
esac
EOF
if [ "${POCKET_IMAGE_BUILD:-0}" != 1 ]; then
 printf '\nGuest tools installed. No disk data was erased.\n'
 pocket-status
fi
