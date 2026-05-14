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
