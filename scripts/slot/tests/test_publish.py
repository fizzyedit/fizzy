"""Verify observable publishing effects and repeat-run behavior through fake gh."""
import json
from unittest.mock import patch

from slot.publish import publish
from slot.tests.test_validate import Artifacts


class PublishTests(Artifacts):
    def publish_twice(self, accepted=True):
        self.sign()
        (self.root / 'verdict.json').write_text(json.dumps(dict(accept=accepted, reasons=['bad'], risky=False)))
        with patch('slot.publish.push') as push:
            publish(self.job_dir, self.out)
            publish(self.job_dir, self.out)
        return json.loads(self.state_path.read_text()), push

    def test_write_opens_pr_once(self):
        state, push = self.publish_twice()
        self.assertEqual(len(state['prs']), 1)
        self.assertEqual(push.call_count, 1)
        self.assertIn('Part of fizzyedit/work#722', state['prs'][0]['body'])

    def test_write_labels_author_kind_instead_of_issue_work_kind(self):
        state, _ = self.publish_twice()
        create = next(call for call in state['calls'] if call[:2] == ['pr', 'create'])
        labels = [create[index + 1] for index, arg in enumerate(create) if arg == '--label']
        self.assertCountEqual(labels, ['area:scripts', 'kind:codex'])

    def test_review_changes_dispatches_rework(self):
        self.review()
        state, push = self.publish_twice()
        self.assertEqual(len(state['dispatches']), 1)
        self.assertEqual(state['dispatches'][0]['client_payload']['round'], 2)
        push.assert_not_called()

    def test_review_round3_stuck(self):
        self.review()
        self.job['attempt'] = 2
        self.state['objects']['repos/fizzyedit/fizzy/issues/9'] = dict(labels=[])
        self.state_path.write_text(json.dumps(self.state))
        state, _ = self.publish_twice()
        self.assertNotIn('dispatches', state)
        self.assertIn(dict(name='stuck'), state['objects']['repos/fizzyedit/fizzy/issues/9']['labels'])

    def test_review_clean_sets_status_and_auto_merge(self):
        self.review()
        self.result['review'].update(verdict='clean', findings=[])
        state, _ = self.publish_twice()
        statuses = state['statuses']['repos/fizzyedit/fizzy/statuses/' + self.head]
        self.assertEqual(len(statuses), 1)
        self.assertEqual(statuses[0]['state'], 'success')
        self.assertTrue(state['objects']['repos/fizzyedit/fizzy/pulls/9']['auto_merge'])

    def test_declined_posts_approach(self):
        self.result.update(status='declined', decline='Need an answer')
        state, push = self.publish_twice()
        comments = state['comments']['repos/fizzyedit/work/issues/722/comments']
        self.assertEqual(len(comments), 1)
        self.assertTrue(comments[0]['body'].startswith('APPROACH:'))
        self.assertEqual(state['objects']['repos/fizzyedit/work/issues/722']['labels'], [dict(name='arch:needed')])
        push.assert_not_called()

    def test_refused_labels_stuck_and_pushes_nothing(self):
        state, push = self.publish_twice(accepted=False)
        self.assertIn(dict(name='stuck'), state['objects']['repos/fizzyedit/work/issues/722']['labels'])
        push.assert_not_called()

    def test_push_retry_after_interrupted_pr_creation(self):
        import os
        import subprocess
        from slot.publish import push
        self.sign()
        remote = self.root / 'remote.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        real_run = subprocess.run
        pushes = []
        def local_git(args, **kwargs):
            args = list(args)
            for index, arg in enumerate(args):
                if arg.startswith('https://x-access-token:'):
                    args[index] = str(remote)
            if 'push' in args:
                pushes.append(args)
            return real_run(args, **kwargs)
        with patch.dict(os.environ, GH_TOKEN='test-token'), patch('subprocess.run', side_effect=local_git):
            push(self.job, self.out, self.result, self.job['branch'])
            push(self.job, self.out, self.result, self.job['branch'])
        self.assertEqual(len(pushes), 1)

    def test_missing_verdict_refuses_before_any_github_call(self):
        self.sign()
        with self.assertRaises(FileNotFoundError):
            publish(self.job_dir, self.out)
        self.assertNotIn('calls', json.loads(self.state_path.read_text()))

    def test_failed_attempt_two_marks_stuck_once(self):
        self.result.update(status='failed', error='gate red')
        self.job['attempt'] = 2
        state, push = self.publish_twice()
        labels = state['objects']['repos/fizzyedit/work/issues/722']['labels']
        self.assertIn(dict(name='attempt:2'), labels)
        self.assertEqual(labels.count(dict(name='stuck')), 1)
        push.assert_not_called()

    def test_rework_pushes_once_and_labels_round(self):
        self.job.update(kind='rework', base=dict(repo=str(self.base), sha=self.head),
                        rework=dict(pr=9, round=1))
        self.state['objects']['repos/fizzyedit/fizzy/issues/9'] = dict(labels=[])
        self.state_path.write_text(json.dumps(self.state))
        state, push = self.publish_twice()
        self.assertEqual(push.call_count, 1)
        self.assertIn(dict(name='rework:1'), state['objects']['repos/fizzyedit/fizzy/issues/9']['labels'])

    def test_followups_and_dispatch_comments_end_with_job_marker(self):
        self.review()
        self.result['review']['follow_ups'] = [dict(id='F2', severity='nit', file='a.txt',
                                                   line=1, added=True, text='suggestion')]
        state, _ = self.publish_twice()
        marker = f'<!-- slot-job: {self.job["id"]} -->'
        for comments in state['comments'].values():
            for comment in comments:
                self.assertTrue(comment['body'].endswith(marker), comment)

    def test_github_paginated_arrays_are_combined(self):
        from slot.validate import gh
        with patch('slot.validate.run', return_value=b'[{"body":"one"}]\n[{"body":"two"}]\n'):
            self.assertEqual(gh('api', '--paginate', 'repos/a/b/issues/1/comments'),
                             [dict(body='one'), dict(body='two')])
