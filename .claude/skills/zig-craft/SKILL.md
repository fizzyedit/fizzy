---
name: zig-craft
description: Write Zig on purpose, like a Zig core-team reviewer would want fizzy's code written. Use before writing or changing any Zig in fizzy (allocators, errors, containers, tests, per-frame cost).
---

# zig-craft

Read `docs/ZIG.md` and follow it; `docs/STYLE.md` covers how the code looks, `docs/ZIG.md` what
it does. Use this before you write or change Zig, and again when you review your own diff.
Look up std in the installed `lib/std` (`zig env` prints `lib_dir`) rather than from memory.

Ask the questions in the "Before you write Zig, ask" section of `docs/ZIG.md` before writing.
