// Heap + sort shims so `zstbi.c` (stb_rect_pack + stb_image_resize2) can compile
// on wasm32-freestanding, where `<stdlib.h>` is not available. Routes C
// allocations to DVUI's exported allocator (same source the zip + stb_image
// shims use). The qsort shim is a simple insertion sort — stb_rect_pack uses it
// once per atlas to sort rects by height, and even for thousand-rect atlases
// O(n²) is negligible compared to the actual pack work.

#include <stddef.h>

extern void *dvui_c_alloc(size_t size);
extern void dvui_c_free(void *ptr);

void *fizzy_stbi_malloc(size_t size) {
    return dvui_c_alloc(size);
}

void fizzy_stbi_free(void *ptr) {
    dvui_c_free(ptr);
}

typedef int (*fizzy_stbi_cmp)(const void *, const void *);

static void fizzy_stbi_swap_bytes(unsigned char *a, unsigned char *b, size_t n) {
    while (n--) {
        unsigned char t = *a;
        *a++ = *b;
        *b++ = t;
    }
}

void fizzy_stbi_qsort(void *base, size_t nmemb, size_t size, fizzy_stbi_cmp cmp) {
    if (nmemb < 2 || size == 0) return;
    unsigned char *arr = (unsigned char *)base;
    for (size_t i = 1; i < nmemb; ++i) {
        for (size_t j = i; j > 0 && cmp(arr + (j - 1) * size, arr + j * size) > 0; --j) {
            fizzy_stbi_swap_bytes(arr + (j - 1) * size, arr + j * size, size);
        }
    }
}
