# 过程式渐进折叠与收纳设计文档 (Process Progressive Folding & Summarization)

本文档阐述了 Paseo 客户端中关于 Agent 执行步骤（中间过程、思考与工具调用）在执行期和闲置期的渐进式折叠与收纳功能的设计方案、实现细节、当前体验痛点及改进方向。

---

## 1. 设计背景与动机 (Background & Motivation)

在与 Agent（如 Antigravity, Claude Code 等）交互时，Agent 通常会经历“思考 -> 调用工具（Bash/Read/Edit 等） -> 继续思考 -> 输出最终回复”的漫长过程。

- **原始痛点**：
  - 如果把所有的中间日志（如终端输出、文件 Diff、大段思考）一股脑全展示在主会话中，页面会极度冗长，冲淡了“最终回复”这一核心内容。
  - 如果采用“武断一刀切”的全部折叠，用户在运行期间完全看不到任何进展，且折叠后也无法回顾工具执行过程。
- **目标设计（借鉴 Claude Code 网页端）**：
  - **由繁入简**：运行期间透明、实时呈现发生了哪些小步骤，但控制细节的曝光度；
  - **由散归整**：回复输出或运行结束时，将所有零散步骤收纳为单一概括大标题；
  - **保留回顾**：收纳后支持二次展开，按需查看每一步的日志细节。

---

## 2. 核心功能与交互流程 (Core Features & UX Flow)

整个折叠收纳系统分为三个主要阶段：

### 阶段 A：执行运行期 (Active Execution Phase)
- **大容器展开**：中间过程外层盒子保持打开，实时呈现步骤列表。
- **小步骤透出**：各个步骤（如 `Thinking`、`Bash`、`Read`）以单行摘要形态按顺序逐个冒出。
- **日志细节折叠**：默认**不展开**步骤深层的控制台框、终端输出或 Diff 编辑器，仅透出单行命令（例如 `Bash du -sh ...`）。用户可手动点击展开，但默认保持收拢。
- **最新步骤焦点**：只有当前正在执行的那一步（如正在 Streaming 的 `Thinking`）可以在外层体现活跃状态（如显示动态字数或微动图标）。

### 阶段 B：回复过渡期 (Transition Phase)
- 当 Agent 结束工具调用、开始流式输出最终回复（即 `assistantMessage` 开始）时，中间过程大盒子应当**立刻执行收拢收纳**。
- 步骤列表由展开态变为收缩态，大盒子标题由 `"Executing steps..."` 变更为绿色对勾的总结词（例如 `"Worked for 3 steps"` 或 `"Worked for 12s"`）。

### 阶段 C：闲置归档期 (Idle Archive Phase)
- 整个会话 Turn 结束，主界面仅保留干净的：
  1. 用户提问
  2. 总结大标题（`Worked for X steps`）
  3. 最终回复（Assistant Reply）
- 用户可以点击“总结大标题”，展开所有历史步骤列表。
- 展开后的历史列表中，每一步依然默认是折叠的，用户可按需“二级展开”查看某次 Bash 的具体 Terminal 文本。

---

## 3. 当前实现机制 (Current Implementation Details)

