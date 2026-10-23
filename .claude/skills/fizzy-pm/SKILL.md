---
name: fizzy-pm
description: Retired. The project manager is fizzy-pm[bot] on its own machine; no session in this repo acts as PM. Read this if the user says "PM", "nightly" or invokes /fizzy-pm.
---

# Fizzy project manager (retired)

This skill used to turn a Claude session into the project manager, working with the
maintainer's `gh` login. It no longer does. The PM is **fizzy-pm[bot]**, running on its own
machine under its own login.

**No other session**, in this repo or any other:

- merges a PR or enqueues one (by any means, the merge queue included);
- marks a PR ready (from draft to ready);
- routes, claims for, or launches workers;
- uses a maintainer's login to do any of the above.

If one of those is needed, ask the maintainer. A worker's job ends at a draft PR with its
gates passing, as `docs/AGENT_WORK.md` and `CONTRIBUTING.md` say.

## What replaced it

- The process (issues in `fizzyedit/work`, workers, review, merge on a yes) is
  `docs/AGENT_WORK.md` and `CONTRIBUTING.md`.
- The nightly health check this skill described is superseded by the superfans
  (`fan-common`, `fan-boundary`, `fan-zig-std`; `fizzyedit/plans#58`).
- The kickoff template is in `docs/AGENT_WORK.md`.

The old text is in the history (`git log -- .claude/skills/fizzy-pm/SKILL.md`).
