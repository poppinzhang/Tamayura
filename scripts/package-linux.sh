#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd -P)"

if [[ "$(uname -s)" != Linux ]]; then
  echo 'Build the Linux package on Linux: Ubuntu 24.04 LTS or an equivalent glibc 2.39 / GTK 3.24 host.' >&2
  exit 1
fi
case "$(uname -m)" in
  x86_64) arch=x64 elf_machine=62 ;;
  aarch64 | arm64) arch=arm64 elf_machine=183 ;;
  *)
    echo "Unsupported Linux build architecture: $(uname -m)." >&2
    exit 1
    ;;
esac
for tool in git flutter dart cmake pkg-config python3 objdump readelf ldd tar gzip sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "The Linux package build requires $tool." >&2
    exit 1
  fi
done
app_version=$(awk '/^version: / { print $2 }' pubspec.yaml)
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]; then
  echo 'pubspec.yaml must contain version: major.minor.patch+build.' >&2
  exit 1
fi
version="${app_version%+*}"
build_number="${app_version##*+}"
# Archive timestamps follow the source commit, so a rebuild differs only where
# the compiled files do.
source_date=$(git log -1 --format=%ct 2>/dev/null || date +%s)

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tamayura-linux-package.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
flutter --version --machine > "$work_dir/flutter.json"
python3 - "$work_dir/flutter.json" <<'PY'
import json
from pathlib import Path
import sys

try:
    sdk = json.loads(Path(sys.argv[1]).read_text())
    flutter_version = sdk.get("flutterVersion")
    dart_version = sdk.get("dartSdkVersion", "").split()
except (OSError, ValueError, AttributeError):
    sys.exit("Could not determine the Flutter / Dart SDK version.")
if flutter_version != "3.47.6" or not dart_version or dart_version[0] != "3.13.5":
    sys.exit("Use the project's Flutter 3.47.6 / Dart 3.13.5 SDK for release builds.")
PY

# The Flutter tool records the absolute path of the plugin registrant in the
# AOT snapshot. Build a neutral temporary copy of the checkout (tracked and
# unignored files), so the package never names the checkout or a home folder.
source_dir="$work_dir/source"
python3 - "$repo_root" "$source_dir" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, target = Path(sys.argv[1]), Path(sys.argv[2])
listing = subprocess.run(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    cwd=root, check=True, capture_output=True).stdout
for name in sorted(set(filter(None, os.fsdecode(listing).split("\0")))):
    source, destination = root / name, target / name
    if source.is_symlink():
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(os.readlink(source), destination)
    elif source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    # Files deleted from the working tree and nested repositories are skipped.
PY

(
  cd "$source_dir"
  flutter pub get --enforce-lockfile
  dart format --output=none --set-exit-if-changed lib test
  flutter analyze --no-pub
  flutter test --no-pub
  scripts/test-linux-native.sh
  flutter build linux --release --no-pub
)

bundle="$source_dir/build/linux/$arch/release/bundle"
if [[ ! -x "$bundle/tamayura" ]]; then
  echo 'Flutter did not produce the expected Linux release bundle.' >&2
  exit 1
fi
python3 - "$bundle" "$version" "$build_number" "$arch" "$elf_machine" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys

bundle, version, build_number, arch = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
elf_machine = int(sys.argv[5])
sizes = [16, 22, 24, 32, 48, 64, 128, 256, 512]
required = [
    "tamayura", "install-desktop-entry.sh", "lib/libapp.so", "lib/libflutter_linux_gtk.so",
    "lib/libsqlite3.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin",
    "data/flutter_assets/NativeAssetsManifest.json", "data/flutter_assets/NOTICES.Z",
    "data/flutter_assets/version.json",
] + [f"data/icons/hicolor/{size}x{size}/apps/dev.tamayura.app.png" for size in sizes] + [
    f"data/tray/hibiki-{variant}-{size}.png"
    for variant in ["black", "white"]
    for size in [16, 20, 24, 32, 40, 48, 64]
]
for name in required:
    if not (bundle / name).is_file():
        sys.exit(f"The release bundle is incomplete: {name}")
for name in ("tamayura", "install-desktop-entry.sh"):
    if not os.access(bundle / name, os.X_OK):
        sys.exit(f"{name} must be executable.")
