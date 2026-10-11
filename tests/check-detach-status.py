#!/usr/bin/env python3
"""Exercise the production polling helper using simulated Darwin status replies."""
from pathlib import Path
import subprocess
import tempfile
s=(Path(__file__).resolve().parents[1]/'JIT26.c').read_text()
a=s.index('static int jit26_wait_for_detach(void)')
b=s.index('\n}\n',a)+2
code='''
#include <stddef.h>
#include <errno.h>
#include <assert.h>
#include <stdio.h>
#define CTL_KERN 1
#define KERN_PROC 2
#define KERN_PROC_PID 3
#define P_TRACED 0x800
struct kinfo_proc { struct { int p_flag; } kp_proc; };
static int mode, calls, waits;
static int getpid(void) { return 1; }
static int usleep(unsigned n) { assert(n == 50000); waits++; return 0; }
static int sysctl(int *m, int n, void *out, size_t *size, void *v, int l) {
 (void)m; (void)n; (void)v; (void)l; calls++;
 if (mode==0) { errno=EPERM; return -1; }
 if (mode==1) { *size=0; return 0; }
 ((struct kinfo_proc *)out)->kp_proc.p_flag =
     mode==2 ? 0 : (mode==3 && calls>3 ? 0 : P_TRACED);
 return 0;
}
'''+s[a:b]+'''
int main(void) {
 int expected[] = {-1,-1,0,0,1};
 for (mode=0;mode<5;mode++) {
  calls=waits=0;
  assert(jit26_wait_for_detach()==expected[mode]);
  if(mode==3) assert(calls==4 && waits==3);
  if(mode==4) assert(calls==41 && waits==40);
 }
 puts("PASS: denied, truncated, detached, delayed detach and persistent attachment");
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'check.c').write_text(code)
 subprocess.run(['cc','-Wall','-Wextra','-Werror',str(p/'check.c'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
