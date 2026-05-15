# PaseoMac 不稳定问题调研 — 2026-05-15

## 用户报告的症状

- 新建 agent / 对话后 PaseoMac 卡死，需要 force quit
- 单个 session 也会卡死（不光是新建时）
- 会话页面经常无故刷新，滚动位置错乱
- 偶尔出现空白
- 整体感觉比官方 Electron Paseo 不稳

## 环境

- App: PaseoMac SwiftUI client, v0.2.50 build 51
- 项目路径: `/Users/naron/Public/Project/paseo-mac/` (Air)
- Daemon: VPS-hosted paseo daemon
  - serverId: `srv__Yv3Gl2R4CVt`
  - VPS 上 node pid 61862, 监听 127.0.0.1:6767
- 客户端连接模式: `.relay` via `wss://relay.cnaron.com:443`
- 系统代理 (Air): Surge listen `*:6152`, URLSession 走系统代理 → wss 经 Surge 中转

## 调研时间线（精简）

### Phase 1 — 错误的初始假设

观察到 PaseoMac 日志反复 `connect_start → connected → disconnected_unexpected (secondsAlive=1) → reconnect_scheduled` 循环。

**初始假设**：两个客户端（Electron Paseo + PaseoMac）连同一本地 daemon 互踢。

用户手动退掉 Electron Paseo → 抖动**未停** → 假设错误，需要重新追踪。

### Phase 2 — 真实连接路径

- `lsof -p $(pgrep PaseoMac)` 显示连接目标 `127.0.0.1:6152`
- 6152 端口主人是 **Surge**（代理），不是 daemon
- 源码 `Sources/PaseoMac/Network/DaemonClient.swift:7-10` 定义 `.relay` 模式连远端 wss
- `defaults read sh.paseo.mac.client` 里 `paseomac.connectionOfferRaw` base64 解码出：
  ```json
  {
    "v": 2,
    "serverId": "srv__Yv3Gl2R4CVt",
    "daemonPublicKeyB64": "coHaCik8LeEYy81MPZfWqYcKkLx0I6n2fZBbx8UWuGk=",
    "relay": { "endpoint": "relay.cnaron.com:443" }
  }
  ```

**完整链路**：
```
PaseoMac (Air)
  → URLSession (系统代理) → Surge :6152
  → wss://relay.cnaron.com:443
  → VPS paseo daemon (srv__Yv3Gl2R4CVt, 127.0.0.1:6767)
```

### Phase 3 — VPS daemon 端分析

- `ssh cc cat ~/.paseo/server-id` = `srv__Yv3Gl2R4CVt`（匹配）
- daemon 日志 `~/.paseo/daemon.log` 显示：
  - **每次 disconnect 都是 `code: 1001 "Client disconnected"`** → **客户端主动断**，不是 daemon 踢
  - 断开前都有 `ws_slow_request` 警告：`fetch_agents_request` 耗时 600–3000ms
  - daemon 自身状态健康：`activeConnections: 2, externalSessionKeys: 3, agents.total: 27`
  - relay 路径 504 条 slow_request vs direct 路径 25 条 → relay 固有延迟约高 20×
- Electron Paseo 客户端 (`cid_673bd...`) 也走 relay，但**不抖**

**结论**：双客户端假设错误。真凶在 PaseoMac 客户端代码层 — 它对 relay 慢响应不耐受，主动关 socket。

### Phase 4 — 代码层根因（Explore agent 审计）

详见 `Sources/PaseoMac/Network/DaemonClient.swift` 和 `Sources/PaseoMac/ViewModels/AppViewModel.swift`。

## 根因总结

### Symptom A — 连接每秒抖

**直接原因**：客户端 35s keepalive 在某条路径下被错误触发，主动 `close(1001 goingAway)`。

注意：**1 秒抖动频率与 35s keepalive 数学对不上** —— 一定还有第二条 close 路径（最可能在 `RelayChannel` 错误分支、`ingest()` 异常被吞、或某个状态机 bug 里）。但 Fix #1/#2 落地后这条路径很可能不再被触发，先做完再看是否残留。

### Symptom B — 单 session 卡死、UI 冻

**直接原因**：`DaemonClient.swift:465-475` `requestResponse()` 用 `withCheckedThrowingContinuation` 等响应，但**没有 per-RPC timeout**。relay 慢 RPC 让 `@MainActor` 上的 `try await` 挂死 → UI 冻直到 35s keepalive 强断为止。

### Symptom C — 会话页面无故刷新、滚动错乱、空白

**是 Symptom A 的下游连锁反应**：

```
relay 慢响应 → 客户端主动 close(1001) → reconnect
  → connect() 跑 refreshAgents() → agents 数组整个被新结果替换
  → @Observable 通知所有依赖 agents 的 View 失效
  → ConversationView re-init → @State 重置 → ScrollView 滚动位置丢失
  → fetchTimeline 还没回来的几百毫秒 → 显示空白 empty state
  → timeline 数据到达 → 列表重建，位置错乱
```

每秒抖一次 = 每秒经历一次上面整套流程。

