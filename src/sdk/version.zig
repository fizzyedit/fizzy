//! SDK version and ABI fingerprint lock.
//!
//! `sdk_version` is bumped when the plugin ABI boundary changes. `recorded_sdk_shape_fingerprint`
//! must be updated in the same commit — CI fails at compile time if the live shape fingerprint
//! drifts from the recorded literal without an intentional version bump.
//!
//! **Two fingerprints, one shape.** Both derive from the same target/mode-invariant declared
//! shape (`fingerprint.hashAllShape`: field names/order, integer bit-width, enum tags, pointer
//! kind, fn signatures — never a byte offset or size) of the Fizzy-owned boundary:
//!
//!   * `dylib.sdk_shape_fingerprint` — the bare shape hash, checked below against a single
//!     recorded literal. The "did you forget to bump `sdk_version`" guard. Invariant, so it needs
//!     no per-(arch, os, mode) table and no cross-compiling: `zig build test-sdk-version` on any
//!     target reports the value to record.
//!   * `dylib.abi_fingerprint` — the runtime dlopen-time load key: the shape hash folded with the
//!     optimize-mode *safety class* (`Debug`/`ReleaseSafe` vs `ReleaseFast`/`ReleaseSmall`, which
//!     lay out hash-map safety fields differently). Host and plugin compute it live and compare
//!     (`dylib.fingerprintMatches`). Also target-invariant — cross-target `dlopen` is impossible
//!     regardless, so the key deliberately excludes per-target byte offsets, which lets the plugin
//!     store match one fingerprint per release across every `os-arch` binary.
//!
//! Because the load key is shape-based, a plugin breaks *only* when the boundary shape actually
//! changes (→ you bump `sdk_version`) or the optimize-mode class differs (a genuinely unloadable
//! combination). A cosmetic dvui/toolchain update that leaves the boundary shape untouched keeps
//! every installed plugin loading. The one thing this no longer catches — pure codegen/padding
//! drift within a single `sdk_version` — only happens on a deliberate, pinned zig/dvui bump that
//! is a coordinated re-release anyway. See `fingerprint.hashAllShape` for the full rationale.
//!
//! **Cadence policy (decoupled from the app version).** The app version (`VERSION` /
//! `build.zig.zon`) ships often and is *not* an input to either fingerprint or to `sdk_version`.
//! The shape fingerprint is a pure function of the plugin-boundary types Fizzy declares (dvui
//! types included, reached transitively where they cross the boundary) — it only moves when one of
//! those *shapes* changes. `dvui` and the Zig toolchain are pinned (see the `dvui` dependency in
//! `build.zig.zon` and `ZIG_VERSION` in CI) and bumped deliberately/batched; a bump that
//! restructures a boundary-reachable dvui type moves the shape fingerprint (→ bump `sdk_version`),
//! while a cosmetic one does not. A Fizzy release that leaves the boundary shape untouched keeps
//! the same fingerprint, so the store's installed plugins keep loading. The store matches plugin
//! binaries on `abi_fingerprint` (see `docs/PLUGINS.md` § Compatibility).
const std = @import("std");
const builtin = @import("builtin");
const dylib = @import("dylib.zig");

pub const VersionTriplet = dylib.VersionTriplet;

/// ABI contract version. Bump minor (or major for breaking changes) when
/// `recorded_sdk_shape_fingerprint` changes.
pub const sdk_version = std.SemanticVersion{
    .major = 0,
    .minor = 31,
    .patch = 0,
};


