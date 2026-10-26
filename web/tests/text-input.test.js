// The hidden input's word and what a keyboard's correction does to the text. Run by
// scripts/test-web-text-input.sh against the web.js the build writes (dvui's, patched):
//   node text-input.test.js <path to the patched web.js>   (or jsc -m, as the script does)
// A fake input stands in for the page's; the fake sink applies the edits like a text field.
const path = globalThis.process ? process.argv[2] : globalThis.arguments[0];
const print = globalThis.print ?? console.log;
const exit = (code) => (globalThis.process ? process.exit(code) : quit());
// web.js builds its codecs as it loads; jsc has none, and these tests never decode.
globalThis.TextDecoder ??= class { decode() { return ""; } };
globalThis.TextEncoder ??= class { encode() { return new Uint8Array(); } };
const { TextInput } = await import(path);

let failed = 0;
function check(name, got, want) {
  if (got === want) return;
  failed++;
  print(`FAIL ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

function fixture() {
  const listeners = {};
  const hidden = {
    value: "", selectionStart: 0, selectionEnd: 0,
    addEventListener(type, fn) { listeners[type] = fn; },
  };
  const field = { text: "" };
  const input = new TextInput(hidden, {
    text: (t) => { field.text += t; },
    backspace: () => { field.text = Array.from(field.text).slice(0, -1).join(""); },
  });
  const fire = (type, ev) => listeners[type](ev);
  const type = (data) => fire("beforeinput", { preventDefault() {}, inputType: "insertText", data, isComposing: false });
  const select = (a, b) => { hidden.selectionStart = a; hidden.selectionEnd = b; };
  return { hidden, field, input, fire, type, select };
}

const replacement = (data, ranges = []) => ({
  preventDefault() {}, inputType: "insertReplacementText", data, isComposing: false, getTargetRanges: () => ranges,
});

{
  const { hidden, field, type, fire, select } = fixture();
  for (const c of "teh") type(c);
  check("the word is mirrored", hidden.value, "teh");
  select(0, 3);
  fire("beforeinput", replacement("the", [{ startOffset: 0, endOffset: 3 }]));
  check("target range replaced", field.text, "the");
  check("mirror follows the replacement", hidden.value, "the");
}
{
  const { field, type, fire, select } = fixture();
  for (const c of "teh") type(c);
  select(0, 3);
  fire("beforeinput", replacement("the"));
  check("selection stands in for empty target ranges", field.text, "the");
}
{
  const { field, type, fire, select } = fixture();
  for (const c of "a teh") type(c);
  select(0, 3);
  fire("beforeinput", replacement("the", [{ startOffset: 0, endOffset: 3 }]));
  check("only the word after the space is replaced", field.text, "a the");
}
{
  const { hidden, field, type, fire } = fixture();
  for (const c of "im") type(c);
  fire("compositionstart", {});
  hidden.value = "I'm";
  fire("compositionend", { data: "I'm" });
  check("a composition over the typed word", field.text, "I'm");
}
{
  const { hidden, field, fire } = fixture();
  fire("compositionstart", {});
  hidden.value = "hello";
  fire("compositionend", { data: "hello" });
  check("a composition on a new word", field.text, "hello");
}
{
  const { field, type, input } = fixture();
  for (const c of "teh") type(c);
  input.clear();
  type(" ");
  check("a cleared word is not replaced", field.text, "teh ");
}
{
  const { hidden, field, type, input } = fixture();
  for (const c of "tex") type(c);
  input.keydown({ key: "Backspace" });
  check("backspace pops the mirror", hidden.value, "te");
  input.keydown({ key: "ArrowLeft" });
  check("a navigation key clears it", hidden.value, "");
  check("and leaves the field alone", field.text, "tex");
}
if (failed > 0) {
  print(`text-input: ${failed} failed`);
  exit(1);
}
print("text-input: ok");
