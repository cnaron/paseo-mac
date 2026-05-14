# PaseoMac Session Log

跨会话续接用的工作日志。每次 Claude Code 协作后追加一节，记录：
- 改动了什么、为什么
- 参考的上游版本（paseo Electron、Claude Code）
- 当前已实现功能清单
- 还没做但讨论过的 backlog

下次会话开始时先读这份，能快速恢复上下文。

---

## 项目速览

- **PaseoMac** = SwiftUI macOS 客户端，连接 paseo daemon 管理 Claude Code agent 会话
- **上游 paseo (Electron)**：`getpaseo/paseo` GitHub 仓库，桌面端
  - 装在 `/Applications/Paseo.app`，发布周期密集（每隔 1-3 天一个版本）
  - mac 客户端的设计哲学是「跟 daemon 解耦，daemon 升级 mac 自动受益」
- **路径**：`/Users/naron/Public/Project/paseo-mac/` (Air)
- **构建**：`swift build -c release` → 替换 `build/PaseoMac.app/Contents/MacOS/PaseoMac` → ad-hoc 签名 → 拷到 `/Applications/PaseoMac.app`
- **GitHub**：`git@github.com:cnaron/paseo-mac.git`，tag 格式 `v0.x.x`

完整构建/打包流程见根目录的 `CLAUDE.md`（注意 `CLAUDE.md` 在 `.gitignore` 里，不入库）。

---

## 已实现功能清单（截至 v0.2.29）

### 连接 / 会话管理
- 通过 pairing offer URL 连接 daemon（首次填一次后持久化）
- 自动重连：1s → 3s → 9s → 27s → 30s 上限退避
- 系统从睡眠唤醒后自动重连
- 多 agent 会话切换，sidebar 显示状态/标题/cwd
- 归档 (archive) / 取消归档 / 显示已归档列表（sidebar 切换）
- 归档会话支持 Resume（继续同一 conversation）
- 重启/重连时不丢已缓存历史，可离线翻阅

### 会话内交互
- 新建会话 composer：选 provider / model / mode
- 发送消息（文本 + 图片 + 文本附件作为 fenced code）
- 流式接收 stream events：assistant 消息、tool calls、reasoning、permissions、attention
- 队列：agent 在跑时连续输入会排队，turn 完成后依次 dispatch
- 发送中的乐观渲染（local user row）
- 编辑队列里待发的消息（editQueued / removeQueued）
- 中断当前 turn（stop button）
- Permission 请求 inline 批准/拒绝
- Agent model / mode / thinking effort 切换器（toolbar）

### 渲染
- Markdown 渲染（`MarkdownRender.swift`），含代码高亮
- Tool detail 三种风格：plain / before-after / unified diff
- 可展开/折叠的 tool detail
- 长 user 消息自动折叠 + Show more
- 用户附图 thumbnail + 点击放大
- Search 消息内容（cmd+F）
- defaultScrollAnchor(.bottom) + deferred scroll → 不闪屏

### 设置 / 杂项
- Claude usage quota 面板（5h / 7d / Sonnet / Opus，从 VPS proxy 拉）
- Claude stats 面板（每日 messages/sessions/tools，按模型 token 量、成本估算）
- Claude Code CLI 版本检查 + 一键升级（VPS 后端跑 `npm i -g`）
- Daemon version mismatch 警告（兼容 prefix 0.1.x）
- macOS 通知（permission 请求时）

---

## 2026-05-06 这次改动

### 1. 新会话发送后空白几秒的修复（v0.2.29）

**问题**：新建会话首次发送消息后，UI 空白 5-7 秒，用户怀疑消息丢失。

**根因**：`AppViewModel.submitPendingAgent` 调完 `createAgent` RPC 后，要等 stream event（5s 超时）或 polling fallback（6×300ms）才能拿到新 agent ID。这段时间 `selectedAgentId` 还是 `__pending__`，ConversationView 显示「Type a message」空状态，composer 也被清空了，体感像消息被吞了。

**修复方案**：
- `AppViewModel.swift`
  - 新增 `creatingAgentText: String?` + `creatingAgentImages: [PendingImageAttachment]` 状态
  - `submitPendingAgent` 入口处设置这俩状态，在拿到新 agent ID / 出错 / 超时时清除
  - stream timeout 5s → 3s，polling 6×300ms → 10×200ms（worst case 7s → 5s）
  - 图片路径下，先 `vm.injectOptimisticFirstMessage` 把 user bubble 写进新 conversation，再 `selectedAgentId = agentId`，避免切换瞬间空白
