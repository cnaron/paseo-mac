# 多 Provider UX 后续计划

接着 `gemini-cli-plan.md` 之后做的几件事。Gemini 能用了，但还有几处用起来明显比 Claude 残：

1. sidebar 上看不出某个会话是 Claude 还是 Gemini，只能凭记忆
2. Gemini 回复的 bubble 没有 model 标签和时间标识
3. 没有 Gemini 额度面板（Claude 在左下角有）
4. 想用「Claude 用完了切 Gemini」的场景没有顺手的路径

逐项 spec。

---

## 任务 A：sidebar 显示 provider 图标（容易，~30 min）

### 现状

`AgentListView.AgentRow` 的布局：

```swift
HStack(spacing: 8) {
    StatusIndicator(...)            // 8pt 状态点
    VStack(alignment: .leading) {
        Text(agent.displayName)
        Text(shortCwd ...)
    }
    Spacer()
}
```

`AgentSnapshot.provider` 是 `String?`，daemon 端是 `"claude"` / `"gemini"` / `"codex"` ...

### 设计

在 StatusIndicator 旁边放一个 12pt 的 provider 图标。**用 SF Symbol，不引外部资源**——保持构建简单。

| provider | SF Symbol | 备注 |
|---|---|---|
| `claude` | `sparkles` | 跟 Anthropic 风格相近 |
| `gemini` | `g.circle.fill` | 字母圆环 |
| `codex` | `terminal.fill` | OpenAI 的 CLI 工具 |
| `opencode` | `chevron.left.forwardslash.chevron.right` | 编程符号 |
| `copilot` | `airplane.circle` | GitHub Copilot 暗示飞行模式 |
| 其它 | `hammer.fill` | 兜底 |

颜色：跟随 system accent / secondary，不强加颜色（保持 SwiftUI 主题）。

### 实现要点

新组件 `ProviderIcon(provider: String?)`：

```swift
private struct ProviderIcon: View {
    let provider: String?
    var body: some View {
        Image(systemName: symbolName)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 14)
    }
    private var symbolName: String {
        switch provider {
        case "claude": return "sparkles"
        case "gemini": return "g.circle.fill"
        case "codex": return "terminal.fill"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        case "copilot": return "airplane.circle"
        default: return "hammer.fill"
        }
    }
}
```

放进 `AgentRow.body` 的 HStack，**在 StatusIndicator 和文字之间**：

```diff
 HStack(spacing: 8) {
     StatusIndicator(...)
+    ProviderIcon(provider: agent.provider)
     VStack(alignment: .leading) { ... }
```

`ArchivedAgentRow` 同样加。

### 风险

- daemon 偶尔会推 `agent.provider == nil` 的 status ping，前面已经用 `provider: other.provider ?? provider` 合并避免抹掉，目前看是 OK 的。但 ProviderIcon 接到 nil 时显示 fallback hammer，对历史 agent 也别意外
- SF Symbol 名跨 macOS 版本可能差异；至少 12+ 上 `sparkles` / `g.circle.fill` 都在

### 工作量

30 分钟，单文件改动。

---

## 任务 B：Gemini bubble 显示 model + duration chip（必要，~30 min）

### 现状

`ConversationView.MessageBubble` 的 assistant bubble：

```swift
MarkdownBodyView(text: group.text, ...)
if let model = group.modelUsed {
    TurnMetaChip(model: model, durationSec: group.durationSec)
}
```

`group.modelUsed` 来自 `Row.modelUsed`，赋值时是 `currentTurnModel`，而 `currentTurnModel` 来自 `agents.first(where: { $0.id == agentId })?.model`。

对 Claude：`agents[].model = "claude-opus-4-7[1m]"`，chip 正常显示。
对 Gemini（ACP）：`agents[].model = nil`（ACP 不暴露 model 概念，固定一种），`currentTurnModel = nil`，chip 整个不渲染。

### 设计

**让 chip 在没有 model 时回退到 provider label**。

引入 `displayName` 函数：

```swift
private func displayProviderModel(provider: String?, model: String?) -> String? {
    if let m = model, !m.isEmpty { return prettyModel(m) }
    switch provider {
    case "gemini": return "Gemini"
    case "claude": return "Claude"        // 不会走到，但兜底
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "copilot": return "Copilot"
    default: return provider?.capitalized
    }
}
```

### 实现要点

需要把 `provider` 也传到 Row 里：

1. `Row` 加 `provider: String?`
2. `appendStreamedRow` 接收 `currentProvider`（从 AppViewModel 传入）
3. `apply(streamEvent:..., currentModel:, currentProvider:)` 签名扩展
4. `AppViewModel.ingest()` 在调 `vm.apply(...)` 时一并传 provider
5. `TurnMetaChip` 接 model 和 provider，渲染时调 `displayProviderModel`
6. `metaCache` 多存一项 provider（向后兼容：解码失败用 nil）

