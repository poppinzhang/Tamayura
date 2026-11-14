#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$root/third_party/flutter_tailscale"
output="${TARGET_BUILD_DIR:?}/${EXECUTABLE_FOLDER_PATH:?}/flutter-tailscale-bridge"
work="$root/build/tailscale/macos"
mkdir -p "$work" "$(dirname "$output")"
# Xcode launched from Finder may not inherit the developer shell's PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
for architecture in arm64 amd64; do
  bash "$sdk/scripts/build-native.sh" darwin "$architecture" "$work/$architecture"
done
lipo -create "$work/arm64" "$work/amd64" -output "$output"
chmod 755 "$output"
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
mkdir -p "$resources"
# Contents/MacOS is a code-signing location; text belongs in Resources.
rm -f "$output.NOTICES.txt"
cp "$work/arm64.NOTICES.txt" "$resources/flutter-tailscale-NOTICES.txt"
# A helper inherits the app sandbox and its network entitlements.
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$root/macos/Runner/TailscaleHelper.entitlements" "$output"
