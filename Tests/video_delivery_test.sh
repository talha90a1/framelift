#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MODE=${1:-plain}
case "$MODE" in
    plain) SAN="" ;;
    asan) SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined" ;;
    tsan) SAN="-fsanitize=thread" ;;
    *) echo "usage: $0 [plain|asan|tsan]" >&2; exit 2 ;;
esac
OUT="build/video_delivery_$MODE"
mkdir -p "$OUT"
xcrun clang++ -std=c++20 -g -O1 -fno-omit-frame-pointer $SAN \
    -ISources/VeyraCore -ISources/VeyraCore/veyra/include \
    Tests/video_delivery_test.cpp Sources/VeyraCore/veyra/SessionInbox.cpp \
    Sources/VeyraCore/veyra/VideoIngress.cpp Sources/VeyraCore/veyra/AnnexB.cpp \
    Sources/VeyraCore/veyra/Timeline.cpp Sources/VeyraCore/veyra/Validation.cpp \
    -o "$OUT/video_delivery_test"
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}
export UBSAN_OPTIONS=${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}
export TSAN_OPTIONS=${TSAN_OPTIONS:-halt_on_error=1:second_deadlock_stack=1}
"$OUT/video_delivery_test"
