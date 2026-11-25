#!/bin/sh
# Builds FrameliftCore + loopback session test + inbox stress under a sanitizer and runs both.
# Usage: Tests/core_sanitize.sh asan|tsan [stress_seconds] [session_cycles]
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MODE=${1:-asan}; SECS=${2:-60}; CYCLES=${3:-20}
case "$MODE" in
  asan) SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined" ;;
  tsan) SAN="-fsanitize=thread" ;;
  *) echo "mode must be asan or tsan" >&2; exit 2 ;;
esac
OUT=build/core_$MODE; mkdir -p "$OUT"
INC="-ISources/FrameliftCore -ISources/FrameliftCore/include -ISources/FrameliftCore/RemotePlay/include -Ibuild/chiaki-dist/include -I/opt/homebrew/opt/openssl@3/include"
CXX="xcrun clang++ -std=c++20 -g -O1 -fno-omit-frame-pointer $SAN $INC"
OBJS=""
for src in Sources/FrameliftCore/*.cpp Sources/FrameliftCore/RemotePlay/*.cpp; do
  obj="$OUT/$(basename "$src" .cpp).o"; $CXX -c "$src" -o "$obj"; OBJS="$OBJS $obj"
done
L=build/chiaki-dist/lib
LIBS="$L/libchiaki.a $L/libcurl.a $L/libprotobuf-nanopb.a $L/libjerasure.a $L/libgf_complete.a $L/libopus.a $L/libjson-c.a $L/libminiupnpc.a $L/libevent.a $L/libevent_pthreads.a $L/libssl.a $L/libcrypto.a -framework CoreServices -framework SystemConfiguration -framework Security -lz"
xcrun clang -g -O1 $SAN -ISources/FrameliftCore/include -c Tests/core_session_test.c -o "$OUT/core_session_test.o"
$CXX "$OUT/core_session_test.o" $OBJS $LIBS -o "$OUT/core_session_test" 2>&1 | grep -v "ld: warning" || true
$CXX Tests/core_stress.cpp $(echo $OBJS | tr ' ' '\n' | grep -v Bridge.o | tr '\n' ' ') $LIBS -o "$OUT/core_stress" 2>&1 | grep -v "ld: warning" || true
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}
export UBSAN_OPTIONS=${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}
export TSAN_OPTIONS=${TSAN_OPTIONS:-halt_on_error=1:second_deadlock_stack=1}
echo "== $MODE: loopback session test ($CYCLES cycles)"; "$OUT/core_session_test" "$CYCLES"
echo "== $MODE: inbox stress (${SECS}s)"; "$OUT/core_stress" "$SECS"
echo "== $MODE: OK"
