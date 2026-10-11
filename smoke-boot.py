#!/usr/bin/env python3
"""CI gate: boot the built ARM64 image and verify its Docker daemon over serial.
Uses the same socket-pair console and machine/devices as the iOS launcher.
This does NOT test iOS executable-memory permissions or the UTM framework.
"""
import os
import pathlib
import re
import select
import socket
import subprocess
import sys
import time

vm = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'vm').resolve()
log_path = vm / 'smoke-serial.log'
parent, guest = socket.socketpair()
args = [
    'qemu-system-aarch64', '-nodefaults', '-no-user-config',
    '-machine', 'virt', '-cpu', 'cortex-a72', '-smp', '1', '-m', '1024',
    '-accel', 'tcg,thread=single,tb-size=256',
    '-kernel', str(vm / 'Image'), '-initrd', str(vm / 'initrd'),
    '-append', 'root=/dev/vda1 rw rootwait net.ifnames=0 earlycon=pl011,mmio32,0x09000000 console=ttyAMA0,115200 loglevel=7 ignore_loglevel systemd.show_status=1',
    '-drive', f'if=none,id=hd0,file={vm / "disk.qcow2"},format=qcow2,cache=writeback,discard=unmap',
    '-snapshot', '-device', 'virtio-blk-pci,drive=hd0',
    '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0,romfile=',
    '-device', 'virtio-rng-pci', '-display', 'none', '-monitor', 'none',
    '-chardev', f'socket,id=con0,fd={guest.fileno()},server=off', '-serial', 'chardev:con0',
]
with open(vm / 'smoke-qemu.log', 'wb') as errors, open(log_path, 'wb') as log:
    proc = subprocess.Popen(args, pass_fds=(guest.fileno(),), stdout=errors, stderr=errors)
    guest.close()
    deadline = time.monotonic() + int(os.getenv('SMOKE_TIMEOUT', '600'))
    tail = b''
    sent = False
    passed = False
    try:
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f'QEMU exited early ({proc.returncode}); inspect smoke-qemu.log')
            readable, _, _ = select.select([parent], [], [], 1)
            if not readable:
                continue
            data = parent.recv(65536)
            if not data:
                raise RuntimeError('Serial socket closed before boot verification')
            log.write(data)
            log.flush()
            tail = (tail + data)[-65536:]
            if not sent and re.search(rb'root@debian-pocket:[^\r\n]*#', tail):
                parent.sendall(b"for i in $(seq 1 60); do if docker info >/dev/null 2>&1; then printf '\\n%s\\n' DEBIAN_POCKET_DOCKER_READY; break; fi; sleep 1; done\n")
                sent = True
            if re.search(rb'(?:^|[\r\n])DEBIAN_POCKET_DOCKER_READY\r?\n', tail):
                passed = True
                print('PASS: ARM64 kernel, root filesystem, serial login, and Docker daemon')
                break
        if not passed:
            raise RuntimeError(f'Boot/Docker timed out; inspect {log_path}')
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        parent.close()
