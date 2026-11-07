// dvui's Paste on the web: the page reads the clipboard and hands its text back once, or does
// nothing. Run: `node web/tests/clipboard-read.test.mjs`.
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../fizzy.js', import.meta.url), 'utf8');
const fn = source.slice(source.indexOf('function clipboardRead'), source.indexOf('// The name this build files'));
const debugs = [];
const { clipboardRead } = runInNewContext(fn + '\n({ clipboardRead })', {
  console: { debug: (...args) => debugs.push(args) },
});

function nav(read) {
  const calls = { read: 0 };
  return { calls, clipboard: { readText: () => { calls.read++; return read(); } } };
}
function sink() {
  const got = [];
  return { got, text: (t) => got.push(t) };
}

const tests = {
  'secure page: the clipboard text arrives once': async () => {
    const n = nav(() => Promise.resolve('héllo wörld'));
    const s = sink();
    await clipboardRead(n, true, s.text);
    assert.equal(n.calls.read, 1);
    assert.deepEqual(s.got, ['héllo wörld']);
  },
  'insecure page: readText is never called': async () => {
    const n = nav(() => Promise.resolve('secret'));
    const s = sink();
    await clipboardRead(n, false, s.text);
    assert.equal(n.calls.read, 0);
    assert.deepEqual(s.got, []);
  },
  'a refused read does nothing': async () => {
    const n = nav(() => Promise.reject(new Error('NotAllowedError')));
    const s = sink();
    const before = debugs.length;
    await clipboardRead(n, true, s.text);
    assert.deepEqual(s.got, []);
    assert.equal(debugs.length, before + 1);
  },
  'an empty clipboard does nothing': async () => {
    const n = nav(() => Promise.resolve(''));
    const s = sink();
    await clipboardRead(n, true, s.text);
    assert.equal(n.calls.read, 1);
    assert.deepEqual(s.got, []);
  },
};
for (const [name, run] of Object.entries(tests)) {
  await run();
  console.log(`clipboard-read: ${name}: ok`);
}
