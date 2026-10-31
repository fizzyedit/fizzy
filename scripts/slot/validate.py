"""Validate signed slot artifacts using only tools from the trusted checkout."""
import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from slot.common import JobError, target


def run(*args, cwd=None, data=None):
    p = subprocess.run(args, cwd=cwd, input=data, capture_output=True)
    if p.returncode:
        raise ValueError(f'{args[0]} failed: {p.stderr.decode(errors="replace")[:500]}')
    return p.stdout


def gh(*args):
    output = run(os.environ.get('SLOT_GH', 'gh'), *args)
    text = output.decode().strip()
    if '--paginate' in args:
        pages, decoder = [], json.JSONDecoder()
        while text:
            page, end = decoder.raw_decode(text)
            if not isinstance(page, list):
                raise ValueError('expected GitHub array page')
            pages.extend(page)
            text = text[end:].lstrip()
        return pages
    try:
        return json.loads(text or 'null')
    except json.JSONDecodeError:
        return text


def matches(path, pattern):
    parts, globs = path.split('/'), pattern.split('/')
    def match(p, g):
        if not g:
            return not p
        if g[0] == '**':
            return match(p, g[1:]) or bool(p) and match(p[1:], g)
        return bool(p) and fnmatch.fnmatchcase(p[0], g[0]) and match(p[1:], g[1:])
    return match(parts, globs)


def test_path(path):
    return any(x in ('test', 'tests', 'fixtures') for x in path.split('/')) or bool(
        re.search(r'(^|/)(test[-_].*|.*_test)\.(py|zig)$', path))


def patch_checks(job, result, out, base, verdict):
    with tempfile.TemporaryDirectory(prefix='slot-validate-') as tmp:
        root = Path(tmp)
        hooks, tree = root / 'hooks', root / 'tree'
        hooks.mkdir()
        # A clone avoids modifying even the source checkout's worktree metadata.
        run('git', 'clone', '--shared', '--no-checkout', str(base), str(tree))
        git = ['git', '-c', f'core.hooksPath={hooks}', '-c', 'user.name=slot-validator',
               '-c', 'user.email=validator@fizzy.invalid']
        run(*git, 'checkout', '--detach', job['base']['sha'], cwd=tree)
        run(*git, 'am', '--3way', str(out / 'change.mbox'), cwd=tree)
        span = job['base']['sha'] + '..HEAD'
        paths = run(*git, 'diff', '--no-renames', '--name-only', '-z', span, cwd=tree).decode().split('\0')
        paths = sorted(p for p in paths if p)
        verdict['touched'] = paths
        reasons = verdict['reasons']
        for path in paths:
            if not any(matches(path, g) for g in job['in_bounds']):
                reasons.append(f'out of bounds: {path}')
        totals = {'files': len(paths), 'added': 0, 'deleted': 0}
        size = 0
        for row in run(*git, 'diff', '--no-renames', '--numstat', '-z', span, cwd=tree).decode().split('\0'):
            if not row:
                continue
            a, d, path = row.split('\t', 2)
            if a == '-' or d == '-':
                continue
            totals['added'] += int(a)
            totals['deleted'] += int(d)
            if not test_path(path):
                size += int(a) + int(d)
        verdict['changed'] = totals
        if size > job['limits']['max_changed_lines']:
            reasons.append(f'too big: {size} changed lines')
        identity = f'fizzy {result["slot_id"]} <slot+{result["slot_id"]}@fizzy.invalid>'
        commits = run(*git, 'rev-list', span, cwd=tree).decode().split()
        if not commits:
            reasons.append('empty patch')
        for commit in commits:
            author = run(*git, 'show', '-s', '--format=%an <%ae>', commit, cwd=tree).decode().strip()
            body = run(*git, 'show', '-s', '--format=%B', commit, cwd=tree).decode()
            if author != identity or f'Signed-off-by: {identity}' not in body.splitlines():
                reasons.append(f'foreign author or missing Signed-off-by: {commit}')
        risky = re.compile(Path(__file__).with_name('risky-paths.txt').read_text().strip(), re.I)
        verdict['risky'] = any(risky.search(p) for p in paths)


