//! Open-document registry bridge: the shell stores `DocHandle`s; this owns `Internal.File`.
const std = @import("std");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const State = pixi_mod.State;
const Internal = pixi_mod.internal;

pub fn registerOpenDocument(st: *State, file: *Internal.File) !*Internal.File {
    const gpa = runtime.allocator();
    try st.docs.files.put(gpa, file.id, file.*);
    return st.docs.files.getPtr(file.id).?;
}

pub fn documentFromId(st: *State, id: u64) ?*Internal.File {
    return st.docs.fileById(id);
}

pub fn documentFromPath(st: *State, path: []const u8) ?*Internal.File {
    return st.docs.fileFromPath(path);
}

pub fn unregisterDocument(st: *State, id: u64) void {
    _ = st.docs.files.swapRemove(id);
}

pub fn persistProjectFolder(st: *State) void {
    st.persistProject();
}

pub fn reloadProjectFolder(st: *State, allocator: std.mem.Allocator) void {
    st.reloadProjectForFolder(allocator);
}
