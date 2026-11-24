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
cp Sources/Framelift/App/DualSensePairing.usdz "$APP/Contents/Resources/"

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORK"
rm -rf "$FRAMEWORK/Versions/B/XPCServices" "$FRAMEWORK/XPCServices"

# chiaki and its deps are static archives; flag any dylib outside the OS that the app would need at runtime.
NON_SYSTEM_LIBS=$(otool -L "$APP/Contents/MacOS/Framelift" | awk 'NR>1 {print $1}' | grep -vE '^(/System/|/usr/lib/|@rpath/libswift|@rpath/Sparkle.framework/)' || true)
if [[ -n "$NON_SYSTEM_LIBS" ]]; then
  echo "warning: the app links non-system dylibs (it will only run on machines that have them):" >&2
  echo "$NON_SYSTEM_LIBS" >&2
fi

release_id=$(security find-identity -p codesigning 2>/dev/null | awk '/"Framelift Release"/ { print $2; exit }')
dev_id=$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)
SIGN_ID="${FRAMELIFT_SIGN_IDENTITY:-${release_id:-${dev_id:--}}}"
codesign --force -s "$SIGN_ID" "$FRAMEWORK/Versions/B/Autoupdate"
codesign --force -s "$SIGN_ID" "$FRAMEWORK/Versions/B/Updater.app"
codesign --force -s "$SIGN_ID" "$FRAMEWORK"
codesign --force -s "$SIGN_ID" --entitlements Resources/Framelift.entitlements "$APP"
codesign --verify --deep --strict "$APP"
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
