# Gemini CLI 支持改造计划

## 目标

让 PaseoMac 在「新建会话」流程里能选 Gemini CLI 作为 provider，效果跟 Claude / Codex 等并列。

## 架构背景（上游怎么做的）

PaseoMac 是 paseo daemon 的客户端。**provider 实际管理逻辑全在 daemon 端**，客户端只负责：

1. 调 `get_providers_snapshot_request` 拿一次 provider 清单
2. 渲染选择器，把用户选的 provider id 通过 `create_agent_request.config.provider` 字段回传

上游 paseo 把 provider 分成两类：

| 类型 | 例子 | 实现方式 |
|---|---|---|
| **Native** | `claude`, `codex`, `opencode`, `copilot`, `pi` | 内置到 daemon 二进制里，硬编码 provider 定义 |
| **ACP**（用户配置） | `gemini`, `cline`, `auggie`, `cursor`, ... | 在 daemon `config.json` 里配 `extends: "acp"` + `command`，daemon spawn 子进程，用 Agent Client Protocol 通过 stdin/stdout JSON-RPC 通信 |

Gemini 走 ACP 路径——Google 的 `@google/gemini-cli` 自带 `--acp` flag，speak ACP，daemon 就能像调度 Claude SDK 那样调度它。

参考 `.vendor/paseo-upstream/packages/app/src/data/acp-provider-catalog.ts`：

```ts
{
  id: "gemini",
  title: "Gemini CLI",
  description: "Google's official CLI for Gemini",
  version: "0.41.1",
  command: ["npx", "-y", "@google/gemini-cli@0.41.1", "--acp"],
}
```

## 当前 VPS daemon 状态

**daemon 端已经配好了**。`~/.paseo/config.json`：

```json
"gemini": {
  "extends": "acp",
  "label": "Gemini CLI",
  "command": ["npx", "-y", "@google/gemini-cli@0.41.1", "--acp"]
}
```

并且 gemini CLI 已经装到 `/home/ubuntu/.npm-global/bin/gemini`。

也就是说：**daemon 已经能 spawn Gemini**，只要 client 让用户选到 gemini 这个 provider 并把它传给 `create_agent_request`，就能跑起来。

## 当前 PaseoMac 状态

代码里已经有 provider 选择基础设施：

| 文件 | 现状 |
|---|---|
| `Network/Protocol.swift` | `ProviderSnapshot { provider, status, models?, modes?, label?, defaultModeId? }` 结构定义完整 |
| `Network/DaemonClient.swift:430` | `getProvidersSnapshot()` RPC 实现完整 |
| `ViewModels/AppViewModel.swift:89, 213-216` | `providers: [ProviderSnapshot]` 状态 + 连接后 fetch 一次 |
| `Views/ComposerView.swift:530-562` | `PendingProviderPicker` 渲染 `app.providers.filter { $0.status == "ready" }`，count > 1 时显示菜单 |

理论上 daemon 返回 gemini，picker 就应该能看到。**但用户实际看不到**，需要排查到底卡哪了。

## 怀疑的 4 个问题

### 1. 默认 provider 名字错了（确定）

`AppViewModel.swift:52, 317`：

```swift
var pendingNewAgentProvider: String = "anthropic"   // ← 上游用 "claude"，不是 "anthropic"
pendingNewAgentProvider = agent?.provider ?? "anthropic"
```

上游 `AGENT_PROVIDER_DEFINITIONS` 里 id 是 `"claude"`、`"codex"`、`"opencode"`、`"copilot"`、`"pi"`、`"gemini"`，**没有 "anthropic"**。

后果：第一次新建会话时 `provider = "anthropic"` 传过去，daemon 找不到，回错。即便能跑起来，picker 也匹配不上 ready 列表里的任何一个，UI 会显示一个"幽灵"默认值。

### 2. picker 显示条件可能太严苛（待确认）

`ComposerView.swift:535`：

```swift
let ready = app.providers.filter { $0.status == "ready" }
if ready.count > 1 {
    Menu { ... }
}
```

如果用户只配了 1 个 ready provider（极端情况），菜单根本不显示。但用户至少有 claude + gemini 两个，所以应该 > 1，能显示。**待测**。

### 3. `providers_snapshot_update` push event 没处理（确定）

daemon 端会推送实时变更（ACP 子进程启停、`gemini auth` 状态变更等）：

```
"outboundSessionMessageTypesTop":[..., ["providers_snapshot_update", 8], ...]
```

PaseoMac 只在 `connect()` 时调一次 `getProvidersSnapshot()`，**之后所有 push update 都丢了**。

如果 daemon 启动初期 gemini 还在 spawn 中（status: "loading"），首次 fetch 时 gemini 就是 loading。后续转 ready 的 update 没人收，picker 永远以为 gemini 没准备好。

### 4. ACP 提供商的 model/mode 字段可能是空（待确认）

`PendingModelPicker`、`PendingModePicker` 依赖 `ProviderSnapshot.models` 和 `.modes`。Gemini 经 ACP 通信，**模型固定**（就是 gemini 自己），**模式动态**（ACP 会话启动后才知道）。