- `ConversationViewModel.swift`
  - 暴露 `injectOptimisticFirstMessage(text:messageId:images:)`（包了私有的 `appendLocalUserRow`）
- `ConversationView.swift`
  - `isPending && creatingAgentText != nil` 时渲染 `PendingCreatingView`（user bubble + "Starting agent…" spinner），代替原来的「Type a message」placeholder

**版本**：0.2.28 → 0.2.29，build 23 → 24。已编译、签名、部署到 `/Applications/PaseoMac.app`。**未 commit / 未 tag / 未 push**——等用户确认效果再走 release 流程。

### 3. 重连后最后一条消息被 composer 遮住（v0.2.30）

**问题**：用户报告自动重连之后拖到底部，最后一条消息不在 composer 上方（应该的位置），而是被 composer 遮住。

**根因**：`ConversationView.swift:448` 的 bottom breathing room 写死 210pt：
```swift
Color.clear.frame(height: searchText.isEmpty ? 210 : 24) // breathing room
```
但 ComposerView 实际高度变量化——尤其 **重连后** `app.providers` 才被拉回来，provider/model/mode 三组 picker chip 长出来，composer 加高超过 210pt。

**修复方案**：动态测量 composer 真实高度作为 breathing room。
- 新增 `ComposerHeightKey: PreferenceKey`（在 ConversationView.swift 末尾）
- ConversationView 加 `@State measuredComposerHeight: CGFloat = 210`
- composer 的 VStack 包一层 `.background(GeometryReader { ... preference(... gp.size.height + 16) })`
- `.onPreferenceChange(ComposerHeightKey.self)` 写回 measuredComposerHeight
- MessageList 加 `var bottomPadding: CGFloat = 210` 参数，breathing room 用该参数
- ConversationView 传 `bottomPadding: max(measuredComposerHeight, 210)` 给 MessageList

**版本**：0.2.29 → 0.2.30，build 24 → 25。已部署。

### 2. 上游 paseo changelog review（决定不抄）

参考：`getpaseo/paseo` 的 v0.1.65 → v0.1.69（2026-04-29 至 05-05）

- ❌ Daemon 自动恢复 / 内部进程崩溃恢复 / 交互问题 reply 修复 → daemon-side
- ❌ Agent init failure 30s vs 5min surfacing → daemon-side
- ❌ Streaming markdown 保留 trailing newline → daemon emits text
- ❌ Codex sub-agent 流式 → daemon-side
- ⚠️ Image 加载 spinner / "Image unavailable" fallback → 候选，目前 mac 还没渲染 assistant 附图
- ⚠️ Archive instant + rollback → 候选，mac 已经 optimistic remove，可以加 RPC 失败时回滚

绝大多数上游改动 mac 客户端会随 daemon 升级自动受益，**没有 Swift 侧需要做的事**。

---

## Backlog（讨论过但还没做）

| 项 | 来源 | 优先级 |
|---|---|---|
| Archive 失败时把 agent 恢复到列表（rollback） | 上游 paseo v0.1.67 | 低 |
| Assistant 消息里图片的 loading spinner / fallback | 上游 paseo v0.1.65-beta.4 | 低，等遇到再说 |
| 新建 agent 流程超时后给更明确的失败 UI（现在是悄悄回到 first agent） | 这次重构旁观察到 | 中 |
| ~~重连后滚动条/拖拽行为异常~~ | 用户 2026-05-06 报告 | ✅ 已修，v0.2.30 |

---

## 参考的 Claude Code 版本

- 当前安装：**2.1.129**（2026-05-06）
- 关键最近改进（影响 mac 客户端用户体验间接，daemon 跑 Claude Code）：
  - **1 小时 prompt cache TTL 被静默降级到 5 分钟 — 已修**（2.1.129）：长会话 cache hit 率回升
  - OAuth refresh 在 Mac 睡眠唤醒后会把所有会话登出 — 已修（2.1.129）
  - Stream idle timeout after Mac wake — 已修（2.1.126）
  - 当 cwd 被删/改名时 Bash tool 永久失效 — 已修（2.1.121）
  - 图片 session + `/usage` 内存泄漏 — 已修（2.1.121）
  - MCP `alwaysLoad: true` 选项（2.1.121）

完整 changelog：`https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`

