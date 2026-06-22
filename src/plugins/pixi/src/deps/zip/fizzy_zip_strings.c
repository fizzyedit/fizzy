// Minimal string routines for zip/miniz on wasm32-freestanding (no libc).

#include <stddef.h>

extern void *memcpy(void *dest, const void *src, size_t n);

int strcmp(const char *l, const char *r) {
    for (; *l == *r && *l; l++, r++) {}
    return *(const unsigned char *)l - *(const unsigned char *)r;
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) {
        p++;
    }
    return (size_t)(p - s);
}

int memcmp(const void *l, const void *r, size_t n) {
    const unsigned char *a = l, *b = r;
    for (; n; n--, a++, b++) {
        if (*a != *b) {
            return *a - *b;
        }
    }
    return 0;
}

char *strcpy(char *dest, const char *src) {
    char *d = dest;
    while ((*d++ = *src++)) {}
    return dest;
}
