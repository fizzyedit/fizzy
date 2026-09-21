//! The mountable-filesystem contract: path-addressed, completion-based, wasm-safe.
//!
//! This is fizzy's seam between "a path" and "whatever answers it": the disk (`core.LocalFs`),
//! an in-memory tree (`Mem`, which a zip archive unpacks into), or a cloud drive that a plugin
//! mounts through `Host.mount`. A provider — Google Drive, Dropbox — lives in its own plugin
//! and implements `Fs` over `http.Transport`; nothing here knows any provider's name.
//!
//! See `Fs.zig` for the two decisions that shape the API (paths, not ids; completions from
//! `pump`, never a blocking call) and `docs/CLOUD_FS_PLAN.md` for the whole design.
const FsFile = @import("Fs.zig");

pub const Error = FsFile.Error;
pub const Kind = FsFile.Kind;
pub const Entry = FsFile.Entry;
pub const Stat = FsFile.Stat;
pub const Read = FsFile.Read;
pub const WriteOptions = FsFile.WriteOptions;
pub const Job = FsFile.Job;
pub const Fs = FsFile.Fs;
pub const ListDirFn = FsFile.ListDirFn;
pub const StatFn = FsFile.StatFn;
pub const ReadFn = FsFile.ReadFn;
pub const DoneFn = FsFile.DoneFn;
pub const freeEntries = FsFile.freeEntries;
pub const path = struct {
    pub const dirname = FsFile.dirname;
    pub const basename = FsFile.basename;
    pub const join = FsFile.join;
    pub const isRoot = FsFile.isRoot;
    pub const segments = FsFile.segments;
};

pub const http = @import("http.zig");
pub const Mem = @import("mem.zig").Mem;
pub const zip = @import("zip.zig");

test {
    _ = @import("Fs.zig");
    _ = @import("http.zig");
    _ = @import("mem.zig");
    _ = @import("zip.zig");
}