---

## 开发约定（项目专属）

- 后缀规范：所有 Claude Code 协作产出的方法/字段加 `_claudecode_YYYYMMDD` 后缀（VPS 根 `CLAUDE.md` 有详述）
  - **paseo-mac 历史上没贯彻这个约定**——之前的 v0.2.x 系列改动都没加后缀
  - 新一轮加 backlog 性质的功能时，再讨论是否引入
- Commit message：`v0.x.x: 简短描述`
- 不通知 Apple、不走 notarize、ad-hoc 签名
- 一定要更新 `CLAUDE.md` 的「当前版本」段落（虽然这文件 .gitignore，但本地引用会用）

---

## 上次会话结束状态

- 工作树：3 个 .swift 文件 dirty（AppViewModel / ConversationViewModel / ConversationView）
- v0.2.29 已部署到 `/Applications/PaseoMac.app`，**未提交**
- `CLAUDE.md` 里「当前版本」段落已更新到 0.2.29 / build 24
- 等待用户验证修复效果（重启 app 试新会话发送流程）
- 验证 OK 后下一步：commit + tag + push 走 release 流程

下次会话开头建议先：

```bash
cd /Users/naron/Public/Project/paseo-mac
git status                # 看是否还有 dirty 改动
git log --oneline -10     # 看最新版本
plutil -p build/PaseoMac.app/Contents/Info.plist | grep BundleVer
```

如果工作树仍 dirty 且最新 commit 是 v0.2.28（16e65ba），说明 v0.2.29 还没走完 release，本档此节适用。如果已经在 v0.2.29 之后，从这节往下读再补充新工作。

---

## 2026-05-07 第二轮改动

### 4. 新会话 thinking effort 选择器（v0.2.31）

新建会话 composer 加 `PendingThinkingPicker`，让用户提交首条消息前就能选 thinking effort（None/Low/Medium/High/Max，由 daemon 通过 ModelDefinition.thinkingOptions 提供）。

实现：AppViewModel 加 `pendingNewAgentThinkingOptionId` 状态；submitPendingAgent 多了 `useTwoStepFlow = !images.isEmpty || thinkingOptionId != nil` 开关：用户选了 thinking 就走 createAgent（不带 prompt）→ setAgentThinking → sendMessage 三步，让首轮就用上选的 effort。CreateAgentRequest.Config 协议层不带 thinking 字段，所以必须客户端拼接。

### 5. nginx stream proxy_timeout 300s → 3600s（VPS）

`/etc/nginx/nginx.conf` 的 stream block 里把 `proxy_timeout 300s` 改成 `3600s`。之前每 5 分钟整 daemon 跟 relay 之间被 nginx 杀一次空闲 TCP，PaseoMac 客户端跟着掉线。改完后正常 idle 1h 内不会被杀。

### 6. Hung-turn 修复（v0.2.32）

用户报 "明明应该结束了但一直悬挂"。根因：daemon turn_completed 事件在断网瞬间丢了，paseo-mac 的 `isAgentWorking` 永远 true。

修复：ConversationViewModel 加 `reconcileAgentStatus(_:)`（status="idle" 且本地 isAgentWorking 时清 spinner、pin duration/model 到最后 assistant row）。AppViewModel 在两处调用：(a) ingest agent_status 事件实时对账；(b) connect() 重连后兜底对账。

### 7. ⚠️ 回归 bug — pending-VM 反复 fetchTimeline 把连接搞挂（v0.2.33）

**自己引入的**。v0.2.30 + v0.2.32 那两次 reconnect 循环 `for (agentId, vm) in conversations` 没排除 `__pending__` 这个占位 ID。ConversationView 渲染 pending 状态时调 `app.conversation(for: "__pending__")` 已经把伪 VM 插进了 conversations 字典。

重连时被当真 agent → `fetchTimeline(agentId: "__pending__")` → daemon `Agent not found` → WebSocket abnormal closure (1006) → 客户端自动重连 → 再来一遍 → **死循环 = 用户看到的"卡死"**。

修复（belt-and-suspenders）：
- `AppViewModel.connect()` reconnect 循环开头 `if agentId == AppViewModel.pendingAgentId { continue }`
- `ConversationViewModel.loadInitial()` 入口 `guard agentId != AppViewModel.pendingAgentId else { return }`

