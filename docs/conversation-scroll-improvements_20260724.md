# 会话页滚动与询问交互改进（2026-07-24）

> 总账见 `conversation-scroll-ledger.md`（当前机制地图 / 历次改动点 / 排查手册 /
> 已证伪的路）。改这块之前先读那一份，这里只是本次改动的细节。

本次围绕"会话页回看历史 / 加载更早 / 询问交互 / 粘贴"做的一组修复。macOS
（paseo-mac）与 iOS（paseo-iOS）共用 `MessageList` / `ConversationViewModel`，
下面每条注明适用平台。改动均带 `_claudecode_20260724` 或 `2026.07.24 Naron`
留痕。

改动文件（两端同名）：
- `Sources/PaseoMac/Views/ConversationView.swift`
- `Sources/PaseoMac/ViewModels/ConversationViewModel.swift`
- `Sources/PaseoMac/Views/ComposerTextView.swift`（粘贴修复，仅 macOS 编译）

---

## 1. 回看历史滚动跳帧出现空白 + 页面进度漂移（mac + iOS）

**现象**：在会话里上下滚动回看历史，行会先空白再淡出来（跳帧），滚动位置也会漂。

**根因**：`LazyVStack` 里每个 turn 行及内部气泡都挂了 `.transition(.opacity)`。
长会话后台仍在活动（流式输出、心跳、channel 消息都会触发 `withAnimation`
事务），此时被 `LazyVStack` 懒加载**重新实例化**的历史行，会在这个动画事务里
执行"插入过渡"（opacity 0→1 淡入）——表现为"滚动时行先空白再淡入"；过渡还会
在滚动中改变行高，导致滚动位置漂移。上一个相关提交只挡住了程序化 `scrollTo`
的拽回，没解决过渡淡入这层闪烁。

**修复**：历史行去掉插入过渡。外层 `ForEach(turns)` 只给**最后一个**（新到达 /
正在流式）的 turn 保留 `.opacity` 淡入，其余一律 `.identity`；用户气泡、助手
气泡、中间步骤气泡、中间步骤容器上各自的 `.transition(.opacity)` 全部移除。

## 2. 滚动不够顺滑（mac + iOS，平台阈值不同）

**根因**：只有 `turns.count <= 3` 时才用 eager `VStack`，其余用 `LazyVStack`。
懒加载的行在滚动到屏幕时才现建视图（构建 + 布局），正好卡在手指划动那一帧；
且 `LazyVStack` 用估算行高，上滑时还会跳位。

**修复**：提高 eager 阈值，让常见长度会话整体 eager 渲染（滚动顺滑 + 精确滚动
几何，超长会话仍回退 `LazyVStack`）。阈值**按平台区分**：
- **macOS：12**（桌面性能足）。
- **iOS：5**。手机上一次性 eager 渲染十来个完整 turn（markdown/代码块/图片）
  会让视图树过重，每帧 SwiftUI 更新都要 diff 大树，竖向滚动手感发沉（阻尼偏
  大）。iOS 更早回退 `LazyVStack` 以保持滚动轻快。

## 3. "加载更早"应显示上一个节点，而非折叠的历史步骤（mac + iOS）

**根因**：初次加载用 `projection: "projected"`（节点级），"加载更早"却用
`canonical`（原始事件日志，每个折叠工具步骤各占一行），且每次只拉 40 条原始行。
一个 turn 可能有几百个工具步骤，点出来全是折叠碎步，而非用户心里的"上一个节点"。

**修复**：
- `loadOlderMessagesInternal` 改用 `projected`，与初次加载一致（游标语义也对齐）。
  已在 daemon 侧确认 `projected + direction:before` 完整支持、`hasOlder`/游标正确。
- "加载更早"改为**按节点加载**（`loadOlderUntilNodeBoundary_claudecode_20260724`）：
  持续拉取直到顶部落在一个干净的节点边界（`user` 行），最多 8 批（~320 行）兜底。

## 4. 单个来回的对话，首次打开要点好几次"加载更早"才显示（mac + iOS）

**根因**：初次 tail 只取最近 50 个事件；若最后一个节点的步骤数 > 50，用户的
提问那一行落在窗口上方，看起来"对话不见了"，得反复点"加载更早"。

