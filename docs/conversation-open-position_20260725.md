# 从列表点进会话"一片空白"的根因与重写（2026-07-25）

> 总账见 `conversation-scroll-ledger.md`（当前机制地图 / 历次改动点 / 排查手册 /
> 已证伪的路）。改这块之前先读那一份，这里只是本次改动的细节。

**现象**（反复出现，mac + iOS 都有）：从会话列表点进一个会话，页面经常是空白
的，既没有落在底部的最新回复上，也不是上次停留的阅读进度；要手动滚一下才看得
到内容。之前几轮改动（07.11 / 07.14 / 07.22 / 07.23 / 07.24）都只是在既有机制上
加补丁，没有解决这个机制本身。

改动文件（两端同名，`paseo-mac` 与 `paseo-iOS` 各一份）：
- `Sources/PaseoMac/Views/ConversationView.swift`（`MessageList`）
- `Sources/PaseoMac/Views/IOSConversationView.swift`
- `Sources/PaseoMac/ViewModels/ConversationViewModel.swift`

留痕后缀 `_claudecode_20260725` / `2026.07.25 Naron`。

---

# 根因

进入会话后的定位，老实现是**按固定节拍猜**的：

```swift
.task(id: vm.agentId) {
    proxy.scrollTo(turns.last?.id, anchor: .bottom)   // t=0
    proxy.scrollTo("bottom", anchor: .bottom)
    try? await Task.sleep(120ms); proxy.scrollTo("bottom", ...)   // t=120ms
    try? await Task.sleep(120ms); proxy.scrollTo("bottom", ...)   // t=240ms
}
```

而会话内容是**分好几步异步到位**的：

1. 磁盘缓存先铺一屏（同步）；
2. `fetchTimeline` 拿回最近 50 条（网络，走 VPS，几百 ms 到几秒）；
3. 这批若没落在节点边界，`loadOlderUntilNodeBoundary` 还会**继续往前补最多 5 批**
   （每批一次往返，并且是**从顶部插入**）；
4. markdown / 代码块的真实高度还要再过几帧才量准。

只要任何一步慢过那 240ms，定位就**永久落空**——之后没有任何代码再把视口拉回来。
更糟的是第 3 步：从顶部插进来几百行，ScrollView 的偏移量原地不动，视口相对内容
整个往下掉；长会话走 `LazyVStack` 时，视口落在**还没被构建出来的行**所在的区间，
屏幕上就是**一片空白**。这就是"容易空白"的直接来源。

同一套代码里还有三个各自独立的结构性问题：

**① 闭包捕获的是旧数据。** `.task` 里的 `turns` 是 body 求值那一刻的值——进会话
那一刻通常是空的。所以第一句 `scrollTo(turns.last?.id)` 从来没有生效过。

**② iOS 上定位跑在"页面被创建时"，而不是"会话被打开时"。** iOS 的会话是
`TabView(.page)` 分页承载的，`IOSConversationPagingView` 对 `app.agents` 做全量
`ForEach`——**所有** agent 的页面都会提前建出来。`.task(id: vm.agentId)` 于是在
那一页还没被选中、一行数据都没有（`ensureLoaded` 只对选中的会话触发）的时候就
跑完了三次 `scrollTo` 并结束；等用户真正划到 / 点进这一页时，`agentId` 没变，
`.task` 不会再跑。iOS 侧几乎必然空白，就是这个原因。

**③ eager `VStack` ↔ `LazyVStack` 的切换会换掉整个内容容器。** 阈值（mac 12 /
iOS 5 个 turn）是按 `turns.count` 算的，加载过程中 turn 数从 0 涨到几十，正好在
定位窗口内跨过阈值：两个分支是不同的视图身份，SwiftUI 会重建整棵内容树，那一帧
滚动位置没有着落。

---

# 改法：定位是内容状态的函数，不是时间的函数

## 1. 收敛式定位（`settleInitialPosition_claudecode_20260725`）

进入会话后进入一个"定位窗口"：每 40ms 把视口按在目标位置上，直到内容**真的不再
变化**为止。判据是内容指纹（`rows.count` + 首尾行 id + `isLoading`）连续 5 拍不
变、且 `isLoading` 已结束、且至少撑过 1.5s 下限（防止 `loadInitial` 还没被调度
起来时"看着很安静"就收工）；硬上限 12s 兜底。

- 指纹**不含**最后一行的正文长度：进来时正在流式输出的会话正文每帧都在变，那不
  该阻止定位收敛（贴底跟随交给常规流式滚动逻辑）。
- **用户一旦自己开始滚动（`isUserScrolling`）立即退出**，绝不跟用户抢。
- 收尾再补两次贴合，等 markdown / 代码块的最终高度量准。

这一条同时把上面的 ①（不再依赖捕获的 `turns`，只用恒定存在的 `"bottom"` 锚点）
和"补齐节点时被顶飞"一起解决了。

## 2. 定位的触发条件改成"这一页成为用户正在看的会话"

`MessageList` 新增 `isActive_claudecode_20260725`，`.task(id: "\(agentId)|\(isActive)")`。

- macOS：`ContentView` 用 `.id(agentId)` 每次选中都重建 `ConversationView`，恒为
  true，行为不变。
