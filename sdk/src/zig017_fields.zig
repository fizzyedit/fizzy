//! ZIG017: 0.16-shaped field records rebuilt from 0.17's struct-of-arrays `@typeInfo`.
const std = @import("std");

pub const Field = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,

    pub inline fn defaultValue(comptime f: Field) ?f.type {
        const dp: *const f.type = @ptrCast(@alignCast(f.default_value_ptr orelse return null));
        return dp.*;
    }
};

pub fn fields(comptime T: type) []const Field {
    const s = @typeInfo(T).@"struct";
    var out: [s.field_names.len]Field = undefined;
    for (s.field_names, s.field_types, s.field_attrs, 0..) |n, t, a, i| out[i] = .{ .name = n, .type = t, .default_value_ptr = a.default_value_ptr };
    const final = out;
    return &final;
}

pub const EnumField = struct { name: [:0]const u8, value: comptime_int };

pub fn enumFields(comptime E: type) []const EnumField {
    const e = @typeInfo(E).@"enum";
    var out: [e.field_names.len]EnumField = undefined;
    for (e.field_names, e.field_values, 0..) |n, v, i| out[i] = .{ .name = n, .value = v };
    const final = out;
    return &final;
}