/// Recorded `dylib.sdk_shape_fingerprint` — see the module doc above for what this hashes and
/// why it is a single target/mode-invariant literal rather than a per-target table. Update this
/// value (from the `@compileError` it triggers) and bump `sdk_version` in the same commit
/// whenever it changes.
///
/// 0.5.0: added `Host.FileRowFillColor.owner` + service-owner tracking for runtime unload.
/// 0.6.0: added `Host.registerFileIcon`/`FileIcon` (plugins draw their own file-tree icons).
/// 0.7.0: removed `host.uiAtlas`/`UiAtlasView`/`UiSprite` (plugins own their own sprite atlases).
/// 0.8.0: boundary layout shifted (custom TextEntryWidget / workbench tabs work); also replaced
/// the old per-(arch, os) `recorded_abi_fingerprints` table — which could not actually hold one
/// value per platform once optimize mode is accounted for (see `fingerprint.hashAllShape`) — with
/// this single shape fingerprint.
///   ↳ Value re-recorded (no `sdk_version` bump, no boundary change) after fixing a
///     target-*variance* bug in `hashAllShape`: it folded in the concrete bit-width of pointer-
///     sized ints, so any `usize`/`isize` reached in the walk (every `std` container's len/
///     capacity) hashed as 64-bit on native but 32-bit on wasm32. The old literal
///     (`0xd8304e87baf922b2`) was a 64-bit-host value that no wasm32 build could ever match, which
///     broke `zig build check-web`/`serve-web`. `hashTypeShape` now canonicalizes `usize`/`isize`
///     to width-free tokens, so this literal is identical on every target. The runtime gate
///     (`abi_fingerprint`) is unchanged, so already-installed plugins keep loading.
/// 0.9.0: added `MenuContribution.title`/`.hidden`, `MenuSectionContribution.hidden`, and the new
/// `NativeMenuItem` contribution + `Host.native_menu_items`/`registerNativeMenuItem` (pure-data
/// menu leaf items the native macOS `NSMenu` builder consumes).
/// 0.10.0: added `LanguageSupport` registry + `TreeSitterHighlight`/`HighlightStyle` +
/// `Host.registerLanguageSupport`/`treeSitterHighlightFor`/`previewProviderFor`.
/// 0.11.0: added `Host.registerPluginIcon`/`PluginIcon` (plugins draw their own store-card logos).
/// 0.12.0: added `Host.pending_new_document_owner` — fixes a "New File" dialog's `createDocument`
/// call resolving to the wrong plugin once more than one plugin implements it (see
/// `requestNewDocument`/`Editor.newFile`).
/// 0.13.0: added `Host.pending_dialog_close_rect` + `setPendingDialogCloseRect`/
/// `takePendingDialogCloseRect` — lets one plugin (the explorer's tree scan) redirect
/// another plugin's open dialog's close animation toward a specific rect ("fly to the new
/// file's row"). `core.dvui.dialog_close_rect_override`, a plain module-level `var`, cannot
/// do this: `core` is compiled into every plugin dylib separately, so each dylib has its own
/// private copy — a write from one plugin's copy is invisible to another's.
/// 0.14.0: removed `Host.pending_dialog_close_rect`/`setPendingDialogCloseRect`/
/// `takePendingDialogCloseRect` — the "fly to row" close animation this enabled never
/// reliably fired (the explorer's tree scan that was supposed to supply the target rect
/// doesn't re-run after the dialog opens, for reasons not fully root-caused) and added
/// real cross-plugin complexity for no working payoff. New File dialogs just close on
/// themselves now (shrink-to-center), same as every other dialog.
/// 0.15.0: added `EditorAPI.panZoomScheme` + shell `Settings.input_scheme` — shared
/// canvas mouse/trackpad zoom/pan preference for the image viewer, pixi, and other
/// `CanvasWidget` consumers.
/// 0.16.0: added basic language-server-style hooks — `LanguageSupport.VTable.hover`/
/// `gotoDefinition` + `HoverResult`/`DefinitionLocation`, `Host.hoverFor`/`gotoDefinitionFor`,
/// `Plugin.VTable.revealPosition` (external plugins moving the caret in a document they don't
/// own), and `workbench.Api.VTable.revealPosition` (open-if-needed + jump to a byte offset).
/// Backs Ctrl/Cmd+click goto-definition and hover tooltips in the text editor.
/// 0.17.0: `LanguageSupport.VTable.hover`/`gotoDefinition` (+ `Host.hoverFor`/
/// `gotoDefinitionFor`) gained an explicit `path` parameter instead of relying on the
/// `previewDocumentPath()` threadlocal. That threadlocal only ever worked for `previewPane`
/// because `text`/`markdown` happen to be statically linked into the same binary and share
/// one copy of it — a genuinely separate plugin dylib (e.g. the third-party `zig` language
/// plugin) gets its own private copy, so the host's write was invisible from inside the
/// plugin and hover/gotoDefinition silently never fired. `path` is now passed explicitly,
/// same as `bytes`.
/// 0.18.0: added the `"markdown"` inter-plugin service (`services/markdown.zig`'s `Api`) —
/// lets other plugins render a CommonMark+GFM byte slice (via the markdown plugin's
/// `cmark-gfm` renderer) into the current dvui parent without importing the markdown plugin
/// directly. Native-only (the markdown plugin itself links libc + a C library and is never
/// statically linked into the web build), so callers must treat `getServiceTyped` returning
/// null as expected and fall back to their own rendering. Backs richer hover-tooltip body
/// rendering (links, lists, bold) in the text editor.
/// 0.19.0: added `EditorAPI.logLine` (+ `Host.logLine`) — lets a plugin append a line to the
/// shell's "Output" bottom panel across the ABI boundary with plain runtime strings (a
/// plugin dylib compiles its own `std.log` binding, so it can't share the shell's). Backs
/// the `zig` plugin's LSP client forwarding zls's subprocess stderr into the Output panel.
/// 0.20.0: added `LanguageSupport.VTable.completion` + `CompletionItem`, `Host.completionFor`
/// — non-blocking, same convention as `hover`. Backs inline (ghost-text) autocomplete in the
/// text editor: a single dimmed suggestion shown after the cursor, VSCode/Copilot-style, not
/// a filterable dropdown of multiple candidates (hence one `CompletionItem`, not a list).
/// 0.21.0: `LanguageSupport.VTable.completion`/`Host.completionFor` now return `?[]const
/// CompletionItem` instead of `?CompletionItem` — 0.20.0's single-candidate-only shape was a
/// deliberate first pass, but real editor parity needs a scrollable list of candidates (not
/// just one), with Up/Down changing which one is "current" for both the ghost-text preview
/// and the list. `CompletionItem` itself is unchanged.
/// 0.22.0: added `CompletionItem.label` — a full, untrimmed display string for the dropdown
/// row, distinct from `insert_text` (which is trimmed to a pure ghost-text suffix and reads
/// confusingly on its own, e.g. "else" instead of "orelse"). Also added
/// `LanguageSupport.VTable.signatureHelp` + `SignatureHelpResult` + `Host.signatureHelpFor` —
/// non-blocking, same convention as `completion`. Backs a VSCode-style parameter-hints popup
/// shown while the cursor sits inside a function call's parens.
/// 0.23.0: pinned `dvui` bump — `proxy_bridge.RenderBridge` gained a `refresh` entry (plugin
/// dylibs draw through this bridge, not the host's real backend, so `dvui.refresh()` called
/// from a plugin's background thread had nothing to actually wake the host's blocking event
/// loop; `ProxyBackend.refresh()` was a silent no-op). Fixes async hover/completion/signature-
/// help results sometimes sitting cached-but-unshown until an unrelated input event.
/// 0.24.0: added `CompletionItem.kind`/`.detail` (+ the new `CompletionKind` enum) — drives an
/// icon and a right-hand type/signature string per dropdown row. Also fixed a real gap this
/// change exposed: `HoverResult`/`DefinitionLocation`/`CompletionItem`/`CompletionKind`/
/// `SignatureHelpResult` were never actually included in the shape fingerprint at all —
/// `VTable`'s hooks only reach them through a slice/optional (a data pointer), which
/// `fingerprint.hashType` deliberately never follows, and none of the five were separately
/// listed in `sdk_boundary_types`. Their field layouts have been unverified since each was
/// introduced; adding `kind`/`.detail` here didn't even move the old fingerprint until they
/// were added to the list. All five are now listed explicitly.
/// 0.25.0: pinned `dvui` bump — `Corner`/`CornerRect` restructured into unit-parameterized
/// `CornerType(units)`/`CornerRectType(units)` (a per-corner `tl`/`tr`/`bl`/`br` rect instead of
/// a flat `x`/`y` pair), and `dragStart`/`dragPreStart` gained an explicit leading
/// `dvui.enums.Button` parameter. Both are reachable from the SDK boundary (`Options.corners`,
/// `DialogOptions`), so the shape fingerprint moves even though no Fizzy-owned type changed.
/// 0.26.0: added `LanguageSupport.VTable.supportsFormat`/`.format` + `Host.canFormatExt`/
/// `formatFor` — non-blocking "can this provider format `ext`" query + a blocking
/// "reformat this document's full contents" call, same supports/do split as
/// `supportsPreview`/`previewPane`. Backs Edit > Format Document (and format-on-save) in the
/// text editor, answered by the `zig` plugin via zls's `textDocument/formatting`.
/// 0.27.0: `DefinitionLocation.byte_offset` replaced with `line`/`character` (LSP
/// `Position`-shaped; `character` a byte count within the line) — `Plugin.VTable.revealPosition`
/// and `workbench.Api.revealPosition` follow suit. A `gotoDefinition` provider previously had to
/// independently re-read and parse the *target* file (often one it otherwise never touches, and
/// can be arbitrarily large — e.g. a standard-library file) just to convert an LSP position into
/// a byte offset, using its own encoding bookkeeping; that conversion is now deferred to the
/// target document's owner, which resolves it against the exact buffer it's about to display.
/// Removes a redundant secondary file read and an independent (and, in the `zig` plugin,
/// previously-suspect) position-conversion path per jump.
/// 0.28.0: `workbench.Api.revealPosition` gained a trailing `open_side: bool` — when the
/// target isn't already open, requests a new grouping/split instead of the current one
/// (mirrors the file tree's "Open to the side"). Ignored when the target is already open
/// anywhere, which just gets focused as before. Backs Shift+Ctrl/Cmd+click and the tooltip's
/// new "Open to Side" button in the text editor.
/// 0.29.0: added `CompletionItem.documentation` — doc-comment/prose text for a candidate
/// (LSP `CompletionItem.documentation`, same shape hover text already draws from), shown in a
/// per-candidate info panel next to the completion dropdown while it's highlighted.
/// 0.30.0: added `LanguageSupport.VTable.resolveCompletionDocumentation` + `Host.
/// resolveCompletionDocumentationFor` — non-blocking "resolve full documentation for candidate
/// `index` from the completion result at this position" query, same supports/do-less pattern as
/// `hover`. Backs LSP `completionItem/resolve`: many language servers (zls included) send
/// completion candidates with an empty placeholder `documentation` up front and only return the
/// real text on a follow-up per-candidate resolve request, so the completion info panel now
/// polls this every frame it's visible instead of trusting the original `CompletionItem.
/// documentation`, which is frequently blank.
/// 0.31.0: added `EditorAPI.VTable.drawMenuItem`/`Host.drawMenuItem` — draws a standard
/// menu-item row (separator, label + keybind, click-detect) inside the currently open menu and
/// returns whether it was clicked, with the actual dvui widget construction happening in the
/// shell's own compiled code rather than the plugin's. `Host.registerMenuSection` draw
/// callbacks (currently just `text`'s "Format Document") must go through this instead of
/// calling `dvui.menuItem()`/`dvui.separator()` directly: dvui tracks "the currently open menu"
/// via a private module-level `var` in `MenuWidget.zig`, and each plugin dylib compiles its own
/// separate copy, so a plugin calling those widgets itself sees its own copy's default `null`
/// even while the host has a menu open — `MenuItemWidget.drawBackground()`'s `menu().?` unwrap
/// on that stale `null` is what crashed `Edit > Format Document` (safety-panics in Debug,
/// silent memory corruption — `0xc0000005` — in ReleaseFast). No dvui fork changes needed; the
/// fix stays entirely on Fizzy's side of the boundary.
pub const recorded_sdk_shape_fingerprint: u64 = 0xb55ebc3e0640a8cd;

