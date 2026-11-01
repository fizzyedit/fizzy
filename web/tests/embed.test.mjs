// Two copies of fizzy on one page, against a fake DOM and a fake wasm: the page's own fields keep
// their keys, a chord goes to the copy it is aimed at, full screen takes the embed, and the editor
// is fetched and compiled once. Run: `node web/tests/embed.test.mjs`.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

// fizzy.js as the build stamps it, beside a `web.js` that is only a stand-in for dvui's.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fizzy-embed-"));
const source = fs.readFileSync(new URL("../fizzy.js", import.meta.url), "utf8")
  .replace("__FIZZY_WEB_STORAGE__", "test")
  .replaceAll("?cache-buster=TEMPLATE_HASH_WITH_PADDING__ITS_64_BYTES_LONG_THE_SAME_AS_SHA256", "");
fs.writeFileSync(path.join(dir, "fizzy.js"), source);
fs.writeFileSync(path.join(dir, "web.js"), `
export class TextInput {
  keydown() {}
  clear() {}
}
export class Dvui {
  constructor() { this.imports = {}; this.hidden_input = null; }
  setInstance(instance) { this.instance = instance; }
  setCanvas(canvas) { this.canvas = canvas; this.gl = { drawingBufferWidth: 100, drawingBufferHeight: 100 }; }
  run() { this.hidden_input = globalThis.document.createElement("input"); }
  requestRender() {}
  oskCheck() { globalThis.oskChecks++; }
}
`);

