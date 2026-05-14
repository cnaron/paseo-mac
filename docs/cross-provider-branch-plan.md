# 跨 Provider 切换（精简版）

> 替代 [`cross-provider-thread-plan.md`](cross-provider-thread-plan.md)。原方案因引入 thread 抽象 + 多 agent 时间线归并导致 client 重负，且只换来 sidebar 「一行」的视觉一致性，性价比不合算。本版回到协议自带的入口，最小改动。

## 核心思路

**不引入 thread。** 每个 daemon agent 还是 sidebar 一行。切换 = 用同 cwd 新建一个目标 provider 的 agent，把当前会话最近 N 轮 user/assistant 内容作为 `createAgent.initialPrompt` 传过去。

`initialPrompt` 是 daemon 协议自带的字段——内容会被 daemon 当成新 agent 的第一条 user message 发给新 provider。**这就是「官方做了」的部分**，不用我们另发明上下文搬运机制。

```
[当前 Claude 会话]
  ├── user: ...
  ├── assistant: ...   ←  最近 N 轮提取
  └── user: 帮我继续

  ↓ 用户点 "Continue with Gemini"

[新 Gemini 会话，sidebar 多出一行]
  ├── user (= initialPrompt):
  │     [Continuing from prior Claude conversation]
  │     **User**: ...
  │     **Assistant**: ...
  │     **User**: 帮我继续
  │     [Please pick up from here.]
  ├── assistant (Gemini 回的): 接着上面继续...
  ↓
  selectedAgentId 自动切到这个新 agent，UI 滚到底，用户接着用
```

## 三处改动

### 1. AppViewModel 加一个 action（~30 行）

```swift
func branchAgent(fromAgentId: String, newProvider: String) async {
    guard let source = agents.first(where: { $0.id == fromAgentId }),
          let client else { return }
    let vm = conversations[fromAgentId]
    let bootstrap = buildBranchBootstrap(sourceVM: vm, sourceTitle: source.title)
    let cwd = source.cwd

    // 用现成 createAgent 路径，bootstrap 走 initialPrompt
    knownAgentIds = Set(agents.map(\.id))
    do {
        try await client.createAgent(
            cwd: cwd, provider: newProvider,
            model: nil, modeId: nil, thinkingOptionId: nil,
            initialPrompt: bootstrap
        )
    } catch {
        EventLogger.shared.log("branch", "error", ["err": error.localizedDescription])
        return
    }
    // 复用 submitPendingAgent 里那套等待 turn_started / poll fallback 的逻辑
    // 拿到 newAgentId 后：
    //   selectedAgentId = newAgentId
}

private func buildBranchBootstrap(sourceVM: ConversationViewModel?, sourceTitle: String?) -> String {
    let rows = sourceVM?.rows ?? []
    let recent = rows
        .filter { ["user", "assistant"].contains($0.kind) }
        .suffix(8)   // 最多 4 轮 user/assistant pair
    let transcript = recent.map { row in
        let role = row.kind == "user" ? "User" : "Assistant"
        return "**\(role)**: \(row.text)"
    }.joined(separator: "\n\n")
    let titleNote = sourceTitle.map { " titled \"\($0)\"" } ?? ""
    return """
    [Continuing a prior conversation\(titleNote). The user and I have already discussed the below; please pick up from there.]

    \(transcript)

    [End of prior context. The user will send their next message after your acknowledgment.]
    """
}
```

「等待 newAgentId」的逻辑跟现有 `submitPendingAgent` 里那段完全一样，可以抽个 helper 共用，或者复制一份。

### 2. ConversationView toolbar 加 Branch 入口（~20 行）

```swift
ToolbarItem(placement: .primaryAction) {
    Menu {
        ForEach(branchableProviders) { prov in
            Button {
                Task { await app.branchAgent(fromAgentId: agentId, newProvider: prov.provider) }
            } label: {
                Label("Continue with \(prov.label ?? prov.provider)",
                      systemImage: ProviderIcon.symbolName(for: prov.provider))
            }
        }
    } label: {
        Image(systemName: "arrow.triangle.branch")
    }
    .help("Continue this conversation with a different provider")
    .disabled(branchableProviders.isEmpty)
}

private var branchableProviders: [ProviderSnapshot] {
    let current = agent()?.provider
    return app.providers
        .filter { $0.status == "ready" && $0.provider != current }
}
```

