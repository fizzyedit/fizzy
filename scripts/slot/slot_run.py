"""Run one untrusted job in a fresh checkout and sign its result."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

try:
    from . import common
except ImportError:
    import common

ROOT = Path(__file__).resolve().parent


class BrokenSlot(RuntimeError):
    pass


def utc():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def clean_env():
    allowed = {'PATH', 'HOME', 'USER', 'LANG', 'TMPDIR', 'TEMP', 'SYSTEMROOT'}
    return {k: v for k, v in os.environ.items()
            if (k.upper() in allowed or k.upper().startswith('SLOT_'))
            and not k.upper().startswith(('GITHUB_', 'GH_', 'ACTIONS_', 'RUNNER_'))
            and not k.upper().endswith('_TOKEN')}


def git(repo, *args, env=None):
    # Command-line config also covers clone/checkout before local config exists.
    return subprocess.check_output(['git', '-c', 'core.hooksPath=' + str(repo.parent / 'empty-hooks'),
                                    '-c', 'commit.gpgSign=false', *args], cwd=repo,
                                   env=env or clean_env(), stderr=subprocess.PIPE)


def checkout(job, job_dir, home):
    work = home / 'work' / job['id']
    work.parent.mkdir(parents=True, exist_ok=True)
    if work.exists():
        raise BrokenSlot('checkout already exists: ' + str(work))
    hooks = work.parent / 'empty-hooks'
    hooks.mkdir(exist_ok=True)
    try:
        bundle = job['base'].get('bundle')
        if bundle:
            source = (job_dir / bundle).resolve()
            git(home, 'init', '--bare', str(work))
            git(work, 'bundle', 'verify', str(source))
            shutil.rmtree(work)
        else:
            source = home / 'mirror.git'
            if not source.exists():
                git(home, 'init', '--bare', str(source))
            git(home, '--git-dir=' + str(source), 'fetch', '--no-tags', '--',
                job['base']['repo'], job['base']['sha'])
        git(home, 'clone', '--no-checkout', '--no-hardlinks', '--', str(source), str(work))
        git(work, 'config', 'core.hooksPath', str(hooks))
        git(work, 'checkout', '--detach', job['base']['sha'])
        if git(work, 'rev-parse', 'HEAD').decode().strip() != job['base']['sha']:
            raise BrokenSlot('HEAD differs from base.sha')
        return work
    except (OSError, subprocess.CalledProcessError) as exc:
        shutil.rmtree(work, ignore_errors=True)
        raise BrokenSlot('fetch/checkout failed') from exc


@contextmanager
def build_lock(directory, slots, deadline):
    directory.mkdir(parents=True, exist_ok=True)
    held = None
    while held is None:
        if time.monotonic() >= deadline:
            raise TimeoutError('time limit waiting for build lock')
        for i in range(slots):
            lock = open(directory / f'{i}.lock', 'a+b')
            try:
                if os.name == 'nt':
                    import msvcrt
                    lock.seek(0)
                    if not lock.read(1):
                        lock.write(b'\0')
                        lock.flush()
                    lock.seek(0)
                    msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held = lock
                break
            except OSError:
                lock.close()
        if held is None:
            time.sleep(min(5, max(0, deadline - time.monotonic())))
    try:
        yield
    finally:
        if os.name == 'nt':
            held.seek(0)
            msvcrt.locking(held.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            fcntl.flock(held, fcntl.LOCK_UN)
        held.close()


def stop_tree(proc):
    if os.name == 'nt':
        try:
            proc.send_signal(signal.CTRL_BREAK_EVENT)
            proc.wait(timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            # Services may have no console for CTRL_BREAK; taskkill covers descendants.
            pass
        subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            pass
        except ProcessLookupError:
            return
        # A child may ignore TERM even after its parent exits.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    proc.wait()


def execute(command, repo, log, deadline, prompt=None, shell=False):
    options = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == 'nt' else {'start_new_session': True}
    with subprocess.Popen(command, cwd=repo, env=clean_env(), shell=shell,
                          stdin=subprocess.PIPE if prompt is not None else subprocess.DEVNULL,
                          stdout=log, stderr=subprocess.STDOUT, **options) as proc:
        try:
            proc.communicate(input=prompt, timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            stop_tree(proc)
            raise TimeoutError('time limit exceeded') from None
        return proc.returncode


def review_shape(value):
    if not isinstance(value, dict) or value.get('verdict') not in ('clean', 'changes'):
        return False
    for name in ('findings', 'follow_ups'):
        if not isinstance(value.get(name), list):
            return False
        for item in value[name]:
            if not isinstance(item, dict):
                return False
            if not all(isinstance(item.get(k), str) and item[k] for k in ('id', 'file', 'text')):
                return False
            if item.get('severity') not in ('blocker', 'major', 'minor', 'nit'):
                return False
            if type(item.get('line')) is not int or item['line'] < 1 or type(item.get('added')) is not bool:
                return False
    return (value['verdict'] == 'changes') == bool(value['findings'])


def read_agent(out, name):
    path = out / 'agent' / name
    return path.read_text(encoding='utf-8', errors='replace') if path.exists() else ''


def run(job, job_dir, out, keep):
    kind = os.environ.get('SLOT_KIND', 'codex')
    slot_id = os.environ.get('SLOT_ID', 'local-' + kind)
    key = Path(os.environ.get('SLOT_KEY', '~/.config/fizzy-slot/key')).expanduser()
    if not key.is_file():
        raise BrokenSlot('SLOT_KEY missing')
    try:
        agents = json.loads(Path(os.environ.get('SLOT_AGENTS', ROOT / 'agents.json')).read_text())
        config = agents[kind]
        command = list(config.get('windows_cmd', config['cmd']) if os.name == 'nt' else config['cmd'])
        command = [os.path.expandvars(os.path.expanduser(a)) for a in command]
        if not shutil.which(command[0]):
            raise BrokenSlot('agent command not on PATH')
    except (OSError, ValueError, KeyError, IndexError, TypeError) as exc:
        raise BrokenSlot('invalid agent configuration') from exc
    home = Path(os.environ.get('SLOT_HOME', '~/.local/share/fizzy-slot')).expanduser().resolve()
    home.mkdir(parents=True, exist_ok=True)
    work = checkout(job, job_dir, home)
    started = utc()
    deadline = time.monotonic() + job['limits']['minutes'] * 60
    phase = ['agent']
    stop = threading.Event()

    def heartbeat():
        interval = max(0.01, float(os.environ.get('SLOT_HEARTBEAT_SECONDS', '60')))
        with (out / 'events.jsonl').open('a', encoding='utf-8') as events:
            while not stop.wait(interval):
                events.write(json.dumps(dict(t=utc(), job=job['id'], phase=phase[0])) + '\n')
                events.flush()

    thread = threading.Thread(target=heartbeat, daemon=True)
    thread.start()
    result = dict(protocol=1, job_id=job['id'], slot_id=slot_id, agent_kind=kind,
                  model=os.environ.get('SLOT_MODEL', ''), os=os.environ.get('SLOT_OS', sys.platform),
                  status='done', started_at=started, title=job.get('issue', {}).get('title', job['id']),
                  pr_body='', review=None, decline=None, gates=[], changed=dict(files=0, added=0, deleted=0))
    try:
        try:
            (out / 'agent').mkdir()
            decline_path = work / 'decline.md'
            values = {**job, 'out_agent': str(out / 'agent'), 'decline_path': str(decline_path),
                      'pr_body_path': str(work / 'pr-body.md'), 'report_path': str(work / 'report.md'),
                      'review_path': str(work / 'review.json')}
            prompt = (ROOT / 'prompts' / (job['kind'] + '.md')).read_text(encoding='utf-8').format_map(values)
            if os.environ.get('SLOT_MODEL'):
                command += [config['model_flag'], os.environ['SLOT_MODEL']]
            if config['prompt'] == 'arg':
                command.append(prompt)
            with (out / 'log.txt').open('wb') as log:
                try:
                    rc = execute(command, work, log, deadline,
                                 prompt.encode() if config['prompt'] == 'stdin' else None)
                finally:
                    # Collect sandbox outputs before staging the implementation patch.
                    for name in ('pr-body.md', 'report.md', 'review.json', 'decline.md'):
                        source = work / name
                        if source.is_file():
                            shutil.copyfile(source, out / 'agent' / name)
                            source.unlink()
                if rc == 64 or rc in config.get('auth_exit', []):
                    raise BrokenSlot('agent not signed in')
                if not decline_path.exists():
                    decline_path = out / 'agent' / 'decline.md'
                if decline_path.exists():
                    shutil.copyfile(decline_path, out / 'decline.md')
                    result.update(status='declined', decline=(out / 'decline.md').read_text(
                        encoding='utf-8', errors='replace'))
                elif rc != 0:
                    raise ValueError(f'agent exited {rc}')
                elif job['kind'] == 'review':
                    review = json.loads(read_agent(out, 'review.json'))
                    if not review_shape(review):
                        raise ValueError('invalid review shape')
                    result['review'] = review
                else:
                    identity = f'fizzy {slot_id}'
                    email = f'slot+{slot_id}@fizzy.invalid'
                    git(work, 'add', '-A')
                    if git(work, 'diff', '--cached', '--name-only').strip():
                        env = {**clean_env(), 'GIT_AUTHOR_NAME': identity, 'GIT_AUTHOR_EMAIL': email,
                               'GIT_COMMITTER_NAME': identity, 'GIT_COMMITTER_EMAIL': email}
                        git(work, 'commit', '-m', result['title'], '-m',
                            f'Signed-off-by: {identity} <{email}>', env=env)
                    changed = common.count_changed(job['base']['sha'], work)
                    result['changed'] = {k: changed[k] for k in ('files', 'added', 'deleted')}
                    if not changed['files']:
                        raise ValueError('no change')
                    if changed['added_non_test'] + changed['deleted_non_test'] > job['limits']['max_changed_lines']:
                        raise ValueError('too many non-test changed lines')
                    phase[0] = 'gates'
                    if job['gates']:
                        locks = Path(os.environ.get('SLOT_BUILD_LOCKS', home / 'build-locks'))
                        slots = int(os.environ.get('SLOT_BUILD_SLOTS', '2'))
                        if slots < 1:
                            raise BrokenSlot('SLOT_BUILD_SLOTS must be positive')
                        with build_lock(locks, slots, deadline):
                            for gate in job['gates']:
                                before = time.monotonic()
                                code = execute(gate, work, log, deadline, shell=True)
                                result['gates'].append(dict(cmd=gate, exit=code, seconds=round(time.monotonic() - before, 3)))
                                if code:
                                    raise ValueError('gate failed: ' + gate)
        except TimeoutError as exc:
            result.update(status='timeout', error=str(exc))
        except (ValueError, subprocess.CalledProcessError) as exc:
            result.update(status='failed', error=str(exc).splitlines()[0])
        phase[0] = 'pack'
        if result['status'] == 'done' and job['kind'] != 'review':
            (out / 'change.mbox').write_bytes(git(work, 'format-patch', '--stdout', job['base']['sha'] + '..HEAD'))
        result.update(finished_at=utc(), pr_body=read_agent(out, 'pr-body.md'), report=read_agent(out, 'report.md')[:8000])
        log_path = out / 'log.txt'
        with log_path.open('rb') as log:
            log.seek(0, 2)
            size = log.tell()
            log.seek(max(0, size - 2 * 1024 * 1024))
            tail = log.read()
        log_path.write_bytes(tail)
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        (out / 'manifest.txt').write_text(common.manifest(out), encoding='utf-8')
        common.sign(out / 'manifest.txt', key)
        return {'done': 0, 'declined': 3, 'failed': 4, 'timeout': 5}[result['status']]
    finally:
        stop.set()
        thread.join()
        if not keep:
            shutil.rmtree(work)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('job_dir', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--keep-checkout', action='store_true')
    args = parser.parse_args(argv)
    try:
        job = common.load_job(args.job_dir / 'job.json')
    except common.JobError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    out = args.out.resolve()
    try:
        if out.exists() and (not out.is_dir() or any(out.iterdir())):
            print('output directory must be empty', file=sys.stderr)
            return 2
        out.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.job_dir / 'job.json', out / 'job.json')
        return run(job, args.job_dir.resolve(), out, args.keep_checkout)
    except (BrokenSlot, OSError, subprocess.CalledProcessError) as exc:
        if out.is_dir():
            (out / 'result.json').unlink(missing_ok=True)
        print(str(exc), file=sys.stderr)
        return 6


if __name__ == '__main__':
    sys.exit(main())
