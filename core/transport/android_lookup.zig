//! Name lookup through bionic's getaddrinfo, for Android only (std's resolver uses getaddrinfo
//! only on glibc; elsewhere on Linux it reads /etc/resolv.conf, which Android does not have).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const HostName = Io.net.HostName;

pub const use = builtin.target.abi.isAndroid();

/// The wrapped vtable, so `netLookup` can rebuild the Io its queue needs. Android runs one Io per
/// process (android/sdl_main.zig), so one slot is enough.
var vtable_self: *const Io.VTable = undefined;

/// `base` with netLookup swapped on Android; `base` unchanged elsewhere. `vtable` must outlive
/// the returned Io.
pub fn wrap(base: Io, vtable: *Io.VTable) Io {
    if (comptime !use) return base;
    vtable.* = base.vtable.*;
    vtable.netLookup = netLookup;
    vtable_self = vtable;
    return .{ .userdata = base.userdata, .vtable = vtable };
}

fn netLookup(
    userdata: ?*anyopaque,
    host: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    const io: Io = .{ .userdata = userdata, .vtable = vtable_self };
    defer resolved.close(io);

    var name: [HostName.max_len:0]u8 = undefined;
    @memcpy(name[0..host.bytes.len], host.bytes);
    name[host.bytes.len] = 0;
    var port_buf: [8]u8 = undefined;
    // A u16 port is at most 5 digits, and its sentinel fits the 8 bytes too.
    const port = std.mem.printSentinel(&port_buf, "{d}", .{options.port}, 0) catch unreachable;

    const hints: std.c.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = if (options.family) |f| switch (f) {
            .ip4 => std.c.AF.INET,
            .ip6 => std.c.AF.INET6,
        } else std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
        .protocol = std.c.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(&name, port.ptr, &hints, &res);
    if (@backingInt(rc) != 0) return switch (rc) {
        .NONAME, .NODATA => error.UnknownHostName,
        .AGAIN, .FAIL => error.NameServerFailure,
        .FAMILY, .ADDRFAMILY => error.AddressFamilyUnsupported,
        .MEMORY => error.SystemResources,
        else => error.Unexpected,
    };
    defer if (res) |r| std.c.freeaddrinfo(r);

    var it = res;
    while (it) |info| : (it = info.next) {
        const sa = info.addr orelse continue;
        resolved.putOne(io, .{ .address = Io.Threaded.addressFromPosix(@ptrCast(@alignCast(sa))) }) catch |err| switch (err) {
            // Only this function closes the queue, and only on return.
            error.Closed => unreachable,
            error.Canceled => return error.Canceled,
        };
    }
}
