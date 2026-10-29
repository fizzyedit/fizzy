# Try a slot locally

A slot is a worker that takes a job, runs an agent in a fresh checkout, and returns a result.
It runs the job's checks and packages a successful change with a signature identifying the slot.
The agent has no GitHub token; separate validation and publishing decide what happens next.

## Commands
Use `scripts/slot/slot` from the repository root (called `slot` in [PROTOCOL.md](PROTOCOL.md)).

- `slot run JOB_DIR --out OUT_DIR`: takes `JOB_DIR/job.json` and an optional base bundle.
  Configure `SLOT_ID`, `SLOT_KIND`, `SLOT_OS`, and `SLOT_KEY`; `SLOT_HOME` holds temporary checkouts.
  Writes `result.json`, `manifest.txt`, `result.sig`, agent files, logs and heartbeats into OUT_DIR,
  plus `change.mbox` for successful write/rework jobs. Success prints nothing; errors go to stderr.
  Exit: 0 done, 3 declined, 4 failed, 5 timeout, 2 bad job/usage, 6 broken slot.
- `slot validate JOB_DIR OUT_DIR --fizzy BASE_CHECKOUT --job-digest SHA256`: takes the original
  job's digest, signed output and trusted base checkout; checks them before any publishing.
  Prints refusal reasons to stderr and writes `OUT_DIR/../verdict.json`; exits 0 accept, 1 refuse.
- `slot publish JOB_DIR OUT_DIR`: takes validated output and `GH_TOKEN` (the App token).
  Publishes the change/review or records a decline/failure on GitHub, according to the result.
  Success has no summary on stdout; errors go to stderr. This step acts on GitHub.

## Offline example
Requires Python 3, Git and OpenSSH (`ssh-keygen` with `-Y` support); no agent login or token.
Paste this from the repository root in a POSIX shell. It uses the fake agent and temporary files;
the printed status comes from the result file, since `slot run` itself is silent on success.

```sh
python3 - <<'PY'
import json, os, subprocess, sys, tempfile
from pathlib import Path
slot = Path('scripts/slot').resolve()
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    env = {**os.environ, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
    env.update(GIT_AUTHOR_NAME='Demo', GIT_AUTHOR_EMAIL='demo@example.invalid',
               GIT_COMMITTER_NAME='Demo', GIT_COMMITTER_EMAIL='demo@example.invalid')
    base = root / 'base'; base.mkdir()
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=base, env=env, stderr=subprocess.PIPE).decode().strip()
    git('init'); git('-c', 'commit.gpgSign=false', 'commit', '--allow-empty', '-m', 'base')
    job = root / 'job'; job.mkdir()
    (job / 'job.json').write_text(json.dumps(dict(protocol=1, id='local-demo', kind='write',
        issue=dict(title='Say hello'), base=dict(repo=str(base), sha=git('rev-parse', 'HEAD'), bundle=None),
        branch='demo/hello', spec='Write hello.txt', in_bounds=['hello.txt'], not_in_scope='Other files',
        acceptance='Hello is written', gates=[], limits=dict(minutes=1, max_changed_lines=10))))
    key = root / 'key'
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    agents = root / 'agents.json'
    agents.write_text(json.dumps({'codex': dict(cmd=[sys.executable, str(slot / 'fakes/agent.py'), 'write-ok'], prompt='stdin')}))
    env.update(SLOT_ID='local-demo', SLOT_KIND='codex', SLOT_KEY=str(key),
               SLOT_HOME=str(root / 'home'), SLOT_AGENTS=str(agents))
    out = root / 'out'
    subprocess.run([sys.executable, str(slot / 'slot'), 'run', str(job), '--out', str(out)], env=env, check=True)
    print('status:', json.loads((out / 'result.json').read_text())['status'])
    print('patch:', (out / 'change.mbox').is_file(), 'signature:', (out / 'result.sig').is_file())
PY
```

Expected output: `status: done` then `patch: True signature: True`. Temporary files are removed.
Tests live in `scripts/slot/tests`: `cd scripts && python3 -m unittest discover -s slot/tests -t .`.
