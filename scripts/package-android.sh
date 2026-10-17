#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f android/key.properties ]]; then
  echo 'Android release signing requires android/key.properties; debug signing is not allowed.' >&2
  exit 1
fi
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" ]]; then
  echo 'Set ANDROID_SDK_ROOT or ANDROID_HOME to an Android SDK with Build Tools 36.0.0.' >&2
  exit 1
fi
build_tools="$sdk_root/build-tools/36.0.0"
for tool in aapt apksigner zipalign; do
  if [[ ! -x "$build_tools/$tool" ]]; then
    echo "Android SDK Build Tools 36.0.0 is missing the required $tool command." >&2
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
verification_dir=$(mktemp -d)
trap 'rm -rf "$verification_dir"' EXIT
flutter --version --machine > "$verification_dir/flutter.json"
python3 - "$verification_dir/flutter.json" <<'PY'
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
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub --coverage
(
  cd android
  ./gradlew testDebugUnitTest
)
flutter build apk --release --no-pub

apk='build/app/outputs/flutter-apk/app-release.apk'
if [[ ! -f "$apk" ]]; then
  echo 'Flutter did not produce the expected release APK.' >&2
  exit 1
fi
if ! "$build_tools/aapt" dump badging "$apk" > "$verification_dir/badging" 2>&1; then
  echo 'Could not inspect the release APK manifest.' >&2
  exit 1
fi
python3 - "$verification_dir/badging" "$version" "$build_number" "$apk" <<'PY'
from pathlib import Path
import re
import sys
import zipfile

badging = Path(sys.argv[1]).read_text()
package = re.search(r"^package: (.+)$", badging, re.MULTILINE)
fields = dict(re.findall(r"(\w+)='([^']*)'", package[1])) if package else {}
expected = {"name": "dev.tamayura.app", "versionName": sys.argv[2], "versionCode": sys.argv[3]}
if any(fields.get(key) != value for key, value in expected.items()):
    sys.exit("Release APK application ID or version differs from pubspec.yaml.")
for field in ("sdkVersion", "targetSdkVersion"):
    if not re.search(rf"^{field}:'36'$", badging, re.MULTILINE):
        sys.exit("Release APK minimum and target Android SDK must both be 36.")
if re.search(r"^application-debuggable(?:\s|$)", badging, re.MULTILINE):
    sys.exit("Release APK must not be debuggable.")
expected_abis = {"armeabi-v7a", "arm64-v8a", "x86_64"}
native = re.search(r"^native-code: (.+)$", badging, re.MULTILINE)
if not native or set(re.findall(r"'([^']+)'", native[1])) != expected_abis:
    sys.exit("Release APK must contain exactly the three supported Android ABIs.")
try:
    with zipfile.ZipFile(sys.argv[4]) as archive:
        names = set(archive.namelist())
        if any(f"lib/{abi}/{library}" not in names for abi in expected_abis for library in ("libapp.so", "libflutter.so")):
            sys.exit("Release APK is missing a Flutter application or engine ABI.")
except (OSError, zipfile.BadZipFile):
    sys.exit("Release APK is not a readable ZIP archive.")
PY
if ! "$build_tools/apksigner" verify --verbose --print-certs "$apk" > "$verification_dir/signature" 2>&1; then
  echo 'Release APK signature verification failed.' >&2
  exit 1
fi
if grep -Eiq 'certificate DN:.*CN[[:space:]]*=[[:space:]]*Android Debug([,[:space:]]|$)' "$verification_dir/signature"; then
  echo 'An Android debug certificate cannot be used for a release APK.' >&2
  exit 1
fi
if ! "$build_tools/zipalign" -c -P 16 -v 4 "$apk" > "$verification_dir/alignment" 2>&1; then
  echo 'Release APK 16 KiB page alignment verification failed.' >&2
  exit 1
fi

output_dir="dist/$version"
archive_name="Tamayura-$version-android.apk"
mkdir -p "$output_dir"
cp "$apk" "$output_dir/$archive_name"
python3 - "$apk" "$output_dir/$archive_name" <<'PY'
import hashlib
from pathlib import Path
import sys

def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()

source, destination = map(Path, sys.argv[1:])
checksum = digest(destination)
if checksum != digest(source):
    sys.exit("The packaged Android APK differs from the verified build.")
(destination.parent / "SHA256SUMS-android").write_text(f"{checksum}  {destination.name}\n", encoding="ascii")
PY
echo "Android release package verified: $output_dir/$archive_name"
