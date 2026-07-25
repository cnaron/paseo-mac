# 会话页滚动 / 定位 总账（长期维护）

> **改这块之前先读这一份。** 会话页的滚动问题从 2026.07 起被改过七八轮，每轮都
> 只看到症状的一个切面，补一层机制上去；补丁互相叠加后，新人（含下一次的 AI）
> 很容易重复推翻已经成立的结论、或者重新踩已经证伪过的假设。这份是总账：
> **当前机制地图 + 历次改动点 + 排查手册 + 不要再走的路**。
>
> 每次再动这块，**在"改动时间线"追加一节**，并同步更新"机制地图"里被你改掉的
> 那一行。单次改动的完整分析仍然各自成文（见文末索引），这里只做索引和结论。
>
> macOS（paseo-mac）与 iOS（paseo-iOS）**共用** `MessageList` /
> `ConversationViewModel`，两个仓库各存一份同名文件，改动必须两边同步。

---

# 一、当前机制地图（截至 2026.07.25）

## 1. 数据是怎么到位的（这是所有定位问题的前提）

打开一个会话，内容**分四步异步到位**，总耗时从几十 ms 到几秒不等：

| # | 步骤 | 触发点 | 特征 |
|---|---|---|---|
| 1 | 磁盘缓存铺屏（最多 300 行） | `ensureLoaded_claudecode_20260713()` | 同步，立刻有内容 |
| 2 | `fetchTimeline` 取 tail 50 条（`projection: "projected"`） | `loadInitial()` | 网络，几百 ms～几秒；**整体替换 `rows`** |
| 3 | 若 tail 没落在节点边界，继续往前补最多 5 批 × 50 | `loadInitial()` 内联（07.25 起） | 每批一次往返；**攒完再一次性发布**，不逐批前插 |
| 4 | markdown / 代码块真实高度量准 | SwiftUI 布局 | 再过几帧 |

关键点：**第 2~3 步合起来只对 `rows` 赋值一次**（07.25 起；之前是每批各前插一次，
每次都是整表重排 + 磁盘缓存写入 + 一次可见跳动）。但这一次赋值仍会**从顶部塞进
内容**——它不改变最后一行的 id，只改变 `rows.count` 和 `rows.first?.id`，所以
只盯 `rows.last?.id` 的监听看不见它。`isLoading` 覆盖第 2~3 步全程。

手动点"加载更早"走的是另一条路（`loadOlderMessagesInternal` → 逐批前插 +
`suppressAutoScroll` + 锚点恢复），那里逐批前插是刻意的（用户在等反馈）。

`ensureLoaded` 每个 VM 生命周期只真正拉一次（`hasRequestedInitialLoad`），由
`AppViewModel.markConversationAccessed_claudecode_20260713` 在 `selectedAgentId`
的 `didSet` 里驱动。VM 按 LRU 缓存，超量会被 `evictStaleConversations` 回收。

## 2. 两端的页面生命周期（很不一样，坑几乎都在这）

- **macOS**：`ContentView.detailView` 是 `ConversationView(agentId:).id(id)`，
  **每次选中都重建**。`.onAppear` / `.task` 在选中那一刻跑。
- **iOS**：`IOSConversationPagingView` 用 `TabView(.page)` 对 `app.agents` 做
  **全量 `ForEach`**（收窄成"选中项 ±1"试过，会让分页 scrollView 和左滑返回手势
  打架，已回退）。也就是说**所有 agent 的页面都提前建好**，那一刻它们既没有数据
  也不在用户眼前。`selectedAgentId` 是在 `navigationDestination` 的 `.onAppear`
  里才设置的 —— 数据加载比页面创建**更晚**。

  ⇒ **任何"页面被创建时做一次"的逻辑，在 iOS 上都等于没做。** 必须挂在
  "这一页成为选中会话"上（`MessageList.isActive_claudecode_20260725`）。

## 3. 谁会滚动（`MessageList` 内所有 `proxy.scrollTo` 的入口）

