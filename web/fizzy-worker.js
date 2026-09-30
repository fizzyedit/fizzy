// The editor in a worker: dvui's `web.js`, unchanged, driving WebGL on the page's canvas through
// an `OffscreenCanvas`, with the page (`index.html`, worker mode) forwarding input and doing what
// only a page can.
//
// Why: Chrome on Android throttles main-thread frames (`requestAnimationFrame` on the page) to
// 60 Hz on a 120 Hz screen unless input is driving them, so every animation — a sidebar
// sliding, a dialog forming — ran at half the display's rate. A worker's own frame loop is not
// throttled. Everything here is the page's `index.html` bootstrap, moved: the fizzy imports, the
// plugin loader. What needs the page is a message to it and back.

const utf8 = new TextDecoder();
const utf8encode = (s) => new TextEncoder().encode(s);

// ---- the page, as dvui's `web.js` sees it ----------------------------------------------------
//
// `web.js` was written for the main thread. The few places it reaches for the page get answers
// from here: the canvas is the `OffscreenCanvas` the page handed over, sized from what the page
// reports; the hidden text input lives on the page (a stand-in here takes `web.js`'s calls);
// media queries and the pixel ratio are the page's, sent when they change.
const env = {
    canvas: null,
    size: { w: 1, h: 1, dpr: 1 },
    prefs: { dark: false, light: false, reduce: false },
    storage: {},
    search: "",
    baseURI: "",
};
const inputStub = { style: {}, value: "", setAttribute() {}, addEventListener() {}, focus() {}, select() {} };
self.document = {
    createElement: () => inputStub,
    body: { prepend() {} },
    querySelector: () => env.canvas,
    execCommand() {},
};
self.window = self;
self.HTMLCanvasElement = class {};
self.alert = (msg) => postMessage({ type: "alert", msg: String(msg) });
self.matchMedia = (query) => ({
    matches: query.includes("prefers-color-scheme: dark") ? env.prefs.dark
        : query.includes("prefers-color-scheme: light") ? env.prefs.light
        : query.includes("prefers-reduced-motion: reduce") ? env.prefs.reduce
        : query.includes("prefers-reduced-motion: no-preference") ? !env.prefs.reduce
        : false,
});
Object.defineProperty(self, "devicePixelRatio", { get: () => env.size.dpr, configurable: true });

function adoptCanvas(canvas) {
    Object.defineProperty(canvas, "clientWidth", { get: () => env.size.w });
    Object.defineProperty(canvas, "clientHeight", { get: () => env.size.h });
    canvas.style = { width: "100%", height: "100%" };
    canvas.focus = () => {};
    canvas.getBoundingClientRect = () => ({ left: 0, top: 0, right: env.size.w, bottom: env.size.h });
    env.canvas = canvas;
}

let dvuiApp = null;
let wasmInstance = null;
const functionTable = new WebAssembly.Table({ initial: 4096, element: "anyfunc" });

// ---- storage: the page's, as a snapshot -------------------------------------------------------
//
// A worker has no `localStorage`, and the app reads its settings synchronously. The page sends
// its `fizzy.*` entries at startup; writes land here at once and go back to the page to keep.
function storageGet(key) {
    return Object.prototype.hasOwnProperty.call(env.storage, key) ? env.storage[key] : null;
}
function storageSet(key, value) {
    env.storage[key] = value;
    postMessage({ type: "storageSet", key, value });
}
function storageRemove(key) {
    delete env.storage[key];
    postMessage({ type: "storageRemove", key });
}

// ---- page-only work, by request ---------------------------------------------------------------
let nextRequest = 1;
const pending = new Map();
function ask(msg, transfer) {
    const id = nextRequest++;
    return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        postMessage({ ...msg, request: id }, transfer || []);
    });
}

// ---- the fizzy imports (was `index.html`'s `fizzyImports`) ------------------------------------
function mem() {
    return wasmInstance.exports.memory.buffer;
}
function str(ptr, len) {
    return utf8.decode(new Uint8Array(mem(), ptr, len));
}
function render() {
    if (dvuiApp) dvuiApp.requestRender();
}

const imageProxy = "https://fizzy-plugin-dl.foxnne.workers.dev/img/";
const pluginProxy = "https://fizzy-plugin-dl.foxnne.workers.dev/dl/";
let pluginFingerprint = "";