我们在 [ConversationView.swift](file:///Users/cc/Public/Project/paseo-mac/Sources/PaseoMac/Views/ConversationView.swift) 中通过以下机制实现了上述设计。**2026.07.16 更新**：第 4 节列出的三个痛点均已修复，具体机制见每条下方的补充说明。

1. **过程活跃度判定 (`isProcessActive`)**：
   ```swift
   private var isProcessActive: Bool {
       isAgentWorking && isLastTurn && turn.assistantMessage == nil
   }
   ```
2. **大盒子折叠控制 (`isExpandedEffective`)**：
   默认状态下，只要 `isProcessActive` 为 `true`，盒子自动展开；一旦进入回复或闲置（`isProcessActive` 变为 `false`），在用户未手动干预时盒子自动合拢。
   - **2026.07.16 补充（软着陆延迟）**：新增 `deferCollapse_claudecode_20260716` 状态，`isExpandedEffective` 的默认分支改为 `isProcessActive || deferCollapse_claudecode_20260716`。回复刚开始流式输出（`isProcessActive` 由 `true` 转 `false`）的那一刻，不会立刻让步骤列表收起——`deferCollapse` 先置 `true`，撑住展开态约 900ms 的宽限窗口（给用户一点时间看清"步骤结束了、马上要出回复了"），期间如果用户没有手动点击折叠区域（`hasManuallyToggled` 仍为 `false`），窗口结束后才用更柔和的 `withAnimation(.easeInOut(duration: 0.35))`（原来是 0.2s）把 `deferCollapse` / `turnExpanded` 一起收起。用户在宽限窗口内的任何手动点击都会直接赢——定时器触发时发现 `hasManuallyToggled` 已经是 `true`，就只清掉 `deferCollapse` 标记本身，不去覆盖用户刚做的选择。
3. **完成时平滑收起**：
   通过监听 `.onChange(of: isProcessActive)` 触发上述延迟 + `withAnimation` 收拢动画。
4. **单步元素不自动展开**：
   移除了 `ToolRowTimeline` 和 `MessageBubble` 在活跃/运行时的 `.onAppear` 强制展开（`expanded = true`）行为，仅保留其在生命周期结束时的收缩重置。
5. **轻量时间轴取代大盒子（2026.07.16 新增）**：
   `isExpandedEffective` 为 `true` 时渲染的步骤列表，不再整体包一层圆角边框 + 半透明底色的"大盒子"（原来的 `.background(Color.secondary.opacity(0.04)).cornerRadius(8).overlay(RoundedRectangle...)`，iOS 上是 `secondarySystemBackground` 卡片）。现在每一步单独用 `FlowStep(showLine:icon:content:)` 包一次，`icon` 换成一个 5×5pt 的小圆点（`Circle().fill(Color.secondary.opacity(0.4))`）而不是大号 SF Symbol，`FlowStep` 自带的细连线（`Color.secondary.opacity(0.18)`，1pt 宽）在相邻步骤之间画出竖线，视觉上跟同一 `FlowStep` 体系画出的主气泡时间轴（头部那个 `cpu`/`checkmark.circle` 图标行）是同一套语言，读起来像"内联条目 + 时间轴"而不是一张独立卡片。折叠态的"Worked for N steps"摘要行本身保留原有的淡红底 chip（`Markdown.inlineCodeBackground`），这个 chip 很小，不受本次改动影响。
6. **智能视口软粘滞取代硬顶对齐（2026.07.16 新增）**：
   `MessageList` 里新 Turn 开始时仍然沿用"把 Turn 头部顶对齐（`anchor: .top`）"的旧逻辑（`.onChange(of: vm.isAgentWorking)`，未改动，效果符合预期予以保留）。新增的是 `.onChange(of: vm.rows.last?.text ?? "")`：只要用户当前处于底部附近（`isNearBottom`，沿用既有 120pt 阈值的探测器）且 Agent 正在工作，每次最后一行文本增长都会追加一次 `withTransaction(Transaction(animation: nil)) { proxy.scrollTo("bottom", anchor: .bottom) }`——不带动画，纯粹让 offset 跟随新增内容平移，读起来像文字自然浮现，不是被强行拉扯的跳动感。一旦用户手动划走导致 `isNearBottom` 变 `false`，这个 nudge 立刻停止生效，滚动位置完全交还给用户（走 `hasNewContent = true` 分支，只提示有新内容，不再纠正位置）。

---

## 4. 历史痛点评估 (Resolved UX Issues)

以下三点是本文档 2026.07.15 之前版本记录的痛点，**均已在 2026.07.16 修复**，机制见第 3 节对应条目；保留记录供回溯。

1. **折叠过渡过于突兀 (Jarring Collapse Transition)** —— 已修复，见第 3 节第 2 条（软着陆延迟 + 更柔和的 0.35s 过渡）。
   > 原描述：在 Agent 刚开始吐出最终回复的瞬间，上方的步骤列表突然整块向上缩回。由于文字仍在流式写入，视图位置发生剧烈缩变，缺乏一个更温和的淡出或视觉平移缓冲，让人感觉"内容被瞬间吸走"。
2. **多层折叠的认知开销 (Cognitive Overhead of Nested Accordions)** —— 已缓解，见第 3 节第 5 条（大盒子换成轻量时间轴，减少一层物理边界）。
   > 原描述："大盒子折叠 -> 展开列表 -> 单步折叠 -> 展开终端"的多级折叠机制，虽然理论上逻辑严密，但在实际操作中显得繁琐。用户需要点击多次才能定位到一个报错的 Bash 日志。
   >
   > **注意**：这一条只解决了"大盒子"这一层视觉边界的问题，单步内部仍保留"点击展开终端/Diff 详情"这一层折叠（`ToolRowTimeline` 的展开机制未改动）——多级折叠本身的点击次数并未减少，只是外层不再是一张突兀的卡片。如果后续还嫌繁琐，可以考虑更激进的方案（例如报错的步骤默认自动展开详情）。
3. **顶对齐与页面跳转的冲突 (Top-Alignment vs Viewport Sync)** —— 已修复，见第 3 节第 6 条（软粘滞 nudge）。
   > 原描述：为了防止回复长高引起乱跳，发送后强行置顶了当前 Turn 的头部。但如果回复过长溢出屏幕，因为没有像传统聊天窗口那样进行"智能底部贴附"，用户可能会看着一成不变的头部，误以为回复已经停止（除非他们手动向下滑动）。
   >
   > **实现细节备注**：没有单独引入文档原先建议的"150px 释放阈值"，而是复用了已有的 `isNearBottom`（120pt 阈值，`NearBottomTrackingModifier_claudecode_20260714`）——一是这个探测器本身已经很可靠（iOS 18+ 走 `onScrollGeometryChange`，实测在交互式滑动中比 PreferenceKey 更新更及时），二是避免引入第二套"是否在底部"的独立判据，两套阈值互相打架导致状态反复横跳的风险比"数字差 30px"更值得规避。

---

## 5. 后续可选优化 (Further Optional Enhancements)

三个原有痛点已修复，以下是修复过程中发现的、值得未来考虑但本次未处理的延伸项：

1. **单步详情的展开仍是多级点击**：见第 4 节第 2 条注释，`ToolRowTimeline` 内部的终端/Diff 展开机制本次未动。如果用户反馈"还是要点两次才能看到报错日志"，可以考虑给状态为失败/异常的步骤默认展开详情。
2. **软着陆延迟的 900ms 是拍脑袋的经验值**：没有做过用户可用性测试，如果实际感觉偏久或偏短，直接改 `deferCollapse_claudecode_20260716` 那个 `Task.sleep` 的纳秒数即可，crossfade 时长在同一处的 `withAnimation(.easeInOut(duration: 0.35))`。
3. **iOS 端口未做**：本次改动只落地在 `paseo-mac`（`Sources/PaseoMac/Views/ConversationView.swift`），`paseo-iOS` 的对应文件尚未同步，逻辑结构预期高度相似但两边文件历史上已有一些差异，需要单独走查后再迁移，避免囫囵搬运引入新 bug。
