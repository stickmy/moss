#!/bin/bash
set -euo pipefail

SCHEME="Moss"
CONFIG="Release"
BUILD_DIR="$(mktemp -d)"
DMG_DIR="$(mktemp -d)"
APP_NAME="Moss.app"
DMG_NAME="Moss.dmg"
OUTPUT_DIR="${1:-$(pwd)}"

echo "==> Building $SCHEME ($CONFIG)..."
xcodebuild -project Moss.xcodeproj -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    build

APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found"
    exit 1
fi

echo "==> Verifying moss CLI in bundle..."
if [ ! -f "$APP_PATH/Contents/Resources/moss" ]; then
    echo "Warning: moss CLI not found in app bundle"
fi

echo "==> Creating DMG..."
mkdir -p "$DMG_DIR/dmg"
cp -R "$APP_PATH" "$DMG_DIR/dmg/"
ln -s /Applications "$DMG_DIR/dmg/Applications"

hdiutil create -volname "Moss" \
    -srcfolder "$DMG_DIR/dmg" \
    -ov -format UDZO \
    "$OUTPUT_DIR/$DMG_NAME"

echo "==> Cleaning up..."
rm -rf "$BUILD_DIR" "$DMG_DIR"

echo "==> Done: $OUTPUT_DIR/$DMG_NAME"
