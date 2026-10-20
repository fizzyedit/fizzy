#!/usr/bin/env python3
"""Checks scripts/agent-record against saved gh JSON: a fake `gh` answers each endpoint from a fixture."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

RECORD = Path(__file__).resolve().parent / "agent-record"

FAKE_GH = """#!/usr/bin/env python3
import os, sys
args = [a for a in sys.argv[1:] if not a.startswith("-")]
key = [a for a in args if a.startswith(("repos/", "search/")) or a == "graphql"][0].replace("/", "_")
print(open(os.path.join(os.environ["FIXTURES"], key + ".json")).read())
"""


def sha(n):
    return f"sha{n}"


def fixtures():
    c = lambda n, date: {"sha": sha(n), "commit": {"committer": {"date": date}}}
    run = lambda i, conclusion, at: {"id": i, "conclusion": conclusion, "completed_at": at}
    return {
        "repos_fizzyedit_fizzy_pulls_7": {"body": "ci: thing\n\nPart of fizzyedit/work#14\n"},
        "repos_fizzyedit_fizzy_pulls_8": {"body": "no reference here"},
        "repos_fizzyedit_work_issues_14": {"labels": [{"name": "agent"}, {"name": "running:codex"}]},
        "repos_fizzyedit_fizzy_pulls_7_commits": [[
            c(1, "2026-10-01T10:00:00Z"), c(2, "2026-10-01T11:00:00Z"),
            c(3, "2026-10-02T09:00:00Z"), c(4, "2026-10-02T10:00:00Z")]],
        "repos_fizzyedit_fizzy_commits_sha1_check-runs": [{"check_runs": [run(1, "success", "2026-10-01T10:05:00Z")]}],
        "repos_fizzyedit_fizzy_commits_sha2_check-runs": [{"check_runs": [run(2, "failure", "2026-10-01T11:30:00Z")]}],
        "repos_fizzyedit_fizzy_commits_sha3_check-runs": [{"check_runs": [
            run(3, "failure", "2026-10-02T09:30:00Z"), run(4, "cancelled", "2026-10-02T09:31:00Z")]}],
        "repos_fizzyedit_fizzy_commits_sha4_check-runs": [{"check_runs": [run(5, "success", "2026-10-02T10:05:00Z")]}],
        "repos_fizzyedit_fizzy_issues_7_timeline": [[
            {"event": "ready_for_review", "created_at": "2026-10-01T10:30:00Z"}, {"event": "labeled"}]],
        "repos_fizzyedit_fizzy_pulls_7_comments": [[{"id": 1}, {"id": 2}, {"id": 3}]],
        "graphql": {"data": {"repository": {"pullRequest": {"reviewThreads": {
            "nodes": [{"id": "a"}, {"id": "b"}], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}}},
        "search_issues": [{"items": [{"number": 7}, {"number": 8}]}],
    }


def run(args, env):
    return subprocess.run([sys.executable, str(RECORD), *args], capture_output=True, text=True, env=env)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "fx").mkdir()
        (tmp / "bin").mkdir()
        for name, body in fixtures().items():
            (tmp / "fx" / f"{name}.json").write_text(json.dumps(body))
        gh = tmp / "bin" / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        log = tmp / "cache" / "log.txt"
        env = {**os.environ, "PATH": f"{tmp / 'bin'}:{os.environ['PATH']}", "FIXTURES": str(tmp / "fx"),
               "FIZZY_AGENT_LOG": str(log)}

        # Ready at 10:30: commits 2, 3, 4 come after; reds are runs 2 and 3 (cancelled is not a failure).
        want = "#7 | codex | 3 | 3c/2t | 2"
        out = run(["7"], env)
        assert out.returncode == 0 and out.stdout.strip() == want, out
        assert log.read_text() == want + "\n"

        out = run(["7"], env)
        assert out.stdout.strip() == want and log.read_text() == want + "\n", "recorded twice"

        out = run(["8"], env)
        assert out.returncode != 0 and "Part of" in out.stderr, out

        log.unlink()
        out = run(["--all", "2026-10-01"], env)
        assert out.returncode == 0 and out.stdout.strip() == want and log.read_text() == want + "\n", out

        assert run([], env).returncode != 0
    print("ok")


main()
