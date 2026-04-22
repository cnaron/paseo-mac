# paseo-mac

Native SwiftUI macOS client for the [Paseo](https://github.com/getpaseo) daemon (Claude Code remote agents). Connect to a Claude Code or Paseo server running on a VPS, manage multiple AI coding agents, and chat with them from a lightweight Mac window.

> Not affiliated with or endorsed by the Paseo project.

## Features

- **Multi-agent sidebar** — live status dots, animated while running
- **Rich conversation view** — markdown, syntax-highlighted code, tool-use details, images
- **Per-turn metadata** — model name + elapsed time chip on each assistant reply
- **Message search** — filter conversations inline via toolbar search
- **Composer** — auto-growing, drag-to-resize, image and text file attachments
- **Agent controls** — model picker, mode picker, thinking level per agent
- **Swipe-to-delete** and context menu for fast agent management
- **Auto-reconnect** on unexpected disconnect
- **Subscription quota panel** — sidebar usage bars (optional, requires VPS setup)

## Requirements

- macOS 14.0+
- Xcode 16 command-line tools: `xcode-select --install`
- A running Paseo daemon — install via `npm i -g @getpaseo/cli` and run `paseo onboard`

## Build

```bash
git clone https://github.com/cnaron/paseo-mac
cd paseo-mac
swift build -c release
bash scripts/bundle.sh release
open build/PaseoMac.app
```

## Connect

1. On your daemon machine, copy the pairing offer (Paseo app → Settings → Pair device, or `paseo pair`)
2. Launch PaseoMac → click the gear icon in the sidebar → paste the offer → **Connect**

The offer is end-to-end encrypted and pinned to the daemon's public key. Traffic goes through the relay server.

## Subscription Quota Panel (Optional)

The sidebar can show your Claude.ai subscription utilization (5-hour and 7-day windows). Because the Mac may not have direct access to the Anthropic API, a VPS-side proxy is required.

### 1 — VPS setup

```bash
mkdir -p ~/usage-api

cat > ~/usage-api/fetch.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
CREDS="$HOME/.claude/.credentials.json"
CACHE="$HOME/usage-api/cache.json"
TMP="$HOME/usage-api/cache.tmp.json"
ACCESS_TOKEN=$(python3 -c "import json,sys; d=json.load(open('$CREDS')); t=d['claudeAiOauth']['accessToken']; sys.exit(0) if t else sys.exit(1); print(t)")
SUB_TYPE=$(python3 -c "import json; d=json.load(open('$CREDS')); print(d.get('claudeAiOauth',{}).get('subscriptionType',''))" 2>/dev/null || echo "")
RESPONSE=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1" --max-time 15 "https://api.anthropic.com/api/oauth/usage")
python3 -c "
import json,sys,time
d=json.loads(sys.argv[1]); d['subscription_type']=sys.argv[2]; d['fetched_at']=int(time.time())
print(json.dumps(d))
" "$RESPONSE" "$SUB_TYPE" > "$TMP" && mv "$TMP" "$CACHE"
SCRIPT

chmod +x ~/usage-api/fetch.sh
~/usage-api/fetch.sh   # initial fetch

# Run every 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/usage-api/fetch.sh >> $HOME/usage-api/fetch.log 2>&1") | crontab -
```

#### nginx location block

```nginx
location = /api/claude-usage {
    if ($http_x_usage_token != "YOUR_SECRET_TOKEN") {
        return 401 '{"error":"unauthorized"}';
    }
    alias /home/youruser/usage-api/cache.json;
    default_type application/json;
    add_header Cache-Control "max-age=60";
}
```

### 2 — App configuration

Open **PaseoMac → Preferences (⌘,) → Integration**:

| Field | Value |
|---|---|
| Endpoint URL | `https://your-vps.example.com/api/claude-usage` |
| Token | your secret token |

The usage panel appears in the sidebar automatically once data is available.

## Architecture

```
┌─────────────────────────┐        WebSocket relay (E2E encrypted)
│  PaseoMac.app (Mac)     │ ─────────────────────────────────────────→ Paseo daemon (VPS)
│                         │                                               └── Claude API
│  (optional)             │        HTTPS + token auth
│  Quota panel            │ ─────────────────────────────────────────→ /api/claude-usage (VPS nginx)
└─────────────────────────┘                                               └── Anthropic usage API
```

## License

MIT
