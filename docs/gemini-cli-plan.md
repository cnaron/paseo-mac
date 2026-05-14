# Gemini CLI 支持改造计划

> **状态：✅ 已完成（v0.2.49，2026-05-14）**
>
> 实际根因和文中预先列出的「怀疑点」都不沾边——是 hello 消息里 appVersion 串太古怪，被 daemon 当成 legacy 客户端，gemini 在响应里直接被过滤。完整复盘见文末 [复盘 Postmortem](#复盘-postmortem) 一节。

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

---

## 复盘 Postmortem

### 实际症状

- 客户端 v0.2.48 部署后，新建会话 picker 里只能看到 Claude，**没有 Gemini**
- 但**官方 paseo Electron / 手机版能正常用 Gemini**——证明 daemon 端一切正常
- 我们这边的 picker / push event handler / 默认 provider 名都改对了，但 client 收到的 provider 列表里**根本没有 gemini**

### 根因

daemon 在 `session.ts` 里有一个版本门控：

```ts
const LEGACY_PROVIDER_IDS = new Set(["claude", "codex", "opencode"]);
const MIN_VERSION_ALL_PROVIDERS = "0.1.45";

private isProviderVisibleToClient(provider: string): boolean {
  if (clientSupportsAllProviders(this.appVersion)) return true;
  return LEGACY_PROVIDER_IDS.has(provider);   // 老客户端只能看到 3 个
}
```

`this.appVersion` 来自 client hello 消息里的 `appVersion` 字段。PaseoMac 自创建以来一直硬编码：

```swift
let hello = HelloMessage(
    ...,
    appVersion: "PaseoMac/0.0.1",   // ← 罪魁
    capabilities: nil
)
```

daemon 比较 semver 用的是 `isAppVersionAtLeast`：

```ts
const parts = base.split(".").map(Number);   // ← .map(Number)
```

`Number("PaseoMac/0")` 等于 `NaN`，比较里既不 `>` 也不 `<`，循环走到第二位 `0 < 1`，返回 `false`。结果：PaseoMac 永远被判 < 0.1.45，gemini / copilot / 所有 ACP provider 在 daemon 出门前就被剔除了。

### 修复

`DaemonClient.swift` 改一行，发纯 semver：

```diff
-appVersion: "PaseoMac/0.0.1",
+appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.48",
```

部署 v0.2.49 后立刻看到 Gemini 进 picker。

### 为什么之前的 plan 完全没指向这里？

写 plan 时全在看客户端代码（picker 逻辑、push event 解码、provider 名）。**没有去读 daemon 在 hello 处理那一段的代码**——因为预设是「上游能用 = daemon 是正确的，我们 client 只是缺功能」。

但「上游能用」≠「daemon 对所有 client 都一样对待」——daemon 会**按 hello 上报的版本号给客户端做能力分层**，老客户端被悄悄降级。

### 教训

1. **遇到「数据少了」类问题，先核对 hello / 握手阶段**：daemon 可能根据 client 自报版本给出不同响应。开 `PASEO_DEBUG_WS=1` 跑一遍 RPC 抓 wire 数据是最直接的验证。
2. **任何写死的版本号都是 future bug**：`"PaseoMac/0.0.1"` 创建以来从没改过，0.2.x 的实际版本与之早就脱节。改成读 `CFBundleShortVersionString`，将来 plist 升一版自动同步。
3. **协议契约要追到源头**：上游 paseo 在 `messages.ts` / `session.ts` 里散落了若干 `isAppVersionAtLeast` 调用（providers、editors、CSS feature flag 等），每条都是潜在的版本陷阱。可以做一份「客户端 hello 应满足的 minVersion 检查清单」存档。

### 涉及的 commit / tag

| 版本 | 内容 |
|---|---|
| v0.2.48 (commit `9aa205e`) | 第一次实现 plan（picker UI + push event 解码 + 默认名修正）。看起来没用，但其实补齐了之后真正出 Gemini 必需的客户端代码 |
| v0.2.49 (commit `e5e5373`) | 真正修复——hello 的 appVersion 改为 semver |

回头看 v0.2.48 不算白费——是必要的客户端基础设施。但**仅靠它本身**用户看不到任何变化。
