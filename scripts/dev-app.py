#!/usr/bin/env python3
"""Build and run Coastline; --watch rebuilds and relaunches after Swift edits."""
import argparse
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = ('Coastline', 'CoastlineCore', 'MillCore', 'Viewport')

def sources():
    result = {}
    for package in PACKAGES:
        base = ROOT / package
        for path in [base / 'Package.swift', base / 'Package.resolved',
                     *sorted(p for p in (base / 'Sources').rglob('*') if p.is_file())]:
            try:
                info = path.stat()
                result[str(path)] = (info.st_mtime_ns, info.st_size)
            except FileNotFoundError:
                pass
    for base in [ROOT / 'engine/coastline_engine', ROOT / 'resources']:
        for path in base.rglob('*'):
            if not path.is_file() or '__pycache__' in path.parts or path.name == '.DS_Store':
                continue
            try:
                info = path.stat()
                result[str(path)] = (info.st_mtime_ns, info.st_size)
            except FileNotFoundError:
                pass
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--watch', action='store_true', help='Rebuild and relaunch after source changes')
    parser.add_argument('--page', choices=['workspace', 'control'], help='Page to open (otherwise resume the previous page)')
    args = parser.parse_args()
    dev = ROOT / 'build/dev'
    dev.mkdir(parents=True, exist_ok=True)
    lock = (dev / 'watcher.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Coastline debug is already running. Keep using that window.', flush=True)
        return
    env = dict(os.environ, COASTLINE_DEV='1', COASTLINE_DEV_STATE=str(dev / 'session.json'))
    if args.page:
        env['COASTLINE_DEV_PAGE'] = args.page
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    if 'Xcode.app' not in developer:
        sdks = sorted(Path('/Library/Developer/CommandLineTools/SDKs').glob('MacOSX26*.sdk'))
        if sdks:
            env['SDKROOT'] = str(sdks[-1])
    process = None
    stopping = False

    def stop_signal(_number, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop_signal)
    signal.signal(signal.SIGTERM, stop_signal)

    def close_app():
        nonlocal process
        if process is not None and process.poll() is None:
            process.terminate()  # Coastline handles SIGTERM with its normal shutdown.
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                print('App has not exited; leaving it open. Close it before retrying.', flush=True)
                return False
        process = None
        return True

    previous = sources()
    build_needed = True
    try:
        while not stopping:
            if build_needed:
                previous = sources()
                print('\nBuilding Coastline…', flush=True)
                with (dev / 'build.log').open('w') as log:
                    built = subprocess.run(['swift', 'build', '--package-path', str(ROOT / 'Coastline'), '-j', '4'], env=env,
                                           stdout=log, stderr=subprocess.STDOUT)
                if built.returncode == 0 and not stopping:
                    binary = ROOT / 'Coastline/.build/debug/Coastline'
                    if close_app():
                        # Use one stable executable, separate from the file Swift overwrites.
                        # A failed future build cannot disturb the running process's image.
                        executable = dev / 'Coastline-Debug'
                        staged = dev / 'Coastline-Debug.next'
                        shutil.copy2(binary, staged)
                        staged.replace(executable)
                        print('Opening Coastline Debug; your saved development session will resume.', flush=True)
                        process = subprocess.Popen([str(executable)], cwd=ROOT, env=env)
                elif built.returncode:
                    print('Build failed. Current app stays open; save another edit to retry.\n'
                          f'Build log: {dev / "build.log"}', flush=True)
                    print((dev / 'build.log').read_text()[-6000:], flush=True)
                build_needed = False
                if not args.watch and (process is None or stopping):
                    break
            if not args.watch:
                if process.poll() is not None:
                    break
                time.sleep(0.25)
                continue
            current = sources()
            if current != previous:
                previous = current
                # Coalesce a burst of saves. Edits during the build are picked up next loop.
                time.sleep(0.7)
                previous = sources()
                build_needed = True
            else:
                time.sleep(0.5)
    finally:
        close_app()

if __name__ == '__main__':
    main()
