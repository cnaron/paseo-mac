#!/usr/bin/env bash
# Wrap the SwiftPM executables into .app bundles.
#
# Usage: scripts/bundle.sh [debug|release] [target]
#   target = paseomac | widget | all   (default: paseomac for back-compat)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
TARGET="${2:-paseomac}"
OUT_DIR="$ROOT/build"

build_paseomac() {
    local BIN_PATH="$ROOT/.build/$CONFIG/PaseoMac"
    local APP="$OUT_DIR/PaseoMac.app"
    local CONTENTS="$APP/Contents"
    local MACOS="$CONTENTS/MacOS"
    local RESOURCES="$CONTENTS/Resources"

    [[ -x "$BIN_PATH" ]] || { echo "PaseoMac binary missing at $BIN_PATH. Run: swift build -c $CONFIG" >&2; exit 1; }

    rm -rf "$APP"
    mkdir -p "$MACOS" "$RESOURCES"

    cp "$BIN_PATH" "$MACOS/PaseoMac"
    cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

    [[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
    [[ -f "$ROOT/Resources/Credits.html" ]] && cp "$ROOT/Resources/Credits.html" "$RESOURCES/Credits.html"
    cp "$ROOT/Resources/"*.png "$RESOURCES/" 2>/dev/null || true

    codesign --force --sign - "$APP" >/dev/null
    echo "Built $APP"
}

build_widget() {
    local BIN_PATH="$ROOT/.build/$CONFIG/PaseoUsageWidget"
    local APP="$OUT_DIR/PaseoUsageWidget.app"
    local CONTENTS="$APP/Contents"
    local MACOS="$CONTENTS/MacOS"
    local RESOURCES="$CONTENTS/Resources"

    [[ -x "$BIN_PATH" ]] || { echo "Widget binary missing at $BIN_PATH. Run: swift build -c $CONFIG" >&2; exit 1; }

    rm -rf "$APP"
    mkdir -p "$MACOS" "$RESOURCES"

    cp "$BIN_PATH" "$MACOS/PaseoUsageWidget"
    cp "$ROOT/Resources/Widget/Info.plist" "$CONTENTS/Info.plist"

    codesign --force --sign - "$APP" >/dev/null
    echo "Built $APP"
}

case "$TARGET" in
    paseomac) build_paseomac ;;
    widget) build_widget ;;
    all) build_paseomac; build_widget ;;
    *) echo "Unknown target: $TARGET (expected paseomac | widget | all)" >&2; exit 1 ;;
esac

