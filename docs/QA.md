# The QA build

`scripts/qa-build` keeps a Debug build of `main` with every plugin on a Mac, a seeded QA profile,
and builds of pull requests beside it for before/after. It lives in this repo because it is a
short script over `scripts/zb` and the plugin build, and it has to change with the build; the
pinned store plugins are `scripts/qa-plugins.txt`.

```sh
scripts/qa-build main       # build origin/main if it moved (incremental), install it
scripts/qa-build pr 815     # pull request 815, beside main's
scripts/qa-build run main   # or: run pr-815
scripts/qa-build reseed main  # a fresh QA profile and fixtures
scripts/qa-build list
scripts/qa-build watch 300  # `main` every 5 minutes: the trigger after a merge
```

Everything is under `$FIZZY_QA_HOME` (default `~/fizzy-qa`); `main` and `pr-<N>` there are
symlinks to the newest build of each. The last 3 builds of each kind are kept. A build is its own
directory (the app, its in-tree plugin dylibs, and a `profile/`), so main's and a PR's never share
state. The script always runs fizzy with `--profile` and builds plugins with `FIZZY_PROFILE`, so
the person's config and plugins are never read or written.

- **External plugins.** pixi, drive and example-plugin are pinned by tag in `qa-plugins.txt` and
  built for each build with `zig build --fork=<tree>/sdk`: against that tree's SDK, whatever SDK
  their own zon pins. One that no longer builds is reported (and listed in `plugins-failed.txt`
  in the build, which makes the next `main` retry it); bump its ref in a PR.
- **Profile.** `recents.zon` lists the fixtures, and `settings.zon` enables every installed store
  plugin (a fresh profile leaves them off). Fixtures (`fixtures/`): `notes` (text and markdown),
  `pixi` (a `.pixi` document from the pinned pixi checkout), `big` (20,000 files in 200
  folders), `history` (one file, 300 commits).
- **Trigger.** `qa-build main` does nothing when `origin/main` is already built, so run it from
  `watch`, a launchd agent (`StartInterval` 300) or the PM's worker after a merge. A second run
  while one is building is not guarded; use one trigger.
- **Not covered.** A pixi document's undo history is not seeded; "long history" is a git history.