**教训**：以后任何对 `conversations` 字典批量操作（loop / map / forEach）都必须显式跳过 `pendingAgentId`。这是 paseo-mac 的隐藏 invariant，没有静态检查能抓住，只能靠纪律。

未来如果觉得 "pending VM 不该真的存在" 是更优的设计（pendingAgentId 就不该出现在 conversations 字典里），那是更大的重构，目前不做。

---

## 2026-05-13 收尾提交：把 v0.2.29 → v0.2.38 一次性 commit

距离上次提交（v0.2.28）已经迭代了 10 个 patch 版本，工作树一直 dirty 在跑。今天一次性 commit + tag v0.2.38 + push。

### 0.2.29 → 0.2.33 已在上一节记录，不重复。

### 0.2.34 → 0.2.38（实时未记，从 diff 反推，准确性低于 0.2.29-0.2.33）

#### 8. App-level keepalive ping（DaemonClient）

- 新 `PingMessage`：`{"type":"ping","requestId":..., "clientSentAt":<ms>}`，每 ~15s 发一次（对齐官方 paseo CLI）
- `sendKeepalivePing()` + `aliveDuration()`（actor 上算 lastInboundAt 距今秒数）
- 静默超阈值就主动 close socket 触发上层 reconnect，不等 OS TCP 超时（可能几分钟）
- WebSocket 控制帧 PING/PONG 在 relay/CDN 链路上不一定保留，所以走 app-level

#### 9. 持久化 client ID（AppViewModel）

- 新 `cid_paseomac_<uuid>` 写 UserDefaults，每个安装一次性生成
- 给 daemon 用做 `externalSessionsByKey` 的 key，重连不再每次开新 entry，可以 resume 同一个 session

#### 10. AskUserQuestion 内联 UI（重头戏）

Protocol 加：
- `PermissionRequestPayload`（解析 `permission_requested` 事件的 `request` 字段，`kind=="question"` 或 `name=="AskUserQuestion"` 时 `askUserQuestion` 非空）
- `AskUserQuestion` / `AskUserQuestion.Question` / `Option`（结构化问答 schema）
- `AskUserQuestionAnswers`（回包用，原问题 + 答案一起回，键名按 question.header）
- `AgentPermissionResponseRequest` / `Response`（`.allow(updatedInput:)` 带答案，普通 tool 权限传 `nil`；`.deny(message:)`）

ViewModel 加：
- `pendingPermission: PermissionRequestPayload?`
- `resolvedPermissionIds: Set<String>`（去重避免重发）
- `submitQuestionAnswers(_:)`（把 [header: label] 转成 `AskUserQuestionAnswers` 走 respondPermission）

View 加：
- `AskUserQuestionView`（多 question 的表单，每题渲染选项；多选/单选）
- `FlowLayout`（自定义 SwiftUI Layout，选项 chip 自动换行）

#### 11. Reconnect ±25% jitter

`applyJitter(_:)` 给退避延迟乘 `Double.random(in: 0.75...1.25)`，多客户端不同步抖动避免雪崩。

#### 12. EventLogger（JSONL 文件日志）

新文件 `Sources/PaseoMac/Logging.swift`：
- `~/Library/Logs/PaseoMac/paseomac.log`，单行 JSON，utility-QoS 串行 queue 写盘
- 5MB → 轮转到 `.log.1`，最多占 ~10MB
- 调用面：AppViewModel（conn / create_agent / turn / status）+ ConversationViewModel（send / turn）
- 用法：`ssh naron@100.112.136.122 'tail -f ~/Library/Logs/PaseoMac/paseomac.log'` 远程跟

#### 13. 几处重连 race 修复

- `connect()` 入口先 cancel 老的 event-listener Task，再 disconnect 老 client。否则老 `for await` 退出会触发 `handleUnexpectedDisconnect()`，跟新连接打架（"phantom reconnect"）
- 重建 transport 前显式 tear down 旧 WS task（不靠 ARC，daemon 侧能短暂看到俩 socket）
- 重连成功后 `clearConnectionError()` 清各 conversation VM 上残留的 "Daemon is not connected" 错误（之前是 sendMessage 跟掉线 race 后留下的）

#### 14. AgentSnapshot.merging(_:)

`agent_status` 事件的增量合并：non-nil 标量从 other 取，nil 回落到 receiver。避免 status update 把已知字段抹空。

#### 15. CreateAgentRequest.Config 加 thinking 字段

