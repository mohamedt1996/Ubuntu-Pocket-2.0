#include "JIT26.h"
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>
#include <string.h>
#include <stdio.h>
#include <libkern/OSCacheControl.h>

// ---- StikDebug universal protocol -------------------------------------------------

__attribute__((noinline, naked)) static void JIT26Detach(void) {
    __asm__("mov x16, #0\n"
            "brk #0xf00d\n"
            "ret\n");
}

__attribute__((noinline, naked)) static void *JIT26PrepareRegion(void *address, size_t length) {
    __asm__("mov x16, #1\n"
            "brk #0xf00d\n"
            "ret\n");
}

static void *g_rx = NULL;   // executable view (prepared by the debugger)
static void *g_rw = NULL;   // writable alias
static size_t g_size = 0;
static int g_ready = 0;
static int g_handed = 0;

int jit26_is_ready(void) { return g_ready; }
size_t jit26_size(void) { return g_size; }

int jit26_prepare(size_t size, char *err, size_t errlen) {
    if (g_ready) return 0;
    void *rx = JIT26PrepareRegion(NULL, size);
    if (rx == NULL) { snprintf(err, errlen, "debugger returned no region"); JIT26Detach(); return -1; }

    vm_address_t rw = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) { snprintf(err, errlen, "vm_remap failed: %d", kr); JIT26Detach(); return -2; }
    kr = vm_protect(mach_task_self(), rw, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) { snprintf(err, errlen, "vm_protect RW failed: %d", kr); JIT26Detach(); return -3; }

    JIT26Detach();

    // Self-test: mov w0, #42 ; ret
    static const uint32_t code[] = { 0x52800540, 0xD65F03C0 };
    memcpy((void *)rw, code, sizeof(code));
    sys_icache_invalidate(rx, sizeof(code));
    int (*fn)(void) = (int (*)(void))rx;
    int r = fn();
    memset((void *)rw, 0, sizeof(code));
    sys_icache_invalidate(rx, sizeof(code));
    if (r != 42) { snprintf(err, errlen, "self-test returned %d", r); return -4; }

    g_rx = rx; g_rw = (void *)rw; g_size = size; g_ready = 1;
    return 0;
}

// ---- Hooks used by QEMU's alloc_code_gen_buffer_splitwx_vmremap --------------------

extern kern_return_t mach_vm_remap(vm_map_t target_task, mach_vm_address_t *target_address,
                                   mach_vm_size_t size, mach_vm_offset_t mask, int flags,
                                   vm_map_t src_task, mach_vm_address_t src_address,
                                   boolean_t copy, vm_prot_t *cur_protection,
                                   vm_prot_t *max_protection, vm_inherit_t inheritance);

static int in_region(const void *p) {
    uintptr_t a = (uintptr_t)p;
    return g_ready && ((a >= (uintptr_t)g_rx && a < (uintptr_t)g_rx + g_size) ||
                       (a >= (uintptr_t)g_rw && a < (uintptr_t)g_rw + g_size));
}

static void *hook_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    if (g_ready && !g_handed && len == g_size && fd == -1 && (flags & MAP_ANON) && !(prot & PROT_EXEC)) {
        g_handed = 1;
        fprintf(stderr, "[jit26] gave QEMU the prepared %zu MB code buffer\n", len >> 20);
        return g_rw;
    }
    return mmap(addr, len, prot, flags, fd, off);
}

static kern_return_t hook_mach_vm_remap(vm_map_t tt, mach_vm_address_t *ta, mach_vm_size_t size,
                                        mach_vm_offset_t mask, int flags, vm_map_t st,
                                        mach_vm_address_t sa, boolean_t copy, vm_prot_t *cur,
                                        vm_prot_t *max, vm_inherit_t inh) {
    if (g_ready && sa == (mach_vm_address_t)(uintptr_t)g_rw) {
        *ta = (mach_vm_address_t)(uintptr_t)g_rx;
        if (cur) *cur = VM_PROT_READ | VM_PROT_EXECUTE;
        if (max) *max = VM_PROT_READ | VM_PROT_EXECUTE;
        return KERN_SUCCESS;
    }
    return mach_vm_remap(tt, ta, size, mask, flags, st, sa, copy, cur, max, inh);
}

