#!/usr/bin/env bash
# Run ON vps. Syncs source to mini, builds Xcode app bundle, copies binary into
# the bundle, then optionally deploys to Air.  Usage: dev-mini-build.sh [--deploy]
set -uo pipefail

DEPLOY=0; [[ "${1:-}" == "--deploy" ]] && DEPLOY=1

BUILD_DIR="/Users/cc/Public/Project/paseo-mac/build"
APP="$BUILD_DIR/PaseoMac.app"

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
    echo '✅ BUILD OK'
  else
    echo '❌ BUILD FAILED'
    grep 'error:' /tmp/pm-build.log | head -3
    exit 1
  fi
"

if [[ $DEPLOY -eq 1 ]]; then
  echo "→ Deploying to Air…"
  ssh mini "cd /Users/cc/Public/Project/paseo-mac && bash scripts/deploy-to-air.sh"
fi
