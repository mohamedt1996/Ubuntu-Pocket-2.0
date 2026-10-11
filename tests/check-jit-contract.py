#!/usr/bin/env python3
"""Exercise production hook selection/bounds on POSIX; not an iOS JIT test."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'JIT26.c').read_text()
def function(name):
    # Locate the complete C function without copying its implementation into the test.
    import re
    match = re.search(r'static [^\n]+\b' + name + r'\(', source)
    assert match, name
    start = match.start()
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

code = r'''
#define _GNU_SOURCE
#include <sys/mman.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <stdatomic.h>
#include <assert.h>
static void *g_rx, *g_rw;
static size_t g_size;
static int g_ready;
static _Atomic int g_handed;
''' + '\n'.join(function(n) for n in ['in_region', 'hook_mmap', 'hook_mprotect', 'hook_munmap']) + r'''
int main(void) {
    g_size = 4096;
    g_rw = mmap(NULL, g_size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
    g_rx = mmap(NULL, g_size, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(g_rw != MAP_FAILED && g_rx != MAP_FAILED);
    g_ready = 1;
    // Guest RAM of exactly the cache size must never be captured.
    void *p = hook_mmap(NULL, g_size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(p != g_rw && p != MAP_FAILED && !g_handed);
    munmap(p, g_size);
    // A different code-cache size is not silently handed an undersized region.
    p = hook_mmap(NULL, 2*g_size, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(p != g_rw && p != MAP_FAILED && !g_handed);
    munmap(p, 2*g_size);
    p = hook_mmap(NULL, g_size, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(p == g_rw && g_handed);
    p = hook_mmap(NULL, g_size, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(p != g_rw && p != MAP_FAILED);
    munmap(p, g_size);
    assert(hook_mprotect(g_rx, g_size, PROT_READ|PROT_EXEC) == 0);
    assert(hook_mprotect(g_rw, g_size, PROT_READ|PROT_WRITE) == 0);
    assert(hook_mprotect(g_rx, g_size, PROT_READ|PROT_WRITE) == -1 && errno == EACCES);
    assert(hook_mprotect(g_rw, g_size+1, PROT_READ|PROT_WRITE) == -1 && errno == EINVAL);
    assert(hook_mprotect(g_rw, g_size, PROT_NONE) == 0);
    assert(hook_munmap(g_rx, g_size) == 0);
    munmap(g_rx, g_size);
    munmap(g_rw, g_size);
    puts("PASS: JIT allocation matching, one-time handoff, alias protections and bounds");
}
'''
with tempfile.TemporaryDirectory() as temp:
    src = Path(temp) / 'hooks.c'
    binary = Path(temp) / 'hooks'
    src.write_text(code)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
