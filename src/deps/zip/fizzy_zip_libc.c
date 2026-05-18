// Heap shims for compiling zip.c / miniz on wasm32-freestanding.
// Routes C allocations to DVUI's exported allocator (same as stb on web).

#include <stddef.h>
#include <stdint.h>

extern void *memset(void *dest, int c, size_t n);
extern void *memcpy(void *dest, const void *src, size_t n);

extern void *dvui_c_alloc(size_t size);
extern void dvui_c_free(void *ptr);
extern void *dvui_c_realloc_sized(void *ptr, size_t oldsize, size_t newsize);

void *fizzy_zip_malloc(size_t size) {
    return dvui_c_alloc(size);
}

void fizzy_zip_free(void *ptr) {
    dvui_c_free(ptr);
}

// `dvui_c_realloc_sized` uses `oldsize` as the memcpy length when copying from
// the old buffer to the new one. Passing 0 would leave the new buffer's content
// uninitialized — miniz's zip archive grows via realloc, so a 0 here would
// corrupt the zip output (the bytes wouldn't even start with `PK\x03\x04`).
//
// DVUI's `dvui_c_alloc` stores the allocation's *total* byte count (user size
// + the 8-byte prefix) 8 bytes before the user pointer. We recover the
// user-visible size by reading that prefix and subtracting 8, then clamp the
// copy to `min(oldsize, newsize)` so a shrinking realloc never overruns the
// new buffer's user area.
void *fizzy_zip_realloc(void *ptr, size_t size) {
    if (!ptr) {
        return dvui_c_alloc(size);
    }
    uint64_t buflen;
    memcpy(&buflen, (uint8_t *)ptr - 8, sizeof(uint64_t));
    size_t oldsize = (size_t)buflen - 8;
    size_t copy = oldsize < size ? oldsize : size;
    return dvui_c_realloc_sized(ptr, copy, size);
}

void *fizzy_zip_calloc(size_t num, size_t size) {
    const size_t total = num * size;
    void *ptr = dvui_c_alloc(total);
    if (ptr) {
        memset(ptr, 0, total);
    }
    return ptr;
}

extern size_t strlen(const char *s);
extern void *memcpy(void *dest, const void *src, size_t n);

char *fizzy_strdup(const char *s) {
    if (!s) {
        return NULL;
    }
    const size_t n = strlen(s) + 1;
    char *d = (char *)dvui_c_alloc(n);
    if (d) {
        memcpy(d, s, n);
    }
    return d;
}
