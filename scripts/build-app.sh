#!/usr/bin/env bash
# Builds a release binary with SwiftPM and wraps it in a .app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="IPLocationMenuBar"
APP_DIR="build/${APP_NAME}.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS accepts the bundle locally (needed for launch at login).
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
