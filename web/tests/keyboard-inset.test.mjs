// The on-screen keyboard reaches the app as a bottom inset, never as a resize: the canvas keeps
// its size, so nothing clears or re-lays out. Run: `node web/tests/keyboard-inset.test.mjs`.
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert';

const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
const fn = source.slice(source.indexOf('export function keyboardInset'), source.indexOf('import { Dvui'));
const { keyboardInset } = runInNewContext(fn.replace('export function', 'function') + '\n({ keyboardInset })');

class Target {
  listeners = {};
  addEventListener(type, fn) { this.listeners[type] = fn; }
  fire(type) { this.listeners[type](); }
}

// Chrome on Android: the VirtualKeyboard API, with the browser told not to resize or pan.
{
  const vk = Object.assign(new Target(), { overlaysContent: false, boundingRect: { height: 0 } });
  const sent = [];
  const bottom = keyboardInset({ navigator: { virtualKeyboard: vk }, innerHeight: 800 }, (m) => sent.push(m));
  assert.equal(vk.overlaysContent, true);
  vk.boundingRect = { height: 301.4 };
  vk.fire('geometrychange');
  vk.fire('geometrychange');
  assert.deepEqual(sent, [{ type: 'inset', bottom: 301 }]);
  assert.equal(bottom(), 301);
  vk.boundingRect = { height: 0 };
  vk.fire('geometrychange');
  assert.deepEqual(sent.at(-1), { type: 'inset', bottom: 0 });
  assert.ok(sent.every((m) => m.type !== 'size'));
}

// iOS Safari: the visual viewport shrinks (and may scroll) over the layout viewport.
{
  const vv = Object.assign(new Target(), { height: 800, offsetTop: 0 });
  const win = { navigator: {}, innerHeight: 800, visualViewport: vv };
  const sent = [];
  keyboardInset(win, (m) => sent.push(m));
  vv.height = 500;
  vv.fire('resize');
  vv.offsetTop = 40;
  vv.fire('scroll');
  vv.height = 900;
  vv.offsetTop = 0;
  vv.fire('resize');
  assert.deepEqual(sent, [{ type: 'inset', bottom: 300 }, { type: 'inset', bottom: 260 }, { type: 'inset', bottom: 0 }]);
  assert.ok(sent.every((m) => m.type !== 'size'));
}
console.log('keyboard-inset: ok');
