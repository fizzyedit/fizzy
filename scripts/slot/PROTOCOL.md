# The slot protocol (v1)

Architect, 2026-10-29 (foxnne card slot-protocol: YES, inside the reset). To be committed as
`slot/PROTOCOL.md` in fizzyedit/work before the four issues are cut; every issue reads it there.
Background: notes/reset-research.md §1.4 (safe-outputs split), notes/off-github.md §2.

## What it is

One job is a pure function: **job in -> agent -> result out**, checked by plain code before anything
acts. The agent never holds a GitHub token or an App key. The same files work whether GitHub Actions
carries them (now) or our own coordinator does (later, for outside slots).

```
job/  job.json        what to do (built by make_job from the issue, never by an agent)
      base.repo   owner/name, one of TARGETS in common.py (fizzyedit/fizzy on main, fizzyedit/dvui on
                  zig-0.17); the old https://github.com/<owner>/<name>.git form reads as the same slug.
                  Any other repo, or a base.branch other than the entry's (default: the entry's), is refused
      base.bundle     optional: git bundle holding base.sha (otherwise base.repo is fetched)
out/  result.json     what happened (written by `slot run`, never by the agent)
      change.mbox     git format-patch base.sha..HEAD (write and rework only)
      manifest.txt    "sha256  <name>" for job.json, result.json, change.mbox (if any), sorted by name
      result.sig      ssh-keygen -Y sign -n fizzy-slot over manifest.txt, with the slot key
      agent/          the agent's own files: report.md, pr-body.md, review.json, decline.md
      log.txt         the agent's stdout+stderr, last 2 MB
      events.jsonl    one heartbeat line every 60 s
```

## Three steps, three trust levels

| Step | Runs where, as whom | Holds | Trusts |
|---|---|---|---|
| `make_job` | publish runner, user `fizzy-publish` | read token for work + fizzy | the issue body only as data |
| `slot run` | a slot runner, user `fizzy-slot-<kind>` | the kind's CLI login, the slot key | nothing it receives |
| `slot validate` + `slot publish` | publish runner, user `fizzy-publish` | the App token, minted in that step | nothing from `out/` until checked |

The publish runner is a separate OS user on pop-os (and on Windows, for the always-on pair) with no
CLI logins, registered with the single label `publish`; no slot runner carries `publish`, and no
publish runner carries `slot`. App private keys are secrets of the work-repo environment `publish`,
which only publish jobs name. The validator and every tool it runs come from the work repo at the
workflow's own sha and from fizzy at `base.sha`, never from the patch.

The slot signature proves which slot produced a result and that nothing changed between the slot and
the validator. It is not a defence against our own agent (it runs as the user who holds the key):
that defence is the validator plus the token living only on the publish runner. For an outside slot
the key is its identity.

## job.json

```json
{
  "protocol": 1,
  "id": "work-704-w1-123456789",
  "kind": "write",
  "issue": {"repo": "fizzyedit/work", "number": 704, "title": "...", "area": "core",
            "labels": ["ready", "prio:1", "os:any"]},
  "base": {"repo": "fizzyedit/fizzy", "branch": "main", "sha": "9fc9c05...", "bundle": null},
  "branch": "core/touch-slop",
  "spec": "<the issue body, verbatim>",
  "in_bounds": ["sdk/src/dvui_context.zig", "core/core.zig", "app/layout/*.zig"],
  "not_in_scope": "<the Not in scope field, verbatim>",
  "acceptance": "<the Acceptance field, verbatim>",
  "gates": ["scripts/check-fmt.sh", "scripts/zb build --summary all"],
  "limits": {"minutes": 90, "max_changed_lines": 400},
  "lease": {"id": "work-704-w1-123456789", "ttl_minutes": 110},
  "attempt": 1,
  "for_review": null,
  "rework": null
}
```

- `id` = `work-<issue>-<w|r|k><round>-<GitHub run id>`; `lease.id` equals it while Actions carries the
  job (the run is the lease); the coordinator later issues its own.
- `kind`: `write` | `review` | `rework`. `base.sha` is main for write, the PR head for review and rework.
- `in_bounds`: paths and globs (`*` within one directory, `**` across) relative to the repo root, the
  issue's In bounds field after make_job expanded any `` `rg -l ...` `` command at `base.sha`. Write and
  rework only; review jobs carry `[]`.
- `limits.minutes`: write 90, rework 60, review 30 unless the issue's Notes say `Minutes: N` (max 180).
  `lease.ttl_minutes` = `limits.minutes` + 20.