def review_checks(job, result, base, reasons):
    repo = target(job)['repo']
    info, review = job['for_review'], result['review']
    if result['agent_kind'] == info['author_kind']:
        reasons.append('review same kind as author')
    head = info['head_sha']
    # PR base is read from GitHub; job.base is the PR head, not its merge base.
    pr = gh('api', f'repos/{repo}/pulls/{info["pr"]}')
    # The checkout may be shallow or at a commit that lacks the PR's merge base: fetch both ends.
    for sha in (pr['base']['sha'], head):
        if subprocess.run(['git', 'cat-file', '-e', sha + '^{commit}'], cwd=base).returncode:
            run('git', 'fetch', '--no-tags', 'origin', sha, cwd=base)
    diff = run('git', 'diff', '--no-renames', '--unified=0', pr['base']['sha'] + '..' + head,
               cwd=base).decode()
    added, path, line = {}, None, 0
    for row in diff.splitlines():
        if row.startswith('+++ b/'):
            path = row[6:]
        elif row.startswith('@@'):
            line = int(re.search(r'\+(\d+)', row).group(1))
        elif row.startswith('+') and path:
            added.setdefault(path, set()).add(line)
            line += 1
        elif row.startswith(' '):
            line += 1
    seen = set()
    for group in ('findings', 'follow_ups'):
        for finding in review[group]:
            fid, path, line = finding['id'], finding['file'], finding['line']
            if fid in seen:
                reasons.append(f'duplicate finding: {fid}')
            seen.add(fid)
            try:
                content = run('git', 'show', f'{head}:{path}', cwd=base).splitlines()
            except ValueError:
                reasons.append(f'review file not at head: {fid}')
                content = []
            actual = line in added.get(path, set())
            if type(line) is not int or not 1 <= line <= len(content):
                reasons.append(f'review line not in file: {fid}')
            if type(finding['added']) is not bool or finding['added'] != actual:
                reasons.append(f'review line not in diff as claimed: {fid}')
            severity = finding['severity']
            is_finding = severity in ('blocker', 'major') or severity == 'minor' and actual
            if severity not in ('blocker', 'major', 'minor', 'nit') or is_finding != (group == 'findings'):
                reasons.append(f'invalid finding/follow-up split: {fid}')
            if group == 'findings' and info.get('must_fix') is not None and fid not in info['must_fix']:
                reasons.append(f're-review outside must_fix: {fid}')
    if review['verdict'] != ('changes' if review['findings'] else 'clean'):
        reasons.append('review verdict does not match findings')


