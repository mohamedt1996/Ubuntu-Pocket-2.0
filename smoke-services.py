#!/usr/bin/env python3
"""Real ARM64 guest TCP+UDP forwarding and QMP graceful shutdown gate.
Separate snapshot boot; never modifies the deliverable disk.
"""
import base64
import json
import pathlib
import re
import select
import socket
import subprocess
import sys
import tempfile
import time

vm = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'vm').resolve()

def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

tcp, udp = free_port(socket.SOCK_STREAM), free_port(socket.SOCK_DGRAM)
parent, guest = socket.socketpair()
control, qemu_control = socket.socketpair()
args = ['qemu-system-aarch64', '-nodefaults', '-no-user-config',
        '-machine', 'virt', '-cpu', 'cortex-a72', '-smp', '1', '-m', '1024',
        '-accel', 'tcg,thread=single,tb-size=256', '-rtc', 'base=utc,clock=host',
        '-kernel', str(vm/'Image'), '-initrd', str(vm/'initrd'),
        '-append', 'root=/dev/vda1 rw rootwait net.ifnames=0 console=ttyAMA0,115200 systemd.firstboot=off pocket.timezone=Etc/UTC',
        '-drive', f'if=none,id=hd0,file={vm/"disk.qcow2"},format=qcow2',
        '-snapshot', '-device', 'virtio-blk-pci,drive=hd0',
        '-netdev', f'user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:{tcp}-:18880,hostfwd=udp:127.0.0.1:{udp}-:18881',
        '-device', 'virtio-net-pci,netdev=net0,romfile=', '-device', 'virtio-rng-pci',
        '-display', 'none', '-monitor', 'none', '-no-shutdown',
        '-chardev', f'socket,id=con0,fd={guest.fileno()},server=off', '-serial', 'chardev:con0',
        '-chardev', f'socket,id=control,fd={qemu_control.fileno()},server=off', '-mon', 'chardev=control,mode=control']
server = '''import socket,threading

def tcp():
 s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',18880));s.listen()
 while True:
  c,a=s.accept()
  with c:
   while True:
    data=c.recv(128)
    if not data:break
    c.sendall(data)
def udp():
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('0.0.0.0',18881))
 while True:
  d,a=s.recvfrom(128);s.sendto(d,a)
threading.Thread(target=tcp,daemon=True).start()
udp()
'''
with open(vm/'smoke-services.log', 'wb') as log, open(vm/'smoke-control.log','wb') as qlog:
    proc = subprocess.Popen(args, pass_fds=(guest.fileno(),qemu_control.fileno()),stdout=qlog,stderr=qlog)
    guest.close();qemu_control.close()
    tail=b''; clean=b''; qbuf=b''; caps=False; sent=False; tested=False; shutdown=False
    deadline=time.monotonic()+300;next_report=time.monotonic()+15
    def command(name):
        control.sendall((json.dumps({'execute':name,'id':name})+'\n').encode())
    try:
        while time.monotonic()<deadline:
            if time.monotonic()>=next_report:
                print('Service test: waiting for '+('guest shutdown' if tested else 'shell and TCP/UDP services'),flush=True)
                next_report=time.monotonic()+15
            for ready in select.select([parent,control],[],[],1)[0]:
                data=ready.recv(65536)
                if not data:raise RuntimeError('QEMU socket closed unexpectedly')
                if ready is control:
                    qlog.write(data);qlog.flush();qbuf+=data
                    while b'\n' in qbuf:
                        line,qbuf=qbuf.split(b'\n',1)
                        obj=json.loads(line)
                        if 'QMP' in obj:command('qmp_capabilities')
                        if obj.get('id')=='qmp_capabilities' and 'return' in obj:caps=True
                        if 'error' in obj:raise RuntimeError(str(obj['error']))
                        if obj.get('event')=='SHUTDOWN':
                            assert obj['data'].get('guest') is True and obj['data'].get('reason')=='guest-shutdown',obj
                            shutdown=True
                else:
                    log.write(data);log.flush();tail=(tail+data)[-65536:]
                    clean=re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]',b'',tail)
            if caps and not sent and re.search(rb'root@debian-pocket:[^\r\n]*#',clean):
                encoded=base64.b64encode(server.encode()).decode()
                parent.sendall((f"printf '%s' '{encoded}' | base64 -d >/tmp/pocket-echo.py; python3 /tmp/pocket-echo.py >/tmp/pocket-echo.log 2>&1 &\n").encode())
                sent=True
            if sent and not tested:
                token=b'pocket-forwarding-test'
                try:
                    with socket.create_connection(('127.0.0.1',tcp),timeout=2) as s:
                        s.sendall(token)
                        received=b''
                        while len(received)<len(token):
                            data=s.recv(128)
                            if not data:break
                            received+=data
                        assert received==token
                    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
                        s.settimeout(2);s.sendto(token,('127.0.0.1',udp))
                        received=b''
                        while len(received)<len(token):
                            data=s.recv(128)
                            if not data:break
                            received+=data
                        assert received==token
                except (OSError,AssertionError):
                    continue
                tested=True
                print('PASS: host loopback → Debian TCP and UDP forwarding',flush=True)
                command('system_powerdown');deadline=time.monotonic()+90
            if shutdown:
                assert tested
                command('quit')
                assert proc.wait(timeout=20)==0
                print('PASS: QMP power button → guest shutdown event → QEMU clean exit',flush=True)
                break
            if proc.poll() is not None:raise RuntimeError('QEMU exited before verification')
        else:raise RuntimeError('TCP/UDP or safe shutdown timed out; inspect smoke-services.log and smoke-control.log')
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:proc.wait(timeout=10)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        parent.close();control.close()
