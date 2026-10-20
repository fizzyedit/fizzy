# IME and text composition

## Documented behaviour

Apple's text system interprets a key event into editing commands, provisional marked
text or committed insertion. Marked text can be replaced during composition; it is
not a series of independent committed keystrokes. Focused text clients participate
in that interpretation rather than deriving all input from raw key events
([Apple text editing and input](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextEditing/TextEditing.html)).

## Cases to observe

No IME regression was recorded in the mined window pitfalls or patch descriptions.
The following need native observation before becoming claims about our backend:

- Compose with a Japanese or Chinese input method, update the candidate selection,
  commit, then repeat and cancel. Check that provisional text does not duplicate
  committed text or survive cancellation as a second insertion.
- Replace selected text through composition, including text outside ASCII. Record
  range units explicitly; byte offsets and character positions are not interchangeable.
- Move the caret, scroll, resize and move between displays while a candidate UI is
  visible. Record its position relative to the caret at each scale.
- Switch focus between main and float editors during composition, then close the
  composing window. Record whether composition commits or cancels and whether input
  subsequently goes to the newly focused editor.
- Exercise dead keys, emoji and a command shortcut during composition. Check text
  output independently from key delivery and shortcut execution.

These cases do not prescribe commit-on-blur policy without evidence. Record input
method, language, OS version and the observed result. Windows and Linux composition
contracts and candidate positioning remain unresearched in this pass.