comptime {
    if (dylib.sdk_shape_fingerprint != recorded_sdk_shape_fingerprint) {
        @compileError(std.fmt.comptimePrint(
            "SDK boundary shape fingerprint is 0x{x} — bump sdk_version and update " ++
                "recorded_sdk_shape_fingerprint in src/sdk/version.zig",
            .{dylib.sdk_shape_fingerprint},
        ));
    }
}

pub fn sdkVersionTriplet() VersionTriplet {
    return .{
        .major = sdk_version.major,
        .minor = sdk_version.minor,
        .patch = sdk_version.patch,
    };
}

/// True when `required` (plugin min SDK) is satisfied by `host` (this Fizzy build).
pub fn sdkVersionSatisfies(host: std.SemanticVersion, required: std.SemanticVersion) bool {
    if (host.major != required.major) return host.major > required.major;
    if (host.minor != required.minor) return host.minor > required.minor;
    return host.patch >= required.patch;
}

pub fn formatVersion(v: std.SemanticVersion, writer: *std.Io.Writer) !void {
    try writer.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

test "sdk shape fingerprint lock is self-consistent" {
    // If this were out of sync, the module-level comptime block above would already have
    // failed to compile, so asserting it here just guards against future refactors.
    try std.testing.expectEqual(recorded_sdk_shape_fingerprint, dylib.sdk_shape_fingerprint);
}

test "shape fingerprint is decoupled from the app version" {
    // The shape fingerprint is a pure function of the Fizzy-owned SDK boundary types. The app
    // version is not in that set, so a routine app-version bump must leave it — and therefore
    // plugin compatibility — unchanged. This guards the cadence policy in the module doc comment:
    // if someone ever wires an app-version-dependent value into a boundary type's declared shape,
    // the live value drifts from the recorded literal and both this lock and the comptime check
    // above fail, forcing a deliberate `sdk_version` bump rather than a silent one.
    try std.testing.expectEqual(recorded_sdk_shape_fingerprint, dylib.sdk_shape_fingerprint);
}