之前 thinking 走两步（create → set_agent_thinking），后者跟 turn 1 启动 race 出 daemon 错 `Cannot read properties of null (reading 'push')`。改成 createAgent 直接带 thinking 配置。

### 提交策略

单 commit `v0.2.38: ...`，tag v0.2.38，push origin main --tags。CLAUDE.md 同步更新到 0.2.38/39（gitignored，本地引用用）。


---

## 2026-05-13 第二轮：v0.2.39 修新会话首轮缺 model + duration chip

### 现象

用户问"为什么现在回应消息的时候没有出现模型和时长？"。确认是新建 agent 的 conversation 里所有回复都缺 TurnMetaChip（"Opus · 2m"），老 agent 正常。

### 根因

EventLogger 抓到关键时序证据：

```
01:26:06.219 create_agent request
01:26:06.634 turn:started (agent 5eb5e8e5...)
01:26:06.635 create_agent:detected (agent_status 到达，agents.insert 执行)
```

`turn_started` 比 `agent_status` 早 ~1ms。AppViewModel 处理 turn_started 时执行：

```swift
let currentModel = agents.first(where: { $0.id == agentId })?.model
```

此时新 agent 还没 insert 进 `agents[]`，`currentModel` = nil。`apply(streamEvent:.turnStarted, currentModel: nil)` 里 `if let m = currentModel { currentTurnModel = m }` guard 不进，整个 turn `currentTurnModel` 留 nil。

后果链：
- 所有 `assistantMessage` row 的 `modelUsed` 字段 = nil（line 619 `tagged: currentTurnModel`）
- `turn_completed` 里 `lastTurnModel = currentTurnModel ?? rows.last(where: { $0.modelUsed != nil })?.modelUsed` → 两边都 nil → lastTurnModel = nil
- stamp 块 `if rows[idx].modelUsed == nil, let m = lastTurnModel` → m 为 nil → 不 stamp
- 渲染 `if let model = group.modelUsed { TurnMetaChip(...) }` → group.modelUsed = nil → chip 不出

老 agent 没事是因为 `agents[].model` 在历史 agent_status 里早就 populate 过，merging() 路径 `model: other.model ?? model` 不会 blank，所以 currentModel 一直拿得到。

### 修复（v0.2.39）

ConversationViewModel 加 `seedTurnModel(_:)` —— 幂等 setter，仅当 `currentTurnModel == nil` 时填入。

AppViewModel 的 `agentStatus` handler 在 `agents.insert(snap, at: 0)` 后立刻调：

```swift
if let m = snap.model {
    conversations[snap.id]?.seedTurnModel(m)
}
```

VM 在哪一刻已经存在？turn_started 处理时通过 `conversation(for: agentId)` 创建过了（lazy 创建在 stream 事件分发里），所以 agent_status 处理时 `conversations[snap.id]` 可取到。

时序：seed 在 turn_started 之后 ~1ms，turn_completed 之前数十秒到几分钟。中间陆续到的 assistantMessage chunk 经 `appendStreamedRow` 的 coalescing（`rows[idx] = row` 整体替换）会带上 modelUsed=model；turn_completed 也能正常 stamp duration。

### 边角

- 用户没选模型（`pendingNewAgentModel` 为 nil，daemon 用 provider 默认）的情况下，daemon 第一次 agent_status 仍然会带 model（daemon 知道实际选了哪个），这条路径同样覆盖
- 极端 race：第一条 assistantMessage chunk 在 agent_status 之前就到（理论上可能但日志里没观察到），那条 chunk 的 row 仍然是 nil；但只要后续还有 chunk 到，coalescing 会把整个 row 覆盖成有 model 的版本
- 完全没有后续 chunk + turn_completed 也在 agent_status 之前到的情况下还是会缺；但实际 turn 一般持续秒级以上，agent_status 1ms 内就到，几乎不可能命中

### 版本

0.2.38 → 0.2.39，build 39 → 40。已部署 `/Applications/PaseoMac.app`。


---

## 2026-05-13 第二轮：v0.2.39 修新会话首轮缺 model + duration chip

### 现象

用户问"为什么现在回应消息的时候没有出现模型和时长？"。确认是新建 agent 的 conversation 里所有回复都缺 TurnMetaChip（"Opus · 2m"），老 agent 正常。

### 根因

EventLogger 抓到关键时序证据：

```
01:26:06.219 create_agent request
01:26:06.634 turn:started (agent 5eb5e8e5...)
01:26:06.635 create_agent:detected (agent_status 到达，agents.insert 执行)
```

