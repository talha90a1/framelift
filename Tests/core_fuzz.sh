#!/bin/sh
# libFuzzer target for the reused Veyra core, built with Homebrew LLVM (Apple clang ships no libFuzzer).
# Usage: Tests/core_fuzz.sh [seconds]
set -eu
cd "$(dirname "$0")/.."
SECS=${1:-60}
CLANG=${CLANG:-/opt/homebrew/opt/llvm/bin/clang++}
OUT=build/core_fuzz; mkdir -p "$OUT/corpus"
SDK=$(DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun --show-sdk-path)
"$CLANG" -std=c++20 -g -O1 -isysroot "$SDK" -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined \
  -ISources/FrameliftCore -ISources/FrameliftCore/RemotePlay/include Tests/core_fuzz.cpp Sources/FrameliftCore/LogRedaction.cpp \
  Sources/FrameliftCore/RemotePlay/AnnexB.cpp Sources/FrameliftCore/RemotePlay/Validation.cpp Sources/FrameliftCore/RemotePlay/Timeline.cpp \
  Sources/FrameliftCore/RemotePlay/VideoIngress.cpp Sources/FrameliftCore/RemotePlay/SessionInbox.cpp -o "$OUT/core_fuzz"
"$OUT/core_fuzz" -max_total_time="$SECS" -max_len=4096 -print_final_stats=1 "$OUT/corpus"
