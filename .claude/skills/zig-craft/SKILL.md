---
name: zig-craft
description: Write Zig on purpose, like a Zig core-team reviewer would want fizzy's code written. Use before writing or changing any Zig in fizzy (allocators, errors, containers, tests, per-frame cost).
---

# zig-craft

Read `docs/ZIG.md` and follow it; `docs/STYLE.md` covers how the code looks, `docs/ZIG.md` what
it does. Use this before you write or change Zig, and again when you review your own diff.
Look up std in the installed `lib/std` (`zig env` prints `lib_dir`) rather than from memory.

Ask these before writing:

1. Who owns this memory, and who frees it?
2. What is the narrowest honest error set (never `anyerror`)?
3. Can this be freed or invalidated while something still holds it?
4. Does order matter, and what keeps it?
5. How much work is this per frame and per event, at a large document?
6. Does std already do this, in the pinned Zig (0.17)? Is any name I use deprecated?
7. Would my test fail without my change?
8. What can I delete?
