#!/usr/bin/env python3
"""The frame export appends report causes and timings to the one perf store."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('perf-frame-record')
REPORT = '''.{
    .frames = .{
        .{ .work_ns = 1234567, .cause = .{ .press = true, .key = true, } },
        .{ .work_ns = 9000, .cause = .{ .refresh = true, } },
    },
}
'''


class FrameStoreTest(unittest.TestCase):
    def test_appends_causes_and_work_to_monthly_store(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory) / 'store'
            command = [str(SCRIPT), '--commit', 'measured', '--machine', 'test/4cpu/8GiB',
                       '--scenario', 'tour', '--store', str(store)]
            env = dict(os.environ, FIZZY_PERF_STORE=str(Path(directory) / 'unused'))
            outputs = [subprocess.run(command, input=REPORT, text=True, capture_output=True,
                                      check=True, env=env).stdout for _ in range(2)]
            month = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m')
            self.assertEqual((store / (month + '.jsonl')).read_text(), ''.join(outputs))
            rows = [json.loads(line) for line in outputs[0].splitlines()]
            self.assertEqual(rows[0]['causes'], ['press', 'key'])
            self.assertEqual(rows[1]['causes'], ['refresh'])
            self.assertEqual(rows[0]['value'], 1.234567)
            self.assertEqual(rows[0]['unit'], 'ms')
            self.assertEqual(rows[0]['commit'], 'measured')
            self.assertFalse((Path(directory) / 'unused').exists())
            bad = subprocess.run(command, input='.{ .frames = 0 }', text=True,
                                 capture_output=True, env=env)
            self.assertNotEqual(bad.returncode, 0)
            self.assertEqual((store / (month + '.jsonl')).read_text(), ''.join(outputs))


if __name__ == '__main__':
    unittest.main()
