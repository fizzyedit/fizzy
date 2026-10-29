// Run the actual request helper and both callers with a fresh document for each page load.
// This isolates the page's routing and diagnostics; it does not reproduce a browser reload.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const source = readFileSync(new URL("../fizzy.js", import.meta.url), "utf8");
const worker = readFileSync(new URL("../fizzy-worker.js", import.meta.url), "utf8");
const helper = source.slice(source.indexOf("    function fullscreenTarget()"), source.indexOf("    // Shortcuts the app binds"));
const mainImport = source.match(/fizzy_web_toggle_fullscreen\(\) \{([\s\S]*?)\n        \},/)[1];
const workerImport = worker.match(/fizzy_web_toggle_fullscreen\(\) \{([\s\S]*?)\n    \},/)[1];
const messageCase = source.slice(source.indexOf('          case "fullscreen":'), source.indexOf('          case "oauth":'));

for (let load = 0; load < 2; load++) {
  const logs = [];
  let requests = 0;
  const document = { fullscreenElement: null };
  const target = {
    requestFullscreen() {
      requests++;
      document.fullscreenElement = target;
      return Promise.resolve();
    },
  };
  document.exitFullscreen = () => {
    document.fullscreenElement = null;
    return Promise.resolve();
  };
  const navigator = { userActivation: { isActive: false, hasBeenActive: false } };
  const context = {
    document, navigator, opts: {}, dvuiCanvas: { parentElement: target },
    console: { debug: (...args) => logs.push(args), warn: () => {} },
  };
  // No request is made by loading the helper or by merely obtaining user activation.
  runInNewContext(helper, context);
  navigator.userActivation.isActive = true;
  navigator.userActivation.hasBeenActive = true;
  assert.equal(requests, 0);
  assert.equal(document.fullscreenElement, null);

  runInNewContext(mainImport, context);
  assert.equal(requests, 1);
  assert.equal(logs.length, 1, "the wasm request logs its caller and activation");
  assert.equal(logs[0][1].caller, "wasm import");
  assert.equal(logs[0][1].action, "enter");
  assert.equal(logs[0][1].userActivation.isActive, true);
  assert.match(logs[0][1].stack, /toggleFullscreen/);

  let message;
  runInNewContext(workerImport, { postMessage: (m) => { message = m; } });
  assert.match(message.stack, /fullscreen wasm import/);
  context.m = message;
  runInNewContext('switch (m.type) { ' + messageCase + ' }', context);
  assert.equal(document.fullscreenElement, null);
  assert.equal(logs[1][1].caller, "worker message");
  assert.equal(logs[1][1].action, "exit");
  assert.equal(logs[1][1].workerStack, message.stack);
}
console.log("fullscreen: fresh page state, explicit callers and activation diagnostics passed");
