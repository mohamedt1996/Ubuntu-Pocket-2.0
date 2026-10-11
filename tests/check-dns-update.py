#!/usr/bin/env python3
"""Run the real DNS migration fragment against a disposable /etc tree."""
from pathlib import Path
import subprocess
import tempfile
source=(Path(__file__).resolve().parents[1]/'guest-update.sh').read_text()
fragment=source.split('# Public DNS',1)[1].split('# Keep kernel warnings',1)[0]
fragment='# Public DNS'+fragment
with tempfile.TemporaryDirectory() as temp:
 root=Path(temp);etc=root/'etc';etc.mkdir()
 original=etc/'resolver-original';original.write_text('nameserver 10.0.2.3\n')
 resolver=etc/'resolv.conf';resolver.symlink_to(original)
 script='set -eu\n'+fragment.replace('/etc/',str(etc)+'/')
 for _ in range(2):subprocess.run(['sh'],input=script,text=True,check=True)
 assert not resolver.is_symlink()
 assert resolver.read_text()=='nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n'
 assert original.read_text()=='nameserver 10.0.2.3\n'
 assert (etc/'resolv.conf.before-pocket').read_text()==original.read_text()
 assert 'UseDNS=no' in (etc/'systemd/network/10-qemu.network.d/80-pocket-dns.conf').read_text()
 print('PASS: permanent DNS, safe symlink replacement, original backup and repeated migration')
