# paseo-mac

[English](README.md)

基于 SwiftUI 的原生 macOS 客户端，用于连接 [Paseo](https://github.com/getpaseo) 守护进程（Claude Code 远程代理）。通过 WebSocket 连接到 VPS 上的 Claude Code 或 Paseo 服务器，在轻量级 Mac 窗口中管理多个 AI 编程代理并与之对话。

> 本项目与 Paseo 官方团队无关，不代表其立场。

## 功能特性

- **多代理侧边栏** — 实时状态指示灯，运行时带动画效果
- **富文本对话视图** — Markdown 渲染、语法高亮代码块、工具调用详情、图片显示
- **每轮元数据** — 每条助手回复下方显示模型名称 + 用时
- **消息搜索** — 工具栏内联搜索过滤对话
- **智能输入框** — 自动高度增长、拖拽调整高度、支持图片和文本文件附件
- **代理控制** — 每个代理独立设置模型、模式、思考强度
- **滑动删除** 和右键菜单，快速管理代理
- **断线自动重连**
- **订阅配额面板** — 侧边栏显示用量进度条（可选，需配置 VPS 端点）

## 环境要求

- macOS 14.0 或更高版本
- Xcode 16 命令行工具：`xcode-select --install`
- 正在运行的 Paseo 守护进程 — 通过 `npm i -g @getpaseo/cli` 安装，然后运行 `paseo onboard`

## 构建

```bash
git clone https://github.com/cnaron/paseo-mac
cd paseo-mac
swift build -c release
bash scripts/bundle.sh release
open build/PaseoMac.app
```

## 连接

1. 在守护进程机器上，复制配对凭证（Paseo 应用 → 设置 → 配对设备，或运行 `paseo pair`）
2. 启动 PaseoMac → 点击侧边栏底部齿轮图标 → 粘贴凭证 → **Connect**

连接凭证经过端到端加密，并绑定到守护进程的公钥。流量通过中继服务器传输。

## 订阅配额面板（可选）

侧边栏可显示你的 Claude.ai 订阅使用情况（5 小时和 7 天窗口）。由于 Mac 端可能无法直接访问 Anthropic API，需要在 VPS 上搭建代理端点。

### 第一步：VPS 配置

```bash
mkdir -p ~/usage-api

cat > ~/usage-api/fetch.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
CREDS="$HOME/.claude/.credentials.json"
CACHE="$HOME/usage-api/cache.json"
TMP="$HOME/usage-api/cache.tmp.json"
ACCESS_TOKEN=$(python3 -c "import json,sys; d=json.load(open('$CREDS')); t=d['claudeAiOauth']['accessToken']; sys.exit(0) if t else sys.exit(1); print(t)")
SUB_TYPE=$(python3 -c "import json; d=json.load(open('$CREDS')); print(d.get('claudeAiOauth',{}).get('subscriptionType',''))" 2>/dev/null || echo "")
RESPONSE=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1" --max-time 15 "https://api.anthropic.com/api/oauth/usage")
python3 -c "
import json,sys,time
d=json.loads(sys.argv[1]); d['subscription_type']=sys.argv[2]; d['fetched_at']=int(time.time())
print(json.dumps(d))
" "$RESPONSE" "$SUB_TYPE" > "$TMP" && mv "$TMP" "$CACHE"
SCRIPT

chmod +x ~/usage-api/fetch.sh
~/usage-api/fetch.sh   # 立即获取一次

# 每 5 分钟自动更新
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/usage-api/fetch.sh >> $HOME/usage-api/fetch.log 2>&1") | crontab -
```

#### nginx 配置片段

```nginx
location = /api/claude-usage {
    if ($http_x_usage_token != "YOUR_SECRET_TOKEN") {
        return 401 '{"error":"unauthorized"}';
    }
    alias /home/youruser/usage-api/cache.json;
    default_type application/json;
    add_header Cache-Control "max-age=60";
}
```

### 第二步：应用配置

打开 **PaseoMac → 偏好设置（⌘,）→ Integration**：

| 字段 | 值 |
|---|---|
| Endpoint URL | `https://你的vps.example.com/api/claude-usage` |
| Token | 你的密钥 |

配置完成后，配额面板会自动出现在侧边栏中。

## 架构说明

```
┌─────────────────────────┐        WebSocket 中继（端到端加密）
│  PaseoMac.app（Mac）    │ ──────────────────────────────────────→ Paseo 守护进程（VPS）
│                         │                                             └── Claude API
│  （可选）               │        HTTPS + Token 鉴权
│  配额面板               │ ──────────────────────────────────────→ /api/claude-usage（VPS nginx）
└─────────────────────────┘                                             └── Anthropic 用量 API
```

## 许可证

MIT
