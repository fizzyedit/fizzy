import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';

// Exercise the page's actual input adapter without loading the wasm/browser runtime.
const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
const adapter = source.slice(source.indexOf('export function pointerInput'), source.indexOf('import { Dvui'));
const { pointerInput } = runInNewContext(adapter.replace('export function', 'function') + '\n({ pointerInput })');
const listeners = {};
const sent = [];
const canvas = {
  style: {},
  addEventListener(name, fn) { listeners[name] = fn; },
  setPointerCapture() {},
  getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 200 }; },
};
pointerInput(canvas, (m) => sent.push(m), 10000);
const event = (id, x, time) => ({ pointerId: id, pointerType: 'touch', clientX: x, clientY: 100, timeStamp: time, stopImmediatePropagation() {} });
listeners.pointerdown(event(5, 10, 1));
listeners.pointermove({ ...event(5, 40, 4), getCoalescedEvents: () => [event(5, 20, 2), event(5, 30, 3), event(5, 40, 4)] });
assert.equal(sent.length, 2);
assert.equal(sent[1].events.length, 3);
assert.deepEqual(Array.from(sent[1].events, (e) => e.time - 9000), [1002, 1003, 1004]);
assert.deepEqual(Array.from(sent[1].events, (e) => e.a[3]), [0.2, 0.3, 0.4]);
assert.equal(canvas.style.touchAction, 'none');
assert.equal(listeners.touchstart, undefined);
listeners.pointerdown(event(6, 10, 5));
listeners.pointerup(event(5, 40, 6));
listeners.pointerdown(event(7, 10, 7));
assert.equal(sent.at(-1).events[0].a[1], 0);
listeners.pointermove(event(6, 20, 8));
assert.equal(sent.at(-1).events[0].a[1], 1);
listeners.pointercancel(event(6, 20, 9));
assert.equal(sent.at(-1).events[0].a[0], 9);
console.log('pointer input: coalescing, clocks, fallback, cancellation and stable slots passed');
const worker = readFileSync(new URL('../fizzy-worker.js', import.meta.url), 'utf8');
const batchCase = worker.slice(worker.indexOf('        case "input":'), worker.indexOf('        case "event":'));
const calls = [];
let renders = 0;
runInNewContext('switch (m.type) { ' + batchCase + ' }', {
  m: sent[1], performance: { timeOrigin: 9000 },
  dvuiApp: { instance: { exports: { add_event: (...a) => calls.push(a) } }, requestRender: () => renders++ },
});
assert.deepEqual(calls.map((a) => a[5]), [1002, 1003, 1004]);
assert.equal(renders, 1);

// The second press and first release of a chord are pointermove events.
const chordStart = sent.length;
const mouse = (buttons, time) => ({ ...event(1, 50, time), pointerType: 'mouse', buttons, button: buttons === 3 || buttons === 0 ? 2 : 0 });
listeners.pointerdown(mouse(1, 10));
listeners.pointermove(mouse(3, 11));
listeners.pointermove(mouse(2, 12));
listeners.pointerup(mouse(0, 13));
assert.deepEqual(sent.slice(chordStart).flatMap((m) => Array.from(m.events).filter((e) => e.a).map((e) => Array.from(e.a).slice(0, 2))),
  [[2, 0], [2, 2], [3, 0], [3, 2]]);
listeners.pointerdown(mouse(5, 14));
listeners.pointercancel(mouse(5, 15));
assert.deepEqual(Array.from(sent.at(-1).events).filter((e) => e.a).map((e) => Array.from(e.a).slice(0, 2)), [[3, 0], [3, 1]]);
console.log('pointer input: chord transitions and cancellation passed');
