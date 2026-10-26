---
name: fizzy-pm
description: Retired. The project manager is fizzy-pm[bot] on its own machine; no session in this repo acts as PM. Read this if the user says "PM", "nightly" or invokes /fizzy-pm.
---

# Fizzy project manager (retired)

This skill used to turn a Claude session into the project manager, working with the
maintainer's `gh` login. It no longer does. The PM is **fizzy-pm[bot]**, running on its own
machine under its own login.

**No session acts as PM.** A session does not use the maintainer's login to route, claim for or
launch workers, or to merge, enqueue or mark ready a PR it does not own. A worker's own PR
follows `CONTRIBUTING.md` ("Claim before you build") and `docs/AGENT_WORK.md` ("Review"), which
govern when it goes ready and who merges. If PM work is needed, ask the maintainer.

## What replaced it

- The process (issues in `fizzyedit/work`, workers, review, merge on a yes) is
  `docs/AGENT_WORK.md` and `CONTRIBUTING.md`.
- The nightly health check this skill described is superseded by the superfans
  (`fan-common`, `fan-boundary`, `fan-zig-std`; `fizzyedit/plans#58`). The cloud smoke run and
  the release steps (plugin tags, SDK go-live) are retired with it; `RELEASING.md` and
  `CONTRIBUTING.md` ("Changing the SDK") are where releases are written down.
- The kickoff template is in `docs/AGENT_WORK.md`.

The old text is in the history (`git log -- .claude/skills/fizzy-pm/SKILL.md`).
