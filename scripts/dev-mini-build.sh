#!/usr/bin/env bash
# Run ON vps. Syncs source to mini, builds Xcode app bundle, copies binary into
# the bundle, then optionally deploys to Air.  Usage: dev-mini-build.sh [--deploy]
set -uo pipefail

DEPLOY=0; [[ "${1:-}" == "--deploy" ]] && DEPLOY=1

BUILD_DIR="/Users/cc/Public/Project/paseo-mac/build"
APP="$BUILD_DIR/PaseoMac.app"

# Bump the build number every dev build so the running app is visibly newer
# (shown in Settings → 通用 → 关于). Lets you confirm the deploy actually landed.
PLIST="/home/ubuntu/paseo-mac/Resources/Info.plist"
CUR_BUILD=$(grep -A1 '<key>CFBundleVersion</key>' "$PLIST" | tail -1 | sed -E 's/[^0-9]//g')
NEW_BUILD=$((CUR_BUILD + 1))
sed -i "0,/<string>${CUR_BUILD}<\/string>/s||<string>${NEW_BUILD}</string>|" "$PLIST"
VERSION=$(grep -A1 CFBundleShortVersionString "$PLIST" | tail -1 | sed -E 's/[^0-9.]//g')
echo "→ Build $VERSION ($NEW_BUILD)"

echo "→ Syncing source to mini…"
rsync -az --delete \
  --exclude='/.git' --exclude='/.build' --exclude='/build' \
  --exclude='/.claude' --exclude='/.vendor' \
  -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
  /home/ubuntu/paseo-mac/ mini:/Users/cc/Public/Project/paseo-mac/ || { echo "RSYNC_FAILED"; exit 1; }

echo "→ Building on mini…"
ssh -o BatchMode=yes -o ConnectTimeout=10 mini "
  set -uo pipefail
  cd /Users/cc/Public/Project/paseo-mac
  xcodebuild -scheme PaseoMac -configuration Debug \
    -destination 'platform=macOS' \
    CONFIGURATION_BUILD_DIR='$BUILD_DIR' \
    build 2>&1 | tee /tmp/pm-build.log | grep -E '^.*error:|Build succeeded|FAILED' | head -20
  if grep -q 'BUILD SUCCEEDED' /tmp/pm-build.log; then
    # Copy linked binary into the app bundle (CONFIGURATION_BUILD_DIR puts the
    # binary at build/PaseoMac but does not update the .app bundle inside).
    cp '$BUILD_DIR/PaseoMac' '$APP/Contents/MacOS/PaseoMac'
    # Force-refresh Info.plist inside the bundle so the bumped build number ships.
    cp Resources/Info.plist '$APP/Contents/Info.plist'
    echo '✅ BUILD OK'
  else
    echo '❌ BUILD FAILED'
    grep 'error:' /tmp/pm-build.log | head -3
    exit 1
  fi
" || exit 1

if [[ $DEPLOY -eq 1 ]]; then
  echo "→ Deploying to Air…"
  ssh mini "cd /Users/cc/Public/Project/paseo-mac && bash scripts/deploy-to-air.sh"
fi

echo "✅ $VERSION ($NEW_BUILD)"
