//! Async project packing for the pixel-art plugin. Invoked from the plugin vtable;
//! the shell routes `EditorAPI.startPackProject` / `isPackingActive` here.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const State = pixi_mod.State;
const PackJob = @import("PackJob.zig");
const Internal = pixi_mod.internal;

fn showPackToast(message: []const u8, canvas_id: ?dvui.Id) void {
    const anchor = canvas_id orelse blk: {
        if (runtime.state().host.activeDoc()) |doc| {
            if (runtime.state().docs.fileById(doc.id)) |file| break :blk file.editor.canvas.id;
        }
        break :blk dvui.currentWindow().data().id;
    };
    const id_mutex = dvui.toastAdd(dvui.currentWindow(), @src(), 0, anchor, pixi_mod.core.dvui.toastDisplay, 2_500_000);
    const id = id_mutex.id;
    const msg_copy = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}", .{message}) catch message;
    dvui.dataSetSlice(dvui.currentWindow(), id, "_message", msg_copy);
    id_mutex.mutex.unlock(dvui.io);
}

fn appendOpenPackInputs(st: *State, inputs: *std.ArrayListUnmanaged(PackJob.PackInput)) !void {
    const gpa = runtime.allocator();
    const host = st.host;
    var i: usize = 0;
    while (i < host.openDocCount()) : (i += 1) {
        const doc = host.docByIndex(i) orelse continue;
        const open_file = st.docs.fileById(doc.id) orelse continue;
        const snapshot = try PackJob.PackFile.fromOpenFile(gpa, open_file);
        try inputs.append(gpa, .{ .open = snapshot });
    }
}

fn findOpenFileForPackPath(st: *State, path: []const u8) ?*Internal.File {
    if (st.docs.fileFromPath(path)) |file| return file;

    const basename = std.fs.path.basename(path);
    const gpa = runtime.allocator();
    const host = st.host;
    var i: usize = 0;
    while (i < host.openDocCount()) : (i += 1) {
        const doc = host.docByIndex(i) orelse continue;
        const file = st.docs.fileById(doc.id) orelse continue;
        if (!std.mem.eql(u8, std.fs.path.basename(file.path), basename)) continue;
        if (std.mem.eql(u8, file.path, path)) return file;
        if (host.folder()) |folder| {
            const joined = std.fs.path.join(gpa, &.{ folder, basename }) catch continue;
            defer gpa.free(joined);
            if (std.mem.eql(u8, file.path, joined)) return file;
        }
    }
    return null;
}

fn gatherPackInputs(
    st: *State,
    inputs: *std.ArrayListUnmanaged(PackJob.PackInput),
    directory: []const u8,
) !void {
    const gpa = runtime.allocator();
    const io = dvui.io;
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (!Internal.File.isFizzyExtension(ext)) continue;

            const abs_path = try std.fs.path.join(gpa, &.{ directory, entry.name });
            defer gpa.free(abs_path);

            if (findOpenFileForPackPath(st, abs_path) != null) continue;

            const owned_path = try gpa.dupe(u8, abs_path);
            try inputs.append(gpa, .{ .path = owned_path });
        } else if (entry.kind == .directory) {
            const abs_path = try std.fs.path.join(gpa, &.{ directory, entry.name });
            defer gpa.free(abs_path);
            try gatherPackInputs(st, inputs, abs_path);
        }
    }
}

