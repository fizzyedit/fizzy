# Example apps: fizzy consumed as a library

Each directory here is an **independent Zig package** that depends on fizzy and produces its own
executable. That independence is the point: everything inside fizzy's own build graph proves the
design, but only an outside package proves *consumability*.

Each example **owns its layout** (`src/layout.zig`, passed as `-Dapp-layout=`). Fizzy does not
ship these as selectable presets — they show things fizzy itself does not do.

| Example | Shape | Identity |
|---|---|---|
| `minimal-app` | one main region, no rail or panel | `minimalapp`, "Minimal App" |
| `studio-app` | canvas, explorer on the right, short bottom strip | `studioapp`, "Studio App" |
| `endless-app` | Center is the workspace; collapsed splits on four edges | `endlessapp`, "Endless App" |

All three load the identical `workbench` / `text` / `image` / `markdown` plugins, **unchanged**.

## What a consumer writes

```zig
const fizzy = b.dependency("fizzy", .{
    .target = target,
    .optimize = optimize,
    .@"app-name" = @as([]const u8, "minimalapp"),
    .@"app-display-name" = @as([]const u8, "Minimal App"),
    .@"app-bundle-id" = @as([]const u8, "dev.fizzy.minimalapp"),
    .@"app-layout" = b.path("src/layout.zig"),
});
const exe = fizzy.artifact("minimalapp");
b.installArtifact(exe);
const run_cmd = b.addRunArtifact(exe);
run_cmd.step.dependOn(b.getInstallStep());
b.step("run", "Run the app").dependOn(&run_cmd.step);
```

`src/layout.zig` exports `pub fn layout(ctx: ?*anyopaque, f: *Layout)`. It imports `dvui`,
`app`, `core`, and `fizzy_sdk` — not `Editor`. Mix regions with your own dvui (a menu, a
rail) and take the app's pointer as `ctx`: set `Host.layout_ctx`, or export
`pub fn context() ?*anyopaque`. Fizzy fills that slot with `*Editor`. The app gets its own
executable name, window title, bundle id and config directory
(`Application Support/minimalapp/`, not `fizzy/`).

`zig build run` works in each example the same way it does for fizzy.

## The bug this caught

Before these existed, `build/exe.zig` set the executable's root module with
`.root_source_file = .{ .cwd_relative = "src/App.zig" }`. That resolves against the *current
working directory*, which is fizzy's own root when fizzy builds itself — so it worked, and every
test passed. The moment an outside package depends on fizzy, cwd is the consumer's directory and
the build dies with `'src/App.zig' file_hash FileNotFound`.

`b.path("src/Entry.zig")` resolves against fizzy's build root and is correct in both cases.

CI builds all three examples on macOS and Linux for this reason.

## Not yet covered

`zig build package` (Velopack installers) and `zig build web` are still fizzy-only: their
`build/package.zig` arguments hardcode fizzy's packId, icons, plist and entitlements. A consumer
gets an executable, not an installer. That parameterization is the remaining build-side work.
