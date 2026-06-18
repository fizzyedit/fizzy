//! Open-document registry bridge: the shell stores `DocHandle`s; this owns `Internal.File`.
const std = @import("std");
const pixelart = @import("../pixelart.zig");
const Globals = pixelart.Globals;
const State = pixelart.State;
const Internal = pixelart.internal;

pub fn registerOpenDocument(st: *State, file: *Internal.File) !*Internal.File {
    const gpa = Globals.allocator();
    try st.docs.files.put(gpa, file.id, file.*);
    return st.docs.files.getPtr(file.id).?;
}

pub fn documentPtr(st: *State, id: u64) ?*Internal.File {
    return st.docs.fileById(id);
}

pub fn documentByPath(st: *State, path: []const u8) ?*Internal.File {
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
