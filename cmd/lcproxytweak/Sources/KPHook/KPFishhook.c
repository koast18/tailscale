//
//  KPFishhook.c
//  LCProxyTweak
//
//  精简 fishhook：在进程内所有已加载 image 的 __la_symbol_ptr/__got 中
//  rebind 目标 C 符号，使后续调用（含第三方/Chromium/NSURLConnection 等）
//  走我们的替换实现。
//

#include "KPFishhook.h"
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/fat.h>

struct kp_rebinding {
    const char *name;        // 不带前导下划线
    void *replacement;
    void **replaced;         // 可空，回填原实现
};

static struct kp_rebinding g_rebindings[8];
static int g_rebinding_count = 0;

static int kp_rebind_image(const struct mach_header *mh, intptr_t slide) {
    int replaced = 0;
    // 注意：arm64 用 mach_header_64（32 字节），不能用 32 位 mach_header（28 字节）算 load commands 偏移
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    const struct load_command *cmd = (const void *)(mh64 + 1);
    struct symtab_command *symtab = NULL;
    struct dysymtab_command *dysymtab = NULL;
    for (uint32_t i = 0; i < mh->ncmds && cmd; i++,
         cmd = (const void *)((const char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd == LC_SYMTAB) symtab = (struct symtab_command *)cmd;
        else if (cmd->cmd == LC_DYSYMTAB) dysymtab = (struct dysymtab_command *)cmd;
    }
    if (!symtab || !dysymtab || g_rebinding_count == 0) return 0;

    const struct nlist_64 *sym = (const void *)((const char *)mh + symtab->symoff);
    const char *strtab = (const char *)mh + symtab->stroff;
    const uint32_t *indirect = (const void *)((const char *)mh + dysymtab->indirectsymoff);

    const struct load_command *lc = (const void *)(mh64 + 1);
    for (uint32_t i = 0; i < mh->ncmds && lc; i++,
         lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            if (sect->reserved1 + sect->size / 8 > dysymtab->nindirectsyms) continue;
            uintptr_t *ptr = (uintptr_t *)((uintptr_t)sect->addr + slide);
            if (sect->size == 0) continue;
            // __DATA_CONST.__got 等只读页：先解除写保护（写指针槽）
            uintptr_t start = (uintptr_t)ptr;
            uintptr_t end = start + sect->size;
            uintptr_t page = start & ~(uintptr_t)(getpagesize() - 1);
            for (; page < end; page += (uintptr_t)getpagesize()) {
                mprotect((void *)page, (size_t)getpagesize(), PROT_READ | PROT_WRITE);
            }
            for (uint32_t k = 0; k < sect->size / sizeof(uintptr_t); k++) {
                uint32_t idx = indirect[sect->reserved1 + k];
                if (idx >= symtab->nsyms) continue;
                uint32_t strx = sym[idx].n_un.n_strx;
                if (strx >= symtab->strsize) continue;
                const char *nm = strtab + strx;
                if (nm[0] == '_') nm++;
                if (!nm[0]) continue;
                for (int b = 0; b < g_rebinding_count; b++) {
                    if (strcmp(nm, g_rebindings[b].name) == 0) {
                        if (g_rebindings[b].replaced) *g_rebindings[b].replaced = (void *)ptr[k];
                        ptr[k] = (uintptr_t)g_rebindings[b].replacement;
                        replaced++;
                    }
                }
            }
        }
    }
    return replaced;
}

static void kp_image_added(const struct mach_header *mh, intptr_t slide) {
    // 保守策略：仅 rebind 主可执行文件（shared cache 内系统库的 symoff 相对 cache 偏移，
    // 直接按 mh+symoff 读取会越界崩溃）。后续真机验证后再扩展范围。
    if (mh != _dyld_get_image_header(0)) return;
    kp_rebind_image(mh, slide);
}

void kp_rebind_symbol(const char *name, void *replacement, void **replaced) {
    if (!name || !replacement || g_rebinding_count >= 8) return;
    g_rebindings[g_rebinding_count].name = name;
    g_rebindings[g_rebinding_count].replacement = replacement;
    g_rebindings[g_rebinding_count].replaced = replaced;
    g_rebinding_count++;
    // 对已加载 image 立即生效（回调对每个 image 触发）
    _dyld_register_func_for_add_image(kp_image_added);
}
