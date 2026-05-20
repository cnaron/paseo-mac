#!/bin/bash
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
XCPROJ="$REPO/Apps/PaseoIOS.xcodeproj"
SCHEME="PaseoIOS"
ARCHIVE="$REPO/build/PaseoIOS.xcarchive"
IPA_DIR="$REPO/build"
EXPORT_PLIST="$REPO/Apps/ExportOptions.plist"

echo "==> Archiving $SCHEME…"
xcodebuild archive \
  -project "$XCPROJ" \
  -scheme "$SCHEME" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Automatic \
  | xcpretty || cat /dev/stdin

echo "==> Exporting IPA…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$IPA_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  | xcpretty || cat /dev/stdin

echo "Built $IPA_DIR/PaseoIOS.ipa"
