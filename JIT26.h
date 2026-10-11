// iOS 26/27 (TXM) JIT support using the StikDebug "universal.js" breakpoint protocol.
#pragma once
#include <stddef.h>
#include <stdint.h>

/// Asks the attached universal.js script for an executable region, makes a writable
/// alias, detaches the script and runs a self-test. Returns 0 on success.
int jit26_prepare(size_t size, char *err, size_t errlen);

/// 1 once jit26_prepare succeeded.
int jit26_is_ready(void);
size_t jit26_size(void);

/// Redirects QEMU's split-W^X code buffer allocation (mmap / mach_vm_remap / mprotect)
/// inside the loaded QEMU image to the prepared region. Returns number of patched imports, or -1 if any required hook is missing.
int jit26_install_qemu_hooks(const char *image_name_contains);

/// 1 once QEMU took the prepared buffer.
int jit26_handed(void);