`branchableProviders` 排掉当前 agent 自己的 provider，剩下 ready 的就是可切换目标。多数情况只列 1 个（Claude ↔ Gemini）。

### 3. 新 agent 显示标记（可选，~10 行）

刚 branch 出的 agent，sidebar 行加个小细节让用户能看出"这是从某个会话续来的"：

可以在新 agent 的 title 旁加个 `↳` icon（如果有 daemon 字段标记 source）；或者就**不做**——用户在 sidebar 看新条目就是接着前一个 cwd 创建的，根据顺序自然能识别。

第一版不做。


---

## Button UX 细节

### 放在哪

ConversationView 的 **toolbar 右侧**，跟现有的 `+`（新建会话）、`⌕`（搜索）并排：

```
                                       [+]  [↗▾]  [⌕]
─────────────────────────────────────────────────────
  Conversation content
  ...
  ┌──────────────────────────────────────┐
  │  Composer                            │
  └──────────────────────────────────────┘
```

为什么放 toolbar 不放别处：

- **不放 composer 区**：composer 只在 active conversation 时出现，archive 状态、search 状态会消失。toolbar 全状态可见
- **不放 status bar 区**：status bar 是关于上一轮的元数据（model · duration），跟 branch 是动作，混在一起会让人误以为 chip 可点
- **不放 sidebar 右键**：太隐藏，新用户不会发现

### Icon 选哪个

`arrow.triangle.branch` —— SF Symbol 里专门表达分叉的那个，看一眼就懂。带个小 `▾` chevron 暗示是个下拉菜单。

不用 emoji。不用文字 "Branch"——保持跟现有 `+` `⌕` 同 visual weight。鼠标 hover 上去 tooltip 显示完整意思：

> Continue this conversation with another model

### 可见性 & 启用条件

| 状态 | Button 表现 |
|---|---|
| Pending (新建尚未发消息) | 隐藏 | 没东西能 branch |
| 当前会话 0 行 | 隐藏 | 同上 |
| 当前会话有内容 + 只有 1 个 provider ready | 显示但 disable，tooltip "No other providers ready" | 让用户知道功能存在但当前用不上 |
| 当前会话有内容 + ≥ 2 个 provider ready | 启用 | 正常状态 |
| Archived 会话 | 启用 | branch 后是个新的 active agent，这是 archive 恢复的一种姿势 |
| Branch 进行中 | 显示 ProgressView 替代 icon ~1s | 给用户视觉反馈，daemon spawn 会有几百 ms 到几秒 |

### 菜单结构（关键决策：只到 provider 层）

```
┌─────────────────────────────────────┐
│ Continue with...                    │
├─────────────────────────────────────┤
│ ✨  Claude                          │  ← 当前 provider，灰掉
│ 🔷  Gemini CLI                      │
│ ⌨   Codex                           │  ← 如果 daemon 配了 codex
│ ⌨   OpenCode                        │  ← 同上
└─────────────────────────────────────┘
```

- **每条 = 一个 provider**，使用各自默认 model
- **当前 provider 也列在菜单里但 disabled**（灰），label 后面跟着 "(current)"——这样用户能确认菜单确实是反映"所有可选项"，不会误以为某个 provider 没装
- **图标**：用任务 A 里定义的 `ProviderIcon`，跟 sidebar 一致
- **label**：优先用 `ProviderSnapshot.label`（daemon 配的人类可读名，如 "Gemini CLI"），缺失时 fallback 用 `provider` id

#### 为什么只到 provider 层，不展开 model

考虑过更细的 2 层菜单：

```
Continue with...
├─ Claude →  Opus 4.7
│            Sonnet 4.6
│            Haiku 4.5
├─ Gemini  (only one model)
└─ Codex →  ...
```

**否决理由**：

1. 同 provider 内换 model **已经有现成 UI**——composer 区的 model picker。branch 不应该跟它抢职责
2. 用户在 branch 这个动作里关心的是 **"换 provider"**，跨 provider 才是核心场景。3 层 nesting 让常见操作变重
3. 新 agent 创建出来后，composer 的 model picker 还在，用户可以二次调整 model。多一步但更清晰

