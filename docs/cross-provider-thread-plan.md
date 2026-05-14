# 跨 Provider 无感切换 + 上下文延续

> **已废弃（superseded）**：原方案引入 thread 抽象 + 多 agent 时间线归并，对 SwiftUI 重渲染负担过重。改用 [cross-provider-branch-plan.md](cross-provider-branch-plan.md) 的简化版——不抽象 thread，每次切换就是新建一个 agent，sidebar 多出一行，用 createAgent.initialPrompt 把 prior 内容传过去。本文保留作思路演进记录。

---


更新自 `multi-provider-ux-plan.md` 里的"任务 D"。重新审视后，发现做到「无感 + 带核心上下文」是可行的——daemon 协议不改，所有粘合都在 client 端做。

---

## 核心思路：客户端"thread"抽象层

daemon 不知道有"thread"这个概念。它只看到一堆独立 agent。**client 自己维护「会话线」=「N 个 agent 的有序串联」**，sidebar 里展示成一行，ConversationView 里把多个 agent 的 timeline 按时间戳归并展示。

切换 provider 时：
1. 用同 cwd 新建一个 Gemini agent
2. 把当前 thread 里的对话内容**作为新 agent 的第一条 user message** 发过去（`createAgent.initialPrompt`）——daemon / ACP 现成的字段，无需协议改动
3. 新 agent id 追加到 thread 的 `agentIds` 数组里
4. UI 上 sidebar 一行不变，bubble 继续追加，只是新 bubble 的 provider chip 是 Gemini

用户视角：一个会话从头到尾，前面是 Claude 回的，后面切了之后是 Gemini 回的，连续可读。

---

## 数据模型

```swift
struct ConversationThread: Codable, Hashable {
    let id: String            // UUID, 客户端生成
    var agentIds: [String]    // 顺序：最早创建到最新
    let cwd: String
    let createdAt: Date
}
```

`AppViewModel` 加：

```swift
var threads: [String: ConversationThread] = [:]   // threadId -> thread
var agentToThread: [String: String] = [:]         // agentId -> threadId（反向索引）
```

持久化：`UserDefaults` 一个 JSON blob `paseomac.threads`。app 启动时 load，每次 mutate 后 save。

启动 reconcile 逻辑：

1. `refreshAgents()` 拿回 daemon 上的 agent 列表
2. 对每个 agent，如果 `agentToThread[agentId]` 缺失（旧数据或外部创建），自建一个 thread：`Thread(id: UUID, agentIds: [agentId], cwd: agent.cwd)`
3. 这样保证存量 agent 不丢

---

## Sidebar 渲染改造

`AgentListView.agentRows` 从遍历 `app.agents` 改成遍历 `app.threads.values`，每个 thread 显示为一行：

- `displayName` 取**最新 agent** 的 title（thread head 总是反映最近活动）
- `provider` 用**最新 agent** 的 provider——`ProviderIcon` 显示最新的 provider 图标
- `status` 用最新 agent 的 status
- `liveStatus` 同样

**Selection 模型变更**：`selectedThreadId: String?`（替代 `selectedAgentId`）。点 thread 进去时，ConversationView 拿这个 threadId 渲染。

发消息 / 切 model 等动作走最新 agent。

### 「Continue with another provider」入口

`ConversationView` toolbar 加一个 button：

```
[Switch ▾]   →   弹出菜单
              Continue with Gemini
              Continue with Claude (if currently Gemini)
              ...
```

点了执行 `app.continueThread(threadId, newProvider:)`：

```swift
func continueThread(_ threadId: String, newProvider: String) async {
    guard let thread = threads[threadId] else { return }
    let bootstrap = buildBootstrapMessage(threadId: threadId)
    // createAgent 走现成路径，模型 / mode 选 newProvider 的默认
    let cwd = thread.cwd
    let agentId = try? await createAgentSync(
        cwd: cwd, provider: newProvider, initialPrompt: bootstrap
    )
    guard let agentId else { return }
    threads[threadId]!.agentIds.append(agentId)
    agentToThread[agentId] = threadId
    saveThreads()
    // 选中后续会自然落到这个 thread；selectedThreadId 没变
}
```

`createAgentSync` 是 `submitPendingAgent` 的非 pending 版本（直接拿 daemon 返回的 agentId）。

---

## ConversationView Timeline 归并

`ConversationView(threadId:)` 内部：

1. 从 `app.threads[threadId].agentIds` 拿所有 agent
2. 对每个 agent 拿其 ConversationViewModel.rows
3. 按 `Row.timestamp` 排序归并

