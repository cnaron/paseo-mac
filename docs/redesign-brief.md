# PaseoMac — UI Redesign Brief

> **For a design tool / design agent.** This document is the single source of truth for redesigning PaseoMac's interface. It describes (1) what the app is, (2) the target visual direction, (3) **every existing feature, screen, component and state that must be preserved**, and (4) the engineering constraints the new design must respect.
>
> **The ask, in one line:** keep 100% of today's functionality, but re-skin and re-organize the UI to match the clean, structured look of the reference screenshot — and lay it out so it can be built on an **AppKit shell with SwiftUI content islands** (see §9), because the current pure-SwiftUI build feels unstable.
>
> Designer latitude is explicitly invited (§10): the IA below is a strong starting point, not a cage. Expand it.

---

## 1. What PaseoMac is

PaseoMac is a **native macOS client for Claude Code / Paseo agents** that run remotely on a server or VPS. It is a lightweight alternative to the official Electron Paseo app: it speaks the same end-to-end-encrypted relay protocol, connects to the same daemon, and sees the same agents — but renders natively, uses ~80 MB instead of ~450 MB, and bundles no Chromium.

- **Platform:** macOS 14+ (Sonoma). Desktop only. Mouse + keyboard, light & dark mode, resizable window (min 900×600).
- **User:** a developer who runs AI coding agents (Claude Code, Codex, Gemini, OpenCode, Copilot, etc.) on a remote machine and wants a fast, calm, Mac-native cockpit to drive them from.
- **Mental model:** the app is a **chat client for autonomous coding agents**. Each "agent" is a long-lived conversation bound to a working directory on the remote host. The user reads the agent's streamed reasoning / tool calls / replies, approves permission requests, and steers via a composer.
- **Connection:** one daemon at a time, reached over a relay (`wss://…`) using a pairing offer that pins the daemon's public key. Works fully offline for reading cached history.

The redesign is **purely the client UI**. The protocol, the daemon, and the feature set stay the same.

---

## 2. Design goals

