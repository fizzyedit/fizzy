"""Exercise signed artifacts against temporary git repositories and fake GitHub."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from slot.validate import validate, matches

FAKE = Path(__file__).resolve().parents[1] / 'fakes/gh.py'


class Artifacts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base, self.out, self.job_dir = (self.root / p for p in ('base', 'out', 'job'))
        for p in (self.base, self.out, self.job_dir):
            p.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'fizzy linux-codex-2')
        self.git('config', 'user.email', 'slot+linux-codex-2@fizzy.invalid')
        (self.base / 'a.txt').write_text('before\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.sha = self.git('rev-parse', 'HEAD').strip()
        (self.base / 'a.txt').write_text('after\n')
        self.git('commit', '-qam', 'change', '-s')
        self.head = self.git('rev-parse', 'HEAD').strip()
        (self.out / 'change.mbox').write_text(self.git('format-patch', '--stdout', self.sha + '..HEAD'))
        now = dt.datetime.now(dt.timezone.utc)
        self.job = dict(protocol=1, id='work-722-w1-123', kind='write',
                        issue=dict(repo='fizzyedit/work', number=722, area='scripts', labels=['kind:test-provable']),
                        base=dict(repo=str(self.base), sha=self.sha), branch='scripts/example',
                        in_bounds=['a.txt'], limits=dict(max_changed_lines=10),
                        lease=dict(ttl_minutes=110), attempt=1, for_review=None, rework=None)
        self.result = dict(protocol=1, job_id=self.job['id'], slot_id='linux-codex-2', agent_kind='codex',
                           status='done', started_at=now.isoformat(), finished_at=now.isoformat(),
                           title='scripts: example', pr_body='Example body', report='report', review=None)
        self.key, self.signers = self.root / 'key', self.root / 'signers'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)
        self.signers.write_text('linux-codex-2 namespaces="fizzy-slot" ' + self.key.with_suffix('.pub').read_text())
        self.state_path = self.root / 'github.json'
        self.state = dict(objects={'repos/fizzyedit/work/issues/722': dict(state='open', labels=[dict(name='ready')]),
                                  'repos/fizzyedit/fizzy/pulls/9': dict(state='open', head=dict(sha=self.head, ref='scripts/example'),
                                                                     base=dict(sha=self.sha))},
                          threads=[dict(number=722, title='PR #9: example')])
        self.state_path.write_text(json.dumps(self.state))
        env = patch.dict(os.environ, SLOT_GH=str(FAKE), SLOT_GH_STATE=str(self.state_path), GH_TOKEN='fake-token')
        env.start()
        self.addCleanup(env.stop)

    def git(self, *args):
        p = subprocess.run(['git', *args], cwd=self.base, capture_output=True, check=True)
        return p.stdout.decode()

    def sign(self):
        (self.job_dir / 'job.json').write_text(json.dumps(self.job))
        (self.out / 'result.json').write_text(json.dumps(self.result))
        files = {'job.json': self.job_dir / 'job.json', 'result.json': self.out / 'result.json'}
        if self.job['kind'] != 'review' and self.result['status'] == 'done':
            files['change.mbox'] = self.out / 'change.mbox'
        (self.out / 'manifest.txt').write_text(''.join(
            hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + name + '\n' for name, p in sorted(files.items())))
        sig = self.out / 'manifest.txt.sig'
        sig.unlink(missing_ok=True)
        subprocess.run(['ssh-keygen', '-Y', 'sign', '-n', 'fizzy-slot', '-f', str(self.key),
                        str(self.out / 'manifest.txt')], capture_output=True, check=True)
        sig.replace(self.out / 'result.sig')
        return hashlib.sha256(files['job.json'].read_bytes()).hexdigest()

    def verdict(self):
        return validate(self.job_dir, self.out, self.base, self.sign(), self.signers)

    def review(self):
        self.job.update(kind='review', base=dict(repo=str(self.base), sha=self.head), in_bounds=[],
                        for_review=dict(pr=9, head_sha=self.head, author_kind='agy', must_fix=None))
        self.result['review'] = dict(verdict='changes', findings=[dict(id='F1', severity='major',
                                            file='a.txt', line=1, added=True, text='problem')], follow_ups=[])


class ValidateTests(Artifacts):
    def test_accepts_good_write(self):
        verdict = self.verdict()
        self.assertTrue(verdict['accept'], verdict)
        self.assertEqual(verdict['changed'], dict(files=1, added=1, deleted=1))

    def test_refuses_out_of_bounds_and_lists_every_reason(self):
        self.job['in_bounds'] = ['other.txt']
        self.job['limits']['max_changed_lines'] = 0
        digest = self.sign()
        (self.out / 'result.sig').write_text('bad signature')
        verdict = validate(self.job_dir, self.out, self.base, digest, self.signers)
        reasons = '\n'.join(verdict['reasons'])
        for text in ('out of bounds', 'too big', 'signature'):
            self.assertIn(text, reasons)

    def test_refuses_tampered_result(self):
        digest = self.sign()
        (self.out / 'result.json').write_text(json.dumps(dict(self.result, title='tampered')))
        self.assertIn('manifest hash mismatch', str(validate(self.job_dir, self.out, self.base, digest, self.signers)))

    def test_refuses_wrong_job_digest(self):
        self.sign()
        self.assertFalse(validate(self.job_dir, self.out, self.base, '0' * 64, self.signers)['accept'])

    def test_refuses_expired_lease(self):
        self.result['finished_at'] = '2099-01-01T00:00:00Z'
        self.assertIn('expired lease', self.verdict()['reasons'])

    def test_refuses_mbox_not_applying(self):
        (self.out / 'change.mbox').write_text('broken')
        self.assertFalse(self.verdict()['accept'])

    def test_refuses_foreign_author(self):
        self.git('commit', '--amend', '--author', 'outsider <other@example.invalid>', '--no-edit')
        (self.out / 'change.mbox').write_text(self.git('format-patch', '--stdout', self.sha + '..HEAD'))
        self.assertIn('foreign author', str(self.verdict()))

    def test_risky_in_bounds_accepted_and_marked(self):
        (self.base / 'AGENTS.md').write_text('rules\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'rules', '-s')
        self.job['in_bounds'].append('AGENTS.md')
        (self.out / 'change.mbox').write_text(self.git('format-patch', '--stdout', self.sha + '..HEAD'))
        verdict = self.verdict()
        self.assertTrue(verdict['accept'], verdict)
        self.assertTrue(verdict['risky'])

    def test_review_same_kind_refused(self):
        self.review()
        self.job['for_review']['author_kind'] = 'codex'
        self.assertIn('review same kind as author', self.verdict()['reasons'])

    def test_review_line_not_in_diff_refused(self):
        self.review()
        self.result['review']['findings'][0]['line'] = 2
        self.assertFalse(self.verdict()['accept'])

    def test_review_nit_as_finding_refused(self):
        self.review()
        self.result['review']['findings'][0]['severity'] = 'nit'
        self.assertIn('invalid finding/follow-up split', str(self.verdict()))

    def test_rereview_outside_must_fix_refused(self):
        self.review()
        self.job['for_review']['must_fix'] = ['F2']
        self.assertIn('re-review outside must_fix', str(self.verdict()))

    def test_accepts_valid_review(self):
        self.review()
        self.assertTrue(self.verdict()['accept'])

    def test_globs_respect_directory_segments(self):
        self.assertFalse(matches('app/a/b.zig', 'app/*.zig'))
        self.assertTrue(matches('app/a/b.zig', 'app/**/*.zig'))
        self.assertTrue(matches('app/b.zig', 'app/**/*.zig'))

    def test_validation_does_not_change_base_checkout(self):
        before = self.git('rev-parse', 'HEAD')
        self.assertTrue(self.verdict()['accept'])
        self.assertEqual(self.git('rev-parse', 'HEAD'), before)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_pr_body_checker_comes_from_base(self):
        scripts = self.base / 'scripts'
        scripts.mkdir()
        checker = scripts / 'check-pr-body'
        checker.write_text('#!/bin/sh\ngrep -q required-heading "$1"\n')
        checker.chmod(0o755)
        self.git('add', '.')
        self.git('commit', '-qm', 'checker', '-s')
        self.job['base']['sha'] = self.git('rev-parse', 'HEAD').strip()
        checker.write_text('#!/bin/sh\nexit 0\n')
        self.git('commit', '-qam', 'bypass checker', '-s')
        self.job['in_bounds'] = ['scripts/check-pr-body']
        (self.out / 'change.mbox').write_text(self.git('format-patch', '--stdout', self.job['base']['sha'] + '..HEAD'))
        self.assertIn('check-pr-body', str(self.verdict()['reasons']))
        self.result['pr_body'] = 'required-heading'
        self.assertTrue(self.verdict()['accept'])
