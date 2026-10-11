#!/usr/bin/env python3
"""Exercise the console probe with simulated QEMU, including network failure."""
import os
from pathlib import Path
import subprocess
import tempfile
script=Path(__file__).resolve().parents[1]/'smoke-boot.py'
with tempfile.TemporaryDirectory() as td:
 p=Path(td);fake=p/'qemu-system-aarch64'
 fake.write_text('''#!/usr/bin/env python3
import os,re,socket,sys,time
arg=sys.argv[sys.argv.index('-chardev')+1]
s=socket.socket(fileno=int(re.search(r'fd=(\\d+)',arg).group(1)))
s.sendall(b'root@debian-pocket:~# ')
command=s.recv(4096)
assert b'docker info' in command
s.sendall(command) # Echo must not satisfy a standalone result marker.
s.sendall(b'\\r\\nDEBIAN_POCKET_DOCKER_READY\\r\\n')
network=s.recv(4096)
assert b'pocket-net' in network
s.sendall(network)
s.sendall(b'\\r\\nDEBIAN_POCKET_NETWORK_' + ( 'FAILED' if os.environ['NETWORK_RESULT']=='FAILED' else 'READY').encode() + b'\\r\\n')
if os.environ['NETWORK_RESULT'] != 'FAILED':
 apt=s.recv(4096)
 assert b'APT::Update::Error-Mode=any' in apt and b'date +%s' in apt
 s.sendall(apt)
 marker={'READY':'APT_READY','APT_FAILED':'APT_FAILED','CLOCK_FAILED':'CLOCK_FAILED'}[os.environ['NETWORK_RESULT']]
 s.sendall(b'\\r\\nDEBIAN_POCKET_' + marker.encode() + b'\\r\\n')
time.sleep(10)
''');fake.chmod(0o755)
 for mode in ['READY','FAILED','APT_FAILED','CLOCK_FAILED']:
  r=subprocess.run(['python3',str(script),td],capture_output=True,timeout=8,
    env=dict(os.environ,PATH=td+':'+os.environ['PATH'],NETWORK_RESULT=mode,SMOKE_TIMEOUT='5'))
  if mode=='READY': assert r.returncode==0 and b'guest mirror HTTPS' in r.stdout,r.stderr
  elif mode=='FAILED': assert r.returncode!=0 and b'Guest network check failed' in r.stderr,r.stderr
  else: assert r.returncode!=0 and b'Guest APT/clock verification failed' in r.stderr,r.stderr
  print('PASS: console network '+mode)
