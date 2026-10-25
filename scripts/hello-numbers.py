#!/usr/bin/env python3
"""Build and measure example-app minimal; stdout is JSONL, diagnostics go to stderr."""

import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
IGNORED = {'.git', '.jj', '.zig-cache', 'zig-pkg', 'zig-out', '__pycache__', '.DS_Store', '.profile', '.temp', '.velopack-msvc'}
FIRST_FRAME = re.compile(r'startup: first frame ([0-9]+(?:\.[0-9]+)?) ms after main')


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise ValueError(f'{path}: expected exactly one {old!r}; example build changed')
    path.write_text(source.replace(old, new))


def copy_tree(source, destination):
    shutil.copytree(source, destination, ignore=lambda _, names: set(names) & IGNORED)


def pin(path, dependency, destination):
    source = path.read_text()
    pattern = rf'\.{dependency}\s*=\s*\.\{{[^{{}}]*\}},'
    # Relative paths keep the scratch tree portable and avoid ZON string escaping.
    relative = os.path.relpath(destination, path.parent).replace(os.sep, '/')
    source, count = re.subn(pattern, lambda _: f'.{dependency} = .{{ .path = "{relative}" }},',
                            source, count=1, flags=re.S)
    if count != 1:
        raise ValueError(f'{path}: dependency {dependency} not found')
    path.write_text(source)


def prepare(work, example, plugin):
    fizzy = work / 'fizzy'
    app = work / 'example-app'
    hello = work / 'example-plugin'
    copy_tree(ROOT, fizzy)
    copy_tree(example, app)
    copy_tree(plugin, hello)
    pin(hello / 'build.zig.zon', 'fizzy', fizzy / 'sdk')
    pin(app / 'build.zig.zon', 'fizzy', fizzy)
    pin(app / 'build.zig.zon', 'fizzy_sdk', fizzy / 'sdk')
    pin(app / 'build.zig.zon', 'hello', hello)
    for zon in (app / 'plugins').glob('*/build.zig.zon'):
        pin(zon, 'fizzy', fizzy / 'sdk')
    # `dotnet vpk` resolves the local tool from the manifest above its cwd, which is the app's
    # directory; the build restores it only beside fizzy.
    shutil.copytree(fizzy / '.config', app / '.config', dirs_exist_ok=True)
    # Velopack rejects the library default 0.0.0; use a fixed, unpublished benchmark version.
    replace_once(app / 'build.zig', '        .@"defer-app" = true,',
                 '        .@"defer-app" = true,\n        .app_version = @as([]const u8, "0.1.0"),')
    # The consumer keeps its plugin list and shape. Expose dependency build outputs.
    replace_once(app / 'build.zig', '    const exe = fizzy_dep.artifact(name);', '''    try fizzy.addPackageSteps(b, fizzy_dep);
    if (fizzy_dep.builder.top_level_steps.contains("package")) {
        const installers = b.addInstallDirectory(.{
            .source_dir = fizzy_dep.namedLazyPath("package"),
            .install_dir = .prefix,
            .install_subdir = "installers",
        });
        b.step("measure-package", "Install native installers for measurement").dependOn(&installers.step);
    }
    const wasm = b.addInstallFile(fizzy_dep.namedLazyPath("web-wasm"), "web/web.wasm");
    b.step("web", "Install the web module for measurement").dependOn(&wasm.step);
    const exe = fizzy_dep.artifact(name);''')
    return app


def rss_bytes(pid):
    # Include helper processes: Electron's renderer is otherwise missing from comparisons.
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss='], text=True)
    processes = [tuple(map(int, line.split())) for line in rows.splitlines() if line.strip()]
    family = {pid}
    while True:
        children = {child for child, parent, _ in processes if parent in family}
        if children <= family:
            break
        family |= children
    values = [rss for child, _, rss in processes if child in family]
    if not any(child == pid for child, _, _ in processes):
        raise RuntimeError('app exited before the RSS sample')
    return sum(values) * 1024


def measure(command, log, env, peer=False, idle_seconds=30):
    started = time.monotonic()
    with log.open('w+') as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        try:
            first_frame_ms = None
            while time.monotonic() - started < idle_seconds:
                if process.poll() is not None:
                    raise RuntimeError(f'app exited ({process.returncode}): {log.read_text()}')
                if first_frame_ms is None:
                    content = log.read_text()
                    if peer:
                        if 'HELLO_FIRST_FRAME' in content:
                            first_frame_ms = (time.monotonic() - started) * 1000
                    else:
                        match = FIRST_FRAME.search(content)
                        if match:
                            first_frame_ms = float(match[1])
                time.sleep(min(0.01, max(0, idle_seconds - (time.monotonic() - started))))
            sample_at = time.monotonic() - started
            if first_frame_ms is None:
                raise RuntimeError(f'first-frame marker missing: {log.read_text()}')
            rss = rss_bytes(process.pid)
            return {'first_frame_ms': first_frame_ms, 'idle_rss_bytes': rss,
                    'rss_sample_after_s': sample_at, 'rss_scope': 'process_tree'}
        finally:
            # A peer may spawn helpers; tear down the entire private process group.
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                time.sleep(0.1)
            process.wait()


