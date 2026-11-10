"""Exercise the watcher with fake build/app processes; never starts a native GUI."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

RUNNER = Path(__file__).resolve().parents[1] / 'dev-app.py'


def until(check, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError('Timed out waiting for watcher')


class WatcherTests(unittest.TestCase):
    def test_source_inventory_includes_shaders_engine_and_resources_without_venv(self):
        spec = importlib.util.spec_from_file_location('dev_app_test', RUNNER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            module.ROOT = root = Path(directory)
            wanted = ['Coastline/Sources/Test.swift', 'Viewport/Sources/Test.metal',
                      'engine/coastline_engine/test.py', 'resources/test.step']
            for name in wanted + ['engine/.venv/lib/ignored.py']:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('test')
            found = module.sources()
            self.assertTrue(all(str(root / name) in found for name in wanted))
            self.assertNotIn(str(root / 'engine/.venv/lib/ignored.py'), found)

    def test_failed_build_keeps_app_and_success_replaces_it_without_duplicate_watchers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Coastline/Sources').mkdir(parents=True)
            source = root / 'Coastline/Sources/Test.swift'
            source.write_text('first')
            fakebin = root / 'bin'; fakebin.mkdir()
            app = root / 'fake-app.py'
            app.write_text('#!' + sys.executable + '\n' + '''
import os, signal, sys, time
from pathlib import Path
log = Path(os.environ['TEST_DEV_ROOT']) / 'app.log'
def record(value):
    with log.open('a') as f: f.write(value + '\\n')
record('start:' + sys.argv[0])
def stop(*_):
    record('stop')
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True: time.sleep(0.05)
''')
            app.chmod(0o755)
            for name, body in {
                'xcode-select': "print('/Applications/Xcode.app/Contents/Developer')",
                'swift': '''
import os, shutil, sys
from pathlib import Path
root = Path(os.environ['TEST_DEV_ROOT'])
if (root / 'fail').exists():
    print('intentional fake build failure')
    sys.exit(1)
target = root / 'Coastline/.build/debug/Coastline'
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'fake-app.py', target)
''',
            }.items():
                tool = fakebin / name
                tool.write_text('#!' + sys.executable + '\n' + body)
                tool.chmod(0o755)
            env = dict(os.environ, TEST_DEV_ROOT=str(root), PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
            command = [sys.executable, '-c',
                "import importlib.util,sys; from pathlib import Path; "
                "s=importlib.util.spec_from_file_location('dev',sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "m.ROOT=Path(sys.argv[2]); sys.argv=['dev-app.py','--watch']; m.main()",
                str(RUNNER), str(root)]
            def events():
                log = root / 'app.log'
                return log.read_text().splitlines() if log.exists() else []
            with (root / 'runner.log').open('w') as output:
                runner = subprocess.Popen(command, env=env, stdout=output, stderr=output)
                try:
                    until(lambda: len(events()) == 1)
                    self.assertTrue(events()[0].endswith('/build/dev/Coastline-Debug'))
                    duplicate = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
                    self.assertIn('already running', duplicate.stdout)
                    (root / 'fail').touch()
                    source.write_text('second, intentionally fails')
                    until(lambda: 'intentional fake build failure' in (root / 'build/dev/build.log').read_text())
                    self.assertEqual(len(events()), 1, 'failed builds must not close the current app')
                    (root / 'fail').unlink()
                    source.write_text('third, repaired')
                    until(lambda: len(events()) == 3)
                    self.assertEqual(events()[1], 'stop')
                    self.assertTrue(events()[2].startswith('start:'))
                finally:
                    runner.terminate()
                    runner.wait(timeout=8)
                self.assertEqual(events()[-1], 'stop')


if __name__ == '__main__':
    unittest.main()
