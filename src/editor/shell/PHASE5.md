# Phase 5: the acceptance test

> *The same `workbench` / `text` / `image` / `markdown` binaries must run unchanged in
> differently-shaped apps. If any plugin needs a source change to work in one of them, the
> design has failed.*

## Result: passes

Three shells, selected with `-Dshell=`, all loading the identical plugin set with **zero plugin
source changes**:

| Shell | Shape |
|---|---|
| `ide` | Fizzy's own: icon rail, left explorer, bottom panel, main area |
| `minimal` | One main region and a status strip. No rail, no explorer, no bottom panel |
| `studio` | Blender-ish: explorer on the **right**, short bottom strip, large canvas |

The decisive observation is `studio`: the **file tree renders on the right-hand side**, and
`workbench` has no idea. Its surface carries the keywords `{"sidebar","explorer"}`; studio's
right-hand region declares the same set; they intersect, so it lands there. No place-name was
negotiated, no plugin was recompiled, and nothing in workbench mentions a side. That is keyword
matching doing the job a place-based scheme could not.

`minimal` proves the other direction: it declares no region accepting `sidebar`/`explorer`, so
the file tree simply does not draw — visible via `Frame.unplaced`, not silently lost.

## The bug this caught, which is the reason to build the examples at all

`minimal` **segfaulted immediately**, in `Editor.drawWorkspaces`:

```zig
if (editor.host.bottom_views.items.len > 0) {
    const panel = editor.panel.paned;      // <- never created by this shell
```

`drawWorkspaces` is the host API the *workbench plugin* calls; it needs the shell's panel
animation state, and it inferred "a panel paned exists" from "bottom surfaces are registered".
That proxy holds only in fizzy's own shape. Any app that registers bottom surfaces but lays
them out differently — or not at all — crashes on the first frame.

Fixed by inverting the coupling, exactly as the Phase 1 spike recommended: the shell now
*states* the fact (`Editor.shell_bottom_split`, cleared each frame and set by whichever layout
establishes a split) instead of the plugin inferring it from an unrelated registry.

This is the single most valuable thing Phase 5 produced, and it was invisible to every test that
only ran fizzy's own shape.

## Two visual regressions also caught by looking

- The sash drag target was `handle_size = 1.0 / dist = 8.0` against fizzy's `10 / 60` — a ~10x
  thinner grab area. Restored.
- The workspace column lost its `padding = .{ .w = handle_size }`, so content sat flush against
  the window edge. Restored in `ide.zig`, and `studio.zig` pads its own mirrored edge.

Neither would have been caught by a compiler or a unit test.

## Not done in this phase

The **build library API** (`build/lib.zig`, `fizzy.app.create`) is not built. The shells here are
selected by a build option inside fizzy's own graph rather than supplied by a downstream package.
That proves the *design* — a different layout, the same plugins — but not *consumability*: making
`build/app.zig` resolve its own files through `dep.builder.path(...)` instead of the consumer's
`b` is a separate, substantial build-graph change. It is the remaining blocker for an external
app, and for Phases 6-7.
