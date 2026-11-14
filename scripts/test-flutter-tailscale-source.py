#!/usr/bin/env python3
"""The SDK dependency snapshot must never copy native state or build outputs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True

SPEC = importlib.util.spec_from_file_location('snapshot', Path(__file__).with_name('sync-flutter-tailscale.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SnapshotTests(unittest.TestCase):
    def test_source_only_and_digest_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / 'sdk', root / 'snapshot'
            files = {
                'pubspec.yaml': 'name: flutter_tailscale\n',
                'native/go.mod': 'module example.test/sdk\n',
                'native/go.sum': 'dependency digest\n',
                'native/bridge/runtime.go': 'package bridge\n',
                'lib/flutter_tailscale.dart': '// public API\n',
                'test/fixtures/test-cert.pem': 'PUBLIC TEST CERTIFICATE',
                'test/fixtures/test-key.pem': 'PUBLIC TEST KEY',
                'test/fixtures/private.pem': 'SECRET',
                'native/node/state.json': 'SECRET',
                'native/node/tailscaled.state': 'SECRET',
                'native/build/private.go': 'SECRET',
                'android/local.properties': 'SECRET',
                'android/key.properties': 'SECRET',
                'lib/.dart_tool/generated.dart': 'SECRET',
                'scripts/private.py': 'SECRET',
            }
            for name, content in files.items():
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            MODULE.snapshot(source, output)
            manifest = json.loads((output / 'SOURCE_SNAPSHOT.json').read_text())
            self.assertEqual(len(manifest['sha256']), 7)
            self.assertTrue((output / 'native/bridge/runtime.go').is_file())
            self.assertTrue((output / 'test/fixtures/test-cert.pem').is_file())
            self.assertTrue((output / 'test/fixtures/test-key.pem').is_file())
            self.assertNotIn(str(source), (output / 'SOURCE_SNAPSHOT.json').read_text())
            for path in output.rglob('*'):
                if path.is_file():
                    self.assertNotIn('SECRET', path.read_text())

    def test_source_symlink_is_rejected_before_destination_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / 'sdk', root / 'snapshot'
            (source / 'lib').mkdir(parents=True)
            secret = root / 'outside.dart'
            secret.write_text('private')
            (source / 'lib/linked.dart').symlink_to(secret)
            output.mkdir()
            preserved = output / 'keep.txt'
            preserved.write_text('existing')
            with self.assertRaisesRegex(ValueError, 'symlinks'):
                MODULE.snapshot(source, output)
            self.assertEqual(preserved.read_text(), 'existing')


if __name__ == '__main__':
    unittest.main()