**未来如果有人提需求**：菜单底部加一条 "More options..."，弹个 sheet 让用户精确选 provider + model + mode + thinking option。在 PaseoMac 第一版用户里这需求频率应该很低，先不做。

#### Provider 排序

按一个稳定顺序，不随 daemon 上报顺序变（避免每次连接菜单顺序漂移）：

```swift
private static let providerOrder = ["claude", "gemini", "codex", "opencode", "copilot", "pi"]
```

不在 known list 里的（用户自定义 ACP）排在最后，按字母序。

### Branch 后的视觉延续

点了 "Gemini CLI" 之后：

1. **toolbar 上 button 变 ProgressView** ~500ms~3s（取决于 daemon spawn 速度）
2. **sidebar 几乎同时多出一行**（新 agent 加入 agents 列表）
3. **selection 自动切到新 agent**——ContentView `.id(agentId)` 会重建 ConversationView，scroll 自动落底
4. 新 conversation 第一条 user bubble 是 bootstrap 文本（看起来就像一条正常的 user message，但内容是 prior 上下文 transcript）
5. Gemini 流式响应 "Got it, continuing from your last question about X..."

#### 是否要"折叠" bootstrap message？

bootstrap 那条本质是机器构造的 prompt，用户不一定想看完。考虑两种渲染：

**A. 完整显示** — 跟普通 user message 一样
- 透明：用户能看到 client 实际发了什么
- 长度可能很大（4 对 user/assistant），占屏

**B. 折叠** — 一行 placeholder "↳ Continued from prior conversation (4 turns)"，点击展开
- 简洁
- 需要在 Row 上加 `kind: "bootstrap"` 区分

**建议 A**：第一版透明优先，让用户能调试。如果实际使用觉得占屏，再升级 B。

### 跟 sidebar 的关系

branch 后 sidebar 多一行，**不做合并**（跟之前 thread 方案的对比）。但可以加一点视觉提示：

- 新 agent 的 title（daemon 生成的，基于第一条 user message 内容）会反映 "continuing from..."——免费拿到的语义提示，不用额外标记
- sidebar row 上不强加 `↳` 之类符号——避免引入"agent 之间的关系图"概念，保持平铺简单

如果用户后来抱怨 "找不到我从哪个会话 branch 出来的"，再考虑加显式追溯（client 存 `branchFrom: String?`）。

### Edge cases

| 情况 | 处理 |
|---|---|
| daemon spawn 超时 | createAgent 抛错；toolbar button 恢复 icon；EventLogger 记 `branch:error`；用户看不到新会话出现（无副作用），可重试 |
| 新 agent 创建成功但 bootstrap 发送失败 | 新 agent 已经在 sidebar 了但没有内容；用户可以手动发消息或删掉 |
| 用户在 branch 进行中点了别的会话 | 不阻断；branch 完成后新 agent 静静出现在 sidebar，**不再自动切 selectedAgentId**（用户已经表达了不同意图） |
| 当前 conversation 太长（几百行）| bootstrap 只取最近 4 对 user/assistant，限制 8 行（已在 buildBranchBootstrap 里实现） |
| 用户连续 branch 两次 | 都生效；sidebar 会有 3 个 agent（原 + 第一次 branch + 第二次 branch）。第二次的 bootstrap 是从**第一次 branch 后的内容**取的，不是从原始 |

### Branch 入口的代码骨架（更新版）