`turn_started` 比 `agent_status` 早 ~1ms。AppViewModel 处理 turn_started 时执行：

```swift
let currentModel = agents.first(where: { $0.id == agentId })?.model
```

此时新 agent 还没 insert 进 `agents[]`，`currentModel` = nil。`apply(streamEvent:.turnStarted, currentModel: nil)` 里 `if let m = currentModel { currentTurnModel = m }` guard 不进，整个 turn `currentTurnModel` 留 nil。

后果链：
- 所有 `assistantMessage` row 的 `modelUsed` 字段 = nil（line 619 `tagged: currentTurnModel`）
- `turn_completed` 里 `lastTurnModel = currentTurnModel ?? rows.last(where: { $0.modelUsed != nil })?.modelUsed` → 两边都 nil → lastTurnModel = nil
- stamp 块 `if rows[idx].modelUsed == nil, let m = lastTurnModel` → m 为 nil → 不 stamp
- 渲染 `if let model = group.modelUsed { TurnMetaChip(...) }` → group.modelUsed = nil → chip 不出

老 agent 没事是因为 `agents[].model` 在历史 agent_status 里早就 populate 过，merging() 路径 `model: other.model ?? model` 不会 blank，所以 currentModel 一直拿得到。

### 修复（v0.2.39）

ConversationViewModel 加 `seedTurnModel(_:)` —— 幂等 setter，仅当 `currentTurnModel == nil` 时填入。

AppViewModel 的 `agentStatus` handler 在 `agents.insert(snap, at: 0)` 后立刻调：

```swift
if let m = snap.model {
    conversations[snap.id]?.seedTurnModel(m)
}
```

VM 在哪一刻已经存在？turn_started 处理时通过 `conversation(for: agentId)` 创建过了（lazy 创建在 stream 事件分发里），所以 agent_status 处理时 `conversations[snap.id]` 可取到。

时序：seed 在 turn_started 之后 ~1ms，turn_completed 之前数十秒到几分钟。中间陆续到的 assistantMessage chunk 经 `appendStreamedRow` 的 coalescing（`rows[idx] = row` 整体替换）会带上 modelUsed=model；turn_completed 也能正常 stamp duration。

### 边角

- 用户没选模型（`pendingNewAgentModel` 为 nil，daemon 用 provider 默认）的情况下，daemon 第一次 agent_status 仍然会带 model，这条路径同样覆盖
- 极端 race：第一条 assistantMessage chunk 在 agent_status 之前就到（理论上可能但日志里没观察到），那条 chunk 的 row 仍然是 nil；但只要后续还有 chunk 到，coalescing 会把整个 row 覆盖成有 model 的版本
- 完全没有后续 chunk + turn_completed 也在 agent_status 之前到的情况下还是会缺；但实际 turn 一般持续秒级以上，agent_status 1ms 内就到，几乎不可能命中

### 版本

0.2.38 → 0.2.39，build 39 → 40。已部署 `/Applications/PaseoMac.app`。


---

## 2026-05-14 v0.2.40 → v0.2.43：稳定性三件套 + 翻车回滚

这次目标是上次代码 review 拍下的三个问题：reconnect 不重试、conversations 无淘汰、图片 PNG 内存。看似都不大，结果有一处把 app 干卡死了。完整复盘见 [`docs/swiftui-stability-notes.md`](swiftui-stability-notes.md)，这里只记时序。

### v0.2.40：一次性改三件事

1. **reconnect bug**：`scheduleReconnect` 的 guard 从 `.disconnected` 放宽到 `.disconnected || .failed`。原意是网络抖动后能继续退避重试。
2. **LRU conversations**：`conversations: [String: ConversationViewModel]` 加 8 个上限，超出时按访问顺序淘汰非选中项。`conversation(for:)` 命中已有 VM 时刷新访问顺序到末尾（MRU），新建时 append 并触发 `evictStaleConversations()`。
3. **图片 PNG 落盘**：`PendingImageAttachment` 从 `pngData: Data` 改为 `fileURL: URL`，写到 `~/Library/Caches/PaseoMac/images/<uuid>.png`，`pngData` 改成 computed property 只在 RPC 发送时读盘。`PaseoMacApp.init()` 调 `cleanOldCache(olderThan: 7天)`。

提交：`a7e8d62`。tag `v0.2.40`，build 41。

