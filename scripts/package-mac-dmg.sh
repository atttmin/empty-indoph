#!/bin/bash
# Package a built Empty.app into a compressed .dmg ready for distribution.
# Usage: scripts/package-mac-dmg.sh <path/to/Empty.app> [output-name]

set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "Usage: $0 <path/to/Empty.app> [output-name]" >&2
    exit 1
fi

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
BUNDLE_NAME="$(basename "$APP_PATH" .app)"

VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
BUILD="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "unknown")"

DMG_NAME="${2:-${BUNDLE_NAME}-${VERSION}-${BUILD}.dmg}"
STAGING_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "Packaging $APP_PATH (v$VERSION b$BUILD) → $DMG_NAME"

cp -R "$APP_PATH" "$STAGING_DIR/$BUNDLE_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$BUNDLE_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_NAME" >/dev/null

hdiutil verify "$DMG_NAME" >/dev/null

echo "Created: $DMG_NAME"
ls -lh "$DMG_NAME"