paths = sorted(bundle.rglob("*"))
if any(path.is_symlink() for path in paths):
    sys.exit("The release bundle must not contain symlinks.")
names = {path.relative_to(bundle).as_posix() for path in paths if path.is_file()}
# Flutter tests leave a host-only manifest with absolute paths next to the
# native assets, and debug builds leave a kernel snapshot with source paths.
leftovers = [name for name in names if name.endswith("native_assets.json") or name.rsplit("/", 1)[-1] in
             ("kernel_blob.bin", "isolate_snapshot_data", "vm_snapshot_data")]
if leftovers:
    sys.exit("The release bundle contains test or debug files: " + ", ".join(sorted(leftovers)))
info = json.loads((bundle / "data/flutter_assets/version.json").read_text())
if (info.get("version"), info.get("build_number")) != (version, build_number):
    sys.exit("The bundle version differs from pubspec.yaml.")
assets = json.loads((bundle / "data/flutter_assets/NativeAssetsManifest.json").read_text())
sqlite = assets.get("native-assets", {}).get(f"linux_{arch}", {})
if sqlite.get("package:sqlite3/src/ffi/libsqlite3.g.dart") != ["absolute", "libsqlite3.so"]:
    sys.exit("The app must load the SQLite library shipped in the bundle.")

def version_tuple(text):
    return tuple(int(part) for part in text.split("."))

# Ubuntu 24.04 LTS provides glibc 2.39 and the GCC 14 C++ runtime.
limits = {"GLIBC": "2.39", "GLIBCXX": "3.4.33", "CXXABI": "1.3.15"}
elf_files = [path for path in paths if path.is_file() and path.read_bytes()[:4] == b"\x7fELF"]
if len(elf_files) < 4:
    sys.exit("The release bundle is missing native libraries.")
for path in elf_files:
    name = path.relative_to(bundle).as_posix()
    header = path.read_bytes()[:20]
    if header[4] != 2 or header[5] != 1 or int.from_bytes(header[18:20], "little") != elf_machine:
        sys.exit(f"{name} is not a 64-bit {arch} binary.")
    symbols = subprocess.run(["objdump", "-T", str(path)], check=True, capture_output=True, text=True).stdout
    for prefix, limit in limits.items():
        found = re.findall(rf"\b{prefix}_([0-9]+(?:\.[0-9]+)+)\b", symbols)
        if found and max(map(version_tuple, found)) > version_tuple(limit):
            sys.exit(f"{name} requires a newer {prefix} than Ubuntu 24.04 provides.")
    dynamic = subprocess.run(["readelf", "-d", str(path)], check=True, capture_output=True, text=True).stdout
    for search_path in re.findall(r"\((?:RPATH|RUNPATH)\)\s+Library r(?:un)?path: \[([^\]]*)\]", dynamic):
        if any(not entry.startswith("$ORIGIN") for entry in search_path.split(":")):
            sys.exit(f"{name} has a library search path outside the bundle.")
    if name == "tamayura" and "Library runpath: [$ORIGIN/lib]" not in dynamic:
        sys.exit("The executable must load its libraries from the bundle lib folder.")
    linked = subprocess.run(["ldd", str(path)], capture_output=True, text=True).stdout
    if "not found" in linked:
        sys.exit(f"{name} depends on a library this host does not provide.")
print(f"PASS Linux {arch} bundle files, version {version}+{build_number}, ELF and library requirements")
PY

archive_root="Tamayura-$version-linux-$arch"
archive_name="$archive_root.tar.gz"
staging="$work_dir/staging"
mkdir -p "$staging"
cp -a "$bundle" "$staging/$archive_root"
tar --sort=name --mtime="@$source_date" --owner=0 --group=0 --numeric-owner \
  --mode='u+rwX,go+rX,go-w' -C "$staging" -cf - "$archive_root" | gzip -n -9 > "$work_dir/$archive_name"

