# PaseoMac — Native SwiftUI Client for Paseo Daemon

## Why this exists

Paseo ships three Mac options today:

| Option | Memory | Mac ergonomics | Blocker |
|---|---|---|---|
| Paseo Electron | ~1.4 GB | decent | heaviest |
| Paseo Web (browser) | ~1.4–1.9 GB | browser chrome | same weight |
| Paseo iOS on Mac | ~450 MB | touch UI, no menu bar | **can't paste images/files** |

The iOS-on-Mac path was the best compromise on memory, but the paste bug is a hard blocker for day-to-day work. A native SwiftUI client talks to the same daemon over its WebSocket API, with no Electron shell and no iOS compatibility quirks.

Target: **~200 MB RSS, real Mac window, first-class paste and drag-drop for images and files.**

## Scope

### In scope (MVP)
- Connect to a remote daemon (VPS) over WebSocket
- Authenticate via the `hello` handshake (no relay / E2EE yet — see risks)
- List agents (equivalent of `paseo ls`)
- Open an agent → render conversation history → stream new messages
- Composer with text, image paste (⌘V), file drag-drop
- Send message, observe streaming response
- Persist connection config in Keychain

### Out of scope (for now)
- Voice / dictation
- Embedded terminal
- MCP config UI
- Skills / Schedule / Loop management
- Multi-window per agent
- Windows / Linux (Mac-only by design)

### Nice to have (P1)
- Diff viewer with syntax highlight
- Native menu bar + shortcuts (⌘N, ⌘,, ⌘W)
- Notifications when agent finishes
- Dock badge for unread
- Dark mode polish

## Architecture

```
┌────────────────────────────────────────────────┐
│ PaseoMac (Swift / SwiftUI)                     │
│                                                │
│ Views ── ViewModels ── DaemonClient ── WSTask  │
└────────────────────────────────────────────────┘
              │ ws(s)://
              ▼
     Paseo daemon (VPS, already running)
              │
              └── agents (claude-cli, codex, ...)
```

- **Transport**: `URLSessionWebSocketTask` (native, no deps)
- **MVP connectivity**: SSH tunnel (`ssh -L 6767:localhost:6767 cc`) + direct WS. Avoids implementing relay / NaCl box now — that is P2 work.
- **Persistence**: `SecItem` Keychain for tokens, `UserDefaults` for benign prefs
- **Concurrency**: Swift 6 actors, async/await throughout
- **UI**: SwiftUI with `@Observable` state, `NavigationSplitView` for the list+detail layout

### Build system

SwiftPM executable target. `swift build` from SSH, `scripts/bundle.sh` wraps into `.app`. An Xcode project can come later for GUI debugging.

## Milestones

### Phase 0 — scaffold ✅ done
- [x] git init, directory layout, PLAN + README
- [x] Package.swift + minimal SwiftUI app
- [x] scripts/bundle.sh produces `.app`
- [x] `swift build && open build/PaseoMac.app` shows empty window

### Phase 1 — daemon client ✅ done
- [x] `DaemonClient.swift`: connect, hello handshake, auto pong, requestId correlation
- [x] `Protocol.swift`: `Codable` types for WS envelope + session messages
- [x] `SmokeTest.swift`: `./PaseoMac --list-agents` prints the same agent list as `paseo ls`
- [x] End-to-end verified against live VPS daemon over SSH tunnel

### Phase 2 — relay transport ✅ done
Replaces the SSH tunnel with a real end-to-end relay path. PaseoMac now
connects to `wss://<relay>/ws?serverId=...&role=client&v=2`, does the NaCl
box handshake with the daemon's pubkey from a pairing offer, and then speaks
the same session protocol from Phase 1 — all frames base64-encoded ciphertext.

- [x] Vendored `swift-sodium` under `.vendor/` (Clibsodium only; git proxy on Air makes SPM fetch unreliable)
- [x] `RelayCrypto.swift` — `crypto_box_beforenm` + `crypto_secretbox_{easy,open_easy}`, bundle `[nonce(24)][mac+ct]`
- [x] `ConnectionOffer.swift` — parses `https://app.paseo.sh/#offer=<b64>`, `paseo://`, raw base64, or JSON
- [x] `RelayChannel.swift` — actor that runs the `e2ee_hello` / `e2ee_ready` handshake, 1s retry, encrypted send/recv
- [x] `DaemonEndpoint` made an enum: `.direct(host,port,clientId)` or `.relay(offer,clientId)`
- [x] `DaemonClient` routes its transport through `RelayChannel` when the endpoint is relay
- [x] `SmokeTest.swift --offer <...>` verified end-to-end against `relay.cnaron.com:443` + the VPS daemon

### Phase 3 — conversation UI ✅ done

