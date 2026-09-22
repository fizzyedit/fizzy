# Naysayer review, 2026-09-22

Read-only review of bookmark `fizzy-lib` (parent `e542b18c`, "web: a plugin updates in the session — the old module stays, inert"), measured against the code on that commit. The September 21 review (`docs/REVIEW_2026-09.md`) is treated as already written; this one covers what landed after it, plus the claims in the docs that no longer match the tree. Line numbers are from this commit and will drift.

The side-module idea itself is sound: one shared memory, table indices where the desktop uses function pointers, the same fingerprint and `register` sequence. The trouble is the session-update layered on top of a loader that cannot unlink, and a store tick that still assumes a plugins directory.

---

## Verdict

Do not treat in-session web update as done. The desktop update path, in the same file, refuses to discard unsaved documents and only drops the offer after the new build has loaded. The web path force-unloads first, reports success when the fetch has merely been *started*, skips the SHA-256 the registry already computed, and the page remembers the URL before the host has accepted the module. A refused build is then what the next visit loads. Disable, uninstall, and the update window never run on the web at all, because `PluginStore.tick` returns before the queue that applies them.

The simpler design is the one the page comment already half-admits: an update changes which URL the next load fetches, then the page reloads. Keeping the old module resident is a reasonable constraint. Pretending the id has moved over inside the same session is what creates the data-loss and the stuck-URL bugs, and it duplicates a loader sequence the desktop already has.

---

## 1. Web update throws away the running plugin, then calls that success

`Editor.updateWebPlugin` unloads with `force = true` and only then asks the page to fetch:

```1604:1608:src/editor/Editor.zig
pub fn updateWebPlugin(editor: *Editor, id: []const u8, url: []const u8) WebLoadError!void {
    if (comptime builtin.target.cpu.arch != .wasm32) return error.NotUnloadable;
    if (editor.app.host.pluginById(id) != null) try editor.unloadPlugin(id, true);
    try editor.loadWebPlugin(id, url);
```

`force = true` skips the dirty-document check. Documents the plugin owns are closed. The desktop completion path, forty lines above the web early-return in `PluginStore.tick`, says the opposite on purpose: `app.update(job.id, false)`, and on `DirtyDocuments` the new file stays on disk so Retry can apply it after the user saves (`PluginStore.zig` around the `downloaded` arm).

`loadWebPlugin` returns as soon as `PluginLoader.begin` has handed the URL to JavaScript. `applyWebUpdate` treats that return as the update having landed and removes the row:

```946:952:app/store/PluginStore.zig
fn applyWebUpdate(id: []const u8, url: []const u8) void {
    app.updateFromUrl(id, url) catch |err| {
        reportError("could not update '{s}': {s}", .{ id, @errorName(err) });
        return;
    };
    dropPendingUpdate(id);
```

If the fetch fails, the compile fails, or `loadAndRegister` rejects the fingerprint, the running plugin is already gone and the offer is already gone. The failure is a log line from `WebPluginRequest.arrived`. There is no Retry, because there is no row and there is no download job (`isInstalling` reads `jobs`, which the web install path never fills).

A load that should be abandoned still completes. `arrived` has no generation: uninstall or a second update cannot cancel the request already in `pending`, and a late `FizzyWebPluginReady` will register whatever it linked.

---

## 2. The page remembers a build the host has not accepted

`PluginLoader_web.remember` and the comment in `WebPluginRequest.arrived` say the URL is stored only after `register` returns ok, so a refused build cannot greet the user on every later visit. `loadPlugin` in `web/index.html` writes `localStorage["fizzy.web_plugins"]` immediately after `FizzyWebPluginReady`, before that callback runs. Any module that instantiates is remembered, including one whose fingerprint, SDK version, or declared id the host is about to reject.

The next visit calls `requestUrlPlugins`, which loads that map with no look at `.plugins.<id>.enabled`. `FizzyWebPluginRequest` does not consult `isPluginDisabled` either (the desktop scan at `Editor.zig` around line 622 does). So:

- A rejected update becomes the URL every future visit tries, and fails the same way.
- Disable cannot survive a reload even if the queued action were applied, because nothing on the web load path reads the flag, and nothing forgets the URL on disable. `forget` runs only from `uninstallPlugin`.

`?plugin=` is also unordered relative to `?open=`. The comment above the open loop says the file is fetched after the plugins so the owner may already be registered. Both loops start their fetches immediately. A zip can be opened by the fallback editor, or refused, because the side module that owns the extension is still compiling.