**修复**：`loadInitial` 取完 tail 后，若顶部不是节点边界且仍有更早消息，自动
补齐到最后一个节点完整可见（最多 5 批兜底）。普通短会话（tail 已覆盖 / 无更早
消息）完全 no-op，不增加打开延迟。

## 5. 加载更早时视口位置跳动（mac + iOS）

**需求**：加载更早消息时，用户停在什么进度就保持在什么进度，视口不动。

**根因**：原来用 `turns.first?.id` 作恢复锚点。但 turn.id = 段落首行 id，而初次
tail 加载后顶部往往是个**残缺 turn**（开头不是 user 消息）。点"加载更早"后，
按节点加载会把补齐它的 user 消息拉到上面——这一刻残缺 turn 被合并、它的 id
不再是任何段落开头，锚点从列表消失，`scrollTo` 静默失效，而上方已塞入大量新
内容 → 视口按原偏移量停着，看起来整体往下猛跳。

**修复**：锚点改用**稳定的消息 id**——优先 `userMessage.id`，其次
`assistantMessage.id`，最后才回退 turn.id。这些是真正的消息 id，即使 turn 重新
分组合并仍照常渲染、仍是已注册的滚动目标，恢复到它们能把原内容精确留在原位。
另加一次布局稳定后（60ms）的二次 re-pin，防止预置的 markdown/代码行延迟测量
把偏移量顶偏。

## 6. 询问过一会儿被覆盖成 running、询问内容被淹没（mac + iOS）

**现象**：有 permission / AskUserQuestion 询问时，若过一段时间没回复，状态被覆盖
成 "running"，询问内容也被压下去。

**根因**：有询问时 `isAgentWorking` 仍为 true；卡顿看门狗几分钟后把它置 false，
随后 daemon 周期性发来 `agent_status: "running"`（进程还活着，只是在等用户），
`reconcileAgentStatus` 又把它翻回 true → 触发滚动到 turn 顶部 + 重新显示运行
指示器，正好把询问压下去。

**修复**：
- VM：有 `pendingPermission` 时 `reconcileAgentStatus("running")` 直接 return，
  不再复活 working 状态。
- View：有询问待处理时隐藏底部运行指示器（mac 的 `BottomWorkingStatusBar` 计时
  条 / iOS 的 `"Thinking..."`）——它就在询问下方、自动滚动的落点，正是淹没询问
  的元凶。
- View：询问首次出现时主动滚动到询问卡片（等强制展开布局完成后），一次性；即使
  在回看历史也会带过去，因为这正是需要用户操作的东西。

## 7. 回复框里 Cmd+V 无效、粘贴跑到对话栏（仅 macOS）

**根因**：composer 的 `NSTextView` 重写了 `performKeyEquivalent` 无条件抢 Cmd+V
粘进自己。而 `performKeyEquivalent` 会发给窗口里**所有**视图，不只当前聚焦的那个
——所以在询问回复框里按 Cmd+V 被 composer 截走。右键能用是因为走的是聚焦框自己
的原生菜单。

**修复**：只有当 composer 真是第一响应者（当前聚焦）时才接管 Cmd+V，否则放行给
真正聚焦的输入框。此修复在 `#if os(macOS)` 块内，iOS 编译时排除（iOS/iPad 的
UITextView 是另一套粘贴路径，不存在此机制）。

---

## 构建 / 安装

- **macOS（paseo-mac）**：`swift build -c release` + `scripts/bundle.sh release
  paseomac`，覆盖安装到 `/Applications/PaseoMac.app`（v0.2.164）。
- **iOS（paseo-iOS）**：`scripts/release-to-iphone.sh`，`xcodebuild` Release +
  `devicectl` 装到 iPhone 15 Pro（build 35）。

## 备注

- 本文档为改进记录；对应代码改动本次随工作树一同保留（已跑在上述构建里）。
- 涉及的滚动手感、eager 阈值等是主观参数，后续可再按手感微调（如 iOS 阈值上下
  调一档，或用 UIScrollView introspection 显式锁定 `decelerationRate`）。
