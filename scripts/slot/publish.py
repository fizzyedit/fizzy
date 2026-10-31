"""Publish validated slot results through GitHub CLI and authenticated git push."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from slot.common import target
from slot.validate import gh, run


def api(endpoint, method='GET', **fields):
    args = ['api', endpoint, '--method', method]
    for key, value in fields.items():
        args += ['-f', f'{key}={value}']
    return gh(*args)


def comment(repo, number, text, marker):
    endpoint = f'repos/{repo}/issues/{number}/comments'
    comments = gh('api', '--paginate', endpoint)
    if not any(marker in c['body'] for c in comments):
        api(endpoint, 'POST', body=text + '\n\n' + marker)


def labels(repo, number, wanted, remove=()):
    endpoint = f'repos/{repo}/issues/{number}'
    issue = gh('api', endpoint)
    current = {x['name'] for x in issue['labels']}
    for label in wanted:
        if label not in current:
            gh('issue', 'edit', str(number), '--repo', repo, '--add-label', label)
    for label in remove:
        if label in current:
            gh('issue', 'edit', str(number), '--repo', repo, '--remove-label', label)


def push(job, out, result, branch, expected=None):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*', branch) or '..' in branch:
        raise ValueError('invalid branch')
    token = os.environ['GH_TOKEN']
    # Keep credentials out of errors and persisted remotes.
    with tempfile.TemporaryDirectory(prefix='slot-publish-') as tmp:
        tree, hooks = Path(tmp) / 'tree', Path(tmp) / 'hooks'
        hooks.mkdir()
        run('git', 'clone', '--no-checkout', f'https://github.com/{target(job)["repo"]}.git', str(tree))
        git = ['git', '-c', f'core.hooksPath={hooks}', '-c', 'user.name=slot-publish',
               '-c', 'user.email=publish@fizzy.invalid']
        run(*git, 'checkout', '--detach', job['base']['sha'], cwd=tree)
        run(*git, 'am', '--3way', '--committer-date-is-author-date', str(out / 'change.mbox'), cwd=tree)
        # The push subprocess's captured output is deliberately never surfaced.
        url = f'https://x-access-token:{token}@github.com/{target(job)["repo"]}.git'
        head = run(*git, 'rev-parse', 'HEAD', cwd=tree).decode().strip()
        remote = subprocess.run([*git, 'ls-remote', url, f'refs/heads/{branch}'], capture_output=True)
        if remote.returncode:
            raise ValueError('cannot inspect remote branch')
        remote_sha = remote.stdout.decode().split()
        if remote_sha and remote_sha[0] == head:
            return
        if expected and remote_sha and remote_sha[0] != expected:
            raise ValueError('PR head moved')
        if expected:
            run(*git, 'merge-base', '--is-ancestor', expected, 'HEAD', cwd=tree)
        lease = f'--force-with-lease=refs/heads/{branch}:{expected or ""}'
        p = subprocess.run([*git, 'push', lease, url, f'HEAD:refs/heads/{branch}'],
                           cwd=tree, capture_output=True)
        if p.returncode:
            raise ValueError('push refused (branch exists or head moved)')


def publish(job_dir, out):
    verdict_path = out.parent / 'verdict.json'
    verdict = json.loads(verdict_path.read_text())
    if not os.environ.get('GH_TOKEN'):
        raise ValueError('GH_TOKEN is required')
    job = json.loads((job_dir / 'job.json').read_text())
    dest = target(job)
    slug = dest['repo']
    repo, number = job['issue']['repo'], job['issue']['number']
    marker = f'<!-- slot-job: {job["id"]} -->'
    if verdict['accept'] is not True:
        comment(repo, number, 'REFUSED: ' + '\n'.join(verdict['reasons']), marker)
        labels(repo, number, ['stuck'])
        return
    result = json.loads((out / 'result.json').read_text())
    status = result['status']
    if status == 'declined':
        comment(repo, number, 'APPROACH: ' + result['decline'], marker)
        labels(repo, number, ['arch:needed'], ['ready'])
    elif status in ('failed', 'timeout'):
        comment(repo, number, f'{status}: {result.get("error", "")}\n{result["report"][-2000:]}', marker)
        labels(repo, number, [f'attempt:{job["attempt"]}'] + (['stuck'] if job['attempt'] >= 2 else []))
    elif job['kind'] == 'write':
        prs = gh('pr', 'list', '--repo', slug, '--head', job['branch'], '--state', 'all',
                 '--json', 'number,body')
        if prs:
            if not any(marker in pr['body'] for pr in prs):
                raise ValueError('branch belongs to another job')
            return
        push(job, out, result, job['branch'])
        body = result['pr_body'] + f'\n\nPart of {repo}#{number}\n\n' + marker
        args = ['pr', 'create', '--repo', slug, '--base', dest['branch'], '--head', job['branch'],
                '--title', result['title'], '--body', body, '--label', f'area:{job["issue"]["area"]}',
                '--label', f'kind:{result["agent_kind"]}']
        if verdict['risky'] or dest['gate']:
            args += ['--label', 'gate:yes']
        created = gh(*args)
        if dest['gate']:
            # This repo has no review bridge: ask the work repo to review the new PR.
            found = re.search(r'/pull/(\d+)', str(created))
            if not found:
                raise ValueError('cannot read the new PR number')
            payload = dict(event_type='review', client_payload=dict(pr=int(found.group(1)), repo=slug))
            run(os.environ.get('SLOT_GH', 'gh'), 'api', f'repos/{repo}/dispatches',
                '--input', '-', data=json.dumps(payload).encode())
    elif job['kind'] == 'rework':
        info = job['rework']
        pr = gh('api', f'repos/{slug}/pulls/{info["pr"]}')
        comments = gh('api', '--paginate', f'repos/{slug}/issues/{info["pr"]}/comments')
        if any(marker in c['body'] for c in comments):
            return
        push(job, out, result, pr['head']['ref'], job['base']['sha'])
        labels(slug, info['pr'], [f'rework:{info["round"]}'])
        comment(slug, info['pr'], 'Rework published.', marker)
    else:
        info, review = job['for_review'], result['review']
        pr_number, sha = info['pr'], info['head_sha']
        threads = gh('issue', 'list', '--repo', repo, '--label', 'pr-thread', '--state', 'all',
                     '--search', f'PR #{pr_number}: in:title', '--json', 'number,title')
        threads = [t for t in threads if t['title'].startswith(f'PR #{pr_number}:')]
        if len(threads) != 1:
            raise ValueError('expected exactly one PR thread')
        text = f'REVIEW: {review["verdict"]} @{sha}\n' + json.dumps(review, indent=2)
        comment(repo, threads[0]['number'], text, marker)
        if review['follow_ups']:
            comment(slug, pr_number, 'Follow-ups:\n' + json.dumps(review['follow_ups'], indent=2), marker)
        endpoint = f'repos/{slug}/statuses/{sha}'
        statuses = gh('api', '--paginate', endpoint)
        state = 'success' if review['verdict'] == 'clean' else 'failure'
        description = f'slot {job["id"]}'
        if not any(s['context'] == 'agent-review' and s.get('description') == description for s in statuses):
            api(endpoint, 'POST', state=state, context='agent-review', description=description)
        if review['verdict'] == 'clean':
            pr = gh('api', f'repos/{slug}/pulls/{pr_number}')
            if not dest['gate'] and not pr.get('auto_merge') and not pr.get('merged'):
                gh('pr', 'merge', str(pr_number), '--repo', slug, '--auto')
        else:
            round_number = job.get('attempt', 1) + 1
            if round_number >= 3:
                labels(slug, pr_number, ['stuck'])
            else:
                # A dispatch receipt makes subsequent successful runs a no-op.
                receipt = f'<!-- slot-dispatch: {job["id"]} -->'
                comments = gh('api', '--paginate', f'repos/{repo}/issues/{threads[0]["number"]}/comments')
                if not any(receipt in c['body'] for c in comments):
                    payload = dict(event_type='rework', client_payload=dict(pr=pr_number,
                                   round=round_number, findings=review['findings']))
                    run(os.environ.get('SLOT_GH', 'gh'), 'api', f'repos/{repo}/dispatches',
                        '--input', '-', data=json.dumps(payload).encode())
                    comment(repo, threads[0]['number'], 'Rework dispatched.\n' + receipt, receipt + '\n' + marker)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('job_dir', type=Path)
    parser.add_argument('out_dir', type=Path)
    args = parser.parse_args()
    try:
        publish(args.job_dir.resolve(), args.out_dir.resolve())
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'publish refused: {error}\n')
    return 0
