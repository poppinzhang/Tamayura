#!/usr/bin/env python3
"""Copy a reviewable source snapshot of the reusable SDK; never copy binaries/state."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml',
              'README.md', 'README.zh-CN.md', 'CHANGELOG.md', 'LICENSE',
              'THIRD_PARTY_NOTICES.txt'}
EXACT_FILES = ROOT_FILES | {
    'native/go.mod', 'native/go.sum', 'native/README.md',
    'android/build.gradle', 'android/settings.gradle',
    'android/src/main/AndroidManifest.xml',
    'scripts/build-native.sh', 'scripts/collect-licenses.py',
    'scripts/smoke-native.py',
    # Public test-only TLS credentials, never used by an application node.
    'test/fixtures/test-cert.pem', 'test/fixtures/test-key.pem',
}
EXCLUDED = {'build', '.dart_tool', '.gradle', '.kotlin', '.git', '__pycache__',
            'dist', '.DS_Store', 'local.properties', 'key.properties'}


def snapshot(source: Path, destination: Path):
    files = {}
    for path in sorted(source.rglob('*')):
        relative = path.relative_to(source)
        if any(part in EXCLUDED for part in relative.parts):
            continue
        name = relative.as_posix()
        included = (name in EXACT_FILES or
                    relative.parts[0] in {'lib', 'test'} and path.suffix == '.dart' or
                    name.startswith(('native/bridge/', 'native/cmd/')) and path.suffix in {'.go', '.c', '.h'} or
                    name.startswith(('android/src/main/kotlin/', 'android/src/test/kotlin/')) and path.suffix == '.kt' or
                    relative.parts[0] == 'docs' and len(relative.parts) == 2 and path.suffix == '.md')
        if not included or path.is_dir():
            continue
        if path.is_symlink():
            raise ValueError('SDK snapshot cannot contain source symlinks')
        files[relative.as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if 'pubspec.yaml' not in files or 'native/go.sum' not in files:
        raise ValueError('Incomplete SDK source')
    # Only remove the generated destination; the independent source is untouched.
    if destination.exists():
        shutil.rmtree(destination)
    for name in files:
        output = destination / name
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, output)
    (destination / 'SOURCE_SNAPSHOT.json').write_text(json.dumps({
        'format': 1, 'project': 'Flutter-Tailscale',
        'description': 'Generated dependency snapshot. Edit the independent SDK and run scripts/sync-flutter-tailscale.py.',
        'sha256': files,
    }, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', nargs='?', type=Path,
                        default=ROOT.parent / 'Flutter-Tailscale')
    args = parser.parse_args()
    snapshot(args.source.resolve(), ROOT / 'third_party/flutter_tailscale')
