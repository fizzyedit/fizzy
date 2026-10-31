// fizzy's web app on a page: the editor's wasm, drawn by dvui's `web.js` (`Dvui`) on a canvas of
// the page's, with the `fizzy` and `env` imports it needs from the page, the plugins it loads at
// runtime, and on Chromium the editor in a worker (`fizzy-worker.js`). `index.html` is fizzy's own
// page, which reads its options from its URL; an app built on fizzy runs it on a page of its own
// with `new Fizzy({ canvas, ... }).run()`.
//
// Stamped by the build (`build/web.zig`): the hash of what it loads, and the storage name
// (`-Dweb-storage`).

// Pixel deltas are CSS pixels. Only discrete notches are normalized to ticks.
// The backend uses 80 points per tick for continuous input on the web.
export function wheelTicks(ev, state) {
  const lowestBatch = [...state.lowestBatch];
  const events = [];
  for (const [i, delta] of [[0, ev.deltaX], [1, ev.deltaY]]) {
    if (delta === 0) continue;
    let ticks;
    let trackpad = 0;
    if (ev.deltaMode !== 0) {
      lowestBatch[i] = Math.min(Math.abs(delta), lowestBatch[i]);
      const notch = ev.deltaMode === 1 && Math.abs(delta) % 4 === 0 ? 4 : 3;
      ticks = -delta / (ev.deltaMode === 1 ? notch : lowestBatch[i]);
    } else if (i === 1 && ev.wheelDeltaY === -3 * delta) {
      trackpad = 1;
      ticks = -delta / 80;
    } else if (i === 1 && ev.wheelDeltaY && ev.wheelDeltaY % 120 === 0) {
      // Windows display scaling changes deltaY but leaves a notch at 120.
      ticks = ev.wheelDeltaY / 120;
    } else if (Math.abs(delta) % 100 === 0) {
      ticks = -delta / 100;
    } else {
      trackpad = 1;
      ticks = -delta / 80;
    }
    events.push({ axis: i, ticks, trackpad });
  }
  return { events, state: { lowestBatch } };
}

// One wheel reader per canvas, for the worker path and the page's own loop. The classifier's
// batch minima reset after a second without wheel input: the user may have switched devices.
// A trackpad pinch is the pinch listener's.
export function wheelInput(canvas, send, now = () => Date.now()) {
  let state = { lowestBatch: [99999, 99999] };
  let lastMs = now();
  canvas.addEventListener("wheel", (ev) => {
    if (ev.ctrlKey && ev.deltaMode === 0) return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
    const ms = now();
    if (ms - lastMs > 1000) state.lowestBatch = [99999, 99999];
    lastMs = ms;
    const result = wheelTicks(ev, state);
    state = result.state;
    for (const { axis, trackpad, ticks } of result.events) send(axis, trackpad, ticks);
  }, { capture: true, passive: false });
}

// Pointer input is batched before crossing the worker boundary. Times are absolute
// performance-clock milliseconds; subtracting the receiver's origin preserves latency.
export function pointerInput(canvas, send, clockOrigin = performance.timeOrigin, done = () => {}) {
  canvas.style.touchAction = "none";
  const slots = new Map();
  let mouseButtons = 0;
  const mods = (e) => (e.metaKey << 3) | (e.altKey << 2) | (e.ctrlKey << 1) | (e.shiftKey << 0);
  const handle = (kind, ev) => {
    const touch = ev.pointerType === "touch";
    if (touch && kind === 8) {
      const slot = Array.from({ length: 10 }, (_, i) => i).find((i) => !Array.from(slots.values()).includes(i));
      if (slot === undefined) return;
      slots.set(ev.pointerId, slot);
    }
    if (touch && !slots.has(ev.pointerId)) return;
    if (kind === 8) canvas.setPointerCapture(ev.pointerId);
    const rect = canvas.getBoundingClientRect();
    let samples = kind === 10 ? ev.getCoalescedEvents?.() : null;
    if (!samples?.length) samples = [ev];
    const events = [];
    for (const e of samples) {
      const x = (e.clientX - rect.left) / rect.width;
      const y = (e.clientY - rect.top) / rect.height;
      const time = e.timeStamp + clockOrigin;
      if (touch) events.push({ a: [kind, slots.get(ev.pointerId), 0, x, y], time });
      else {
        events.push({ mouse: true, x, y, mods: mods(e), time });
        // Pointer moves also carry intermediate presses and releases in a mouse chord.
        const buttons = kind === 9 ? 0 : e.buttons;
        const changed = mouseButtons ^ buttons;
        for (const [bit, button] of [[1, 0], [2, 2], [4, 1], [8, 3], [16, 4]]) {
          if (changed & bit) events.push({ a: [buttons & bit ? 2 : 3, button, mods(e), 0, 0], time });
        }
        mouseButtons = buttons;
      }
    }
    send({ type: "input", events });
    if (kind === 9) { slots.delete(ev.pointerId); done(); }
  };
  for (const [name, kind] of [["pointerdown", 8], ["pointermove", 10], ["pointerup", 9], ["pointercancel", 9]]) {
    canvas.addEventListener(name, (ev) => handle(kind, ev), { capture: true });
  }
  // A touch tap ends with compatibility mouse events whose `mousedown` focuses the tabindex'd
  // canvas after `pointerup` has focused the hidden input, closing the keyboard again.
  // Cancelling `touchstart` and `touchend` suppresses them; pointer events are unaffected.
  for (const name of ["touchstart", "touchend"]) {
    canvas.addEventListener(name, (ev) => ev.preventDefault(), { capture: true, passive: false });
  }
}

// The on-screen keyboard's height over the page's bottom edge, posted as `{type: "inset", bottom}`
// and never as a `size`: the canvas keeps its size, so nothing clears or re-lays out, and the app
// lays out above the keyboard itself. Chrome on Android (a secure context) has the VirtualKeyboard
// API: with `overlaysContent` the browser neither resizes nor pans for the keyboard. Elsewhere
// (iOS Safari) the visual viewport says how much of the layout viewport the keyboard covers.
// Returns the current inset reader for the hidden input to stay above.
export function keyboardInset(win, send, canvas = null, owns = () => true) {
  let bottom = 0;
  let rest = null;
  let savedHeight = null;
  const rect = () => canvas?.getBoundingClientRect() ?? { bottom: win.innerHeight, height: win.innerHeight };
  const post = (next) => {
    next = owns() ? Math.max(0, Math.round(next)) : 0;
    if (next === bottom) return;
    bottom = next;
    send({ type: "inset", bottom });
  };
  const vv = win.visualViewport;
  const viewport = win.document?.querySelector('meta[name="viewport"]')?.content ?? "";
  const overlays = /(?:^|[,;])\s*interactive-widget\s*=\s*overlays-content\s*(?:[,;]|$)/i.test(viewport);
  // A resizing viewport and VK geometry can use different origins. Measure only the
  // visual viewport unless the page explicitly requests an overlay (or has no VV API).
  const vk = overlays || !vv ? win.navigator?.virtualKeyboard : null;
  const update = () => {
    const current = rect();
    const base = rest ?? current;
    const edge = vk ? (vk.boundingRect.height ? vk.boundingRect.y ?? win.innerHeight - vk.boundingRect.height : Infinity)
      : vv ? vv.height + vv.offsetTop : win.innerHeight;
    const next = owns() ? Math.max(0, base.bottom - edge) : 0;
    // resizes-content pages shrink the CSS canvas as well. Keep the focused canvas's layout
    // height until the keyboard closes, so both dvui loops see the same backing-store size.
    if (canvas && next > 0 && current.height < base.height) {
      if (savedHeight === null) savedHeight = canvas.style.height ?? "";
      canvas.style.height = `${base.height}px`;
    } else if (savedHeight !== null && next === 0) {
      canvas.style.height = savedHeight;
      savedHeight = null;
    }
    const closed = bottom > 0 && next === 0;
    post(next);
    if (closed) rest = null;
  };
  win.addEventListener?.("focusin", () => {
    if (owns() && bottom === 0) rest = rect();
    update();
  });
  win.addEventListener?.("focusout", () => win.setTimeout?.(update, 0));
  win.addEventListener?.("resize", update);
  win.addEventListener?.("orientationchange", () => { rest = null; update(); });
  if (vk) {
    if (overlays) vk.overlaysContent = true;
    vk.addEventListener("geometrychange", update);
  } else if (vv) {
    vv.addEventListener("resize", update);
    vv.addEventListener("scroll", update);
  }
  return () => bottom;
}

import { Dvui, TextInput } from "./web.js?cache-buster=TEMPLATE_HASH_WITH_PADDING__ITS_64_BYTES_LONG_THE_SAME_AS_SHA256";

// The name this build files what it keeps in the browser under: its own files, the plugins it
// remembers and their cached bytes. Every copy of the app served from one site shares the
// browser's storage for it, so a test build beside the real one (fizzyed.it/testapp/ beside
// /app/) is built with a name of its own (`zig build web -Dweb-storage=...`) and never reads or
// overwrites the real one's settings, layout or plugins. Stamped by the build.
const buildStorageName = "__FIZZY_WEB_STORAGE__";
// iPhone Safari has no Fullscreen API for pages (iPad does); there, "Add to Home Screen"
// is the way to lose the address bar (manifest.webmanifest).
const fullscreenSupported = !!(document.fullscreenEnabled && document.documentElement.requestFullscreen);