class Target {
  constructor() { this.listeners = {}; this.children = []; this.parentElement = null; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  removeEventListener() {}
  dispatch(type, ev) { for (const fn of this.listeners[type] ?? []) fn(ev); }
  prepend(child) { child.parentElement = this; this.children.unshift(child); }
}
class Element extends Target {
  constructor() { super(); this.style = {}; this.fullscreen = 0; }
  setAttribute() {}
  focus() {}
  getBoundingClientRect() { return { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 }; }
  requestFullscreen() { fullscreenStack.push(this); document.fullscreenElement = this; this.fullscreen++; document.dispatch("fullscreenchange", {}); return Promise.resolve(); }
}
class Canvas extends Element {
  constructor() { super(); this.clientWidth = 100; this.clientHeight = 100; }
  getContext() { return {}; }
  setPointerCapture() {}
}
globalThis.oskChecks = 0;
const fullscreenStack = [];
const document = Object.assign(new Target(), {
  fullscreenElement: null,
  baseURI: "http://localhost/",
  body: new Element(),
  documentElement: new Element(),
  createElement: (tag) => (tag === "canvas" ? new Canvas() : new Element()),
  exitFullscreen() { fullscreenStack.pop(); document.fullscreenElement = fullscreenStack.at(-1) ?? null; document.dispatch("fullscreenchange", {}); return Promise.resolve(); },
});
const window = Object.assign(new Target(), {
  visualViewport: Object.assign(new Target(), { height: 100, offsetTop: 0 }),
  devicePixelRatio: 1, scrollX: 0, scrollY: 0, localStorage: new Map(), parent: null,
  dispatchEvent() {}, matchMedia: () => ({ matches: false, addEventListener() {} }),
});
window.parent = window;
Object.assign(globalThis, {
  window, document, HTMLCanvasElement: Canvas, Event: class {}, requestAnimationFrame: (f) => setTimeout(f, 0),
  screen: { width: 800, height: 600 }, TextEncoder, TextDecoder, location: { href: "http://localhost/" },
});
Object.defineProperty(globalThis, "navigator", { value: {}, configurable: true });

// The editor: a module that answers FizzyWebKeyBound for the chord Ctrl+S, counting its asks.
let fetches = 0;
let compiles = 0;
const bound = [];
const toggles = [];
const storageApis = [];
const insets = [];
const memory = new WebAssembly.Memory({ initial: 1 });
globalThis.fetch = (url) => { fetches++; return Promise.resolve({ url }); };
WebAssembly.compileStreaming = async () => { compiles++; return { fake: true }; };
WebAssembly.instantiate = async (module, imports) => {
  const id = bound.length;
  bound.push([]);
  insets.push([]);
  toggles.push(imports.fizzy.fizzy_web_toggle_fullscreen);
  storageApis.push(imports.fizzy);
  return {
    exports: {
      memory: { buffer: memory.buffer },
      add_event() {},
      FizzyWebSetKeyboardInset: (bottom) => insets[id].push(bottom),
      FizzyWebKeyBuffer: () => 0,
      FizzyWebKeyBound: (len, mods) => { bound[id].push([len, mods]); return 1; },
    },
  };
};
WebAssembly.Table = class {};

const { Fizzy } = await import(pathToFileURL(path.join(dir, "fizzy.js")).href);

const mount = async (parent, options = {}) => {
  const canvas = document.createElement("canvas");
  canvas.parentElement = parent;
  const ready = new Promise((resolve, reject) => {
    new Fizzy({ canvas, worker: false, persist: false, ...options, onReady: resolve, onError: reject, onInstance: () => {} }).run();
  });
  await ready;
  return canvas;
};
const a = await mount(new Element());
const b = await mount(new Element());

document.activeElement = a;
window.dispatch("focusin", { target: a });
window.visualViewport.height = 60;
window.visualViewport.dispatch("resize", {});
assert.deepEqual(insets, [[40], []], "only the focused main-thread embed receives the inset");
window.visualViewport.height = 100;
window.visualViewport.dispatch("resize", {});
assert.deepEqual(insets, [[40, 0], []], "closing the keyboard clears the main-thread inset");
window.visualViewport.height = 60;
window.visualViewport.dispatch("resize", {});
const checksBeforeBlur = globalThis.oskChecks;
document.activeElement = new Element();
window.dispatch("focusin", { target: document.activeElement });
assert.equal(globalThis.oskChecks, checksBeforeBlur, "clearing an inactive embed never refocuses its input");
assert.equal(insets[0].at(-1), 0);
window.visualViewport.height = 100;


assert.equal(compiles, 1, "two copies share one compile");
assert.equal(fetches, 1, "two copies share one download");

const key = (target) => {
  const ev = { target, key: "s", ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  window.dispatch("keydown", ev);
  return ev;
};

const field = new Element();
assert.equal(key(field).defaultPrevented, false, "a chord typed into the page's own field stays the page's");
assert.deepEqual(bound, [[], []], "the editors were not asked");

assert.equal(key(a).defaultPrevented, true, "a chord on the first copy is its");
assert.deepEqual(bound.map((asks) => asks.length), [1, 0], "only the copy it was aimed at is asked");
assert.equal(key(b).defaultPrevented, true);
assert.deepEqual(bound.map((asks) => asks.length), [1, 1]);

b.dispatch("pointerdown", { pointerId: 1, pointerType: "mouse", buttons: 1, clientX: 0, clientY: 0, timeStamp: 0 });
assert.equal(key(document.body).defaultPrevented, true, "with nothing focused the last copy used has the key");
assert.deepEqual(bound.map((asks) => asks.length), [1, 2]);

// View › Toggle Full Screen: the copy's own element, not the page; the other copy switches to its own.
const parentA = a.parentElement;
const parentB = b.parentElement;
toggles[0]();
assert.equal(document.fullscreenElement, parentA, "full screen shows the embed, not the page");
assert.equal(document.documentElement.fullscreen, 0);
toggles[1]();
assert.equal(document.fullscreenElement, parentB, "the other copy takes full screen for itself");
toggles[1]();
assert.equal(document.fullscreenElement, parentA, "leaving the second embed reveals the first");
toggles[0]();
assert.equal(document.fullscreenElement, null, "leaving the first embed exits full screen");
// Independent app namespaces share only the person's preferences.
const stored = new Map();
window.localStorage = {
  getItem: (key) => stored.get(key) ?? null,
  setItem: (key, value) => stored.set(key, value),
  removeItem: (key) => stored.delete(key),
  key: (i) => [...stored.keys()][i] ?? null,
  get length() { return stored.size; },
};
await mount(new Element(), { persist: true, storage: "left" });
await mount(new Element(), { persist: true, storage: "right" });
const encoder = new TextEncoder();
const put = (api, key, value) => {
  const k = encoder.encode(key), v = encoder.encode(value);
  new Uint8Array(memory.buffer, 0, k.length).set(k);
  new Uint8Array(memory.buffer, 256, v.length).set(v);
  api.fizzy_web_storage_set(0, k.length, 256, v.length);
};
const get = (api, key) => {
  const k = encoder.encode(key);
  new Uint8Array(memory.buffer, 0, k.length).set(k);
  const n = api.fizzy_web_storage_get(0, k.length, 512, 256);
  return n === 0xffffffff ? null : new TextDecoder().decode(new Uint8Array(memory.buffer, 512, n));
};
put(storageApis[2], "fizzyedit.person", ".{ .motion = 0.4 }");
assert.equal(stored.get("fizzyedit.person"), ".{ .motion = 0.4 }");
assert.equal(get(storageApis[3], "fizzyedit.person"), ".{ .motion = 0.4 }");
put(storageApis[2], "settings.zon", ".{}");
assert.equal(get(storageApis[3], "settings.zon"), null);
const epoch = storageApis[3].fizzy_web_focus_epoch();
window.dispatch("focus", {});
assert.equal(storageApis[3].fizzy_web_focus_epoch(), epoch + 1);
console.log("embed.test: ok");

// Deliver text input as soon as the handler is installed, before setup completes.
let earlyTextInputs = 0;
let filterClears = 0;
const { TextInput } = await import(pathToFileURL(path.join(dir, "web.js")).href);
TextInput.prototype.clear = () => { filterClears++; };
Canvas.prototype.transferControlToOffscreen = function () { return {}; };
globalThis.OffscreenCanvas = class {};
globalThis.ResizeObserver = class { observe() {} };
const workerMessages = [];
globalThis.Worker = class {
  set onmessage(handler) {
    this.handler = handler;
    handler({ data: { type: "textInput", rect: [10, 20, 80, 30] } });
    earlyTextInputs++;
  }
  postMessage(message) {
    workerMessages.push(message);
    if (message.type === "init") this.handler({ data: { type: "ready" } });
  }
};
const workerCanvas = document.createElement("canvas");
workerCanvas.parentElement = new Element();
const focusBefore = (window.listeners.focus ?? []).length;
await new Promise((resolve, reject) => {
  new Fizzy({ canvas: workerCanvas, worker: true, persist: false, onReady: resolve, onError: reject }).run();
});
assert.equal((window.listeners.focus ?? []).length - focusBefore, 2, "worker mode adds only startWorker's two window focus listeners");
assert.equal(earlyTextInputs, 1, "worker text input is handled during setup");
assert.equal(filterClears, 1, "entering text input clears the initialized filter");
assert.equal(document.body.children[0].style.left, "10px", "early text input positions the hidden input");
workerCanvas.dispatch("pointerdown", { pointerId: 1, pointerType: "mouse", buttons: 1, clientX: 0, clientY: 0, timeStamp: 0 });
assert.equal(filterClears, 2, "pointer input still clears the filter");
console.log("embed.test: worker startup and early text input ok");

document.activeElement = document.body.children[0];
window.dispatch("focusin", { target: document.activeElement });
window.visualViewport.height = 60;
window.visualViewport.dispatch("resize", {});
window.dispatch("resize", {});
assert.equal(workerMessages.at(-1).type, "inset", "a keyboard-only resize never posts a worker size");
assert.equal(workerMessages.at(-1).bottom, 40);
assert.equal(document.activeElement.style.top, "20px", "the input stays above the keyboard");
window.visualViewport.height = 100;
window.visualViewport.dispatch("resize", {});
assert.equal(workerMessages.at(-1).bottom, 0);
console.log("embed.test: worker keyboard inset and resize suppression ok");
