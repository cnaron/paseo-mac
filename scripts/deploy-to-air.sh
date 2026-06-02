#!/usr/bin/env bash
# Run ON mini. Waits for Air, then overwrites /Applications/PaseoMac.app and relaunches.
set -uo pipefail
APP="/Users/cc/Public/Project/paseo-mac/build/PaseoMac.app"
for i in $(seq 1 1); do
  if ssh -o BatchMode=yes -o ConnectTimeout=8 air 'echo up' >/dev/null 2>&1; then
    touch "$APP"
    ssh air 'osascript -e "quit app \"PaseoMac\"" 2>/dev/null; sleep 1; rm -rf /Applications/PaseoMac.app'
    rsync -az --delete -e ssh "$APP/" air:/Applications/PaseoMac.app/
    ssh air 'xattr -dr com.apple.quarantine /Applications/PaseoMac.app 2>/dev/null; touch /Applications/PaseoMac.app; open -a /Applications/PaseoMac.app'
    echo "DEPLOYED"; exit 0
  fi
  echo "air unreachable"; exit 3
done
