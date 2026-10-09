# Working on fizzy

`CLAUDE.md` says what fizzy is. This file says how a change gets from an idea to `main`, for
people and agents alike, on a laptop or in a cloud session. Several agents work on this repo at
once, and these rules are what keep their work from colliding.

**Rules live here, not in private memory.** A session that learns a rule a second contributor
would need adds it to this file in a PR. Agent memory is for one person's context: their
preferences, findings still in flight.

## One plan step, one branch, one PR

- **A plan is an issue** with a checklist of steps, or a plan doc merged on its own and linked
  from one. A plan is never the PR its implementation lands in.
- **Each step is its own PR**, saying `Part of #N`. A PR is one change a reviewer can hold in
  their head: aim for **800 lines or fewer** of diff outside tests and docs. Bigger work goes in
  a stack of PRs, or lands dark behind a flag (`FIZZY_POPOUT` is the pattern) and is switched on
  in a small PR of its own.
- **One branch per PR, never reused**, named `<area>/<slug>`: `popout/float-overshoot`,
  `sdk/file-row-decorator`, `ci/required-gate`. The area is the part of the tree the change is
  about: `sdk`, `app`, `core`, `layout`, `workbench`, `text`, `markdown`, `web`, `macos`,
  `windows`, `linux`, `ci`, `docs`, and so on.
- **The PR title is the commit on `main`.** PRs are squash-merged, the title becoming the subject
  and the body the message. Title: `area: what changes`, at most 72 characters, saying what a
  user or plugin author sees. The rest (why, what was measured, what was tried and dropped) goes
  in the body. jj descriptions follow the same shape: a short first line, a blank line, then the
  paragraph.

## Claim before you build

The open PR list is the board of who is working on what.

1. **Look first.** `gh pr list --json number,title,headRefName,isDraft,files`. If an open PR
   touches the same files or the same plan step, coordinate on it (comment, or stack on top of
   it) instead of starting a parallel version.
2. **Open a draft PR on your first push** (`gh pr create --draft --body-file <file>`), with the
   template filled in as far as you know it. A draft runs CI but doesn't take the one web test
   copy (`web.yml`), so claim early.
3. **Mark it ready when it is done and verified.** Merging is the maintainer's. Never push to
   `main`, and never merge a PR you opened unless asked to.

## jj

`fizzy` is a **Jujutsu** repo with a colocated `.git`. Use `jj`.

- **No git write commands.** `git checkout -- <file>`, `git restore`, `git reset` and
  `git commit` act on the last *git* commit, which can be far behind jj's working copy, and take
  undescribed work with them. If something is clobbered, `jj op log` and `jj undo` /
  `jj op restore` bring it back.
- **Work in a workspace of your own.** The default checkout is shared: the desktop app moves it
  between sessions' branches, and other sessions edit in it. For anything longer than a quick
  look, `jj workspace add --name <task> -r main@origin ../fizzy-<task>` and build, test and
  describe there. A cloud session or a git worktree is already isolated.
- **Never put a workspace under `/tmp`** or a session scratchpad (`/private/tmp/…` on macOS).
  The OS clears files there that go untouched for a few days, and jj's next snapshot records
  the deletions into your change. It happened on 2026-10-08: `build.zig` and most of `src/`
  vanished from a workspace mid-task. Put it beside the main checkout instead.
- **`jj new` before the work, not after.** Start each change with
  `jj new -m "<what I'm about to do>"` and refine it with `jj describe` when done. Describing
  twice without a `jj new` between folds two changes into one and overwrites the first message.
- **A workspace stacked on another's change goes stale when that change is rewritten.** Amend
  the bottom of a stack in one workspace, and every workspace above it is stale. Run
  `jj workspace update-stale` there before editing again. If it reports a fresh commit, check
  `jj log` for a divergent twin of your change (`??` after the id): keep the one that holds your
  edits (`jj edit <commit>`) and abandon the empty one. Edits made in the stale workspace
  before the update are in the twin, not lost.
- **Backticks in messages:** write the message to a file through a quoted heredoc (`<<'MSG'`),
  then `jj describe --stdin < file` or `gh pr create --body-file file`. With `-m "…"` or an
  unquoted heredoc, zsh runs every backticked name as a command.
- **Push a branch:** `jj bookmark create <area>/<slug> -r @-`, then
  `jj git push --bookmark <area>/<slug>`. Pushing `main` publishes (the web app at
  fizzyed.it/app, and an SDK release when the version moved), so `main` moves only by a merged
  PR.
