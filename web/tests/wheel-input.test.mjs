import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
// Import the whole module with only its browser dependencies replaced.
const moduleSource = source.replace(/import \{ Dvui, TextInput \} from "[^"\n]+";/,
  'class Dvui {} class TextInput {}');
globalThis.document = { fullscreenEnabled: false };
const { wheelTicks, wheelInput } = await import(`data:text/javascript;base64,${Buffer.from(moduleSource).toString('base64')}`);
delete globalThis.document;
const initial = () => ({ lowestBatch: [99999, 99999] });
const event = (deltaY, extra = {}) => ({ deltaX: 0, deltaY, deltaMode: 0, ...extra });
const vertical = (result) => result.events.map(({ ticks, trackpad }) => ({ ticks, trackpad }));
for (const prior of [0.25, 1, 3.5, 100]) {
  let state = wheelTicks(event(prior), initial()).state;
  let pixels = 0;
  for (let i = 0; i < 10; i++) {
    const result = wheelTicks(event(10, { wheelDeltaY: -30 }), state);
    assert.deepEqual(vertical(result), [{ ticks: -10 / 80, trackpad: 1 }]);
    pixels -= result.events[0].ticks * 80;
    state = result.state;
  }
  assert.equal(pixels, 100);
}
for (const delta of [40, 80, 100, 120, 0.25]) {
  assert.deepEqual(vertical(wheelTicks(event(delta, { wheelDeltaY: -3 * delta }), initial())),
    [{ ticks: -delta / 80, trackpad: 1 }]);
}
for (const [delta, extra, ticks] of [
  [100, {}, -1], [200, {}, -2], [66.67, { wheelDeltaY: -120 }, -1],
  [96, { wheelDeltaY: -240 }, -2], [3, { deltaMode: 1 }, -1],
  [4, { deltaMode: 1 }, -1], [6, { deltaMode: 1 }, -2],
]) {
  assert.deepEqual(vertical(wheelTicks(event(delta, extra), initial())), [{ ticks, trackpad: 0 }]);
}
const tail = [10, 8, 4, 2, 1, 0.25];
assert.equal(tail.reduce((sum, delta) => sum - wheelTicks(event(delta), initial()).events[0].ticks * 80, 0),
  tail.reduce((sum, delta) => sum + delta, 0));

function reader() {
  let ms = 0;
  let listener;
  const sent = [];
  const canvas = { addEventListener(name, fn, options) {
    assert.equal(name, 'wheel');
    assert.equal(options.capture, true);
    assert.equal(options.passive, false);
    listener = fn;
  } };
  wheelInput(canvas, (...args) => sent.push(args), () => ms);
  return { sent, emit(deltaY, extra = {}, elapsed = 0) {
    ms += elapsed;
    let prevented = false;
    let stopped = false;
    listener({ ...event(deltaY), ctrlKey: false, ...extra,
      preventDefault() { prevented = true; },
      stopImmediatePropagation() { stopped = true; },
    });
    return { prevented, stopped };
  } };
}
{
  const r = reader();
  assert.deepEqual(r.emit(66.67, { wheelDeltaY: -120 }), { prevented: true, stopped: true },
    'a notch is consumed before dvui sees it');
  assert.deepEqual(r.sent, [[1, 0, -1]], 'a notch on a 150% display sends one tick');
}
{
  const r = reader();
  r.emit(0.25);
  r.emit(10);
  r.emit(100, {}, 500);
  r.emit(10, {}, 1100);
  assert.deepEqual(r.sent, [[1, 1, -0.25 / 80], [1, 1, -10 / 80], [1, 0, -1], [1, 1, -10 / 80]],
    'each event keeps its kind and pixel scale across batches');
}
{
  const r = reader();
  assert.deepEqual(r.emit(3.5, { ctrlKey: true }), { prevented: false, stopped: false });
  assert.deepEqual(r.sent, [], "a pinch is the pinch listener's");
  r.emit(100, { deltaX: 100 });
  assert.deepEqual(r.sent, [[0, 0, -1], [1, 0, -1]], 'both axes');
}
console.log('wheel reader: pixel distance, fractional history, momentum, notches, mixed kinds and capture passed');