`FizzyWebPluginRequest` interpolates the query id into `plugins/{id}/{id}.wasm` without `App.isValidPluginId`. An id is allowed to contain `..` and slashes. That is a same-origin path, so it cannot leave the site, but it can name any wasm the site happens to host.

---

## 3. The store's buttons on the web queue work the frame never runs

`PluginStore.tick` on wasm pumps the catalog, READMEs, and icons, then returns:

```1275:1281:app/store/PluginStore.zig
pub fn tick() void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        if (catalog) |*c| c.pump(web_fetch);
        Readme.pump();
        StoreIcon.pump();
        syncReadmeCenter();
        return;
    }
```

Everything after that return is the desktop. In particular it never reaches:

- `pending_actions` — Enable, Disable, Uninstall, and the auto-update toggle all append here (`queueSetEnabled`, `queueUninstall`, `queueSetAutoUpdate`) and are applied only in this loop.
- `autoUpdateTick` — the once-per-session update check and the "Plugin updates" window.

The card's Update button calls `applyWebUpdate` directly, so that one control does start a fetch. Enable, Disable, and Uninstall do not. Re-enable would still be the wrong function if the queue were drained: `setPluginEnabled` calls `loadUserPluginById`, which returns `error.NotUnloadable` on wasm before it looks for a URL. The URL lives only in the page's `localStorage`, and Zig has no way to ask for it back.

`uninstalledCatalog` still returns an empty slice on wasm, with a comment that the store is browse-only. `queueInstall` on wasm calls `installFromUrl`. The home-page offers and the comment describe a store that the Plugins tab has already left behind.

---

## 4. The web install path does not check the hash the registry published

Desktop `startDownloadUrl` passes `sha256` into `download.zig`, which refuses the bytes before they are written. Web `queueInstall` and `applyWebUpdate` pass only `dl.url`. `loadPlugin` does `fetch` + `WebAssembly.compile` on whatever that URL returns. TLS protects the transport. A registry entry whose URL was edited, or a `localStorage` map rewritten by any script on the origin, is executed as a plugin with the host's memory, the host's function table, and every host export copied into `env` (the loop over `host.exports` in `loadPlugin`).

That trust model matches a desktop dylib, and it should be said in one place. It does not match "the store verifies SHA-256", which is still true only on the desktop.

Two tighter holes in the same loader, before the module even runs:

- `readDylinkNeeds` trusts `memorySize` and `memoryAlign`. `FizzyWebPluginAlloc` then `rawAlloc`s that size. A side module (or a file that merely has a `dylink.0` section) can ask for a huge reservation. `1 << needs.memoryAlign` is a JavaScript shift; an alignment above 31 becomes a nonsense value passed into `Alignment.fromByteUnits`. Cap the size, require the alignment to be a small power of two, and do it before allocating.
- `tableAlign` is parsed and ignored. `tableBase` is `functionTable.length` with no padding. If wasm-ld emits a non-zero table alignment, relocations land on the wrong slots. Either honor it or refuse the module when it is not 0 or 1.
- There is no byte cap on `?open=` either. The whole body is copied into the wasm heap via `FizzyWebPluginAlloc`. A link of the form `?open=<huge url>` is enough; the plugin does not have to be malicious.

`fizzy_web_request` is an arbitrary method, headers, and body, with no size cap on the response. Cookies are not included (`fetch` defaults to same-origin credentials), which is the right default. The function is still a proxy with the user's network position. Fine for a trusted plugin; worth not handing to a module that skipped the hash check.

`fizzy_web_oauth_open_page` turns plugin-supplied HTML into a blob URL on this origin and accepts `postMessage` from that origin. A plugin that can already read linear memory gains script access to `localStorage`, including `fizzy.file:*` (settings, recents, layout, keybinds) and `fizzy.web_plugins`. Same trust boundary. Do not document it as a sandbox.

---

## 5. `Secrets.set` on the web frees the value it just stored

`Secrets` is documented as memory-only on the web, and `save` returns `error.Unsupported` there. `set` inserts the new buffer into the map and then calls `save`. The `errdefer` that frees that buffer is still armed:

```50:64:app/Secrets.zig
pub fn set(self: *Secrets, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return self.remove(key);
    self.load();
    const v = try self.gpa.dupe(u8, value);
    errdefer self.gpa.free(v);
    // ... put v into self.values ...
    try self.save();
}
```