### v0.2.41：scroll-on-turn-complete

用户反馈"回应结束了但字显示不全，要切换会话才能看全"。

定位：`turn_completed` 改的是 `rows[idx].durationSec`（TurnMetaChip 浮现）和 `vm.isAgentWorking`（TurnStatusBar 切样式）；现有自动滚动只看 `rows.count` 和 `rows.last?.text`，**两个都没变**，layout 增高的内容被 composer 挡住。

修：`MessageList` 加 `.onChange(of: vm.isAgentWorking)`，从 true→false 后延迟 150ms 调 `proxy.scrollTo("bottom")`。

提交：`dd31759`。tag `v0.2.41`，build 42。

### v0.2.42：紧急回滚 reconnect retry

用户：「打开就卡死，连上后看不到任何之前的对话」。

诊断手段：
- `~/Library/Logs/PaseoMac/paseomac.log` 显示 `connect_start → connect_failed (relay handshake timeout) → connect_start 3s 后` —— 是我新加的 retry 在跑
- daemon 日志 `~/.paseo/daemon.log`：`ws_runtime_metrics` 显示 PaseoMac client 5 秒内打出 14 个 fetch_agents，最多 11 个并发，每个堵 4-5s

根因：v0.2.40 的 reconnect retry 让 `.failed` 也进重试循环。`connect()` 失败时 WS 实际已经握过手，relay 留了 grace session。客户端重试 → 新 WS 握手 → relay 把上一轮 grace 里的 fetch_agents 顺手 resume 重放 → daemon 短时间被请求洪水淹没 → 响应丢失/延迟 → 客户端 agent 列表永远空白。

修：guard 改回原版 `case .disconnected`。失去自动从 `.failed` 重试，但换来稳定性——用户需要手动点 reconnect 按钮。

提交：`fc32de5`。tag `v0.2.42`，build 43。

### v0.2.43：99% CPU 死循环——LRU 触发了 SwiftUI 自我重渲染

用户：「还是不行，还是打开就卡死」。

`ps -o pcpu` 显示主线程 99% CPU 持续。`sample` 抓栈，全部停在：

```
GraphHost.flushTransactions
 → AG::Subgraph::update
   → ResolvedTextFilter.updateValue
     → PropertyList.Tracker.hasDifferentUsedValues
       → compare → find1 (递归)
```

不是死锁，是 SwiftUI 在以 30+ Hz 频率重新评估整棵 view 树。

根因：`ConversationView.body` 里有：

```swift
let vm = app.conversation(for: agentId)
```

每次 body 触发都会调一次。v0.2.40 的 LRU 在命中已有 VM 时 mutate `conversationAccessOrder`（`@Observable` 属性）：

```swift
if let existing = conversations[agentId] {
    conversationAccessOrder.removeAll { $0 == agentId }
    conversationAccessOrder.append(agentId)
    return existing
}
```

虽然没有 View 显式订阅这个属性，但写入仍走 `ObservationRegistrar`，把当前 transaction 标脏。SwiftUI 在 flushTransactions 阶段扫整个 PropertyList 比对——大会话场景下这一轮就要数十 ms。每次 `body` 又写一次，再标脏一次，**自循环就这样成立**。

修：访问已有 VM 时直接返回，不刷顺序：

```swift
if let existing = conversations[agentId] { return existing }
```

LRU 退化为 FIFO（按创建顺序淘汰）。对 15 个 agent 上下的规模完全够。

提交：`32d3b8c`。tag `v0.2.43`，build 44。

### 当前部署状态

- `/Applications/PaseoMac.app` = v0.2.43 build 44，CPU 稳定在 15% 左右处理 stream（之前 99%）
- 三个稳定性改动里只有 reconnect retry 整个回滚了；LRU 保留了上限但去掉触发热路径的 mutate；图片磁盘缓存 + scroll-on-turn-complete 都还在

### 经验入册

新建 [`docs/swiftui-stability-notes.md`](swiftui-stability-notes.md)，把这次踩到的四个坑做成可检索的案例：

1. `body` 里 mutate `@Observable` → SwiftUI 自我重渲染死循环
2. reconnect 无条件从 `.failed` 重试 → relay 消息风暴
3. 图片字节直接挂 Row → 内存线性上涨（这次的修复是正确的）
4. `turn_completed` 后需要补 scroll-to-bottom（这次的修复是正确的）

下次再动稳定性相关的代码先翻这份 notes。