但 `ConversationViewModel` 当前是 `agentId → rows`。归并逻辑放在哪？两个选择：

**方案 A：保留 ConversationViewModel 不变，新建 `ThreadViewModel` 包装**

```swift
@MainActor @Observable
final class ThreadViewModel {
    let threadId: String
    var rows: [Row] { /* 合并 children */ }
    var isAgentWorking: Bool { children.last?.isAgentWorking ?? false }
    ...
    private var children: [ConversationViewModel] {
        guard let thread = app.threads[threadId] else { return [] }
        return thread.agentIds.map { app.conversation(for: $0) }
    }
}
```

`rows` 是 computed，每次 SwiftUI 读取重新归并。children 的 rows 一变就触发 view 更新。

**方案 B：只在 view body 里做归并，不抽 VM**

简单但每次 view 重渲染要做 merge。考虑到上次踩过 view body mutate state 的坑，**优先方案 A**。

### 渲染：provider 切换分隔符

归并出的 rows 数组，相邻 row 来自不同 agent 时，插入一条 "─── Switched to Gemini ───" 分隔行（kind="provider_switch"，文本是新 provider label）。

```swift
private func mergeWithSeparators(_ children: [ConversationViewModel]) -> [Row] {
    var out: [Row] = []
    var lastProvider: String? = nil
    for child in children {
        let agentProvider = app.agents.first(where: { $0.id == child.agentId })?.provider
        if let p = agentProvider, p != lastProvider, lastProvider != nil {
            out.append(Row.providerSwitch(to: p))
        }
        out.append(contentsOf: child.rows)
        lastProvider = agentProvider
    }
    return out
}
```

`ConversationView` 渲染 row 时遇到 `kind == "provider_switch"` 渲染成一条带图标的 divider。

---

## Bootstrap message 设计

`createAgent.initialPrompt` 字段就是 daemon 发给新 agent 的第一条 user message。塞 prior conversation context：

```swift
func buildBootstrapMessage(threadId: String) -> String {
    let thread = threads[threadId]!
    let agentId = thread.agentIds.last!     // 当前 active agent
    let vm = conversations[agentId]!
    
    // 取最近 N 个 user/assistant pair，跳过 tool 调用细节
    let recent = vm.rows
        .filter { ["user", "assistant"].contains($0.kind) }
        .suffix(10)   // 最多 5 轮
    
    let transcript = recent.map { row in
        let role = row.kind == "user" ? "User" : "Assistant"
        return "**\(role)**: \(row.text)"
    }.joined(separator: "\n\n")
    
    return """
    [Continuing a prior conversation. The user and I have already discussed the below; please pick up from here.]

    \(transcript)

    [End of prior context. Please continue from the user's latest question above.]
    """
}
```

**注意**：
- 不带 tool 调用细节（太长 + 新 provider 用不上）
- 限定 N 轮避免 token 爆炸
- 标记清楚是 prior context，新 provider 不会把它当成 fresh 用户输入

### 进阶：让旧 provider 自己写 summary

Bootstrap 之前先调当前 provider 自己写 "summarize what we've done so far"，然后把 summary（不是原文）塞给新 provider。token 省一个量级。但要多一次往返。

第一版用直接 transcript 即可，summary 留 backlog。

---

## Layer 2（可选）：自动切换

Layer 1 落地后，再做自动 fallback：

1. 设置项里加 "Auto-fallback when current provider hits quota"（默认关）
2. AppViewModel 监听 `turn_failed` 事件，匹配 quota 错误关键词（`"quota"`, `"rate_limit"`, `"usage_exceeded"` 等）
3. 命中后自动调 `continueThread(threadId, newProvider: alternateProvider)`
4. 用户视角：发了条消息 → Claude 失败提示一闪而过 → 新 bubble 自动用 Gemini 回了

风险：误判（短暂网络错误被当成 quota），quota 检测的 string match 脆弱。先手动 + UI 提示，自动留观察期。

---

## 边界 / 容错

| 场景 | 处理 |
|---|---|
| **archive 整个 thread** | 调 `archiveAgent` 对 thread 里**所有** agent；thread record 移到 archivedThreads |
| **某个 agent 在 daemon 端被删了** | refreshAgents 之后那个 id 找不到了 → 从 thread.agentIds 移除；如果 thread 空了，归档 thread record |
| **手动外部新建 agent**（CLI 或别处） | refreshAgents 拿回新 agent → 创建独立 thread 收纳 |
| **continue 失败**（新 agent 没建成） | thread.agentIds 不追加；UI 提示"Continue failed"，回到当前 active provider |
| **同 thread 反复切**（claude→gemini→claude→gemini） | thread.agentIds 越来越长；timeline 归并照常 |
| **app 重启** | UserDefaults 里 load threads，refresh 后跟 agents 对账，缺的补一个独立 thread |
| **delete (archive) thread 中间某个 agent** | 不允许通过 UI 做——只允许 archive 整 thread |

