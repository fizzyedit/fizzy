# Zig craft

How to write Zig on purpose in fizzy. Every worker reads this with
[`STYLE.md`](STYLE.md) (what the code looks like); this file is what it does. Each rule has
a one-line why and a tiny example. Lessons name their source; they are real bugs.

## Memory and ownership

1. **Pass the allocator; say who frees.** A function that returns memory says in its `///`
   who frees it and with what. Why: the caller cannot guess, and a leak or double free is a
   guess gone wrong.
   ```zig
   /// Caller frees the result with `gpa`.
   pub fn names(gpa: Allocator, doc: *const Doc) ![][]const u8
   ```
2. **`errdefer` on the line after the acquisition, in reverse order of release.** Why: a later
   `try` leaks everything above it otherwise.
   ```zig
   const a = try gpa.alloc(u8, n);
   errdefer gpa.free(a);
   const b = try gpa.alloc(u8, m); // b's errdefer goes here, below a's
   ```
3. **Containers are unmanaged in the pinned Zig (0.17).** `std.ArrayList(T)` is
   `.empty`, takes the allocator on each call, and `deinit(gpa)`. Why: the owner already
   holds the allocator; a copy in every list is waste and a way to free with the wrong one.
   ```zig
   var list: std.ArrayList(u32) = .empty;   // not ArrayList(u32).init(gpa)
   defer list.deinit(gpa);
   try list.append(gpa, 1);
   ```
4. **Do not free what a walk still holds.** Defer the free until the walk is over. Why:
   fizzy#758 freed a layout-tree node while the draw walk still held a pointer to it: a
   use-after-free. Queue the doomed node, free after the walk returns.
   ```zig
   // Bad: tree.remove(node) inside drawNode(node)
   // Good: self.doomed.append(gpa, node); ... after the walk: self.reap(gpa);
   ```
5. **Tests use `std.testing.allocator`.** Why: it fails the test on a leak and, with the
   debug allocator, on a use-after-free or double free; `page_allocator` hides all three.

## Errors and API shape

6. **Error sets as narrow as is truthful; no `anyerror` return.** Name the set across the SDK
   boundary; infer it privately. A `lint-allow(anyerror)` needs a reason and the ratchet in
   `scripts/lint-allow.zon` only goes down. Why: callers `switch` on what can happen.
   ```zig
   pub fn open(gpa: Allocator, path: []const u8) OpenError!File  // not anyerror!File
   ```
7. **`catch unreachable`, `catch {}` and `@panic` carry a comment with the proof** (STYLE.md).
   Why: the comment is the review; without it the next reader must redo the proof.
8. **Use the current std; replace deprecated names.** Look the replacement up in the
   installed `lib/std` (`zig env` prints `lib_dir`), not from memory: `std.mem.print` replaces
   `std.fmt.bufPrint`, `Allocator.print` replaces `allocPrint`, `*std.Io.Writer` is the sink
   (not `anytype` writers). Why: deprecated names are removed without notice. Our own
   `/// Deprecated` marker says ``Deprecated: use `X` `` (STYLE.md and the lint); a bare one is a bug.
   ```zig
   const s = try std.mem.print(&buf, "{d}", .{n}); // not std.fmt.bufPrint
   ```
9. **No `anytype` or `comptime` unless it removes real duplication.** Why: generic code
   costs compile time and error-message quality; one concrete caller does not need it.
10. **Read flags and options from source, not from `--help`.** `fizzy --help` opens the
    app instead of printing usage. Why: running it to learn the flags launches a window; the
    argument parser in the source is the truth.

## Data structures

11. **If order matters, keep an ordered list; state what is preserved.** An unordered
    `HashMap` iterates in no promised order. Why: pixi#68 and #69 lost stroke order by
    keeping strokes in a hash map; a repaint drew them in another order, silently.
    ```zig
    /// Strokes in the order drawn; ids are unique. (A map keyed by id is the index only.)
    strokes: std.ArrayList(Stroke) = .empty,
    ```
12. **Never `for (a, b)` over lists that can differ in length without checking.** Why: Zig
    panics on unequal lengths in Debug and ReleaseSafe (a pixi crash), and in ReleaseFast and
    ReleaseSmall it is undefined behaviour.
    ```zig
    std.debug.assert(a.len == b.len); // or: for (a[0..n], b[0..n]) with `const n = @min(a.len, b.len)` when truncating is intended
    for (a, b) |x, y| ...
    ```

## Cost: frames and events

13. **Per-frame work is O(visible); per-event work is O(changed).** Move anything bigger
    off the frame and off the UI thread. Why, all found here: a bounding-box scan at pen-up
    was O(area), another pass at pen-up was O(layer); the Files explorer measured 284k rows
    every frame; the checkpoint captured a 31 MB document for one step. A fast machine hides
    it; a large document does not.
    ```zig
    // Bad: for (all_rows) |r| measure(r)      each frame
    // Good: measure only rows in the viewport; cache the total; invalidate on change
    ```
14. **No synchronous GPU readback in a step.** Why: it stalls the pipeline until the GPU
    drains; ask once, off-frame, or keep a CPU copy of what changed.
15. **Measure before and after** with `fizzy_profile` or a process sampler (`sample <pid>` on macOS, `perf record -p <pid>` on Linux), on main-thread CPU
    (`core/AGENTS.md`). Why: a guess about cost is wrong as often as right.

## Tests

16. **A regression test must fail without the fix.** Revert the fix, run the test, see it
    red, restore. Why: PR #758's first test passed with the bug in place, so it proved
    nothing. Assert the symptom (the dangling read), not that the call returns.
17. **Tests prove behaviour, named for it.** `test "a removed node is freed after the walk"`,
    with `expectEqual`/`expectEqualStrings` for a readable diff. Why: the name is the spec
    when it breaks.

## Shape

18. **Names say what, not how or who.** `strokeBounds`, not `calc2`; no `Manager`/`Utils`.
    Why: STYLE.md; the name is most of the documentation.
19. **A small function has one reason to change.** Why: the 150-line limit is a ceiling,
    not a target; a function you must scroll hides its bug.
20. **No dead code, no commented-out code, no speculative parameters.** Why: version
    control keeps history; unused code rots into a trap and misleads the next reader.
21. **Take the std function.** Before writing `startsWith`, `trim`, `indexOf` or a sort,
    search `lib/std`. Why: it is tested, and the reviewer will cite its file:line.

## Running things

22. **Plugin repos: always set `FIZZY_PROFILE` to a scratch dir** before any `zig build`.
    Why: a plain `zig build` in a plugin repo installs into the person's real profile
    (see `docs/PITFALLS.md`, "Running a second fizzy").
    ```sh
    FIZZY_PROFILE=$(mktemp -d) zig build   # never a bare `zig build` in a plugin repo
    ```

## Before you write Zig, ask

1. Who owns this memory, and who frees it? 2. What is the narrowest honest error set?
3. Can this be freed or invalidated while something still holds it? 4. Does order matter,
and what keeps it? 5. How much work is this per frame and per event, at a big document?
6. Does std already do this, in the pinned Zig? 7. Would my test fail without my change?
8. What can I delete?