替代 [`第 2 节`](#2-conversationview-toolbar-加-branch-入口20-行) 里的草稿：

```swift
ToolbarItem(placement: .primaryAction) {
    Menu {
        ForEach(branchTargets, id: \.provider) { entry in
            Button {
                Task { await app.branchAgent(fromAgentId: agentId, newProvider: entry.provider) }
            } label: {
                Label(
                    entry.label + (entry.isCurrent ? " (current)" : ""),
                    systemImage: ProviderIcon.symbolName(for: entry.provider)
                )
            }
            .disabled(entry.isCurrent || entry.status != "ready")
        }
        if branchTargets.allSatisfy({ $0.isCurrent || $0.status != "ready" }) {
            // 全 disable 时给个明示
            Divider()
            Text("No other providers ready").font(.caption).foregroundStyle(.secondary)
        }
    } label: {
        if app.branchInFlight == agentId {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "arrow.triangle.branch")
        }
    }
    .help("Continue this conversation with another model")
    .disabled(shouldDisableEntirely)
}

private var branchTargets: [BranchTarget] {
    let current = agent()?.provider
    return Self.providerOrder.compactMap { id in
        guard let snap = app.providers.first(where: { $0.provider == id }) else { return nil }
        return BranchTarget(
            provider: id,
            label: snap.label ?? id.capitalized,
            status: snap.status,
            isCurrent: id == current
        )
    }
}

private var shouldDisableEntirely: Bool {
    let vm = app.conversation(for: agentId)
    return vm.rows.isEmpty || branchTargets.filter { !$0.isCurrent && $0.status == "ready" }.isEmpty
}

private static let providerOrder = ["claude", "gemini", "codex", "opencode", "copilot", "pi"]

private struct BranchTarget {
    let provider: String
    let label: String
    let status: String
    let isCurrent: Bool
}
```

`branchInFlight: String?` 是 AppViewModel 上的新 state，记录"哪个 agent 正在 branch 中"，让 toolbar 知道何时显示 ProgressView。

## 用户体验流程

正常 case：

1. 在 Claude 会话里聊到 quota 紧张
2. toolbar 点 `↗` 按钮 → 弹出 "Continue with Gemini"
3. 一秒内 sidebar 多一行（默认标题是新会话的 daemon 生成 title），selectedAgentId 自动切过去
4. 新会话 view 里第一条 user message 是 bootstrap 文本（折叠或正常显示，跟普通 user message 没区别）
5. Gemini 紧接着回了一条 "OK 接着上面的..."
6. 用户继续输入下一条

需要回看 Claude 那边 → sidebar 切回去就行，老 conversation 还在。

## 跟原 thread 方案的对比

| 维度 | thread 方案（已废） | branch 方案（本版） |
|---|---|---|
| 数据模型新增 | `ConversationThread`、`agentToThread`、`selectedThreadId` | 无 |
| Sidebar 改造 | 每行渲染 thread 而非 agent，selection 模型变 | 不动 |
| ConversationView | 新 `ThreadViewModel`，跨 agent 归并 timeline | 不动 |
| Timeline 合并性能开销 | 长 thread 每帧 O(N log N) | 0 |
| 用户感知 | sidebar 一行从头到尾 | sidebar 多出一行 |
| 上下文 | initialPrompt | initialPrompt |
| 工作量 | 4-5.5 h | 1-1.5 h |
| 失败回退 | 多个 agent 状态要对齐 | 删掉新 agent 即可 |

branch 方案在用户感知上的"代价"就是 sidebar 多出一行——但这一行客观上**就是新会话**（绑了新 provider、独立 daemon session），sidebar 如实反映本来就比强行合并更诚实。

## 自动 fallback（Phase 2，可选）

Layer 1 落地后，当 Claude `turn_failed` 且错误信息匹配 quota 关键词（`quota`, `rate_limit`, `usage_exceeded`），UI 弹一个 inline 按钮 "Continue with Gemini?" 在错误 bubble 下方。用户点一下就触发 branch。

不做自动直接切——quota 检测的 string match 脆弱、误判会让用户莫名其妙跨 provider，建议做成"明确二次确认"。

## 工作量

| 项 | 时长 |
|---|---|
| `branchAgent` + `buildBranchBootstrap` | 45 min |
| toolbar UI + ProviderIcon menu | 20 min |
| 测试 | 15 min |
| 合计 | **1-1.5 h** |

发布 v0.2.50（合并到 multi-provider-ux 那批一起发，单次部署）。

## 风险

- **bootstrap 太长 token 爆**：限制 8 行（4 个 pair）。超长用户消息可以做 truncation：超过 2000 字符截到 2000 + "..."
- **新 provider 不认这种 meta prompt**：实测看效果，无效就调 prompt 措辞
- **branch 失败留下半残 agent**：daemon 拒绝创建时不切 selectedAgentId；如果创建成功但 send 失败，agent 留在 sidebar 用户能手动删

## 不做的

- thread 抽象、timeline 归并、多 agent 复合视图——除非未来用户高频跨 provider 切，发现 sidebar 列表太杂时再回头看
- 自动迁移 tool 调用历史、文件读取记录——这些跨 provider 没意义，新 provider 该重新 explore 就重新 explore
- 让 daemon 加 `set_agent_provider_request`——超出 client 范围