// Pixels of an image, as an `<img>` would decode it: here when the worker can (PNG/JPEG), on the
// page otherwise (an SVG, which a worker cannot rasterize).
async function imagePixelsHere(url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error("http " + res.status);
    const bitmap = await createImageBitmap(await res.blob());
    const fit = Math.min(1, Math.sqrt((4 * 1024 * 1024) / (bitmap.width * bitmap.height)));
    const w = Math.max(1, Math.floor(bitmap.width * fit));
    const h = Math.max(1, Math.floor(bitmap.height * fit));
    const canvas = new OffscreenCanvas(w, h);
    const ctx = canvas.getContext("2d");
    ctx.drawImage(bitmap, 0, 0, w, h);
    bitmap.close();
    const data = ctx.getImageData(0, 0, w, h);
    return { data: data.data, width: w, height: h };
}
async function imagePixels(url) {
    try {
        return await imagePixelsHere(url);
    } catch (_) {
        return await ask({ type: "rasterize", url });
    }
}

function oauthOpen(inst, msg) {
    ask(msg).then((result) => {
        if (!result || typeof result.text !== "string") {
            inst.exports.FizzyWebOAuthFailed();
        } else {
            const bytes = utf8encode(result.text);
            const ptr = inst.exports.FizzyWebOAuthAlloc(bytes.length);
            if (!ptr) inst.exports.FizzyWebOAuthFailed();
            else {
                new Uint8Array(mem(), ptr, bytes.length).set(bytes);
                inst.exports.FizzyWebOAuthResult(ptr, bytes.length);
            }
        }
        render();
    });
}