### 为什么 Electron 走同样 relay 不抖

- JS 单线程 + 微任务事件循环：`await` 不阻塞 UI 渲染线程，慢 RPC 顶多让数据晚到
- Swift `@MainActor await` 是真把主线程隔离挂住，一旦慢就感知成"卡死"
- 官方 Electron Paseo 有大量真实用户帮打磨 corner case；PaseoMac 是新写的、第一轮，相同 bug 没被磨过

**这不是 SwiftUI 的根本问题，是 PaseoMac 这份实现的具体 bug。**

## 高优先级修复方案

### Fix #1 — `requestResponse()` 加 per-RPC timeout（核心修复）

- **File:** `Sources/PaseoMac/Network/DaemonClient.swift:465-475`
- **改动**：把 `withCheckedThrowingContinuation` 包在一个超时竞赛里，10–15s 内没等到响应则通过 `failPending(requestId:, error: .rpcTimeout)` 失败单个请求。**不要因为 timeout 关 socket，只失败那一个 continuation。**
- **意义**：让单个慢 RPC 失败掉，不要拖整个 socket / `@MainActor`。**直接解决 Symptom B**。
- **风险**：低。当前完全没超时机制，加上严格更好。timeout 值可调。

### Fix #2 — `refreshAgents()` 移出 connect 关键路径

- **File:** `Sources/PaseoMac/ViewModels/AppViewModel.swift:185`
- **改动**：把 `try await refreshAgents()` 改成 detached:
  ```swift
  Task { try? await self.refreshAgents() }
  ```
- **意义**：握手一完成就 `connectionState = .connected`，agents 列表后台慢慢填。首连 / 重连不再阻塞 UI。**Symptom A 的"重连即冻" + Symptom C 的级联刷新都会显著缓解。**
- **风险**：低。Agents 列表晚到几秒是符合慢网络预期的行为。

### Fix #3 — `pongDeadline` 调到 50–60s（配合 #1）

- **File:** `Sources/PaseoMac/Network/DaemonClient.swift:77`（值），`:168`（tickKeepalive 处）
- **改动**：`pongDeadline = 50`（或 60）。可选进阶：跟 pending RPC 数挂钩，有 RPC 在飞就不算 silent。
- **意义**：让 #1 的 per-RPC timeout 先生效，keepalive 只判定真死。
- **风险**：低，纯调参。

## 验证计划

1. 改完 #1 #2 #3 后在 Air 上编译：
   ```bash
   ssh air "cd ~/Public/Project/paseo-mac && swift build -c release"
   ```
2. **先不部署到 /Applications**。让用户手动跑：
   ```bash
   ~/Public/Project/paseo-mac/.build/release/PaseoMac
   ```
3. 同时盯日志：
   ```bash
   tail -f ~/Library/Logs/PaseoMac/paseomac.log
   ```
4. **验收标准**：
   - 连续 60 秒内无 `disconnected_unexpected` 事件
   - 新建 agent / 新建对话不冻 UI
   - 会话页面不再无故刷新、不再丢滚动位置
5. 验收通过后再走 PaseoMac CLAUDE.md 里"Release 打包完整流程"（更新版本号、replace binary、签名、部署到 `/Applications/PaseoMac.app`、tag、push）

## 如果修完症状仍残留

- **会话刷新 / 位置错乱仍存在** → SwiftUI view 层独立 bug，查：
  - `Sources/PaseoMac/Views/ConversationView*.swift` 里 list row 的 `.id(...)` 是否稳定（不要用 array index）
  - ScrollView 有没有 `.scrollPosition(id: ...)` 保存
  - timeline 数组是不是每次 fetch 都全量替换（应该 merge / diff，保留稳定 id）
- **个别 RPC 仍卡** → 在 #1 的 timeout fire 时记录 requestId 类型，看是哪类请求 chronically 慢；可能要 daemon 侧加索引或缩减 timeline 加载窗口。
- **每秒抖动仍存在** → 去找前面提到的"第二条 close 路径"：`RelayChannel.swift` 错误分支、`AppViewModel.swift ingest()` 异常吞掉、状态机 bug。

## 参考命令（调研中用过）

```bash
# PaseoMac 实际网络目标
ssh air 'lsof -nP -p $(pgrep -f PaseoMac) | grep TCP'

# PaseoMac 存储的 ConnectionOffer
ssh air 'defaults read sh.paseo.mac.client | grep -E "connectionOffer|clientId|lastSelected"'

# VPS daemon 状态
ssh cc 'cat ~/.paseo/server-id; pgrep -lf paseo; tail -50 ~/.paseo/daemon.log'

# Daemon log 里的 client-side close 事件
ssh cc 'grep "Client disconnected" ~/.paseo/daemon.log | tail'

# 关键源码位置一览
ssh air 'grep -nE "requestResponse|pongDeadline|forceCloseDueToKeepalive|handshakeTimeout" \
  ~/Public/Project/paseo-mac/Sources/PaseoMac/Network/DaemonClient.swift'
```

## 本次调研未做的修改

无。纯静态分析 + 日志观察，未改任何源码、未部署任何二进制。