- iOS：`IOSConversationView` 传 `app.selectedAgentId == agentId`。未选中的分页页
  面不做定位；被划到 / 点进来时 `isActive` 翻转，`.task` 重跑一次完整定位。

`.onAppear` 里那句"顺手贴一下底"同样加了 `isActive` 判断——它原来还会把
`trackingGraceActive` 永久置位（未选中的页面没有任何人再把它关掉），让贴底判断
一直失真。

## 3. 兜底两条（定位窗口之外）

- `.onChange(of: vm.rows.count)`：**顶部插入不会改变最后一行的 id**，原有的
  last-id 监听完全看不到它。停在底部时，任何行数增长都重新贴底。
- `.onChange(of: turns.count <= eagerTurnLimit)`：容器切换后重新贴底。

## 4. 记住上次停留的阅读进度

`ConversationViewModel.readingAnchor_claudecode_20260725`（`turnId` + 记录时的
`lastRowId` + 时间戳，仅内存，随 VM 缓存存活）。

- **写**：滚动（含惯性）彻底停下的那一刻记一次——每次手势一次，不是每帧一次。
  贴着底部就清空记录（下次进来直接到底部）。
- **读**：进入会话时，只有「记录过 + 10 分钟内 + 期间没有新消息（`lastRowId` 未
  变）+ 那个锚点在当前分段结果里仍是真实存在的滚动目标」四条全满足，才恢复到该
  位置，并同时亮出"跳到底部"按钮；任何一条不满足都回到底部。
- 视口顶部可见段落的 id 用 `onScrollTargetVisibilityChange`（iOS 18 / macOS 15）
  采集，写进一个 **class 引用盒子**而不是 `@State`——滚动时每跨一行就回调一次，
  写 `@State` 会让 `MessageList` 整个 body（含 `groupMessages` / `groupTurns`）
  重算，正是滚动发沉的来源。老系统没有这个 API 时直接透传，"记住位置"降级为
  "回到底部"，主路径不受影响。

---

---

# 追加（同日）：定位对了，但"闪一下 / 抖一下"

**现象**：上面那版装上以后，从列表点进会话**总会闪一下**才稳定下来。

**根因**：定位正确不等于不闪。`proxy.scrollTo` 是**布局之后**的纠正动作——它成立
的前提是"先画了一帧错误的位置"。老实现因为定位落空，那帧错误画面就一直留着（表现
为空白/位置不对）；新实现把它纠正了，于是错误帧 → 正确帧的切换变成可见的一跳。
加载过程中内容分好几次到位（磁盘缓存 → 网络 tail → 节点补齐每批各一次前插），
**每一次都画错一帧再纠正一次**，连起来就是"抖好几下"。

**改法：不要画错帧，而不是画错了再纠正。**

1. **初始偏移交给布局系统**：`.defaultScrollAnchor(.bottom, for: .initialOffset)`
   （iOS 18 / macOS 15）。第一帧画出来就已经在底部，没有可纠正的错误帧。
2. **定位窗口内，内容尺寸变化也交给布局系统**：
   `.defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)`，`sizeChangeAnchor`
   只在定位窗口内为 `.bottom`，结束立刻置回 `nil`。这样加载中每次内容到位都由布局
   系统直接钉住底边，不再产生"画错一帧 + scrollTo 纠正"的跳动。
   - 长期开着**不行**：那会在用户回看历史时把人往下拽（07.23 专门修掉的手感问题）。
   - 恢复到历史阅读位置时也不开（会跟恢复目标打架）。
   - `UnitPoint?` 是同一个 modifier 的**取值**变化，不改变视图身份，不触发重建。
3. **初次加载只对 `rows` 赋值一次**：节点补齐（最多 5 批）改成在**发布给视图之前**
   攒完（`fetchOlderBatch_claudecode_20260725` 纯取数、不碰 `rows`），整个初次窗口
   从"最多 6 次整表重排 + 6 次磁盘缓存写入"降到 1 次。

老系统（<iOS 18 / <macOS 15）没有 `defaultScrollAnchor(_:for:)`，保持原行为（仍靠
收敛式 `scrollTo`），只是会看到原来那样的一跳。

# 构建 / 安装

- **macOS**：`swift build -c release` + `scripts/bundle.sh release paseomac`，覆盖
  安装到 `/Applications/PaseoMac.app`，**v0.2.165 (build 166)** → 消闪版
  **v0.2.166 (build 167)**。
- **iOS**：`scripts/release-to-iphone.sh`，Release 签名构建 + `devicectl` 装到
  iPhone 15 Pro，**build 36** → 消闪版 **build 37**。

# 观察项

- 点进任意会话（尤其是工具步骤很多的长会话、以及冷启动后第一次点开）都应直接落在
  最新回复上，不再需要手动滚一下。
- iOS 左右划动切换会话时，每换到一页都会重新定位一次到底部。
- 回看历史滚到一半离开、10 分钟内回来，应停在原处并出现"跳到底部"按钮；超时、或
  期间来了新消息，则回到底部。
- 若仍偶发空白，先看是不是**超过 12s 硬上限**的极慢加载（网络很差时），那种情况
  定位窗口会提前收工；此时 `rows.count` 兜底那条仍会在贴底状态下把视口拉回。
