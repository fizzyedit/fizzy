# Clipboard

## Documented behaviour

A macOS pasteboard can contain several items, each with several representations.
A plain-text reader may accept the text representation without accepting rich text
or images. Some offered representations are produced only when requested. A change
counter identifies replacement of pasteboard contents; separate named pasteboards
have separate counters. Copy/paste and dragging are distinct exchanges
([Apple pasteboard concepts](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/PasteboardGuide106/Articles/pbConcepts.html)).

## Cases to observe

The mined window pitfalls and patch descriptions contain no clipboard regression
report. These are candidate conformance cases, not results:

- Copy Unicode text with multiple lines, paste within the app and into another app,
  then reverse the direction. Include empty text and unavailable text separately.
- Offer text with rich text or image representations. Verify the chosen format and
  failure behaviour when no supported representation exists.
- Replace clipboard contents in another app between two pastes. Check freshness.
- Copy, then close the source document or quit the source app before pasting.
  Record eager and deferred-data outcomes separately.
- Repeat paste with focus in a float, then a dialog. Content must reach the intended
  editor rather than whichever window originally performed the copy.

Record OS version, producing application, offered types and actual received bytes
for each result. Windows and Linux ownership, selection and persistence semantics
are still unresearched here; do not generalize the macOS contract to them.
