# Three packages: core, sdk, app

Agreed shape, not yet executed. Written first because the move is large and the *reasoning* is
the part worth keeping — the file lists below will drift, the rule they follow should not.

## The rule

Two audiences, one shared floor:

| package | audience | may depend on |
|---|---|---|
| **core** | both | dvui, std. Nothing of fizzy's. |
| **sdk** | plugin authors | core |
| **app** | app authors | core, sdk |

`fizzy` itself becomes the **first consumer of `app`**, not the place `app` lives. That is the
whole test: if fizzy can be written against `app` with no privileged reach-through, an app author
can write theirs.

Why `core` is a package and not just "shared code": a plugin is a dylib and an app is an exe, and
both need the same widgets, the same fuzzy matcher, the same paths. Anything both sides draw with
lives there — `Tabs` and `Split` already do, and that was not a coincidence.

## Why the split is exactly here

`sdk` is a **hard boundary**: it crosses a `dlopen`, so its layout is in the ABI fingerprint and
it must never gain an app dependency. CLAUDE.md already spells out why a lazy dep in the root zon
is not enough — Zig unpacks cached lazy URL deps into every consumer, so a plugin depending on the
root package grows a Velopack tree it never asked for.

`app` is a **soft boundary**: an ordinary Zig package that may depend on whatever an application
needs, Velopack included.

Today there is no `app` package at all. Its contents are scattered through `src/editor/`, which is
why nobody would think to look there — you would be reaching into fizzy's own source to find the
framework.

## What goes where

### core — shared floor (mostly already right)

Stays as `core/`: `dvui.zig` and `widgets/` (Tabs, Split, TreeWidget, CanvasWidget, Paned,
Reorder, FloatingWindow), `math/`, `fs`, `paths`, `fuzzy`, `lsp/`, `Fling`, `FileTable`.

### sdk — the plugin contract (already a package)

Stays: `src/sdk/**` behind `sdk/build.zig`. `Surface`, `Plugin`, `Host`, `DocHandle`, `EditorAPI`,
`keywords`, `settings.Schema`, `services/`, `dylib.zig`.

### app — the framework (new)

Moved out of `src/editor/`:

- **Layout** — `layout/` entire: the region/split API (`Frame`, to be renamed), the shipped shapes
  (`ide`, `minimal`, `studio`, `linear`), `chrome.zig`, `panes/`.
- **App state** — `Editor.zig`, renamed. It is the running application: plugin host, documents,
  settings, themes, window state, recents, layout state. Not an editor.
- **Plugin loading** — `PluginLoader.zig`, `PluginLoader_stub.zig`, `PluginStore.zig`,
  `plugin_repo_asset.zig`, `store_icon.zig`. Opt-in per the app.
- **Watching** — `FolderWatcher.zig`, `DocumentWatcher.zig`, `SettingsWatcher.zig`,
  `folder_events.zig`. Opt-in per the app.
- **Settings** — `Settings.zig`, `SettingsTree.zig`, `SettingsMigration.zig`,
  `SettingsPluginsZon.zig`, `SettingRow.zig`, `PluginSettingsPane.zig`, `FileTypeSettings.zig`.
- **Keybinds** — `Keybinds.zig`, `KeybindSettings.zig`, `keymap/`.
- **Chrome an app of any shape wants** — `dialogs/`, `CommandPalette.zig`, `Menu.zig`,
  `menu_model.zig`, `Infobar.zig`, `Recents.zig`, `RecentsMigration.zig`, `Theme.zig`,
  `OutputLog.zig`.
- **Platform** — `src/backend/` entire: window geometry, singleton lock, native/web backends,
  auto-update, file association.
- **Build API** — `build/` entire: `app.zig`, `exe.zig`, `package.zig`, `velopack.zig`, `web.zig`,
  `plugins.zig`. This is what gives an app installers and packaging for free.

### fizzy — the application (what is left)

`src/App.zig` (entry), its themes, its identity, its chosen shape, its bundled plugin list, and
the chrome that is genuinely fizzy's rather than any app's: `explorer/`, `Sidebar.zig`,
`OutputPanel.zig`, `file_glyphs.zig`, `readme.zig`.

## Open questions, deliberately not decided here

- **`Frame`'s new name.** It is the handle a shape declares regions with, and "frame" already
  means one rendered frame in immediate mode. `Layout` is the obvious candidate and collides with
  the module; the module can be renamed instead.
- **`Editor`'s new name.** `App` is right and taken by `src/App.zig`, which is the dvui entry.
  Splitting those two is the fix: the entry point is not the application.
- **Does a plugin get regions?** Today it cannot — `Frame` needs the app state, so the workbench
  builds its document splits out of raw boxes and a split. That is why "pane" exists as a word. If
  the region API moved to `core`, panes would just be regions and the term would disappear.

## Order

Each stage leaves the tree building and every check green. No stage renames *and* moves the same
file — a rename that hides a behaviour change is exactly the diff nobody can review.

1. Split `src/App.zig` into the dvui entry and the application state, freeing the name `App`.
2. `Editor` → `App`. Mechanical, no behaviour.
3. `Frame` → its new name, with the module renamed to suit.
4. Create the `app` package and move the layout + build API into it; fizzy consumes it.
5. Move the rest of the framework list; whatever will not move without reaching into fizzy is a
   bug in the seam, and gets fixed rather than exempted.
