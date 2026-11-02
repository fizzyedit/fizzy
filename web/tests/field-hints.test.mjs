import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
const fn = source.slice(source.indexOf('export function fieldHints'), source.indexOf('// Pixel deltas'));
const { fieldHints } = runInNewContext(fn.replace('export function', 'function') + '\n({ fieldHints })');
const attributes = new Map();
const el = {
  setAttribute: (name, value) => attributes.set(name, value),
  removeAttribute: (name) => attributes.delete(name),
};
fieldHints(el, 1);
assert.equal(attributes.get('autocorrect'), 'off');
assert.equal(attributes.get('spellcheck'), 'false');
assert.equal(attributes.get('autocapitalize'), 'none');
assert.equal(attributes.get('inputmode'), 'text');
fieldHints(el, 192 | (1 << 3));
assert.equal(attributes.get('autocorrect'), 'on');
assert.equal(attributes.get('spellcheck'), 'true');
assert.equal(attributes.get('autocapitalize'), 'sentences');
assert.equal(attributes.get('enterkeyhint'), 'send');
for (const [kind, mode] of ['text', 'text', 'url', 'email', 'numeric', 'search'].entries()) {
  fieldHints(el, kind);
  assert.equal(attributes.get('inputmode'), mode);
}
for (const [enter, hint] of ['enter', 'send', 'done', 'next', 'search'].entries()) {
  fieldHints(el, enter << 3);
  assert.equal(attributes.get('enterkeyhint'), hint);
}
for (const reset of [0xFFFFFFFF, -1]) {
  fieldHints(el, reset);
  assert.deepEqual([...attributes], [['autocapitalize', 'none']]);
}

// Exercise the actual page-mode dvui import expression with a real wasm import.
// This catches a missing import as a LinkError, even without built web assets.
const pageImport = source.match(/dvui: (\{ \.\.\.app\.imports, wasm_field_hints: \(\) => \{\} \}),/);
assert.ok(pageImport, 'page mode must provide the field-hints import');
const existingImport = () => 42;
const dvui = runInNewContext(`(${pageImport[1]})`, { app: { imports: { existingImport } } });
assert.equal(dvui.existingImport, existingImport, 'page mode must preserve dvui imports');
assert.doesNotThrow(() => dvui.wasm_field_hints(1));
const str = (s) => [s.length, ...Buffer.from(s)];
const section = (id, bytes) => [id, bytes.length, ...bytes];
const module = new WebAssembly.Module(new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [1, 96, 1, 127, 0]),
  ...section(2, [1, ...str('dvui'), ...str('wasm_field_hints'), 0, 0]),
]));
for (const entry of WebAssembly.Module.imports(module)) {
  assert.equal(typeof dvui[entry.name], 'function');
}
new WebAssembly.Instance(module, { dvui });
console.log('field-hints: ok');
