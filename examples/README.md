# Example apps: fizzy consumed as a library

Each directory here is an **independent Zig package** that depends on fizzy and produces its own
executable. That independence is the point: everything inside fizzy's own build graph proves the
design, but only an outside package proves *consumability*.

| Example | Shape | Identity |
|---|---|---|
| `minimal-app` | `-Dlayout=minimal` — one main region, no rail/explorer/panel | `minimalapp`, "Minimal App" |
| `studio-app` | `-Dlayout=studio` — explorer on the right, short bottom strip, big canvas | `studioapp`, "Studio App" |
| `endless-app` | its own `src/layout.zig` via `-Dapp-layout=` — Center is the workspace; collapsed splits on four edges | `endlessapp`, "Endless App" |

All three load the identical `workbench` / `text` / `image` / `markdown` plugins, **unchanged**.
`endless-app` is the consumability test for a consumer-owned shape: fizzy does not ship that
layout as a preset.

## What a consumer writes

The whole build file:

```zig
const fizzy = b.dependency("fizzy", .{
    .target = target,
    .optimize = optimize,
    .@"app-name" = @as([]const u8, "minimalapp"),
    .@"app-display-name" = @as([]const u8, "Minimal App"),
    .@"app-bundle-id" = @as([]const u8, "dev.fizzy.minimalapp"),
    .@"new-shell" = true,
    .shell = @as([]const u8, "minimal"),
});
b.installArtifact(fizzy.artifact("minimalapp"));
```

No `build/lib.zig`, no bespoke `fizzy.app.create` — ordinary Zig dependency mechanics carry it,
because Phase 3 made identity a build option and Phase 5 made the layout one. The app gets its
own executable name, window title, bundle id and config directory
(`Application Support/minimalapp/`, not `fizzy/`). To bring a shape of your own instead of a
shipped `-Dlayout=` preset, pass `.@"app-layout" = b.path("src/layout.zig")` — a file exporting
`pub fn layout(*Layout)`. `endless-app` is that form.

## The bug this caught

Before these existed, `build/exe.zig` set the executable's root module with
`.root_source_file = .{ .cwd_relative = "src/App.zig" }`. That resolves against the *current
working directory*, which is fizzy's own root when fizzy builds itself — so it worked, and every
test passed. The moment an outside package depends on fizzy, cwd is the consumer's directory and
the build dies with `'src/App.zig' file_hash FileNotFound`.

Notably 25 of 28 build steps still succeeded: the entire dependency graph resolved and every
plugin compiled. Exactly one path was wrong, and nothing inside fizzy could have revealed it.
`b.path("src/App.zig")` resolves against fizzy's build root and is correct in both cases.

CI builds all three examples on macOS and Linux for this reason. `endless-app` also has
`zig build run`, the same step fizzy itself exposes.

## Not yet covered

`zig build package` (Velopack installers) and `zig build web` are still fizzy-only: their
`build/package.zig` arguments hardcode fizzy's packId, icons, plist and entitlements. A consumer
gets an executable, not an installer. That parameterization is the remaining build-side work.
