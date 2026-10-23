# web/: fizzy in a browser

The page and its JavaScript (`index.html`, `web.js`, workers). The Zig half is
`src/backend/WebBackend.zig` and `src/web_main.zig`. `zig build web` builds into `zig-out/web`, and
`scripts/serve-web.sh` serves it on :8765. `main` deploys to fizzyed.it/testapp; fizzyed.it/app is the live SDK release (`web.yml`).

- **The web backend is fizzy's,** begun from dvui's `web.zig`/`web.js` and linked through dvui's
  `custom` backend with dvui's web options passed explicitly (`build/web.zig`). A dvui bump that
  touches dvui's own web backend is merged into these by hand.
- **One upload per frame where possible.** In Firefox (WebGL runs out of process) `bufferData`
  costs ~15–20 µs, about 100× any other GL call. The backend records a frame as one stream and
  flushes only at pixel reads, frame end, or a change to a texture a pending draw uses. Keep it
  that way; call count barely matters, uploads do.
- **Plugins load at runtime as wasm side modules** (`index.html`'s `loadPlugin` →
  `app/store/PluginLoader_web.zig`). To test one: build it with
  `-Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`, copy it to
  `zig-out/web/plugins/<id>/<id>.wasm`, and open `/?plugin=<id>&open=<url>`. `?open=` opens a file
  as an upload, and a zip becomes the root. The page remembers loaded plugins in `localStorage`
  (`fizzy.web_plugins`), so clear that key to reset. The host and plugin must be the same
  optimize class, and an optimized plugin imports libm by name (`ldexpf`), which the host
  exports from `web_main.zig`.
- **A new `export fn` the page calls goes in `build/web.zig`'s `export_symbol_names`.** The wasm
  exports only what that list names. An unlisted one still compiles, and its name even shows in
  the binary, but the page finds `exports.FizzyWebX` undefined and its guard returns silently.
- **Preview the phone shape with `?form=phone|tablet|desktop`.** By design a fine pointer is
  always `.desktop` (`core/form_factor.zig`), and a browser's phone emulation leaves hover on, so
  a desktop browser never shows the mobile shape on its own. The override is read from the URL
  on each load, never stored, and anything else is ignored. The console prints
  `form-factor: coarse=.. hover=.. w=.. h=.. override=.. -> phone|tablet|desktop` at startup and
  whenever the measurement changes: on a device that shows the wrong shape, that line says which
  number failed the rule (`coarse` = `(pointer: coarse)`, `hover` = `(hover: hover)`; w/h are
  `screen.*`). The main-thread loop (Firefox, Safari, `?worker=0`) sends the same message.
- **The heap never shrinks.** The wasm allocator rounds blocks over 64 KB up to a power-of-two
  class and reuses a freed block only within its class, so a large image can step memory from
  tens to hundreds of MB. Before blaming memory for a failed open, read the logged error.
- **The browser pane hides itself.** Behind the chat it is `visibilityState: hidden`, so
  `requestAnimationFrame` runs at ~1 fps and clicks collapse into one frame. Front the tab, or
  dispatch `MouseEvent`s at the canvas ~1 s apart. dvui on the web draws only on request.
- After `zig build web`, a hand-edited copy of `index.html` keeps a stale cache-buster hash and
  the browser serves the old `web.js`. Regenerate the copy.
