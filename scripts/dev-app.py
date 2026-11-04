#!/usr/bin/env python3
"""Build and run Coastline; --watch rebuilds and relaunches after Swift edits."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = ('Coastline', 'CoastlineCore', 'MillCore', 'Viewport')

def sources():
    result = {}
    for package in PACKAGES:
        base = ROOT / package
        for path in [base / 'Package.swift', *sorted((base / 'Sources').rglob('*.swift'))]:
            try:
                info = path.stat()
                result[str(path)] = (info.st_mtime_ns, info.st_size)
            except FileNotFoundError:
                pass
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--watch', action='store_true', help='Rebuild and relaunch after source changes')
    args = parser.parse_args()
    env = dict(os.environ, COASTLINE_DEV='1')
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
                process.wait(timeout=8)
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
                built = subprocess.run(['swift', 'build', '--package-path', str(ROOT / 'Coastline')], env=env)
                if built.returncode == 0 and not stopping:
                    binary = ROOT / 'Coastline/.build/debug/Coastline'
                    if close_app():
                        print('Opening UI development build (Digital Machine only).', flush=True)
                        process = subprocess.Popen([str(binary)], cwd=ROOT, env=env)
                elif built.returncode:
                    print('Build failed. Current app stays open; save another edit to retry.', flush=True)
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
