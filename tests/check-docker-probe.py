#!/usr/bin/env python3
"""Test the actual guest shell probe with missing, healthy and failed Docker."""
import ast
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
tree = ast.parse((root / 'smoke-boot.py').read_text())
command = next(ast.literal_eval(n.value) for n in ast.walk(tree)
               if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'command' for t in n.targets))
subprocess.run(['/bin/bash', '-n'], input=command, text=True, check=True)
with tempfile.TemporaryDirectory() as td:
    p = Path(td)
    def executable(name, body):
        f = p / name
        f.write_text('#!/bin/sh\n' + body + '\n')
        f.chmod(0o755)
    # All tools are simulated. No Docker daemon or host service is touched.
    for name, body in {
        'seq': 'echo 1', 'sleep': ':', 'timeout': 'shift; exec "$@"',
        'cat': 'echo captured-docker-error', 'systemctl': 'echo service-diagnostics',
        'journalctl': 'echo journal-diagnostics'
    }.items(): executable(name, body)
    for mode, marker in [('missing','CLI_MISSING'),('healthy','READY'),('failed','FAILED')]:
        if mode != 'missing': executable('docker', 'exit ' + ('0' if mode == 'healthy' else '1'))
        # Avoid fixed guest /tmp path when running locally.
        probe = command.replace('/tmp/docker-check.log', str(p / 'docker-check.log'))
        r = subprocess.run(['/bin/bash'], input=probe, text=True, capture_output=True,
                           env=dict(os.environ, PATH=td), timeout=5)
        assert 'DEBIAN_POCKET_DOCKER_' + marker in r.stdout.splitlines(), (mode, r.stdout, r.stderr)
        if mode == 'failed': assert 'service-diagnostics' in r.stdout and 'journal-diagnostics' in r.stdout
        print('PASS: guest Docker probe ' + mode)