| 入口 | 时机 | 约束 |
|---|---|---|
| `defaultScrollAnchor(.bottom, for: .initialOffset)` | 首次布局 | 布局层，不是 scrollTo；第一帧就在底部，没有可闪的错误帧 |
| `defaultScrollAnchor(anchor, for: .sizeChanges)` | 定位窗口内内容尺寸变化 | 布局层；窗口结束立刻置 nil，**长期开着会在回看历史时把人往下拽** |
| `settleInitialPosition_claudecode_20260725` | `.task(id: "agentId\|isActive)`，即"成为选中会话" | 内容收敛式，见 §4；用户一滚就退出 |
| `.onAppear` | 页面出现（仅 `isActive`） | 只是先贴一下底 |
| `.onChange(of: rows.count)` | 行数增长（**顶部插入的唯一可见信号**） | 仅 `isAtBottom && !isUserScrolling` |
| `.onChange(of: turns.count <= eagerLimit)` | eager/lazy 容器切换 | 仅 `isAtBottom`，延迟 30ms |
| `.onChange(of: rows.last?.id)` | 新消息 | user 行只在 `isNearBottom` 或**本机 3s 内发过**才跳；其它行 `isNearBottom` 才贴底 |
| `.onChange(of: rows.last?.text)` | 流式增长 | 120ms 节流，仅 `isNearBottom && !isUserScrolling` |
| `.onChange(of: isAgentWorking)` | turn 开始 / 结束 | 开始滚到 turn 顶；同样要 near-bottom 或本机刚发 |
| `.onChange(of: pendingPermission != nil)` | 出现询问 | **无视是否在回看历史**（这是用户必须操作的东西） |
| "Load earlier" 按钮 | 手动 | `suppressAutoScroll` + 稳定消息 id 锚点 + 60ms 二次 re-pin |
| jump-to-bottom 按钮 / 消息跳转列表 | 手动 | — |
| `onToggleExpanded` | 展开折叠段 | 仅 `isAtBottom` |

## 4. 定位状态机（2026.07.25 重写的核心）

进入会话 → 进入"定位窗口"：**每 40ms 把视口按在目标位置，直到内容真的不再变化**。

- 内容指纹 = `rows.count` + 首行 id + 末行 id + `isLoading`；
  **刻意不含末行正文长度**（流式输出每帧都变，不该阻止收敛）。
- 收敛判据：指纹连续 5 拍不变 + `isLoading` 结束 + `rows` 非空 + 至少撑过 **1.5s
  下限**（`loadInitial` 可能还没被调度起来，此时"看着很安静"是假象）。
- 硬上限 **12s**；`isUserScrolling` 一旦为真**立即退出**（绝不跟用户抢）。
- 收尾再补两次贴合（markdown/代码块高度晚几帧才准）。

## 5. 状态标志速查

| 标志 | 含义 | 谁写 |
|---|---|---|
| `isNearBottom` / `isAtBottom` | 距底 ≤100pt / ≤20pt | `onScrollGeometryChange`（iOS18/macOS15）或老系统的 PreferenceKey 探针 |
| `isUserScrolling_claudecode_20260723` | 手指/触控板在驱动滚动（含惯性） | `onScrollPhaseChange`；`.animating` 是程序化滚动，不算 |
| `trackingGraceActive_claudecode_20260714` | 定位期间冻结上面两个的更新 | 定位状态机自己开关 |
| `suppressAutoScroll` | 手动加载更早 / 定位期间，屏蔽所有自动滚动 | 各入口 |
| `isPositioning_claudecode_20260725` | 定位窗口进行中 | 定位状态机 |
| `hasNewContent` | 底部有没看过的内容（jump 按钮红点） | 各入口 |
| `visibleAnchor_claudecode_20260725` | 视口顶部段落 id，**class 引用盒子** | `onScrollTargetVisibilityChange` |

> ⚠️ `visibleAnchor` 用引用类型而不是 `@State` 是**故意的**：滚动时每跨一行就
> 回调一次，写 `@State` 会让 `MessageList` 整个 body（含 `groupMessages` /
> `groupTurns`）重算 —— 那正是"滚动发沉"的来源。别把它改回 `@State`。

## 6. 阅读位置记忆

`ConversationViewModel.readingAnchor_claudecode_20260725`（`turnId` + 记录时的
`lastRowId` + 时间戳，**仅内存**，随 VM 缓存存活，被 LRU 回收就没了）。

- 写：滚动彻底停下那一刻（每次手势一次）；贴着底部则清空记录。
- 读：进入会话时四条**全**满足才恢复 —— 记录过 / 10 分钟内 / 期间没有新消息
  （`lastRowId` 未变）/ 锚点在当前分段结果里仍是真实存在的滚动目标。
  任何一条不满足 = 回到底部。恢复时同时亮出"跳到底部"按钮。

---

# 二、改动时间线（新的追加在最后）

## 2026.07.11 — 首屏只取 tail + 贴底节流
iOS 打开会话先只取 tail，历史走 load-more；新增
`scrollToBottomThrottled_claudecode_20260711`（120ms 节流），防流式输出每 token
一次 `scrollTo`。**现状：仍在生效。**

