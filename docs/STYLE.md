# Zig style

How fizzy's Zig is written. New and changed code follows this file. The rules come from the
[Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide), `zig fmt` and
`lib/std`; each section names what it follows and where fizzy differs, with the reason.
Fizzy's own rules (a file is a struct, the plugin boundary, the case-rename trap) are in
[`AGENTS.md`](../AGENTS.md) and are not repeated here. How a change gets merged is in
[`CONTRIBUTING.md`](../CONTRIBUTING.md).

Where a rule can be checked by machine it will be, by a `zig build lint` step that does not
exist yet. The rest is for the reviewer. Existing code that breaks a rule stays until its
sweep; code a change adds or rewrites follows the rule.

## Names

- Types, type aliases and functions that return `type`: `TitleCase`.
- Callable functions: `camelCase`. Everything else (variables, fields, constants, enum tags,
  namespace structs with no fields): `snake_case`.
- A file with top-level fields is a struct: `TitleCase.zig`. Any other file is a namespace:
  `snake_case.zig`. Directories are `snake_case`.
- Acronyms are words: `XmlParser`, `readU32Be`.
- No leading underscores. Do not repeat the namespace in a name (`Tabs`, not `TabsWidget`
  inside `widgets`). Avoid vague words: `Manager`, `Data`, `Value`, `Utils`. Existing
  names that break this (`widgets.TabsWidget`) stay; do not add more.
- Error names are `TitleCase` (`error.OutOfMemory`).

Source: Style Guide "Names", "Avoid Redundancy in Names", "Refrain from Underscore Prefixes".

Exceptions, each forced by something outside fizzy:

- `export` and `extern` names, and C-ABI entry points, keep the name the other side expects.
  Helpers around them get Zig names (`sdlRectToDvui`, not `SDL_Rect_to_dvui`).
- Platform constants keep their system spelling (`ENOENT`).
- A field that mirrors a file format or the `std` call it feeds keeps that spelling.
- `Context` is fine where `std` uses it; a `{ctx, vtable}` seam names its pointer `ctx`.

## Layout of a file

In order:

1. The `//!` doc comment.
2. `const std = @import("std");` once, never inline as `@import("std").x`. Then named modules,
   then relative files.
3. In a struct file, `const Self = @This();`, then the fields, then the declarations.
4. Among related declarations, `pub` ones first. Do not reorder an existing file for this.
5. Tests at the bottom of the file they test.

Source: `lib/std/array_list.zig` and the other struct files in `lib/std`.

## Whitespace

`zig fmt` is law and `scripts/check-fmt.sh` gates it. Beyond what it does:

- Code lines are about 100 columns. This is soft: `zig fmt` does not wrap, so a longer line
  is fine where splitting it hurts.
- Comment lines are wrapped at 100, by hand; nothing checks it yet. Comments are prose, and a long line of prose is
  harder to read than a long line of code.

Source: Style Guide "Whitespace". Fizzy keeps code soft because thousands of existing lines
run past 100 and a mass rewrap would bury every blame.

## Memory

- Allocators are parameters or fields. There is no global allocator. A plugin uses
  `host.allocator` and `host.arena()` (see AGENTS.md).
- Every `init` has a `deinit`; every `create` has a `destroy`.
- `errdefer` goes on the line after the acquisition it undoes. `defer` goes on the line after
  a resource that dies in scope.
- A function that returns memory says in its `///` who frees it and with which allocator.
- Prefer an unmanaged container when the owner already holds the allocator.

Source: `lib/std/mem/Allocator.zig` ("Call `destroy` with the result to free the memory."),
`lib/std/array_list.zig`.

## Errors

- Return errors; do not hide them. A private function uses an inferred set; anything across
  the SDK boundary names its set.
- `catch unreachable` and `catch @panic` need a comment saying why the failure cannot happen.
  `catch {}` needs one saying why dropping the error is right.
- No `std.debug.print` outside tests and scratch tools. Use `std.log`.

Source: `lib/std` practice; Style Guide "Doc Comment Guidance" on unchecked and checked
illegal behavior.

## anytype

Use a concrete type when one exists, and `comptime T: type` when the caller can name the type.
`anytype` is allowed only on an allowlist, each entry with its reason (the lint's allowlist
file once it exists; until then a comment at the use): writer and format
plumbing that `std` itself leaves open, and comptime-generic helpers whose parameter set is
truly open. The reason keeps `anytype` from becoming the easy way out of a signature.

Source: `std` takes `*Writer` or `comptime T: type` wherever it can.

## Invariants

- `assert` a condition the code relies on when a cheap check proves it, next to the line that
  relies on it.
- `unreachable` marks a branch that is provably dead, with the proof in a comment.
- `@panic` is for unrecoverable failure at setup: build scripts, entry points, and a
  `catch @panic` with a comment. Past setup, return the error.
- `@ptrCast` needs a comment saying why the cast is sound, except a plain vtable or FFI cast.
  `@constCast` always needs one.
- A file-scope `var` needs a comment naming who writes it and on which thread.
- In a `///`, "Asserts" means the function checks the condition (safety-checked). "Assumes"
  means it does not (unchecked illegal behavior).

Source: Style Guide "Doc Comment Guidance"; `lib/std` places `assert` beside the use.

## Tests

- `test "name"` blocks sit beside the code.
- Leak-check with `std.testing.allocator`.
- A new test file needs a root: `zig build check-tests-reached` fails on a `test` block that no
  test binary compiles. Add the root in `build/app.zig`, or `test { _ = @import(...); }` from
  a file that has one.

Source: `lib/std`, where tests live in the file they test.

## Size and shape

- A function stays under 150 lines. Existing longer ones are reported and may not grow; no new
  one is added. The limit is report-only for now.
- Speed and "no one-line wrappers" are in `CONTRIBUTING.md`.

Source: judgment, not `std`. A fixed number makes the limit checkable.

## Comments

(Written in a following change.)
