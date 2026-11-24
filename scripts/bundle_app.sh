#!/bin/zsh
# Builds Framelift in release mode and assembles an ad-hoc signed dist/Framelift.app.
# Prereq: scripts/build_chiaki.sh has staged build/chiaki-dist.
# Usage: scripts/bundle_app.sh [--debug] [--install]
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG=release
[[ " $* " == *" --debug "* ]] && CONFIG=debug

[[ -d build/chiaki-dist/lib ]] || { echo "build/chiaki-dist missing: run scripts/build_chiaki.sh first" >&2; exit 1; }

swift build -c "$CONFIG" --product Framelift
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
[[ -x "$BIN_DIR/Framelift" ]] || { echo "built executable not found in $BIN_DIR" >&2; exit 1; }

APP="$ROOT/dist/Framelift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Framelift" "$APP/Contents/MacOS/Framelift"
if [[ "${FRAMELIFT_STRIP:-0}" == 1 ]]; then
  BINARY="$APP/Contents/MacOS/Framelift"
  if codesign -d "$BINARY" >/dev/null 2>&1; then
    codesign --remove-signature "$BINARY"
  fi
  strip -S -x "$BINARY"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R licenses "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp -R Sources/Framelift/Render/Shaders "$APP/Contents/Resources/"

# chiaki and its deps are static archives; flag any dylib outside the OS that the app would need at runtime.
NON_SYSTEM_LIBS=$(otool -L "$APP/Contents/MacOS/Framelift" | awk 'NR>1 {print $1}' | grep -vE '^(/System/|/usr/lib/|@rpath/libswift)' || true)
if [[ -n "$NON_SYSTEM_LIBS" ]]; then
  echo "warning: the app links non-system dylibs (it will only run on machines that have them):" >&2
  echo "$NON_SYSTEM_LIBS" >&2
fi

# Sign with a stable identity so the Keychain (and Local Network/Automation consents) keep trusting the
# app across rebuilds; ad-hoc signatures change every build and re-trigger the prompts. Override with
# FRAMELIFT_SIGN_IDENTITY; falls back to ad-hoc when no Apple Development identity exists.
SIGN_ID="${FRAMELIFT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)}"
SIGN_ID="${SIGN_ID:--}"
codesign --force --deep -s "$SIGN_ID" --entitlements Resources/Framelift.entitlements "$APP"
codesign --verify --strict "$APP"
echo "signed with: ${SIGN_ID}"

# --install: copy to /Applications (stable location; same signing identity keeps Keychain access).
if [[ " $* " == *" --install "* ]]; then
  if pgrep -xq Framelift; then echo "Framelift is running; quit it, then re-run with --install" >&2; exit 1; fi
  rm -rf /Applications/Framelift.app   # replace, so files removed from the build do not linger
  ditto "$APP" /Applications/Framelift.app
  echo "installed /Applications/Framelift.app"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "built $APP ($CONFIG)"
echo "run: open \"$APP\""