## 2026.07.13 — 磁盘缓存 + 只给选中会话拉网络
症状当时也被描述成"点进去半天空白"，归因是 **fetchTimeline 风暴**：iOS 分页
TabView 给每个 agent 建页，创建 VM 时顺带拉历史 ⇒ 打开任一会话等于给全部 agent
发请求，抢同一条 WebSocket。改为 VM 创建零网络开销，只有
`markConversationAccessed` → `ensureLoaded` 才拉；同时加 300 行磁盘缓存（冷启动
先铺屏）和 markdown 预热缓存。**现状：仍在生效；但它没有解决"定位"本身**——
2026.07.25 才发现同一个 TabView 结构还让**定位逻辑**跑在了没有数据的时刻。

## 2026.07.14 — 贴底跟踪 + jump 按钮 + 动态 bottomPadding
`isNearBottom` / `isAtBottom` 跟踪、jump-to-bottom 按钮（350ms 延迟出现）、
`trackingGraceActive` 冻结窗口、composer 高度实测驱动底部留白。**现状：仍在生效。**

## 2026.07.22 / 07.23 — 别跟用户抢 + 探针只装老系统
`ScrollState` 结构化；`onScrollPhaseChange` 引入 `isUserScrolling`，用户手势期间
禁止一切程序化 `scrollTo`（"上滑总被回坐"的手感来源）；`GeometryReader +
PreferenceKey` 探针改成只在 <iOS18/<macOS15 安装（新系统用
`onScrollGeometryChange`，省掉每帧 preference 传播的开销）。**现状：仍在生效。**

## 2026.07.24 — 回看历史跳帧 / 加载更早 / 询问被淹没
详见 `conversation-scroll-improvements_20260724.md`。要点：历史行去掉插入过渡
（`.transition` 只留最后一个 turn，否则后台活动触发的 `withAnimation` 会让懒加载
重建的历史行淡入 = 滚动时先空白再淡出来）；eager `VStack` 阈值（mac 12 / iOS 5）；
"加载更早"改用 `projected` 并按**节点边界**加载；初次加载自动补齐最后一个节点；
加载更早的锚点改用**稳定消息 id**（`userMessage.id` 优先，turn.id 会因重新分段而
消失）；有询问时不让 `agent_status: running` 复活 working 状态、隐藏底部运行指示
器、询问出现时主动滚过去。**现状：全部仍在生效。**

## 2026.07.25 — 「点进去一片空白」的根因重写（本轮）
详见 `conversation-open-position_20260725.md`。三个叠加的根因：

1. **定位是按固定节拍猜的**（0/120/240ms），而内容分四步异步到位；任何一步慢过
   240ms 定位就永久落空，而第 3 步的顶部插入会把视口推进 `LazyVStack` 尚未构建
   的区间 = 空白。附带：`.task` 闭包捕获的 `turns` 是 body 求值那一刻的值（进来
   时是空的），第一句 `scrollTo(turns.last?.id)` **从来没生效过**。
2. **iOS 定位跑在"页面被创建时"而非"会话被打开时"**（见 §一.2），且 `.onAppear`
   还会把 `trackingGraceActive` 永久置位，让未选中页面的贴底判断一直失真。
3. **eager `VStack` ↔ `LazyVStack` 切换换掉整个内容容器**，加载中正好跨阈值。

改动：定位改成内容收敛式状态机（§一.4）；触发条件改成
`isActive_claudecode_20260725`；补两条兜底（`rows.count` 增长、容器切换）；
新增阅读位置记忆（§一.6）。发布：PaseoMac **v0.2.165 (build 166)**、
Paseo iOS **build 36**。

## 2026.07.25（同日追加）— 消掉"进会话闪一下"
定位对了之后暴露出的第二层问题：`proxy.scrollTo` 是**布局之后**的纠正，前提是先画
了一帧错的；加载中内容分几次到位就画错几帧、纠正几次 = 抖好几下。改成**不画错帧**：
`.defaultScrollAnchor(.bottom, for: .initialOffset)` 让第一帧就在底部；
`.defaultScrollAnchor(anchor, for: .sizeChanges)` 只在**定位窗口内**给 `.bottom`
（结束立刻置 nil，长期开着会在回看历史时把人往下拽）；`loadInitial` 的节点补齐改成
发布前攒完、**整个初次窗口只对 `rows` 赋值一次**。发布：PaseoMac **v0.2.166
(build 167)**、Paseo iOS **build 37**。

---

# 三、下次排查手册

