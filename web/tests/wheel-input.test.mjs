import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
// Import the whole module with only its browser dependencies replaced.
const moduleSource = source.replace(/import \{ Dvui, TextInput \} from "[^"\n]+";/,
  'class Dvui {} class TextInput {}');
globalThis.document = { fullscreenEnabled: false };
const { wheelTicks, wheelInput } = await import(`data:text/javascript;base64,${Buffer.from(moduleSource).toString('base64')}`);
delete globalThis.document;
const initial = () => ({ lowest: [99999, 99999], lowestBatch: [99999, 99999] });
const event = (deltaY, extra = {}) => ({ deltaX: 0, deltaY, deltaMode: 0, ...extra });
const vertical = (result) => Array.from(result.events, ({ axis, ticks, trackpad }) => ({ axis, ticks, trackpad }));

for (const deltaY of [96, 66.67, 57.14, 100]) {
  for (const direction of [1, -1]) {
    const state = initial();
    assert.deepEqual(vertical(wheelTicks(event(deltaY * direction, { wheelDeltaY: -120 * direction }), state)),
      [{ axis: 1, ticks: -direction, trackpad: 0 }]);
    assert.deepEqual(state, initial(), 'classification does not mutate the supplied state');
  }
}
assert.deepEqual(vertical(wheelTicks(event(96, { wheelDeltaY: -240 }), initial())),
  [{ axis: 1, ticks: -2, trackpad: 0 }]);

for (const wheelDeltaY of [undefined, 0, -30]) {
  let state = initial();
  for (const deltaY of [3.5, 7, 12]) {
    const result = wheelTicks(event(deltaY, { wheelDeltaY }), state);
    assert.deepEqual(vertical(result), [{ axis: 1, ticks: -deltaY / 3.5 * 0.025, trackpad: 1 }]);
    state = result.state;
  }
}
// macOS trackpad flicks can also have legacy deltas that are multiples of 120.
for (const direction of [1, -1]) {
  for (const deltas of [[40, 80, 120], [3.5, 40, 80, 120]]) {
    let state = initial();
    for (const magnitude of deltas) {
      const deltaY = magnitude * direction;
      const result = wheelTicks(event(deltaY, { wheelDeltaY: -3 * deltaY }), state);
      assert.deepEqual(vertical(result),
        [{ axis: 1, ticks: -deltaY / deltas[0] * 0.025, trackpad: 1 }]);
      state = result.state;
    }
  }
}
for (const deltaMode of [1, 2]) {
  let state = initial();
  for (const deltaY of [3, 6]) {
    const result = wheelTicks(event(deltaY, { deltaMode, wheelDeltaY: -120 }), state);
    assert.deepEqual(vertical(result), [{ axis: 1, ticks: -deltaY / 3, trackpad: 0 }]);
    state = result.state;
  }
}
for (const deltaY of [100, 16, 4.000244140625]) {
  assert.deepEqual(vertical(wheelTicks(event(deltaY), initial())),
    [{ axis: 1, ticks: deltaY === 4.000244140625 ? -0.025 : -1, trackpad: 0 }]);
}
for (const deltaX of [9, 40]) {
  assert.deepEqual(vertical(wheelTicks(event(0, { deltaX, wheelDeltaY: -120 }), initial())),
    [{ axis: 0, ticks: -1, trackpad: 0 }]);
}
assert.deepEqual(vertical(wheelTicks(event(0, { wheelDeltaY: 0 }), initial())), []);
// A new batch forgets its minimum but retains the device-wide trackpad minimum.
const trackpadState = wheelTicks(event(3.5), initial()).state;
const nextBatch = { ...trackpadState, lowestBatch: [99999, 99999] };
assert.deepEqual(vertical(wheelTicks(event(7), nextBatch)), [{ axis: 1, ticks: -0.05, trackpad: 1 }]);
assert.deepEqual(vertical(wheelTicks(event(96, { wheelDeltaY: -120 }), trackpadState)),
  [{ axis: 1, ticks: -1, trackpad: 0 }]);
console.log('wheel input: scaled Windows notches, trackpads, line/page modes and fallback axes passed');

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
  r.emit(3.5);
  r.emit(7);
  r.emit(100, {}, 500);
  assert.deepEqual(r.sent.map((a) => a[1]), [1, 1, 1]);
  r.emit(100, {}, 1100);
  assert.deepEqual(r.sent.at(-1), [1, 0, -1], 'the batch minima reset after a second');
  r.emit(7);
  assert.deepEqual(r.sent.at(-1), [1, 1, -0.05], 'the all-time minimum is not reset');
}
{
  const r = reader();
  assert.deepEqual(r.emit(3.5, { ctrlKey: true }), { prevented: false, stopped: false });
  assert.deepEqual(r.sent, [], "a pinch is the pinch listener's");
  r.emit(100, { deltaX: 100 });
  assert.deepEqual(r.sent, [[0, 0, -1], [1, 0, -1]], 'both axes');
}
console.log('wheel reader: capture, scaled notches, batch reset, retained minimum, pinch and both axes passed');
