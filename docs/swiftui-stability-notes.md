# SwiftUI / @Observable 稳定性 notes

跨会话续接用。每条都是一次具体踩坑后的总结，不是空泛的"最佳实践"。
读法：先看 **症状**，再看 **根因**，最后看 **怎么避免**。

---

## 1. 不要在 `View.body` 里 mutate `@Observable` 属性

### 症状

App 启动后 SwiftUI 主线程 99% CPU，UI 完全卡死。`sample` 抓栈：

```
GraphHost.flushTransactions
 → GraphHost.runTransaction
   → AG::Subgraph::update
     → ResolvedTextFilter.updateValue
       → PropertyList.Tracker.hasDifferentUsedValues
         → compare → TrackedValue.hasMatchingValue
           → PropertyList.subscript.getter
             → find1 (递归 4 层以上)
```

切换会话或 force-quit 是唯一逃出。

### 根因

`ConversationView.body` 里有：

```swift
var body: some View {
    let vm = app.conversation(for: agentId)   // ← 每次渲染都调
    ...
}
```

`conversation(for:)` 在 v0.2.40 加了 LRU 访问顺序刷新：

```swift
func conversation(for agentId: String) -> ConversationViewModel {
    if let existing = conversations[agentId] {
        conversationAccessOrder.removeAll { $0 == agentId }   // ← 写 @Observable
        conversationAccessOrder.append(agentId)               // ← 写 @Observable
        return existing
    }
    ...
}
```

`conversationAccessOrder` 是 `AppViewModel` 上的 `@Observable` 属性。SwiftUI 的依赖追踪是 per-property 的——*理论上*没 View 读这个属性就不会触发其它 View 重渲染。

但实际上：

- `body` 调用过程中走 `ObservationRegistrar` 的 `willSet` / `didSet`，把当前 transaction 标脏
- 即使没有 View 显式订阅，GraphHost 在 `flushTransactions` 阶段仍要扫一遍整个 PropertyList 比较新旧值
- 大会话场景下（3.6K 行 timeline、上百个嵌套 view），这一轮比较本身就是 100ms+
- 每次 `body` 再次跑都触发一次写、再触发一轮比较，**自循环成立**

99% CPU 不是死循环，是 SwiftUI 在以每秒数十次的频率重新评估一棵 ~3K 节点的视图树。

### 怎么避免

**`body` 必须是纯函数**——只读 state，不写。

具体到 LRU：访问已有 VM 时**不要**刷新顺序。退化为 FIFO 淘汰（按创建顺序踢），对几十个 agent 的规模完全够用。

```swift
func conversation(for agentId: String) -> ConversationViewModel {
    if let existing = conversations[agentId] { return existing }   // 不写
    let vm = ConversationViewModel(...)
    conversations[agentId] = vm
    conversationAccessOrder.append(agentId)   // 创建时才写
    Task { await vm.loadInitial() }
    evictStaleConversations()
    return vm
}
```

如果一定要在用户切换会话时刷新顺序，应该绑到 `selectedAgentId` 的 `didSet` 或 `.onChange(of: app.selectedAgentId)`——状态变化的事件源，不是渲染。

### 提前嗅探

- VM/Model 上写 `[weak self] { self?.mutate() }` 之类的 closure 容易被从 body 误调
- 凡是计算属性返回值还顺手写状态的，都是雷

---

## 2. Reconnect 重试不要无条件从 `.failed` 状态恢复

### 症状

App 打开后看起来连上了但 agent 列表空白。daemon 日志显示同一个 client 在 5 秒内发出 14 个 `fetch_agents_request`，最多 11 个并发，每个堵 4-5 秒。

### 根因

v0.2.40 改了 `scheduleReconnect`：

```swift
// 原版
guard case .disconnected = connectionState else { return }

// v0.2.40
switch connectionState {
case .disconnected, .failed: break   // ← 加了 .failed
default: return
}
```

动机是好的：网络抖动导致重试失败后 state 变 `.failed`，原版会就此放弃；新版让循环继续。

但 paseo 的传输栈：

- 客户端 → Cloudflare relay → daemon
- relay 有消息缓冲 + grace session（断连后短时间内重连会 resume）

当 relay 偶发抖动 + 客户端持续重试：

1. connect() 内 WS 握手成功，发 fetch_agents
2. relay 抖了一下，daemon 没收到（或响应丢了）
3. 客户端 timeout, state → .failed
4. **新代码继续重试**，下一个 connect() 又发 fetch_agents
5. 此时上一个 connect 留下的 grace session 还活着，relay resume 它，**重放**之前没送达的 fetch_agents
6. 累计起来 5 秒 14 个请求，daemon 来不及响应，相应丢失/延迟
7. 客户端永远拿不到 agent 列表

### 怎么避免

原版的"失败一次就放弃，等用户手动点重连"反而是稳健的——它给了系统冷却时间。

如果一定要让 `.failed` 也自动重试，得加：

- **更长的初始退避**：1s 太短；5-10s 起步给 relay 清队列
- **请求级 dedup**：客户端不应该重发已发出的 fetch_agents，除非确认前一个失败了
- **circuit breaker**：连续失败 N 次就停止自动重试，转回手动

