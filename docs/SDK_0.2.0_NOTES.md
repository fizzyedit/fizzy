# SDK 0.2.0 — what changed, in plain terms

Draft source for release notes. 0.2.0 is a **compatibility epoch**: plugins built against
0.1.x do not load against it. They are *rebuilt*, not migrated — in most cases that means
re-pinning the SDK and fixing what the compiler points at.

## The one-sentence version

Fizzy stopped being an editor with a plugin API and became a small framework three packages
wide, where the app itself is just another consumer — so a plugin can now contribute *places*,
not only things that go in the places fizzy happened to have.

## What a plugin author sees

**One dependency, shipped on its own.** A plugin pins `fizzy-sdk-v0.2.0.tar.gz` — the `sdk/`
package with `core/` vendored in — instead of a commit of the whole fizzy repo. `sdk.core`
re-exports the shared floor (widgets, anim, dialogs, icons, images, fuzzy, fs), so there is
one name to depend on and no app-only dependencies to leak into a plugin build.

**Four files at the root, and identity is all the manifest holds.** `plugin.zig.zon` carries
`id` / `name` / `version` / `min_sdk_version` / `description` / `tags` and nothing else. What
a plugin *can do* is what its `register(host)` actually registers — there is no capability
list to keep in sync, and no `.zon` sidecar is installed beside the binary.

**Surfaces and regions instead of fixed panes.** A plugin contributes a `Surface` — the one
drawable contribution — tagged with keywords saying where it may go. Regions accept surfaces
by keyword, and the user can move any surface anywhere with the picker; where things ended up
persists. A plugin that wants to lay out its own area declares regions of its own
(`host.region`) and draws the surfaces that land in them. The file tree, the document panes
and the note graph are all this same mechanism, with no privileged path for the built-ins.

**Documents are opaque handles.** A `DocHandle` is `{ptr, id, owner}`; fizzy never looks
inside `ptr`, it routes every operation back to the owning plugin. Opening, saving, closing,
dirty state, "save as", reload-on-external-change — all of it is the owner's vtable.

**Services are versioned and can have more than one provider.** `registerService(T, impl,
owner)` / `getServiceTyped` — a lookup refuses on a version mismatch rather than handing back
a differently-shaped struct, and every lookup is allowed to return null, which is a normal
path with a real fallback rather than an error.

**Settings are a comptime schema.** `sdk.settings.Schema(struct { … })` and fizzy draws the
controls, persists only non-defaults, merges them into one `settings.zon`, watches that file,
and hands the plugin a blob back when it changes on disk. All user config is ZON.

**File types are owned explicitly.** The old numeric priority is gone: the user decides which
plugin owns an extension, the choice persists, and a newly installed plugin asks rather than
silently outranking what is already there.

**User actions are commands.** `"<owner_id>.<action>"`, dispatched to whoever is active, so
keybinds and menus work the same for a built-in and a third-party plugin.

## What ships alongside it

**The web is a real target.** The same plugin source builds as a wasm side module that the
fizzy web app fetches and links at runtime, and registers through the same checks a desktop
dylib passes: ABI fingerprint, SDK version, declared id. Two differences worth stating plainly.
The page cannot verify the SHA-256 the registry publishes, so a web install trusts the URL the
way a desktop install trusts a signed-off dylib; and nothing can unlink a module once linked, so
an update links the new build beside the old one and hands the id over, leaving the previous
code resident but owning nothing until the tab closes.

**The store is the way plugins ship.** Author repo → release CI (six desktop targets plus
best-effort web) → registry → in-app store. Compatibility is checked by a structural ABI
fingerprint at load, so a binary is valid for exactly one (Zig, dvui, SDK contract) tuple and
a mismatched one is refused rather than crashing.

**Fizzy is an example of its own framework.** `app/` is the runtime an application switches
on; `src/` is just fizzy's own contributions. An app built on fizzy picks a layout shape or
copies the closest one and edits it — shapes are ordinary code over the public API, not a
configurable engine.

## Upgrading a 0.1.x plugin

1. Re-pin to the `fizzy-sdk-v0.2.0.tar.gz` release asset.
2. Slim `plugin.zig.zon` to identity; delete any `root.zig` / package-root hub.
3. Replace pane/tab contributions with `Surface`s and keywords; declare your own regions if
   you lay out your own area.
4. Move preferences to `sdk.settings.Schema`.
5. Tag a release; the CI builds every target and the store picks it up.
