# Redesign Follow-ups (design/v1)

Running record of what the 2026-06-02 UI session changed and what's still open.
Pick up the **Pending** items next time.

## Done this session (build 70, design/v1, not yet committed)

| Area | Change | Files |
|---|---|---|
| Lazy render | Transcript shows the last 30 turns; "显示更早 N 条" button pages 20 more (anchors scroll to the previously-first visible turn). Cuts memory of long conversations. | `Views/Redesign/Transcript.swift` (`shownTurnCount`, `showEarlier`) |
| Streaming jitter | Replaced per-token `scrollTo("bottom")` (immediate-on-stale-layout + trailing = scroll/drift/snap) with native **`.defaultScrollAnchor(.bottom)`** — bottom stays pinned in the same layout pass, no scrollTo during streaming. | `Views/Redesign/Transcript.swift` |
| Tail compensation | Bottom gap now lives in the **bottom marker** (not an outer `.padding(.bottom)`), so `scrollTo("bottom")` lands exactly where `defaultScrollAnchor` pins — no fight. Marker height = working ? 44 : 20, giving the just-sent message + working indicator breathing room. | `Views/Redesign/Transcript.swift` |
| Content close to composer | `Spacer(minLength: 0)` + `minHeight` bottom-aligns short conversations. | `Views/Redesign/Transcript.swift` |
| Line spacing setting | Wired `MDView` line spacing to `settings.paragraphLineSpacing` (was hardcoded `fs*0.30`); added a 行间距 slider (0–10pt) in the redesign Settings; default 6.0. | `Views/Redesign/MDView.swift`, `Views/Redesign/SettingsView.swift`, `SettingsStore.swift` |
| Title-bar divider | `window.titlebarSeparatorStyle = .none` (the hairline was the AppKit titlebar separator, not the split divider). Also gave the split a zero-divider subclass. | `Views/Redesign/RootView.swift` (`WindowConfigurator`), `Views/AppKit/AppKitRoot.swift` (`ZeroDividerSplitView`) |
| File preview | **In-window full-page overlay** over the conversation area (below header/tabs), ✕ to close. NOT a separate window, NOT a docked column — those were two wrong turns this session, now reverted. | `Views/AppKit/ConversationVC.swift` (`workspacePreviewHost`), `Views/AppKit/WorkspacePanel.swift` (`previewRoute`/`openFile`/`closePreview`) |

**Caveats to verify in real use:**
- Streaming jitter: confirm the transcript no longer jumps as a whole while a reply streams.
- `defaultScrollAnchor(.bottom)` behaviour when the user scrolls UP mid-stream — should preserve their position (not yank down). If it yanks, revisit.
- Marker height flips 20↔44 at turn start/end → a one-time ~24pt settle each. Acceptable; watch that it isn't jarring.

## Pending — for next session

### 1. New-conversation flow feels slow + the UI jumps

**Goal:** clicking 新对话 → typing → send should feel like sending a message in an
existing conversation. No distinct "creating" screen, no layout change.

**Current behaviour (the problem):**
- `createAgent(cwd:)` sets `selectedAgentId = pendingAgentId` → transcript shows
  `TranscriptEmptyView(pending:)`.
- `submitPendingAgent(text:)` (text path) calls `createAgent(initialPrompt: text)` then
  **blocks** waiting for the new agent to appear (stream event, else poll up to ~3s),
  showing `creatingAgentText` → "正在启动会话…" spinner screen the whole time.
- Only after the agent id is detected does it switch `selectedAgentId = agentId` and
  clear `creatingAgentText`. Net: three visual states (empty pending → 正在启动会话 → real
  transcript) = the jump.
- The **image path already does it right**: `injectOptimisticFirstMessage` builds the
  real conversation VM with an optimistic user row immediately, then sends.

**Approach sketch:**
- Make the text path mirror the image path: on send, immediately show the user's
  message + a thinking rail in a normal-looking transcript (reuse
  `injectOptimisticFirstMessage`), and run `createAgent` in the background; reconcile the
  optimistic row once the real agent id + stream arrive.
- Drop the dedicated "正在启动会话…" UI (or make it visually identical to a working turn:
  user bubble + `ThinkingRail`), so there's no screen swap.
- The createAgent RPC latency is inherent, but the *perceived* slowness comes from the
  blank/creating screens — showing the optimistic message makes it feel instant.

**Key code:** `ViewModels/AppViewModel.swift` `submitPendingAgent` (~L443), `createAgent`
(~L422), `creatingAgentText`/`creatingAgentImages`, `injectOptimisticFirstMessage`
(`ConversationViewModel`). UI: `Views/AppKit/TranscriptVC.swift` `TranscriptEmptyView`
(~L95), `Views/AppKit/ConversationVC.swift` `syncAgent`.

### 2. Memory: ~190–300 MB now, target ~80–100 MB

Native client's selling point is low memory (docs/redesign-brief.md: "~80 MB"). After this
session it sits ~190 MB idle (was 270). Electron Paseo's true total is ~400 MB across 3
processes, so we're already well under it — but there's headroom.

**Levers (cheap → expensive):**
- `maxCachedConversations` 8 → 3–4 (`AppViewModel.swift` ~L185). ~10–15 MB.
- `shownTurnCount` initial 30 → 20 (`Transcript.swift`). Fewer live SwiftUI nodes.
- Consolidate NSHostingView islands — ConversationVC has 4 (header/composer/scrollButton/
  workspacePreview) + transcript. Each is its own SwiftUI render tree. Merging header+
  composer or dropping scrollButtonHost saves ~1–2 trees.
- SyntaxHighlighter builds `AttributedString` per code block; consider caching by
  (content, lang) or rendering lighter during streaming.

Getting to ~100 MB likely needs trimming the richer UI (syntax highlighting AttributedString
is inherently heavy). ~150 MB is reachable with the cheap levers alone.

## Notes
- Transcript is **pure SwiftUI** hosted in one NSHostingView. Do NOT reintroduce
  NSTableView / NSStackView transcript containers — both failed (see
  `swiftui-stability-notes.md`, memory `project_transcript_stability`).
- File preview is an in-window overlay driven by `WorkspacePanelModel.previewRoute`,
  observed in `ConversationVC.observeWorkspacePreview`. The standalone `WindowGroup("Workspace
  Files")` in `PaseoMacApp.swift` still exists for the old pure-SwiftUI path; the AppKit path
  does NOT use it.
