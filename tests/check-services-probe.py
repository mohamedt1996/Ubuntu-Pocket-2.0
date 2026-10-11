#!/usr/bin/env python3
"""Validate the service gate orchestration; this is not a real guest boot."""
import os
from pathlib import Path
import subprocess
import tempfile
script=Path(__file__).resolve().parents[1]/'smoke-services.py'
with tempfile.TemporaryDirectory() as td:
 p=Path(td)
 fake=p/'qemu-system-aarch64'
 fake.write_text(r'''#!/usr/bin/env python3
import json,os,re,socket,sys,threading
args=sys.argv
chars=[args[i+1] for i,a in enumerate(args) if a=='-chardev']
serial=socket.socket(fileno=int(re.search(r'fd=(\d+)',chars[0]).group(1)))
qmp=socket.socket(fileno=int(re.search(r'fd=(\d+)',chars[1]).group(1)))
net=args[args.index('-netdev')+1]
tcp=int(re.search(r'hostfwd=tcp:127.0.0.1:(\d+)',net).group(1))
udp=int(re.search(r'hostfwd=udp:127.0.0.1:(\d+)',net).group(1))
def echo_tcp():
 s=socket.socket();s.bind(('127.0.0.1',tcp));s.listen()
 while True:
  c,_=s.accept()
  with c:c.sendall(c.recv(128))
def echo_udp():
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',udp))
 while True:
  d,a=s.recvfrom(128);s.sendto(d,a)
def guest():
 command=b''
 while not command.endswith(b'\n'):command+=serial.recv(4096)
 assert b'python3 /tmp/pocket-echo.py' in command
 threading.Thread(target=echo_tcp,daemon=True).start()
 threading.Thread(target=echo_udp,daemon=True).start()
threading.Thread(target=guest,daemon=True).start()
serial.sendall(b'root@debian-pocket:~# ')
qmp.sendall(b'{"QMP":{}}\r\n')
for line in qmp.makefile('rb'):
 obj=json.loads(line);cmd=obj['execute']
 qmp.sendall((json.dumps({'return':{},'id':cmd})+'\r\n').encode())
 if cmd=='system_powerdown':
  qmp.sendall((json.dumps({'event':'SHUTDOWN','data':{'guest':os.getenv('GUEST_SHUTDOWN')=='1','reason':'guest-shutdown'}})+'\r\n').encode())
 if cmd=='quit':break
''');fake.chmod(0o755)
 for mode in ['1','0']:
  r=subprocess.run(['python3',str(script),td],capture_output=True,timeout=15,
      env=dict(os.environ,PATH=td+':'+os.environ['PATH'],GUEST_SHUTDOWN=mode))
  if mode=='1':assert r.returncode==0 and b'QEMU clean exit' in r.stdout,(r.stdout,r.stderr)
  else:assert r.returncode!=0,(r.stdout,r.stderr)
  print('PASS: service probe '+('accepts confirmed guest shutdown' if mode=='1' else 'rejects unconfirmed shutdown'))
