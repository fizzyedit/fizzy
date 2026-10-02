// SDL's C API as fizzy's native backend imports it (`sdl3-c`, translated in `build/exe.zig`). A copy
// of dvui's `src/backends/sdl3-c.h`: the backend takes SDL from fizzy's own pin, not dvui's, so it
// translates its own header too.

#define SDL_DISABLE_OLD_NAMES

#if defined(_MSC_VER)
#include <stdint.h>
#include <limits.h>
#ifndef SIZE_MAX
#define SIZE_MAX UINT_MAX
#endif
#undef INT8_C
#undef UINT8_C
#undef INT16_C
#undef UINT16_C
#undef INT32_C
#undef UINT32_C
#undef INT64_C
#undef UINT64_C
#define INT8_C(x)   (x)
#define UINT8_C(x)  (x)
#define INT16_C(x)  (x)
#define UINT16_C(x) (x)
#define INT32_C(x)  (x)
#define UINT32_C(x) (x)
#define INT64_C(x)  (x)
#define UINT64_C(x) (x)
#endif

#include "SDL3/SDL.h"

#define SDL_MAIN_HANDLED
#include "SDL3/SDL_main.h"