# Verify the archive as a user receives it: entry types and names, contents,
# environment paths, and a launch that loads the bundled SQLite.
extracted="$work_dir/extracted"
mkdir -p "$extracted"
gzip -t "$work_dir/$archive_name"
tar -tvzf "$work_dir/$archive_name" > "$work_dir/listing"
tar -xzf "$work_dir/$archive_name" -C "$extracted"
python3 - "$work_dir/listing" "$archive_root" "$bundle" "$extracted" "$repo_root" "${HOME:-}" <<'PY'
import filecmp
import os
from pathlib import Path
import sys

listing, root, bundle, extracted = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])
for line in listing.read_text().splitlines():
    kind, name = line[0], line.split()[-1]
    if kind not in "-d" or not (name == f"{root}/" or name.startswith(f"{root}/")) or "/../" in f"/{name}/":
        sys.exit("The archive may contain only regular files and folders under its top-level folder.")
if [entry.name for entry in extracted.iterdir()] != [root]:
    sys.exit("The archive must contain exactly one top-level folder.")
unpacked = extracted / root
expected = sorted(path.relative_to(bundle).as_posix() for path in bundle.rglob("*"))
actual = sorted(path.relative_to(unpacked).as_posix() for path in unpacked.rglob("*"))
if expected != actual:
    sys.exit("The archive file list differs from the verified bundle.")
for name in expected:
    source, copy = bundle / name, unpacked / name
    if source.is_file() and (not filecmp.cmp(source, copy, shallow=False) or
                             os.access(source, os.X_OK) != os.access(copy, os.X_OK)):
        sys.exit(f"The archived {name} differs from the verified bundle.")
# Paths of this machine: the checkout and the home folder, which also cover a
# temporary build folder inside either of them.
markers = {(path.rstrip("/") + "/").encode() for path in sys.argv[5:7] if path.rstrip("/")}
for path in [listing, *sorted(unpacked.rglob("*"))]:
    if path.is_file():
        content = path.read_bytes()
        if any(marker in content for marker in markers):
            sys.exit("The package contains a path of this build machine; build from a neutral TMPDIR such as /tmp.")
print("PASS archive entries, contents and environment privacy")
PY

if command -v xvfb-run >/dev/null 2>&1 && command -v dbus-run-session >/dev/null 2>&1; then
  smoke_home="$work_dir/smoke-home"
  mkdir -p "$smoke_home"
  cat > "$work_dir/smoke.sh" <<'SH'
#!/bin/bash
# Starts the extracted app with an empty profile and waits until it has
# loaded the SQLite library shipped next to it.
app="$1"
library="$(realpath "$(dirname "$app")/lib/libsqlite3.so")"
"$app" > "$HOME/app.log" 2>&1 &
pid=$!
for _ in $(seq 120); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo 'The packaged app exited during startup.' >&2
    exit 1
  fi
  if grep -qF " $library" "/proc/$pid/maps"; then
    kill "$pid"
    wait "$pid" 2>/dev/null
    exit 0
  fi
  sleep 0.5
done
kill "$pid"
echo 'The packaged app did not load its bundled SQLite library.' >&2
exit 1
SH
  chmod 755 "$work_dir/smoke.sh"
  if ! HOME="$smoke_home" XDG_CONFIG_HOME="$smoke_home/.config" XDG_DATA_HOME="$smoke_home/.local/share" \
    XDG_CACHE_HOME="$smoke_home/.cache" XDG_STATE_HOME="$smoke_home/.local/state" \
    xvfb-run -a dbus-run-session -- "$work_dir/smoke.sh" "$extracted/$archive_root/tamayura"; then
    tail -n 20 "$smoke_home/app.log" >&2 || true
    exit 1
  fi
  echo 'PASS the extracted app starts and loads its bundled SQLite'
else
  echo 'SKIP launch check: install xvfb and dbus to start the extracted app'
fi

output_dir="dist/$version"
mkdir -p "$output_dir"
mv -f "$work_dir/$archive_name" "$output_dir/$archive_name"
(
  cd "$output_dir"
  # Other platforms keep their own checksum files; the release workflow
  # combines them into SHA256SUMS and release.json.
  sha256sum "$archive_name" > "SHA256SUMS-linux-$arch"
  sha256sum -c "SHA256SUMS-linux-$arch"
)
echo "Linux $arch package: $output_dir/$archive_name"
echo 'Unsigned tar.gz for local testing. Extract the whole folder before running tamayura.'
