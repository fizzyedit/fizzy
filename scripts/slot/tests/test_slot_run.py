"""Protocol integration tests: real git and OpenSSH, fake agent, no network."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

from slot import common, slot_run

ROOT = Path(__file__).resolve().parents[1]


class SlotRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / 'base.repo'
        self.base.mkdir()
        self.env = {**os.environ, 'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                    'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}
        self.git(self.base, 'init')
        (self.base / 'hello.txt').write_text('base\n')
        self.git(self.base, 'add', '.')
        self.git(self.base, '-c', 'commit.gpgSign=false', 'commit', '-m', 'base')
        sha = self.git(self.base, 'rev-parse', 'HEAD').strip()
        self.job_dir = self.root / 'job'
        self.job_dir.mkdir()
        self.job = dict(protocol=1, id='work-721-w1-test', kind='write',
                        issue=dict(title='Improve hello'), base=dict(repo=str(self.base), sha=sha, bundle=None),
                        branch='test/change', spec='Update hello.', in_bounds=['hello.txt'],
                        not_in_scope='Other files', acceptance='Hello is improved', gates=[],
                        limits=dict(minutes=1, max_changed_lines=400), for_review=None, rework=None)
        self.key = self.root / 'key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)
        self.signers = self.root / 'allowed_signers'
        self.signers.write_text('test-slot namespaces="fizzy-slot" ' + Path(str(self.key) + '.pub').read_text())
        self.env.update(SLOT_ID='test-slot', SLOT_KIND='codex', SLOT_OS='windows' if os.name == 'nt' else 'linux',
                        SLOT_HOME=str(self.root / 'home'), SLOT_KEY=str(self.key),
                        SLOT_BUILD_LOCKS=str(self.root / 'locks'), SLOT_HEARTBEAT_SECONDS='1')
        self.out = self.root / 'out'

    def git(self, repo, *args):
        return subprocess.check_output(['git', *args], cwd=repo, env=self.env, stderr=subprocess.PIPE).decode()

    def run_slot(self, mode='write-ok', keep=False, agent=None):
        (self.job_dir / 'job.json').write_text(json.dumps(self.job))
        agents = self.root / 'agents.json'
        agents.write_text(json.dumps({self.env['SLOT_KIND']: dict(cmd=[sys.executable, str(agent or ROOT / 'fakes/agent.py'), mode],
                                                   prompt='stdin', model_flag='--model', auth_exit=[64])}))
        self.env['SLOT_AGENTS'] = str(agents)
        args = [sys.executable, str(ROOT / 'slot'), 'run', str(self.job_dir), '--out', str(self.out)]
        if keep:
            args.append('--keep-checkout')
        proc = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=20)
        self.detail = proc.stderr
        return proc.returncode

    def result(self, status):
        value = json.loads((self.out / 'result.json').read_text())
        self.assertEqual(value['status'], status)
        self.assertTrue(common.verify(self.out / 'manifest.txt', self.out / 'result.sig', self.signers, 'test-slot'))
        self.assertEqual((self.out / 'manifest.txt').read_text(), common.manifest(self.out))
        for line in (self.out / 'manifest.txt').read_text().splitlines():
            digest, name = line.split('  ')
            self.assertEqual(digest, hashlib.sha256((self.out / name).read_bytes()).hexdigest())
        if status != 'done' or self.job['kind'] == 'review':
            self.assertFalse((self.out / 'change.mbox').exists())
        return value

    def test_write_ok_signed_result(self):
        self.assertEqual(self.run_slot(), 0, self.detail)
        self.result('done')
        self.git(self.base, 'am', str(self.out / 'change.mbox'))
        self.assertEqual((self.base / 'hello.txt').read_text(), 'hello from agent\n')
        self.assertIn('Signed-off-by: fizzy test-slot <slot+test-slot@fizzy.invalid>', self.git(self.base, 'log', '-1', '--format=%B'))
        self.assertFalse((self.root / 'home/work' / self.job['id']).exists())

    def test_decline(self):
        self.assertEqual(self.run_slot('decline'), 3, self.detail)
        self.assertIn('Missing acceptance', self.result('declined')['decline'])

    def test_workspace_decline_is_copied_to_output(self):
        agent = self.root / 'decline_agent.py'
        agent.write_text("from pathlib import Path\n"
                         "import sys\n"
                         "prompt = sys.stdin.read()\n"
                         "note = Path(prompt.split('Decline note path: ', 1)[1].splitlines()[0])\n"
                         "assert note.is_absolute() and note.parent == Path.cwd()\n"
                         "note.write_text('Question: which acceptance criterion applies?')\n"
                         "sys.exit(1)\n")
        for agent_kind in ('codex', 'claude'):
            for kind in ('write', 'review', 'rework'):
                with self.subTest(agent=agent_kind, kind=kind):
                    self.env['SLOT_KIND'] = agent_kind
                    self.job['kind'] = kind
                    self.out = self.root / ('out-' + agent_kind + '-' + kind)
                    self.assertEqual(self.run_slot(agent=agent), 3, self.detail)
                    note = (self.out / 'decline.md').read_text()
                    self.assertEqual(note, 'Question: which acceptance criterion applies?')
                    result = self.result('declined')
                    self.assertEqual(result['agent_kind'], agent_kind)
                    self.assertEqual(result['decline'], note)
                    self.assertEqual((self.out / 'agent/decline.md').read_text(), note)
                    self.assertFalse((self.root / 'home/work' / self.job['id']).exists())

    def test_workspace_pr_body_and_report_are_collected(self):
        agent = self.root / 'workspace_agent.py'
        agent.write_text("from pathlib import Path\n"
                         "import json, sys\n"
                         "prompt = sys.stdin.read()\n"
                         "for label, text in [('PR body path: ', '## In plain words\\nA useful change.'), "
                         "('Report path: ', 'Verified.')]:\n"
                         "    if label not in prompt: continue\n"
                         "    path = Path(prompt.split(label, 1)[1].splitlines()[0])\n"
                         "    assert path.is_absolute() and path.parent == Path.cwd()\n"
                         "    path.write_text(text)\n"
                         "if prompt.startswith('Review'):\n"
                         "    path = Path(prompt.split('Review path: ', 1)[1].splitlines()[0])\n"
                         "    assert path.is_absolute() and path.parent == Path.cwd()\n"
                         "    path.write_text(json.dumps(dict(verdict='clean', findings=[], follow_ups=[])))\n"
                         "else:\n"
                         "    Path('hello.txt').write_text('improved\\n')\n")
        for kind in ('write', 'rework', 'review'):
            with self.subTest(kind=kind):
                self.job['kind'] = kind
                self.job['id'] = 'workspace-artifacts-' + kind
                self.out = self.root / ('out-' + kind)
                self.assertEqual(self.run_slot(agent=agent, keep=True), 0, self.detail)
                result = self.result('done')
                self.assertEqual(result['report'], 'Verified.')
                self.assertEqual((self.out / 'agent/report.md').read_text(), 'Verified.')
                if kind != 'review':
                    self.assertEqual(result['pr_body'], '## In plain words\nA useful change.')
                    self.assertEqual(result['changed']['files'], 1)
                if kind == 'review':
                    self.assertEqual(result['review']['verdict'], 'clean')
                    self.assertTrue((self.out / 'agent/review.json').is_file())
                work = self.root / 'home/work' / self.job['id']
                self.assertFalse((work / 'review.json').exists())
                self.assertFalse((work / 'pr-body.md').exists())
                self.assertFalse((work / 'report.md').exists())

    def test_no_change_fails(self):
        self.assertEqual(self.run_slot('no-change'), 4, self.detail)
        self.assertEqual(self.result('failed')['error'], 'no change')

    def test_too_big_fails(self):
        self.assertEqual(self.run_slot('write-huge'), 4, self.detail)
        self.assertIn('non-test', self.result('failed')['error'])

    def test_gate_red_fails(self):
        # list2cmdline is cmd.exe quoting; shlex.join is POSIX shell quoting.
        args = [sys.executable, '-c', 'raise SystemExit(1)']
        self.job['gates'] = [subprocess.list2cmdline(args) if os.name == 'nt' else shlex.join(args)]
        self.assertEqual(self.run_slot(), 4, self.detail)
        self.assertEqual(self.result('failed')['gates'][0]['exit'], 1)

    def test_out_of_time_kills_agent(self):
        self.job['limits']['minutes'] = 0.05
        before = time.monotonic()
        self.assertEqual(self.run_slot('sleep'), 5, self.detail)
        self.assertLess(time.monotonic() - before, 15)
        self.result('timeout')
        pids = json.loads((self.out / 'agent/pids.json').read_text())
        for pid in pids:
            if os.name == 'nt':
                listing = subprocess.check_output(['tasklist', '/FI', f'PID eq {pid}', '/FO', 'CSV']).decode()
                self.assertNotIn(f'"{pid}"', listing)
            else:
                stat = Path(f'/proc/{pid}/stat')
                if stat.exists():
                    self.assertEqual(stat.read_text().split(')')[1].split()[0], 'Z')
                else:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)

    def test_agent_env_has_no_tokens(self):
        names = ['GITHUB_TOKEN', 'GH_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'FOO_TOKEN',
                 'RUNNER_SECRET', 'GITHUB_OTHER', 'SLOT_PRIVATE_TOKEN', 'UNRELATED']
        self.env.update({name: 'fake-secret' for name in names})
        self.assertEqual(self.run_slot('env-dump'), 0, self.detail)
        env = json.loads(self.result('done')['report'])
        for name in names:
            self.assertNotIn(name, env)
        self.assertIn('PATH', env)
        self.assertEqual(env['SLOT_ID'], 'test-slot')

    def test_hooks_not_run(self):
        marker = self.root / 'hook-ran'
        hook = self.base / '.git/hooks/post-commit'
        hook.write_text('#!/bin/sh\ntouch "' + str(marker).replace('\\', '/') + '"\n')
        hook.chmod(0o755)
        self.env['GIT_TEMPLATE_DIR'] = str(self.base / '.git')
        self.assertEqual(self.run_slot(keep=True), 0, self.detail)
        self.assertFalse(marker.exists())
        work = self.root / 'home/work' / self.job['id']
        self.assertTrue(self.git(work, 'config', 'core.hooksPath').strip().endswith('empty-hooks'))

    def test_review_shape(self):
        self.job['kind'] = 'review'
        self.job['in_bounds'] = []
        for mode, code in [('review-clean', 0), ('review-changes', 0), ('review-bad-json', 4)]:
            with self.subTest(mode=mode):
                self.out = self.root / mode
                self.assertEqual(self.run_slot(mode), code, self.detail)
                self.result('done' if code == 0 else 'failed')

    def test_slot_broken(self):
        self.assertEqual(self.run_slot('not-signed-in'), 6, self.detail)
        self.assertFalse((self.out / 'result.json').exists())

    def test_bad_job(self):
        self.job['protocol'] = 2
        self.assertEqual(self.run_slot(), 2, self.detail)
        self.assertFalse((self.out / 'result.json').exists())

    def test_heartbeat(self):
        self.job['limits']['minutes'] = 0.05
        self.assertEqual(self.run_slot('sleep'), 5, self.detail)
        lines = (self.out / 'events.jsonl').read_text().splitlines()
        self.assertGreaterEqual(len(lines), 2)
        for line in lines:
            self.assertEqual(json.loads(line)['phase'], 'agent')

    def test_bundle(self):
        bundle = self.job_dir / 'base.bundle'
        self.git(self.base, 'bundle', 'create', str(bundle), 'HEAD')
        self.job['base'].update(bundle='base.bundle', repo='unavailable')
        self.assertEqual(self.run_slot(), 0, self.detail)
        self.result('done')

    def test_crash(self):
        self.assertEqual(self.run_slot('crash'), 4, self.detail)
        self.assertIn('agent exited 1', self.result('failed')['error'])

    def test_missing_key_command_and_fetch(self):
        for failure in ('key', 'command', 'fetch'):
            with self.subTest(failure=failure):
                self.out = self.root / ('out-' + failure)
                if failure == 'key':
                    self.env['SLOT_KEY'] = str(self.root / 'missing-key')
                else:
                    self.env['SLOT_KEY'] = str(self.key)
                if failure == 'command':
                    self.env['PATH'] = str(self.root / 'empty-path')
                else:
                    self.env['PATH'] = os.environ['PATH']
                if failure == 'fetch':
                    self.job['base']['repo'] = str(self.root / 'missing-repo')
                self.assertEqual(self.run_slot(), 6, self.detail)
                self.assertFalse((self.out / 'result.json').exists())

    def test_existing_output_is_preserved(self):
        self.out.mkdir()
        marker = self.out / 'result.json'
        marker.write_text('previous result')
        self.assertEqual(self.run_slot(), 2, self.detail)
        self.assertEqual(marker.read_text(), 'previous result')

    def test_rework(self):
        self.job['kind'] = 'rework'
        self.job['rework'] = dict(findings=[])
        self.assertEqual(self.run_slot(), 0, self.detail)
        self.result('done')

    def test_build_lock_waits_and_releases(self):
        locks = self.root / 'locks'
        ready = self.root / 'locked'
        # Another interpreter owns the OS lock; the runner must wait for it.
        code = ("import sys,time; from pathlib import Path; "
                "from slot.slot_run import build_lock; "
                "lock=build_lock(Path(sys.argv[1]),1,time.monotonic()+20); "
                "lock.__enter__(); Path(sys.argv[2]).touch(); time.sleep(1.5); lock.__exit__(None,None,None)")
        proc = subprocess.Popen([sys.executable, '-c', code, str(locks), str(ready)], cwd=ROOT.parent)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        deadline = time.monotonic() + 5
        while not ready.exists():
            self.assertIsNone(proc.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        self.env['SLOT_BUILD_SLOTS'] = '1'
        self.job['gates'] = [subprocess.list2cmdline([sys.executable, '-c', 'pass']) if os.name == 'nt'
                             else shlex.join([sys.executable, '-c', 'pass'])]
        before = time.monotonic()
        self.assertEqual(self.run_slot(), 0, self.detail)
        self.assertGreater(time.monotonic() - before, 1)
        proc.wait(timeout=5)
        self.assertEqual(self.result('done')['gates'][0]['exit'], 0)
        with slot_run.build_lock(locks, 1, time.monotonic() + 1):
            pass

    def test_job_and_review_validation(self):
        self.assertFalse(slot_run.review_shape(dict(verdict='clean', findings=[{}], follow_ups=[])))
        for path in ['tests/a.zig', 'foo/test/a', 'a_test.zig', 'a.test.js', '__tests__/a']:
            self.assertTrue(common.is_test_path(path), path)
        self.assertFalse(common.is_test_path('contest/main.zig'))
        for changes in [dict(id='../escape'), dict(limits=dict(minutes=float('nan'), max_changed_lines=1)), dict(spec='a' * 12001)]:
            with self.subTest(changes=changes):
                (self.job_dir / 'job.json').write_text(json.dumps({**self.job, **changes}))
                with self.assertRaises(common.JobError):
                    common.load_job(self.job_dir / 'job.json')


if __name__ == '__main__':
    unittest.main()