- `for_review` (review only): `{"pr": 1000, "head_sha": "...", "author_kind": "codex",
  "must_fix": [<finding ids from the previous review>] | null}`; `must_fix` set = a re-review that checks
  only those findings (docs/REVIEW.md, one-review rule).
- `rework` (rework only): `{"pr": 1000, "round": 1, "author_kind": "codex", "findings": [<finding>],
  "ci_log_tail": "<last 200 lines of the failed ci-ok job>" | null, "conflict": false}`.
- Size: job.json at most 64 KiB (the spec is at most 12,000 characters).

## result.json

```json
{
  "protocol": 1,
  "job_id": "work-704-w1-123456789",
  "slot_id": "linux-codex-2",
  "agent_kind": "codex",
  "model": "gpt-5.5-codex",
  "os": "linux",
  "status": "done",
  "started_at": "2026-10-29T14:02:11Z",
  "finished_at": "2026-10-29T14:41:50Z",
  "title": "core: one touch slop for every tap-or-drag decision",
  "pr_body": "<out/agent/pr-body.md, verbatim>",
  "review": null,
  "decline": null,
  "gates": [{"cmd": "scripts/check-fmt.sh", "exit": 0, "seconds": 3}],
  "changed": {"files": 4, "added": 61, "deleted": 7},
  "report": "<out/agent/report.md, at most 8,000 characters>"
}
```

- `status`: `done` | `declined` (the spec has a gap: `decline` holds out/agent/decline.md, the APPROACH
  text) | `failed` (a gate is red, or the agent made no change, or broke a rule `slot run` checks) |
  `timeout`. `failed` and `timeout` carry `"error": "<one line>"`.
- `review` (review jobs): `{"verdict": "clean" | "changes", "findings": [<finding>], "follow_ups":
  [<finding>]}`, copied from out/agent/review.json after `slot run` checks its shape.
- A finding: `{"id": "F1", "severity": "blocker" | "major" | "minor" | "nit", "file": "core/x.zig",
  "line": 42, "added": true, "text": "..."}`. `added` = the line is a `+` line of the PR's diff.
  docs/REVIEW.md's rule, enforced by the validator: blockers, majors and minors with `added: true` are
  findings; every nit and every minor with `added: false` belongs in `follow_ups`.
- `verdict` is `changes` exactly when `findings` is not empty.

## change.mbox

`slot run`, not the agent, commits: after the agent exits it runs `git add -A` (the checkout's
.gitignore applies), then one commit `<title>` with author `fizzy <slot_id> <slot+<slot_id>@fizzy.invalid>`
and a `Signed-off-by:` line of the same identity, then `git format-patch --stdout base.sha..HEAD`.
Commits the agent made itself are kept and come first. No mbox for review jobs, nor when status is not
`done`.

## The signature

```
key:      ~/.config/fizzy-slot/key (ed25519, no passphrase, mode 0600), made once per slot user:
          ssh-keygen -t ed25519 -N '' -C <slot_id> -f ~/.config/fizzy-slot/key
sign:     ssh-keygen -Y sign -n fizzy-slot -f <key> out/manifest.txt      -> out/manifest.txt.sig
          (moved to out/result.sig)
verify:   ssh-keygen -Y verify -f slot/allowed_signers -I <slot_id> -n fizzy-slot \
            -s out/result.sig < out/manifest.txt, then every hash in manifest.txt recomputed
register: one line per slot in fizzyedit/work slot/allowed_signers:
          <slot_id> namespaces="fizzy-slot" ssh-ed25519 AAAA...
revoke:   delete the line (a PR to the work repo).
```

All slots of one OS user share that user's key; `slot_id` names the runner, and the key's comment
names the user (`fizzy-slot-codex@linux`). allowed_signers then lists each slot_id of that user with
the same key.

## `slot run`

```
slot run JOB_DIR --out OUT_DIR [--keep-checkout]
env:  SLOT_ID (linux-codex-2)  SLOT_KIND (claude|codex|agy)  SLOT_OS (linux|windows|macos)
      SLOT_HOME (default ~/.local/share/fizzy-slot: mirror and work dirs)
      SLOT_KEY (default ~/.config/fizzy-slot/key)  SLOT_BUILD_LOCKS (dir of build-slot locks)
      SLOT_BUILD_SLOTS (number, default 2)  SLOT_MODEL (optional model flag)
```

