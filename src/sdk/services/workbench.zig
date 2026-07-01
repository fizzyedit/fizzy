//! Workbench inter-plugin service — SDK-facing definition of the `"workbench"` service.
//!
//! The workbench plugin registers an instance via `host.registerService`. Plugin code
//! uses `host.getServiceTyped(workbench.Api)`. The layout is part of the ABI fingerprint.
const std = @import("std");
const dvui = @import("dvui");

pub const Api = struct {
    pub const service_name = "workbench";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const BranchDecorator = struct {
        ctx: ?*anyopaque = null,
        draw: *const fn (ctx: ?*anyopaque, path: []const u8, id_extra: usize) void,
    };

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool,
        currentGrouping: *const fn (ctx: *anyopaque) u64,
        newGrouping: *const fn (ctx: *anyopaque) u64,
        close: *const fn (ctx: *anyopaque, id: u64) anyerror!void,
        save: *const fn (ctx: *anyopaque) anyerror!void,
        isOpen: *const fn (ctx: *anyopaque, path: []const u8) bool,
        openCount: *const fn (ctx: *anyopaque) usize,
        openPathAt: *const fn (ctx: *anyopaque, index: usize) ?[]const u8,
        createFile: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        createDir: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        rename: *const fn (ctx: *anyopaque, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) anyerror!void,
        delete: *const fn (ctx: *anyopaque, path: []const u8) void,
        move: *const fn (ctx: *anyopaque, path: []const u8, target_dir: []const u8) anyerror!bool,
        registerBranchDecorator: *const fn (ctx: *anyopaque, decorator: BranchDecorator) anyerror!void,
    };

    pub fn open(self: Api, path: []const u8, grouping: u64) !bool {
        return self.vtable.open(self.ctx, path, grouping);
    }
    pub fn currentGrouping(self: Api) u64 {
        return self.vtable.currentGrouping(self.ctx);
    }
    pub fn newGrouping(self: Api) u64 {
        return self.vtable.newGrouping(self.ctx);
    }
    pub fn close(self: Api, id: u64) !void {
        return self.vtable.close(self.ctx, id);
    }
    pub fn save(self: Api) !void {
        return self.vtable.save(self.ctx);
    }
    pub fn isOpen(self: Api, path: []const u8) bool {
        return self.vtable.isOpen(self.ctx, path);
    }
    pub fn openCount(self: Api) usize {
        return self.vtable.openCount(self.ctx);
    }
    pub fn openPathAt(self: Api, index: usize) ?[]const u8 {
        return self.vtable.openPathAt(self.ctx, index);
    }
    pub fn createFile(self: Api, path: []const u8) !void {
        return self.vtable.createFile(self.ctx, path);
    }
    pub fn createDir(self: Api, path: []const u8) !void {
        return self.vtable.createDir(self.ctx, path);
    }
    pub fn rename(self: Api, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) !void {
        return self.vtable.rename(self.ctx, path, new_path, kind);
    }
    pub fn delete(self: Api, path: []const u8) void {
        return self.vtable.delete(self.ctx, path);
    }
    pub fn move(self: Api, path: []const u8, target_dir: []const u8) !bool {
        return self.vtable.move(self.ctx, path, target_dir);
    }
    pub fn registerBranchDecorator(self: Api, decorator: BranchDecorator) !void {
        return self.vtable.registerBranchDecorator(self.ctx, decorator);
    }
};
