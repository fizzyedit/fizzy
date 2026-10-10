//! The loaded image (executable or dynamic library) holding an address: where it is mapped and
//! the build id that names the exact binary, read from the mapped headers themselves.
//!
//! The build id is what a crash report's offsets are resolved against: the Mach-O `LC_UUID`
//! (what a `.dSYM` carries), the ELF `NT_GNU_BUILD_ID` note, or a PE image's CodeView record (the
//! PDB's GUID and age). Read once, when the image is loaded, so a crash only compares addresses.
const std = @import("std");
const builtin = @import("builtin");

pub const Image = struct {
    /// Where the image is mapped: its header on Mach-O and PE, its lowest loaded segment on ELF.
    /// An offset in a report is an address minus this.
    base: usize,
    /// One past the last mapped byte of its code.
    end: usize,
    build_id_buf: [20]u8 = @splat(0),
    build_id_len: u8 = 0,

    pub fn contains(self: Image, address: usize) bool {
        return address >= self.base and address < self.end;
    }

    pub fn buildId(self: *const Image) []const u8 {
        return self.build_id_buf[0..self.build_id_len];
    }

    fn setBuildId(self: *Image, bytes: []const u8) void {
        const n = @min(bytes.len, self.build_id_buf.len);
        @memcpy(self.build_id_buf[0..n], bytes[0..n]);
        self.build_id_len = @intCast(n);
    }
};

/// The image `address` lies in, or null where the platform can't say (or it lies in none).
pub fn containing(address: usize) ?Image {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .visionos, .watchos => macho(address),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => elf(address),
        .windows => pe(address),
        else => null,
    };
}

fn macho(address: usize) ?Image {
    const macho_ = std.macho;
    const header: *const macho_.mach_header_64 = @ptrCast(@alignCast(
        std.c._dyld_get_image_header_containing_address(@ptrFromInt(address)) orelse return null,
    ));
    var image: Image = .{ .base = @intFromPtr(header), .end = 0 };
    var at: usize = @intFromPtr(header) + @sizeOf(macho_.mach_header_64);
    for (0..header.ncmds) |_| {
        const lc: *const macho_.load_command = @ptrFromInt(at);
        switch (lc.cmd) {
            .SEGMENT_64 => {
                const seg: *const macho_.segment_command_64 = @ptrFromInt(at);
                // __TEXT starts at the header (file offset 0), so its size is the code's extent.
                if (std.mem.eql(u8, std.mem.sliceTo(&seg.segname, 0), "__TEXT")) image.end = image.base + seg.vmsize;
            },
            .UUID => image.setBuildId(&@as(*const macho_.uuid_command, @ptrFromInt(at)).uuid),
            else => {},
        }
        at += lc.cmdsize;
    }
    if (image.end == 0) return null;
    return image;
}

fn elf(address: usize) ?Image {
    const Search = struct {
        address: usize,
        found: ?Image = null,

        fn visit(info: *std.c.dl_phdr_info, _: usize, data: ?*anyopaque) callconv(.c) c_int {
            const s: *@This() = @ptrCast(@alignCast(data.?));
            const phdrs = info.phdr[0..info.phnum];
            var lo: usize = std.math.maxInt(usize);
            var hi: usize = 0;
            var hit = false;
            for (phdrs) |p| if (p.type == .LOAD) {
                const start = info.addr + p.vaddr;
                const end = start + p.memsz;
                lo = @min(lo, start);
                hi = @max(hi, end);
                if (s.address >= start and s.address < end) hit = true;
            };
            if (!hit) return 0;
            var image: Image = .{ .base = lo, .end = hi };
            for (phdrs) |p| if (p.type == .NOTE) {
                if (gnuBuildId(@as([*]const u8, @ptrFromInt(info.addr + p.vaddr))[0..p.memsz])) |id| image.setBuildId(id);
            };
            s.found = image;
            return 1;
        }
    };
    var search: Search = .{ .address = address };
    _ = std.c.dl_iterate_phdr(Search.visit, &search);
    return search.found;
}

