# Review standard

What a reviewer answers about a PR, and what a writer answers about their own before handing it
off. The same four questions, the same format. Zig and comment rules are not repeated here:
[`docs/STYLE.md`](STYLE.md) and `docs/ZIG.md` hold them, and a finding cites the rule.

## The four questions

1. **Q1 Goal.** Does the change accomplish its goal: the issue's `Done`, with the harness's
   build and test results as evidence?
2. **Q2 Redundancy and Zig standard.** Is there redundant code or a Zig-standard problem? Name
   the existing code it duplicates, or the `docs/ZIG.md` rule it breaks.
3. **Q3 Better approach.** Is there a better approach worth reworking? Only with a concrete
   alternative: what it is, its rough size, and why it is better.
4. **Q4 Fit.** Does it fit the plan step and the big picture? Flag drift; the PM decides.

## The answer format

```
VERDICT: clean | changes | unable
Q1 Goal: met | partly | not met: <evidence>
Q2 Lean and Zig: <findings, or "none found">
Q3 Approach: keep | consider: <the alternative, if any>
Q4 Fit: aligned | drift: <what drifted from which plan step>
Risk: <what the change could break, or "none">
Net lines: +<added> -<removed>
Findings:
F1 [blocker|major|minor|nit] [Q1-Q4] file:line: what and why
F2 ...
Not checked: <what was not verified, or "nothing">
```

The harness checks the first line and the four `Q` lines by these exact prefixes. Only blocker
and major make the verdict `changes`; `unable` means the review could not be done.

Findings are numbered `F<n>` in one list, most severe first. A writer answering for their own
PR uses the same shape, with `VERDICT` replaced by what they changed after answering.

## Severity

- **blocker**: wrong behaviour, a crash, a leak, build or tests fail, the goal is not met.
- **major**: duplicates existing code; a Zig-standard break with real cost; new logic without a
  test; a test that passes without the change; drift from the plan step.
- **minor**: readability, naming, small lean gains.
- **nit**: taste.

Only blocker and major hold a PR. Minor and nit are the writer's to take or leave.

## Lean

- A new helper is used more than once, or is clearer than the code it replaces.
- No rename-only wrappers.
- No dead code.
- No comments that restate the code.
- Report net lines. Deletions are welcome.

## Evidence

Every finding cites `file:line` or gate output. Anything not verified says so ("not run",
"read, not built"); an unverified claim is not a finding.

## Writers

Before handing a PR off, answer the four questions about it in the format above, fix what
holds, and put the answer in the PR body.