---

## 实施分步

### Phase 1：thread 抽象层 + 持久化（基础）
1. 新增 `ConversationThread` model
2. AppViewModel 加 `threads`、`agentToThread`、`selectedThreadId`
3. 启动 / refreshAgents 后跑 reconcile（每个孤儿 agent 建 thread）
4. UserDefaults 持久化

### Phase 2：sidebar 改成 thread 视角
5. `AgentListView` 遍历 threads；selection 走 selectedThreadId
6. archive / delete 行为对应到所有 backing agent

### Phase 3：timeline 归并 + 渲染
7. 新 `ThreadViewModel`
8. `ConversationView` 改 `init(threadId:)`，从 ThreadViewModel 拿 rows
9. Row 新增 `.providerSwitch` kind，view 渲染分隔行
10. 发消息走 thread 的最新 agent

### Phase 4：continue 入口
11. ConversationView toolbar 加 "Switch ▾"
12. `continueThread(threadId, newProvider:)` 实现
13. bootstrap message builder
14. 切换后 streaming 正常显示

### Phase 5（可选）：自动 fallback
15. 设置项 + 错误识别 + 自动调 continueThread

---

## 工作量

| Phase | 时长 |
|---|---|
| 1：thread 抽象 + 持久化 | 1-1.5 h |
| 2：sidebar 视角切换 | 1 h |
| 3：timeline 归并 + 渲染 | 1.5-2 h（最复杂，归并和分隔行） |
| 4：continue 入口 | 1 h |
| 5：自动 fallback | 1 h（独立可选） |

**Phase 1-4 合计 4-5.5 h**，比 multi-provider-ux 那份重很多——是因为 sidebar 的 selection 模型从 agent 改成 thread 触及面很大。但**这是值得的重构**：之后所有跟 conversation 相关的 UI 都基于 thread 而不是裸 agent，结构上更清晰。

---

## 跟 multi-provider-ux-plan 的关系

那份计划里的：
- **任务 A**（sidebar provider 图标）：照旧做，但 icon 取的是 thread 最新 agent 的 provider，会随切换更新
- **任务 B**（bubble model chip 兼容 Gemini）：照旧做，每个 bubble 显示自己 provider 来源时更合理
- **任务 C**（Gemini 额度外链）：照旧做，跟 thread 无关
- **任务 D**：被这份计划完整取代

建议顺序：
1. 先做 multi-provider-ux 的 A + B + C，约 75 min，**先获得视觉收益**（图标 + chip）
2. 再做这份的 Phase 1-4，4-5 h，**结构性升级**
3. Phase 5 等用户实际感受到 quota 痛点再做

---

## 风险与权衡

| 风险 | 说明 | 缓解 |
|---|---|---|
| **重构面大** | sidebar selection 从 agent 变 thread 触及 ContentView / AgentListView / ConversationView 多处 | Phase 1-2 不上线（feature flag 或单独分支），等 Phase 3-4 跟着上 |
| **timeline 归并性能** | 长 thread 跨 10 个 agent 各 1000 行，归并是 O(N log N)。SwiftUI 重渲染每帧跑可能卡 | ThreadViewModel 内部 cache 归并结果，只在 children rows 变化时重算 |
| **bootstrap 消耗 token** | 每次切换都把前文塞过去，长 thread 切多次累积大 | Phase 5 之前是用户手动行为，触发频率低；后续做 summary 模式 |
| **新 provider 不接受 system-style prompt** | "Continuing a prior conversation..." 这种 meta 提示对某些 model 可能效果差 | 实测调整 prompt；最差情况就是新 provider 重复一些已经讲过的话 |
| **daemon 不知道 thread 存在** | 后端搜索 / 归档逻辑还是 per-agent | 接受这个限制，client 用 thread 视图 + 对所有 backing agent 一致操作 |

---

## 不做的（划线）

- **不做** daemon 端协议改动（加 `set_agent_provider_request` 或 thread-aware 字段）——超出 PaseoMac scope
- **不做** 真正的「session 层迁移」（让 Gemini 沿用 Claude session id）——ACP 协议不支持
- **不做** UI 上隐藏 thread 内 agent 数量——sidebar 可以加角标显示「Claude + Gemini」混合提示
