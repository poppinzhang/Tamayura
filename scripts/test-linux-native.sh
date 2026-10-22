#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
  echo 'Linux native tests require Linux with CMake and the GTK 3, GdkPixbuf and Avahi client development packages.' >&2
  exit 1
fi

# Sanitizers catch memory errors in the file, image and D-Bus code. Set
# TAMAYURA_SANITIZE=OFF on a host without their runtime libraries.
build_dir="$repo_root/build/linux-native-tests"
generator=()
if command -v ninja >/dev/null 2>&1; then
  generator=(-G Ninja)
fi
cmake -S "$repo_root/linux/tests" -B "$build_dir" "${generator[@]}" \
  -DCMAKE_BUILD_TYPE=Debug -DTAMAYURA_SANITIZE="${TAMAYURA_SANITIZE:-ON}"
cmake --build "$build_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tamayura-linux-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
ctest --test-dir "$build_dir" --output-on-failure --no-tests=error | tee "$work_dir/ctest.log"
# Tray and discovery tests skip without dbus-daemon or avahi-daemon. CI sets
# TAMAYURA_LINUX_TESTS_NO_SKIP=1 so that a missing service cannot pass.
if [[ "${TAMAYURA_LINUX_TESTS_NO_SKIP:-0}" == 1 ]] && grep -q 'Skipped' "$work_dir/ctest.log"; then
  echo 'Native tests were skipped; start dbus-daemon and avahi-daemon.' >&2
  exit 1
fi

python3 - "$repo_root" <<'PYCONFIG'
from pathlib import Path
import re
import struct
import sys

root = Path(sys.argv[1]) / 'linux'
runner = (root / 'runner/CMakeLists.txt').read_text()
for source in sorted((root / 'runner').glob('*.cc')):
    assert f'"{source.name}"' in runner, f'{source.name} is not compiled by the runner'
tests = (root / 'tests/CMakeLists.txt').read_text()
for source in sorted((root / 'tests').glob('*_test.cc')):
    assert re.search(rf'\s{re.escape(source.name)}\s', tests), f'{source.name} is not a registered test'
project = (root / 'CMakeLists.txt').read_text()
script = (root / 'packaging/install-desktop-entry.sh').read_text()
assert 'set(APPLICATION_ID "dev.tamayura.app")' in project
assert 'app_id=dev.tamayura.app\n' in script
# Flutter tests leave a manifest with host paths next to the native assets.
assert 'PATTERN "native_assets.json" EXCLUDE' in project
sizes = [16, 22, 24, 32, 48, 64, 128, 256, 512]
assert f'foreach(icon_size {" ".join(map(str, sizes))})' in project
assert f'sizes="{" ".join(map(str, sizes))}"' in script
for size in sizes:
    data = (root / f'runner/resources/icons/{size}.png').read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', f'{size}.png is not a PNG'
    assert struct.unpack('>II', data[16:24]) == (size, size), f'{size}.png is not {size}x{size}'
print('PASS Linux project registration, application ID and icons')
PYCONFIG

# Install the desktop entry for a stand-in bundle whose path needs every kind
# of Desktop Entry escaping, then launch it through GLib when available.
bundle="$work_dir/My \"Apps\" \$HOME \`id\` \\x/Tamayura"
mkdir -p "$bundle"
cp "$repo_root/linux/packaging/install-desktop-entry.sh" "$bundle/"
printf '#!/bin/sh\nprintf %%s "$0" > "$TAMAYURA_LAUNCH_MARKER"\n' > "$bundle/tamayura"
chmod 755 "$bundle/tamayura"
for size in 16 22 24 32 48 64 128 256 512; do
  mkdir -p "$bundle/data/icons/hicolor/${size}x${size}/apps"
  cp "$repo_root/linux/runner/resources/icons/$size.png" \
    "$bundle/data/icons/hicolor/${size}x${size}/apps/dev.tamayura.app.png"
done
export XDG_DATA_HOME="$work_dir/data"
entry="$XDG_DATA_HOME/applications/dev.tamayura.app.desktop"
for language in zh ja en; do
  LC_ALL='' LANGUAGE="$language" "$bundle/install-desktop-entry.sh" > "$work_dir/added-$language"
done
grep -q '已将玉响添加到应用菜单' "$work_dir/added-zh"
grep -q 'Tamayura をアプリケーションメニューに追加しました' "$work_dir/added-ja"
grep -q 'Added Tamayura to the application menu' "$work_dir/added-en"
test "$(find "$XDG_DATA_HOME/icons" -name dev.tamayura.app.png | wc -l)" -eq 9
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate --no-hints "$entry"
else
  echo 'SKIP desktop-file-validate is not installed'
fi
if command -v gio >/dev/null 2>&1; then
  export TAMAYURA_LAUNCH_MARKER="$work_dir/launched"
  gio launch "$entry"
  for _ in $(seq 50); do
    [[ -s "$TAMAYURA_LAUNCH_MARKER" ]] && break
    sleep 0.1
  done
  if [[ "$(cat "$TAMAYURA_LAUNCH_MARKER" 2>/dev/null)" != "$bundle/tamayura" ]]; then
    echo 'The desktop entry did not launch the bundle executable.' >&2
    exit 1
  fi
else
  echo 'SKIP gio is not installed; the desktop entry was not launched'
fi
# A % in the path would be hidden by GLib, so the script refuses it and keeps
# the existing entry.
percent="$work_dir/100%/Tamayura"
mkdir -p "$(dirname "$percent")"
cp -R "$bundle" "$percent"
cp "$entry" "$work_dir/entry-before"
if LC_ALL='' LANGUAGE=en "$percent/install-desktop-entry.sh" 2> "$work_dir/percent"; then
  echo 'A bundle path with % must be rejected.' >&2
  exit 1
fi
grep -q 'contains % or a line break' "$work_dir/percent"
cmp "$entry" "$work_dir/entry-before"
"$bundle/install-desktop-entry.sh" --remove > /dev/null
test ! -e "$entry"
test -z "$(find "$XDG_DATA_HOME/icons" -name dev.tamayura.app.png)"
echo 'PASS Linux desktop entry install, launch and removal'