/** The editor's compiled wasm by URL, shared by every copy on the page: one download, one compile. */
const compiledEditors = new Map();

/**
 * The compiled editor at `url`, started on the first ask and shared after. Null when it could not
 * be fetched or compiled (a later copy tries again); the caller then fetches it itself.
 * @param {string} url
 * @returns {Promise<WebAssembly.Module | null>}
 */
function compiledEditor(url) {
  let compiled = compiledEditors.get(url);
  if (!compiled) {
    compiled = WebAssembly.compileStreaming(fetch(url)).catch((err) => {
      console.warn("fizzy: compiling the editor early failed; the copy fetches it", err);
      compiledEditors.delete(url);
      return null;
    });
    compiledEditors.set(url, compiled);
  }
  return compiled;
}

/** The copy whose canvas or input was last used, which gets keys that land on the page itself. */
let activeCopy = null;

/**
 * @typedef {object} FizzyOptions
 * @property {HTMLCanvasElement} canvas - Where the editor draws and takes its input.
 * @property {string} [storage] - A name of this copy's own, as `-Dweb-storage` takes them
 *   (`[a-z0-9_-]{1,64}`). Its settings, layout, files and installed plugins are filed under it,
 *   beside the build's, so a copy embedded in a page (fizzyed.it's examples) never reads or
 *   overwrites the real app's, and two embeds on one page never each other's.
 * @property {boolean} [persist] - False: nothing this copy changes outlives the page. Its
 *   settings, layout, files and installed plugins live in memory only and start from defaults on
 *   every load, for an embed that should stay as the page set it up (fizzyed.it's homepage).
 *   Default true: the browser's `localStorage`.
 * @property {boolean} [worker] - Run the editor in a worker (true) or on the page's thread (false).
 *   Default: in a worker on Chromium only. Never in a worker with `imports`.
 * @property {"desktop" | "tablet" | "mobile"} [form] - The form factor to take, in place of the
 *   device's (`core.platform.formFactor()`). Anything else is ignored.
 * @property {string} [glassBench] - Visit-local glass benchmark scene.
 * @property {number|string} [glassRepeat] - Glass benchmark repeat factor (1..32).
 * @property {HTMLElement} [fullscreenElement] - What View › Toggle Full Screen shows full screen.
 *   Default: the canvas's parent, so an embed fills the screen and the page around it does not.
 * @property {string[]} [plugins] - Ids of plugins to load from `plugins/<id>/<id>.wasm` beside the
 *   app once it is up, each in place of an installed one of the same id: how a developer tries a
 *   build.
 * @property {string[]} [open] - URLs of files to open once the plugins are asked for, as an upload
 *   would (a zip becomes the root folder).
 * @property {string} [show] - A path inside what `open` opened, to open from it.
 * @property {string[]} [demos] - Demos to play: a bundled one by name (`tour`), or a tape's URL
 *   (`.zon`, or `.tape` for the binary form).
 * @property {string} [tape] - The URL of a shared tape to play. The plugins it needs come from the
 *   store, and the page shows only the tape.
 * @property {Record<string, WebAssembly.ModuleImports>} [imports] - Import namespaces of the app's
 *   own, beside `dvui`, `fizzy` and `env`. The editor then runs on the page's thread, where they
 *   can be called.
 * @property {(instance: WebAssembly.Instance) => void} [onInstance] - Called with the editor's
 *   instance once it exists, on the page's thread.
 * @property {() => void} [onReady] - Called once the editor is up.
 * @property {(message: string) => void} [onError] - Called with what to tell the user when the
 *   editor cannot start.
 */

export class Fizzy {
  /** @param {FizzyOptions} opts */
  constructor(opts) {
    if (!opts || !(opts.canvas instanceof HTMLCanvasElement)) throw new TypeError("fizzy: `canvas` must be a canvas element");
    if (opts.storage !== undefined && !/^[a-z0-9_-]{1,64}$/.test(opts.storage)) {
      throw new RangeError(`fizzy: storage name "${opts.storage}" is not [a-z0-9_-]{1,64}`);
    }
    /** @readonly */
    this.opts = opts;
    /** What this copy files its storage under: the build's name, or that and `opts.storage`. */
    this.storageName = opts.storage ? buildStorageName + "~" + opts.storage : buildStorageName;
  }