约 50 行净改。Hashable / metaCache 持久化需要小心兼容旧数据（加 `provider: String?` 是 additive，老 JSON 解码会失败 → fallback 重新生成）。

### 边界

- 用户中途换 Claude 模型（opus → sonnet）：chip 上跟着变（现状已支持）
- Gemini 改了用 different model（理论上没有，但 daemon 升级后可能有）：chip 仍以 daemon 报上来的 model 为准
- 没有 turn_completed 也没 model 的极端情况：chip 整体不渲染，跟现在一致

### 工作量

30 分钟。改动比 A 大一倍。

---

## 任务 C：Gemini 额度面板（受限，~未知）

### 现状

`UsagePanel` 显示 Claude 5h / 7d 利用率，数据来自 VPS proxy 端点（`paseomac.usageApiUrl`），Claude.ai 订阅 API 后台抓取。

### Gemini 额度的可行性

**坏消息**：Google Gemini API 没有公开的「查我当前用了多少 token / quota」端点。可参考的只有：

1. **响应头里的 rate-limit info**——`X-RateLimit-Remaining` 等。但 Gemini CLI 走 ACP 到 daemon，前端拿不到原始响应
2. **Google Cloud Console**——网页端能看，需要登录 Google 账号
3. **Vertex AI billing API**——只对 Cloud 项目内的 Service Account 开放，且粒度是天级、滞后几小时
4. **Gemini CLI 本地状态**——`~/.gemini/` 里缓存 OAuth token 但**没有用量数据**

### 我能想到的可行方案

| 方案 | 准确度 | 维护成本 |
|---|---|---|
| 1. 在 daemon 端 wrap Gemini API 请求，本地计数请求量（按分钟 / 天） | 中（按请求数算，不算 token） | 中（需要改 daemon 或 ACP wrapper） |
| 2. 显示 Gemini 的免费层固定上限（60 RPM / 1000 RPD），不显示实时余量 | 低（只是科普） | 低 |
| 3. 用户填 Cloud Console 链接，左下角放个跳转按钮 | 信息全在外部 | 极低 |
| 4. 不做 | — | 零 |

### 推荐

短期：**方案 3**（一个外链按钮 + 静态文字说明免费层上限）。`UsagePanel` 加一段「Gemini」标签，点了打开 `https://aistudio.google.com/usage`（或 Google Cloud Console 用量页）。

长期（如果重度依赖 Gemini）：daemon 端做本地计数。这需要改上游 paseo daemon，超出 PaseoMac 范围，先不开坑。

### 工作量

方案 3 大概 15 分钟。需要确认正确的跳转 URL（Google AI Studio 个人用户 vs Cloud Console 企业用户）。

---

## 任务 D：跨 provider 切换（**结论：不做**，~0）

### 用户诉求

「Claude 额度用完了，能不能切到 Gemini 继续聊？」

### 技术答案

不行。具体：

1. daemon 每个 agent 在 createAgent 时绑定 provider，**没有 `set_agent_provider_request`**——只有 `set_agent_model_request`（同 provider 内换 model）
2. ACP session id 跟 Gemini 子进程 1:1 绑定，强行切换会丢上下文
3. 上下文跨 provider 迁移在协议层没设计

### 妥协方案：「Resume in another provider」快捷动作

在会话的 toolbar / context menu 加一个「Continue in Gemini」按钮：

1. 拿当前会话最后 N 条用户消息（或全部 timeline 摘要）
2. 用同 cwd + 选好的 provider 新建会话
3. 把那些消息**预填**到新会话的 composer，不自动发送（让用户决定要不要修改 / 发哪一段）

**优点**：保持 daemon 协议契约不变，跨 provider 的「续聊」从产品层实现。
**缺点**：上下文不是真的延续，只是把摘要塞回去；新会话从零开始。

### 推荐

不做（短期）。等任务 A + B + C 落地、用户实际使用上发现「老想换 provider」的频率上来再考虑。

---

## 实施顺序

按价值 / 工作量比排：

1. **任务 A**（侧边栏 provider 图标）—— 30 min，提升瞬间识别
2. **任务 B**（Gemini bubble 上 model chip）—— 30 min，对称 Claude，UI 一致性
3. **任务 C 方案 3**（Gemini 额度跳转按钮）—— 15 min，比没有强

任务 D 先按下不做。

合计 75 分钟，单一发布 v0.2.50。

---

## 发布版本

v0.2.50 / build 51。这次没有协议层改动，只有 UI 装饰 + 一个外链。回归风险极低。
