# Examples

Fizzy's examples live in repos of their own, which CI builds against every pull request
(`scripts/check-examples.sh`):

- [fizzyedit/example-app](https://github.com/fizzyedit/example-app): fizzy as a library, in
  every layout shape (`zig build run-fizzy -Dshape=minimal|studio|endless`).
- [fizzyedit/example-plugin](https://github.com/fizzyedit/example-plugin): the smallest plugin,
  the template to copy.

## replay-app

Not fizzy at all: a plain dvui app (dvui's own SDL3 backend) with tape playback from
`sdk/replay/`. It plays a live tape into its window at launch, draws the tape's pointer, and
prints a snapshot of its screen.

It depends only on the SDK package (`sdk/`), and builds `tape` and `replay` against its own dvui
with `@import("fizzy_sdk").replay.modules(…)`: the whole of what any dvui app needs for tape
playback. It moves to example-app once an SDK release carries `replay`
(fizzyedit/fizzy#281).
