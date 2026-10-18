#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS native tests require macOS 15+ and Xcode Command Line Tools.' >&2
  exit 1
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tamayura-swift-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/tamayura-swift-module-cache}" \
  "$repo_root/macos/Runner/AppText.swift" \
  "$repo_root/macos/Runner/StorageCore.swift" \
  "$repo_root/macos/Runner/DirectoryBookmarks.swift" \
  "$repo_root/macos/Runner/MediaPreview.swift" \
  "$repo_root/macos/Tests/StorageCoreTests.swift" \
  -o "$test_dir/storage-tests"
"$test_dir/storage-tests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/tamayura-swift-module-cache}" \
  "$repo_root/macos/Runner/AppText.swift" \
  "$repo_root/macos/Runner/StorageCore.swift" \
  "$repo_root/macos/Runner/DirectoryBookmarks.swift" \
  "$repo_root/macos/Runner/MediaPreview.swift" \
  "$repo_root/macos/Tests/AppTextTests.swift" \
  -o "$test_dir/app-text-tests"
"$test_dir/app-text-tests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/tamayura-swift-module-cache}" \
  "$repo_root/macos/Runner/NetworkActivity.swift" \
  "$repo_root/macos/Tests/NetworkActivityTests.swift" \
  -o "$test_dir/network-activity-tests"
"$test_dir/network-activity-tests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/tamayura-swift-module-cache}" \
  "$repo_root/macos/Runner/AppText.swift" \
  "$repo_root/macos/Runner/DesktopStatusItem.swift" \
  "$repo_root/macos/Tests/DesktopStatusItemTests.swift" \
  -o "$test_dir/desktop-status-tests"
"$test_dir/desktop-status-tests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/tamayura-swift-module-cache}" \
  "$repo_root/macos/Runner/ReleasePage.swift" \
  "$repo_root/macos/Tests/ReleasePageTests.swift" \
  -o "$test_dir/release-page-tests"
"$test_dir/release-page-tests"

plutil -lint "$repo_root/macos/Runner/Info.plist" \
  "$repo_root"/macos/Runner/*.lproj/InfoPlist.strings \
  "$repo_root/macos/Runner/DebugProfile.entitlements" \
  "$repo_root/macos/Runner/Release.entitlements" \
  "$repo_root/macos/Runner.xcodeproj/project.pbxproj"
python3 - "$repo_root" <<'PYCONFIG'
from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys
root = Path(sys.argv[1]) / 'macos'
info = plistlib.loads((root / 'Runner/Info.plist').read_bytes())
assert info['LSMinimumSystemVersion'] == '15.0'
assert '_tamayura._tcp' in info['NSBonjourServices']
assert info['NSLocalNetworkUsageDescription'] and info['NSCameraUsageDescription']
for config in ['DebugProfile', 'Release']:
    entitlements = plistlib.loads((root / f'Runner/{config}.entitlements').read_bytes())
    for key in ['app-sandbox', 'network.client', 'network.server', 'files.user-selected.read-write', 'files.bookmarks.app-scope', 'device.camera']:
        assert entitlements[f'com.apple.security.{key}'], f'{config}: missing {key}'
project = (root / 'Runner.xcodeproj/project.pbxproj').read_text()
assert set(re.findall(r'MACOSX_DEPLOYMENT_TARGET = ([^;]+);', project)) == {'15.0'}
for source in (root / 'Runner').glob('*.swift'):
    assert f'{source.name} in Sources' in project, f'{source.name} is not compiled by Runner'
# System permission prompts follow the system language with the same texts.
assert 'InfoPlist.strings in Resources' in project
for language in ['en', 'zh-Hans', 'ja']:
    assert f'{language}.lproj/InfoPlist.strings' in project, f'{language} permission texts are not bundled'
    strings = json.loads(subprocess.run(
        ['plutil', '-convert', 'json', '-o', '-', str(root / f'Runner/{language}.lproj/InfoPlist.strings')],
        check=True, capture_output=True).stdout)
    assert set(strings) == {'NSCameraUsageDescription', 'NSLocalNetworkUsageDescription'}, language
    assert all(strings.values()), language
print('PASS macOS project registration, minimum version and permissions')
PYCONFIG
