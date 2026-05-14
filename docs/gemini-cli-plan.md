# Gemini CLI 支持改造计划

## 目标

让 PaseoMac 在「新建会话」流程里能选 Gemini CLI 作为 provider，效果跟 Claude / Codex 等并列。

## 进度更新（2026-05-14）

✅ **daemon 端 + Gemini CLI + OAuth 全部已验证可用**，用户确认上游 paseo Electron 客户端能正常使用 gemini provider。

由此可以**完全跳过**：
- 任务 6（鉴权 UI / 错误传达）
- 验证步骤 1（VPS 上手测 `gemini auth`）
- 风险列表里的 OAuth 项

剩余工作量收窄到客户端两处修改，预估 30 分钟。

## 架构背景（供后来者了解，可跳过）

PaseoMac 是 paseo daemon 的客户端。**provider 管理逻辑全在 daemon 端**，客户端只负责：

1. 调 `get_providers_snapshot_request` 拿一次 provider 清单
2. 监听 `providers_snapshot_update` push 事件做后续同步
3. 渲染选择器，把用户选的 provider id 通过 `create_agent_request.config.provider` 字段回传

上游 paseo 把 provider 分两类：

| 类型 | 例子 | 实现方式 |
|---|---|---|
| **Native** | `claude`, `codex`, `opencode`, `copilot`, `pi` | 内置到 daemon 二进制，硬编码 |
| **ACP（用户配置）** | `gemini`, `cline`, `auggie`, `cursor`, ... | `~/.paseo/config.json` 里配 `extends: "acp"` + `command`，daemon spawn 子进程经 Agent Client Protocol stdin/stdout JSON-RPC 通信 |

VPS 的 `~/.paseo/config.json`：

```json
"gemini": {
  "extends": "acp",
  "command": ["npx", "-y", "@google/gemini-cli@0.41.1", "--acp"]
}
```

## 客户端要改的两件事

### 任务 1：修默认 provider 名（1 行 × 2 处）

`Sources/PaseoMac/ViewModels/AppViewModel.swift`：

```diff
@@ line 52
-    var pendingNewAgentProvider: String = "anthropic"
+    var pendingNewAgentProvider: String = "claude"

@@ line 317（createAgent 方法里）
-        pendingNewAgentProvider = agent?.provider ?? "anthropic"
+        pendingNewAgentProvider = agent?.provider ?? "claude"
```

**Why**：上游 `AGENT_PROVIDER_DEFINITIONS` 里 native provider id 是 `"claude"`，没有 `"anthropic"`。当前 client 传 `"anthropic"` 给 daemon 会得到 "Unknown agent provider" 错误。

### 任务 2：处理 `providers_snapshot_update` push 事件

**Why**：daemon 端每隔几秒就 push 一次 `providers_snapshot_update`，承载 ACP provider 的 status 变化（loading → ready → error）。PaseoMac 现在只在 `connect()` 时拉一次 snapshot 之后就再也不更新——如果 gemini 在 daemon 启动初期还在 loading，client 永远看不到它转 ready，picker 里就显示不了。

#### 改动详情

**a. `Sources/PaseoMac/Network/Protocol.swift`**

在 `SessionInbound` 枚举里加 case（约 line 346）：

```diff
     case getProvidersSnapshotResponse(GetProvidersSnapshotResponse)
+    case providersSnapshotUpdate(ProvidersSnapshotUpdatePayload)
     case cancelAgentResponse(CancelAgentResponse)
```

`init(from decoder:)` 的 switch 里加分支（约 line 378）：

```diff
         case "get_providers_snapshot_response":
             self = .getProvidersSnapshotResponse(try JSONDecoder.paseo.decode(GetProvidersSnapshotResponse.self, from: raw))
+        case "providers_snapshot_update":
+            self = .providersSnapshotUpdate(try JSONDecoder.paseo.decode(ProvidersSnapshotUpdatePayload.self, from: raw))
         case "cancel_agent_response":
```

新增 payload struct（紧挨 `GetProvidersSnapshotResponse` 后面）：

