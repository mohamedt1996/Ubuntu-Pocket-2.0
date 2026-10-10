#!/usr/bin/env bash
# Builds the Ubuntu 24.04 arm64 disk with Docker preinstalled.
# Runs on a GitHub ubuntu (x86_64) runner using qemu-user-static + chroot.
set -euxo pipefail

OUT="${1:-vm}"
SIZE="${DISK_SIZE:-16G}"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
mkdir -p "$OUT"
WORK="$(pwd)/imgwork"; mkdir -p "$WORK"; cd "$WORK"

sudo apt-get update
sudo apt-get install -y qemu-utils qemu-user-static binfmt-support cloud-guest-utils e2fsprogs zstd file python3
ls /proc/sys/fs/binfmt_misc/ | grep -i aarch64

wget -q -O base.img "$IMG_URL"
qemu-img convert -O raw base.img disk.raw
rm base.img
truncate -s "$SIZE" disk.raw

LOOP=$(sudo losetup -fP --show disk.raw)
sudo growpart "$LOOP" 1 || true
sudo losetup -d "$LOOP"; sleep 1
LOOP=$(sudo losetup -fP --show disk.raw); sleep 1
lsblk "$LOOP"
sudo e2fsck -fy "${LOOP}p1" || true
sudo resize2fs "${LOOP}p1"

R=/mnt/ub
sudo mkdir -p $R
sudo mount "${LOOP}p1" $R
# noble keeps the kernel on a separate /boot partition (16)
if [ -b "${LOOP}p16" ]; then sudo mount "${LOOP}p16" $R/boot; fi
for d in dev dev/pts proc sys; do sudo mount --bind /$d $R/$d; done

sudo mv $R/etc/resolv.conf $R/etc/resolv.conf.orig
echo "nameserver 1.1.1.1" | sudo tee $R/etc/resolv.conf
printf '#!/bin/sh\nexit 101\n' | sudo tee $R/usr/sbin/policy-rc.d; sudo chmod +x $R/usr/sbin/policy-rc.d

sudo tee $R/tmp/setup.sh > /dev/null <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get purge -y snapd lxd-installer unattended-upgrades || true
apt-get install -y --no-install-recommends docker.io docker-compose-v2 containerd runc iptables \
  ca-certificates curl nano htop less iproute2 iputils-ping
apt-get autoremove -y; apt-get clean
rm -rf /var/lib/apt/lists/*

# Login: root / ubuntu, auto-login on the serial console
echo 'root:ubuntu' | chpasswd
mkdir -p /etc/systemd/system/serial-getty@ttyAMA0.service.d
cat > /etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf <<'X'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
X

echo ubuntu-pocket > /etc/hostname
echo '127.0.1.1 ubuntu-pocket' >> /etc/hosts

# No cloud metadata on the phone, so turn cloud-init off and configure DHCP ourselves
touch /etc/cloud/cloud-init.disabled
cat > /etc/netplan/01-dhcp.yaml <<'X'
network:
  version: 2
  ethernets:
    all:
      match: {name: "en*"}
      dhcp4: true
X
chmod 600 /etc/netplan/01-dhcp.yaml

# Trim boot time under emulation
systemctl mask systemd-networkd-wait-online.service apt-daily.timer apt-daily-upgrade.timer \
  motd-news.timer man-db.timer fstrim.timer multipathd.service multipathd.socket \
  ModemManager.service ssh.service ssh.socket fwupd.service \
  e2scrub_reap.service plymouth-quit-wait.service || true
systemctl enable docker.service containerd.service || true

# Fit the serial console to the phone screen at every login (type: fixsize)
cat > /etc/profile.d/fixsize.sh <<'X'
fixsize() {
  [ -t 0 ] || return 0
  local old; old=$(stty -g)
  stty raw -echo min 0 time 5
  printf '\033[s\033[999;999H\033[6n\033[u' > /dev/tty
  IFS='[;R' read -r _ rows cols _ < /dev/tty || true
  stty "$old"
  [ -n "$rows" ] && [ -n "$cols" ] && stty rows "$rows" cols "$cols"
}
case "$(tty)" in /dev/ttyAMA0) fixsize ;; esac
export TERM=xterm-256color
X
CHROOT
sudo chroot $R /bin/bash -eux /tmp/setup.sh < /dev/null
sudo rm -f $R/tmp/setup.sh

# Kernel + initrd straight from the image so modules match
KERNEL=$(sudo readlink -f $R/boot/vmlinuz)
INITRD=$(sudo readlink -f $R/boot/initrd.img)
sudo cp "$KERNEL" "$WORK/vmlinuz"; sudo cp "$INITRD" "$OUT/initrd"

sudo rm -f $R/usr/sbin/policy-rc.d $R/etc/resolv.conf
sudo mv $R/etc/resolv.conf.orig $R/etc/resolv.conf
sudo fstrim -v $R || true
for d in sys proc dev/pts dev; do sudo umount $R/$d; done
sudo umount $R/boot 2>/dev/null || true
sudo umount $R
sudo losetup -d "$LOOP"

# Decompress kernel to a raw arm64 Image (handles gzip and EFI zboot)
sudo chown "$(id -u)" "$WORK/vmlinuz" "$OUT/initrd"
python3 - "$WORK/vmlinuz" "$OUT/Image" <<'PY'
import sys, struct, gzip, subprocess
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
if d[:2] == b'\x1f\x8b':
    out = gzip.decompress(d)
elif d[4:8] == b'zimg':
    off, size = struct.unpack_from('<II', d, 8)
    comp = d[24:32].split(b'\0')[0].decode()
    payload = d[off:off+size]
    if comp == 'gzip':
        out = gzip.decompress(payload)
    elif comp == 'zstd':
        out = subprocess.run(['zstd', '-dc'], input=payload, capture_output=True, check=True).stdout
    else:
        sys.exit('unsupported zboot compression: ' + comp)
else:
    out = d
assert out[56:60] == b'ARM\x64', 'not an arm64 Image'
open(dst, 'wb').write(out)
PY

qemu-img convert -c -O qcow2 disk.raw "$OUT/disk.qcow2"
rm disk.raw
ls -lh "$OUT"
