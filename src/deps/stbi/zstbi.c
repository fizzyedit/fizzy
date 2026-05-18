#ifdef STBI_NO_STDLIB
// `wasm32-freestanding` has no libc. Route alloc + qsort through fizzy shims
// (see `fizzy_stbi_libc.c`) and stub out asserts so neither stb header pulls
// in `<stdlib.h>` / `<assert.h>`.
#include <stddef.h>
extern void *fizzy_stbi_malloc(size_t size);
extern void fizzy_stbi_free(void *ptr);
extern void fizzy_stbi_qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *));

// stb_rect_pack: comparator-driven sort + asserts.
#define STBRP_SORT(base, nmemb, size, compar) fizzy_stbi_qsort((base), (nmemb), (size), (compar))
#define STBRP_ASSERT(x) ((void)0)

// stb_image_resize2: malloc/free + asserts. `user_data` is passthrough.
#define STBIR_MALLOC(size, user_data) ((void)(user_data), fizzy_stbi_malloc(size))
#define STBIR_FREE(ptr, user_data) ((void)(user_data), fizzy_stbi_free(ptr))
#define STBIR_ASSERT(x) ((void)0)
// Skip `<math.h>` — use Clang/LLVM builtins available on wasm32.
#define STBIR_CEILF(x) __builtin_ceilf(x)
#define STBIR_FLOORF(x) __builtin_floorf(x)
// Skip `<string.h>` — use the Clang builtin memcpy. Zig's wasm target provides
// `memcpy` as an intrinsic for any compilation unit that emits a memcpy.
#define STBIR_MEMCPY(dest, src, len) __builtin_memcpy((dest), (src), (len))
#else
#include <stdlib.h>
#endif

#define STB_RECT_PACK_IMPLEMENTATION
#include "stb_rect_pack.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STBIR_DEFAULT_FILTER_UPSAMPLE     STBIR_FILTER_POINT_SAMPLE
#define STBIR_DEFAULT_FILTER_DOWNSAMPLE   STBIR_FILTER_POINT_SAMPLE
#include "stb_image_resize2.h"