1. **Match the reference aesthetic** (§3): clean, quiet, well-structured. Clear hierarchy, generous whitespace, a single restrained accent color, native macOS materials.
2. **Lose nothing.** Every capability in §5–§7 must have a home in the new design.
3. **Feel native and stable.** Standard macOS controls, real sidebar/toolbar/status-bar chrome, light+dark, Dynamic Type-ish font scaling. The transcript must never "flicker, jump, or blank out" (today's biggest complaint — see §9).
4. **Calm density.** This is a tool people keep open all day. Prefer legible, slightly roomy spacing over cramming. Information should be glanceable, not loud.
5. **Designed for an AppKit + SwiftUI hybrid build** (§9). Favor layouts that map to native macOS structures (NSSplitView, toolbar, source list, status bar, tab bar, table/collection rows).

---

## 3. Reference / target aesthetic

The user supplied a screenshot of a polished Paseo client as the north star. (Designer: ask the user for `docs/assets/target-reference.png` and study it directly.) Salient features of that reference, all of which we want:

**Overall:** light theme, two-pane window with standard traffic-light controls, a thin chrome, lots of breathing room. Quiet grays and a soft blue accent; almost no hard borders — separation is done with whitespace and very light dividers.

**Left sidebar (~290 pt):**
- **Workspace switcher** at top — an avatar + "cnaron's workspace" + a chevron (a dropdown to switch workspace/account).
- A prominent **"New conversation"** action (pencil icon).
- A **"Chats"** section: recent conversations as rows, each with an icon, a truncated title, and a right-aligned **relative timestamp** ("1mo").
- A **projects section grouped by host** — header like **"NarondeMacBook-Air.local 的项目" ("…'s projects")**, then folder rows ("paseo-mac").
- A **bottom utility toolbar**: small icon buttons — settings (gear), help (?), archive (box), filter (sliders).

**Main area:**
- A **header bar**: a section title ("对话" / "Conversation") with a leading glyph on the left; an **overflow "…" menu** and a **sidebar-collapse toggle** on the right.
- A **tab strip** under the header: open conversations as tabs (each with the agent's provider glyph + truncated title) and a **"+" new-tab** button. Multiple conversations open at once.
- The **transcript**: user messages right-aligned in a soft tinted bubble; assistant turns left-aligned with a **provider avatar**, a **timestamp + profile label** ("4/15/2026 09:44 AM · default"), a collapsible **"Completed work" disclosure**, then richly rendered markdown (bold labels, bullet lists, inline-code chips for paths), and a **per-turn footer** (context-window %, copy button, elapsed time "8s").
- The **composer**: a large rounded multiline field; bottom row with a **model chip** ("Claude Code") on the left and **attach + send** controls on the right.
- A **status bar** pinned to the very bottom: the **remote host name** ("VM-4-6-ubuntu") on the left; an **access-level badge** ("完全访问" / "Full access") on the right; a secondary line with **run status** ("Stopped"), a **CLI-exit chip** ("[cli exited: 0]"), and a **"keep-awake" pill** ("禁止休眠中" / "Preventing sleep").

**Net change vs. today:** the current app has all the *features* but a flatter IA (a single "Agents" + "Archived" sidebar list, no workspace switcher, no project grouping, no conversation tabs, no bottom status bar). The redesign should adopt the reference's richer structure: **workspace switcher → chats → projects-by-host** in the sidebar, **tabs** in the main area, and a **status bar** at the bottom.

---

## 4. Information architecture (target)

```
┌───────────────────────────────────────────────────────────────────────────┐
│ ●●●  PaseoMac                                                    [⌘ toolbar] │
├──────────────────────┬────────────────────────────────────────────────────┤
│ SIDEBAR (source list)│ MAIN                                                 │
│                      │ ┌────────────────────────────────────────────────┐  │
│ ▸ Workspace switcher │ │ Header: title · ⋯ menu · sidebar toggle         │  │
│ ✎ New conversation   │ ├────────────────────────────────────────────────┤  │
│                      │ │ Tab strip: [agent A] [agent B] … [+]            │  │
│ CHATS                │ ├────────────────────────────────────────────────┤  │
│  • Agent 1     2h    │ │                                                  │  │
│  • Agent 2     1d    │ │   TRANSCRIPT (scrolling)                         │  │
│  • Agent 3     1mo   │ │     user bubble (right)                          │  │
│                      │ │     assistant turn (left, timeline rail):        │  │
│ <HOST> 的项目         │ │       · reasoning (collapsible)                  │  │
│  📁 project-a        │ │       · tool calls (cluster, expandable)         │  │
│  📁 project-b        │ │       · assistant markdown                       │  │
│                      │ │       · permission / question prompts            │  │
│ ARCHIVED (toggle)    │ │     per-turn meta (model · duration)             │  │
│                      │ │     turn status pill (elapsed / done)            │  │
│ ── usage panel ──    │ ├────────────────────────────────────────────────┤  │
│ ── connection ────   │ │ Composer card (attachments, pickers, send)      │  │
│ [⚙][?][🗄][⤵]         │ ├────────────────────────────────────────────────┤  │
│                      │ │ Status bar: host · status · cli · access · awake│  │
└──────────────────────┴────────────────────────────────────────────────────┘
```

Three persistent regions: **Sidebar**, **Conversation (tabs + transcript + composer)**, **Status bar**. Plus modal/secondary surfaces: Connect sheet, Import-session sheet, Preferences window (4 tabs), Workspace-file preview window, and a standalone menu-bar usage widget.

---

## 5. Sidebar — full component inventory

Everything below exists today and must remain reachable. Reorganize freely into the §3 structure.

### 5.1 Workspace / account switcher *(new in target, designer to define)*
Top-of-sidebar control showing the current workspace/account with a dropdown. Today PaseoMac is single-daemon; map this to **the connected daemon identity** (host name + daemon version) with the dropdown offering: switch/återpair daemon (opens Connect sheet), disconnect, connection settings. Room to grow into true multi-workspace later.

### 5.2 New conversation
- **"New Agent"** primary action. Opens a **directory picker popover**:
  - Header "Choose directory".
  - A scrollable list of **suggested directories** (recent agents' working dirs + their parents, de-duplicated, newest first), each row = folder icon + dir name + full path (truncated middle), hover-highlighted.
  - A **custom path** text field at the bottom ("/path/to/project") with a return-to-confirm affordance.
- Picking a directory creates a **pending agent**: the sidebar shows a transient **"New conversation"** row (with a cancel ✕), and the main area switches to an empty "type a message to start" state. The first sent message actually creates the agent on the daemon.
- Disabled while disconnected.

### 5.3 Chats list (active agents)
Today: a **"Agents"** section listing every active (non-archived) agent. Each **agent row**:
- **Status dot** (8 pt): green = running (pulses when the *selected* agent is actively working), cyan = idle, red = error/failed, accent = requires attention, gray = other. White hairline ring so it stays visible on selection highlight.
- **Provider icon**: real brand logo for Claude / Gemini / Codex (PNG), SF-Symbol fallback for others (antigravity, opencode, copilot, pi…).
- **Display name** (title if set, else short id) — one line.
- **Subtitle**: shortened cwd ("…/parent/dir"); when running, shows "…/dir · running" in green.
- **Tooltip**: full cwd.
- **Context menu**: Rename… (inline alert with text field; requires daemon ≥ 0.1.79), Delete Agent (archive).
- **Swipe action** (trailing, full-swipe): Delete → archive.
- Selecting a row opens its conversation.

> Target reorg: rename "Agents" → **"Chats"**, add a right-aligned **relative timestamp** per row (we have `lastUserMessageAt` / `updatedAt`), and optionally group/sort.

### 5.4 Projects-by-host grouping *(new in target)*
The reference groups workspaces under a **"<host> 的项目"** header. We have the data to synthesize this: every agent carries a `cwd`; agents also carry the daemon host. Designer should define a **projects section** that groups conversations by their working directory / repo, with folder rows. This is the main *new* IA element — it gives the flat agent list structure. (Existing per-agent data: cwd, provider, git remote URL via `fetchGitHubUrl`.)

### 5.5 Archived section
- A **"Show archived / Hide archived"** toggle row (clock icon) loads/clears archived agents on demand (only when connected).
- When loaded, an **"Archived"** section lists archived agents (archive-box icon, dimmed). Row context menu: **"New Conversation Here"** (creates a fresh agent in that cwd).
- Opening an archived conversation shows a read-only banner with **"Resume conversation"** / **"New conversation"** actions (see §6.6).

### 5.6 Import session
- **"Import session…"** row (tray-and-arrow-down icon). Opens the Import-session sheet (§8.2). Disabled while disconnected.

### 5.7 Inline banners (conditional, above the footer)
- **Daemon version mismatch** banner: when the daemon version is outside the supported prefix — title, explanation (host + version + expected), dismiss ✕.
- **Claude Code update available** banner: orange, "Claude Code update available · v{latest} ready", with an **Update** button (shows spinner while updating).

### 5.8 Usage panel (conditional, near the bottom)
Appears when the optional usage endpoint is configured (Preferences → Integration). Sections, top to bottom:
- **Claude API quota**: plan name + refresh button; horizontal **usage bars** for **5h** and **7d** windows (label + progress bar + percentage + reset countdown like "3h 12m"/"2d 4h"/"now"); optional **7-day Sonnet** and **7-day Opus** sub-quota rows; "Updated HH:mm" footer. Bar color thresholds: **blue < 70% < orange < 90% < red**.
- **Codex (ChatGPT) session stats** (if a Codex provider is ready): a link row to chatgpt.com usage; shows aggregated **cost · tokens · N running** across Codex agents, or a "click to view usage" hint.
- **Gemini free tier** (if a Gemini provider is ready): a link row to AI Studio with "free tier: 60 RPM / 1000 RPD".
- **Claude Code version**: "Claude Code · v{current}" with check-for-updates refresh; when an update exists, shows "v{current} → v{latest}" in orange with an **Update** action; else "· latest".

### 5.9 Connection footer
- **Status dot + label**: Connected (green) / Connecting… (yellow) / Disconnected (red) / Offline (gray).
- When connected, a secondary line: **"{host} · v{daemonVersion}"** — the at-a-glance "which daemon am I on" line.
- A **gear button** opens the Connect / connection-settings sheet.

### 5.10 Bottom utility toolbar *(from reference)*
The reference shows a row of small icon buttons at the very bottom: **settings · help · archive · filter**. Map to: Preferences (⌘,), Help/Credits, Archived toggle, and a future **filter/sort** control for the chats list. Designer to define the filter affordance.

### 5.11 Empty / loading states
- No agents: a centered "No agents — Connect and your agents will appear here."
- Loading archived: inline spinner.

---

## 6. Conversation area — full component inventory

### 6.1 Tab strip *(from reference)*
Multiple open conversations as **tabs** under the header: each tab = provider glyph + truncated agent title; a **"+"** opens a new agent (directory picker) in the current dir. Active tab underlined/highlighted. (Today the app shows one conversation at a time bound to `selectedAgentId`; the redesign introduces real tabs. Closing a tab ≠ archiving.)

### 6.2 Header / toolbar
The conversation has a navigation title (agent display name, or "New Conversation") and a **toolbar** with these actions (all exist today):
- **Usage chip**: compact **$cost** + a **context-window ring** ("12k/200k") for the selected agent; hover tooltip breaks down input/cached/output tokens, cost, context. Color ring: accent < 70% < orange < 90% < red.
- **"Working…" indicator**: a small spinner + "Working…" while the agent is mid-turn.
- **New agent in same dir** ("+").
- **Branch / continue-with-another-provider** (branch glyph): a menu of other providers ("Claude", "Codex", "Gemini"…); picking one forks this conversation's transcript into a new agent on that provider. Disabled if there's no content or no other ready provider; shows a spinner while branching.
- **Search** (magnifier): toggles an inline search bar (see 6.7).
- **Open file-preview window** (folder): opens the workspace file browser/preview window (§8.4) at the agent's cwd.
- **Open on GitHub** (only when the cwd resolves to a GitHub remote): opens the repo in the browser.

### 6.3 The transcript (message list)
A vertically scrolling list of turns, newest at the bottom, **auto-scrolls to bottom** on new content when the user is already near the bottom (otherwise shows a **"jump to bottom"** pill with an unread dot). Anchored to the bottom by default. **Bottom breathing room is sized to the live composer height** so the last message is never hidden behind the composer.

Rows are grouped/coalesced: consecutive assistant/reasoning chunks merge into one bubble; consecutive tool calls collapse into a **tool cluster**.

**Message / turn types** (every one must be designed):

| Kind | Today's treatment | Notes |
|---|---|---|
| **User message** | Right-aligned bubble, soft accent tint, rounded 12 pt, max ~560 pt wide, hugs short content. Optional image grid above text. Timestamp below. Long messages (>500 chars) collapse with a fade + "Show more/less". Context menu: Copy text; **Rewind** submenu (see 6.5). | The only right-aligned element. |
| **Assistant message** | Left side, on a **timeline rail** (small clock glyph + thin vertical connector to the next step). Full markdown (see §6.4). Below the last bubble of a turn: a **model·duration meta chip** and a **Copy** button (copies the whole turn's text). | The reference's "avatar + timestamp + default + Completed-work disclosure" header is a richer version of this — designer to fold in. |
| **Reasoning / "Thinking"** | Timeline rail, a collapsible **"Thinking · N words"** disclosure; expanded body is italic, secondary. | Streams live. |
| **Thinking indicator** | While the agent is working but hasn't emitted content yet: "Thinking" + animated dots on the rail. | Placeholder before first token. |
| **Tool call (cluster)** | Bolt glyph on the rail; each tool = compact row: tool icon + **name** + **target** (file path is a green tappable link → file preview; other targets dimmed) + a badge ("Script"/"Edit") + status suffix (running/failed/canceled) + expand chevron. Expanded detail renders one of: plain/mono text (shell output, file content), **before/after** code blocks, or a **unified diff** (green/red/purple line coloring). | Read → Edit → Bash collapse into one tight cluster. |
| **Permission request** | Shield glyph; "Permission Required" with **Allow** (green) / **Deny** buttons. Collapses once resolved. | Blocks the turn until answered. |
| **AskUserQuestion** | Question-bubble glyph; "Question from agent", each question rendered with its **option chips** (wrap-flow, single/multi-select) + an "Other (type a custom answer)" field; **Submit** (disabled until every question answered) / **Skip**. | Structured Q&A from the agent. |
| **Attention required** | Exclamation glyph; "Attention Required" + reason text. Collapses when resolved. | Informational. |
| **Todo list** | Checklist glyph; the agent's task list. | |
| **Compaction** | Italic accent note (context was compacted). | Codex. |
| **Error** | Red text on the rail. | |

**Right-rail navigator:** a thin floating **timeline of user messages** on the right edge — a vertical line of dots, one per user message, hover shows a **preview card** of that message and clicking scrolls to it; a "load earlier" chevron at the top. (A minimap of the conversation.)

**Load earlier:** a "Load earlier messages" pill at the top when older history exists (paginates backward).

**Per-turn status bar:** at the end of the live/last turn — a pill with **animated dots + elapsed timer** while working, or a **checkmark + final duration** when done.

### 6.4 Markdown rendering (assistant & user content)
Custom renderer (must stay faithful, this is a known pain point — see §9). Supported blocks: **headings** (H1/H2 get an underline divider), **paragraphs** (line-spacing user-configurable), **bullet & ordered lists** (roomy 10 pt item gap), **blockquotes** (left accent bar, tinted bg), **GFM tables** (bordered, zebra rows, header tint), **fenced code blocks** (language label + copy button + lightweight syntax highlighting for ~12 languages), **horizontal rules**, inline **bold/italic/strikethrough**, **inline code** (gray chip), **auto-linked URLs**, and **auto-linked file paths** (absolute `/path:line` → green tappable link that opens the file-preview window at that line). Block reveal is animated on final render, instant during streaming.

> Spacing values are intentionally tuned to match the upstream Paseo web client and are easy to regress — treat the current rhythm as a baseline to match, not to "fix" blindly.

### 6.5 Rewind
From a user message's context menu (when the agent supports it): **Rewind Conversation**, **Rewind Files**, or **Rewind Conversation and Files** — restores the conversation/working-tree to that point; the rewound text drops back into the composer.

### 6.6 Archived conversation banner
When viewing an archived agent: a material banner "This conversation is archived" with **Resume conversation** (re-activates; shows a "Resuming…" strip while the daemon spins it back up) and **New conversation** (fresh agent in same cwd).

### 6.7 Inline search
A toggle (magnifier / ⌘F) reveals a search bar (field + clear + Done). Filters the transcript to matching messages and shows a result count / "No results"; Esc closes.

### 6.8 New-conversation empty state
For a pending agent: a centered "Type a message to start the conversation" (or an optimistic user bubble + "Starting agent…" spinner once sent, or an error state with the message returned to the composer).

---

## 7. Composer — full component inventory

A floating rounded **card** (max ~720 pt, centered) pinned above the status bar. Top-to-bottom:

- **Subagent section** (only if the agent has subagents): a collapsible pill "**N subagents · M running**" expanding to a list of child agents (status dot + name + mode + archive ✕; click focuses the child).
- **Queued-messages strip** (only if messages are queued): header "Queued · click to edit" (or, if the turn looks stuck, an orange "Previous turn looks stuck…") + a **"Send anyway"** escape button; then each queued message as a row (preview + image indicator + edit ✏️ + remove ✕).
- **Resize grip:** an 8 pt zone at the top edge — drag to grow the text area, double-click to reset (cursor changes to resize).
- **Attachment chips** (if any): a horizontal strip of **image thumbnails** (64 pt, remove ✕) and **text-file chips** (name + char count, remove ✕).
- **Drop-error** text (if a dropped file couldn't be attached).
- **Text input:** a native multiline field (placeholder "Reply…"). Supports **⌘V image paste**, **file/image drag-drop** (images → vision attachments; text/source files → inlined as a code block; large pastes → auto-saved as a `Pasted-….txt` attachment), **up/down arrow history** of sent messages, and **IME-safe** editing (CJK input methods). Height is user-configurable and drag-resizable.
- **Bottom action row:**
  - **"+" attachment button** → file picker (images, text, source, json, xml, csv, shell).
  - **Inline context bar**: a slim progress bar + **context %** + **session cost** for the active agent (same thresholds as the usage chip).
  - **Right-aligned control cluster** (provider-dependent menus):
    - **Feature toggles/selects** (e.g. OpenCode "Auto Accept" shield, plan-mode, fast-mode) — icon buttons / dropdowns, colored when enabled.
    - **Permission-mode picker** (shield icon; menu of modes like Build / Accept Edits / Plan / Bypass / Full-access; icon color encodes risk: red = bypass/full, orange = accept/auto, blue = plan, green = auto-review).
    - **Model picker** (text menu; current model label; gated/"blocked" models hidden unless current; primary vs secondary split for long lists).
    - **Thinking-level picker** (text + chevron; off/low/medium/high/max/xhigh per model).
    - For a **pending new agent**, the same cluster plus a **provider picker** and a **worktree toggle** (spin up a throwaway git worktree, auto-archive on finish).
  - **Send button** (circle, up-arrow). While the agent is working it splits into **Queue (⌘↩)** + **Interrupt (⌘⇧↩, stop-square)**. Disabled when there's nothing to send.

**Send semantics:** if the agent is busy and the turn isn't stale, the message **queues** (flushed one-per-turn-completion); if idle, it sends immediately; **Interrupt** cancels the current turn and sends now; **Send anyway** force-cancels a stuck turn and flushes the queue. Drafts and the queue persist across app restarts (per agent).

---

## 8. Secondary surfaces

### 8.1 Connect sheet
First-run / re-pair flow (min 520×340). Title "Connect to Paseo Daemon", an explanation, a **monospace text area** to paste a pairing offer (accepts JSON, base64, `https://app.paseo.sh/#offer=…`, or `paseo://…`), an error line, and **Cancel / Connect** (Connect shows "Connecting…"). Surfaces automatically on first launch or when disconnected with no saved offer.

### 8.2 Import-session sheet
Browse & import existing CLI sessions (min 560×420). Title + refresh; explanation; then a **list of importable sessions** — each row: provider badge (Claude/Codex/OpenCode/Pi), title, relative activity time, a 2-line prompt preview, and the cwd (mono). Tapping imports it as a paired agent. States: scanning spinner / "No sessions found" / list. Close button.

### 8.3 Preferences window (4 tabs, min 520×420)
- **General** — Typography: **Font size** slider (0.85×–1.5×), **Line spacing** slider (0–10 pt). Layout: **Bubble gap** slider (8–28 pt), **Composer height** slider (44–420 pt). **Reset to Defaults**.
- **Integration** — **Claude Usage**: endpoint URL field + token (secure) field + explainer (powers the §5.8 quota panel). **Model Access**: count of auto-blocked models + Reset (models get auto-blocked when claude.ai returns "extra usage required for 1M context").
- **Daemon** — **Global system prompt**: a mono text editor the daemon appends to every new agent, with Save + save-state (saving / saved / unsaved / error).
- **Usage (stats)** — "Last computed" + Refresh; a **recent-activity grid** (date · sessions · messages · tool calls · tokens, up to 14 days); a **totals-by-model grid** (model · input · output · cache read · cache write · API-equivalent cost) with a totals row; explainer that the API-equivalent cost is notional under a flat subscription.

### 8.4 Workspace file-preview window
Standalone window (min 900×620) opened from file links or the folder toolbar button. Header: doc icon + file path (truncated) + optional **"line N–M"** badge + file size + Refresh + Open-in-default-app + Close. Content adapts to file type: **image** (zoomable), **markdown** (rendered), **text/code** (native mono viewer with line numbers, selectable line-range highlight, find bar, auto-scroll to the linked line), or **binary** ("can't render as text"). Resolves GitHub-style (`#L10-L20`), LSP-style (`:line:col`), and range file references; rejects paths outside the workspace.

### 8.5 Menu-bar usage widget (separate executable)
A standalone menu-bar app showing Claude Code 5h/7d quota, independent of the main window (talks straight to the usage proxy). Out of the main redesign scope but should stay visually consistent.

---

## 9. Engineering direction — AppKit shell + SwiftUI islands

The user reports the current **pure-SwiftUI** build feels unstable — "the conversation isn't stable, the display has weird glitches." Two internal investigations (`docs/instability-investigation-20260515.md`, `docs/swiftui-stability-notes.md`) traced the worst symptoms to a mix of (a) networking bugs and (b) **SwiftUI-specific failure modes in the transcript**:

- **Scroll position lost / transcript blanks & rebuilds:** a slow RPC or reconnect replaces the whole `agents`/`rows` array, which re-inits the conversation view, resets `@State`, and drops the scroll position. A native list with a stable diffable data source would not do this.
- **Main-thread stalls:** SwiftUI re-evaluates a ~3K-node view tree on every change; mutating an `@Observable` from a `body` (a real past bug) spun the layout engine to 99% CPU.
- **Layout hacks:** auto-scroll, composer-height measurement, and streaming-animation timing are all worked around with `preference`/`onChange`/`Task.sleep` glue that is fragile.

**Recommended architecture for the rebuild (this constrains the design, hence it's here):**

- **AppKit shell:** real `NSWindow`, `NSToolbar`, `NSSplitViewController` (source-list sidebar + content), a native **tab** mechanism, and a real **status bar** at the bottom. These give us free, correct, native behavior for the chrome in §3–§4.
- **The transcript should be AppKit** — an `NSScrollView` + `NSTableView`/`NSCollectionView` with a **diffable data source** and **stable row identities**, so streaming appends and reconnects update in place without losing scroll position or rebuilding the tree. This is the single highest-leverage change for the "feels unstable" complaint.
- **SwiftUI as content islands inside cells** (`NSHostingView`): each message bubble, the composer chrome, pickers, sheets, and Preferences can stay SwiftUI — they're self-contained and benefit from SwiftUI's declarative layout. The composer's text input and the code/file viewers are **already** AppKit (`NSTextView`), which validates the hybrid.
- **Net:** AppKit owns *structure, scrolling, and lifecycle*; SwiftUI owns *the look of individual pieces of content*. The design should therefore decompose cleanly into (1) native chrome and (2) independent, embeddable content components — which the redesign IA above already does.

**For the designer this means:** lean into native macOS patterns (source list, toolbar, tabs, status bar, standard controls, materials, light/dark, focus rings). Avoid designs that depend on one giant continuously-reflowing canvas. Components should be drawable as discrete, reusable cells/views.

---

## 10. What's fixed vs. open (designer latitude)

**Must preserve (non-negotiable):** every capability in §5–§8. Nothing in the feature set may silently disappear. Status semantics and color meanings (running/idle/error/attention; risk colors on permission modes; quota thresholds) should stay legible and consistent.

**Strongly desired (from the reference):** workspace switcher, "New conversation" prominence, **Chats** + **projects-by-host** sidebar structure, **conversation tabs**, the **bottom status bar**, the calmer/cleaner visual language.

**Open for you to design / expand ("继续扩容"):**
- Visual language: exact palette, typography scale, spacing system, light & dark, density options, iconography, the accent color, motion.
- The workspace-switcher dropdown contents and multi-workspace future.
- The projects-by-host grouping model and the sidebar **filter/sort** control.
- The assistant-turn header (avatar + timestamp + profile + "Completed work" disclosure) treatment.
- Tab overflow, drag-reorder, close, and restore behavior.
- Onboarding / first-run polish, empty states, error states, notifications, dock badges.
- Anything that makes a long-running agent cockpit calmer and clearer.

**Out of scope:** the relay protocol, the daemon, multi-platform (macOS only by design), and re-implementing agent capabilities.

---

## 11. Quick component checklist (for coverage)

Sidebar: workspace switcher · new-agent + directory popover · chats list (status dot, provider icon, name, cwd, timestamp, rename, archive) · projects-by-host · archived toggle + list + "new here" · import-session entry · version-mismatch banner · CC-update banner · usage panel (Claude 5h/7d + sub-quotas, Codex, Gemini, CC version) · connection footer (status + daemon line + gear) · bottom utility toolbar (settings/help/archive/filter) · empty/loading states.

Conversation: tab strip + new-tab · header (title, usage chip, working indicator, new-agent, branch menu, search, files, GitHub) · transcript (user bubble w/ images + collapse + rewind; assistant markdown; reasoning disclosure; thinking indicator; tool cluster w/ links, badges, expand → plain/before-after/diff; permission Allow/Deny; AskUserQuestion chips + Other + submit/skip; attention; todo; compaction; error) · markdown (headings, lists, tables, code+copy+highlight, quotes, rules, inline code, auto-links, file links) · right-rail user-message navigator + preview cards · load-earlier · per-turn meta chip · turn status pill · jump-to-bottom · archived banner · inline search · pending/empty/error states.

Composer: subagent section · queued strip + send-anyway · resize grip · attachment chips (image + text-file) · text input (paste/drop/history/IME) · "+" picker · inline context+cost bar · feature controls · mode picker · model picker · thinking picker · (pending: provider picker + worktree toggle) · send / queue+interrupt.

Status bar: host name · run status · CLI-exit chip · access-level badge · keep-awake pill.

Secondary: Connect sheet · Import-session sheet · Preferences (General / Integration / Daemon / Usage) · Workspace file-preview window (image/markdown/code/binary) · menu-bar usage widget.

---

*Generated from a full read of the PaseoMac source (Swift, ~13.5k LOC) on 2026-05-31. If anything here conflicts with the code, the code wins — flag it.*