- **When your PR has merged, forget its workspace, then fetch.** `jj workspace forget <task>`,
  then `jj git fetch`. GitHub deletes a merged branch, and the fetch abandons the changes only
  that branch held, so landed work doesn't linger in the next agent's `jj log` looking live.
  Forget the workspace first: a change still checked out somewhere is kept. Never abandon a
  change that is some workspace's working copy (`jj workspace list`).

## Verify, and say how

- **Gates:** `zig build`, `zig build test`, `zig build test-integration`, `zig build check-web`,
  `zig build test-sdk-version`. CI runs all of them, `test-integration` on Linux only, but a
  minute locally beats a ten-minute round trip: run them before you push.
- **Read the Build Summary, not the test count.** `test-integration` prints `failed command:`
  whenever a test logs a warning, even on a pass, and can show `N/N tests passed` beside a failed
  step. Only `N/N steps succeeded` is a pass.
- **Know what a green run covered.** `addTest` collects tests from its root module only; check
  the list in `build/app.zig` before citing a run for a file's tests.
- **A plugin's plain `zig build` also installs** into the real plugins directory. For a sandbox
  run, set `FIZZY_PROFILE` to a directory of its own, for the build and for the fizzy you start
  (or `fizzy --profile <dir>`): the plugin installs into `<dir>/plugins`, and that fizzy keeps its
  config, recents, lock and socket there too, apart from the person's own instance.
- **UI changes say how they were seen** (a test, a demo tape, a screenshot, a measurement) and
  on which platforms. CI's Windows cross-compile shows the app links, not that it works.

## Changing the SDK: a release train

The plugin boundary has two numbers. `recorded_sdk_shape_fingerprint` (`sdk/src/version.zig`)
must match the boundary's live shape, or the build fails. `sdk_version` (`sdk/sdk_version.zig`)
is what plugins pin, and **a new `sdk_version` merged to `main` is a release**: `sdk-tag.yml`
tags `sdk-v*` and publishes the tarball, then asks each `fizzyedit` store plugin to repin. Each
builds against the new SDK and opens a `sdk: repin to fizzy SDK <version>` PR in its own repo
when it needs a release (its fingerprint moved, or it no longer builds, as a draft); merge it and
tag the version it names. A merge that leaves the version alone publishes nothing: a released
tarball is pinned by hash, so it is never replaced.

- **A feature PR records the fingerprint and leaves `sdk_version` alone.** When the shape moves,
  the build fails with the new value; record it, label the PR `sdk`, and say in the template's
  SDK section what changed for plugin authors.
- **Only a release PR bumps `sdk_version`**: `sdk: release 0.2.N`, listing the `sdk` PRs merged
  since the last `sdk-v*` tag. Two branches never race for the same number, and a morning's SDK
  changes cost one round of repinning instead of several. Changes to `core/` that plugins build
  in, with no fingerprint move, reach them the same way.
- **Release soon after a merge that moved the fingerprint.** fizzyed.it/app is built from
  `main`, and store plugins don't load there until the release is out and they are repinned.
  Batch on purpose, not by forgetting.
- **An app release never ships an unreleased fingerprint.** If it moved since the last `sdk-v*`
  tag, release the SDK first (`RELEASING.md`).

## Where knowledge lives

| What | Where |
|---|---|
| What fizzy is, and its architecture rules | `CLAUDE.md` |
| How we work | this file |
| The plugin contract | `docs/PLUGINS.md` |
| Plans | issues; a long design as `docs/<NAME>_PLAN.md`, opening with a status line (`Status: proposed`, `in progress, #N`, or `done`) |
| The forks fizzy builds on | `docs/DEPENDENCIES.md` |
| Releases | `RELEASING.md` |

## Habits reviewers ask for

- **Fix the root cause.** When a fix is the third patch to the same mechanism, stop and name
  what is wrong with the model. Say plainly when a fix is a workaround.
- **Use dvui's public API** rather than reaching into its state. Changes to dvui itself go to
  the fork (`docs/DEPENDENCIES.md`).
- **A deferred feature gets a named seam.** When a plan leaves something for later, say what it
  will hook into, not just "not yet".
- **No one-line wrapper functions.** Write the library call at the site.

## The gate on `main`

`main` takes changes only through squash-merged PRs whose one required check, `ci-ok`, has
passed. `.github/rulesets/main.json` is the record of that ruleset; changing it is a repo setting
as well as a PR. Admins can merge a PR past a failing check in an emergency, never push to
`main` directly.

`ci-ok` passes when every other CI job passed or was skipped: a PR changing only Markdown skips
the builds and still gets its check. CI also runs for a merge queue (`merge_group`), so turning
the queue on needs no workflow change.
