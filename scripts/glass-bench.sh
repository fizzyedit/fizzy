#!/usr/bin/env bash
# Measure fixed glass scenes; JSONL goes to stdout and the shared performance store.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import datetime
import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess
import sys
import tempfile

args = sys.argv[1:]
store = Path(os.environ.get('FIZZY_PERF_STORE',
             str(Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'fizzy/perf')))
self_test = False
gpu = None
while args:
    arg = args.pop(0)
    if arg == '--self-test':
        self_test = True
    elif arg == '--no-store':
        store = None
    elif arg == '--store' and args:
        store = Path(args.pop(0))
    elif not arg.startswith('-') and gpu is None:
        gpu = arg
    else:
        sys.exit('usage: scripts/glass-bench.sh <gpu-name> [--store DIR|--no-store] | --self-test')
if self_test:
    gpu, store = 'fixture-over', None
if gpu is None:
    sys.exit('glass-bench: a GPU name is required')


def number(text, field):
    match = re.search(r'\.' + field + r'\s*=\s*([0-9_]+)', text)
    if not match:
        raise ValueError('missing verdict field: ' + field)
    return int(match[1].replace('_', ''))


def section(text, name):
    match = re.search(r'\.' + name + r'\s*=\s*\.\{', text)
    if not match:
        raise ValueError('missing verdict section: ' + name)
    start = match.end()
    depth = 1
    for end in range(start, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if depth == 0:
            return text[start:end]
    raise ValueError('unclosed verdict section: ' + name)


def verdict(path):
    text = path.read_text()
    at_end = section(text, 'at_end')
    frames = section(at_end, 'frame_times')
    peak = section(at_end, 'peak_frame')
    return dict(frame_p50_us=number(frames, 'p50_us'),
                frame_p99_us=number(frames, 'p99_us'),
                work_p50_us=number(section(text, 'work_times'), 'p50_us'),
                target_switches_peak=number(peak, 'target_switches'),
                program_px_peak=number(peak, 'program_px'))


budget = {}
for entry in re.findall(r'\.\{([^{}]+)\}', Path('tests/tapes/glass-bench.budget.zon').read_text()):
    name = re.search(r'\.gpu\s*=\s*"([^"]+)"', entry)
    if name and name[1] == gpu:
        budget = {key: number(entry, key) for key in ('max_pane_us', 'max_list_work_us')
                  if re.search(r'\.' + key + r'\s*=', entry)}

now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
commit = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], text=True).strip()
try:
    kib = number(Path('/proc/meminfo').read_text().replace('MemTotal:', '.mem ='), 'mem')
    memory = str(kib // 1048576) + 'GiB'
except (OSError, ValueError):
    memory = 'unknown'
machine = f'{socket.gethostname()}/{os.cpu_count()}cpu/{memory}'


def emit(arm, metric, value):
    line = json.dumps(dict(date=now, commit=commit, machine=machine,
                          os=platform.system() + ' ' + platform.release(),
                          scenario='glass_bench_' + arm, metric=metric,
                          value=round(value, 3), unit='count' if metric.endswith('_peak') else 'us',
                          gpu=gpu), separators=(',', ':'))
    print(line, flush=True)
    if store is not None:
        store.mkdir(parents=True, exist_ok=True)
        with (store / (now[:7] + '.jsonl')).open('a') as output:
            output.write(line + '\n')


failed = False
arms = ['12x350x200'] if self_test else [
    '1x350x200', '4x350x200', '12x350x200', '4x700x400', 'list:30', 'list:100', 'list:200']
with tempfile.TemporaryDirectory(prefix='glass-bench-') as tmp:
    for arm in arms:
        samples = {}
        for repeat in ([1] if arm.startswith('list:') else [1, 9]):
            if self_test:
                path = Path(f'tests/fixtures/glass-bench/{repeat}.zon')
            else:
                path = Path(tmp) / f'{arm}-{repeat}.zon'
                env = dict(os.environ, FIZZY_VSYNC='0', FIZZY_GLASS='liquid',
                           FIZZY_GLASS_BENCH=arm, FIZZY_GLASS_REPEAT=str(repeat),
                           FIZZY_VERDICT=str(path), FIZZY_DEMO='tests/tapes/glass-bench.zon')
                # A caller's expectation file must not apply another scene's budget.
                env.pop('FIZZY_VERDICT_EXPECT', None)
                subprocess.run([os.environ.get('FIZZY_BIN', 'fizzy'), '--profile',
                                str(Path(tmp) / f'profile-{arm}-{repeat}')], env=env,
                               stdout=sys.stderr, check=True, timeout=120)
            samples[repeat] = verdict(path)
        base = samples[1]
        for metric, value in base.items():
            emit(arm, metric, value)
        if arm.startswith('list:'):
            limit = budget.get('max_list_work_us')
            failed |= limit is not None and base['work_p50_us'] > limit
        else:
            pane_us = (samples[9]['frame_p50_us'] - base['frame_p50_us']) / (8 * int(arm.split('x')[0]))
            emit(arm, 'glass_pane_us', pane_us)
            if arm == '12x350x200':
                limit = budget.get('max_pane_us')
                failed |= limit is not None and pane_us > limit
if failed:
    print('glass-bench: GPU budget exceeded for ' + gpu, file=sys.stderr)
sys.exit(1 if failed else 0)
PY
