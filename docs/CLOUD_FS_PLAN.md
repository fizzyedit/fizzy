# Cloud filesystems: Google Drive as a mounted `Fs`

The goal: the web build signs into Google Drive and gets the same file explorer the native
build has over a local folder — create, rename, delete, move, open, save — with edits landing in
the cloud as they are made. Native gets the same thing beside its local disk. Dropbox/OneDrive
later are another backend behind the same seam, not another explorer.

Two repos are involved:

- **fizzy** — everything provider-agnostic: the mount contract (`core.vfs`: `Fs`, `Mem`,
  `http.Transport`, zip), the disk behind it (`LocalFs`), the mount table and routing
  (`FileTable`, `MountIo`), the two transports, a generic web OAuth popup, and the built-in
  `archive` plugin. Nothing in fizzy names Google.
- **`fizzyedit/zig-drive`** (`~/dev/fizzyedit/zig-drive`) — the Google Drive plugin, an
  ordinary third-party plugin (pixi's shape): the Drive v3 client over `core.vfs`, OAuth, and
  the sign-in UI. Natively a store plugin; fizzy's web build links it in by directory
  (`web_plugin_dirs`) because a browser cannot load plugins at runtime.

## Design decisions (settled)

1. **Path-addressed, not id-addressed.** Everything in fizzy is a path: `DocHandle` surface ids
   (`<owner>.doc:<path>`), `core.FileTable` listings keyed by directory, `sdk.services.files`,
   `openFilePath`, extension→owner routing, recents, watchers. An id-addressed `Fs` (what
   zig-drive started as) forces a second code path into every one of those. So `Fs` speaks paths,
   and the Drive backend keeps the path→id map to itself. In fizzy a cloud path is
   self-identifying by scheme: `gdrive://<account>/Notes/todo.md`; the local disk is "the empty
   scheme". An `Fs` itself sees only the part after the mount, rooted at `/` — the host strips
   `gdrive://<account>` — so zig-drive never learns fizzy's naming and `Mem` is reusable as-is.
   Duplicate names inside one Drive folder (Drive allows them) resolve first-listed-wins.
2. **Async, completion-based.** wasm32-freestanding is single-threaded and cannot block on
   `fetch`, so a synchronous `readFile() -> []u8` is unimplementable on the very target this
   exists for. Every `Fs` op is start → complete-later; completions are delivered on the caller's
   thread from a per-frame `pump()`. Native backends may run the request on a thread (or
   complete inline), the web backend completes from the JS callback exports. This is the shape
   fizzy already uses for `FileLoadJob`, `pollWebFileIo` and `web_fetch`.
3. **A path index that fills lazily, then deltas.** The Drive backend lists a directory once
   (`files.list` with `'<id>' in parents`) and records every child's id/kind/size/mtime under
   its path, so `stat` and path→id resolution for anything beneath a listed directory cost no
   further requests; resolving a cold path lists its ancestors in turn. Per-directory listing is
   the base because it works under every scope — with `drive.file` and a picked folder it is
   not guaranteed that descendants are granted, and a whole-drive `files.list` would hide that.
   `changes.list` with a stored page token is the "watcher" and maps directly onto
   `FileTable.invalidateListing` / `noteFileModified`; a whole-tree snapshot is an optimisation
   layered on the same index later. Only file *bytes* hit the network per-file.
4. **The `drive` plugin is out of tree** (`fizzyedit/zig-drive`), like every provider will be.
   The web build, which cannot `dlopen`, links it in as app-level build data — the same
   mechanism an app built on fizzy uses to bundle its own plugins — and that is the only place
   fizzy's repo names it.
5. **Tokens live in the host, never in zig-drive.** Native: desktop-client OAuth with PKCE, system
   browser + `std.Io.net` loopback, refresh token persisted in `settings.zon`. Web: Google
   Identity Services token client in `index.html` (Google will not do a browser PKCE code
   exchange for a Web client without a secret) — 1-hour access tokens, silent re-request. Both
   hand Zig a bearer string; zig-drive sees `Authorization: Bearer …` and nothing else.

## Roadblocks found up front

| Roadblock | Status |
|---|---|
| `Fs` is id-addressed | Fix in zig-drive (step 1). |
| `Fs` and `http.Transport` are synchronous | Fix in zig-drive (step 1). Unimplementable on wasm otherwise. |
| `fizzy_web_fetch` is GET-only, no headers, no body | Generalize to `(method, url, headers, body)` in `web/index.html` + `app/store/web_fetch.zig` (step 4). |
| Native HTTP / TLS | Already works: `std.http.Client` in `app/store/plugin_repo_asset.zig`. |
| Native OAuth loopback | `std.Io.net.IpAddress.listen` + `std.http.Server` exist in 0.16; `dvui.openURL` opens the browser. |
| Web OAuth | GIS token client, JS side. No refresh token on web — accept re-prompt after an hour. |
| Windows path joins | `std.fs.path.sep_str` would produce `gdrive://acct\Notes\x.md`. Add a scheme-aware join to `core.paths`; audit the 8 `isAbsolute` call sites. |
| Document owners write disk themselves | `text`/`image` `Document.zig` call `cwd().writeFile`. Add a bytes-based save hook beside the existing `loadDocumentFromBytes` so owners never touch storage (step 3). Third-party owners (pixi) need the same change to save to a cloud path. |
| Atlas on a cloud vault | Out of scope here: atlas is SQLite-backed and walks the vault with `std.Io.Dir`. The mount layer is the prerequisite; atlas needs its own pass. |
| Google Docs / Sheets | Not bytes. Listed with `kind = .file` but reads return `error.NotBinary`; the explorer shows them, opening explains why. |

## Steps

Each step leaves both repos building and tested. Order is chosen so the first three are
verifiable without a Google account.

### 1. zig-drive: reshape `Fs` (path-addressed, async) — DONE

Landed as zig-drive `pxvpqtnz`. 18 tests, `check-wasm` links.

- `Fs` vtable over `/`-rooted, `/`-separated paths within the mount. Ops: `listDir`, `stat`,
  `readFile`, `writeFile`, `createFile`, `mkdir`, `rename` (covers move: a different parent in
  `new_path`), `remove`. Every op takes a
  completion callback + ctx and returns a `Job` handle; `cancel(job)`; `pump()` drains
  completions. Errors split `Unauthorized` (refresh and retry) from `Forbidden`.
- `http.Transport` gets the same treatment: `request(req, on_done)` + `pump()`.
- `Mem` backend completes inline (in `pump`) so tests stay synchronous-looking.
- Drive backend: lazy path index, byte read/write (`files.get?alt=media`, `files.update`
  media upload), metadata-only `files.create` for empty files and folders (no multipart needed:
  fizzy's `createFile` creates empty and `writeFile` fills), `files.update` with
  `addParents/removeParents` + `name` for rename/move, `trashed=true` for remove.
  `changes.list` polling follows once the mount exists in fizzy (step 5 drives it).
- Canned-transport tests port over; add path resolution, duplicate-name and write-path tests.

### 2. fizzy: mount table + `FileTable` routing — DONE

- `core.vfs` (`core/vfs/`): the contract, `Mem`, `http.Transport`, zip. Fizzy's own; the SDK
  has no dependency for it.
- `core.LocalFs`: the disk behind `vfs.Fs`; on wasm every op is `Unsupported`.
- `core.FileTable`: `mount`/`unmount`/`resolve`/`pump`; `listDir` on a miss asks the path's
  filesystem and pumps it, so the disk still answers in the call while a cloud mount returns
  null until its completion installs the listing and fires `Env.refresh`. Mutations complete
  through a callback (`FilesService` moved its document bookkeeping into it). `isDir` on a
  mount answers from the parent's cached listing.
- `Host.mount(prefix, fs)` / `Host.unmount(prefix)` (fingerprint bumped, SDK still 0.2.0).
- `Editor.tick` pumps the table before anything draws.
- Search indexes through the mount too (`FileTable.IndexJob`): the walk is a chain of
  `listDir` completions, so the disk still finishes inside the `search` call while a cloud root
  fills across frames — results grow as listings land, `indexing()` says when it is still
  going. One index covers several roots at once (the disk beside a mount), each `search(root)`
  ranking only its own. Ending a session cancels an unfinished walk. A cloud session re-walks
  on every new search; the snapshot/`changes.list` work in decision 3 is what makes that cheap.
- (since resolved) cross-mount moves copy then remove; the workbench draws mounts as roots;
  joins are mount-aware.

### 2b. a zip archive as a mount (PhysicsFS-style) — DONE

- zig-drive `zip.zig`: by-hand reader over bytes (`std.zip.Iterator` wants a `File.Reader`;
  the archive arrives as bytes on the web; std's own `EndRecord.findBuffer` does not compile)
  and a store-method writer; `Mem.generation` for dirty tracking.
- `plugins/archive` (built-in, static in exe + web): owns `.zip` as a *document type*, so the
  existing open paths do the work — the web "Open Files" picker, a double-click in the tree,
  argv. Registering the document mounts its tree at `zip://<name>`; the tab is the mount's
  handle (name, dirty state); saving the tab packs the tree back (to the file natively, as a
  download on the web via the new host-side download for any owner with `documentBytes`);
  closing it unmounts.
- The workbench draws every mount as a root beside the project folder — one filter, one tree
  code path, per-root menus (a mount has no "close project"/"reveal") — on the web too, where
  the empty state now says a `.zip` opens as a folder. Its four "does this exist" probes and
  its `Dir.walk` now go through `FileTable.exists`/listings, which is what let the tree code
  compile for wasm at all.
- Verified in the browser end to end: upload `demo.zip` → root appears → open `hello.txt`
  from inside it in the text editor → edit → ⌘S writes into the mount and the archive tab goes
  dirty → ⌘S on the archive tab → the download is a valid zip with the edit and the empty
  directory intact, tab back to clean. Natively: `fizzy demo.zip` mounts and lists it.
- Fixed along the way: a document tab titled by `basename(surface id)` showed
  `owner.doc:name` for any web upload (no separator in a bare name).

### 3. fizzy: documents read/write through the mount — DONE

- `src/editor/MountIo.zig`: `openFilePath` on a mounted path reads through the mount and opens
  from the bytes (`loadDocumentFromBytes`, which every owner already has for the browser
  picker) — on the web build too, where the disk path bails. Save, Save All, Save As and the
  quit save-all serialize through two new SDK hooks, `documentBytes` + `documentWritten`, and
  the host writes through the mount; the owner hears back only when the write lands (Save As
  adopts the path there). `Editor.docSaving` counts an in-flight mount write so a quit waits
  for it. An owner without `documentBytes` gets one toast rather than a silent no-op.
- (since resolved) the host writes **every** document whose owner has `documentBytes`, disk
  included — one save path per backend, the disk answering inline. `owner.saveDocument` is
  the fallback for owners without the hooks and can only reach the disk. Disk opens keep
  `FileLoadJob` (a worker thread), a performance path that ends in the same
  `loadDocumentFromBytes`. `MountIo` became `DocumentIo`.
- `core.paths` is mount-aware (`mountPrefixLen`, `normalize`, `normalizeJoin`,
  `isNormalizedAbsolute`): a `gdrive://` path is normalized after its prefix and never
  joined onto the cwd. argv dispatch hands a mount path straight to the file sink instead of
  `openDirAbsolute`-asserting on it (found by running it).
- `text` implements the hooks (format-on-save applies); `image` is read-only and needs
  neither. Verified in-app with a temporary `Mem` mount: `fizzy mem://demo/notes/hello.txt`
  opened the document with its contents. The write half is covered by the `LocalFs`/`Mem`
  tests, not yet driven in-app.
- Not done: `reloadDocument` / the document watcher are disk-only (a mount has no watcher until
  `changes.list`); conflict detection on a mount is therefore "last write wins" for now.

### 4. the two `http.Transport`s — DONE

- `core.transport.Web` (wasm): a new `fizzy_web_request` import in `index.html` — method,
  `Name: value` header lines, body — answered through `FizzyWebRequestAlloc/Ready/Failed`
  with the status. The store's GET-only `fizzy_web_fetch` is untouched. The exports are kept
  live by a reference in `Editor` so the page has them whether or not a cloud plugin is
  bundled.
- `core.transport.Native`: one `std.http.Client.fetch` per request on its own thread, results
  parked under a spinlock and delivered from `pump`; `wake` (the host's refresh) runs the next
  frame. Tested against a loopback `std.http.Server` (`fizzy-native-transport-tests`): method,
  auth header, body and status round-trip; cancel joins the worker and leaks nothing.
- The web transport's first real exercise is the Drive plugin's first `files.list` (step 5).

### 5. the Drive plugin (`fizzyedit/zig-drive`) — BUILT, first contact with Google made

- `fizzyedit/zig-drive/plugin.zig`: settings (desktop client id + secret, web client id, root folder id, and
  the refresh token / account Sign In writes back), commands `drive.sign_in` /
  `drive.sign_out`, a File-menu section (in-app + native), and a per-frame `beginFrame` that
  pumps the plugin's own requests, polls the loopback and refreshes the token two minutes
  before expiry. A saved refresh token signs in silently at the next launch.
- Native flow (`src/oauth.zig`): PKCE (S256), the system browser, a one-shot loopback
  `std.http.Server` on `127.0.0.1:<port>` that checks `state` and answers the browser tab, the
  token exchange and refresh as form POSTs through `core.transport.Native`, then
  `about?fields=user` to name the mount `gdrive://<email>`. The listener is tested against a
  real `std.http.Client` (correct and forged `state`).
- Web flow: Google's implicit grant through `core.transport.WebOAuth` — a provider-agnostic
  popup that lands on fizzy's `oauth-callback.html` and posts the redirect's query/fragment
  back to wasm. `prompt=none` re-request before expiry. The same `about` → mount path follows.
- First real run (desktop): sign-in completed and the refresh token was saved; the `about`
  call then returned 403 *API not enabled* — README step 2 had been skipped. `Full Drive
  access` setting added because `drive.file` shows an empty drive on the desktop.
- Not yet: the explorer's web empty state still says "Open Files", not "Connect Google
  Drive" (the File menu has it). Writes carry a `modifiedTime` precondition; a conflict is a toast and a dirty
  document, not a silent overwrite.
- Publisher setup, step by step: `~/dev/fizzyedit/zig-drive/README.md`.

### 6. Verification

- `zig build test` in both repos; `zig build check-wasm` in zig-drive; `zig build check-web`,
  `test`, `test-sdk-version` in fizzy after the vtable change.
- Native end-to-end against a real Drive: sign in, explorer shows the granted folder, create /
  rename / move / delete / open / edit / save, confirm in drive.google.com.
- Web end-to-end on `zig build web` served locally with the localhost JS origin registered on
  the Web OAuth client.

## The 2026-09 review (`docs/REVIEW_2026-09.md` §5), folded in

Fixed, with tests where the review named one: **D1** in-flight listing vs. `forget` (no `.?`
on the index; a forgotten ancestor fails that listing), **D2** cancel during delivery
(`Completions.drain` marks a later job of the batch skipped; the Drive client, `Mem`,
`LocalFs`, both transports honour it), **D3** refresh storm (failure backs off a minute; a
400/401 refresh signs out), **D4** a failed mount listing is remembered for the TTL, **D6**
edits during an upload stay dirty (`savedBytes` records the op id), **D7** Save As onto a
mount creates then writes (`Mem.writeFile` is create-or-replace too), **D9** cancel never joins
a blocking fetch (the worker owns an orphaned job; tested at <100 ms with a held connection),
**D10** the loopback accepts until the request carrying `state` (idle/favicon connections are
404'd; tested) and closes once, **D11** zip offsets in `u64` with a 1 GiB inflate budget
(tested), **D12** `Mem.rename` into its own subtree refused, **D13** `isDir` on a mount root,
**D17** unique archive prefixes, the header CR/LF injection, the same-folder Drive rename
(Google rejects `addParents == removeParents`). The layering/path-pin/GIS-outside-the-frame
points went away with the move out of tree.

Also fixed since: **D15** a mount's completions land only on the host's per-frame pump, never
inside a draw-time call (the disk still answers in the call); **D8** `Env.unmounting(prefix)`
lets `MountIo` cancel loads and saves against a mount before it goes (tested); **D5** a
document whose save did not land stays open and aborts the quit; **D14** `core.paths.join` is
mount-aware and every join in the tree and the files service uses it.

Since then: `settings.Value` has `.secret` (the pane masks it; the Drive plugin marks the client
secret and refresh token), and the native transport shares one `std.http.Client` (connection
pool, one TLS handshake per host).

Since then: `Host.getSecret`/`setSecret` — the seam for credentials, backed today by
`app/Secrets.zig` (`<config>/secrets`, `key=base64` lines, created `0600`, written whole and
renamed into place; tested). The Drive plugin keeps its refresh token there and moves an old
one out of settings on load. OS keychain backends slot in behind the same two calls.

Still open, in the order they should be taken:
- Keychain / libsecret / DPAPI backends for `Secrets` (the file store is the fallback).
- (done) `vfs.Fs.readFile` returns the file's modified time with the bytes and `writeFile`
  takes `if_unmodified_ms`; `MountIo` remembers each open document's and passes it on save
  (a stat after a successful write refreshes it). The Drive client checks Drive's live
  `modifiedTime` before uploading; `Mem` and `LocalFs` compare theirs. A `Conflict` leaves the
  document dirty with a toast; the next save from the user overwrites. Proper reload/merge UI
  is still to come.
- (done) a move across mounts (`FileTable.MoveJob`) copies the tree entry by entry, then
  removes the source; nothing is removed until every copy landed. Tested disk↔`Mem` both ways.
- (done) Google's own folder picker is the folder chooser on both targets (`api_key` in
  `credentials.zon`): the web build opens the plugin's `web/picker.html` (copied to
  `plugins/drive/` by the web build, reached via `WebOAuth.pageUrl`) through the same popup
  round trip as sign-in; the desktop serves the same page from the loopback listener and
  opens it in the system browser. The picked folder re-roots the mount
  (`gdrive://<account>/<folder>`); "Open Google Drive" re-roots at My Drive. The in-app
  `FolderChooser` dialog is gone.
- (done in pixi's working tree, uncommitted there) pixi implements `documentBytes`/
  `documentWritten` over its existing encoders, so a `.pixi`/`.png` on a mount saves. atlas,
  ghostty and zig own no documents.

## Out of scope for this pass

Dropbox/OneDrive backends (the seam is the deliverable; a second backend is the proof it
holds), atlas on a cloud vault, offline edit queueing, shared-drive (`drives.list`) support,
Google-Docs export.