最稳的做法：保持原版行为，只在用户能感知的地方（sidebar footer 的 reconnect 按钮）暴露重试入口。

---

## 3. 图片字节直接挂 Row 上的内存代价

### 症状

长会话内存占用线性上涨。一张截图 2-10MB，攒几十张就是几百 MB 常驻。

### 根因

`PendingImageAttachment` 原本：

```swift
struct PendingImageAttachment: ... {
    let id: UUID
    let pngData: Data   // ← 完整 PNG 字节
    ...
}
```

附件粘进 composer → 发送 → 写到 `Row.images` → row 永远活在 `ConversationViewModel.rows` 里 → VM 又活在 `AppViewModel.conversations` 直到 disconnect。中间没有任何回收路径。

### 怎么避免

把字节落盘，struct 里只留 URL：

```swift
struct PendingImageAttachment: ... {
    let id: UUID
    let fileURL: URL   // ~/Library/Caches/PaseoMac/images/<uuid>.png
    let width: Int
    let height: Int
    let mimeType: String

    var pngData: Data {   // 改成 computed，只在 RPC 发送时读一次
        (try? Data(contentsOf: fileURL)) ?? Data()
    }
}
```

显示走 `NSImage(contentsOf: fileURL)`（NSImage 内部有自己的缓存）。

落盘点：`PendingImageAttachment.from(image:)` 写 PNG 到 cache 目录，文件名 = `<id>.uuidString.png`。
清理点：`PaseoMacApp.init()` 调 `cleanOldCache(olderThan: 7天)`。

### 注意

- `Hashable` 合成出来会包含所有存储属性。`fileURL: URL` 比 `pngData: Data` 比较快得多——这是免费的副作用
- 历史消息（`rowFromEntry` 路径）`images: []` 是空的，daemon 不回传图片字节。所以这套方案只对**本会话内发出的**图片有效；重启后历史 row 没图是预期行为
- `cleanOldCache` 同步执行在 App init 里要小心——遍历 dir 慢的话会拖启动。我这里是 cache 自己管的目录，文件数受限于 7 天活跃发送量，问题不大

---

## 4. `turn_completed` 后需要补一次 scroll-to-bottom

### 症状

回复结束后，最后几行内容被 composer 挡住，要切换会话再切回来才能看全。

### 根因

`turn_completed` 触发两件事：

1. 最后一个 assistant row 被 stamp 上 `durationSec`（`TurnMetaChip` 出现，bubble 长高）
2. 底部的 `TurnStatusBar` 从"进行中"切换为"已完成"样式

但已有的自动滚动监听器只看：

```swift
.onChange(of: vm.rows.count) { ... }
.onChange(of: vm.rows.last?.text ?? "") { ... }
```

count 没变、text 没变 → **没人触发 scroll**。layout 增高的部分被推到 composer 下面。

### 怎么避免

加一个 `.onChange(of: vm.isAgentWorking)`，从 true 变 false 时延迟 150ms 滚到底：

```swift
.onChange(of: vm.isAgentWorking) { _, isWorking in
    guard !isWorking, !suppressAutoScroll else { return }
    Task {
        try? await Task.sleep(nanoseconds: 150_000_000)
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}
```

150ms 是给 SwiftUI 完成 layout 用的——太短滚不到位，太长用户感知到延迟。

### 提前嗅探

凡是"state 变化触发 UI 长高但 row count 不变"的场景，自动滚动都不会触发，需要额外补一个事件源。常见的：

- meta chip 显现（model + duration）
- 折叠/展开 tool detail
- markdown 代码块语法高亮异步完成（图片懒加载也是）

---

## 诊断手段速查

按"先廉价后昂贵"顺序：

1. **`ps -o pid,pcpu` + `sample <pid> 1`**——CPU 异常瓶颈，主线程栈一目了然
2. **`~/Library/Logs/PaseoMac/paseomac.log`**——`EventLogger` 是 JSONL，`jq` 或 `python -c "import json"` 看时序
3. **daemon 端 `~/.paseo/daemon.log`**——`ws_runtime_metrics` 每 30s 一份，能看出请求并发数、慢请求、session resume 次数
4. **`md5` 二进制 vs `.build/release/PaseoMac` vs `/Applications/.../MacOS/PaseoMac`**——确认部署的是不是当前编译产物
5. **Xcode → View Debugger** (`-XCInspectorOverlays YES`)——SwiftUI 重渲染热点

`sample` 输出里关键词：
- `GraphHost.flushTransactions` 持续高 → view 树反复脏标记
- `ResolvedTextFilter.updateValue` → 环境值传播
- `find1` 递归深 → PropertyList 太长（可能不是问题，但提示视图嵌套深）

---

## 通用原则

- `@Observable` 属性写入路径要可枚举：哪些 user action、stream event、timer 会改它？凡是不在这个清单里的（尤其是 view body / computed property），都要排查
- 网络重试要分层：传输层（WS）、协议层（RPC）、应用层（refresh）。每层独立 backoff，不要级联
- 内存持有路径要可绘制：`AppViewModel.conversations` → `ConversationViewModel.rows` → `Row.tool.detailKind / Row.images` 这条链上任何节点持有大字节，都会等到 disconnect 才释放
- 部署后**必须**重新打开 app 验证，CFBundleVersion 已对就够说明部署的是新版
