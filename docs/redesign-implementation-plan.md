# PaseoMac — Redesign Implementation Plan (design/v1)

> The build doc for rewriting PaseoMac's UI to the **Claude Design** final prototype
> (lody.ai-style, terracotta accent). This is a **fresh UI layer on the existing
> backend** — not a refactor of the views, a rewrite. Source of truth for the look:
> the prototype bundle (`paseo-mac.html` + `src/*.jsx` + `screenshots/`), already
> read in full. This doc translates it into Swift.

## 0. Principle: keep the backend, rewrite the presentation

The daemon integration is hard-won and fragile (relay, E2EE, streaming, reconnect).
**We keep it 100% intact** and write a new SwiftUI presentation layer on top, wired
to the same view models.

| Layer | Decision |
|---|---|
| `Network/` (DaemonClient, Protocol, RelayChannel, RelayCrypto, ConnectionOffer) | **KEEP as-is** |
| `ViewModels/` (AppViewModel, ConversationViewModel) | **KEEP**; add light hooks only (settings, notifications, panel state) |
| `Models/` (PasteAndDrop, WorkspaceFilePreviewRouting), Logging, SmokeTest | **KEEP** |
| `SettingsStore` | **EXTEND**: accent, fontSize, density (design's real prefs) |
| `Views/` (all) + `ContentView` + `PaseoMacApp` | **REWRITE** to the design |

Behavior that already works (row grouping/coalescing, streaming merge, auto-scroll,
queue, optimistic send, permission flow, paste/drop) is **ported**, not reinvented —
we restyle the container, keep the logic.

## 1. Visual language — design tokens (the foundation)

Lifted verbatim from `paseo-mac.html` `:root`. Default accent is **terracotta
`#d97757`** (the user's final pick — `app.jsx` `SETTINGS_DEFAULTS.accent`), not the
blue CSS fallback. Light theme ships first; tokens are structured so a `[dark]`
variant drops in later.

### Surfaces
| token | light |
|---|---|
| desktop | `#d7d6d2` |
| sidebar-bg | `#f5f5f3` |
| content-bg | `#ffffff` |
| divider | `#e7e7e3` |
| divider-strong | `#dcdcd7` |
| hover | `rgba(0,0,0,0.045)` |
| hover-strong | `rgba(0,0,0,0.07)` |

### Text
`text #1d1d1f` · `text-2 #6e6e73` · `text-3 #9a9a9f` · `text-faint #b6b6ba`

### Accent (terracotta default; 4 swatches in Settings → 外观)
| | accent | press | tint (bubble/sel-fill) | sel (row) | ring | send |
|---|---|---|---|---|---|---|
| 陶土 (default) | `#d97757` | — | `#f9ece5` | `#f6ece6` | `rgba(217,119,87,0.32)` | `#fae4d9` |
| 蓝 | `#2c6ce6` | `#1f57c4` | `#e3ebfc` | `#e7eaf7` | `rgba(44,108,230,0.32)` | `#dbe6fd` |
| 天蓝 | `#5b8def` | — | `#e9effd` | `#ecf0fb` | `rgba(91,141,239,0.32)` | `#e3ecfd` |
| 青 | `#2f8f7d` | — | `#e0f1ec` | `#e4f0ec` | `rgba(47,143,125,0.32)` | `#dcefe7` |

### Semantic status
`green #34a853` (soft-bg `#e6f3e2`, soft-tx `#3f8e3a`) · `cyan #32ade6` ·
`red #e0524b` (soft-bg `#fbe7e6`) · `orange #e08a2b` (soft-bg `#fbeedb`) ·
`gray-dot #b3b3b8`. Code chip: bg `#ededeb`, tx `#2a2a2d`.

### Type / shape
Body `--fs 15.5px` (Settings slider 13–18), line-height 1.62, system font + SF Mono.
Bubble gap 18px (compact 12). Radii: row 8, chip 8, card 12, bubble 15, composer 17,
window 11. Sidebar width 290. Shadows: card `0 1px 2px /.05`, pop `0 8px 30px /.16`,
window `0 24px 70px /.32`.

### Status colors (used widely — keep meanings consistent)
running=green · waiting=orange · done=cyan · idle=neutral. Permission-mode risk:
build=green, accept/auto=orange, plan=blue, bypass/full=red. Usage bar: <70% accent,
≥70% orange, ≥90% red.

## 2. Information architecture (final, per the chat)

```
Window (.win, radius 11, shadow-win)
├─ Sidebar (290, #f5f5f3)
│   ├─ workspace switcher (avatar · name · ▾ → daemon menu)
│   ├─ 新对话 (→ directory picker popover)
│   ├─ Chats  (four-state rows: provider logo avatar + pulse-ring/badge + title + …/dir·state + time)
│   ├─ 显示归档 · 导入会话…
│   ├─ Usage panel  (host header · 5h/7d/Sonnet/Opus bars · Codex/Gemini/CC-version)
│   ├─ connection footer (●已连接 · host·vX · ⚙→Connect)
│   └─ utility bar  [⚙ pref] [? help] [🗄 archive]  ……  [⤵ filter]
└─ Content
    ├─ header (52): chat-title ········ Working… · [Open(GitHub)] · [+N −M changes] · [🔔 bell] · [⋯] · [▢ panel]
    ├─ tab strip (41): [logo title ✕] … [+]
    ├─ transcript (max-w 760, centered) + right-rail navigator
    └─ composer-wrap: composer card  (NO host/access footer, NO bottom status bar — both removed)
└─ Workspace panel (docked right, shares the [▢] toggle, own ✕): 变更 | 文件
└─ Overlays: Settings modal · Connect dialog · toast stack (top-right) · notification center (bell dropdown)
```

Removed vs the brief: projects-by-host, bottom status bar, header usage chip,
composer host/access footer. Cost/context now lives only in the composer's
`31% · $0.41` bar.

## 3. Swift file plan (new `Views/` tree)

```
Views/
  DesignSystem/
    Theme.swift          – Color/Font/Metric tokens, accent palette, Theme env, light(+dark stub)
    Glyph.swift          – design line-icon set → SF Symbols map; ProviderGlyph (claude/codex/gemini PNG)
    Components.swift      – PillButton, IconButton, Card, Chip, Seg2, Toggle/Switch, Popover, Badge, ThinkingDots
  Shell/
    RootView.swift       – split (sidebar | content | panel), overlays (settings/connect/toasts)
  Sidebar/
    SidebarView.swift     – workspace switcher, 新对话, Chats, archived/import, footer, util bar
    ChatRow.swift         – four-state row (avatar + ring + badge)
    UsagePanelView.swift  – quota bars + provider/version rows
  Conversation/
    ConversationView.swift – header + tab strip + transcript + composer assembly (per agent)
    HeaderBar.swift        – title/working/Open/changes/bell/⋯/panel-toggle
    TabStripView.swift
    TranscriptView.swift   – scroll + grouping host + right-rail + jump-to-bottom (ports current logic)
    Bubbles/
      UserTurnView.swift   – stamp + sent-check + attachments + bubble + show-more
      AssistantTurnView.swift – avatar/meta header (+compact/rail variants) + disclosures + blocks + footer/pill
      ToolClusterView.swift   – rows + badges + expandable text/before-after/diff
      InteractionCards.swift  – permission / AskUserQuestion / attention / todo
      TurnExtras.swift        – ContextRing, TurnPill, ThinkingIndicator, ModelMeta
  Markdown/
    MarkdownView.swift    – restyle of MarkdownRender to `.md` tokens (headings w/ rule, code chips, pathlinks, tables, quotes, code blocks + highlight)
  Composer/
    ComposerCard.swift    – grip, attachments, queue, subagents, input (ComposerTextView), action row
    Pickers.swift         – model / permission(risk) / thinking / provider / worktree, feature toggles
  Workspace/
    WorkspacePanelView.swift – docked 变更|文件, no tree/breadcrumb, code viewer (line# + wrap + hl + find), md/image/binary
  Settings/
    SettingsView.swift    – modal: 通用 / 外观 / 用量统计 / 连接 / 模型
    UsageStatsView.swift  – range switch + stat cards + per-model line chart
    ConnectDialog.swift   – server URL + recent hosts
  Notifications/
    NotificationsView.swift – ToastStack + NotifBell + center; NotificationStore in VM
```

Existing `ConnectSheet`, `ImportSessionSheet`, `PreferencesView`, `UsagePanel`,
`AgentListView`, `ConversationView`, `ComposerView`, `MarkdownRender`,
`WorkspaceFilePreviewWindow/Routing`, `ComposerTextView` are superseded or folded in;
`ComposerTextView` (NSTextView input) and `WorkspaceFilePreviewRouting` are **reused**.

## 4. Component mapping (design CSS class → Swift view)

| design | Swift |
|---|---|
| `.win / .traffic` | RootView window chrome (real NSWindow traffic lights) |
| `.sidebar / .ws-switch / .sb-action` | SidebarView |
| `.chat-row + .chat-ava .ava-badge .run/.wait` | ChatRow (status → ring+badge+subtitle color) |
| `.cv-header + .hdr-pill(.diff) + bell` | HeaderBar |
| `.tab-strip / .tab` | TabStripView |
| `.turn-user / .ubub / .u-stamp / .u-atts` | UserTurnView |
| `.turn-asst / .asst-head / .disc` | AssistantTurnView |
| `.tool-cluster / .tool-row / .diff-*` | ToolClusterView |
| `.icard.perm/.ask/.attn/.todo` | InteractionCards |
| `.md *` | MarkdownView |
| `.composer / .comp-bar / .pillbtn / .send-btn` | ComposerCard + Pickers |
| `.queue / .subagents / .comp-attach` | ComposerCard sub-views |
| `.fp-panel / .fp-tab / .code-row` | WorkspacePanelView |
| `.modal.prefs / .prefs-nav / .set-row / .switch / .swatch / .range` | SettingsView |
| `.dialog / .host-row` | ConnectDialog |
| `.toast / .bell-count / .notif-row` | NotificationsView |
| `.ctx-ring / .turn-pill / .tdots / .rail` | TurnExtras / TranscriptView |

## 5. Data wiring (mock → real)

The prototype's `data.jsx` is mock; each piece maps to existing model/VM state:

| prototype | real source |
|---|---|
| `CHATS[]` + status | `AppViewModel.agents` + `liveStatus`; status→{running,waiting(requiresAttention),done(just-finished),idle} |
| `WORKSPACE.host/daemonVersion` | `AppViewModel.daemonHostname/daemonVersion` |
| `USAGE` (5h/7d/sub/codex/gemini/cc) | `AppViewModel.usageData` + providers + codexSessionStats + claudeCode*Version |
| `TRANSCRIPT` blocks | `ConversationViewModel.rows` grouped (existing `groupRows`) |
| `MODELS/PERMISSION_MODES/THINKING_LEVELS` | `ProviderSnapshot.models/modes` + model.thinkingOptions |
| `CHANGES` / `FILES` / `FILE_TREE` | daemon `fileExplorer` RPC + a new `git status`-style changes RPC (fallback: hide 变更 if unavailable) |
| `NOTIFICATIONS` | derived in a new `NotificationStore` from turn-completed / permission / attention / error stream events |
| Settings accent/fontSize/density | `SettingsStore` (new keys) |

Anything the daemon can't supply yet (e.g. uncommitted-changes list) degrades
gracefully — the tab shows "暂无变更" rather than breaking.

## 6. Build order (each phase compiles on mini before the next)

0. **Foundation** — Theme, Glyph, Components. (compiles standalone)
1. **Shell** — RootView split + window chrome + empty content; app launches, connects, lists agents in a stub sidebar.
2. **Sidebar** — full SidebarView + ChatRow + UsagePanelView, wired to AppViewModel.
3. **Header + tabs** — HeaderBar + TabStripView.
4. **Transcript** — TranscriptView + all bubbles + MarkdownView (port grouping/scroll). The big one.
5. **Composer** — ComposerCard + Pickers (reuse ComposerTextView).
6. **Workspace panel** — WorkspacePanelView (reuse WorkspaceFilePreviewRouting).
7. **Settings + Connect** — SettingsView + UsageStatsView + ConnectDialog.
8. **Notifications** — toasts + bell + center + NotificationStore.
9. **Polish** — empty/loading/error states, dark-mode token pass, version bump.

## 7. Build & deploy pipeline

- **Write** on VPS (`/home/ubuntu/paseo-mac`, branch `design/v1`).
- **Build** on **mini** (`/Users/cc/Public/Project/paseo-mac`, Swift 6.2 / Xcode 26):
  sync code (git fetch design/v1, or rsync over Tailscale if GitHub is slow) →
  `swift build -c release` → `scripts/bundle.sh release paseomac` → `build/PaseoMac.app`.
- **Bump** `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist`
  each ship so the deployed binary is identifiable.
- **Deploy** to **Air**: from mini, overwrite `/Applications/PaseoMac.app` and relaunch.
  (Air is Tailscale-reachable from mini; it was offline from the VPS during recon.)

## 8. Non-goals / risks

- **Light theme first.** Dark mode tokens are structured but not pixel-tuned (design
  itself ships light; "深色即将推出").
- **AppKit `NSTableView` transcript migration** (brief §9) is **out of scope for this
  pass** — we keep the SwiftUI transcript but fix the known instability (stable row
  ids, no whole-array replace) as part of TranscriptView. The full NSTableView port is
  a later, separate phase. (Fittingly, it's the very task the mock agent is doing.)
- **No protocol/daemon changes.** Uncommitted-changes data may be unavailable until a
  daemon RPC exists; the 变更 tab degrades gracefully.
- Can't compile on the VPS (old toolchain) — every phase is verified on mini.

---

*Plan authored 2026-05-31 for branch `design/v1`. Implementation follows §6 in order.*