/// The `NT_GNU_BUILD_ID` note's bytes in a `PT_NOTE` segment, if it holds one.
fn gnuBuildId(notes: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at + 12 <= notes.len) {
        const namesz = std.mem.readInt(u32, notes[at..][0..4], builtin.cpu.arch.endian());
        const descsz = std.mem.readInt(u32, notes[at + 4 ..][0..4], builtin.cpu.arch.endian());
        const kind = std.mem.readInt(u32, notes[at + 8 ..][0..4], builtin.cpu.arch.endian());
        const name_at = at + 12;
        const desc_at = name_at + std.mem.alignForward(usize, namesz, 4);
        const next = desc_at + std.mem.alignForward(usize, descsz, 4);
        if (next > notes.len) return null;
        if (kind == std.elf.NT_GNU_BUILD_ID and namesz == 4 and std.mem.eql(u8, notes[name_at..][0..4], "GNU\x00"))
            return notes[desc_at..][0..descsz];
        at = next;
    }
    return null;
}

const win = struct {
    const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 0x2;
    const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x4;
    extern "kernel32" fn GetModuleHandleExW(flags: u32, name: ?*const anyopaque, module: *?*anyopaque) callconv(.winapi) i32;
};

fn pe(address: usize) ?Image {
    var module: ?*anyopaque = null;
    if (win.GetModuleHandleExW(
        win.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(address),
        &module,
    ) == 0) return null;
    const base = @intFromPtr(module orelse return null);
    const at = struct {
        fn u16_(p: usize) u16 {
            return std.mem.readInt(u16, @as(*const [2]u8, @ptrFromInt(p)), .little);
        }
        fn u32_(p: usize) u32 {
            return std.mem.readInt(u32, @as(*const [4]u8, @ptrFromInt(p)), .little);
        }
    };
    const nt = base + at.u32_(base + 0x3c); // e_lfanew
    if (at.u32_(nt) != 0x4550) return null; // "PE\0\0"
    const optional = nt + 4 + 20; // past the signature and the COFF file header
    if (at.u16_(optional) != 0x20b) return null; // PE32+
    var image: Image = .{ .base = base, .end = base + at.u32_(optional + 56) }; // SizeOfImage
    // Data directory 6 is the debug directory; its CodeView entry is "RSDS", GUID, age.
    const debug_rva = at.u32_(optional + 112 + 6 * 8);
    const debug_size = at.u32_(optional + 112 + 6 * 8 + 4);
    var entry: usize = 0;
    while (entry + 28 <= debug_size) : (entry += 28) {
        const d = base + debug_rva + entry;
        if (at.u32_(d + 12) != 2) continue; // IMAGE_DEBUG_TYPE_CODEVIEW
        const cv = base + at.u32_(d + 20);
        if (at.u32_(cv) == 0x53445352) // "RSDS"
            image.setBuildId(@as(*const [20]u8, @ptrFromInt(cv + 4)));
        break;
    }
    return image;
}

test "the image holding this code contains it, and names its build" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    const here = @intFromPtr(&containing);
    const image = containing(here) orelse return error.NoImage;
    try std.testing.expect(image.contains(here));
    // Zig's Mach-O linker always writes an LC_UUID; ELF and PE only carry an id when asked to.
    if (builtin.os.tag == .macos) try std.testing.expectEqual(16, image.buildId().len);
}

test "a GNU build-id note is found among others" {
    const w = struct {
        fn u(v: u32) [4]u8 {
            return std.mem.toBytes(v);
        }
    }.u;
    const other = w(4) ++ w(8) ++ w(1) ++ "GNU\x00".* ++ [_]u8{0} ** 8;
    const build_id = w(4) ++ w(5) ++ w(std.elf.NT_GNU_BUILD_ID) ++ "GNU\x00".* ++ "\xde\xad\xbe\xef\x01\x00\x00\x00".*;
    try std.testing.expectEqualSlices(u8, "\xde\xad\xbe\xef\x01", gnuBuildId(&(other ++ build_id)).?);
    try std.testing.expectEqual(null, gnuBuildId(&other));
}
