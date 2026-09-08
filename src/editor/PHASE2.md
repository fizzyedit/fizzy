# Phase 2: threading `*Editor` — what landed, and what is left

## Landed

`src/fizzy.zig`'s `pub var app` / `pub var editor` are gone. They are now private vars behind
`fizzy.app()` / `fizzy.editor()` accessors, set once via `fizzy.setInstances`.

Editor-scoped code takes an explicit `*Editor` and reaches the allocator through a new
`Editor.gpa` field rather than the `fizzy.app` global:

| Area | Before | After |
|---|---|---|
| `Editor.zig` itself | 413 global refs | 11 |
| Shell path (`Sidebar`, `Explorer`, `Panel`, `Menu`, `Infobar`) | 28 | 0 |
| **Total across `src/`** | **521** | **296** |

The shell path matters most: those are the subsystems a library consumer's `layout()` calls,
and they now receive the editor rather than assuming one.

## Left, and why

The residual splits into two kinds, and only one of them is mechanical.

**1. Callbacks with no context pointer (~75 refs) — needs a design change, not a rename.**

These are invoked by the OS, by dvui, or by a background thread, with no userdata slot to carry
an editor:

- `backend_native.zig` (50) — `GenericDialogCallback`, `showOpenFileDialog` /
  `showSaveFileDialog` / `showOpenFolderDialog` completions, and the native macOS menu
  rebuild/keyequivalent path.
- `Editor.saveAsDialogCallback` (4), `singleton_native.dispatchPath` (4),
  `update_notify.kickInstall` (1).
- `dialogs/*` (44) — `UnsavedClose.onSaveAndClose`, `AppQuitUnsaved.onSaveAllAndQuit`,
  `FileChangedOnDisk.onOverwrite`, `WebSaveAs.callAfter`, `FileTypeDefaults.confirm`.

Fixing these properly means giving each callback a userdata slot and threading the editor
through it. That is a real change to the dialog and native-menu plumbing, not a parameter
addition, so it is deliberately **not** bundled into a refactor commit.

**2. Fizzy-specific singleton modules (~120 refs) — mechanical but low value.**

`PluginStore.zig` (87) is 111 module-level functions over module-level `var` state — a
singleton module rather than a struct. `explorer/settings.zig` (26) and the settings/keybind
trees are the same shape. Threading them is straightforward but touches a lot of surface, and
**none of it is library-critical**: these are fizzy's own UI, and a custom fizzy-based app may
not include them at all.

## Does this block using fizzy as a library?

No, for a single-app-per-process consumer — which is the target. Every consumer gets its
`*Editor` explicitly; the accessors resolve to the one instance the app created. What is still
blocked is *multiple editors in one process*, which nothing in the plan requires.

The honest statement: the ambient-global dependency is now confined to fizzy's own UI modules
and to callbacks that structurally need a context parameter, and both are enumerated above
rather than scattered.
