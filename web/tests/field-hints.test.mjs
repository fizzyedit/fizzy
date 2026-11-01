// Keyboard attributes follow the focused field and reset when it publishes no hints.
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
const fn = source.slice(source.indexOf('export function fieldHints'), source.indexOf('// Pixel deltas'));
const { fieldHints } = runInNewContext(fn.replace('export function', 'function') + '\n({ fieldHints })');
const el = {
  attrs: {},
  setAttribute(name, value) { this.attrs[name] = value; },
  removeAttribute(name) { delete this.attrs[name]; },
};
fieldHints(el, 1);
assert.deepEqual(el.attrs, {
  autocorrect: 'off', spellcheck: 'false', autocapitalize: 'none', inputmode: 'text', enterkeyhint: 'enter',
});
fieldHints(el, 64 | 128 | (1 << 3));
assert.deepEqual(el.attrs, {
  autocorrect: 'on', spellcheck: 'true', autocapitalize: 'sentences', inputmode: 'text', enterkeyhint: 'send',
});
for (const [kind, mode] of [[2, 'url'], [3, 'email'], [4, 'numeric'], [5, 'search']]) {
  fieldHints(el, kind | (4 << 3));
  assert.equal(el.attrs.inputmode, mode);
  assert.equal(el.attrs.enterkeyhint, 'search');
}
for (const [enter, hint] of [[2, 'done'], [3, 'next']]) {
  fieldHints(el, enter << 3);
  assert.equal(el.attrs.enterkeyhint, hint);
}
for (const sentinel of [0xFFFFFFFF, -1]) {
  fieldHints(el, sentinel);
  assert.deepEqual(el.attrs, { autocapitalize: 'none' });
}
console.log('field-hints: ok');
