#!/usr/bin/env bash
set -uo pipefail
CONFIG="${1:-debug}"
rsync -az --delete \
  --exclude='/.git' --exclude='/.build' --exclude='/build' \
  --exclude='/.claude' --exclude='/.vendor' \
  -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
  /home/ubuntu/paseo-mac/ mini:/Users/cc/Public/Project/paseo-mac/ || { echo "RSYNC_FAILED"; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=10 mini "cd /Users/cc/Public/Project/paseo-mac && swift build -c $CONFIG 2>&1 | tee /tmp/pm-build.log | grep -E 'error:|warning: .*unused' | head -40; if grep -q 'Build complete' /tmp/pm-build.log; then echo '✅ BUILD OK'; else echo '❌ BUILD FAILED'; grep -E 'error:' /tmp/pm-build.log | head -1; fi"
