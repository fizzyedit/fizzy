cmake_minimum_required(VERSION 3.12.0)
project(fizzy_hello)

# Built by `zig build lib -p zig-out/<abi>` in android/ (the Gradle task zigBuild does it).
set(ZIG_OUT ${CMAKE_SOURCE_DIR}/../../../../../zig-out/${ANDROID_ABI})

add_library(fizzy_hello_lib STATIC IMPORTED)
set_target_properties(fizzy_hello_lib PROPERTIES IMPORTED_LOCATION ${ZIG_OUT}/lib/libfizzy_hello.a)
add_library(sdl3_lib STATIC IMPORTED)
set_target_properties(sdl3_lib PROPERTIES IMPORTED_LOCATION ${ZIG_OUT}/lib/libSDL3.a)

add_library(fizzy_hello SHARED main.c)
target_include_directories(fizzy_hello PRIVATE ${ZIG_OUT}/include)
# whole-archive: SDL's JNI entry points (JNI_OnLoad, Java_org_libsdl_app_*) are only
# looked up at runtime by the JVM, so a plain static link would drop them.
target_link_libraries(fizzy_hello PRIVATE
    fizzy_hello_lib
    -Wl,--whole-archive sdl3_lib -Wl,--no-whole-archive
    android log dl m EGL GLESv1_CM GLESv2 OpenSLES)
