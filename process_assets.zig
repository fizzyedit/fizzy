const std = @import("std");
const path = std.fs.path;
const Step = std.Build.Step;
const Io = std.Io;

const Atlas = @import("src/plugins/pixi/src/Atlas.zig");
const ProcessAssetsStep = @This();

step: Step,
builder: *std.Build,
assets_path: []const u8,
output_folder: []const u8,

pub fn init(builder: *std.Build, comptime assets_path: []const u8, comptime output_folder: []const u8) !*ProcessAssetsStep {
    const self = try builder.allocator.create(ProcessAssetsStep);
    self.* = .{
        .step = Step.init(.{ .id = .custom, .name = "process-assets", .owner = builder, .makeFn = process }),
        .builder = builder,
        .assets_path = assets_path,
        .output_folder = output_folder,
    };

    return self;
}

fn process(step: *Step, options: Step.MakeOptions) anyerror!void {
    const progress = options.progress_node.start("Processing assets...", 100);
    defer progress.end();
    const self: *ProcessAssetsStep = @fieldParentPtr("step", step);
    const root = self.assets_path;
    const output_folder = self.output_folder;
    try generate(self.builder.allocator, step.owner.graph.io, root, output_folder);
}

pub fn generate(allocator: std.mem.Allocator, io: Io, assets_root: []const u8, output_folder: []const u8) !void {
    var atlases: usize = 0;

    const cwd = Io.Dir.cwd();

    var dir = cwd.openDir(io, assets_root, .{ .access_sub_paths = true }) catch |err| {
        std.debug.print("Not a directory: {s}, err: {}\n", .{ assets_root, err });
        return;
    };
    dir.close(io);

    const files = try getAllFiles(allocator, io, assets_root, true);

    if (files.len == 0) {
        std.debug.print("No assets found!", .{});
        return;
    }

    for (files) |file| {
        const ext = std.fs.path.extension(file);

        if (std.mem.eql(u8, ext, "")) continue;

        const base = std.fs.path.basename(file);
        const ext_ind = std.mem.lastIndexOf(u8, base, ".");
        const name = base[0..ext_ind.?];

        const path_fixed = try allocator.alloc(u8, file.len);
        _ = std.mem.replace(u8, file, "\\", "/", path_fixed);

        const name_fixed = try allocator.alloc(u8, name.len);
        _ = std.mem.replace(u8, name, "-", "_", name_fixed);

        if (!std.mem.eql(u8, ext, ".atlas")) continue;
        atlases += 1;

        var allocating: Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();
        const atlas_writer = &allocating.writer;

        try atlas_writer.writeAll("// This is a generated file, do not edit.\n\n");
        try atlas_writer.print("// Sprites \n\n", .{});

        var atlas = try Atlas.loadFromFile(allocator, io, file);

        try atlas_writer.print("pub const sprites = struct {{\n", .{});

        for (atlas.sprites, 0..) |_, sprite_index| {
            const sprite_name = try atlas.spriteName(allocator, sprite_index);
            try atlas_writer.print("    pub const {s} = {d};\n", .{ sprite_name, sprite_index });
        }

        try atlas_writer.print("}};\n\n", .{});
        try atlas_writer.print("// Animations \n\n", .{});

        if (atlas.animations.len > 0) {
            try atlas_writer.print("pub const animations = struct {{\n", .{});

            for (atlas.animations) |animation| {
                const animation_name = try allocator.alloc(u8, animation.name.len);
                _ = std.mem.replace(u8, animation.name, " ", "_", animation_name);
                _ = std.mem.replace(u8, animation_name, ".", "_", animation_name);

                try atlas_writer.print("     pub var {s} = [_]usize {{\n", .{animation_name});

                for (animation.frames) |frame| {
                    try atlas_writer.print("        sprites.{s},\n", .{try atlas.spriteName(allocator, frame.sprite_index)});
                }

                try atlas_writer.print("    }};\n", .{});
            }

            try atlas_writer.print("}};\n", .{});
        }

        const atlas_path = if (atlases > 1) blk: {
            const atlas_name = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ output_folder, atlas_name });
        } else try std.fs.path.join(allocator, &[_][]const u8{ output_folder, "atlas.zig" });

        try cwd.writeFile(io, .{
            .sub_path = atlas_path,
            .data = allocating.written(),
        });
    }
}

fn getAllFiles(allocator: std.mem.Allocator, io: Io, root_directory: []const u8, recurse: bool) ![][:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;

    const recursor = struct {
        fn search(alloc: std.mem.Allocator, scan_io: Io, directory: []const u8, recursive: bool, filelist: *std.ArrayList([:0]const u8)) !void {
            var dir = try Io.Dir.cwd().openDir(scan_io, directory, .{ .access_sub_paths = true, .iterate = true });
            defer dir.close(scan_io);

            var iter = dir.iterate();
            while (try iter.next(scan_io)) |entry| {
                if (entry.kind == .file) {
                    const name_null_term = try std.mem.concat(alloc, u8, &[_][]const u8{ entry.name, "\x00" });
                    const abs_path = try std.fs.path.join(alloc, &[_][]const u8{ directory, name_null_term });
                    try filelist.append(alloc, abs_path[0 .. abs_path.len - 1 :0]);
                } else if (entry.kind == .directory) {
                    if (!recursive) continue;
                    const abs_path = try std.fs.path.join(alloc, &[_][]const u8{ directory, entry.name });
                    try search(alloc, scan_io, abs_path, recursive, filelist);
                }
            }
        }
    }.search;

    try recursor(allocator, io, root_directory, recurse, &list);

    std.mem.sort([:0]const u8, list.items, Context{}, compare);

    return try list.toOwnedSlice(allocator);
}

const Context = struct {};
fn compare(_: Context, a: [:0]const u8, b: [:0]const u8) bool {
    const base_a = std.fs.path.basename(a);
    const base_b = std.fs.path.basename(b);

    return std.mem.order(u8, base_a, base_b) == .lt;
}
