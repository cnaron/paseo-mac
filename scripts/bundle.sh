#!/usr/bin/env bash
# Wrap the SwiftPM executable into a proper .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"        # debug | release
BIN_PATH="$ROOT/.build/$CONFIG/PaseoMac"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/PaseoMac.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Binary not found at $BIN_PATH. Run: swift build -c $CONFIG" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_PATH" "$MACOS/PaseoMac"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Copy icon if present
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi
if [[ -f "$ROOT/Resources/Credits.html" ]]; then
    cp "$ROOT/Resources/Credits.html" "$RESOURCES/Credits.html"
fi
cp "$ROOT/Resources/"*.png "$RESOURCES/" 2>/dev/null || true

# Code sign ad-hoc so Gatekeeper / launchd will run it
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
ls -la "$APP/Contents/"