  /** Start the editor. Once per `Fizzy`. */
  run() {
    const opts = this.opts;
    const storageName = this.storageName;
    let focusEpoch = 0;
    window.addEventListener("focus", () => {
      focusEpoch++;
      if (dvuiApp) dvuiApp.requestRender();
    });
    const fileKey = (path) => path === "fizzyedit.person" ? path : storageName + ".file:" + path;
    const persists = opts.persist !== false;
    const onReady = opts.onReady ?? (() => {});
    const onError = opts.onError ?? (() => {});
    // What to load, open and play once the editor is up; the worker is sent it as it is.
    const startup = {
      plugins: opts.plugins ?? [],
      open: opts.open ?? [],
      show: opts.show ?? "",
      demos: opts.demos ?? [],
      tape: opts.tape ?? "",
    };
    const memoryStore = () => {
      const m = new Map();
      return {
        getItem: (k) => (m.has(k) ? m.get(k) : null),
        setItem: (k, v) => { m.set(k, String(v)); },
        removeItem: (k) => { m.delete(k); },
        key: (i) => [...m.keys()][i] ?? null,
        get length() { return m.size; },
      };
    };
    const store = (() => {
      if (!persists) return memoryStore();
      // A browser with its site data blocked throws on the bare name.
      try { return window.localStorage; } catch (_) { return memoryStore(); }
    })();
    // Ask, once a thing worth keeping is kept, for storage the browser will not clear under
    // pressure; refused is fine, and a copy that keeps nothing never asks.
    const askToPersist = () => {
      if (persists && navigator.storage && navigator.storage.persist) navigator.storage.persist().catch(() => {});
    };

    function hasWebGl() {
      const probe = document.createElement("canvas");
      return !!(probe.getContext("webgl2") || probe.getContext("webgl"));
    }

    /** Wait until layout has settled so clientWidth/Height are correct. */
    function waitForLayout() {
      return new Promise((resolve) => {
        requestAnimationFrame(() => requestAnimationFrame(resolve));
      });
    }

    // Markdown remote images (and SVG badges) load through the browser: Zig calls
    // `fizzy_web_image_request`, and the page writes RGBA back through `FizzyWebImageAlloc` /
    // `FizzyWebImageReady` for dvui to draw like any other texture.
    const utf8 = new TextDecoder();
    const utf8encode = (s) => new TextEncoder().encode(s);
    let wasmInstance = null;

    // The one function table, created here so it can grow: a plugin loaded at runtime (a
    // wasm side module, see `loadPlugin`) brings functions of its own, and its function
    // pointers are indices into this table. The main module imports it (`--import-table`).
    const functionTable = new WebAssembly.Table({ initial: 4096, element: "anyfunc" });

    // The `fizzy` import namespace. Memory is always the main module's (a plugin shares it);
    // the *callbacks* go to whichever instance made the call — a plugin exports its own
    // `FizzyWebRequestReady` and friends, with state of its own behind them — so this is a
    // factory over the instance to call back into.
    function oauthPopup(inst, url, cleanup) {
      const done = () => { if (cleanup) cleanup(); };
      const fail = () => {
        done();
        inst.exports.FizzyWebOAuthFailed();
        if (dvuiApp) dvuiApp.requestRender();
      };
      let settled = false;
      const onMessage = (ev) => {
        if (ev.origin !== location.origin || !ev.data || typeof ev.data.fizzyOAuth !== "string") return;
        settled = true;
        window.removeEventListener("message", onMessage);
        done();
        const bytes = utf8encode(ev.data.fizzyOAuth);
        const ptr = inst.exports.FizzyWebOAuthAlloc(bytes.length);
        if (!ptr) return fail();
        new Uint8Array(wasmInstance.exports.memory.buffer, ptr, bytes.length).set(bytes);
        inst.exports.FizzyWebOAuthResult(ptr, bytes.length);
        if (dvuiApp) dvuiApp.requestRender();
      };
      window.addEventListener("message", onMessage);
      const popup = window.open(url, "fizzy-oauth", "popup,width=520,height=680");
      if (!popup) {
        window.removeEventListener("message", onMessage);
        return fail();
      }
      const watch = setInterval(() => {
        if (settled) return clearInterval(watch);
        if (popup.closed) {
          clearInterval(watch);
          window.removeEventListener("message", onMessage);
          fail();
        }
      }, 500);
    }

    const fizzyImports = (target) => ({
        fizzy_web_image_request(id, urlPtr, urlLen) {
          const inst = target();
          if (!inst) return;
          const url = utf8.decode(new Uint8Array(wasmInstance.exports.memory.buffer, urlPtr, urlLen));
          // Pixels or nothing: an image has to be a texture to sit under a menu, be frosted
          // behind a flyout and take the theme's corners. A host that does not let the page
          // read its pixels is read through the proxy instead, which adds the header.
          loadImagePixels(url).catch(() => loadImagePixels(imageProxy + encodeURIComponent(url))).then((imageData) => {
            const bytes = new Uint8Array(
              imageData.data.buffer,
              imageData.data.byteOffset,
              imageData.data.byteLength,
            );
            const ptr = inst.exports.FizzyWebImageAlloc(bytes.length);
            if (!ptr) {
              inst.exports.FizzyWebImageFailed(id);
            } else {
              new Uint8Array(wasmInstance.exports.memory.buffer, ptr, bytes.length).set(bytes);
              inst.exports.FizzyWebImageReady(id, ptr, bytes.length, imageData.width, imageData.height);
            }
            if (dvuiApp) dvuiApp.requestRender();
          }).catch(() => {
            inst.exports.FizzyWebImageFailed(id);
            if (dvuiApp) dvuiApp.requestRender();
          });
        },
        // A full request for `core.transport.Web`: any method, headers as `Name: value`
        // lines, a body, and the status back with the bytes. Cloud drives speak through
        // this; `fizzy_web_fetch` below stays the GET-only path the store uses.
        fizzy_web_request(id, methodPtr, methodLen, urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen) {
          const inst = target();
          if (!inst) return;
          const mem = wasmInstance.exports.memory.buffer;
          const method = utf8.decode(new Uint8Array(mem, methodPtr, methodLen));
          const url = utf8.decode(new Uint8Array(mem, urlPtr, urlLen));
          const headers = new Headers();
          for (const line of utf8.decode(new Uint8Array(mem, headersPtr, headersLen)).split("\n")) {
            const at = line.indexOf(": ");
            if (at > 0) headers.append(line.slice(0, at), line.slice(at + 2));
          }
          // Copied: the wasm buffer may move before fetch reads it.
          const body = bodyLen > 0 ? new Uint8Array(mem, bodyPtr, bodyLen).slice() : undefined;
          const fail = () => {
            inst.exports.FizzyWebRequestFailed(id);
            if (dvuiApp) dvuiApp.requestRender();
          };
          fetch(url, { method, headers, body, cache: "no-store" }).then((res) => {
            return res.arrayBuffer().then((buf) => {
              const bytes = new Uint8Array(buf);
              const ptr = inst.exports.FizzyWebRequestAlloc(id, bytes.length);
              if (!ptr) return fail();
              if (bytes.length > 0) new Uint8Array(wasmInstance.exports.memory.buffer, ptr, bytes.length).set(bytes);
              inst.exports.FizzyWebRequestReady(id, res.status, ptr, bytes.length);
              if (dvuiApp) dvuiApp.requestRender();
            });
          }).catch(fail);
        },
        // A web OAuth round trip for whichever plugin asks (core/transport/WebOAuth.zig): open
        // the provider's URL in a popup and hand back what it redirected to
        // oauth-callback.html with. Provider-agnostic on purpose.
        // The popup round trip: open `url`, wait for the page it ends on to post its
        // location back (`oauth-callback.html`, or a page of the plugin's own that does the
        // same), fail if the popup closes first. Bound to the instance that asked, whose
        // `FizzyWebOAuth*` exports carry the answer.
        fizzy_web_oauth_open(urlPtr, urlLen) {
          const inst = target();
          if (!inst) return;
          const url = utf8.decode(new Uint8Array(wasmInstance.exports.memory.buffer, urlPtr, urlLen));
          oauthPopup(inst, url);
        },
        // The same round trip through a page the plugin *carries* rather than one served
        // beside the app: `html` becomes a same-origin blob URL (so its `postMessage` to
        // the opener passes the origin check), with `hash` as the fragment the page reads.
        // How a plugin loaded at runtime brings its own picker.
        fizzy_web_oauth_open_page(htmlPtr, htmlLen, hashPtr, hashLen) {
          const inst = target();
          if (!inst) return;
          const mem = wasmInstance.exports.memory.buffer;
          const html = utf8.decode(new Uint8Array(mem, htmlPtr, htmlLen));
          const hash = utf8.decode(new Uint8Array(mem, hashPtr, hashLen));
          const blobUrl = URL.createObjectURL(new Blob([html], { type: "text/html" }));
          oauthPopup(inst, blobUrl + (hash.length ? "#" + hash : ""), () => URL.revokeObjectURL(blobUrl));
        },
        // Load a plugin built for the web (see `loadPlugin` below) and report back through
        // `FizzyWebPluginReady` / `FizzyWebPluginFailed` on the host.
        fizzy_web_plugin_load(req, idPtr, idLen, urlPtr, urlLen, shaPtr, shaLen) {
          const inst = wasmInstance;
          if (!inst) return;
          const mem = wasmInstance.exports.memory.buffer;
          const id = utf8.decode(new Uint8Array(mem, idPtr, idLen));
          const url = utf8.decode(new Uint8Array(mem, urlPtr, urlLen));
          const sha256 = shaLen ? utf8.decode(new Uint8Array(mem, shaPtr, shaLen)) : "";
          loadPlugin(req, url, id, sha256).then(() => {
            if (dvuiApp) dvuiApp.requestRender();
          }).catch((err) => {
            console.error("fizzy: plugin load failed:", url, err);
            reportPluginFailed(inst, req, err);
            if (dvuiApp) dvuiApp.requestRender();
          });
        },
        // View › Toggle Full Screen. The request runs a frame after the key press or click
        // that asked for it, which is still inside the browser's user-activation window.
        fizzy_web_toggle_fullscreen() {
          toggleFullscreen();
        },
        // False where a page cannot go full screen (Safari on iPhone), so the command is disabled.
        fizzy_web_fullscreen_supported() {
          return fullscreenSupported ? 1 : 0;
        },
        // `Clock.real` for the app's `Io` (src/backend/web_io.zig).
        fizzy_web_now_real_ms() {
          return Date.now();
        },
        // `core.fs` on the web: the app's own small files (settings.zon, recents.zon,
        // keybinds.zon) live in localStorage, keyed by the path the app would have used.
        fizzy_web_focus_epoch() { return focusEpoch; },
        fizzy_web_storage_get(keyPtr, keyLen, bufPtr, bufLen) {
          const key = fileKey(utf8.decode(new Uint8Array(wasmInstance.exports.memory.buffer, keyPtr, keyLen)));
          let value = null;
          try { value = store.getItem(key); } catch (_) {}
          if (value === null) return 0xffffffff;
          const bytes = utf8encode(value);
          if (bytes.length <= bufLen) new Uint8Array(wasmInstance.exports.memory.buffer, bufPtr, bytes.length).set(bytes);
          return bytes.length;
        },
        fizzy_web_storage_set(keyPtr, keyLen, valPtr, valLen) {
          const mem = wasmInstance.exports.memory.buffer;
          const key = fileKey(utf8.decode(new Uint8Array(mem, keyPtr, keyLen)));
          const value = utf8.decode(new Uint8Array(mem, valPtr, valLen));
          try { store.setItem(key, value); } catch (err) { console.warn("fizzy: could not store", key, err); }
        },
        fizzy_web_storage_remove(keyPtr, keyLen) {
          const key = fileKey(utf8.decode(new Uint8Array(wasmInstance.exports.memory.buffer, keyPtr, keyLen)));
          try { store.removeItem(key); } catch (_) {}
        },
        // What the page remembers for an id, so the host can load it again after a disable
        // without a round trip through the store. Same copy-into-buffer shape as the storage
        // shims: returns the length needed, or `max` when there is nothing.
        // Which catalog shard this build installs from, for the download proxy's allowlist.
        fizzy_web_plugin_fingerprint(fpPtr, fpLen) {
          pluginFingerprint = utf8.decode(new Uint8Array(wasmInstance.exports.memory.buffer, fpPtr, fpLen));
        },
        fizzy_web_plugin_remembered_url(idPtr, idLen, bufPtr, bufLen) {
          const mem = wasmInstance.exports.memory.buffer;
          const id = utf8.decode(new Uint8Array(mem, idPtr, idLen));
          const url = rememberedPlugins()[id];
          if (typeof url !== "string") return 0xffffffff;
          const bytes = utf8encode(url);
          if (bytes.length <= bufLen) new Uint8Array(wasmInstance.exports.memory.buffer, bufPtr, bytes.length).set(bytes);
          return bytes.length;
        },
        fizzy_web_plugin_forget(idPtr, idLen) {
          forgetPlugin(utf8.decode(new Uint8Array(wasmInstance.exports.memory.buffer, idPtr, idLen)));
        },
        // Which build to bring back next visit. Written once a module has registered, so a
        // build the host refused is never what the page asks for again.
        fizzy_web_plugin_remember(idPtr, idLen, urlPtr, urlLen) {
          const mem = wasmInstance.exports.memory.buffer;
          rememberPlugin(
            utf8.decode(new Uint8Array(mem, idPtr, idLen)),
            utf8.decode(new Uint8Array(mem, urlPtr, urlLen)),
          );
        },
        fizzy_web_oauth_callback_url(bufPtr, bufLen) {
          const inst = target();
          if (!inst) return 0;
          // Resolved against the document, not the origin: the app is not always at the
          // root — fizzyed.it serves it from /app/ — and an origin-rooted guess names a page
          // that is not there, which Google rejects as redirect_uri_mismatch before anything
          // else happens. `pageUrl` takes this URL's directory for plugin pages too, so both
          // follow wherever the app is deployed.
          const bytes = utf8encode(new URL("oauth-callback.html", document.baseURI).href);
          if (bytes.length <= bufLen) new Uint8Array(wasmInstance.exports.memory.buffer, bufPtr, bytes.length).set(bytes);
          return bytes.length;
        },
        // Byte fetch for the store catalog / READMEs / icons — no rasterize, just GET.
        fizzy_web_fetch(id, urlPtr, urlLen) {
          const inst = target();
          if (!inst) return;
          const url = utf8.decode(new Uint8Array(wasmInstance.exports.memory.buffer, urlPtr, urlLen));
          fetch(url, { cache: "no-cache" }).then((res) => {
            if (!res.ok) throw new Error("http " + res.status);
            return res.arrayBuffer();
          }).then((buf) => {
            const bytes = new Uint8Array(buf);
            const ptr = inst.exports.FizzyWebFetchAlloc(bytes.length);
            if (!ptr) {
              inst.exports.FizzyWebFetchFailed(id);
            } else {
              new Uint8Array(wasmInstance.exports.memory.buffer, ptr, bytes.length).set(bytes);
              inst.exports.FizzyWebFetchReady(id, ptr, bytes.length);
            }
            if (dvuiApp) dvuiApp.requestRender();
          }).catch(() => {
            inst.exports.FizzyWebFetchFailed(id);
            if (dvuiApp) dvuiApp.requestRender();
          });
        },
    });

    // Plugins the store installed on an earlier visit, by id → URL. The page's memory, since
    // the app has no settings file here; forgotten on uninstall.
    const rememberedKey = storageName + ".web_plugins";
    function rememberedPlugins() {
      try { return JSON.parse(store.getItem(rememberedKey) || "{}"); } catch (_) { return {}; }
    }
    function rememberPlugin(id, url) {
      try {
        const all = rememberedPlugins();
        // An update names a new build: the old one's bytes are no longer anybody's.
        if (all[id] && all[id] !== url) dropPluginBytes(all[id]);
        all[id] = url;
        store.setItem(rememberedKey, JSON.stringify(all));
      } catch (_) {}
      keepPluginBytes(url);
    }
    function forgetPlugin(id) {
      try {
        const all = rememberedPlugins();
        if (all[id]) dropPluginBytes(all[id]);
        delete all[id];
        store.setItem(rememberedKey, JSON.stringify(all));
      } catch (_) {}
    }

    // ---- installed plugins' bytes, kept between visits --------------------------------------
    //
    // Every visit used to download every installed plugin again — `no-store`, and for a release
    // asset (no CORS header) a failed direct fetch and then the proxy — before it could compile
    // one. The bytes of a build the host has accepted now live in Cache Storage (localStorage
    // holds ~5 MB of strings; a plugin is megabytes of binary), keyed by its URL. A store URL
    // names one release and never changes under it, so a hit is simply the bytes: no network,
    // and an update is a new URL — `rememberPlugin` drops the old entry, `forgetPlugin` the
    // uninstalled one. A dev build served beside the app (`opts.plugins`) is rebuilt at the same
    // URL, so it is never kept.
    // Under the build's name, not the embed's: a store URL names one release, so its bytes
    // serve every embed alike, and a plugin installed in one is not downloaded again for the next.
    const pluginCacheName = buildStorageName + "-plugins-v1";
    const pluginCacheAvailable = typeof caches !== "undefined";
    // Verified bytes of builds that have linked but not yet registered, by URL: the host
    // remembers a build only once it has registered (see the end of `loadPlugin`), and only
    // then are they kept.
    const unkeptPluginBytes = new Map();
    function keepablePluginUrl(url) {
      if (!pluginCacheAvailable || !url) return false;
      try {
        const u = new URL(url, document.baseURI);
        return (u.protocol === "https:" || u.protocol === "http:") && u.origin !== location.origin;
      } catch (_) {
        return false;
      }
    }
    async function cachedPluginBytes(url) {
      if (!keepablePluginUrl(url)) return null;
      try {
        const hit = await (await caches.open(pluginCacheName)).match(url);
        return hit ? await hit.arrayBuffer() : null;
      } catch (_) {
        return null;
      }
    }
    function keepPluginBytes(url) {
      const bytes = unkeptPluginBytes.get(url);
      unkeptPluginBytes.delete(url);
      if (!bytes || !keepablePluginUrl(url)) return;
      caches.open(pluginCacheName)
        .then((c) => c.put(url, new Response(bytes, { headers: { "content-type": "application/wasm" } })))
        .catch((err) => console.warn("fizzy: could not keep plugin", url, err));
      askToPersist();
    }
    function dropPluginBytes(url) {
      if (!keepablePluginUrl(url)) return;
      caches.open(pluginCacheName).then((c) => c.delete(url)).catch(() => {});
    }
    // Start reading the remembered builds out of the cache now, while the editor itself is
    // still downloading and starting — by the time it asks for them they are in hand.
    const warmPluginBytes = new Map();
    for (const url of Object.values(rememberedPlugins())) {
      if (keepablePluginUrl(url)) warmPluginBytes.set(url, cachedPluginBytes(url));
    }
    function requestPlugin(id, url) {
      const inst = wasmInstance;
      const idBytes = utf8encode(id);
      const urlBytes = utf8encode(url || "");
      const idPtr = inst.exports.FizzyWebPluginAlloc(idBytes.length, 1);
      const urlPtr = urlBytes.length ? inst.exports.FizzyWebPluginAlloc(urlBytes.length, 1) : 0;
      if (!idPtr || (urlBytes.length && !urlPtr)) return;
      new Uint8Array(inst.exports.memory.buffer, idPtr, idBytes.length).set(idBytes);
      if (urlBytes.length) new Uint8Array(inst.exports.memory.buffer, urlPtr, urlBytes.length).set(urlBytes);
      inst.exports.FizzyWebPluginRequest(idPtr, idBytes.length, urlPtr, urlBytes.length);
    }
    function requestUrlPlugins() {
      const inst = wasmInstance;
      if (!inst || !inst.exports.FizzyWebPluginRequest) return;
      // A dev build stands in for a remembered one of the same id.
      const devPlugins = startup.plugins;
      for (const [id, url] of Object.entries(rememberedPlugins())) if (!devPlugins.includes(id)) requestPlugin(id, url);
      for (const id of devPlugins) requestPlugin(id, "");
      // The store's update pass waits for this: it can only tell a remembered build that runs
      // from one that needs replacing once every one of them has been tried.
      if (inst.exports.FizzyWebStartupPluginsRequested) inst.exports.FizzyWebStartupPluginsRequested();
      if (dvuiApp) dvuiApp.requestRender();
      // After the plugins, so the one that owns a file may be among them.
      for (const url of startup.open) {
        fetch(url, { cache: "no-store" }).then((r) => r.arrayBuffer()).then((buf) => {
          const inst2 = wasmInstance;
          const name = utf8encode(url.split("/").pop().split("?")[0]);
          const namePtr = inst2.exports.FizzyWebPluginAlloc(name.length, 1);
          const bytes = new Uint8Array(buf);
          const bytesPtr = inst2.exports.FizzyWebPluginAlloc(bytes.length, 1);
          if (!namePtr || !bytesPtr) return;
          new Uint8Array(inst2.exports.memory.buffer, namePtr, name.length).set(name);
          new Uint8Array(inst2.exports.memory.buffer, bytesPtr, bytes.length).set(bytes);
          inst2.exports.FizzyWebOpenBytes(namePtr, name.length, bytesPtr, bytes.length);
          const show = startup.show;
          if (show && inst2.exports.FizzyWebShowInRoot) {
            const showBytes = utf8encode(show);
            const showPtr = inst2.exports.FizzyWebPluginAlloc(showBytes.length, 1);
            if (showPtr) {
              new Uint8Array(inst2.exports.memory.buffer, showPtr, showBytes.length).set(showBytes);
              inst2.exports.FizzyWebShowInRoot(showPtr, showBytes.length);
            }
          }
          if (dvuiApp) dvuiApp.requestRender();
        }).catch((err) => console.error("fizzy: could not open", url, err));
      }
      for (const demo of startup.demos) playDemo(demo);
      if (startup.tape) playTape(startup.tape);
    }

    function playTape(url) {
      fetch(url, { cache: "no-store" })
        .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(r.status)))
        .then((buf) => {
          const exports = wasmInstance.exports;
          if (!exports.FizzyWebPlayTape) return;
          const bytes = new Uint8Array(buf);
          const ptr = exports.FizzyWebPluginAlloc(bytes.length, 1);
          if (!ptr) return;
          new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
          exports.FizzyWebPlayTape(ptr, bytes.length);
          if (dvuiApp) dvuiApp.requestRender();
        })
        .catch((err) => console.error("fizzy: could not fetch the tape", url, err));
    }

    function playDemo(demo) {
      const send = (bytes, isTape) => {
        const exports = wasmInstance.exports;
        if (!exports.FizzyWebPlayDemo) return;
        const ptr = exports.FizzyWebPluginAlloc(bytes.length, 1);
        if (!ptr) return;
        new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
        exports.FizzyWebPlayDemo(ptr, bytes.length, isTape);
        if (dvuiApp) dvuiApp.requestRender();
      };
      if (!/\.(zon|tape)(\?|$)/.test(demo)) return send(utf8encode(demo), false);
      fetch(demo, { cache: "no-store" })
        .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(r.status)))
        .then((buf) => send(new Uint8Array(buf), true))
        .catch((err) => console.error("fizzy: could not fetch demo", demo, err));
    }

    // ---- plugins at runtime: wasm side modules -------------------------------------------
    //
    // A plugin built for the web is an Emscripten-style side module: position-independent,
    // importing the host's memory, function table and stack pointer, with its own data laid
    // out at `__memory_base` and its functions at `__table_base`. Loading one is: fetch,
    // read its `dylink.0` needs, carve its data out of the host's heap, grow the table,
    // instantiate against the host's exports, apply relocations, then hand the host a table
    // index for each of the plugin's entry points — the dylib model, with indices for
    // function pointers. Everything after that is the same code the desktop runs.
    const pluginEntryPoints = [
      "fizzy_plugin_abi_fingerprint",
      "fizzy_plugin_sdk_version",
      "fizzy_plugin_min_sdk_version",
      "fizzy_plugin_version",
      "fizzy_plugin_id",
      "fizzy_plugin_manifest_zon",
      "fizzy_plugin_register",
      "fizzy_plugin_set_dvui_context",
      "fizzy_plugin_set_render_bridge",
      "fizzy_plugin_set_globals",
    ];
    const loadedPlugins = new Map();

    function readDylinkNeeds(module) {
      const sections = WebAssembly.Module.customSections(module, "dylink.0");
      if (sections.length === 0) throw new Error("not a side module (no dylink.0 section)");
      const bytes = new Uint8Array(sections[0]);
      let pos = 0;
      const leb = () => {
        let result = 0, shift = 0, b;
        do { b = bytes[pos++]; result |= (b & 0x7f) << shift; shift += 7; } while (b & 0x80);
        return result >>> 0;
      };
      const needs = { memorySize: 0, memoryAlign: 0, tableSize: 0, tableAlign: 0 };
      while (pos < bytes.length) {
        const type = bytes[pos++];
        const size = leb();
        const end = pos + size;
        if (type === 1) { // WASM_DYLINK_MEM_INFO
          needs.memorySize = leb();
          needs.memoryAlign = leb();
          needs.tableSize = leb();
          needs.tableAlign = leb();
        }
        pos = end;
      }
      return needs;
    }

    // Where a plugin's bytes come from when its own host will not let a browser have them.
    //
    // A release asset — the way every plugin publishes — carries no `access-control-allow-origin`,
    // so `fetch()` fails on it before a byte moves. That is a browser rule, not a property of
    // the file, so it is answered here rather than by making every author publish somewhere
    // else: try the URL as given, and on failure ask fizzy's own origin to fetch it. A host
    // that does send CORS is read directly and never touches the proxy.
    //
    // On its own `dl.fizzyed.it` host (a Workers Custom Domain, `web/wrangler.toml`) because the
    // zone's other records are DNS-only, so a route on `fizzyed.it/dl/*` would never fire. The
    // page checks the sha256 the registry published before it compiles anything, so this is a
    // pipe, never something trusted.
    const pluginProxy = "https://dl.fizzyed.it/dl/";
    // The same Worker's image route (`dl-worker.js`): an image whose host sends no CORS header
    // is fetched through it so its pixels can be read.
    const imageProxy = "https://dl.fizzyed.it/img/";
    // Set once at startup by the host (`PluginLoader_web.init`): the ABI fingerprint whose
    // catalog shard this build installs from. The proxy checks the URL against that shard.
    let pluginFingerprint = "";

    // fetchPluginBytes and reportPluginFailed have a matching copy in web/fizzy-worker.js; change both.
    async function fetchPluginBytes(url) {
      // Each fetch (the body included) gets a deadline: a request the network swallows would
      // otherwise leave the store's row on "Updating..." for good, with nothing to say why.
      const timeoutMs = 30000;
      const attempt = async (target) => {
        try {
          return await fetch(target, { cache: "no-store", signal: AbortSignal.timeout(timeoutMs) });
        } catch (err) {
          if (err && err.name === "TimeoutError") throw new Error("timed out after " + timeoutMs / 1000 + " s");
          throw err;
        }
      };
      // The bytes of a response whose headers arrived: the body is under the same deadline. Worst case before a failure shows is three asks (direct, proxy, proxy again), 90 s.
      const body = async (response) => {
        try {
          return await response.arrayBuffer();
        } catch (err) {
          if (err && err.name === "TimeoutError") throw new Error("timed out after " + timeoutMs / 1000 + " s");
          throw err;
        }
      };
      let directWhy = "";
      try {
        const direct = await attempt(url);
        if (direct.ok) return await body(direct);
        // A real 404 is worth reporting as itself; anything else is worth a second try.
        if (direct.status === 404) { console.error("fizzy: plugin not found (404):", url); throw new Error("not found (404)"); }
        directWhy = "status " + direct.status;
      } catch (err) {
        if (String(err).includes("not found (404)")) throw err;
        directWhy = String(err && err.message ? err.message : err);
      }
      if (!pluginFingerprint) throw new Error(directWhy + " (and no catalog shard to ask the proxy)");
      // The proxy is asked twice: one dropped or stalled request should not cost the user the update.
      let why = "";
      for (let tries = 0; tries < 2; tries++) {
        try {
          const viaProxy = await attempt(pluginProxy + pluginFingerprint + "/" + encodeURIComponent(url));
          if (viaProxy.ok) return await body(viaProxy);
          why = "proxy said " + viaProxy.status;
          // Another ask cannot change a refusal of this URL; only a server-side hiccup is retried.
          if (viaProxy.status < 500 && viaProxy.status !== 408 && viaProxy.status !== 429) break;
        } catch (err) {
          why = String(err && err.message ? err.message : err);
        }
      }
      throw new Error(why); // the cause alone: the store shows it in a narrow row, the URL is in the console
    }

    // Tell the host a load failed, and why: the store shows the text beside Retry. The text
    // is copied into the host's heap, and the host frees it.
    function reportPluginFailed(inst, req, err) {
      const msg = utf8encode(String(err && err.message ? err.message : err).slice(0, 300));
      const ptr = msg.length ? inst.exports.FizzyWebPluginAlloc(msg.length, 1) : 0;
      if (ptr) new Uint8Array(inst.exports.memory.buffer, ptr, msg.length).set(msg);
      inst.exports.FizzyWebPluginFailed(req, ptr, ptr ? msg.length : 0);
    }

    // Lowercase hex of the bytes' SHA-256, for comparing against what the registry published.
    async function sha256Hex(bytes) {
      const digest = await crypto.subtle.digest("SHA-256", bytes);
      return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
    }

    async function loadPlugin(req, url, id, sha256) {
      const host = wasmInstance;
      // A build kept from an earlier visit, if there is one (see "installed plugins' bytes").
      const warm = warmPluginBytes.get(url);
      warmPluginBytes.delete(url);
      let bytes = await (warm || cachedPluginBytes(url));
      // The check the desktop downloader has always done. Before `compile`, so a tampered or
      // truncated module is never handed to the engine, let alone registered. A kept build is
      // held to it too when the registry's hash is at hand; one that fails it is dropped and
      // downloaded again rather than refused.
      if (bytes && sha256 && (await sha256Hex(bytes)) !== sha256.toLowerCase()) {
        dropPluginBytes(url);
        bytes = null;
      }
      if (!bytes) {
        bytes = await fetchPluginBytes(url);
        if (sha256) {
          const got = await sha256Hex(bytes);
          if (got !== sha256.toLowerCase()) {
            { console.error("fizzy: sha256 mismatch for " + id + ": expected " + sha256 + ", got " + got); throw new Error("download did not match the published checksum"); }
          }
        }
        if (keepablePluginUrl(url)) unkeptPluginBytes.set(url, bytes);
      }
      const module = await WebAssembly.compile(bytes);
      const needs = readDylinkNeeds(module);
      const memoryBase = host.exports.FizzyWebPluginAlloc(needs.memorySize, 1 << needs.memoryAlign);
      if (!memoryBase) throw new Error("out of memory for plugin data");
      const tableBase = functionTable.length;
      functionTable.grow(needs.tableSize);
      // Every function the host exports is available to the plugin (dvui's C shims, stb);
      // the linking globals point the plugin at its own slice of memory and table.
      const env = {};
      for (const [name, value] of Object.entries(host.exports)) {
        if (typeof value === "function") env[name] = value;
      }
      env.memory = host.exports.memory;
      env.__indirect_function_table = functionTable;
      env.__stack_pointer = host.exports.__stack_pointer;
      env.__memory_base = new WebAssembly.Global({ value: "i32", mutable: false }, memoryBase);
      env.__table_base = new WebAssembly.Global({ value: "i32", mutable: false }, tableBase);
      // Say which import the host lacks, rather than the linker's "Import #12".
      const missing = WebAssembly.Module.imports(module)
        .filter((i) => i.module === "env" && i.kind === "function" && !(i.name in env))
        .map((i) => i.name);
      if (missing.length) throw new Error("the host does not export: " + missing.join(", "));
      const holder = { inst: null };
      const instance = await WebAssembly.instantiate(module, {
        env,
        fizzy: fizzyImports(() => holder.inst),
        dvui: dvuiApp ? dvuiApp.imports : {},
      });
      holder.inst = instance;
      if (instance.exports.__wasm_apply_data_relocs) instance.exports.__wasm_apply_data_relocs();
      if (instance.exports.__wasm_call_ctors) instance.exports.__wasm_call_ctors();
      // The entry points, as table indices the host can call through.
      const base = functionTable.length;
      functionTable.grow(pluginEntryPoints.length);
      pluginEntryPoints.forEach((name, i) => {
        const fn = instance.exports[name];
        if (!fn) throw new Error("plugin is missing " + name);
        functionTable.set(base + i, fn);
      });
      const list = host.exports.FizzyWebPluginAlloc(4 * pluginEntryPoints.length, 4);
      const indices = new Uint32Array(host.exports.memory.buffer, list, pluginEntryPoints.length);
      for (let i = 0; i < pluginEntryPoints.length; i++) indices[i] = base + i;
      loadedPlugins.set(url, instance);
      host.exports.FizzyWebPluginReady(req, list, pluginEntryPoints.length);
      // Deliberately not remembered here. Linking a module says nothing about whether this
      // host will run it — the fingerprint, SDK version and declared id are checked after
      // `FizzyWebPluginReady`, in `PluginLoader_web.loadAndRegister` — and a build remembered
      // at this point would be re-fetched and re-refused on every later visit. The host calls
      // `fizzy_web_plugin_remember` once the plugin has actually registered.
    }

    /** Rasterize `url` the way an `<img>` would — PNG/JPEG and CORS-friendly SVG. */
    function loadImagePixels(url) {
      return new Promise((resolve, reject) => {
        const img = new Image();
        img.crossOrigin = "anonymous";
        img.onload = () => {
          // An SVG with no size of its own (a badge, often) still needs a box to raster into;
          // GitHub's are about 200×20.
          const nw = img.naturalWidth || 200;
          const nh = img.naturalHeight || 20;
          // Screenshots in READMEs run to 8+ megapixels and are shown at a fraction of that:
          // scale down to the cap rather than refuse, so the pixels handed over stay bounded.
          const fit = Math.min(1, Math.sqrt((4 * 1024 * 1024) / (nw * nh)));
          const w = Math.max(1, Math.floor(nw * fit));
          const h = Math.max(1, Math.floor(nh * fit));
          const canvas = document.createElement("canvas");
          canvas.width = w;
          canvas.height = h;
          const ctx = canvas.getContext("2d");
          ctx.drawImage(img, 0, 0, w, h);
          try {
            resolve(ctx.getImageData(0, 0, w, h));
          } catch (err) {
            reject(err);
          }
        };
        img.onerror = () => reject(new Error("image load failed"));
        img.src = url;
      });
    }

    // Trackpad pinch arrives as a `wheel` event with `ctrlKey=true` and `deltaMode=0`
    // (every modern browser synthesizes this). Two things to do here in the capture phase,
    // before dvui's bubble-phase listener on the canvas:
    //   1. preventDefault + stopImmediatePropagation — keeps the browser from page-zooming
    //      and keeps the wheel reader from folding the tiny pinch delta into its
    //      `lowest` minimum (an all-time min that never resets and otherwise
    //      poisons trackpad scroll sensitivity for the rest of the session).
    //   2. Forward the magnification into the wasm trackpad accumulator
    //      (`FizzyWebTrackpadMagnification`). The canvas widget drains it each frame and
    //      applies the same scale-around-point math used by macOS native pinch.
    // `dvuiApp` starts null and is filled in once the app loads — events that arrive
    // before then are still safely suppressed.
    // Scale factor (100): browser pinch deltaY is roughly ±1..±20 per event; dividing by
    // 100 produces ratios around 1.01..1.2 per event, matching the magnitude AppKit
    // reports for native trackpad gestures. Negate deltaY because positive deltaY means
    // "pinch fingers together = zoom out".
    let dvuiApp = null;
    const dvuiCanvas = opts.canvas;
    // The element dvui's text input lives in (set once the editor is up): where text arrives.
    let textInput = null;
    for (const type of ["pointerdown", "focus"]) dvuiCanvas.addEventListener(type, () => { activeCopy = this; }, { capture: true });

    // View › Toggle Full Screen shows this copy's element, not the whole page, and switches to it
    // when another element (another copy) is already full screen.
    function fullscreenTarget() {
      return opts.fullscreenElement ?? dvuiCanvas.parentElement ?? dvuiCanvas;
    }
    function toggleFullscreen() {
      const target = fullscreenTarget();
      if (document.fullscreenElement === target) {
        document.exitFullscreen().catch(() => {});
      } else if (target.requestFullscreen) {
        target.requestFullscreen().catch((err) => console.warn("fizzy: full screen refused:", err));
      }
    }

    // Shortcuts the app binds are the app's, not the browser's: ⌘S must not also save the
    // page. Capture phase, so this runs before dvui's own listener (which still receives the
    // key — preventDefault stops the browser, not the event). The app answers synchronously
    // from its keymap (`Keybinds.webKeyBound`), which also keeps typing, copy/cut/paste and
    // unbound chords with the browser.
    //
    // Only the keys meant for this copy: typed into the page's own field, or a chord aimed at
    // another copy, they stay the page's. A key lands on this copy when its canvas or its text
    // input has the focus, or when nothing has and this copy was the last one used.
    const ownsKey = (ev) => {
      const target = ev.target;
      if (target === dvuiCanvas || (textInput && target === textInput)) return true;
      return (target === document.body || target === document.documentElement) && activeCopy === this;
    };
    window.addEventListener("keydown", (ev) => {
      if (!ownsKey(ev)) return;
      const ex = wasmInstance && wasmInstance.exports;
      if (!ex || !ex.FizzyWebKeyBound) return;
      const bytes = utf8encode(ev.key);
      if (bytes.length === 0 || bytes.length > 16) return;
      new Uint8Array(ex.memory.buffer, ex.FizzyWebKeyBuffer(), bytes.length).set(bytes);
      const mods = (ev.metaKey << 3) | (ev.altKey << 2) | (ev.ctrlKey << 1) | (ev.shiftKey << 0);
      if (ex.FizzyWebKeyBound(bytes.length, mods)) ev.preventDefault();
    }, { capture: true });

    // Some shortcuts never reach a page at all (⌘W, ⌘T, ⌘N, Ctrl+Tab). The Keyboard Lock API
    // hands them over, but only in full screen and only in Chromium; elsewhere this is a no-op
    // and those chords stay the browser's.
    document.addEventListener("fullscreenchange", () => {
      const kb = navigator.keyboard;
      const full = document.fullscreenElement === fullscreenTarget();
      // The text input is the page's, outside the element shown full screen, where it cannot
      // take focus; it goes in with the editor and comes out again.
      if (textInput) (full ? fullscreenTarget() : document.body).prepend(textInput);
      if (!kb || !kb.lock) return;
      if (full) kb.lock().catch(() => {});
      else if (!document.fullscreenElement) kb.unlock();
    });
    dvuiCanvas.addEventListener("wheel", (ev) => {
      if (ev.ctrlKey && ev.deltaMode === 0) {
        ev.preventDefault();
        ev.stopImmediatePropagation();
        if (dvuiApp && dvuiApp.instance.exports.FizzyWebTrackpadMagnification) {
          dvuiApp.instance.exports.FizzyWebTrackpadMagnification(-ev.deltaY / 100);
          // dvui normally calls `requestRender` from its own wheel listener — since we
          // swallowed the event in the capture phase, drive the frame loop ourselves so
          // the canvas widget actually drains the accumulator we just wrote.
          dvuiApp.requestRender();
        } else if (pinchSink) {
          pinchSink(-ev.deltaY / 100);
        }
      }
    }, { capture: true, passive: false });

    // ---- form factor ----------------------------------------------------------------------
    //
    // The device as `core.platform.formFactor()` sees it, for both the worker and the page's
    // own loop: a finger with no hover as the primary pointer, and the screen in CSS px (not
    // the viewport or canvas, which the soft keyboard and sheets shrink). `opts.form` overrides
    // the rule. The extra fields are for the console readout.
    const formNames = ["desktop", "tablet", "mobile"]; // the order of `FormFactor` in core/form_factor.zig
    const formOverride = formNames.indexOf(opts.form ?? ""); // -1: none
    function formMeasure() {
      const mq = (q) => window.matchMedia(q).matches;
      return {
        coarse: mq("(pointer: coarse)") && mq("(hover: none)"), w: screen.width, h: screen.height,
        override: formOverride, overrideName: formOverride >= 0 ? opts.form : "",
        pointerCoarse: mq("(pointer: coarse)"), hoverHover: mq("(hover: hover)"),
      };
    }
    // The main-thread loop's twin of the worker's `applyForm`.
    let appliedForm = "";
    function applyFormMain() {
      const f = formMeasure();
      const exp = dvuiApp && dvuiApp.instance.exports.FizzyWebSetFormFactor;
      if (!exp) return;
      const key = `${f.coarse}|${f.w}|${f.h}|${f.override}`;
      if (key === appliedForm) return;
      appliedForm = key;
      const chosen = exp(f.coarse, f.w, f.h, f.override);
      console.log(
        `form-factor: coarse=${f.pointerCoarse} hover=${f.hoverHover} w=${f.w} h=${f.h} ` +
        `override=${f.overrideName || "none"} -> ${formNames[chosen]}`,
      );
      dvuiApp.requestRender();
    }

    // ---- worker mode: the editor runs in `fizzy-worker.js` --------------------------------
    //
    // Chrome on Android throttles a page's own frames to 60 Hz on a 120 Hz screen unless input
    // is driving them; a worker's frame loop is not. So the editor, dvui's `web.js` and all,
    // runs in a worker drawing to this canvas through an `OffscreenCanvas`, and the page is
    // what only a page can be: where input lands (sent on as dvui would have queued it), and
    // where the worker's cursor, on-screen keyboard, links, downloads, file pickers,
    // clipboard, full screen and OAuth popups happen.
    function startWorker(wasmUrl, wasmModule) {
      const canvas = dvuiCanvas;
      const worker = new Worker(new URL("fizzy-worker.js?cache-buster=TEMPLATE_HASH_WITH_PADDING__ITS_64_BYTES_LONG_THE_SAME_AS_SHA256", import.meta.url), { type: "module" });
      const post = (msg, transfer) => worker.postMessage(msg, transfer || []);
      const reply = (request, value, transfer) => post({ type: "reply", request, value }, transfer);

      const media = (q) => window.matchMedia(q).matches;
      // `form` is the device, in CSS px, for `core.platform.formFactor()`: a finger with no
      // hover as the primary pointer, and the screen (not the viewport or canvas, which the soft keyboard and sheets shrink).
      const size = () => ({
        w: canvas.clientWidth, h: canvas.clientHeight, dpr: window.devicePixelRatio,
        form: formMeasure(),
      });
      const prefs = () => ({
        dark: media("(prefers-color-scheme: dark)"),
        light: media("(prefers-color-scheme: light)"),
        reduce: media("(prefers-reduced-motion: reduce)"),
      });
      const storage = {};
      window.addEventListener("focus", () => {
        try { post({ type: "personFocus", value: store.getItem("fizzyedit.person") }); } catch (_) {}
      });
      try {
        for (let i = 0; i < store.length; i++) {
          const key = store.key(i);
          if (key && (key === "fizzyedit.person" || key.startsWith(storageName + "."))) storage[key] = store.getItem(key);
        }
      } catch (_) {}

      // dvui's hidden input: where text arrives, and what raises the on-screen keyboard.
      const hidden = document.createElement("input");
      hidden.setAttribute("autocapitalize", "none");
      Object.assign(hidden.style, { position: "absolute", left: 0, top: 0, padding: 0, border: 0, margin: 0, opacity: 0, zIndex: -1 });
      document.body.prepend(hidden);
      textInput = hidden;
      let textInputRect = [];
      // Focus never scrolls the page; and a copy embedded in another page (fizzyed.it's
      // examples, in an iframe) takes none until it is clicked, tapped or tabbed into.
      // Focusing anything inside an iframe scrolls the page holding it to show it, so an
      // embed below the fold that grabbed focus as it started pulled the visitor down to it.
      let engaged = window.parent === window;
      const engage = () => { engaged = true; };
      canvas.addEventListener("pointerdown", engage, { capture: true });
      window.addEventListener("focus", engage);
      function focusQuietly(el) {
        if (engaged) el.focus({ preventScroll: true });
      }
      function oskCheck() {
        if (textInputRect.length === 0) {
          focusQuietly(canvas);
          return;
        }
        const rect = canvas.getBoundingClientRect();
        const left = window.scrollX + rect.left + textInputRect[0];
        // Above the keyboard: the browser scrolls the page to keep a focused element visible, and
        // an input at the caret under the keyboard is what made the page jump.
        const above = Math.max(0, canvas.clientHeight - insetBottom() - textInputRect[3]);
        const top = window.scrollY + rect.top + Math.min(textInputRect[1], above);
        hidden.style.left = left + "px";
        hidden.style.top = top + "px";
        hidden.style.width = Math.max(0, Math.min(textInputRect[2], canvas.clientWidth - textInputRect[0])) + "px";
        hidden.style.height = Math.max(0, Math.min(textInputRect[3], canvas.clientHeight - Math.min(textInputRect[1], above))) + "px";
        focusQuietly(hidden);
      }

      let boundKeys = new Set();
      const offscreen = canvas.transferControlToOffscreen();
      // The init waits for the early compile (`wasmModule`), which by now has usually finished.
      Promise.resolve(wasmModule).then((module) => post({
        type: "init",
        canvas: offscreen,
        wasmUrl: new URL(wasmUrl, document.baseURI).href,
        wasmModule: module || null,
        webJsUrl: new URL("web.js?cache-buster=TEMPLATE_HASH_WITH_PADDING__ITS_64_BYTES_LONG_THE_SAME_AS_SHA256", import.meta.url).href,
        size: size(),
        glassBench: opts.glassBench,
        glassRepeat: opts.glassRepeat,
        prefs: prefs(),
        storage,
        storageName,
        buildStorageName,
        fullscreenSupported,
        startup,
        baseURI: document.baseURI,
      }, [offscreen]));

      const insetBottom = keyboardInset(window, (m) => {
        post(m);
        if (ownsKey({ target: document.activeElement })) oskCheck();
      }, canvas,
        () => ownsKey({ target: document.activeElement }));
      let lastSize = size();
      const resize = () => {
        const next = size();
        if (next.w === lastSize.w && next.h === lastSize.h && next.dpr === lastSize.dpr) return;
        lastSize = next;
        post({ type: "size", size: next });
      };
      new ResizeObserver(resize).observe(canvas);
      window.addEventListener("resize", resize);
      window.addEventListener("orientationchange", () => post({ type: "size", size: size() }));
      for (const q of ["(pointer: coarse)", "(hover: none)"]) {
        window.matchMedia(q).addEventListener("change", () => post({ type: "size", size: size() }));
      }
      for (const q of ["(prefers-color-scheme: dark)", "(prefers-reduced-motion: reduce)"]) {
        window.matchMedia(q).addEventListener("change", () => post({ type: "prefs", prefs: prefs() }));
      }

      // What the keyboard does to the fragment before the caret reaches the worker as typing.
      const inputFilter = new TextInput(hidden, {
        text: (text) => post({ type: "text", text }),
        backspace: () => {
          post({ type: "key", kind: 5, key: "Backspace", repeat: 0, mods: 0 });
          post({ type: "key", kind: 6, key: "Backspace", repeat: 0, mods: 0 });
        },
      });

      worker.onerror = (err) => {
        console.error(err);
        onError(`Failed to load the editor (${err.message || "worker error"}).`);
      };
      worker.onmessage = (e) => {
        const m = e.data;
        switch (m.type) {
          case "ready":
            onReady();
            break;
          case "error":
            console.error(m.message);
            onError(`Failed to load the editor (${m.message}). Try a hard refresh, or use a recent Chrome, Firefox, or Safari.`);
            break;
          case "alert":
            alert(m.msg);
            break;
          case "cursor":
            canvas.style.cursor = m.name;
            break;
          case "textInput":
            if ((textInputRect.length === 0) !== (m.rect.length === 0)) inputFilter.clear();
            textInputRect = m.rect;
            oskCheck();
            break;
          case "openUrl":
            if (m.newWin) window.open(m.url);
            else window.location.href = m.url;
            break;
          case "download": {
            const url = URL.createObjectURL(new Blob([m.data], { type: "application/octet-stream" }));
            const a = document.createElement("a");
            a.href = url;
            a.download = m.name;
            a.click();
            a.remove();
            URL.revokeObjectURL(url);
            break;
          }
          case "filePicker": {
            const input = document.createElement("input");
            input.type = "file";
            input.accept = m.accept;
            if (m.multiple) input.multiple = true;
            input.oncancel = () => reply(m.request, []);
            input.onchange = () => {
              const files = Array.from(input.files || []);
              Promise.all(files.map((f) => f.arrayBuffer())).then((datas) => {
                const out = files.map((f, i) => ({ name: f.name, size: f.size, data: datas[i] }));
                reply(m.request, out, datas);
              });
            };
            input.click();
            break;
          }
          case "clipboard":
            if (navigator.clipboard) navigator.clipboard.writeText(m.text);
            else {
              hidden.value = m.text;
              hidden.focus({ preventScroll: true });
              hidden.select();
              document.execCommand("copy");
              hidden.value = "";
            }
            break;
          case "fullscreen":
            toggleFullscreen();
            break;
          case "oauth": {
            let blobUrl = null;
            let url = m.url;
            if (m.html !== undefined) {
              blobUrl = URL.createObjectURL(new Blob([m.html], { type: "text/html" }));
              url = blobUrl + (m.hash ? "#" + m.hash : "");
            }
            let settled = false;
            const finish = (value) => {
              if (settled) return;
              settled = true;
              window.removeEventListener("message", onMessage);
              if (blobUrl) URL.revokeObjectURL(blobUrl);
              reply(m.request, value);
            };
            const onMessage = (ev) => {
              if (ev.origin !== location.origin || !ev.data || typeof ev.data.fizzyOAuth !== "string") return;
              finish({ text: ev.data.fizzyOAuth });
            };
            window.addEventListener("message", onMessage);
            const popup = window.open(url, "fizzy-oauth", "popup,width=520,height=680");
            if (!popup) {
              finish(null);
              break;
            }
            const watch = setInterval(() => {
              if (settled) return clearInterval(watch);
              if (popup.closed) {
                clearInterval(watch);
                finish(null);
              }
            }, 500);
            break;
          }
          case "rasterize":
            loadImagePixels(m.url).then((img) => {
              reply(m.request, { data: img.data, width: img.width, height: img.height }, [img.data.buffer]);
            }).catch(() => reply(m.request, null));
            break;
          case "storageSet":
            try { store.setItem(m.key, m.value); } catch (err) { console.warn("fizzy: could not store", m.key, err); }
            break;
          case "storageRemove":
            try { store.removeItem(m.key); } catch (_) {}
            break;
          case "persistStorage":
            askToPersist();
            break;
          case "boundKeys":
            boundKeys = new Set(m.keys);
            break;
        }
      };

      // Input, as dvui's `web.js` would have queued it (its event codes, its wheel heuristics).
      const mods = (ev) => (ev.metaKey << 3) | (ev.altKey << 2) | (ev.ctrlKey << 1) | (ev.shiftKey << 0);
      const event = (a0, a1, a2, a3, a4) => post({ type: "event", a: [a0, a1, a2, a3, a4] });
      canvas.addEventListener("contextmenu", (ev) => ev.preventDefault());
      pointerInput(canvas, post, performance.timeOrigin, oskCheck);

      wheelInput(canvas, (axis, trackpad, ticks) => event(4, axis, trackpad, ticks, 0));

      canvas.addEventListener("pointerdown", () => inputFilter.clear());
      const keydown = (ev) => {
        inputFilter.keydown(ev);
        if (ev.key === "Tab") {
          if (ev.ctrlKey) return;
          ev.preventDefault();
        }
        if (boundKeys.has(ev.key + "|" + mods(ev))) ev.preventDefault();
        post({ type: "key", kind: 5, key: ev.key, repeat: ev.repeat ? 1 : 0, mods: mods(ev) });
      };
      const keyup = (ev) => post({ type: "key", kind: 6, key: ev.key, repeat: 0, mods: mods(ev) });
      canvas.addEventListener("keydown", keydown);
      hidden.addEventListener("keydown", keydown);
      canvas.addEventListener("keyup", keyup);
      hidden.addEventListener("keyup", keyup);

      pinchSink = (amount) => post({ type: "pinch", amount });
    }

    // Where a trackpad pinch goes in worker mode (the capture listener above).
    var pinchSink = null;

    // The worker is for Chromium, whose page frames are held to 60 Hz on a phone unless input
    // drives them; a worker's are not. Safari drives a worker's frames at about 60 Hz where its
    // page's run at the display's 120, so everywhere else the page is the faster place.
    // `navigator.userAgentData` is Chromium's alone; `opts.worker` overrides. Never with imports
    // of the caller's own: they are the page's functions, which a worker cannot call.
    const workerMode = (opts.worker ?? "userAgentData" in navigator) &&
      !opts.imports && typeof OffscreenCanvas !== "undefined" && "transferControlToOffscreen" in HTMLCanvasElement.prototype;

    if (!hasWebGl()) {
      onError("This browser does not support WebGL, which fizzy needs to run.");
    } else if (workerMode) {
      const wasmUrl = new URL("web.wasm?cache-buster=TEMPLATE_HASH_WITH_PADDING__ITS_64_BYTES_LONG_THE_SAME_AS_SHA256", import.meta.url).href;
      // Fetched and compiled now, seen or not. A page opened in a background tab gets no
      // animation frames, so `waitForLayout` holds the worker until the tab is shown; the
      // editor's download used to wait with it, tens of seconds on a slow link. The worker is
      // handed the compiled module and fetches nothing itself, so a page shown at once never
      // downloads it twice. Null on failure: the worker then fetches it as before.
      const wasmModule = compiledEditor(wasmUrl);
      waitForLayout().then(() => startWorker(wasmUrl, wasmModule)).catch((err) => {
        console.error(err);
        onError(`Failed to load the editor (${err instanceof Error ? err.message : String(err)}).`);
      });
    } else {
      const wasmUrl = new URL("web.wasm?cache-buster=TEMPLATE_HASH_WITH_PADDING__ITS_64_BYTES_LONG_THE_SAME_AS_SHA256", import.meta.url).href;
      waitForLayout()
        .then(() => {
          const app = new Dvui();
          const imports = {
            ...opts.imports,
            dvui: app.imports,
            fizzy: fizzyImports(() => wasmInstance),
            env: { __indirect_function_table: functionTable },
          };
          return compiledEditor(wasmUrl).then((module) => module
            ? WebAssembly.instantiate(module, imports).then((instance) => ({ instance }))
            : WebAssembly.instantiateStreaming(fetch(wasmUrl), imports)
          ).then((result) => {
            wasmInstance = result.instance;
            if (opts.onInstance) opts.onInstance(result.instance);
            app.setInstance(result.instance);
            app.setCanvas(dvuiCanvas);
            app.run();
            textInput = app.hidden_input ?? null;
            return app;
          });
        })
        .then((app) => {
          // Late-bind the app reference so the capture-phase wheel listener above can
          // forward pinch deltas into the trackpad accumulator and kick a render.
          dvuiApp = app;
          const insetBottom = keyboardInset(window, (m) => {
            app.instance.exports.FizzyWebSetKeyboardInset?.(m.bottom);
            app.requestRender();
            if (ownsKey({ target: document.activeElement })) app.oskCheck();
          }, dvuiCanvas, () => ownsKey({ target: document.activeElement }));
          const oskCheck = app.oskCheck.bind(app);
          app.oskCheck = () => {
            const r = app.textInputRect;
            if (!r?.length) return oskCheck();
            const y = r[1];
            r[1] = Math.min(y, Math.max(0, dvuiCanvas.clientHeight - insetBottom() - r[3]));
            try { oskCheck(); } finally { r[1] = y; }
          };
          // Registered before the stoppers below: a stopper on the same element and phase would
          // end propagation to pointerInput's touch listeners, which cancel the touch's default.
          pointerInput(dvuiCanvas, (m) => {
            for (const e of m.events) {
              const a = e.mouse ? [1, e.mods, 0, e.x * app.gl.drawingBufferWidth, e.y * app.gl.drawingBufferHeight] : e.a;
              app.instance.exports.add_event(...a, e.time - performance.timeOrigin);
            }
            app.requestRender();
          }, performance.timeOrigin, () => app.oskCheck());
          wheelInput(dvuiCanvas, (axis, trackpad, ticks) => {
            app.instance.exports.add_event(4, axis, trackpad, ticks, 0);
            app.requestRender();
          });
          for (const name of ["touchstart", "touchmove", "touchend", "touchcancel", "mousedown", "mousemove", "mouseup"]) {
            dvuiCanvas.addEventListener(name, (ev) => ev.stopImmediatePropagation(), { capture: true });
          }
          // The main-thread loop never sent the device to the editor, so Firefox and Safari
          // (which take this path) were always `.desktop`: send it now and on change.
          applyFormMain();
          if (opts.glassBench && app.instance.exports.FizzyWebGlassBench) {
            const bytes = new TextEncoder().encode(opts.glassBench);
            const ptr = app.allocBuffer(app.instance.exports.arena_u8, bytes);
            app.instance.exports.FizzyWebGlassBench(ptr, bytes.length, Number(opts.glassRepeat) || 1);
          }
          for (const ev of ["resize", "orientationchange"]) window.addEventListener(ev, applyFormMain);
          for (const q of ["(pointer: coarse)", "(hover: none)"]) {
            window.matchMedia(q).addEventListener("change", applyFormMain);
          }
          window.dispatchEvent(new Event("resize"));
          app.requestRender();
          onReady();
          // After the first frame: the editor exists once `dvui_init` has run.
          setTimeout(requestUrlPlugins, 0);
        })
        .catch((err) => {
          console.error(err);
          const detail = err instanceof Error ? err.message : String(err);
          onError(`Failed to load the editor (${detail}). Try a hard refresh, or use a recent Chrome, Firefox, or Safari.`);
        });
    }
  }
}
