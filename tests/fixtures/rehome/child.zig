//! A framework-dependent submodule with a C implementation.
pub const Window = @import("dvui").Window;
extern fn rehome_value() c_int;

pub fn value() c_int {
    return rehome_value();
}
