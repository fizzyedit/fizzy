#!/usr/bin/env python3
"""Deterministic offline agent used by the slot protocol tests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

mode = sys.argv[1]
prompt = sys.stdin.read()
out = Path(prompt.split('Output directory: ', 1)[1].splitlines()[0]) if 'Output directory: ' in prompt else None
if mode == 'not-signed-in':
    sys.exit(64)
if mode == 'crash':
    sys.exit(1)
if mode == 'sleep':
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(3600)'])
    (out / 'pids.json').write_text(json.dumps([os.getpid(), child.pid]))
    while True:
        time.sleep(60)
if mode == 'decline':
    (out / 'decline.md').write_text('Missing acceptance; clarify it before editing.')
elif mode.startswith('review-'):
    finding = dict(id='F1', severity='major', file='hello.txt', line=1, added=True, text='Fix this.')
    value = dict(verdict='changes' if mode == 'review-changes' else 'clean',
                 findings=[finding] if mode == 'review-changes' else [], follow_ups=[])
    Path(prompt.split('Review path: ', 1)[1].splitlines()[0]).write_text('bad json' if mode == 'review-bad-json' else json.dumps(value))
elif mode != 'no-change':
    name = 'outside.txt' if mode == 'write-oob' else 'hello.txt'
    Path(name).write_text('hello from agent\n' * (600 if mode == 'write-huge' else 1))
    (out / 'pr-body.md').write_text('A small useful change.')
    (out / 'report.md').write_text(json.dumps(dict(os.environ)) if mode == 'env-dump' else 'Done.')
