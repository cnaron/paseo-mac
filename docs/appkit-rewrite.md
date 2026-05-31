# PaseoMac — AppKit Rewrite (architecture · decision · status)

> **Living doc.** Read this first if you're picking up the redesign. It records
> the stability problem, the full-AppKit-vs-hybrid decision, the target
> architecture, what's changed, and where things stand — so the work survives
> context resets. Branch: **`design/v1`**. Updated 2026-05-31.

---

## 1. Why we're doing this

The user wants PaseoMac's UI redesigned to the Claude Design prototype **and** the
**instability fixed**. v0.3.0 (already deployed to Air) achieved the *look* by
re-skinning the existing SwiftUI views — but it kept the same SwiftUI internals,
so it's **still unstable**. The user's verdict: *"只是套了一个 UI 设计壳，内部架构
还是原来的 SwiftUI，所以还是不稳定. 换成 AppKit，全新去写，只用原来的功能和设计图."*

### Root causes of the instability (from `docs/instability-investigation-20260515.md` + `swiftui-stability-notes.md`)

1. **Scroll position lost / transcript blanks & rebuilds.** A reconnect (or slow
   RPC) replaces the whole `rows` array; SwiftUI re-inits the `List`/`ScrollView`
   and resets `@State`, including scroll offset.
2. **Main-thread CPU storms.** SwiftUI re-evaluates a ~3K-node view tree on every
   change; mutating an `@Observable` from `body` spun GraphHost to 99% CPU.
3. **Fragile imperative scroll glue** (`onChange → proxy.scrollTo`, composer-height
   measurement, streaming-animation timing) fighting the layout engine.

The investigation's own conclusion: *"这不是 SwiftUI 的根本问题，是这份实现的具体
bug"* — specifically, **the SwiftUI scrolling container for the transcript** is the
problem, not SwiftUI as a language.

---

## 2. Decision: Full AppKit vs Hybrid → **Hybrid**

| | Full AppKit (zero SwiftUI) | **Hybrid (chosen)** |
|---|---|---|
| Transcript scrolling | NSScrollView+NSTableView | **NSScrollView+NSTableView** |
| Sidebar / header / composer / settings | native AppKit views | **SwiftUI islands in NSHostingView** |
| Message body (markdown) | NSTextView / NSAttributedString | **SwiftUI `MDView` in a hosted cell** |
| Fixes the root cause? | yes | **yes** (transcript is the root cause; it becomes AppKit either way) |
| Reuses the built design layer | no — rewrite everything | **yes — all of it** |
| Markdown tables / code highlight / interactive cards | painful in NSAttributedString | already done in SwiftUI |
| Memory / perf ceiling | best | very good (bounded rows) |
| Effort / bug surface | weeks; high | days; moderate |

### Reasoning

- **The instability lives in the SwiftUI scroll *container*, not in SwiftUI views
  per se.** Replacing the transcript's `List`/`LazyVStack` with an AppKit
  `NSTableView` (stable row identity + diffable updates) removes the exact
  mechanism that lost scroll position and re-evaluated the whole tree. **Both
  options do this** — so both fix the root cause.
- The **only** thing full-AppKit adds beyond hybrid is rewriting *cell content*
  (markdown, cards, pickers) in native AppKit. That content is **not** the
  instability source — a hosted SwiftUI cell renders only its own small subtree and
  never touches the scroll container. So the extra work buys **marginal** stability.
- That extra work is **large and lossy**: GFM tables, code highlighting, file/auto
  links, and the interactive cards (permission Allow/Deny, AskUserQuestion option
  chips, todo, diffs) are straightforward in SwiftUI and genuinely painful in
  `NSAttributedString`/manual AppKit. It would also throw away the pixel-faithful
  design layer already built and approved.
- The app's selling point is **low memory**; NSHostingView cells are heavier than
  NSTextView, but for a **bounded** chat transcript (tens–hundreds of rows, not
  infinite) it stays well within the ~80–200 MB target.

