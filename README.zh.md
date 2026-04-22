# paseo-mac

[English](README.md)

用于远程管理 [Claude Code](https://claude.ai/code) 代理的原生 macOS 客户端。Claude Code 运行在你的服务器或 VPS 上，这个 App 让你从 Mac 连接并与之交互。

## 为什么要做这个 App

Claude Code 是一个运行在服务端的命令行工具，负责管理 AI 编程代理。它自带一个 Web UI，但这意味着你需要在浏览器里保持一个标签页打开，同时还要开放端口。

这个 App 是一个原生 macOS 替代方案：它通过 Paseo 中继（Claude Code 使用的同一套 WebSocket 基础设施）连接到守护进程，让你用一个标准的 Mac 窗口来管理代理、查看对话、发送消息。

核心使用场景：你在 VPS 上 24 小时运行着 Claude Code，希望有一个轻量的 Mac 客户端随时查看进度——就像查看 Slack 或消息 App 一样。

## 功能

- **侧边栏** — 列出所有代理，带实时状态指示灯（绿色=运行中，带动画）
- **对话视图** — Markdown 渲染、代码高亮、工具调用详情、内联图片
- **每轮信息** — 每条助手回复下方显示模型名称和用时
- **消息搜索** — 在任意对话中过滤消息
- **输入框** — 发送消息，支持图片和文本/代码文件附件
- **代理控制** — 每个代理独立设置模型、模式和思考强度
- **配额面板** — 显示 Claude.ai 订阅用量（5小时/7天窗口），需配置后使用

## 局限性

**使用前请务必阅读。**

- **非官方产品。** 这是个人项目，与 Anthropic 或 Paseo 团队没有任何关联。
- **依赖协议。** App 使用 `@getpaseo/server` 的 WebSocket 协议通信。协议一旦变更，App 即失效。
- **未经 Apple 公证。** 二进制文件未签名。首次启动时 macOS 会提示警告——右键 → 打开 即可继续。
- **必须有守护进程。** 需要一个正在运行的 Paseo 守护进程和有效的配对凭证。App 本身不能独立运行。
- **配额面板需要自行搭建。** 侧边栏的用量进度条需要在 VPS 上配置一个代理端点（见下方说明）。App 不能从 Mac 直接调用 Anthropic API——由 VPS 来调用。
- **预览质量。** 为个人使用而构建和测试。边缘情况处理不完善，错误提示较少。
- **仅支持 macOS 14+。** 使用了 SwiftUI Observation 框架（`@Observable`），需要 Sonoma 或更高版本。

## 安装

从 [Releases](https://github.com/cnaron/paseo-mac/releases) 下载 **PaseoMac.zip**，解压后拖入 Applications 文件夹。

首次启动：右键点击 App → **打开**（macOS Gatekeeper 会阻止双击打开未签名应用）。

## 连接

你需要在某台机器上运行 Paseo 守护进程。安装方式：

```bash
npm i -g @getpaseo/cli
paseo onboard
```

在守护进程所在机器上复制配对凭证，然后在 PaseoMac 中：点击齿轮图标 → 粘贴凭证 → **Connect**。

## 配额面板（可选）

App 不能从 Mac 直接访问 Anthropic 用量 API——Mac 可能没有对外网络。由 VPS 获取数据后，App 从 VPS 读取。

**VPS 端** — 创建 `~/usage-api/fetch.sh`：

```bash
#!/bin/bash
set -euo pipefail
CREDS="$HOME/.claude/.credentials.json"
ACCESS_TOKEN=$(python3 -c "import json; print(json.load(open('$CREDS'))['claudeAiOauth']['accessToken'])")
SUB_TYPE=$(python3 -c "import json; print(json.load(open('$CREDS')).get('claudeAiOauth',{}).get('subscriptionType',''))" 2>/dev/null || echo "")
RESP=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1" --max-time 15 "https://api.anthropic.com/api/oauth/usage")
python3 -c "
import json,sys,time
d=json.loads(sys.argv[1]); d['subscription_type']=sys.argv[2]; d['fetched_at']=int(time.time())
print(json.dumps(d))
" "$RESP" "$SUB_TYPE" > ~/usage-api/cache.json
```

```bash
chmod +x ~/usage-api/fetch.sh && ~/usage-api/fetch.sh
# 每 5 分钟自动更新：
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/usage-api/fetch.sh") | crontab -
```

**nginx** — 添加带 token 鉴权的 location：

```nginx
location = /api/claude-usage {
    if ($http_x_usage_token != "YOUR_SECRET_TOKEN") { return 401; }
    alias /home/youruser/usage-api/cache.json;
    default_type application/json;
}
```

**App 端** — 打开**偏好设置（⌘,）→ Integration**，填入端点 URL 和 token。

## 许可证

MIT