static kern_return_t hook_vm_remap(vm_map_t tt, vm_address_t *ta, vm_size_t size, vm_address_t mask,
                                   int flags, vm_map_t st, vm_address_t sa, boolean_t copy,
                                   vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inh) {
    if (g_ready && sa == (vm_address_t)g_rw) {
        *ta = (vm_address_t)g_rx;
        if (cur) *cur = VM_PROT_READ | VM_PROT_EXECUTE;
        if (max) *max = VM_PROT_READ | VM_PROT_EXECUTE;
        return KERN_SUCCESS;
    }
    return vm_remap(tt, ta, size, mask, flags, st, sa, copy, cur, max, inh);
}

static int hook_mprotect(void *addr, size_t len, int prot) {
    if (in_region(addr)) return 0;      // region protections are owned by the debugger
    return mprotect(addr, len, prot);
}

static int hook_munmap(void *addr, size_t len) {
    if (in_region(addr)) return 0;
    return munmap(addr, len);
}

// ---- Minimal fishhook: rebind imports of one image ---------------------------------

struct rebind { const char *name; void *repl; };

static int rebind_section(const struct section_64 *s, intptr_t slide, const struct nlist_64 *symtab,
                          const char *strtab, const uint32_t *indirect, const struct rebind *rb, int n) {
    const uint32_t *ind = indirect + s->reserved1;
    void **slots = (void **)((uintptr_t)slide + s->addr);
    size_t count = s->size / sizeof(void *);
    int patched = 0, unlocked = 0;
    for (size_t i = 0; i < count; i++) {
        uint32_t si = ind[i];
        if (si == INDIRECT_SYMBOL_ABS || si == INDIRECT_SYMBOL_LOCAL ||
            si == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + symtab[si].n_un.n_strx;
        if (name[0] != '_') continue;
        for (int j = 0; j < n; j++) {
            if (strcmp(name + 1, rb[j].name) != 0) continue;
            if (!unlocked) {
                vm_protect(mach_task_self(), (vm_address_t)slots, s->size, FALSE,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                unlocked = 1;
            }
            slots[i] = rb[j].repl;
            patched++;
        }
    }
    return patched;
}

static int rebind_image(const struct mach_header_64 *mh, intptr_t slide, const struct rebind *rb, int n) {
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dst = NULL;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const void *)lc;
        else if (lc->cmd == LC_SYMTAB) st = (const void *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dst = (const void *)lc;
    }
    if (!linkedit || !st || !dst || !dst->nindirectsyms) return 0;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const void *)(base + st->symoff);
    const char *strtab = (const char *)(base + st->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dst->indirectsymoff);

    int total = 0;
    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strcmp(seg->segname, "__DATA") && strcmp(seg->segname, "__DATA_CONST") &&
            strcmp(seg->segname, "__AUTH_CONST") && strcmp(seg->segname, "__AUTH")) continue;
        const struct section_64 *sec = (const void *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++) {
            uint32_t type = sec[j].flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
                total += rebind_section(&sec[j], slide, symtab, strtab, indirect, rb, n);
        }
    }
    return total;
}

int jit26_install_qemu_hooks(const char *image_name_contains) {
    static const struct rebind rb[] = {
        { "mmap", (void *)hook_mmap },
        { "mach_vm_remap", (void *)hook_mach_vm_remap },
        { "vm_remap", (void *)hook_vm_remap },
        { "mprotect", (void *)hook_mprotect },
        { "munmap", (void *)hook_munmap },
    };
    int total = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, image_name_contains)) continue;
        total += rebind_image((const struct mach_header_64 *)_dyld_get_image_header(i),
                              _dyld_get_image_vmaddr_slide(i), rb, 5);
    }
    fprintf(stderr, "[jit26] region %zu MB ready, patched %d QEMU imports\n", g_size >> 20, total);
    return total;
}