**Conclusion:** Hybrid = AppKit owns *structure, scrolling, row lifecycle*; SwiftUI
owns *the look of individual cells/panes* as `NSHostingView` islands. This is
exactly what brief §9 specified. It fixes the real problem, reuses the design, and
ships in days not weeks.

### Residual risk + mitigation (the one thing to watch)

`NSHostingView` transcript cells must size + update cleanly:
- **Streaming row**: update the cell's `rootView` *in place* (don't recreate the
  cell) and call `noteHeightOfRows` — smooth, no flicker, no scroll jump.
- **Height**: `NSTableView.usesAutomaticRowHeights` + cells pinned with Auto Layout
  (NSHostingView reports intrinsic size).
- **If profiling shows jank on very long transcripts**: drop *only the markdown
  body* to an `NSTextView`/`NSAttributedString` renderer behind the same cell API,
  keeping the interactive cards in SwiftUI. Not needed for v1; documented as the
  escape hatch.

---

## 3. Target architecture

```
SwiftUI App (@main PaseoMacApp)  ── keeps lifecycle: Settings scene, Workspace-file
  │                                  window, ⌘-commands, environment injection
  └─ ContentView (thin SwiftUI shell)
       ├─ AppKitRoot  (NSViewControllerRepresentable)  ──────────────┐
       │    └─ RootSplitController : NSSplitViewController            │ AppKit
       │         ├─ sidebar item  → HostingVC(SidebarView island)     │ owns
       │         └─ content item  → ConversationVC                    │ window/
       │              ├─ header host  → NSHostingView(Header/Tabs)    │ split/
       │              ├─ transcript   → TranscriptVC (NSTableView) ★  │ scroll/
       │              └─ composer host → NSHostingView(ComposerCard)  │ rows
       │                                                              ─┘
       ├─ ToastStack (SwiftUI overlay)        ── thin modal layer stays SwiftUI:
       ├─ .sheet ConnectSheet / ImportSheet   ── low-frequency, not the hot path
       ├─ .sheet SettingsView
       └─ WindowConfigurator (forces light, full-size-content window)
```

★ = the stability fix. Everything else is a reused SwiftUI island.

### How updates flow (no SwiftUI scroll container in the hot path)

- **Islands (sidebar/header/composer/cards)** are real SwiftUI views in
  `NSHostingView`; they re-render themselves via Observation when `@Observable`
  state changes — exactly like a SwiftUI app, but each is a small isolated subtree,
  never the giant transcript tree.
- **Transcript** is AppKit. `ConversationVC` watches `app.selectedAgentId` via
  `withObservationTracking` and re-binds `TranscriptVC` to the new
  `ConversationViewModel`. `TranscriptVC` watches that VM's `rows` (same mechanism)
  and applies a **diffable update**:
  - rows unchanged, content changed (streaming) → update last cell in place + note
    its height;
  - rows appended → `insertRows` + reload the previously-last cell;
  - structural change (load-older / reconnect) → `reloadData` (infrequent).
  Scroll-to-bottom is managed manually (stable; only when already at bottom).

### Data model reused

`groupTurns(rows, provider:) -> [TurnGroup]` (in `Transcript.swift`, ported
coalescing logic) feeds the table. Each `TurnGroup` → one `NSTableView` row →
`NSHostingView(UserTurnView | AssistantTurnView)`.

---

## 4. What's changed (file map)

**Backend — UNTOUCHED** (proven daemon integration): `Network/*`, `ViewModels/*`,
`Models/*`, `Logging`, `SmokeTest`. The redesign wires to the same view models.

**Reused SwiftUI design layer** (built in design/v1, kept as islands):
- `Views/DesignSystem/` — `Theme` (terracotta tokens), `Glyph` (SF-Symbol map +
  provider logos), `Components` (IconButton, Seg2, DSSwitch, FlexWrap, pills…)
