// SDL's C API for the spike, as fizzy's native backend translates it (`backend/src/sdl3-c.h`).
#define SDL_DISABLE_OLD_NAMES
#include "SDL3/SDL.h"
#define SDL_MAIN_HANDLED
#include "SDL3/SDL_main.h"