const fizzyImports = (target) => ({
    fizzy_web_image_request(id, urlPtr, urlLen) {
        const inst = target();
        if (!inst) return;
        const url = str(urlPtr, urlLen);
        imagePixels(url).catch(() => imagePixels(imageProxy + encodeURIComponent(url))).then((image) => {
            const bytes = new Uint8Array(image.data.buffer, image.data.byteOffset, image.data.byteLength);
            const ptr = inst.exports.FizzyWebImageAlloc(bytes.length);
            if (!ptr) inst.exports.FizzyWebImageFailed(id);
            else {
                new Uint8Array(mem(), ptr, bytes.length).set(bytes);
                inst.exports.FizzyWebImageReady(id, ptr, bytes.length, image.width, image.height);
            }
            render();
        }).catch(() => {
            inst.exports.FizzyWebImageFailed(id);
            render();
        });
    },
    fizzy_web_request(id, methodPtr, methodLen, urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen) {
        const inst = target();
        if (!inst) return;
        const method = str(methodPtr, methodLen);
        const url = str(urlPtr, urlLen);
        const headers = new Headers();
        for (const line of str(headersPtr, headersLen).split("\n")) {
            const at = line.indexOf(": ");
            if (at > 0) headers.append(line.slice(0, at), line.slice(at + 2));
        }
        const body = bodyLen > 0 ? new Uint8Array(mem(), bodyPtr, bodyLen).slice() : undefined;
        const fail = () => {
            inst.exports.FizzyWebRequestFailed(id);
            render();
        };
        fetch(url, { method, headers, body, cache: "no-store" }).then((res) => res.arrayBuffer().then((buf) => {
            const bytes = new Uint8Array(buf);
            const ptr = inst.exports.FizzyWebRequestAlloc(id, bytes.length);
            if (!ptr) return fail();
            if (bytes.length > 0) new Uint8Array(mem(), ptr, bytes.length).set(bytes);
            inst.exports.FizzyWebRequestReady(id, res.status, ptr, bytes.length);
            render();
        })).catch(fail);
    },
    fizzy_web_oauth_open(urlPtr, urlLen) {
        const inst = target();
        if (!inst) return;
        oauthOpen(inst, { type: "oauth", url: str(urlPtr, urlLen) });
    },
    fizzy_web_oauth_open_page(htmlPtr, htmlLen, hashPtr, hashLen) {
        const inst = target();
        if (!inst) return;
        oauthOpen(inst, { type: "oauth", html: str(htmlPtr, htmlLen), hash: str(hashPtr, hashLen) });
    },
    fizzy_web_plugin_load(req, idPtr, idLen, urlPtr, urlLen, shaPtr, shaLen) {
        const inst = wasmInstance;
        if (!inst) return;
        const id = str(idPtr, idLen);
        const url = str(urlPtr, urlLen);
        const sha256 = shaLen ? str(shaPtr, shaLen) : "";
        loadPlugin(req, url, id, sha256).then(render).catch((err) => {
            console.error("fizzy: plugin load failed:", url, err);
            inst.exports.FizzyWebPluginFailed(req);
            render();
        });
    },
    fizzy_web_toggle_fullscreen() {
        postMessage({ type: "fullscreen" });
    },
    fizzy_web_storage_get(keyPtr, keyLen, bufPtr, bufLen) {
        const value = storageGet("fizzy.file:" + str(keyPtr, keyLen));
        if (value === null) return 0xffffffff;
        const bytes = utf8encode(value);
        if (bytes.length <= bufLen) new Uint8Array(mem(), bufPtr, bytes.length).set(bytes);
        return bytes.length;
    },
    fizzy_web_storage_set(keyPtr, keyLen, valPtr, valLen) {
        storageSet("fizzy.file:" + str(keyPtr, keyLen), str(valPtr, valLen));
    },
    fizzy_web_storage_remove(keyPtr, keyLen) {
        storageRemove("fizzy.file:" + str(keyPtr, keyLen));
    },
    fizzy_web_plugin_fingerprint(fpPtr, fpLen) {
        pluginFingerprint = str(fpPtr, fpLen);
    },
    fizzy_web_plugin_remembered_url(idPtr, idLen, bufPtr, bufLen) {
        const url = rememberedPlugins()[str(idPtr, idLen)];
        if (typeof url !== "string") return 0xffffffff;
        const bytes = utf8encode(url);
        if (bytes.length <= bufLen) new Uint8Array(mem(), bufPtr, bytes.length).set(bytes);
        return bytes.length;
    },
    fizzy_web_plugin_forget(idPtr, idLen) {
        forgetPlugin(str(idPtr, idLen));
    },
    fizzy_web_plugin_remember(idPtr, idLen, urlPtr, urlLen) {
        rememberPlugin(str(idPtr, idLen), str(urlPtr, urlLen));
    },
    fizzy_web_oauth_callback_url(bufPtr, bufLen) {
        const inst = target();
        if (!inst) return 0;
        const bytes = utf8encode(new URL("oauth-callback.html", env.baseURI).href);
        if (bytes.length <= bufLen) new Uint8Array(mem(), bufPtr, bytes.length).set(bytes);
        return bytes.length;
    },
    fizzy_web_fetch(id, urlPtr, urlLen) {
        const inst = target();
        if (!inst) return;
        fetch(str(urlPtr, urlLen), { cache: "no-cache" }).then((res) => {
            if (!res.ok) throw new Error("http " + res.status);
            return res.arrayBuffer();
        }).then((buf) => {
            const bytes = new Uint8Array(buf);
            const ptr = inst.exports.FizzyWebFetchAlloc(bytes.length);
            if (!ptr) inst.exports.FizzyWebFetchFailed(id);
            else {
                new Uint8Array(mem(), ptr, bytes.length).set(bytes);
                inst.exports.FizzyWebFetchReady(id, ptr, bytes.length);
            }
            render();
        }).catch(() => {
            inst.exports.FizzyWebFetchFailed(id);
            render();
        });
    },
});

// ---- plugins at runtime (was `index.html`'s loader; see there for the why) --------------------
const rememberedKey = "fizzy.web_plugins";
function rememberedPlugins() {
    try { return JSON.parse(storageGet(rememberedKey) || "{}"); } catch (_) { return {}; }
}
function rememberPlugin(id, url) {
    const all = rememberedPlugins();
    if (all[id] && all[id] !== url) dropPluginBytes(all[id]);
    all[id] = url;
    storageSet(rememberedKey, JSON.stringify(all));
    keepPluginBytes(url);
}
function forgetPlugin(id) {
    const all = rememberedPlugins();
    if (all[id]) dropPluginBytes(all[id]);
    delete all[id];
    storageSet(rememberedKey, JSON.stringify(all));
}

