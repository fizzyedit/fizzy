<!--
Title: `area: what changes`, 72 characters at most, in words a visitor understands (never a branch slug or "work-N"). It becomes the commit on main.
This page is public: write the plain sections for someone who has never read the code (docs/AGENT_WORK.md, "The PR page").
`scripts/check-pr-body <PR number>` checks the shape. How we work: CONTRIBUTING.md.
-->

Part of #<!-- the plan's issue, if there is one -->

## In plain words

<!-- Two to four sentences: what changes for a person using fizzy, and why it matters. No function, file or flag names. -->

## What changes

<!-- Bullets, in plain terms. At least one fenced code snippet taken from the diff: a before/after or the key function, 15 lines at most. -->

## What you will notice

<!-- What a person sees or feels. Or: "Nothing visible: internal", and what it makes possible. -->

## How we know it works

<!-- In plain terms: the tests that fail without the change, the check on a real device, the measurement. -->

## How this serves fizzy

<!-- One sentence: the goal or principle this moves, and the result for people, linked to its anchor:
[Phones and tablets](https://github.com/fizzyedit/fizzy/blob/main/docs/VISION.md#mobile)
Anchors: speed, quality, demos, mobile, platform, agents, collaboration, materials; principles: zig-quality, lean,
measured, respect, every-platform, delight, craft, app-owns-look, evidence. -->

<details><summary>For agents: technical summary</summary>

## Goal

## What changed and why

<!-- What was measured, what was tried and dropped. -->

## How it was verified

<!-- Per platform: a test, a demo tape, a screenshot, a measurement. Leave a platform unticked rather than claim it. -->

- [ ] macOS:
- [ ] Windows:
- [ ] Linux:
- [ ] Web:

## SDK impact

- [ ] None
- [ ] Core-only or additive: reaches plugins at the next SDK release
- [ ] Fingerprint moved: recorded in `sdk/src/version.zig`, `sdk_version` untouched, PR labelled `sdk`
- [ ] SDK release: bumps `sdk_version`, lists the `sdk` PRs since the last `sdk-v*` tag

## Not done / follow-ups

<!-- What was deliberately left out, with an issue if it outlives this PR. -->

</details>

<!-- agent-notes {"issue":0,"worker":"","slot":"","status":"draft","area":"","open_questions":[],"next":"review"} -->
