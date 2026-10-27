//! The fixture plugin's dependency of its own: Zig declaring a function that `lib.c` defines, so
//! a lost import or a lost C source fails the plugin's compile or link.
pub extern fn fixture_answer() c_int;
