#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$root/third_party/flutter_tailscale"
case "$(uname -s)" in Darwin) target_os=darwin;; Linux) target_os=linux;; *) echo 'Run on macOS or Linux.' >&2; exit 2;; esac
case "$(uname -m)" in arm64|aarch64) target_arch=arm64;; x86_64) target_arch=amd64;; *) exit 2;; esac
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
cd "$sdk/native"
go test -race ./...
bash "$sdk/scripts/build-native.sh" "$target_os" "$target_arch" "$temporary/flutter-tailscale-bridge"
python3 "$sdk/scripts/smoke-native.py" "$temporary/flutter-tailscale-bridge"
cd "$sdk"
flutter pub get --enforce-lockfile
flutter analyze --no-pub
FLUTTER_TAILSCALE_HELPER="$temporary/flutter-tailscale-bridge" flutter test --no-pub
