// Minimal <string.h> for msf_gif on wasm32-freestanding.
#pragma once

#include <stddef.h>

void *memcpy(void *restrict dest, const void *restrict src, size_t n);
void *memset(void *s, int c, size_t n);
