# paseo-mac

[中文](README.zh.md)

Native macOS client for interacting with [Claude Code](https://claude.ai/code) agents running remotely on a server or VPS.

## Why this exists

Claude Code is a CLI tool that runs on your server and controls AI coding agents. It ships with a web UI, but that means keeping a browser tab open and exposing a port. This app is a native macOS alternative: it connects to the Paseo relay — the same WebSocket infrastructure Claude Code uses — and gives you a proper Mac window to monitor agents, read conversations, and send messages.

The core use case: you have Claude Code running 24/7 on a VPS, and you want a lightweight, always-ready Mac app to check in on it from anywhere, the same way you'd check Slack or Messages.

## What it does

- **Sidebar** — lists all agents with live status dots (green = running, animated)
- **Conversations** — markdown, code highlighting, tool-use details, inline images
- **Per-turn info** — model name and elapsed time below each assistant reply
- **Search** — filter messages in any conversation
- **Composer** — send messages, attach images and text/code files
- **Agent controls** — switch model, mode, and thinking level per agent
- **Quota panel** — shows Claude.ai subscription usage (5h / 7d windows) if configured

## Limitations

**Read these before using.**

- **Not official.** This is a personal project, not affiliated with Anthropic or the Paseo team.
- **Protocol dependency.** The app speaks the `@getpaseo/server` WebSocket protocol. If that protocol changes, the app breaks.
- **No Apple notarization.** The binary is unsigned. macOS will warn you on first launch — right-click → Open to proceed.
- **Relay required.** You need a running Paseo daemon and a valid pairing offer. The app does nothing standalone.
- **Quota panel needs setup.** The sidebar usage bars require a self-hosted VPS endpoint (see below). The app cannot call the Anthropic API directly from the Mac — your VPS does it.
- **Pre-alpha quality.** This is built and tested for personal use. Edge cases are unhandled, error messages are sparse.
- **macOS 14+ only.** Uses SwiftUI Observation framework (`@Observable`), which requires Sonoma.

## Install

Download **PaseoMac.zip** from [Releases](https://github.com/cnaron/paseo-mac/releases), unzip, drag to Applications.

First launch: right-click the app → **Open** (Gatekeeper blocks unsigned apps on double-click).

## Connect

You need a Paseo daemon running somewhere. Install it with:

```bash
npm i -g @getpaseo/cli
paseo onboard
```

Then from the daemon machine, copy the pairing offer. In PaseoMac: click the gear icon → paste the offer → **Connect**.

## Quota panel (optional)

The app cannot reach the Anthropic usage API directly — the Mac may not have outbound internet. The VPS fetches it and serves it locally.

**VPS side** — create `~/usage-api/fetch.sh`:

```bash
#!/bin/bash
set -euo pipefail
CREDS="$HOME/.claude/.credentials.json"
ACCESS_TOKEN=$(python3 -c "import json; print(json.load(open('$CREDS'))['claudeAiOauth']['accessToken'])")
SUB_TYPE=$(python3 -c "import json; print(json.load(open('$CREDS')).get('claudeAiOauth',{}).get('subscriptionType',''))" 2>/dev/null || echo "")
RESP=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1" --max-time 15 "https://api.anthropic.com/api/oauth/usage")
python3 -c "
import json,sys,time
d=json.loads(sys.argv[1]); d['subscription_type']=sys.argv[2]; d['fetched_at']=int(time.time())
print(json.dumps(d))
" "$RESP" "$SUB_TYPE" > ~/usage-api/cache.json
```

```bash
chmod +x ~/usage-api/fetch.sh && ~/usage-api/fetch.sh
# Refresh every 5 minutes:
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/usage-api/fetch.sh") | crontab -
```

**nginx** — add a token-protected location:

```nginx
location = /api/claude-usage {
    if ($http_x_usage_token != "YOUR_SECRET_TOKEN") { return 401; }
    alias /home/youruser/usage-api/cache.json;
    default_type application/json;
}
```

**App** — open **Preferences (⌘,) → Integration**, enter the endpoint URL and token.

## License

MIT
