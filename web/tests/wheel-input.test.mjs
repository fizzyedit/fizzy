import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
const helper = source.slice(source.indexOf('export function wheelTicks'), source.indexOf('// Pointer input'));
const { wheelTicks } = runInNewContext(helper.replace('export function', 'function') + '\n({ wheelTicks })');
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