- [x] `AgentListView` — sidebar `List` with status dots, bound to `selectedAgentId`
- [x] `Protocol.swift` extended: `FetchAgentTimelineRequest/Response`, `TimelineItem`/`TimelineEntry`, `AgentStreamMessage`/`AgentStreamEvent`
- [x] `DaemonClient.fetchTimeline(agentId:)` + `sendMessage(agentId:text:)` wired with requestId correlation; agent_stream events routed to per-agent VMs
- [x] `ConversationView` — LazyVStack of role-aware `MessageBubble`s, auto-scroll to bottom on new rows
- [x] `ComposerView` — `TextEditor` + ⌘↩ send; optimistic user bubble then reconciled via agent_stream
- [x] `AppViewModel` + `ConversationViewModel` (@Observable / @MainActor) — routes `turn_started/completed/failed` to a "working…" chip, timeline events to row appends
- [x] `ConnectSheet` — first-run pairing-offer paste UI; persisted in `UserDefaults`, auto-reconnect on relaunch
- [x] Plain-text rendering only for MVP — markdown / tool-call detail cards / diff viewer deferred
- [x] Verified via `--list-agents --timeline <prefix>` and a GUI cold-start survives 3s without crashing

### Phase 4 — paste and drop ← the reason we're building this
- [ ] NSPasteboard hook on ⌘V, detect `public.image` / `public.file-url`
- [ ] `Attachment` model with thumbnail
- [ ] Drop target on composer (`onDrop(of:)`)
- [ ] Upload: base64 inline via `send_agent_message_request.images[]`
  - Confirmed from upstream code: images are base64 inline, no separate HTTP endpoint.
- [ ] Images preview inline, files show as a chip with filename

### Phase 5 — diff / code polish (optional)
- [ ] Detect unified diff in messages, render with add/remove colors
- [ ] Syntax highlight via a dep-light highlighter
- [ ] Collapse long code blocks

### Phase 6 — Mac-native polish (rolling)
- [ ] Menu bar (File, Edit, Agent, Window, Help)
- [ ] Standard shortcuts
- [ ] Notifications via `UNUserNotificationCenter`
- [ ] Restore window/session on relaunch

## Risks, unknowns, and notes accumulated during Phase 1

1. **MVP uses SSH tunnel, not relay.** The relay protocol needs Curve25519 + XSalsa20-Poly1305 (NaCl box) via CryptoKit, plus the handshake in `packages/relay/`. We can add this later. For now users run `ssh -L 6767:localhost:6767 <vps>` and PaseoMac connects to `ws://localhost:6767/ws`.
2. **`WS_PROTOCOL_VERSION = 1`** — the daemon checks this literal; relay protocol is a separate `"2"` (unrelated).
3. **Envelope discrepancy**: our earlier docs note assumed `{type:"server_info"}` but server actually emits `{type:"session", message:{type:"status", payload:{status:"server_info", ...}}}`. Our decoder handles it by routing to `.unknown` on the session level for now — good enough because list/send don't need the info.
4. **Response shape**: `fetch_agents_response.payload.entries[].agent` (wraps agent inside `{agent, project}`) — not `payload.agents[]`. Handle `entries` when decoding.
5. **Paging**: `pageInfo.nextCursor` returned when `hasMore:true`. Ignored for MVP (MVP pulls top 50).
6. **Streaming delta merge** is still unverified — will be exercised in Phase 2 when we consume `assistant_chunk`.
7. **Binary WS frames**: confirmed unused at the session level. Binary frames are reserved for `terminal-stream-protocol` (out of scope).

## Non-goals and anti-goals

- **Not a Paseo feature-for-feature clone.** We're replacing daily-driver workflow, not rebuilding the whole app.
- **Not a distributable product.** AGPLv3 source is public if published, but this is personal tooling first.
- **Not going to re-implement the daemon.** The VPS already runs `@getpaseo/server`. We're a client, period.

## Directory layout

```
paseo-mac/
├── PLAN.md                 ← this file
├── README.md
├── LICENSE                 (AGPLv3, matches upstream)
├── Package.swift
├── .gitignore
├── Sources/PaseoMac/
│   ├── PaseoMacApp.swift   ← @main (dispatches to smoke test when --list-agents)
│   ├── SmokeTest.swift     ← CLI agent list printer
│   ├── ContentView.swift   ← Phase 0 placeholder; rewritten in Phase 2
│   ├── Network/
│   │   ├── DaemonClient.swift
│   │   └── Protocol.swift
│   ├── Models/             (to be populated in Phase 2)
│   ├── ViewModels/
│   └── Views/
├── Resources/Info.plist
├── scripts/bundle.sh
└── docs/daemon-protocol.md
```

## How to run today (post Phase 2)

```bash
# Direct (localhost or SSH-tunnelled to a daemon on :6767):
#   ssh -f -N -L 6767:localhost:6767 <your-vps-alias>

# Relay (recommended): produce a pairing offer on the daemon side, pass it via --offer.
# The offer is the JSON blob (or the URL fragment from app.paseo.sh) that pairs
# this client with the daemon over the relay, end-to-end encrypted.

# build + run the CLI smoke test
cd paseo-mac
swift build
./.build/debug/PaseoMac --list-agents --offer "$OFFER_JSON_OR_URL"
# => table of agents identical to `paseo ls` on the VPS
```

The GUI (`open build/PaseoMac.app`) still shows the Phase 0 placeholder window; Phase 2 wires the UI to the client.
