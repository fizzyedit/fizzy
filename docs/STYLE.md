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
3. In a struct file, `const Writer = @This();` (the file's own name, as in std), then the fields,
   then the declarations. `Self` is for a type-returning fn only. `zig build lint` checks it
   (`file-alias`).
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
  the SDK boundary names its set. Do not use `anyerror` in a function or function-type return
  type (`anyerror!T`, `anyerror`); vtable slots that must erase the set are marked
  `// lint-allow(anyerror): <reason>`, and existing `anyerror!` returns sit on the
  `scripts/lint-allow.zon` ratchet, which holds the count.
- `catch unreachable` and `catch @panic` need a comment saying why the failure cannot happen.
  `catch {}` needs one saying why dropping the error is right.
- No `std.debug.print` outside tests and scratch tools. Use `std.log`.

Source: `lib/std` practice (`std` uses named error sets rather than `anyerror!`); Style Guide
"Doc Comment Guidance" on unchecked and checked illegal behavior.

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

Three kinds, three jobs. Source: the language reference sections "Comments" and "Doc
Comments", and the doc comments in `lib/std/array_list.zig` and `lib/std/mem/Allocator.zig`.

- `//!` opens a file or container: what it is for and what it is not, in one to three short
  paragraphs. Every file has one: a new file starts with it, and a change that rewrites a file
  without one adds it.
- `///` documents the declaration below it. It is the contract, read by the caller.
- `//` is for the next reader of the implementation. It says why, never what.

### What a `///` states

- What the declaration does, in one line. Leave out what the name and signature already say.
- The contract: what the caller must pass, and what the function asserts or assumes.
- Ownership and lifetime: who frees, with which allocator, how long a returned slice or
  pointer stays valid, and which calls invalidate it.
- The errors it can return, and when.
- Thread or frame restrictions.

A field gets a `///` when its use is not clear from its name and type, as `ArrayList.items`
and `capacity` do. Sibling functions may repeat shared wording; it helps in IDE help.

### What a `///` leaves out

The implementation, who calls it today, how it used to work, and any plan step, PR number or
date.

```zig
// Bad: restates the signature and names a caller.
/// Returns the path. Called by the tab bar.
pub fn path(self: *const File) []const u8

// Good: ownership and lifetime.
/// The file's path. Valid until `close`; the caller does not free it.
pub fn path(self: *const File) []const u8
```

### Tone and length

- Plain, present tense, declarative. Full sentences with a period in `///` and `//!`; short
  fragments are fine in `//`.
- One line is the norm. A paragraph is for ownership or an invariant. A `//` block of more
  than about 15 lines wants a `//!` or a file in `docs/`.
- ASCII, plus typographic punctuation such as the em dash. No other non-ASCII, no emoji, no
  emphasis markup beyond backticks around identifiers.
- No narration (`// increment i`), no section banners (`// ---- tests ----`), no commented-out
  code (version control keeps it).

### No change-log wording

A comment describes the code as it is. Do not write history: "no longer", "used to",
"previously", "formerly", "fixed", "now X instead", "the old ...", a date, `#NNN` or "this
PR". History belongs in the commit and the PR. Words that only describe the code ("returns a
new slice") are fine.

A comment may say why not the obvious alternative, because that is a constraint that holds
today.

```zig
// Bad: tells a story.
// This used to give up after 200,000 yields, which failed on a slow CI disk.
// Now it waits 5 s.

// Good: states the constraint.
// The read runs on the Io's pool, so wait on the clock: 5 s, because a yield count varies
// with the disk.
```

Once the lint exists, this rule is report-only at first, then fails. A false hit (such as
"fixed-size") goes on its allowlist with a reason; the word list is not loosened.

### When a comment is required

The full list; Errors and Invariants name the same constructs. Each has a comment saying why
it is sound:

- `unreachable` and `catch unreachable`
- `@panic`
- `@constCast` and `@setRuntimeSafety`
- `@ptrCast`, except a plain vtable or FFI cast
- `undefined` for a value that is not trivial
- a file-scope `var` (who writes it, on which thread)
- a lock (at its declaration: what it guards) and an atomic ordering (why that order)
- a workaround for another project's bug: name the project and the condition for removing it
- a literal other than 0, 1 or one its name explains; an ordering constraint; a
  frame-timing assumption

```zig
// Bad
const n = std.mem.print(&buf, "{d}", .{id}) catch unreachable;

// Good
// 20 digits hold any u64, and buf is 32 bytes.
const n = std.mem.print(&buf, "{d}", .{id}) catch unreachable;
```

### TODO names a seam

`TODO(<seam, plans/X.md or #issue>): what`. An issue number is allowed here, as the one
exception to the `#NNN` rule. The seam is what the work will hook into, which is
what CONTRIBUTING.md asks of a deferred feature. A bare `TODO` is deleted or given a seam.

### Deprecated names its replacement

In `sdk/src`, a `/// Deprecated` doc comment names its replacement in backticks
and adds the removal `sdk_version` when it is known. The shim
stays until a release PR removes it, so a plugin author reading the marker sees what to change
to. `scripts/lint.zig` rejects a marker with no backticked name; a justified exception uses
`// lint-allow(deprecated-names-replacement): <reason>` on the line before it.