遇到"进会话位置不对 / 空白 / 被拽走"，按这个顺序看：

1. **先分清是哪一类**：
   - 进去就不对 → 定位状态机（§一.4）/ 触发时机（§一.2）
   - 进去是对的、过一会被拽走 → §一.3 表里那些 `onChange` 入口
   - 滚动中跳帧 / 先空白再淡入 → 过渡动画 + `LazyVStack` 重建（见 07.24 那节）
   - 加载更早后位置乱跳 → 锚点失效（turn 重新分段，见 07.24 那节）
2. **确认数据到位的时序**：慢网络下第 2、3 步要几秒；先确认是不是**超过 12s 硬
   上限**的极端情况（那时定位窗口会提前收工，只剩 `rows.count` 兜底）。
3. **iOS 特有**：任何"只做一次"的逻辑，先问一句**它是不是跑在页面创建时**。
   `IOSConversationPagingView` 会给每个 agent 都建页。
4. **别只信症状描述**：同一个"空白"在 07.13 和 07.25 是两个完全不同的根因
   （网络风暴 vs 定位落空）。改之前先确认这次是哪一个。

---

# 四、已被证伪 / 不要再走的路

- ❌ **用固定延时的 `scrollTo` 序列做首屏定位**。内容到位是异步且时长不可预测的，
  任何固定节拍都是赌博 —— 这正是 07.25 之前反复失败的原因。要按内容状态收敛。
- ❌ **把 iOS 分页的 `ForEach` 收窄成"选中项 ±1"** 来省资源。试过（07.13）：分页
  scrollView 的层级和左滑返回手势会跟着抖，切换卡顿、手势打架，已回退。省资源要
  在**数据层**做（`ensureLoaded`），不要动视图集合。
- ❌ **把可见锚点写进 `@State`**（或任何会让 `MessageList` body 重算的地方）。
  滚动时每跨一行回调一次，body 里有 `groupMessages` / `groupTurns`，直接变成滚动
  卡顿。用引用盒子。
- ❌ **给历史行加插入过渡**（`.transition(.opacity)`）。后台活动触发的
  `withAnimation` 会让懒加载重建的历史行淡入，表现为滚动跳帧 + 位置漂移。
- ❌ **用 `turn.id` 做跨加载的滚动锚点**。turn.id = 段落首行 id，补齐上文后该 turn
  会被合并、id 从列表消失，`scrollTo` 静默失效。用稳定消息 id。
- ❌ **在用户手势期间做程序化 `scrollTo`**。必看 `isUserScrolling`。
- ❌ **靠 `scrollTo` 去"纠正"首屏位置**。它发生在布局之后，等于承认先画错一帧
  ——那一帧就是用户看到的"闪一下"。首屏位置要用 `defaultScrollAnchor` 在布局层
  解决，`scrollTo` 只做兜底。
- ❌ **长期开着 `defaultScrollAnchor(.bottom, for: .sizeChanges)`**。只能在定位
  窗口内开；常开 = 回看历史时被新内容往下拽。

---

# 五、已知残余 / 还没解决

- 极慢网络下加载超过 **12s 硬上限**，定位窗口提前收工，此时只剩"贴底时行数增长
  再贴底"这条兜底；理论上仍可能有一瞬不在底部。
- 阅读位置记忆**只在内存**：VM 被 LRU 回收、或 app 重启后丢失，退化为回到底部。
  （要持久化的话，落到已有的 `PaseoMac/meta/<agentId>.json` 那套 metaCache 里最省事。）
- eager/lazy 阈值（mac 12 / iOS 5）是**手感参数**，不是理论值；真要再调，先确认
  改的是"滚动顺滑度"而不是"定位正确性"——后者现在不再依赖它。
- macOS 与 iOS 两份 `ConversationView.swift` 靠**手工同步**，已经有平台差异
  （mac 的 `turnStartedAt` 计时条 vs iOS 的 "Thinking..." 指示器）。改共用逻辑时
  两边都要改；改完 `diff` 一遍确认只剩已知的平台差异。

---

# 六、单次改动文档索引

- `conversation-scroll-improvements_20260724.md` — 回看历史跳帧、加载更早按节点、
  询问被淹没、Cmd+V 被 composer 抢（仅 macOS）
- `conversation-open-position_20260725.md` — 进会话一片空白的根因与定位重写（含同日
  追加的"消闪"一节：布局层锚点 + 初次加载只赋值一次）
- `swiftui-stability-notes.md` — 更早期的 SwiftUI 稳定性笔记（含 AppKit transcript
  那一轮的教训）