`ProviderSnapshot.models` 大概率是 `[]` 或 `nil`，PaseoMac 现在的渲染逻辑要能正确处理这种情况（不崩、不显示空菜单）。

## 改造任务清单

按风险从低到高排：

### 任务 1：修默认 provider 名（必须，1 行改动）

```swift
// AppViewModel.swift:52
var pendingNewAgentProvider: String = "claude"   // 原来是 "anthropic"
// AppViewModel.swift:317
pendingNewAgentProvider = agent?.provider ?? "claude"
```

### 任务 2：处理 `providers_snapshot_update` push 事件（必须）

`Protocol.swift` 加新的 inbound case：

```swift
case .providersSnapshotUpdate(let payload):
    // 直接覆盖 app.providers
```

加 decoder 入口、`AppViewModel.ingest()` 里加分支处理。

### 任务 3：picker 显示条件松绑

如果只有 1 个 ready provider 也应该能看到（虽然没法切换，但让用户确认当前在用什么）。或者保留 > 1 才显示。**等任务 2 做完再决定**——可能只是初期 gemini 没 ready，看到的就是 claude-only。

### 任务 4：ACP provider 的 model / mode 兜底渲染

`ComposerView.swift` 的 `PendingModelPicker` 和 `PendingModePicker` 在 `models == nil || models.isEmpty` 时静默隐藏，不要崩，不要显示空菜单。**需要看一下现在是怎么处理的**，如果已经容错过就跳过这条。

### 任务 5：provider 图标（可选）

上游有 `acp-provider-icons.ts`，给每个 ACP provider 一个 SVG。Mac 端可以：

- 简单：picker 里只用文字 label
- 进阶：内置常见 provider 的 SF Symbol 映射（gemini = `sparkles`、claude = `c.circle`、codex = `terminal` 之类）

第一版不做。

### 任务 6：Gemini 鉴权失败时的错误传达（待调研）

Gemini CLI 第一次跑要 `gemini auth`（Google OAuth 浏览器流程）。daemon 跑在 VPS 上无头环境，可能出错。需要测：

- daemon 怎么处理这种情况？是否在 `provider.status` 里报 `"error"` 带 message？
- PaseoMac 在 picker 里看到 error provider 时怎么显示？现在是 `filter { status == "ready" }` 直接过滤掉，用户看不到 error。

可能需要：picker 把 error provider 也展示出来，置灰 + tooltip 显示错误原因。

## 验证步骤

1. 修任务 1 + 2，build deploy
2. 重启 PaseoMac，开 Xcode Debug Console 看 `getProvidersSnapshot` 返回内容里有没有 gemini，status 是什么
3. 如果 gemini 在列表且 ready，picker 应该能切到它
4. 切到 gemini，新建一个会话，看 daemon 端能不能正确 spawn 子进程
5. 跑一条简单 prompt，看响应能流回来

任一步失败时的 fallback：

- step 2 没看到 gemini → 升级 daemon 版本；或检查 daemon 日志里 gemini 启动报错
- step 3 picker 没出现 → 看任务 2 的 push event 处理
- step 4 spawn 失败 → 大概率是 OAuth 问题（任务 6）
- step 5 响应有问题 → ACP 协议级别的差异，深入排查

## 风险与未知

| 风险 | 影响 | 缓解 |
|---|---|---|
| Gemini OAuth 在 VPS 无头环境跑不起来 | gemini 不能用 | 需要先在 VPS 命令行手工 `gemini auth` 完成一次，之后凭据缓存到 `~/.gemini/` |
| ACP 协议的 timeline 事件结构跟 native Claude 不同 | timeline 渲染不全 | daemon 端会做协议适配，前端不感知；但有可能漏字段 |
| 现有 PaseoMac 写死的 mode id（如 `"bypassPermissions"`）在 Gemini 上不存在 | 默认 mode 不对 | picker 让用户从 provider 自己声明的 modes 选 |
| 一个会话从 Claude 切到 Gemini 不是同一 conversation | 用户语义混淆 | 让创建新会话来切换，不允许 in-place 切 provider |

## 工作量估计

任务 1：5 分钟  
任务 2：30 分钟（协议层 + ingest 分支）  
任务 3、4：测出来再决定，预计各 15 分钟  
任务 5（图标）：跳过  
任务 6（鉴权 UI）：30 分钟，看任务 4 后是否真的需要

总计 1-1.5 小时，**前提是 daemon 端 gemini 已经能正常 spawn**——这点先在 VPS 上手测一下 `gemini auth` 流程能不能完成。

## 下一步

1. 在 VPS 上执行一次 `gemini auth`，确认 Google OAuth 能完成（必要时用本地浏览器走 redirect 拿 token 再粘回去）
2. 重启 paseo daemon，看 `~/.paseo/daemon.log` 里 gemini provider 的初始化日志
3. 等 gemini 在 daemon 端是 `ready` 状态后，回来做客户端这边的任务 1 + 2