1. Read and check job.json (protocol 1, kind, sizes). Bad job: exit 2, no result.
2. Check out `base.sha` into a fresh dir `SLOT_HOME/work/<job id>`: from `base.bundle` (`git bundle
   verify`, clone) when set, else from the mirror `SLOT_HOME/mirror.git` after `git fetch` from
   `base.repo`. Hooks off (`core.hooksPath` to an empty dir). HEAD must equal `base.sha`.
3. Write the prompt (slot/prompts/<kind>.md with the job's fields filled in) and start the agent from
   slot/agents.json for `SLOT_KIND`, cwd = the checkout, with a clean environment: only PATH, HOME,
   USER, LANG, TMPDIR/TEMP, SYSTEMROOT (Windows) and `SLOT_*` pass; every `GITHUB_*`, `GH_*`,
   `ACTIONS_*`, `RUNNER_*` and `*_TOKEN` variable is dropped. stdout+stderr go to out/log.txt.
4. Every 60 s append `{"t": "<utc>", "job": "<id>", "phase": "agent|gates|pack"}` to out/events.jsonl.
5. At `limits.minutes`: terminate the agent's process tree, wait 30 s, kill it; status `timeout`.
6. After the agent: if out/agent/decline.md exists, status `declined`. Else, write and rework: commit
   (above); no change is `failed` ("no change"); more than `limits.max_changed_lines` added+deleted
   (files matching the test patterns excluded, as in Ops' auto-triage) is `failed`; then run each gate
   in order, holding one of `SLOT_BUILD_SLOTS` build locks in `SLOT_BUILD_LOCKS` (a lock file per slot,
   taken with an OS file lock, so it works on Windows), and stop at the first red gate (`failed`).
   Review: out/agent/review.json must parse and match the shape above, else `failed`.
7. Write result.json, change.mbox, manifest.txt, result.sig. Delete the checkout unless
   `--keep-checkout`.

Exit codes: 0 done, 3 declined, 4 failed, 5 timeout, 2 bad job or usage, 6 the slot is broken (agent
CLI missing, not signed in, key missing, fetch failed): the run is retried elsewhere, never counted as
the job's attempt. Exits 3-5 still leave a complete signed out/.

slot/agents.json (config, not code):

```json
{
  "claude": {"cmd": ["claude", "-p", "--output-format", "text", "--permission-mode", "acceptEdits"],
             "model_flag": "--model", "prompt": "stdin"},
  "codex":  {"cmd": ["codex", "exec", "--sandbox", "workspace-write", "-"],
             "windows_cmd": ["codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "-"],
             "model_flag": "--model", "prompt": "stdin"},
  "agy":    {"cmd": ["agy", "-p"], "model_flag": "--model", "prompt": "arg"}
}
```

(The exact flags of each CLI are for Ops to confirm on each machine; the shape is fixed.)

The prompt tells the agent: the spec; edit files only, do not commit, push or call GitHub; run the
gates and fix until they pass; write out/agent/pr-body.md (the plain PR page, docs/AGENT_WORK.md) and
out/agent/report.md; if the spec has a gap, write out/agent/decline.md (the gap in one line, at most two
options with their cost, your pick) and stop; review jobs write out/agent/review.json in the shape above.
`out/agent` is passed as an absolute path outside the checkout.

## `slot validate` and `slot publish`

```
slot validate JOB_DIR OUT_DIR --fizzy BASE_CHECKOUT    exit 0 accept, 1 refuse (reasons on stderr,
                                                       and in OUT_DIR/../verdict.json)
slot publish  JOB_DIR OUT_DIR                          acts; needs GH_TOKEN (the App token)
```

The validator refuses when any of these fails, and lists every failure, not the first:

1. job.json is the one make_job wrote (the workflow passes the plan job's artifact digest; the
   manifest's job.json hash must match it).
2. The signature verifies for `result.slot_id`; every manifest hash matches; `result.job_id` = job id.
3. Lease: `finished_at` - `started_at` <= `lease.ttl_minutes`; the issue is open and still `ready`
   (write) or the PR is open with head = `base.sha` (review, rework).
4. Write and rework: `git am --3way` of change.mbox applies cleanly on a fresh clone at `base.sha`;
   every touched path matches `in_bounds`; the size is under `limits.max_changed_lines`; every
   commit author and Signed-off-by is the slot identity.
5. Risky paths (slot/risky-paths.txt, one regex, today's list: `sdk/`, `build/`, `.github/`, build.zig,
   core/platform.zig, scripts/lint, AGENTS.md, CLAUDE.md, rules/credentials/secrets/releases): not a
   refusal when the path is in bounds; the result is `risky: true` and the PR gets label `gate:yes`.
6. The PR body passes fizzy's scripts/check-pr-body **from base.sha** (not from the patch).
7. Review: `agent_kind` != `for_review.author_kind`; every finding's file and line exist at
   `head_sha` and `added` is true exactly when the line is a `+` line of the PR diff; the
   finding/follow-up split follows the rule above; `verdict` matches; a re-review (`must_fix` set) has
   no finding outside `must_fix`.
8. `status` is `done` (or `declined`: accepted, and publish posts the APPROACH; or `failed`/`timeout`:
   accepted, and publish records the failure).

`slot publish`, by kind and status (work-repo App acts in fizzyedit/work, the system's App in fizzy):

| Result | Action |
|---|---|
| write done | push `branch` to the target repo (new branch, fails if it exists), open the PR against its branch (ready, not draft) with `pr_body` + `Part of fizzyedit/work#N`, labels `area:<x>`, `kind:<agent_kind>` from result.json (never the issue's work-kind labels), `gate:yes` if risky or the target has no review bridge (dvui), which also dispatches `review` `{pr, repo}` to the work repo; a clean dvui review never runs `gh pr merge --auto` |
| rework done | push to the PR's branch, fast-forward only (refuse if head moved), label `rework:<round>` |
| review done | comment the findings on the PR's pr-thread issue in work (`REVIEW: clean|changes @<sha>`); commit status `agent-review` on `head_sha` (success when clean); follow-ups appended to the PR's follow-up list; `changes` dispatches `rework` (round + 1), round 3 labels `stuck` instead; `clean` runs `gh pr merge --auto` |
| declined | comment `APPROACH:` + the decline on the issue, label `arch:needed`, remove `ready` |
| failed / timeout | comment one line + the report tail on the issue; label `attempt:<n>`; at attempt 2, `stuck` |
| refused (validator) | comment the reasons on the issue; label `stuck`; nothing pushed |

Every action is idempotent (it checks before it writes), so a re-run of publish does no harm.

## How the Actions jobs call it (fizzyedit/work/.github/workflows)

```
write.yml   on: issues labeled ready | repository_dispatch write | workflow_dispatch(issue)
  plan     runs-on [self-hosted, publish]  actor check; area lock; make_job -> artifact job
  run      runs-on [self-hosted, slot, <os or none>, kind-<k> if writer:<k>]
           concurrency: area-<area>, queue: max; timeout-minutes: lease.ttl_minutes
           permissions: {}   (no GITHUB_TOKEN rights)  steps: download job; slot run; upload out
  publish  runs-on [self-hosted, publish]  environment: publish  if: always() && plan succeeded
           steps: checkout fizzy@base.sha; slot validate; create-github-app-token; slot publish
review.yml  on: repository_dispatch pr {pr, sha, author_kind}  (sent by fizzy's bridge)
  run      runs-on [self-hosted, slot, review-for-<author_kind>]
rework.yml  on: repository_dispatch rework {pr, round, findings | ci | conflict}
  run      runs-on [self-hosted, slot, kind-<author_kind>]
sweep.yml   on: schedule */15 | repository_dispatch merged {pr, area}
```

Runner labels: a slot runner carries `slot`, `<os>`, `kind-<k>` and `review-for-<every other kind>`.
Area lock: `plan` looks for an open fizzy PR labelled `area:<x>`; if one exists it labels the issue
`deferred` and stops; the `merged` dispatch (and the sweeper) re-dispatch that area's deferred issues.

## Per-slot OS users and keys

- One OS user per kind per machine: `fizzy-slot-claude`, `fizzy-slot-codex`, `fizzy-slot-agy` (Windows:
  local accounts; the existing `fizzy-worker` may stay the Windows user for codex+claude at first). Each
  holds its own CLI login, signed in once by foxnne on that user (never copied), its slot key, its
  mirror. No sudo, home 0700, not in any group that reads /etc/fizzy.
- N runner services per user (`actions-runner-<kind>-<n>`), each with its own work dir, running as
  that user (systemd `User=`; Windows service logon = the account).
- `fizzy-publish`: the publish runner's user. No CLI logins, no slot key; it receives App tokens only
  through the environment secret in the publish step.

## Not in v1

The coordinator (leases over HTTPS, SSE, outside slots), signed jobs (job.json signed by make_job),
base bundles from make_job (fizzy is public: fetch is enough; `slot run` already accepts a bundle),
review of risky PRs by two kinds, and any change to how fizzy's CI runs.
