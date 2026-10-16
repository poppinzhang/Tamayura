#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v protoc >/dev/null || { echo '请先安装 Protocol Buffers protoc 编译器' >&2; exit 1; }
dart pub global activate protoc_plugin 22.5.0
mkdir -p lib/network/generated
protoc --plugin="protoc-gen-dart=${PUB_CACHE:-$HOME/.pub-cache}/bin/protoc-gen-dart" --dart_out=grpc:lib/network/generated -Iproto proto/media.proto