const pluginCacheName = "fizzy-plugins-v1";
const pluginCacheAvailable = typeof caches !== "undefined";
const unkeptPluginBytes = new Map();
function keepablePluginUrl(url) {
    if (!pluginCacheAvailable || !url) return false;
    try {
        const u = new URL(url, env.baseURI);
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
    postMessage({ type: "persistStorage" });
}
function dropPluginBytes(url) {
    if (!keepablePluginUrl(url)) return;
    caches.open(pluginCacheName).then((c) => c.delete(url)).catch(() => {});
}
const warmPluginBytes = new Map();
function warmRememberedPlugins() {
    for (const url of Object.values(rememberedPlugins())) {
        if (keepablePluginUrl(url)) warmPluginBytes.set(url, cachedPluginBytes(url));
    }
}

function requestPlugin(id, url) {
    const inst = wasmInstance;
    const idBytes = utf8encode(id);
    const urlBytes = utf8encode(url || "");
    const idPtr = inst.exports.FizzyWebPluginAlloc(idBytes.length, 1);
    const urlPtr = urlBytes.length ? inst.exports.FizzyWebPluginAlloc(urlBytes.length, 1) : 0;
    if (!idPtr || (urlBytes.length && !urlPtr)) return;
    new Uint8Array(mem(), idPtr, idBytes.length).set(idBytes);
    if (urlBytes.length) new Uint8Array(mem(), urlPtr, urlBytes.length).set(urlBytes);
    inst.exports.FizzyWebPluginRequest(idPtr, idBytes.length, urlPtr, urlBytes.length);
}
function requestUrlPlugins() {
    const inst = wasmInstance;
    if (!inst || !inst.exports.FizzyWebPluginRequest) return;
    const params = new URLSearchParams(env.search);
    for (const [id, url] of Object.entries(rememberedPlugins())) requestPlugin(id, url);
    for (const id of params.getAll("plugin")) requestPlugin(id, "");
    if (inst.exports.FizzyWebStartupPluginsRequested) inst.exports.FizzyWebStartupPluginsRequested();
    render();
    for (const url of params.getAll("open")) {
        fetch(new URL(url, env.baseURI), { cache: "no-store" }).then((r) => r.arrayBuffer()).then((buf) => {
            const name = utf8encode(url.split("/").pop().split("?")[0]);
            const namePtr = wasmInstance.exports.FizzyWebPluginAlloc(name.length, 1);
            const bytes = new Uint8Array(buf);
            const bytesPtr = wasmInstance.exports.FizzyWebPluginAlloc(bytes.length, 1);
            if (!namePtr || !bytesPtr) return;
            new Uint8Array(mem(), namePtr, name.length).set(name);
            new Uint8Array(mem(), bytesPtr, bytes.length).set(bytes);
            wasmInstance.exports.FizzyWebOpenBytes(namePtr, name.length, bytesPtr, bytes.length);
            render();
        }).catch((err) => console.error("fizzy: could not open", url, err));
    }
}

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
        if (type === 1) {
            needs.memorySize = leb();
            needs.memoryAlign = leb();
            needs.tableSize = leb();
            needs.tableAlign = leb();
        }
        pos = end;
    }
    return needs;
}

async function fetchPluginBytes(url) {
    try {
        const direct = await fetch(url, { cache: "no-store" });
        if (direct.ok) return await direct.arrayBuffer();
        if (direct.status === 404) throw new Error("not found: " + url);
    } catch (err) {
        if (String(err).includes("not found")) throw err;
    }
    if (!pluginFingerprint) throw new Error("cannot reach " + url + " and no catalog shard to ask the proxy for");
    const viaProxy = await fetch(pluginProxy + pluginFingerprint + "/" + encodeURIComponent(url), { cache: "no-store" });
    if (!viaProxy.ok) throw new Error("could not fetch " + url + " (proxy said " + viaProxy.status + ")");
    return await viaProxy.arrayBuffer();
}

