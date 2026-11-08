"""Checkout cleanup: the result survives a failed rmtree, and the job's processes die first."""
import errno
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from slot import slot_run  # noqa: E402
from slot.tests import test_slot_run  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


class CleanupRunTests(unittest.TestCase):
    setUp = test_slot_run.SlotRunTests.setUp
    git = test_slot_run.SlotRunTests.git
    result = test_slot_run.SlotRunTests.result

    def work(self):
        return (self.root / 'home' / 'work' / self.job['id']).resolve()

    def main(self):
        (self.job_dir / 'job.json').write_text(json.dumps(self.job))
        agents = self.root / 'agents.json'
        agents.write_text(json.dumps({self.env['SLOT_KIND']: dict(
            cmd=[sys.executable, str(ROOT / 'fakes/agent.py'), 'write-ok'],
            prompt='stdin', model_flag='--model', auth_exit=[64])}))
        self.env['SLOT_AGENTS'] = str(agents)
        with mock.patch.dict(os.environ, self.env, clear=True):
            return slot_run.main([str(self.job_dir), '--out', str(self.out)])

    def test_rmtree_fails_once_with_errno_39_then_retry_removes_tree(self):
        real = shutil.rmtree
        seen = []

        def flaky(path, *args, **kwargs):
            if Path(path) == self.work() and not seen:
                seen.append((self.out / 'result.json').is_file())
                raise OSError(errno.ENOTEMPTY, os.strerror(errno.ENOTEMPTY), str(Path(path) / '.git' / 'objects'))
            return real(path, *args, **kwargs)

        with mock.patch.object(slot_run.shutil, 'rmtree', side_effect=flaky):
            self.assertEqual(self.main(), 0)
        self.assertEqual(seen, [True], 'result.json must exist before the first rmtree')
        self.result('done')
        self.assertTrue((self.out / 'change.mbox').is_file())
        self.assertFalse(self.work().exists())

    def test_late_file_at_rmdir_goes_through_shutil_handler_and_retry(self):
        # The race itself: a file appears just before the checkout's own os.rmdir, so the real
        # shutil error handler sees ENOTEMPTY and the retry must still be able to list the tree.
        real = os.rmdir
        seen = []

        def racing(path, *args, **kwargs):
            if os.path.basename(os.fsdecode(path)) == self.job['id'] and not seen:
                seen.append((self.out / 'result.json').is_file())
                (self.work() / 'late.txt').write_text('late')
            return real(path, *args, **kwargs)

        with mock.patch.object(slot_run.os, 'rmdir', side_effect=racing), \
                mock.patch('sys.stderr') as stderr:
            self.assertEqual(self.main(), 0)
        self.assertEqual(seen, [True], 'result.json must exist before the first rmdir of the checkout')
        logged = ''.join(c.args[0] for c in stderr.write.call_args_list)
        self.assertIn('attempt 1/5', logged)
        self.assertIn('Directory not empty', logged)
        self.result('done')
        self.assertTrue((self.out / 'change.mbox').is_file())
        self.assertFalse(self.work().exists())

    @unittest.skipIf(not shutil.which('pgrep'), 'needs pgrep')
    def test_pgrep_failure_keeps_the_result_and_still_removes_tree(self):
        real = subprocess.run

        def run(args, *rest, **kwargs):
            if isinstance(args, list) and args[0] == 'pgrep':
                raise OSError(errno.EAGAIN, os.strerror(errno.EAGAIN))
            return real(args, *rest, **kwargs)

        with mock.patch.object(slot_run.subprocess, 'run', side_effect=run), \
                mock.patch('sys.stderr') as stderr:
            self.assertEqual(self.main(), 0)
        logged = ''.join(c.args[0] for c in stderr.write.call_args_list)
        self.assertIn('could not list processes', logged)
        self.result('done')
        self.assertTrue((self.out / 'change.mbox').is_file())
        self.assertFalse(self.work().exists())

    def test_cleanup_error_never_replaces_a_done_result(self):
        with mock.patch.object(slot_run, 'remove_checkout', side_effect=TypeError('boom')), \
                mock.patch('sys.stderr') as stderr:
            self.assertEqual(self.main(), 0)
        logged = ''.join(c.args[0] for c in stderr.write.call_args_list)
        self.assertIn('cleanup: failed', logged)
        self.result('done')
        self.assertTrue((self.out / 'change.mbox').is_file())
        shutil.rmtree(self.work())

    @unittest.skipIf(os.name == 'nt', 'process groups are POSIX')
    def test_background_gate_process_is_killed_before_rmtree(self):
        marker = 'slot-cleanup-' + str(os.getpid())
        # The marker is the loop's $0, so pgrep -f finds it.
        self.job['gates'] = [f'sh -c "while :; do date > busy.\\$\\$; sleep 0.05; done" {marker} >/dev/null 2>&1 &']
        self.assertEqual(self.main(), 0)
        self.result('done')
        self.assertFalse(self.work().exists())
        time.sleep(0.2)
        left = subprocess.run(['pgrep', '-f', marker], capture_output=True, text=True, check=False).stdout
        self.assertEqual(left, '', 'the gate left its background loop running')


class RemoveCheckoutTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name).resolve() / 'work'
        (self.work / 'sub').mkdir(parents=True)

    def test_falls_back_to_ignore_errors_and_never_raises(self):
        calls = []

        def rmtree(path, ignore_errors=False):
            calls.append(ignore_errors)
            if not ignore_errors:
                raise OSError(errno.ENOTEMPTY, 'Directory not empty', str(path))

        with mock.patch.object(slot_run, 'rmtree', side_effect=rmtree), \
                mock.patch('sys.stderr') as stderr:
            slot_run.remove_checkout(self.work, [], attempts=3, pause=0)
        self.assertEqual(calls, [False, False, False, True])
        logged = ''.join(c.args[0] for c in stderr.write.call_args_list)
        self.assertIn('attempt 3/3', logged)
        self.assertIn('left behind', logged)

    @unittest.skipIf(os.name == 'nt', 'permission bits are POSIX')
    def test_rmtree_keeps_directory_mode_on_enotempty(self):
        real = os.rmdir
        mode = stat.S_IMODE(self.work.stat().st_mode)

        def racing(path, *args, **kwargs):
            if os.fsdecode(path) in (str(self.work), self.work.name):
                (self.work / 'late.txt').write_text('late')
            return real(path, *args, **kwargs)

        with mock.patch.object(slot_run.os, 'rmdir', side_effect=racing):
            with self.assertRaises(OSError) as raised:
                slot_run.rmtree(self.work)
        self.assertEqual(raised.exception.errno, errno.ENOTEMPTY)
        self.assertEqual(stat.S_IMODE(self.work.stat().st_mode), mode)
        slot_run.rmtree(self.work)
        self.assertFalse(self.work.exists())

    @unittest.skipIf(not Path('/proc').is_dir(), 'reads /proc')
    def test_still_running_names_a_process_in_the_workspace(self):
        proc = subprocess.Popen(['sleep', '30'], cwd=self.work / 'sub')
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)
        self.assertTrue(any(line.startswith(f'{proc.pid} sleep') for line in slot_run.still_running(self.work)))


if __name__ == '__main__':
    unittest.main()