On wasm `save` always errors, so every `set` returns `Unsupported` and frees `v` while the map still holds it. The next `get` hands the caller a dangling slice. A second `set` of the same key `memset`s and `free`s that dangling pointer. Drive-style OAuth (`WebOAuth`, landed the day before this review) is the caller this will hit as soon as a plugin stores a refresh token.

`set` should return `error.Unsupported` before mutating the map, or keep the value and skip `save` when there is no file. The `errdefer` has the same shape on desktop if `save` fails after a successful `put`: the map retains a freed buffer there too.

---

## 6. `core.fs` on the web reports writes that did not happen

`core/fs.zig` `write` calls `fizzy_web_storage_set` and returns. The JavaScript implementation swallows `localStorage.setItem` failures (quota, private mode) with `console.warn`. Settings, recents, layout, and keybinds all go through this seam now, which is the right single seam, and a full `localStorage` will look like a successful save. `fizzy_web_storage_set` needs a status the Zig side can turn into `error.NoSpaceLeft`.

---

## 7. Simplicity and reuse

**One update story.** Remember the new URL only after the host accepts it, leave the running module alone, reload the page. Dirty documents get the same prompt the desktop already has, because the unload happens on the way out of the page rather than as a side effect of starting a fetch. The "old module stays resident" paragraph, the force flag, `updateFromUrl`, and the success-before-arrival drop all go away. In-session swap is worth it only after the new module has registered and the old one's contributions are the only thing still pointing at it — which is the desktop order, not a second one.

**One loader sequence.** `PluginLoader_web.loadAndRegister` is a second copy of the fingerprint, version, id, inject, and `register` steps in `PluginLoader.zig`. They have already drifted in comments (who is allowed to remember). A `lookup(T, name)` is the whole difference; the sequence should be one function. `WebDynLib` already has that lookup.

**`pluginEntryPoints` is listed twice**, in the same order, in `web/index.html` and `WebDynLib.entry_names`. A missing or reordered export is a silent mismatch: `FizzyWebPluginReady` copies indices by position. Generate one list, or compare names.

**`Shape.apply` is the right size.** A static tree of `region` and `split`, and an explicit refusal to grow conditionals, matches the copy-don't-configure rule. The test named "a depth-first walk numbers every place once" does not call `apply` or `place`; it counts children with a second walk. It cannot catch two regions sharing an `id_extra`. The split's `id_extra` is the counter value the following child then consumes. That happens to be unique per call site today because `region` and `split` use different `@src()` lines. A test that runs `apply` against a headless `Layout` would lock it.

**Dead branch still in the frame.** `Editor.tick` sets `chrome` to `fill` on both arms of the maximized check (`const chrome = if (...) fill else fill`). The September 21 review already noted it. It is still the value published into every dialog.

---

## 8. Docs that are now wrong

| Where it says | What the tree does |
|---|---|
| `WebPluginRequest.arrived` and `PluginLoader_web.remember`: the URL is stored only once the host accepts the build | `loadPlugin` calls `rememberPlugin` as soon as the module is linked |
| `updateWebPlugin`: a refused build leaves the next visit on the one that worked | The page has already overwritten `fizzy.web_plugins`, and the working module was force-unloaded before the refusal |
| `uninstalledCatalog`: wasm is browse-only | `queueInstall` links the release URL |
| `SDK_0.2.0_NOTES.md`: the web plugin "fetches and links at runtime — same registration path as a desktop dylib" | Registration is the same function shape. Install skips SHA-256, disable and uninstall never run, and update force-closes documents |
| `SDK_0.2.0_NOTES.md`: "six desktop targets plus best-effort web" | The host key `web-wasm32` exists (`registry/compat.zig`). Whether release CI emits that artifact is a different repo; the notes read as if the store path were finished |
| `Surface.zig` doc: keyword overrides live in `settings.zon` | Placement is `layout.zon` assignments. The settings sentence is the pre-assignment model |
| `LIB_CHECKPOINT.md` header: last updated 2026-09-16, bundled plugins "workbench, text, image, markdown, shared" | The bookmark has since gained the web loader, `archive`/`drive`, accounts, `core.work`, and `-Dapp-layout=<file>.zon`. The phase narrative (regions, workbench panes) is still the right history. The header is a cold-start trap |
| `docs/REVIEW_2026-09.md` §2.3: wasm install is gated off, `hostKey()` is `unknown-unknown`, `web_fetch` is too small for a plugin | Install is on, the key is `web-wasm32`, and the plugin body is fetched by `loadPlugin`, not `web_fetch`. The fingerprint and unload findings in §3 were not re-closed by this work (see below) |
| `CLAUDE.md` bundled list | Still omits `archive` and `drive`. The checkpoint's "trust `ls plugins/`" rule is the one that is right |

