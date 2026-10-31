"""Shared slot protocol parsing, accounting and OpenSSH signatures (stdlib only)."""
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess


class JobError(ValueError):
    pass


# The only repos slot work may land in. gate=True: the repo has no review bridge of its own, so
# publish labels the PR gate:yes and dispatches its review to the work repo.
TARGETS = {
    'fizzyedit/fizzy': dict(branch='main', gate=False),
    'fizzyedit/dvui': dict(branch='zig-0.17', gate=True),
}


def target(job):
    """The allowed target the job names, as dict(repo=<slug>, branch=..., gate=...)."""
    try:
        base = job['base']
        url = re.fullmatch(r'https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git', base['repo'])
        slug = url.group(1) if url else base['repo']
        if slug not in TARGETS:
            raise JobError(f'repo not allowed: {slug}')
        entry = TARGETS[slug]
        branch = base.get('branch', entry['branch'])
        if branch != entry['branch']:
            raise JobError(f'branch not allowed for {slug}: {branch}')
    except (KeyError, TypeError, AttributeError) as exc:
        raise JobError(f'invalid base: {exc}') from exc
    return dict(repo=slug, **entry)


def load_job(path):
    try:
        with Path(path).open('rb') as source:
            raw = source.read(65537)
        if len(raw) > 65536:
            raise JobError('job.json exceeds 64 KiB')
        job = json.loads(raw)
        if type(job['protocol']) is not int or job['protocol'] != 1:
            raise JobError('unsupported protocol')
        if job['kind'] not in ('write', 'review', 'rework'):
            raise JobError('invalid kind')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', job['id']):
            raise JobError('unsafe job id')
        if not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', job['base']['sha']):
            raise JobError('invalid base sha')
        if not isinstance(job['base']['repo'], str):
            raise JobError('invalid base repo')
        for field in ('spec', 'not_in_scope', 'acceptance', 'branch'):
            if not isinstance(job[field], str):
                raise JobError('invalid ' + field)
        if len(job['spec']) > 12000:
            raise JobError('spec exceeds 12000 characters')
        for field in ('gates', 'in_bounds'):
            if not isinstance(job[field], list) or not all(isinstance(s, str) for s in job[field]):
                raise JobError('invalid ' + field)
        minutes = job['limits']['minutes']
        lines = job['limits']['max_changed_lines']
        if type(minutes) not in (int, float) or not math.isfinite(minutes) or not 0 < minutes <= 180:
            raise JobError('invalid minutes')
        if type(lines) is not int or lines < 0:
            raise JobError('invalid max_changed_lines')
        return job
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise JobError(str(exc)) from exc


def manifest(out_dir):
    out = Path(out_dir)
    names = ['job.json', 'result.json']
    if (out / 'change.mbox').exists():
        names.append('change.mbox')
    return ''.join(f'{hashlib.sha256((out / name).read_bytes()).hexdigest()}  {name}\n'
                   for name in sorted(names))


def sign(manifest_path, key):
    path = Path(manifest_path)
    subprocess.run(['ssh-keygen', '-Y', 'sign', '-n', 'fizzy-slot', '-f', str(key), str(path)],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sig = path.parent / 'result.sig'
    Path(str(path) + '.sig').replace(sig)
    return sig


def verify(manifest_path, sig_path, allowed_signers, slot_id):
    with open(manifest_path, 'rb') as source:
        return subprocess.run(['ssh-keygen', '-Y', 'verify', '-f', str(allowed_signers),
                               '-I', slot_id, '-n', 'fizzy-slot', '-s', str(sig_path)],
                              stdin=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0


def is_test_path(path):
    return re.search(r'(^|/)(tests?|__tests__)/|[._-]tests?\.|_test\.|\.test\.',
                     path, re.IGNORECASE) is not None


def count_changed(base_sha, repo_dir):
    raw = subprocess.check_output(['git', 'diff', '--numstat', '-z', '--no-renames',
                                   base_sha, 'HEAD', '--'], cwd=repo_dir)
    counts = dict(files=0, added=0, deleted=0, added_non_test=0, deleted_non_test=0)
    for record in raw.split(b'\0'):
        if not record:
            continue
        added, deleted, path = record.split(b'\t', 2)
        a, d = (0 if n == b'-' else int(n) for n in (added, deleted))
        counts['files'] += 1
        counts['added'] += a
        counts['deleted'] += d
        if not is_test_path(path.decode('utf-8', 'surrogateescape')):
            counts['added_non_test'] += a
            counts['deleted_non_test'] += d
    return counts
