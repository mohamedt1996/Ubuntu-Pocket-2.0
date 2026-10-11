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
    '-append', 'root=/dev/vda1 rw rootwait net.ifnames=0 earlycon=pl011,mmio32,0x09000000 console=ttyAMA0,115200 loglevel=7 ignore_loglevel systemd.show_status=1 systemd.firstboot=off',
    '-drive', f'if=none,id=hd0,file={vm / "disk.qcow2"},format=qcow2,cache=writeback,discard=unmap',
    '-snapshot', '-device', 'virtio-blk-pci,drive=hd0',
    '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0,romfile=',
    '-device', 'virtio-rng-pci', '-display', 'none', '-monitor', 'none',
    '-chardev', f'socket,id=con0,fd={guest.fileno()},server=off', '-serial', 'chardev:con0',
]
with open(vm / 'smoke-qemu.log', 'wb') as errors, open(log_path, 'wb') as log:
    proc = subprocess.Popen(args, pass_fds=(guest.fileno(),), stdout=errors, stderr=errors)
    guest.close()
    started = time.monotonic()
    deadline = started + int(os.getenv('SMOKE_TIMEOUT', '600'))
    next_report = started + 15
    print('Boot test started: waiting for Debian shell, then Docker (maximum 600 seconds)', flush=True)
    tail = b''
    sent = False
    passed = False
    try:
        while time.monotonic() < deadline:
            if time.monotonic() >= next_report:
                print(f'\n[boot test: {int(time.monotonic() - started)}s] waiting for ' +
                      ('Docker response' if sent else 'root shell'), flush=True)
                next_report = time.monotonic() + 15
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
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            tail = (tail + data)[-65536:]
            clean = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', tail)
            if b'Please configure your system!' in clean or b'-- Press any key to proceed --' in clean:
                raise RuntimeError('Interactive first-boot wizard blocked startup; check image provisioning and systemd.firstboot=off')
            if not sent and re.search(rb'root@debian-pocket:[^\r\n]*#', clean):
                command = (
                    "if ! command -v docker >/dev/null 2>&1; then "
                    "printf '\\n%s\\n' DEBIAN_POCKET_DOCKER_CLI_MISSING; "
                    "else ok=0; for i in $(seq 1 12); do "
                    "if timeout 10 docker info >/tmp/docker-check.log 2>&1; then ok=1; break; fi; sleep 2; done; "
                    "if [ $ok -eq 1 ]; then printf '\\n%s\\n' DEBIAN_POCKET_DOCKER_READY; "
                    "else cat /tmp/docker-check.log; "
                    "systemctl --no-pager --full status docker.service containerd.service; "
                    "journalctl --no-pager -u docker.service -u containerd.service -n 60; "
                    "printf '\\n%s\\n' DEBIAN_POCKET_DOCKER_FAILED; fi; fi\n"
                )
                parent.sendall(command.encode())
                sent = True
            if re.search(rb'(?:^|[\r\n])DEBIAN_POCKET_DOCKER_CLI_MISSING\r?\n', clean):
                raise RuntimeError('docker command missing: the image must install docker-cli')
            if re.search(rb'(?:^|[\r\n])DEBIAN_POCKET_DOCKER_FAILED\r?\n', clean):
                raise RuntimeError('Docker did not become ready; guest service diagnostics are above')
            if re.search(rb'(?:^|[\r\n])DEBIAN_POCKET_DOCKER_READY\r?\n', clean):
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