pub fn start(st: *State) !void {
    const gpa = runtime.allocator();
    var inputs: std.ArrayListUnmanaged(PackJob.PackInput) = .empty;
    errdefer {
        for (inputs.items) |*input| input.deinit(gpa);
        inputs.deinit(gpa);
    }

    if (comptime builtin.target.cpu.arch == .wasm32) {
        try appendOpenPackInputs(st, &inputs);
    } else {
        const root = st.host.folder() orelse return;
        try appendOpenPackInputs(st, &inputs);
        try gatherPackInputs(st, &inputs, root);
    }

    if (inputs.items.len == 0) {
        const msg = if (comptime builtin.target.cpu.arch == .wasm32)
            "No open files to pack"
        else
            "No .fiz or .pixi files to pack";
        showPackToast(msg, null);
        return;
    }

    var owned_inputs: ?[]PackJob.PackInput = try inputs.toOwnedSlice(gpa);
    errdefer if (owned_inputs) |o| {
        for (o) |*input| input.deinit(gpa);
        gpa.free(o);
    };

    for (st.pack_jobs.items) |old| {
        old.cancelled.store(true, .monotonic);
    }

    const job = try PackJob.create(gpa, owned_inputs.?);
    owned_inputs = null;
    errdefer job.destroy();

    try st.pack_jobs.append(gpa, job);
    errdefer _ = st.pack_jobs.pop();

    if (comptime builtin.target.cpu.arch == .wasm32) {
        dvui.refresh(dvui.currentWindow(), @src(), null);
    } else {
        const thread = try std.Thread.spawn(.{}, PackJob.workerMain, .{job});
        thread.detach();
    }
}

pub fn isActive(st: *const State) bool {
    for (st.pack_jobs.items) |job| {
        if (job.cancelled.load(.monotonic)) continue;
        if (!job.done.load(.acquire)) return true;
        if (!job.result_consumed) return true;
    }
    return false;
}

pub fn runWasmWorkers(st: *State) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    for (st.pack_jobs.items) |job| {
        if (job.cancelled.load(.monotonic)) continue;
        if (job.done.load(.acquire)) continue;
        PackJob.workerMain(job);
        return;
    }
}

pub fn tick(st: *State) void {
    if (st.pack_jobs.items.len == 0) return;

    const gpa = runtime.allocator();
    var install_index: ?usize = null;
    {
        var i = st.pack_jobs.items.len;
        while (i > 0) {
            i -= 1;
            const job = st.pack_jobs.items[i];
            if (!job.done.load(.acquire)) continue;
            if (job.cancelled.load(.monotonic)) continue;
            if (job.currentPhase() == .ready and job.result_atlas != null) {
                install_index = i;
                break;
            }
        }
    }

    if (install_index) |idx| {
        const job = st.pack_jobs.items[idx];
        const new_atlas = job.result_atlas.?;
        if (runtime.packer().atlas) |*current_atlas| {
            current_atlas.deinitCheckerboardTile();
            for (current_atlas.data.animations) |*anim| gpa.free(anim.name);
            gpa.free(current_atlas.data.sprites);
            gpa.free(current_atlas.data.animations);
            gpa.free(pixi_mod.image.bytes(current_atlas.source));

            current_atlas.source = new_atlas.source;
            current_atlas.data = new_atlas.data;
            current_atlas.initCheckerboardTile();
        } else {
            runtime.packer().atlas = new_atlas;
            runtime.packer().atlas.?.initCheckerboardTile();
        }
        runtime.packer().last_packed_at_ns = pixi_mod.perf.nanoTimestamp();
        job.result_consumed = true;
        st.host.setActiveSidebarView("pixi_mod.project");
        const toast_canvas: ?dvui.Id = if (st.host.activeDoc()) |doc|
            if (st.docs.fileById(doc.id)) |file| file.editor.canvas.id else null
        else
            null;
        showPackToast("Project packed", toast_canvas);
    } else blk: {
        var i = st.pack_jobs.items.len;
        while (i > 0) {
            i -= 1;
            const job = st.pack_jobs.items[i];
            if (!job.done.load(.acquire)) continue;
            if (job.cancelled.load(.monotonic)) continue;
            if (job.currentPhase() == .ready and job.result_atlas == null) {
                showPackToast("Nothing to pack in the selected files", null);
                break :blk;
            }
        }
    }

    var write: usize = 0;
    for (st.pack_jobs.items) |job| {
        if (!job.done.load(.acquire)) {
            st.pack_jobs.items[write] = job;
            write += 1;
            continue;
        }
        const phase = job.currentPhase();
        switch (phase) {
            .ready, .cancelled => {},
            .failed => {
                dvui.log.err("Pack project failed: {any}", .{job.err});
                showPackToast("Pack failed", null);
            },
            else => dvui.log.err("Pack job finished in unexpected phase {s}", .{@tagName(phase)}),
        }
        job.destroy();
    }
    st.pack_jobs.shrinkRetainingCapacity(write);
}