def validate(job_dir, out, base, digest, signers):
    verdict = dict(accept=False, reasons=[], risky=False, touched=[], changed={})
    reasons = verdict['reasons']
    def check(label, action):
        try:
            action()
        except (ValueError, KeyError, TypeError, OSError, IndexError) as error:
            reasons.append(f'{label}: {error}')
    try:
        job_bytes = (job_dir / 'job.json').read_bytes()
        job = json.loads(job_bytes)
        result = json.loads((out / 'result.json').read_bytes())
    except (ValueError, OSError) as error:
        reasons.append(f'invalid input: {error}')
        return verdict
    try:
        target(job)
    except JobError as error:
        reasons.append(f'target: {error}')
        return verdict
    if hashlib.sha256(job_bytes).hexdigest() != digest:
        reasons.append('wrong job digest')
    if job.get('protocol') != 1 or result.get('protocol') != 1:
        reasons.append('unsupported protocol')
    if result.get('job_id') != job.get('id'):
        reasons.append('job id mismatch')
    def signature():
        run('ssh-keygen', '-Y', 'verify', '-f', str(signers), '-I', result['slot_id'],
            '-n', 'fizzy-slot', '-s', str(out / 'result.sig'), data=(out / 'manifest.txt').read_bytes())
    check('signature', signature)
    def hashes():
        expected = {'job.json', 'result.json'}
        if job['kind'] in ('write', 'rework') and result['status'] == 'done':
            expected.add('change.mbox')
        entries = {}
        for row in (out / 'manifest.txt').read_text().splitlines():
            sha, name = row.split('  ', 1)
            if name not in expected or name in entries:
                raise ValueError('unexpected or duplicate manifest entry')
            entries[name] = sha
        if set(entries) != expected:
            raise ValueError('incomplete manifest')
        for name, sha in entries.items():
            data = job_bytes if name == 'job.json' else (out / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != sha:
                reasons.append(f'manifest hash mismatch: {name}')
        if entries['job.json'] != digest:
            reasons.append('manifest job digest mismatch')
    check('manifest', hashes)
    def lease():
        start, finish = (dt.datetime.fromisoformat(result[k].replace('Z', '+00:00'))
                         for k in ('started_at', 'finished_at'))
        elapsed = (finish - start).total_seconds()
        if not 0 <= elapsed <= job['lease']['ttl_minutes'] * 60:
            reasons.append('expired lease')
        if job['kind'] == 'write':
            issue = gh('api', f'repos/{job["issue"]["repo"]}/issues/{job["issue"]["number"]}')
            if issue['state'] != 'open' or 'ready' not in [x['name'] for x in issue['labels']]:
                reasons.append('issue no longer open and ready')
        else:
            info = job['for_review'] if job['kind'] == 'review' else job['rework']
            pr = gh('api', f'repos/{target(job)["repo"]}/pulls/{info["pr"]}')
            if pr['state'] != 'open' or pr['head']['sha'] != job['base']['sha']:
                reasons.append('PR closed or head moved')
    check('lease', lease)
    if result.get('status') not in ('done', 'declined', 'failed', 'timeout'):
        reasons.append('invalid result status')
    if job.get('kind') not in ('write', 'review', 'rework'):
        reasons.append('invalid job kind')
    if result.get('status') == 'done':
        if job['kind'] in ('write', 'rework'):
            check('patch', lambda: patch_checks(job, result, out, base, verdict))
            def body():
                with tempfile.TemporaryDirectory() as tmp:
                    tree, hooks = Path(tmp) / 'tree', Path(tmp) / 'hooks'
                    hooks.mkdir()
                    run('git', 'clone', '--shared', '--no-checkout', str(base), str(tree))
                    run('git', '-c', f'core.hooksPath={hooks}', 'checkout', '--detach',
                        job['base']['sha'], cwd=tree)
                    body_file = Path(tmp) / 'body.md'
                    body_file.write_text(result['pr_body'])
                    checker = tree / 'scripts/check-pr-body'
                    if not checker.exists():
                        checker = Path(__file__).resolve().parents[1] / 'check-pr-body'
                    run(str(checker), str(body_file), cwd=tree)
            check('check-pr-body', body)
        elif job['kind'] == 'review':
            check('review', lambda: review_checks(job, result, base, reasons))
    verdict['accept'] = not reasons
    return verdict


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('job_dir', type=Path)
    parser.add_argument('out_dir', type=Path)
    parser.add_argument('--fizzy', type=Path, required=True)
    parser.add_argument('--job-digest', required=True)
    parser.add_argument('--allowed-signers', type=Path, default=Path(__file__).with_name('allowed_signers'))
    args = parser.parse_args()
    verdict = validate(args.job_dir.resolve(), args.out_dir.resolve(), args.fizzy.resolve(),
                       args.job_digest, args.allowed_signers.resolve())
    (args.out_dir.parent / 'verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
    for reason in verdict['reasons']:
        print(reason, file=sys.stderr)
    return 0 if verdict['accept'] else 1
