# Working on fizzy

`AGENTS.md` says what fizzy is. This file says how a change gets from an idea to `main`, for
people and agents alike, on a laptop or in a cloud session. Several agents work on this repo at
once, and these rules are what keep their work from colliding.

**Rules live here, not in private memory.** A session that learns a rule a second contributor
would need adds it to this file in a PR. Agent memory is for one person's context: their
preferences, findings still in flight.

## One plan step, one branch, one PR

- **A plan is an issue** with a checklist of steps, or a plan doc merged on its own and linked
  from one, both in the private [`fizzyedit/plans`](https://github.com/fizzyedit/plans) repo. A
  plan is never the PR its implementation lands in. A PR here says `Part of fizzyedit/plans#N`,
  or names the plan file as `plans/<NAME>_PLAN.md`; what a reviewer without access needs to judge
  the change goes in the PR itself.
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
   template filled in as far as you know it. A draft runs CI, so claim early.
3. **Take it to ready yourself; don't hand back a draft.** When the change is done and the gates
   pass, review your own diff (in Claude Code, the `code-review` skill at `high` on the PR), fix
   what holds up, push, and wait for CI to go green. Then `gh pr ready`, and end the session
   with one question: merge it? Say what was reviewed and what was left, so the answer can be
   yes without opening the PR.
4. **Merging is the maintainer's.** On a yes, merge with `gh pr merge --squash`. Never push to
   `main`, and never merge a PR you opened unless asked to.
5. **Auto-merge comes after review and a yes.** It merges, so it is the maintainer's, or whoever
   merges on their yes: on only once the PR's code review is done and the maintainer said yes,
   never by the session that opened the PR. On 2026-10-19 #623 and #624 merged before their
   review landed, and the findings became follow-ups #639 and #640.

## jj

`fizzy` is a **Jujutsu** repo with a colocated `.git`. Use `jj`.

- **No git write commands.** `git checkout -- <file>`, `git restore`, `git reset` and
  `git commit` act on the last *git* commit, which can be far behind jj's working copy, and take
  undescribed work with them. If something is clobbered, `jj op log` and `jj undo` /
  `jj op restore` bring it back.
- **Claude Code enforces some of this.** `.claude/settings.json` hooks refuse git write commands
  in a jj repo and a workspace under `/tmp` (`.claude/hooks/guard-bash.sh`), and run `zig fmt` on
  each `.zig` or `.zon` file an agent writes (`.claude/hooks/zig-fmt.sh`). Other agents have only
  the written rules, and CI's format check.
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
  `jj git push --bookmark <area>/<slug>`. Pushing `main` publishes (fizzyed.it/testapp
  always, fizzyed.it/app while `main` is on the live SDK, and an SDK release when the version
  moved), so `main` moves only by a merged PR.
- **Look before `jj abandon`.** Abandon only an id that `jj log` prints as `(empty)` that moment,
  never one from memory, and never a change that is some workspace's working copy
  (`jj workspace list`). `jj undo` brings back a wrong one.
- **A local bookmark can hold another session's work.** `jj git push --bookmark X` pushes wherever
  `X` points, whoever moved it. Before pushing a branch you didn't create, compare `X` with
  `X@origin`, and check that `jj bookmark set` printed "Moved" rather than a hint.
- **When your PR has merged, forget its workspace, then fetch.** `jj workspace forget <task>`,
  then `jj git fetch`. GitHub deletes a merged branch, and the fetch abandons the changes only
  that branch held, so landed work doesn't linger in the next agent's `jj log` looking live.
  Forget the workspace first: a change still checked out somewhere is kept. Never abandon a
  change that is some workspace's working copy (`jj workspace list`).

## A session is one PR long

Every turn re-sends the whole conversation, so a session costs its context size times its
turns. In the week to 2026-10-19, three quarters of fizzy's input tokens went to turns already
past 400k of context, mostly in a few sessions that ran one PR after another for thousands of
turns.

- **End the session when its PR is ready** and the merge question asked (above). The next step
  starts fresh: its kickoff names the plan step, the PRs it builds on and the workspace, and
  the PR body and `jj log` carry the rest.
  `.claude/settings.json` sets `autoCompactWindow` to 300k as a backstop, not a budget.
- **Read code through a subagent.** A sweep of `grep`/`sed`/`cat` lands in the main context and
  is re-read every turn after it. Hand "how does X work" and "run the gates, report failures" to
  an Explore or general-purpose agent and keep its conclusion; read a file yourself when you are
  about to edit it.
- **Look with text before pixels.** A screenshot stays in context for the rest of the session.
  Ask `fizzy_screen`, `fizzy_profile` or a number first; when an image is the answer, crop it to
  what changed.
- **Don't reload what is loaded.** `AGENTS.md` and this file are already in a Claude Code
  session's context through `CLAUDE.md`; a kickoff prompt need not say to read them.

## Verify, and say how

- **Heavy builds go through `scripts/zb`.** `scripts/zb build test` is `zig build test` once a
  slot is free (two by default, `FIZZY_BUILD_SLOTS`) and the load average is under the machine's
  performance cores (`FIZZY_BUILD_MAX_LOAD`). Agents and people share one Mac, and parallel builds
  have taken its load past 17 and crashed it; don't poll `uptime` and start anyway. Every gate
  below runs as `scripts/zb build …` (`scripts/zb build test-integration`). Not for `zig build run`
  of the editor, which would hold the slot until it quits; `FIZZY_BUILD_SKIP=1` runs at once.
- **Gates:** `scripts/check-fmt.sh` (`--fix` formats), `zig build`, `zig build test`,
  `zig build test-integration`, `zig build check-web`, `zig build test-sdk-version`. CI runs all
  of them, `test-integration` on Linux only, but a
  minute locally beats a ten-minute round trip: run them before you push.
- **Read the Build Summary, not the test count.** `test-integration` prints `failed command:`
  whenever a test logs a warning, even on a pass, and can show `N/N tests passed` beside a failed
  step. Only `N/N steps succeeded` is a pass.
- **Know what a green run covered.** `addTest` collects tests from its root module only, and
  only from files that module analyzes. `zig build check-tests-reached` (run in CI) fails when a
  `test` block is compiled into no test binary, naming it; a new test file needs a root in
  `build/app.zig` or a `test { _ = @import(...); }` from a file that has one.
- **Cloud sessions run `scripts/cloud-setup.sh`.** A Claude Code cloud session's GitHub proxy
  blocks every repo but `fizzyedit/fizzy`, so `zig build` cannot fetch fizzy's dependencies
  there. `.github/workflows/deps-cache.yml` publishes the Zig package cache as the asset
  `zig-deps-linux.tar.zst` of the rolling `deps-cache` release, and the script installs Zig 0.17
  (`pip install ziglang`) and unpacks that cache into `~/.cache/zig/p`. The environment's setup
  script is the one line `curl -fsSL https://github.com/fizzyedit/fizzy/releases/download/deps-cache/cloud-setup.sh | bash`.
  A dependency bump reaches cloud sessions when the workflow has run on the merge.
- **A plugin's plain `zig build` also installs** into the real plugins directory. For a sandbox
  run, set `FIZZY_PROFILE` to a directory of its own, for the build and for the fizzy you start
  (or `fizzy --profile <dir>`): the plugin installs into `<dir>/plugins`, and that fizzy keeps its
  config, recents, lock and socket there too, apart from the person's own instance.
- **A fizzy you launch takes the person's window focus.** macOS activates it, and a self-restart
  into a rebuilt binary relaunches it, so never run a rebuild-and-relaunch loop, or a build that
  triggers fizzy's self-restart, while a sandbox runs. Launch a sandbox fizzy only when a test or
  the headless integration harness can't show the thing, at most a couple of times, and quit it
  when done. On 2026-10-19 a worker's restart repro pulled the person out of their windows for an
  hour.
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
tarball is pinned by hash, so it is never replaced. Once the plugins have released into it, the
maintainer makes the SDK **live** on the site (below).

- **A feature PR records the fingerprint and leaves `sdk_version` alone.** When the shape moves,
  the build fails with the new value; record it, label the PR `sdk`, and say in the template's
  SDK section what changed for plugin authors.
- **Only a release PR bumps `sdk_version`**: `sdk: release 0.2.N`, listing the `sdk` PRs merged
  since the last `sdk-v*` tag. Two branches never race for the same number, and a morning's SDK
  changes cost one round of repinning instead of several. Changes to `core/` that plugins build
  in, with no fingerprint move, reach them the same way.
- **The site has two copies, and merging an `sdk` PR breaks neither** (`web.yml`).
  fizzyed.it/testapp is `main`, every push: a new SDK is there to try while plugins catch up.
  fizzyed.it/app is the **live** SDK release, the one the store's plugins are built for, so every
  plugin loads there. It goes up from `main` only while `main` is on the live SDK; after an `sdk`
  merge it holds. Going live is the maintainer's step, once the repinned plugins are released and
  the store holds them: `gh workflow run web.yml --ref main -f go_live=0.2.N` records
  `sdk-v0.2.N` as live (a deployment to the `web-live` environment) and puts the app up (from
  `main`, or from the release's own commit if `main` has moved on). Until then non-SDK fixes
  reach testapp, not the app.
- **An app release never ships an unreleased fingerprint.** If it moved since the last `sdk-v*`
  tag, release the SDK first (`RELEASING.md`).

## Where knowledge lives

| What | Where |
|---|---|
| What fizzy is, and its architecture rules | `AGENTS.md` |
| How Zig and comments are written | `docs/STYLE.md` |
| How we work | this file |
| The plugin contract | `docs/PLUGINS.md` |
| Plans | private, in [`fizzyedit/plans`](https://github.com/fizzyedit/plans): issues, and a long design as `plans/<NAME>_PLAN.md` opening with a status line (`Status: proposed`, `in progress, fizzyedit/fizzy#N`, or `done`) |
| The forks fizzy builds on | `docs/DEPENDENCIES.md` |
| Releases | `RELEASING.md` |
| Licensing, and the name | `LICENSING.md`, `TRADEMARKS.md` |

## Licensing contributions

Fizzy is MIT (`LICENSING.md`), and a contribution comes in under the license it goes out under:
opening a PR offers its change under MIT. There is no contributor license agreement. Code
copied from elsewhere must carry a license compatible with MIT, and keeps its notice.

## Habits reviewers ask for

- **Fix the root cause.** When a fix is the third patch to the same mechanism, stop and name
  what is wrong with the model. Say plainly when a fix is a workaround.
- **Use dvui's public API** rather than reaching into its state. Changes to dvui itself go to
  the fork (`docs/DEPENDENCIES.md`).
- **A deferred feature gets a named seam.** When a plan leaves something for later, say what it
  will hook into, not just "not yet".
- **No one-line wrapper functions.** Write the library call at the site.
- **Speed over convenience.** Native performance is fizzy's edge. Nothing optional (automation,
  agents, debug capture) may cost a frame when it is unused. Measure before calling a change
  fast, and keep a benchmark once it is.
- **Build the seam the next plugin needs.** When a plugin needs something from the host, add the
  general primitive (an event its owner fires, a host-owned copy) rather than a fix for this one
  plugin (a per-frame poll, a slice borrowed from plugin memory). Moving the fingerprint for the
  clearer shape is fine.
- **Pitfalls go where they bite.** A trap that cost real time is written down in the
  `AGENTS.md` of the directory it lives in, or `docs/PITFALLS.md` if it has none.

## The gate on `main`

`main` takes changes only through squash-merged PRs whose one required check, `ci-ok`, has
passed. `.github/rulesets/main.json` is the record of that ruleset; changing it is a repo setting
as well as a PR. Admins can merge a PR past a failing check in an emergency, never push to
`main` directly.

`ci-ok` passes when every other CI job passed or was skipped: a PR changing only Markdown skips
the builds and still gets its check. `main` merges through the merge
queue (squash, up to 4 PRs a batch, `ci-ok` rerun on the `merge_group` ref): `gh pr merge N --auto`
queues a PR once its checks pass, and the queue lands it.
