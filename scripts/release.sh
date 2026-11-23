#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Builds an ad hoc signed Apple Silicon release: dist/Framelift-<version>-macOS-arm64.zip plus its SHA-256.
# Ad hoc signing embeds no developer identity; without a Developer ID and notarization, users approve
# the first launch in System Settings › Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
NAME="Framelift-${VERSION}-macOS-arm64"

FRAMELIFT_SIGN_IDENTITY=- scripts/bundle_app.sh

APP=dist/Framelift.app
# Drop debug symbols: they carry absolute build paths (the builder's home folder and user name).
strip -S -x "$APP/Contents/MacOS/Framelift"
codesign --force --deep -s - --entitlements Resources/Framelift.entitlements "$APP"
# Releases are built by GitHub Actions; a local build embeds the builder's home folder in compiler-made
# path strings, so it is refused unless it runs on a CI runner.
if [[ -z "${GITHUB_ACTIONS:-}" ]] && grep -rIaq -e "$HOME" -e "/Users/$USER/" "$APP"; then
  echo "error: the app contains paths from this Mac ($HOME); publish releases from GitHub Actions" >&2
  exit 1
fi
[[ "$(lipo -archs "$APP/Contents/MacOS/Framelift")" == "arm64" ]] || { echo "error: expected an arm64-only binary" >&2; exit 1; }
[[ "$(codesign -dv "$APP" 2>&1)" == *"Signature=adhoc"* ]] || { echo "error: expected an ad hoc signature" >&2; exit 1; }

rm -f "dist/$NAME.zip" "dist/$NAME.zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"
(cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

echo "release: dist/$NAME.zip"
cat "dist/$NAME.zip.sha256"
