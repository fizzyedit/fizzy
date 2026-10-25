#!/usr/bin/env python3
"""Exercise measurement failure paths and JSON records without opening a window."""

import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('hello_numbers', Path(__file__).with_name('hello-numbers.py'))
hello = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hello)


class HelloNumbersTests(unittest.TestCase):
    def test_repin_preserves_neighbor_and_rejects_changed_anchor(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            zon = work / 'build.zig.zon'
            zon.write_text('.{ .dependencies = .{\n .fizzy = .{\n .url = "url",\n .hash = "hash",\n },\n .other = .{ .path = "other" },\n} }')
            hello.pin(zon, 'fizzy', work / 'sdk')
            self.assertIn('.fizzy = .{ .path = "sdk" },', zon.read_text())
            self.assertIn('.other = .{ .path = "other" }', zon.read_text())
            hello.pin(zon, 'fizzy', work / 'new-sdk')
            self.assertIn('.fizzy = .{ .path = "new-sdk" },', zon.read_text())
            self.assertIn('.other = .{ .path = "other" }', zon.read_text())
            with self.assertRaises(ValueError):
                hello.replace_once(zon, 'missing anchor', 'replacement')

    @patch.object(hello, "rss_bytes", return_value=1024)
    def test_first_frame_and_rss(self, _rss):
        with tempfile.TemporaryDirectory() as temporary:
            command = [sys.executable, '-u', '-c',
                       'import time; print("info: startup: first frame 12.375 ms after main"); time.sleep(10)']
            record = hello.measure(command, Path(temporary) / 'log', os.environ, idle_seconds=2)
            self.assertEqual(record['first_frame_ms'], 12.375)
            self.assertGreater(record['idle_rss_bytes'], 0)
            self.assertGreaterEqual(record['rss_sample_after_s'], 2)
            output = Path(temporary) / 'numbers.jsonl'
            with contextlib.redirect_stdout(io.StringIO()):
                hello.emit(record, output)
                hello.emit(record, output)
            self.assertEqual([json.loads(line) for line in output.read_text().splitlines()], [record, record])

    def test_missing_marker_and_early_exit_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            for program in ('import time; time.sleep(10)', 'raise SystemExit(7)'):
                with self.assertRaises(RuntimeError):
                    hello.measure([sys.executable, '-c', program], Path(temporary) / 'log',
                                  os.environ, idle_seconds=2)

    @patch.object(hello, "rss_bytes", return_value=1024)
    def test_peer_marker_and_process_tree(self, _rss):
        with tempfile.TemporaryDirectory() as temporary:
            program = ('import subprocess,sys,time; '
                       'subprocess.Popen([sys.executable,"-c","import time; time.sleep(10)"]); '
                       'print("HELLO_FIRST_FRAME", flush=True); time.sleep(10)')
            record = hello.measure([sys.executable, '-c', program], Path(temporary) / 'log',
                                   os.environ, peer=True, idle_seconds=2)
            self.assertGreater(record['first_frame_ms'], 0)
            self.assertEqual(record['rss_scope'], 'process_tree')

    def test_rss_includes_descendants_and_rejects_dead_root(self):
        rows = '10 1 100\n11 10 200\n12 11 300\n20 1 999\n'
        with patch.object(hello.subprocess, 'check_output', return_value=rows):
            self.assertEqual(hello.rss_bytes(10), 600 * 1024)
            with self.assertRaises(RuntimeError):
                hello.rss_bytes(99)

    def test_missing_or_ambiguous_installer_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            with self.assertRaises(ValueError):
                hello.one_file(work, '.dmg')
            (work / 'a.dmg').touch()
            self.assertEqual(hello.one_file(work, '.dmg').name, 'a.dmg')
            (work / 'b.dmg').touch()
            with self.assertRaises(ValueError):
                hello.one_file(work, '.dmg')


if __name__ == '__main__':
    unittest.main()
