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
  fire(type) { this.listeners[type]?.(); }
}

// Chrome on Android: the VirtualKeyboard API, with the browser told not to resize or pan.
{
  const vk = Object.assign(new Target(), { overlaysContent: false, boundingRect: { height: 0 } });
  const sent = [];
  const bottom = keyboardInset({
    navigator: { virtualKeyboard: vk }, innerHeight: 800, visualViewport: new Target(),
    document: { querySelector: () => ({ content: 'interactive-widget=overlays-content' }) },
  }, (m) => sent.push(m));
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

// The visual viewport handles Safari and Chrome pages without an overlay directive.
for (const navigator of [{}, { virtualKeyboard: Object.assign(new Target(), { overlaysContent: false, boundingRect: { height: 0 } }) }]) {
  const vv = Object.assign(new Target(), { height: 800, offsetTop: 0 });
  const win = { navigator, innerHeight: 800, visualViewport: vv };
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
  if (navigator.virtualKeyboard) assert.equal(navigator.virtualKeyboard.overlaysContent, false);
}
// A resizes-content page must retain the focused canvas's height; embeds measure overlap.
{
  const vv = Object.assign(new Target(), { height: 800, offsetTop: 0 });
  const win = Object.assign(new Target(), { navigator: {}, innerHeight: 800, visualViewport: vv });
  let height = 600;
  let owned = true;
  const canvas = { style: { height: '100%' }, getBoundingClientRect: () => ({ bottom: 100 + height, height }) };
  const sent = [];
  keyboardInset(win, (m) => sent.push(m), canvas, () => owned);
  win.fire('focusin');
  height = 300;
  vv.height = 500;
  win.innerHeight = 500;
  win.fire('resize');
  assert.equal(canvas.style.height, '600px');
  assert.equal(sent.at(-1).bottom, 200, 'overlap uses the original canvas bottom, not the window bottom');
  owned = false;
  vv.fire('resize');
  assert.equal(sent.at(-1).bottom, 0, 'another focused copy clears the inset');
  assert.equal(canvas.style.height, '100%', 'the original CSS height is restored');
}
// Android resizes-content: VK geometry and layout events must not add two occlusions.
{
  const vk = Object.assign(new Target(), { overlaysContent: false, boundingRect: { y: 1018, height: 0 } });
  const vv = Object.assign(new Target(), { height: 1018, offsetTop: 0 });
  const win = Object.assign(new Target(), {
    navigator: { virtualKeyboard: vk }, innerHeight: 1018, visualViewport: vv,
    document: { querySelector: () => ({ content: 'viewport-fit=cover, interactive-widget=resizes-content' }) },
  });
  let height = 1018;
  const canvas = { style: { height: '100%' }, getBoundingClientRect: () => ({ bottom: height, height }) };
  const sent = [];
  const bottom = keyboardInset(win, (m) => sent.push(m), canvas);
  for (let tap = 0; tap < 3; tap++) {
    win.fire('focusin');
    vv.height = 648;
    vk.boundingRect = { y: 648, height: 370 };
    vk.fire('geometrychange');
    vv.fire('resize');
    assert.equal(bottom(), 370);
    vv.height = 302;
    vk.boundingRect = { y: -44, height: 716 };
    vk.fire('geometrychange');
    vv.fire('resize');
    assert.equal(bottom(), 716);
    assert.ok(sent.every((m) => m.bottom <= 716), 'never sum successive keyboard rectangles');
    // The viewport settles at the real keyboard edge while VK keeps a displaced origin.
    vv.height = 672;
    vk.boundingRect = { y: 302, height: 346 };
    vk.fire('geometrychange');
    vv.fire('resize');
    assert.equal(bottom(), 346);
    height = 672;
    win.innerHeight = 672;
    win.fire('resize');
    assert.equal(canvas.style.height, '1018px');
    vv.height = height = win.innerHeight = 1018;
    vk.boundingRect = { y: 1018, height: 0 };
    vk.fire('geometrychange');
    vv.fire('resize');
    assert.equal(bottom(), 0);
    assert.equal(canvas.style.height, '100%');
  }
  assert.equal(vk.overlaysContent, false, 'respect the page viewport policy');
}
console.log('keyboard-inset: ok');
