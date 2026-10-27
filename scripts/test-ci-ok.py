#!/usr/bin/env python3
"""Run the actual ci-ok shell against selected and excluded job outcomes.

Run with python3 scripts/test-ci-ok.py; no YAML package or hosted runner is needed.
These checks cover the gate shell, not GitHub's event scheduling or cache behaviour.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CiOkTests(unittest.TestCase):
    def test_changes_selects_work_only_when_ready(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml').read_text()
        self.assertIn('types: [opened, synchronize, reopened, ready_for_review]', workflow)
        self.assertIn("if: always() && !(github.event_name == 'pull_request' && github.event.pull_request.draft)", workflow)
        changes = workflow.split('\n  changes:\n', 1)[1].split('\n  format:\n', 1)[0]
        shell = changes.split('        run: |\n', 1)[1].split('\n\n', 1)[0]
        shell = '\n'.join(line[10:] for line in shell.splitlines())
        cases = [
            ('draft', 'pull_request', 'true', '', 'false', 'false'),
            ('ready code', 'pull_request', 'false', 'src/Entry.zig', 'true', 'false'),
            ('ready workflow', 'pull_request', 'false', '.github/workflows/ci.yml', 'true', 'true'),
            ('ready docs', 'pull_request', 'false', 'README.md', 'false', 'false'),
            ('main', 'push', '', 'src/Entry.zig', 'true', 'false'),
            ('queue', 'merge_group', '', 'backend/build.zig', 'true', 'true'),
            ('manual', 'workflow_dispatch', '', '', 'true', 'true'),
        ]
        # A draft must exit before invoking git. Other cases provide a successful base lookup
        # and the changed paths, without touching refs or depending on checkout history.
        mock_git = "git() { [ \"$DRAFT\" != true ] || exit 99; if [ \"$1\" = diff ]; then printf '%s\\n' \"$FILES\"; fi; }\n"
        for name, event, draft, files, code, sdl in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'output'
                env = dict(os.environ, EVENT=event, DRAFT=draft, FILES=files,
                           PUSH_BEFORE='main-base', QUEUE_BASE='queue-base',
                           GITHUB_OUTPUT=str(output))
                result = subprocess.run(['bash', '-c', mock_git + shell], env=env,
                                        capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(output.read_text(), f'code={code}\nsdl={sdl}\n')

    def test_selected_jobs_must_succeed(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml').read_text()
        gate = workflow.split('\n  ci-ok:\n', 1)[1]
        shell = gate.split('        run: |\n', 1)[1]
        shell = '\n'.join(line[10:] for line in shell.splitlines())
        cases = [
            ('selected success', 'success', 'true', 'false', 'success ' * 6, 'skipped', True),
            ('docs only', 'success', 'false', 'false', 'skipped ' * 6, 'skipped', True),
            ('SDL success', 'success', 'true', 'true', 'success ' * 6, 'success', True),
            ('unexpected skip', 'success', 'true', 'false', 'success skipped', 'skipped', False),
            ('failure', 'success', 'true', 'false', 'success failure', 'skipped', False),
            ('cancellation', 'success', 'true', 'false', 'cancelled', 'skipped', False),
            ('filter failure', 'failure', '', '', 'skipped', 'skipped', False),
            ('missing SDL success', 'success', 'true', 'true', 'success ' * 6, 'skipped', False),
        ]
        for name, changes, code, sdl, results, sdl_result, passed in cases:
            with self.subTest(name=name):
                env = dict(os.environ, CHANGES=changes, CODE=code, SDL=sdl,
                           CODE_RESULTS=results, SDL_RESULT=sdl_result,
                           RESULTS=f"{changes} {results} {sdl_result}")
                result = subprocess.run(['bash', '-c', shell], env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, passed, result.stdout.decode())


if __name__ == '__main__':
    unittest.main()
