# Variable-height lists

`core.HeightIndex` is the std-only height model. `core.widgets.VirtualList` draws
its viewport and overscan using the host's theme. Keep a `VirtualList.State` with
the view and free it with the same allocator used to open the list.

```zig
var list = try core.widgets.VirtualList.init(@src(), gpa, &state, .{
    .source = .{ .ctx = rows, .key = rowKey, .estimate = estimateHeight },
    .count = rows.len,
    .revision = rows.revision,
    .follow_end = true,
}, .{ .expand = .both });
defer list.deinit();
while (list.next()) |i| {
    var row = list.row(i);
    defer row.deinit();
    // Draw this row's children here, with their natural minimum heights.
}
if (list.nearStart()) requestOlderRows();
```

The callbacks have signatures `fn (*anyopaque, usize) u64` and
`fn (*anyopaque, usize, f32) f32`. Keys must be unique and stable across prepends,
reorders and removals. Estimates must be finite, nonnegative heights in logical
points at the supplied width. The source and state outlive the frame. Change the
revision whenever the supplied keys change; null asks the index to compare keys
on every frame. If a row's content changes, its visible box is measured again;
for offscreen edits, replace that row's key to discard its cached measurement.

Draw every index returned by `next`, once, in order. `row(i)` returns a `Row`
whose `box` is a vertical dvui box; close it before requesting another row.
Avoid vertical expansion on children: their minimum heights define the row's
measurement. Estimates and measurements are independent of dvui's widget cache,
so skipped rows retain their sizes. Overscan defaults to 200 points each side.

The saved position is a row key and an offset within that row. Prepending rows,
measuring preceding rows and changing width preserve that position. A removed
anchor falls back to the row at the current scroll offset. At either end the
position clamps to the available scroll range. Width invalidation keeps measured
heights as stale guesses until drawn again and refreshes unmeasured estimates.
`HeightIndex.invalidateForWidth(source, width)` exposes this operation without
allocating; `reconcile` also applies it automatically.

`follow_end` follows appended content while the reader is at the bottom, including
the initial frame. Scrolling away stops following; returning to the bottom resumes
it. `state.scrollTo(key)` requests a row for the next frame, aligned at the top
unless the end clamp prevents it; it stops following. A missing key is ignored.
`list.scrollTo(key)` also requests a refresh. `nearStart()` uses a configurable
200-point threshold and concerns only the supplied rows.

The index holds only supplied rows. It uses O(n) memory and linear reconstruction
on changes, O(log n) measurement updates and range lookup, and O(1) reconciliation
on an unchanged revision and width. Drawing costs O(visible + overscan), with an
O(log n) position lookup per drawn row. The caller must page before the total
height reaches dvui's 2,000,000-point size limit; this widget does not implement
paging or an unbounded virtual coordinate system.

## Headless scrolling demo

Run `scripts/zb build test-integration -Dtest-filter='virtual list scrolling demo'`.
The demo draws 20,000 variable-height rows with text, scrolls through 180 frames,
and draws a readout of the preceding frame's milliseconds and drawn-row count.
It prints mean and maximum frame times including `Window.end` and `Window.begin`.
These are Debug measurements on dvui's testing backend, not GPU or native frame
performance. The demo opens no OS window. The other `virtual list` tests check
actual row screen positions, including the first frame after a prepend or width
change, plus follow-end and bounded row drawing at positions across all 20,000 rows.

The markdown preview keeps its existing block list. Its migration and paging are
separate changes. This core API is available to external plugins at the next SDK
release; it does not change the SDK boundary or its version.
