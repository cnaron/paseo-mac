#!/usr/bin/env bash
# Run ON vps. Bumps Info.plist version, syncs to mini, builds Xcode app,
# copies binary into the bundle, and deploys to Air.
#
# Usage: ./scripts/release.sh <version>   e.g. ./scripts/release.sh 0.4.16
#        ./scripts/release.sh             # auto-bump patch
set -uo pipefail

PLIST="/home/ubuntu/paseo-mac/Resources/Info.plist"
CUR=$(grep -A1 CFBundleShortVersionString "$PLIST" | tail -1 | sed -E 's/[^0-9.]//g')
CUR_BUILD=$(grep -A1 '<key>CFBundleVersion</key>' "$PLIST" | tail -1 | sed -E 's/[^0-9]//g')

if [[ -n "${1:-}" ]]; then
  NEW="$1"
else
  IFS='.' read -r MAJ MIN PAT <<<"$CUR"
  NEW="${MAJ}.${MIN}.$((PAT + 1))"
fi
NEW_BUILD=$((CUR_BUILD + 1))

echo "→ Version bump: $CUR (build $CUR_BUILD) → $NEW (build $NEW_BUILD)"

sed -i "s|<string>$CUR</string>|<string>$NEW</string>|" "$PLIST"
sed -i "0,/<string>$CUR_BUILD<\/string>/s||<string>$NEW_BUILD</string>|" "$PLIST"

echo "→ Syncing source to mini…"
rsync -az --delete \
  --exclude='/.git' --exclude='/.build' --exclude='/build' \
  --exclude='/.claude' --exclude='/.vendor' \
  /home/ubuntu/paseo-mac/ mini:/Users/cc/Public/Project/paseo-mac/ \
  || { echo "❌ RSYNC failed"; exit 1; }

echo "→ Building on mini…"
ssh mini "
  set -uo pipefail
  cd /Users/cc/Public/Project/paseo-mac
  xcodebuild -scheme PaseoMac -configuration Debug \
    -destination 'platform=macOS' \
    CONFIGURATION_BUILD_DIR=/Users/cc/Public/Project/paseo-mac/build \
    build 2>&1 | tee /tmp/pm-build.log | tail -3
  if ! grep -q 'BUILD SUCCEEDED' /tmp/pm-build.log; then
    echo '❌ BUILD FAILED'; grep 'error:' /tmp/pm-build.log | head -5; exit 1
  fi
  cp build/PaseoMac build/PaseoMac.app/Contents/MacOS/PaseoMac
  # Force-refresh Info.plist inside the bundle (xcodebuild may stash a copy).
  cp Resources/Info.plist build/PaseoMac.app/Contents/Info.plist
  echo '✅ BUILD OK'
" || { echo "❌ BUILD step failed"; exit 1; }

echo "→ Deploying to Air…"
ssh mini "cd /Users/cc/Public/Project/paseo-mac && bash scripts/deploy-to-air.sh"

echo ""
echo "✅ Shipped $NEW (build $NEW_BUILD)"
ssh mini "ssh air 'defaults read /Applications/PaseoMac.app/Contents/Info CFBundleShortVersionString'" \
  | xargs -I{} echo "   Air now runs: {}"
