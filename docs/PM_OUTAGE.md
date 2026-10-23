# When the PM is down

The PM (Fizzy, on pop-os) is the only identity that can post `pm-approval`. If it is down, workers
keep claiming issues and opening PRs, but nothing reaches `main`. This is the safe failure.

## How you find out

`pm-stall` in fizzyedit/work opens an issue labelled `pm-stalled` when a PR has had a green `ci-ok`
for 6 hours with no `pm-approval`. It runs on GitHub, so it fires when pop-os is off.

## Check the PM

- `systemctl --user status fizzy-pm.service` as user `agent` on pop-os.
- `tailscale status` shows whether pop-os is online.

## Merging while the PM is down

Only the maintainer does this, and only for a PR with green `ci-ok` that a second worker reviewed.
Use the repo Admin bypass on the `main` ruleset (pull requests only), then merge from the PR page.
Do not turn the ruleset off. Say in the PR that the merge bypassed `pm-approval`.

## Afterwards

When the PM is back, it reads the PRs merged without `pm-approval` and reports anything it would
not have approved. Credentials stay on pop-os: do not copy `/etc/fizzy/pm.pem` to another machine.
