#!/usr/bin/env bash
set -euo pipefail

# Usage: build-native.sh <darwin|linux|windows|android> <arch|ABI> <output>
# Android requires ANDROID_NDK_HOME pointing at an installed NDK. Native API
# floor defaults to 35; the host app still enforces Android 36 as its minimum.
# The build
# stores no credentials; downloaded module versions are pinned in native/go.sum.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_os="${1:?target OS required}"
target_arch="${2:?target architecture required}"
output="${3:?absolute output path required}"
case "$output" in /*|[A-Za-z]:*) ;; *) echo 'Output must be absolute.' >&2; exit 2;; esac
mkdir -p "$(dirname "$output")"
cd "$root/native"
export GOTOOLCHAIN=go1.27.4
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
case "$target_os" in
  android)
    : "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an installed Android NDK}"
    case "$(uname -s)" in Darwin) ndk_host=darwin-x86_64;; Linux) ndk_host=linux-x86_64;; *) echo 'Unsupported Android build host.' >&2; exit 2;; esac
    native_api="${ANDROID_API:-35}"
    case "$target_arch" in
      arm64-v8a|arm64) go_arch=arm64; compiler="aarch64-linux-android${native_api}-clang";;
      armeabi-v7a|arm) go_arch=arm; compiler="armv7a-linux-androideabi${native_api}-clang"; export GOARM=7;;
      x86_64|amd64) go_arch=amd64; compiler="x86_64-linux-android${native_api}-clang";;
      *) echo 'Unsupported Android ABI.' >&2; exit 2;;
    esac
    export CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ndk_host/bin/$compiler"
    export CGO_ENABLED=1 GOOS=android GOARCH="$go_arch"
    native_package=./cmd/flutter-tailscale-mobile
    go build -trimpath -buildmode=c-shared -ldflags='-s -w -buildid=' -o "$output" "$native_package"
    ;;
  darwin|linux|windows)
    export CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch"
    native_package=./cmd/flutter-tailscale
    go build -trimpath -ldflags='-s -w -buildid=' -o "$output" "$native_package"
    ;;
  *) echo 'Unsupported target OS.' >&2; exit 2;;
esac
python3 "$root/scripts/collect-licenses.py" "$output.NOTICES.txt" "$native_package"
