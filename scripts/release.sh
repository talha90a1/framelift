#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Builds dist/Framelift-<version>-macOS-arm64.zip and its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
NAME="Framelift-${VERSION}-macOS-arm64"

IDENTITY=$(security find-identity -p codesigning | awk '/"Framelift Release"/ { print $2; exit }')
[[ -n "$IDENTITY" ]] || { echo "error: no \"Framelift Release\" signing identity in the keychain" >&2; exit 1; }
FRAMELIFT_RELEASE_BUILD=1 FRAMELIFT_SIGN_IDENTITY="$IDENTITY" scripts/bundle_app.sh

APP=dist/Framelift.app
# Releases are built by GitHub Actions; a local build embeds the builder's home folder in compiler-made
# path strings, so it is refused unless it runs on a CI runner.
if [[ -z "${GITHUB_ACTIONS:-}" ]] && grep -rIaq -e "$HOME" -e "/Users/$USER/" "$APP"; then
  echo "error: the app contains paths from this Mac ($HOME); publish releases from GitHub Actions" >&2
  exit 1
fi
[[ "$(lipo -archs "$APP/Contents/MacOS/Framelift")" == "arm64" ]] || { echo "error: expected an arm64-only binary" >&2; exit 1; }
[[ "$(codesign -dvv "$APP" 2>&1)" == *"Authority=Framelift Release"* ]] || { echo "error: expected the Framelift Release signature" >&2; exit 1; }

rm -f "dist/$NAME.zip" "dist/$NAME.zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"
(cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

echo "release: dist/$NAME.zip"
cat "dist/$NAME.zip.sha256"
