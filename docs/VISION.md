# What fizzy is for

fizzy is a Zig editor library and app. It is a fast, lean foundation that apps are built on, fizzy's
own editor among them. It has plugins, a history you can scrub through and replay, and demos that teach
an app by playing inside it. It aims to work the same on the desktop, the web and phones.

The problem it solves is windowing and application design. Apps built on fizzy should get perfect
animations, the smallest footprint and the widest platform support without each one solving that again.

One history records every change, whoever made it: the person, a demo, an agent or a collaborator. Any
moment of it can be put back.

Every pull request says which goal or principle below it serves, linking its anchor (for example
`docs/VISION.md#mobile`). The anchors are stable: the wording around them may change, the names do not.

## Goals, in order

<a id="speed"></a>
### 1. Fast to build, fast to run

Changing the code and seeing the result should take seconds. Compile speed and hot reload come first,
then how fast the app runs: frames, startup and memory, tracked over time.

<a id="quality"></a>
### 2. Code that reads well and does not crash

The Zig standard is enforced by a lint, one rule at a time. When the app does crash, the crash can be
replayed, on your own machine and in private.

<a id="demos"></a>
### 3. Demos that never break

Demos and recorded sessions play inside your own setup and keep working as the app changes.

<a id="mobile"></a>
### 4. Phones and tablets

Phones and tablets get a real mobile layout, and typing, tapping, scrolling and selecting feel as good as
in the best native apps. Settings and the plugin store fit any screen width.

<a id="platform"></a>
### 5. Apps choose their pieces

An app picks the plugins it needs, and the full editor workbench is optional. A Zig windowing library
grows alongside, slowly.

<a id="agents"></a>
### 6. Agents beside you

Any AI agent can work in fizzy from the desktop, with its own view of a document, beside the person and
never in the way.

<a id="collaboration"></a>
### 7. Editing together

Several people edit the same text live, and each one's undo stays their own.

<a id="materials"></a>
### Alongside: materials and polish

Glass, blur and light are part of the library, available to every app through a simple interface, and
fast and smooth on every platform. They stay off by default until they are ready.

### Not now

A chat client, recipes, an embedded web view, hosted services and public sign-up.

## Principles

These decide trade-offs. The goals order the work; a principle is never traded away for a goal.

<a id="zig-quality"></a>
### Code quality to Zig standards

Idiomatic, readable Zig (docs/ZIG.md, docs/STYLE.md and the lint). A change that works but reads badly is
not done.

<a id="lean"></a>
### Lean

No code that does not make fizzy clearer. Reuse or delete before adding. Each shared piece has one design,
never three. This repository holds the library; plans and process live elsewhere.

<a id="measured"></a>
### Fast, and measured

A claim that something is faster comes with numbers, and the trend is tracked.

<a id="respect"></a>
### Respect the person

Demos and agents never take over. They change nothing they cannot undo, they adapt to your setup, they
never make things jump and they never steal focus. A demo puts back every setting it changed, even when
it is interrupted. Your work, your layout and your windows stay where you left them.

<a id="every-platform"></a>
### One codebase, every platform

Linux, macOS, Windows, the web, then phones: the same behaviour everywhere, with the differences kept
inside each platform's backend.

<a id="delight"></a>
### Delight is kept

The fun of the app is part of the product: smooth animations, crossfades, overshoots and playful touches
stay. Making fizzy faster or smaller makes them smoother and cheaper; it never removes them. We never cut
a feature to save effort; we make it cheaper.

<a id="craft"></a>
### Craft and materials come first

We obsess over how apps feel so the people building on fizzy do not have to. We try ideas inside a real
app, measure them on every platform, and only then make the best one part of the library.

<a id="app-owns-look"></a>
### An app owns its look; plugins do not

An app sets its own design language. Plugins draw with the host app's theme and materials, never their own
colours, so the same plugin looks at home in any app.

<a id="evidence"></a>
### Evidence over opinion

Tests that fail without the change, measurements, and recordings or screenshots for anything that has to
be seen.

## How finished a piece of work is

Every piece of work states its level.

<a id="l0"></a>
- **L0 Sketch:** throwaway, to see or feel an idea. Never merged.

<a id="l1"></a>
- **L1 Working:** quick and private, with one check that it works. Never in this repository.

<a id="l2"></a>
- **L2 Solid:** tests, lint, one review, and its known gaps listed. In the library only behind an
  experimental option that is off by default.

<a id="l3"></a>
- **L3 Shipped:** the full standard: docs/REVIEW.md's four questions, review by a second reviewer, and
  evidence. Everything public and everything that is on by default.
