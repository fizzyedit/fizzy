---
name: fan-common
description: The shared contract of every superfan (fan-boundary, fan-perf, ...): setup, run-only-when-main-changed, fingerprints and dedupe, the issue format, caps, budget and the run record. Each fan reads this first. Not run by itself.
---

# Superfans: the contract every fan follows

A superfan has one obsession and no other purpose. It reads code on its topic, looks for
regressions, and files deduplicated findings as issues. A routine's whole prompt is
`Run /fan-<name>`; everything it does is written here and in that fan's `SKILL.md`. Plan:
`fizzyedit/plans#58`.

A fan files issues. It does not fix code, open PRs, merge, tag, push (to `main` least of all),
change settings, comment on other people's issues, or write anywhere but issues in
`fizzyedit/work` (the one exception: `fan:perf` writes the `perf-data` branch). Findings are
posted: a run that finds something and files nothing is a failed run.

## 1. Setup

1. Find where this fan runs: `scripts/fan-route.sh <name>`. A line ending `no-runner` means no
   runner offers a need: write the run record (section 6) with `gate: no runner` and stop; that
   is not an error and not an issue.
2. Only then, on a cloud machine run the repo's `scripts/cloud-setup.sh` (it is the release
   asset `deps-cache/cloud-setup.sh`, so a fresh machine without a checkout can run
   `curl -fsSL https://github.com/fizzyedit/fizzy/releases/download/deps-cache/cloud-setup.sh | bash`),
   which installs Zig and unpacks the dependency cache. Elsewhere `zig version` and
   `gh auth status` are enough.
3. If setup or the fan's gate cannot run (cache missing, no network), file exactly one issue
   `fan:<name>: cannot run`, fingerprint `fan:<name>/setup/<what failed>`, deduped like any
   finding, write the run record, and stop. No retries beyond 2.

## 2. Run only when main changed

`git fetch origin main`, then compare `git rev-parse origin/main` with the commit in the last
run-record comment on the fan's tracking issue (`fan:<name>: runs`).
- Equal (look only at records whose gate is `pass`, `fail` or `unchanged`; a `no runner` or
  `cannot run` record examined nothing): write a one-line `unchanged` run record and stop (about 2k tokens).
- Different: read `git diff <last-sha>..origin/main -- <the fan's globs>` first. Do a full
  sweep only on Sundays, when the fan's own `SKILL.md` changed since the last run, or when
  there is no earlier record.
- Empty diff for the fan's globs: a one-line `no change in globs` record, stop.

## 3. Fingerprints and dedupe

Every issue body ends with the line
`fingerprint: fan:<name>/<check-id>/<path>[:<symbol>]`, stable across line moves (a symbol or a
check-specific key, never a line number).

Before filing, `scripts/fan-dedupe.sh --check <fingerprint>`:
- exit 0 `new`: file it.
- exit 10 `duplicate of #N`: skip, count it in the run record. Open and dismissed
  (`wontfix`, `invalid`, closed as not planned) both skip.
- exit 11 `regression of #N`: it was fixed and is back; file it with title prefix
  `regression:` and `Regression of #N` in the body.

`scripts/fan-dedupe.sh <name>` lists what is already filed. A fingerprint listed under the
fan's "Known and accepted" is a duplicate too, whatever the issues say: `--check` reads that
section of the fan's `SKILL.md` itself (exit 10, `duplicate: known and accepted`). A closed-completed
batch of lows counts as a duplicate of each low, not a regression; a regression is only a fixed
issue with the same fingerprint.

Stale check: an open `fan:<name>` issue not touched for 14 days is re-checked by this fan on
its next run; if its fingerprint no longer reproduces, close it with one line saying so.

## 4. Filing

- Repo `fizzyedit/work` (private). Labels `agent`, `superfan`, `fan:<name>`, one of
  `sev:high` `sev:med` `sev:low`. The labels exist; a fan never creates labels. A missing label
  is a setup failure (section 1, step 3).
- Title `fan:<name>: <what is wrong>`, at most 72 characters.
- Body: severity; one paragraph on why it matters; **Repro** (the exact command or tape,
  expected against actual); `file:line` at the commit examined (`main@<sha>`); for medium and
  high a filled kickoff block (the template in `docs/AGENT_WORK.md`); last line the fingerprint.
- Cap: at most 5 new issues per run, highest severity first. Overflow is one line in the run
  record. Lows go into one `fan:<name>: low-severity batch` issue per run, not one each, with one
  `fingerprint:` line per low at the end of the body (dedupe indexes every such line); the batch
  does not count toward the cap.
- Verify before filing: a suspected hit is escalated to one `Agent` (Opus or Sonnet at high
  effort) that must reproduce it or cite the exact lines. Unverified suspicion is not filed.

## 5. Budget

Scanners: 80k tokens per run (`fan:perf`, which builds: 150k). Scan with the cheaper model
(Sonnet; Haiku for docs); delegate searches to `Agent`s. At 90% of budget stop scanning and
file what is confirmed. Report tokens used in the run record.

## 6. Run record

Every run, including zero findings and `unchanged`, ends by adding one comment to the pinned
issue `fan:<name>: runs` in `fizzyedit/work` (create it the first time: labels `agent`,
`superfan`, `fan:<name>`). One line:

`<UTC date> runner=<name> main@<sha> tokens=<n> filed=<n> duplicates=<n> gate=<pass|fail|unchanged|no runner> <note>`

There is no summary issue per run. The PM flags a fan with no record in 36 hours.

## 7. Where the work stays

Use your own checkout; build or test only what the fan's gate names. Follow `CONTRIBUTING.md`
if you launch the app: own `FIZZY_PROFILE`, never on the maintainer's desktop, at most a couple
of launches, quit it. A fan never reads or prints secrets.