async function sha256Hex(bytes) {
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function loadPlugin(req, url, id, sha256) {
    const host = wasmInstance;
    const warm = warmPluginBytes.get(url);
    warmPluginBytes.delete(url);
    let bytes = await (warm || cachedPluginBytes(url));
    if (bytes && sha256 && (await sha256Hex(bytes)) !== sha256.toLowerCase()) {
        dropPluginBytes(url);
        bytes = null;
    }
    if (!bytes) {
        bytes = await fetchPluginBytes(new URL(url, env.baseURI).href);
        if (sha256) {
            const got = await sha256Hex(bytes);
            if (got !== sha256.toLowerCase()) throw new Error("sha256 mismatch for " + id + ": expected " + sha256 + ", got " + got);
        }
        if (keepablePluginUrl(url)) unkeptPluginBytes.set(url, bytes);
    }
    const module = await WebAssembly.compile(bytes);
    const needs = readDylinkNeeds(module);
    const memoryBase = host.exports.FizzyWebPluginAlloc(needs.memorySize, 1 << needs.memoryAlign);
    if (!memoryBase) throw new Error("out of memory for plugin data");
    const tableBase = functionTable.length;
    functionTable.grow(needs.tableSize);
    const envImports = {};
    for (const [name, value] of Object.entries(host.exports)) {
        if (typeof value === "function") envImports[name] = value;
    }
    envImports.memory = host.exports.memory;
    envImports.__indirect_function_table = functionTable;
    envImports.__stack_pointer = host.exports.__stack_pointer;
    envImports.__memory_base = new WebAssembly.Global({ value: "i32", mutable: false }, memoryBase);
    envImports.__table_base = new WebAssembly.Global({ value: "i32", mutable: false }, tableBase);
    const missing = WebAssembly.Module.imports(module)
        .filter((i) => i.module === "env" && i.kind === "function" && !(i.name in envImports))
        .map((i) => i.name);
    if (missing.length) throw new Error("the host does not export: " + missing.join(", "));
    const holder = { inst: null };
    const instance = await WebAssembly.instantiate(module, {
        env: envImports,
        fizzy: fizzyImports(() => holder.inst),
        dvui: dvuiApp ? dvuiApp.imports : {},
    });
    holder.inst = instance;
    if (instance.exports.__wasm_apply_data_relocs) instance.exports.__wasm_apply_data_relocs();
    if (instance.exports.__wasm_call_ctors) instance.exports.__wasm_call_ctors();
    const base = functionTable.length;
    functionTable.grow(pluginEntryPoints.length);
    pluginEntryPoints.forEach((name, i) => {
        const fn = instance.exports[name];
        if (!fn) throw new Error("plugin is missing " + name);
        functionTable.set(base + i, fn);
    });
    const list = host.exports.FizzyWebPluginAlloc(4 * pluginEntryPoints.length, 4);
    const indices = new Uint32Array(mem(), list, pluginEntryPoints.length);
    for (let i = 0; i < pluginEntryPoints.length; i++) indices[i] = base + i;
    host.exports.FizzyWebPluginReady(req, list, pluginEntryPoints.length);
}

// ---- keys the app binds -------------------------------------------------------------------
//
// The page decides, in its own `keydown` handler, whether a key is the app's (⌘S must not also
// save the page) — too soon to ask the worker. So the worker asks the app about every key a
// shortcut could name, under every modifier, and hands the page the chords it binds. Asked again
// after any key reaches the app, which is when a binding could have changed.
const probeKeys = (() => {
    const keys = [];
    for (let c = 97; c <= 122; c++) keys.push(String.fromCharCode(c), String.fromCharCode(c - 32));
    for (let c = 48; c <= 57; c++) keys.push(String.fromCharCode(c));
    for (const k of "`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>? ") keys.push(k);
    for (let f = 1; f <= 12; f++) keys.push("F" + f);
    keys.push("Tab", "Enter", "Escape", "Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown", "Insert");
    return keys;
})();
let boundPosted = "";
function postBoundKeys() {
    const ex = wasmInstance && wasmInstance.exports;
    if (!ex || !ex.FizzyWebKeyBound || !ex.FizzyWebKeyBuffer) return;
    const bound = [];
    for (const key of probeKeys) {
        const bytes = utf8encode(key);
        for (let mods = 0; mods < 16; mods++) {
            new Uint8Array(mem(), ex.FizzyWebKeyBuffer(), bytes.length).set(bytes);
            if (ex.FizzyWebKeyBound(bytes.length, mods)) bound.push(key + "|" + mods);
        }
    }
    const joined = bound.join("\n");
    if (joined === boundPosted) return;
    boundPosted = joined;
    postMessage({ type: "boundKeys", keys: bound });
}

// ---- start -------------------------------------------------------------------------------
async function start(init) {
    Object.assign(env, { size: init.size, prefs: init.prefs, storage: init.storage, search: init.search, baseURI: init.baseURI });
    adoptCanvas(init.canvas);
    warmRememberedPlugins();

    const { Dvui } = await import(init.webJsUrl);
    const app = new Dvui();
    const imports = app.imports;

    // What `web.js` does on the page, done by the page.
    imports.wasm_cursor = (ptr, len) => postMessage({ type: "cursor", name: app.stringFromPointer(ptr, len) });
    const textInput = imports.wasm_text_input;
    let lastTextRect = "";
    imports.wasm_text_input = (x, y, w, h) => {
        textInput(x, y, w, h);
        const rect = JSON.stringify(app.textInputRect);
        if (rect !== lastTextRect) {
            lastTextRect = rect;
            postMessage({ type: "textInput", rect: app.textInputRect });
        }
    };
    imports.wasm_open_url = (ptr, len, newWin) => postMessage({ type: "openUrl", url: app.stringFromPointer(ptr, len), newWin: !!newWin });
    imports.wasm_download_data = (namePtr, nameLen, dataPtr, dataLen) => {
        const data = app.bytesFromPointer(dataPtr, dataLen).slice();
        postMessage({ type: "download", name: app.stringFromPointer(namePtr, nameLen), data }, [data.buffer]);
    };
    imports.wasm_open_file_picker = (id, acceptPtr, acceptLen, multiple) => {
        ask({ type: "filePicker", accept: app.stringFromPointer(acceptPtr, acceptLen), multiple: !!multiple }).then((files) => {
            if (files && files.length) {
                app.filesCacheModified = true;
                app.filesCache.set(id, { files: files.map((f) => ({ name: f.name, size: f.size })), data: files.map((f) => f.data) });
            }
            app.requestRender();
        });
    };
    imports.wasm_clipboardTextSet = (ptr, len) => {
        if (len > 0) postMessage({ type: "clipboard", text: app.stringFromPointer(ptr, len) });
    };

    const result = await WebAssembly.instantiateStreaming(fetch(init.wasmUrl), {
        dvui: imports,
        fizzy: fizzyImports(() => wasmInstance),
        env: { __indirect_function_table: functionTable },
    });
    wasmInstance = result.instance;
    app.setInstance(result.instance);
    app.setCanvas(env.canvas);
    app.run();
    dvuiApp = app;
    app.requestRender();
    postMessage({ type: "ready" });
    setTimeout(() => {
        requestUrlPlugins();
        postBoundKeys();
    }, 0);
}

// ---- from the page ----------------------------------------------------------------------------
function addEvent(kind, a, b, c, d) {
    if (!dvuiApp || dvuiApp.stopped) return;
    dvuiApp.instance.exports.add_event(kind, a, b, c, d);
    dvuiApp.requestRender();
}
function addStringEvent(kind, text, c, d) {
    if (!dvuiApp || dvuiApp.stopped) return;
    const bytes = utf8encode(text);
    if (bytes.length === 0 && kind !== 6) return;
    const ptr = dvuiApp.allocBuffer(dvuiApp.instance.exports.arena_u8, bytes);
    dvuiApp.instance.exports.add_event(kind, ptr, bytes.length, c, d);
    dvuiApp.requestRender();
}

onmessage = (e) => {
    const m = e.data;
    switch (m.type) {
        case "init":
            start(m).catch((err) => postMessage({ type: "error", message: err instanceof Error ? err.message : String(err) }));
            break;
        case "size":
            env.size = m.size;
            if (dvuiApp) dvuiApp.requestRender();
            break;
        case "prefs":
            env.prefs = m.prefs;
            if (dvuiApp) dvuiApp.requestRender();
            break;
        case "mouse": {
            // Scaled here: the drawing buffer's size is the worker's.
            if (!dvuiApp) break;
            const gl = dvuiApp.gl;
            addEvent(1, m.mods, 0, m.x * gl.drawingBufferWidth, m.y * gl.drawingBufferHeight);
            break;
        }
        case "event":
            addEvent(m.a[0], m.a[1], m.a[2], m.a[3], m.a[4]);
            break;
        case "key":
            addStringEvent(m.kind, m.key, m.repeat, m.mods);
            if (m.kind === 5) postBoundKeys();
            break;
        case "text":
            addStringEvent(7, m.text, 0, 0);
            break;
        case "pinch":
            if (dvuiApp && wasmInstance.exports.FizzyWebTrackpadMagnification) {
                wasmInstance.exports.FizzyWebTrackpadMagnification(m.amount);
                dvuiApp.requestRender();
            }
            break;
        case "render":
            if (dvuiApp) dvuiApp.requestRender();
            break;
        case "reply": {
            const p = pending.get(m.request);
            if (!p) break;
            pending.delete(m.request);
            p.resolve(m.value);
            break;
        }
    }
};
