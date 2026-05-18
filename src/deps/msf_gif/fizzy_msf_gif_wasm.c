// msf_gif encoder for wasm32-freestanding: no <stdlib.h>; route heap through DVUI's
// exported allocator (same as zstbi / zip shims). SSE2 paths are disabled — not available on wasm.

#include <stddef.h>

void *memcpy(void *restrict dest, const void *restrict src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; ++i) d[i] = s[i];
    return dest;
}

void *memset(void *s, int c, size_t n) {
    unsigned char *p = (unsigned char *)s;
    const unsigned char byte = (unsigned char)c;
    for (size_t i = 0; i < n; ++i) p[i] = byte;
    return s;
}

extern void *dvui_c_alloc(size_t size);
extern void dvui_c_free(void *ptr);

static void *fizzy_msf_gif_malloc(size_t newSize) {
    return dvui_c_alloc(newSize);
}

static void *fizzy_msf_gif_realloc(void *oldMemory, size_t oldSize, size_t newSize) {
    if (newSize == 0) {
        dvui_c_free(oldMemory);
        return NULL;
    }
    void *ptr = dvui_c_alloc(newSize);
    if (ptr == NULL) return NULL;
    if (oldMemory != NULL && oldSize > 0) {
        const size_t copy = oldSize < newSize ? oldSize : newSize;
        unsigned char *dst = (unsigned char *)ptr;
        const unsigned char *src = (const unsigned char *)oldMemory;
        for (size_t i = 0; i < copy; ++i) dst[i] = src[i];
        dvui_c_free(oldMemory);
    }
    return ptr;
}

static void fizzy_msf_gif_free(void *oldMemory) {
    dvui_c_free(oldMemory);
}

#define MSF_GIF_MALLOC(contextPointer, newSize) fizzy_msf_gif_malloc(newSize)
#define MSF_GIF_REALLOC(contextPointer, oldMemory, oldSize, newSize) fizzy_msf_gif_realloc(oldMemory, oldSize, newSize)
#define MSF_GIF_FREE(contextPointer, oldMemory, oldSize) fizzy_msf_gif_free(oldMemory)

#define MSF_GIF_IMPL
#define MSF_USE_ALPHA
#define MSF_GIF_NO_SSE2
#include "msf_gif.h"
