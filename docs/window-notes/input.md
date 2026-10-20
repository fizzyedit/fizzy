# Input

## Recorded findings

Our macOS pitfalls record left presses reaching the native content view in full
screen without reaching the app's input stream. Test an actual press in both normal
and full-screen windows; successful motion or hover does not prove button delivery.

The Wayland keyboard reports describe a driver failing to start on older system
keyboard libraries when the binary was built against newer headers. Compatibility
must include both starting the native Wayland session and correct modifier results.
The recorded German-layout cases distinguish Shift, Caps Lock and AltGr. Unusual
virtual-modifier mappings remain a limitation of the compatibility path; success
with a standard layout does not prove arbitrary layouts work.

## Documented behaviour

Keyboard events pass through system handling, menu shortcuts, keyboard navigation
and the focused responder. Text interpretation can yield a command, marked text or
inserted text. A physical key press is therefore not a text insertion contract
([Apple text-input sequence](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextEditing/TextEditing.html)).

## Cases to pin

- Press in main, float, menu and dialog; repeat after focus changes and full screen.
- Hold a button while crossing windows and release outside the starting window.
  Record whether capture ends and which window receives the release.
- Lose focus with a key or button held; check for stuck state on return.
- Check shortcut identity separately from layout-produced characters. Include key
  repeat, modifier-only changes and a keyboard-layout change during the session.
- Check wheel direction and fine scrolling separately from pointer motion. Record
  device and OS settings rather than assuming every wheel has integral steps.

These last cases are observation tasks, not claims of current platform coverage.
For composition-specific cases see [IME](ime.md).
