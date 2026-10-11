#!/usr/bin/env bash
# Builds the Debian 13 "trixie" arm64 disk with Docker preinstalled.
# Runs on a GitHub ubuntu (x86_64) runner using qemu-user-static + chroot.
set -euxo pipefail

OUT="${1:-vm}"
SIZE="${DISK_SIZE:-16G}"
# Official Debian cloud image, "nocloud" flavour: no cloud-init, made for plain QEMU
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-arm64.qcow2"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(pwd)/imgwork"; mkdir -p "$WORK"; cd "$WORK"

sudo apt-get update
sudo apt-get install -y qemu-utils qemu-user-static binfmt-support cloud-guest-utils e2fsprogs zstd file python3 wget
ls /proc/sys/fs/binfmt_misc/ | grep -i aarch64

wget -q -O base.qcow2 "$IMG_URL"
qemu-img info base.qcow2
qemu-img convert -O raw base.qcow2 disk.raw
rm base.qcow2
truncate -s "$SIZE" disk.raw

LOOP=$(sudo losetup -fP --show disk.raw)
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"
sudo growpart "$LOOP" 1 || true
sudo losetup -d "$LOOP"; sleep 1
LOOP=$(sudo losetup -fP --show disk.raw); sleep 1
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"
test "$(sudo blkid -o value -s TYPE "${LOOP}p1")" = "ext4"
sudo e2fsck -fy "${LOOP}p1" || true
sudo resize2fs "${LOOP}p1"

R=/mnt/deb
sudo mkdir -p $R
sudo mount "${LOOP}p1" $R
for d in dev dev/pts proc sys; do sudo mount --bind /$d $R/$d; done

# Temporary DNS + no service starts inside the chroot
if [ -e $R/etc/resolv.conf ] || [ -L $R/etc/resolv.conf ]; then sudo mv $R/etc/resolv.conf $R/etc/resolv.conf.orig; fi
echo "nameserver 1.1.1.1" | sudo tee $R/etc/resolv.conf
printf '#!/bin/sh\nexit 101\n' | sudo tee $R/usr/sbin/policy-rc.d; sudo chmod +x $R/usr/sbin/policy-rc.d

sudo tee $R/tmp/setup.sh > /dev/null <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends docker.io docker-compose containerd runc iptables \
  ca-certificates curl nano htop less iproute2 iputils-ping procps
# networkd is a separate package on newer Debian; ignore if it's already part of systemd
apt-get install -y --no-install-recommends systemd-networkd || true
apt-get clean
rm -rf /var/lib/apt/lists/*

# Login: root / debian, auto-login on the serial console
echo 'root:debian' | chpasswd
mkdir -p /etc/systemd/system/serial-getty@ttyAMA0.service.d
cat > /etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf <<'X'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
X

echo debian-pocket > /etc/hostname
grep -q debian-pocket /etc/hosts || echo '127.0.1.1 debian-pocket' >> /etc/hosts

# Network: QEMU user networking always uses 10.0.2.0/24, so a static setup boots
# instantly (no DHCP wait). Interface is eth0 thanks to net.ifnames=0 on the kernel line.
mkdir -p /etc/cloud && touch /etc/cloud/cloud-init.disabled
rm -f /etc/netplan/*.yaml 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-qemu.network <<'X'
[Match]
Name=eth0 en*

[Network]
Address=10.0.2.15/24
Gateway=10.0.2.2
DNS=10.0.2.3
X
if [ -x /usr/lib/systemd/systemd-networkd ] || [ -x /lib/systemd/systemd-networkd ]; then
  systemctl enable systemd-networkd.service
  systemctl mask networking.service ifup@eth0.service || true
else
  apt-get update && apt-get install -y --no-install-recommends ifupdown && apt-get clean
  cat > /etc/network/interfaces <<'X'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet static
  address 10.0.2.15/24
  gateway 10.0.2.2
X
fi
rm -f /etc/resolv.conf.orig
printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf.final

# Trim boot time under emulation
systemctl mask systemd-networkd-wait-online.service apt-daily.timer apt-daily-upgrade.timer \
  man-db.timer fstrim.timer e2scrub_all.timer e2scrub_reap.service \
  ssh.service ssh.socket unattended-upgrades.service || true
systemctl enable docker.service containerd.service

# Fit the serial console to the phone screen at every login (type: fixsize)
cat > /etc/profile.d/fixsize.sh <<'X'
fixsize() {
  [ -t 0 ] || return 0
  old=$(stty -g)
  stty raw -echo min 0 time 5
  printf '\033[s\033[999;999H\033[6n\033[u' > /dev/tty
  IFS='[;R' read -r _ rows cols _ < /dev/tty || true
  stty "$old"
  [ -n "$rows" ] && [ -n "$cols" ] && stty rows "$rows" cols "$cols"
}
case "$(tty)" in /dev/ttyAMA0) fixsize ;; esac
export TERM=xterm-256color
X

cat > /etc/motd <<'X'

 Debian Pocket - Debian 13 "trixie" (arm64) with Docker
 Try:  docker run --rm hello-world
 Screen size wrong? type: fixsize

X
CHROOT
sudo chroot $R /bin/bash -eux /tmp/setup.sh < /dev/null
sudo rm -f $R/tmp/setup.sh

# Kernel + initrd straight from the image so modules match
KVER=$(ls $R/boot | sed -n 's/^vmlinuz-//p' | sort -V | tail -1)
test -n "$KVER"
echo "Kernel: $KVER"
sudo cp "$R/boot/vmlinuz-$KVER" "$WORK/vmlinuz"
sudo cp "$R/boot/initrd.img-$KVER" "$OUT/initrd"

# Restore networking DNS for the guest and clean up the chroot helpers
sudo rm -f $R/usr/sbin/policy-rc.d $R/etc/resolv.conf
sudo mv $R/etc/resolv.conf.final $R/etc/resolv.conf
sudo fstrim -v $R || true
for d in sys proc dev/pts dev; do sudo umount $R/$d; done
sudo umount $R
sudo losetup -d "$LOOP"

# Decompress kernel to a raw arm64 Image (handles gzip, EFI zboot or already-raw)
sudo chown "$(id -u)" "$WORK/vmlinuz" "$OUT/initrd"
file "$WORK/vmlinuz"
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
print('Image size', len(out))
PY

qemu-img convert -c -O qcow2 disk.raw "$OUT/disk.qcow2"
rm disk.raw
ls -lh "$OUT"
