// Included first when compiling zip.c with -DFIZZY_ZIP_WASM (web / freestanding).
#pragma once

#include <stddef.h>
#include <stdint.h>

extern void *memcpy(void *dest, const void *src, size_t n);
extern void *memset(void *dest, int c, size_t n);
extern void *memmove(void *dest, const void *src, size_t n);

extern int strcmp(const char *l, const char *r);
extern size_t strlen(const char *s);
extern int memcmp(const void *l, const void *r, size_t n);
extern char *strcpy(char *dest, const char *src);
extern char *fizzy_strdup(const char *s);

extern void *fizzy_zip_malloc(size_t size);
extern void fizzy_zip_free(void *ptr);
extern void *fizzy_zip_realloc(void *ptr, size_t size);
extern void *fizzy_zip_calloc(size_t num, size_t size);

#define malloc(SZ) fizzy_zip_malloc(SZ)
#define free(PTR) fizzy_zip_free(PTR)
#define calloc(N, SZ) fizzy_zip_calloc(N, SZ)
#define realloc(PTR, SZ) fizzy_zip_realloc(PTR, SZ)

#define MINIZ_NO_STDIO
#define MINIZ_NO_TIME

#define MZ_MALLOC(SZ) fizzy_zip_malloc(SZ)
#define MZ_FREE(PTR) fizzy_zip_free(PTR)
#define MZ_REALLOC(PTR, SZ) fizzy_zip_realloc(PTR, SZ)

#ifndef assert
#define assert(EXPR) \
    do {             \
        if (!(EXPR)) \
            __builtin_trap(); \
    } while (0)
#endif

#include "miniz.h"
