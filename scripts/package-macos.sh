#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# A fresh Xcode installation may leave xcode-select on Command Line Tools.
# Select the standard installation for this script without changing the system.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcodebuild -version >/dev/null 2>&1 && \
  [[ -d '/Applications/Xcode.app/Contents/Developer' ]]; then
  export DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo '需要完整 Xcode；Command Line Tools 不能构建 Flutter macOS 应用。' >&2
  echo '安装并初始化 Xcode；非标准安装位置请设置 DEVELOPER_DIR 指向其 Contents/Developer。' >&2
  exit 1
fi

# Local preview only: the Xcode project uses ad-hoc signing. Public distribution
# requires the owner's Developer ID and notarization as documented in docs/发布.md.
export FLUTTER_SWIFT_PACKAGE_MANAGER=true
app_version=$(awk '/^version: / { print $2 }' pubspec.yaml)
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]; then
  echo 'pubspec.yaml 必须包含 version: 主版本.次版本.修订号+构建号。' >&2
  exit 1
fi
version="${app_version%+*}"
build_number="${app_version##*+}"
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
scripts/test-macos-native.sh
flutter build macos --release --no-pub

app_path='build/macos/Build/Products/Release/Tamayura.app'
test -d "$app_path"
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")
if [[ "$minimum" != '15.0' ]]; then
  echo "最低系统版本应为 15.0，实际为 $minimum。" >&2
  exit 1
fi
codesign --verify --deep --strict --all-architectures "$app_path"
# Swift plugin debug symbols can retain local source paths in a Release binary.
# Only rewrite this script's ad-hoc preview signatures; never replace a
# Developer ID or other certificate-backed signature with an ad-hoc signature.
architectures=$(lipo -archs "$app_path/Contents/MacOS/Tamayura")
for architecture in $architectures; do
  signature=$(codesign --display --arch "$architecture" --verbose=4 "$app_path" 2>&1)
  if ! grep -Fxq 'Signature=adhoc' <<< "$signature"; then
    echo '仅支持处理 ad-hoc 本地试用签名；拒绝修改其他类型的应用签名。' >&2
    exit 1
  fi
done
xcrun strip -S "$app_path/Contents/MacOS/Tamayura"
# Apply the declared Release permissions rather than retaining Xcode's injected
# get-task-allow entitlement. Keep all other existing signing metadata.
codesign --force --sign - \
  --entitlements macos/Runner/Release.entitlements \
  --preserve-metadata=identifier,requirements,flags,runtime "$app_path"
codesign --verify --deep --strict --all-architectures "$app_path"
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
if [[ "$actual_version" != "$version" || "$actual_build" != "$build_number" ]]; then
  echo "应用版本与 pubspec 不一致：$actual_version+$actual_build，预期 $app_version。" >&2
  exit 1
fi
for binary in "$app_path/Contents/MacOS/Tamayura" \
  "$app_path/Contents/Frameworks/App.framework/Versions/A/App"; do
  architectures=$(lipo -archs "$binary")
  for architecture in arm64 x86_64; do
    if [[ " $architectures " != *" $architecture "* ]]; then
      echo "缺少 $architecture 架构：$binary" >&2
      exit 1
    fi
  done
done

output_dir="dist/$version"
archive_name="Tamayura-$version-macos.zip"
mkdir -p "$output_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive_name"
(
  cd "$output_dir"
  # The combined Android/macOS release manifest is maintained by the release
  # process. Repackaging macOS must not overwrite its Android checksum.
  shasum -a 256 "$archive_name" > SHA256SUMS-macos
  shasum -a 256 -c SHA256SUMS-macos
)
echo "本地试用版已打包：$output_dir/$archive_name（未公证）"
