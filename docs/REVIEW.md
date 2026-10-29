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
F1 [blocker|major|minor] [Q1-Q4] file:line: what and why
F2 ...
Follow-ups:
- [minor|nit] file:line: what and why
Not checked: <what was not verified, or "nothing">
```

The harness checks the first line and the four `Q` lines by these exact prefixes. Only blocker
and major make the verdict `changes`; `unable` means the review could not be done.

Findings are numbered `F<n>` in one list, most severe first; follow-ups are not numbered. Write
`none` under either heading when it is empty. A writer answering for their own PR uses the same
shape, with `VERDICT` replaced by what they changed after answering.

## Severity

A finding is **blocker** or **major** only when it breaks the issue's `Done` criteria, a test,
correctness, or a principle of the vision, and it says which. Everything else is minor or nit.

- **blocker**: wrong behaviour, a crash, a leak, build or tests fail, the goal is not met.
- **major**: breaks a named `Done` criterion, a test or a vision principle, for example
  duplicated code (Lean), a `docs/ZIG.md` break with real cost (code quality), new logic without
  a test, a test that passes without the change, or drift from the plan step. Name the principle.
- **minor**: readability, naming, small lean gains.
- **nit**: taste.

## Findings or follow-ups

Where an item goes depends on its severity and on whether the PR adds the line it is about.

| Item | Goes in | The writer |
|---|---|---|
| blocker or major, anywhere | `Findings` | must fix it, or decline with a reason the PM rules on |
| minor on a line the PR adds | `Findings` | answers it: fixed, or declined with a reason |
| minor on a line the PR does not touch | `Follow-ups` | may take it or leave it |
| nit, anywhere | `Follow-ups` | may take it or leave it |

A line the PR adds is a `+` line of `git diff -U0 <base>...<head>`: new, changed or moved lines. A
line that is only context in that diff, or not in it at all, is untouched. Cite the added line:
when the problem shows only beside old code (a new call that misuses an old function), the finding
anchors on the new call.

Only blocker and major make the verdict `changes`. A `clean` review may still list minor
findings; the writer answers them in `FIXES` before the PR is approved. The PM files a review's
`Follow-ups` as one issue; they never hold the PR.

## How many reviews

One reviewer reviews an ordinary PR: a worker of another kind than the author (claude, codex or
agy), on the other always-on system when it can. The PM adds a second reviewer when the PR:

- is risky: CI, the gate, agent rules, credentials, releases, `AGENTS.md` or `CLAUDE.md`;
- changes a shared piece (one a design note in fizzyedit/plans covers);
- is large: over 400 lines outside tests;
- had a blocker found: the second reviewer reads the head after the fix.

## Rounds

- **Evidence first.** A PR whose `Done` needs evidence (numbers, screenshots, a tape) is not
  reviewed until the evidence is in its body.
- **Verify checks the must-fix list.** `VERIFY` checks only the must-fix items the `RULING` (or
  rework issue) lists; a minor's answer is the writer's word. A new finding at verify is a
  follow-up, unless it is a blocker the fix itself caused.
- **Two fix rounds at most.** After the second the PM decides once: merge with follow-ups,
  split, or close and restart. The stage labels and markers are in
  [`AGENT_WORK.md`](AGENT_WORK.md).

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

After a review, answer every `F<n>` finding in one `FIXES` comment ([`AGENT_WORK.md`](AGENT_WORK.md)
has its form): fixed, with the commit, or declined, with the reason. Follow-ups need no answer;
one taken in the same PR is named in `FIXES` as `follow-up taken: <file:line>`.