```swift
/// Server-initiated push: daemon notifies us when provider statuses change
/// (e.g. an ACP-extended provider finishes booting and turns ready).
struct ProvidersSnapshotUpdatePayload: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let entries: [ProviderSnapshot]
        let generatedAt: String?
        let cwd: String?
    }
}
```

**b. `Sources/PaseoMac/ViewModels/AppViewModel.swift`**

`ingest(session:)` switch 里加分支（紧跟 `.serverInfo` 后面）：

```diff
         case .serverInfo(let info):
             daemonVersion = info.version
             daemonHostname = info.hostname
             versionMismatchDismissed = false
+        case .providersSnapshotUpdate(let msg):
+            providers = msg.payload.entries
         case .status, .fetchAgentsResponse, .fetchAgentTimelineResponse,
              .sendAgentMessageResponse, .setAgentModeResponse, .setAgentModelResponse,
              .setAgentThinkingResponse, .getProvidersSnapshotResponse, .cancelAgentResponse,
              .unknown:
             break
```

**c. DaemonClient.swift 不用动**：dispatch 里 `requestId == nil` 的事件自动走 `eventContinuation.yield(session)`，到 `ingest()`。

### 待测：任务 4（ACP provider 的 model / mode 空数组兜底）

Gemini ACP 经实测 `ProviderSnapshot.models` 可能是 `nil` 或 `[]`，`modes` 也可能动态化（ACP 在 `session/new` 后才上报）。

PaseoMac 现有的 `PendingModelPicker` 和 `PendingModePicker`：

- `ComposerView.swift:589` `availableModels` 走 `.models ?? []`，空列表时 picker 应当不渲染（待测确认）
- `ComposerView.swift:630` `availableModes` 类似

任务 1 + 2 做完先测一遍。若发现 picker 渲染空菜单 / 崩溃，再补这条。

## 验证步骤

1. 改完 build deploy v0.2.48
2. 重启 PaseoMac
3. 在 sidebar 「New Agent」popover 里选个目录，开始新建会话
4. **composer 顶部 chip 区**应当能看到 provider 选择菜单——里面除了 `Claude` 还有 `Gemini CLI`（label 由 daemon 的 config 决定）
5. 切到 Gemini，输入一句简单 prompt，回车
6. 期待：会话能起来，daemon spawn 子进程，几秒后流回 Gemini 的响应

任一步失败的应对：

- 步骤 4 看不到 Gemini → 开 `~/Library/Logs/PaseoMac/paseomac.log` 看实际 providers 列表（如果 EventLogger 没记，需要临时加一行 `EventLogger.shared.log("providers", "snapshot", ["count": providers.count, "ids": providers.map(\.provider)])`）
- 步骤 5 picker 里 model / mode 菜单异常 → 任务 4
- 步骤 6 起会话失败 → 看 daemon 日志找 spawn 错误

## 改动文件清单

| 文件 | 改动 |
|---|---|
| `Sources/PaseoMac/ViewModels/AppViewModel.swift` | 2 处 `"anthropic"` → `"claude"`；ingest() 加 1 case 处理 push 事件 |
| `Sources/PaseoMac/Network/Protocol.swift` | SessionInbound 枚举加 case；decoder switch 加分支；新增 `ProvidersSnapshotUpdatePayload` struct |

约 25 行净增。无新依赖，无外部 SwiftPM 包变动。

## 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| `providers_snapshot_update` payload schema 跟 `get_providers_snapshot_response` 不完全一致 | decode 失败，新 push 事件被忽略 | 客户端宽松解码（用 `?` 允许 generatedAt / cwd 缺失）；首次启动 fetch 仍然能用 |
| `pendingNewAgentProvider = "claude"` 的修改影响**已存在的旧用户**：UserDefaults 没存 provider，agent 关联记录跟新默认值不一致 | 不影响——agent 记录里的 provider 是创建时写死的，default 只影响 NEW agent | 无 |
| Gemini 子进程冷启动慢（npx 拉包） | 第一次新建 Gemini 会话要等 10-30s | 已有 `creatingAgentText` 显示 "Starting agent…" 占位 |

## 发布版本

v0.2.48 / build 49。变更最小，单一目标。