`PLUGIN_MANIFEST_PLAN.md` is a July log that still says "External plugin repos still need pin + reshape" in the banner, then records R7 as landed. Harmless as a log, misleading as a status page. It should not be the document a new session treats as the plan; `LIB_CHECKPOINT.md` is, and its date is the problem.

---

## 9. Still open from the September 21 review (re-checked, not assumed)

These were not the subject of the last day's commits. They are still true, and the new web path makes two of them sharper.

- **The fingerprint still does not name `Surface`.** `sdk/src/dylib.zig` `sdk_boundary_types` lists `FileTable`, `Setting`, `CompletionItem`, and the wikilink types, each with a comment about slices `hashTypeShape` does not follow. `Surface` is reached the same way (`regionMatching`'s slice, workbench reading fields off it) and is absent. So are `Host.Painter`, `Host.FileKind`, `Host.ServiceEntry`. Adding a field still shifts every installed plugin's layout without moving the fingerprint.
- **Partial `register` still closes over a live registration on the desktop, and now on the web too.** `loadAndRegister` maps a non-ok status to `RegisterRejected` and returns. Contributions already pushed into `Host` stay. On the web there is not even a `dlclose` to make the subsequent crash obvious; the half-registered plugin keeps drawing.
- **Live unload still does not sweep image-owned callbacks.** `unregisterPlugin` does drop selections whose ids no longer resolve, and `setSelectionForKey` stores the registry's own `id` slice. That part of the old use-after-free is addressed. Mounts, dvui `dataSet` deinit functions, and dialog `displayFn`s were not. On the web those callbacks remain callable, because the module is never unmapped. "Inert" is true only for contributions `unregisterPlugin` actually removed.
- **`@errorName` on plugin failures** was cleaned up on the keymap rebuild path (the log now says "see the plugin's own log"). Other sites in `Editor.zig` still print `@errorName` for host-side errors, which is fine. Do not extend that cleanup into a shared error enum; the checkpoint's "not worth it" note is right.

---

## 10. What is solid and should stay

- Shared linear memory and a growable table, with entry points handed back as indices. That is the dylib model, and a second wasm instance per plugin would break every `*Host` and every slice the SDK passes today.
- Fingerprint check before `register`, and id check against the id the host asked for.
- `Shape` as data for the static case only, with the zig file as the escape hatch. The comment at the top of `app/layout/Shape.zig` is the design, and it is the right one.
- Secrets kept out of `settings.zon` on the desktop (0600 file, wiped on free). The web bug is the error path, not the split.
- One `core.fs` seam for the small config files, so plugin and app code do not grow `wasm32` branches. It needs a real error on quota, not a second storage API.
- The region/keyword model, versioned services, and the stable mapped copy on desktop. None of the findings above are a reason to reopen those.

---

## Suggested order

1. `Secrets.set`: fail before inserting on wasm, and do not `errdefer`-free a buffer the map owns. Small, and it is a use-after-free on a credential.
2. Stop remembering from `loadPlugin`. One writer, after `register` returns ok. On rejection, leave the previous URL in place.
3. Make web update "remember, then reload" until the new module can be registered before the old one is torn down. Pass `force = false` if any in-session unload remains. Drop the offer from `arrived` on success, and put it back on failure.
4. Drain `pending_actions` inside the wasm arm of `PluginStore.tick`. Wire enable to `loadWebPlugin` with the remembered URL, and consult `isPluginDisabled` in `FizzyWebPluginRequest`.
5. Hash the bytes in the page before `WebAssembly.compile`, with the `sha256` the row already carries. Cap `memorySize` and `?open=` bodies.
6. Add `Surface` (and the other by-slice host types) to `sdk_boundary_types`. The fingerprint may still move freely under unpublished 0.2.0.
7. Refresh the `LIB_CHECKPOINT.md` header and correct `SDK_0.2.0_NOTES.md` so a release note does not claim the web store path is the desktop path.