def metadata(args):
    return {'schema_version': 1, 'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'os': platform.system(), 'os_release': platform.release(), 'arch': platform.machine(),
            'machine': platform.node(), 'runner_image': os.environ.get('ImageOS'),
            'revision': args.revision, 'startup_cache': 'fresh_process_fresh_profile_warm_os_cache',
            'idle_seconds': 30}


def one_file(directory, suffix):
    files = list(directory.rglob(f'*{suffix}'))
    if len(files) != 1:
        raise ValueError(f'expected one {suffix} in {directory}, found {files}')
    return files[0]


def emit(record, output):
    line = json.dumps(record, sort_keys=True, allow_nan=False)
    with output.open('a') as stream:
        stream.write(line + '\n')
    print(line, flush=True)


def benchmark(args):
    if platform.system() not in ('Darwin', 'Linux'):
        raise ValueError('only macOS and Linux are supported')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fizzy-hello-') as temporary:
        work = Path(temporary)
        app = prepare(work, args.example.resolve(), args.plugin.resolve())
        build_env = dict(os.environ, FIZZY_PROFILE=str(work / 'build-profile'))
        for mode in ('ReleaseFast', 'ReleaseSmall'):
            prefix = work / mode
            common = [ROOT / 'scripts/zb', 'build', '-Dshape=minimal', f'-Doptimize={mode}',
                      '--prefix', prefix, '--summary', 'all']
            subprocess.run(common, cwd=app, env=build_env, check=True, stdout=sys.stderr)
            subprocess.run([*common, 'measure-package'], cwd=app, env=build_env, check=True, stdout=sys.stderr)
            subprocess.run([*common, 'web'], cwd=app, env=build_env, check=True, stdout=sys.stderr)
            binary = prefix / 'bin/minimalapp'
            subprocess.run(['strip', binary], check=True, stdout=sys.stderr)
            # strip invalidates the Mach-O signature; ad-hoc sign before executing on arm64.
            if platform.system() == 'Darwin':
                subprocess.run(['codesign', '--force', '--sign', '-', binary], check=True, stdout=sys.stderr)
            installer = one_file(prefix / 'installers', '.pkg' if platform.system() == 'Darwin' else '.AppImage')
            wasm = one_file(prefix / 'web', '.wasm')
            record = metadata(args)
            record.update({'app': 'example-app/minimal', 'optimize': mode,
                           'example_revision': args.example_revision, 'plugin_revision': args.plugin_revision,
                           'package_version': '0.1.0',
                           'zig_version': subprocess.check_output([os.environ.get('FIZZY_BUILD_ZIG', 'zig'), 'version'], text=True).strip(),
                           'binary_bytes': binary.stat().st_size, 'installer_bytes': installer.stat().st_size,
                           'installer_format': installer.suffix, 'wasm_gzip_bytes': len(gzip.compress(wasm.read_bytes(), compresslevel=9, mtime=0)),
                           'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                           'first_frame_source': 'core.profile main -> first frame'})
            env = dict(os.environ, FIZZY_PROFILE=str(work / f'profile-{mode}'), FIZZY_QUIET='1',
                       FIZZY_STARTUP_REPORT='1')
            if not args.sizes_only:
                record.update(measure([str(binary)], work / f'{mode}.log', env))
            emit(record, args.output)


def compare(args):
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='compare-hello-') as temporary:
        record = metadata(args)
        record.update({'app': args.app, 'framework_version': args.framework_version,
                       'binary_bytes': args.binary.stat().st_size,
                       'installer_bytes': args.installer.stat().st_size,
                       'installer_format': args.installer.suffix,
                       'first_frame_source': 'process spawn -> stdout HELLO_FIRST_FRAME (10 ms polling)',
                       'wasm_gzip_bytes': None})
        env = dict(os.environ, HELLO_PROFILE=temporary)
        record.update(measure([str(args.binary.resolve()), *(args.app_args[1:] if args.app_args[:1] == ['--'] else args.app_args)],
                              Path(temporary) / 'app.log', env, peer=True))
        emit(record, args.output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='append-only JSONL output')
    parser.add_argument('--revision', required=True, help='source revision (include dirty if applicable)')
    sub = parser.add_subparsers(dest='kind', required=True)
    fizzy = sub.add_parser('fizzy')
    fizzy.add_argument('--sizes-only', action='store_true',
                       help='record the three sizes and skip the run (no window opens)')
    fizzy.add_argument('--example', type=Path, required=True)
    fizzy.add_argument('--plugin', type=Path, required=True)
    fizzy.add_argument('--example-revision', required=True)
    fizzy.add_argument('--plugin-revision', required=True)
    peer = sub.add_parser('compare')
    peer.add_argument('--app', choices=('electron', 'tauri'), required=True)
    peer.add_argument('--framework-version', required=True)
    peer.add_argument('--binary', type=Path, required=True)
    peer.add_argument('--installer', type=Path, required=True)
    peer.add_argument('app_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    (benchmark if args.kind == 'fizzy' else compare)(args)


if __name__ == '__main__':
    main()