- `Views/Redesign/` — `SidebarView`, `UsagePanelView`, `HeaderBar`, `TabStripView`,
  `Notifications`, `MDView` (markdown), `Bubbles` (turn model + all message views),
  `ComposerCard`, `SettingsView`. `Transcript.swift` keeps **`groupTurns`** (reused)
  but its SwiftUI `TranscriptView` is **superseded** by the AppKit `TranscriptVC`.
- `SettingsStore` extended: `accentHex` / `fontSize` / `density`.
- `MarkdownRender.swift`: syntax palette → design tokens (the parser is reused).

**New AppKit layer** (`Views/AppKit/`):
- `AppKitRoot.swift` — representable + `RootSplitController` + `HostingVC`. ✅ done
- `ConversationVC.swift` — pane: header/composer islands + transcript + selection
  observation. ✅ done
- `TranscriptVC.swift` — the `NSTableView` transcript + diffable update + hosted
  cells. ⏳ **in progress (next)**

**Shell swap**: `ContentView` → hosts `AppKitRoot` + the SwiftUI modal layer
(replacing the SwiftUI `RootView` from v0.3.0; `RootView` is superseded).

**Superseded (still compiled; safe to delete once the AppKit path is verified)**:
old `AgentListView`, old `ConversationView`, old `ComposerView`, `PreferencesView`,
`UsagePanel`, `RootView`. Leaving them in keeps the build green during the swap.

---

## 5. Status & checklist

- [x] SwiftUI design layer (v0.3.0) — built, deployed to Air, looks right
- [x] Decision documented (this file): **hybrid**
- [x] AppKit shell — `AppKitRoot` + `RootSplitController` + `HostingVC`
- [x] `ConversationVC` — header/composer islands + selection observation + layout
- [ ] **`TranscriptVC`** — NSTableView + diffable update + NSHostingView cells ← NEXT
- [ ] `ContentView` → `AppKitRoot` (+ keep modal sheets/toasts)
- [ ] Build green on mini; fix
- [ ] Workspace panel (docked 变更/文件) — currently opens the file-preview window
- [ ] Notification event-wiring (bell/toasts from real turn/permission events)
- [ ] Polish: right-rail navigator, subagent section, pending-agent pickers, search
- [ ] Delete superseded old views
- [ ] Bump to **0.4.0**, package on mini, deploy to Air (on user's signal — Air off)

---

## 6. Build & deploy (mini-only — VPS can't compile Swift)

- Write on VPS (`/home/ubuntu/paseo-mac`, branch `design/v1`).
- Dev loop: `scripts/dev-mini-build.sh debug` — rsync VPS→mini (Tailscale,
  **excludes `/.vendor`**), `swift build` on mini, report.
- **`.vendor/swift-sodium/Clibsodium.xcframework`** is git-ignored and NOT on the
  VPS; mini has it. NEVER rsync `.vendor` with `--delete` (it wipes mini's binary →
  "Clibsodium does not contain a binary artifact"). The helper already excludes it.
- Release: `swift build -c release && scripts/bundle.sh release paseomac` →
  `build/PaseoMac.app`.
- Deploy: `scripts/deploy-to-air.sh` (run on mini) — waits for Air, quits, overwrites
  `/Applications/PaseoMac.app`, relaunches. Air is reachable from **mini** (Tailscale),
  not from the VPS.

---

## 7. Invariants & gotchas

- **Accent: terracotta `#d97757`** (user's final pick; `SettingsStore.accentHex`
  default). Light theme only for v1 — `WindowConfigurator` forces `.aqua`.
- **Reuse the backend; never rewrite the protocol/daemon client.**
- **`body` must be pure** — never mutate `@Observable` from a SwiftUI `body`
  (caused the 99% CPU storm). `conversation(for:)` only writes on first create.
- Provider logos (terracotta Claude spark) live in `Resources/{claude,codex,gemini}.png`.
- Version: 0.3.0 = SwiftUI re-skin (live on Air). 0.4.0 = AppKit hybrid (next ship).
