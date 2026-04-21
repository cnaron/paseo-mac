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
- Connect to a remote daemon (VPS) over WebSocket, via relay or direct
- Authenticate using the existing pairing token flow
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
│                              │                 │
│                              └── Relay (NaCl)  │
└────────────────────────────────────────────────┘
              │ ws(s)://
              ▼
     Paseo daemon (VPS, already running)
              │
              └── agents (claude-cli, codex, ...)
```

- **Transport**: `URLSessionWebSocketTask` (native, no deps)
- **Crypto for relay**: Apple CryptoKit `Curve25519` + libsodium-style sealed boxes where needed
- **Persistence**: `SecItem` Keychain for tokens, `UserDefaults` for benign prefs
- **Concurrency**: Swift 6 actors, async/await throughout
- **UI**: SwiftUI with `@Observable` state, `NavigationSplitView` for the list+detail layout

### Build system

First pass uses **Swift Package Manager** executable target. Faster to iterate from SSH (`swift build`, no Xcode GUI). A shell script wraps the built binary into a `.app` with a hand-written `Info.plist`.

Once the app stabilizes we can optionally add an `.xcodeproj` for GUI debugging.

## Milestones

### Phase 0 — scaffold (today)
- [x] git init, directory layout, PLAN + README
- [ ] Package.swift + minimal SwiftUI app
- [ ] scripts/bundle.sh produces `.app`
- [ ] `swift build && open .build/PaseoMac.app` shows empty window

### Phase 1 — daemon client (day 2–3)
- [ ] `DaemonClient.swift`: connect, send frame, receive frame, reconnect
- [ ] `Protocol.swift`: `Codable` types for the RPC messages we need
- [ ] `Connection.swift`: host/port/token stored in Keychain
- [ ] CLI sanity: listing agents printed to stdout matches `paseo ls`

### Phase 2 — conversation UI (day 4–7)
- [ ] `AgentListView` — left sidebar, native List
- [ ] `ConversationView` — streaming messages
- [ ] `MessageBubble` — role-aware bubbles, markdown via `AttributedString`
- [ ] `ComposerView` — text input + send
- [ ] Incremental message merging (deltas into one bubble)

### Phase 3 — paste and drop (day 8–10) ← the reason we're building this
- [ ] NSPasteboard hook on ⌘V, detect `public.image` / `public.file-url`
- [ ] `Attachment` model with thumbnail
- [ ] Drop target on composer (`onDrop(of:)`)
- [ ] Upload to daemon (binary WS frame or multipart — TBD after protocol dig)
- [ ] Images embed inline, files attach with filename chip

### Phase 4 — diff / code polish (day 11–14, optional)
- [ ] Detect ```diff / unified diff in messages
- [ ] Syntax highlight via a small, dep-light highlighter
- [ ] Collapse long code blocks

### Phase 5 — Mac-native polish (rolling)
- [ ] Menu bar (File, Edit, Agent, Window, Help)
- [ ] Standard shortcuts
- [ ] Notifications via `UNUserNotificationCenter`
- [ ] Restore window/session on relaunch

## Risks and unknowns

1. **Pairing flow** — iOS app presumably scans a QR code from the desktop. We need to replicate whichever handshake the daemon expects. Will dig into `packages/server/src/server/connection-offer.ts` and the relay before Phase 1.
2. **Binary upload path** — if daemon WebSocket is JSON-only, we either base64-inline images (slow) or find an HTTP multipart endpoint. Will determine during Phase 3.
3. **Streaming delta merge** — agent responses arrive as many partial events; merging them into one bubble without flicker needs care.
4. **Relay v2 crypto** — tweetnacl sealed boxes in Swift via CryptoKit are straightforward if the scheme is standard Curve25519+XSalsa20-Poly1305. If Paseo uses a custom twist we may need to port a small shim.

## Non-goals and anti-goals

- **Not a Paseo feature-for-feature clone.** We're replacing daily-driver workflow, not rebuilding the whole app.
- **Not a distributable product.** AGPLv3 source is public if published, but this is personal tooling first. Publishing can come later if the app is useful.
- **Not going to re-implement the daemon.** The VPS already runs `@getpaseo/server`. We're a client, period.

## Directory layout

```
paseo-mac/
├── PLAN.md                 ← this file
├── README.md               ← how to build/run
├── Package.swift
├── .gitignore
├── Sources/PaseoMac/
│   ├── PaseoMacApp.swift   ← @main
│   ├── ContentView.swift
│   ├── Models/             ← Agent, Message, Attachment
│   ├── Network/            ← DaemonClient, Protocol, Relay
│   ├── ViewModels/         ← @Observable state
│   └── Views/              ← UI
├── Resources/
│   └── Info.plist
├── scripts/
│   └── bundle.sh           ← wrap binary into .app
└── docs/
    └── daemon-protocol.md  ← notes from reading packages/server
```
