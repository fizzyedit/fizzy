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
| `endless-app` | Center is the workspace; split from the corner menu | `endlessapp`, "Endless App" |
| `hello-plugin` | not an app: the smallest third-party-shaped plugin, one sidebar surface | id `hello` |

All three apps load the identical `workbench` / `text` / `image` / `markdown` plugins,
**unchanged**; `minimal-app` additionally bundles `hello-plugin` from its own `build.zig.zon`.

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

## Bundling plugins of your own

A plugin is a package (its `build.zig` calls `fizzy.plugin.create`, which exports the plugin's
source as the `"plugin"` module besides building its dylib). List it in your `build.zig.zon`,
then hand its module to fizzy — which `b.dependency` options cannot carry, so the app is built
in two steps: `defer-app`, then `buildApp`:

```zig
const fizzy = @import("fizzy");

const fizzy_dep = b.dependency("fizzy", .{
    .target = target,
    .optimize = optimize,
    .@"defer-app" = true,
    .@"app-name" = @as([]const u8, "minimalapp"),
    .@"app-layout" = b.path("src/layout.zig"),
});
const hello = b.dependency("hello", .{ .target = target, .optimize = optimize });
try fizzy.buildApp(fizzy_dep, &.{
    .{ .name = "hello", .module = hello.module("plugin") },
});
const exe = fizzy_dep.artifact("minimalapp");
```

`name` is the plugin's id. The plugin is linked in and registered like fizzy's own four (the
build lists them all in a generated `bundled_plugins` module); a dylib of the same id beside
the executable takes precedence, as for the built-ins. Everything the plugin's own
`build.zig` adds to `plugin.static` (its dependencies) comes along; `dvui`, `core`,
`fizzy_sdk` and `icons` are fizzy's.

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
