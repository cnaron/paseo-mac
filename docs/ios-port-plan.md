# iOS 端移植方案

> 目标：把 paseo-mac 改造成"一份代码、两个平台壳"的结构，让 macOS 上现有的所有自定义功能（连接 VPS、relay 协议、品牌图标、跨 provider 切换、quota 面板等）在 iOS 上零成本同步可用。未来在 paseo-mac 上的任何改动，只要落在共享层，iOS 端自动享用。

## 为什么不 fork 官方 Expo app

| 维度 | fork 官方 iOS app (Expo/RN) | 移植 paseo-mac (SwiftUI) |
|---|---|---|
| 起点包大小 | 几十 MB（RN runtime + xterm webview） | 预计 5-8 MB |
| 运行时内存 | 几百 MB（同上） | 预计 50-100 MB |
| iPhone 发热 | 高（语音双向音频 + WebGL xterm） | 低（无音频、无 WebView） |
| 代码复用 | 0（跟 paseo-mac 完全两套技术栈） | ~60% 直接共享 |
| 自定义功能延续 | 全部要在 RN 重写一遍 | 已有 Swift 代码迁过来即可 |

paseo-mac 已经独立验证过 relay 协议、NaCl 加密、agent 列表、会话渲染、跨 provider 切换、quota 面板等所有核心场景。在 SwiftUI 框架内做 iOS 适配比从 React Native 重写省一个数量级的工作量。

## 架构目标

```
paseo-mac/  （仓库名暂不变，README 里说明同时承载 iOS）
├── Package.swift                         # 改造为 multi-platform，暴露 PaseoCore + PaseoUI
├── Sources/
│   ├── PaseoCore/                        # 平台无关，纯 Foundation
│   │   ├── Network/                      # DaemonClient, Protocol, RelayChannel, RelayCrypto, ConnectionOffer
│   │   ├── Logging.swift
│   │   ├── SettingsStore.swift           # Keychain 跨平台
│   │   └── Models/                       # 协议数据模型
│   ├── PaseoUI/                          # SwiftUI 跨平台 view + viewmodel
│   │   ├── ViewModels/                   # AppViewModel, ConversationViewModel
│   │   ├── Views/                        # 可跨平台的 view，平台差异用 #if os(...) 隔离
│   │   └── Platform/                     # 平台抽象（图片、剪贴板、打开 URL 等）
│   ├── PaseoMacApp/                      # macOS 专属：@main + NSViewRepresentable 文本框
│   │   ├── PaseoMacApp.swift
│   │   ├── ComposerTextView.swift        # 包 NSTextView
│   │   └── ComposerView+Mac.swift        # NSOpenPanel、NSImage 拖拽
│   └── PaseoIOSApp/                      # iOS 专属：@main + UIViewRepresentable
│       ├── PaseoIOSApp.swift
│       ├── ComposerTextView.swift        # 包 UITextView
│       └── ComposerView+IOS.swift        # PhotosPicker、UIDocumentPicker
├── Apps/
│   └── PaseoIOS.xcodeproj                # iOS app bundle（SPM 不能产出 iOS .app）
└── scripts/
    ├── bundle.sh                         # 现有 mac 打包脚本
    └── build-ios.sh                      # 新增：xcodebuild + ad-hoc 个人签名
```

### 关键约束

- **`PaseoCore` 和 `PaseoUI` 不允许 import AppKit/UIKit**，全部 Foundation + SwiftUI。所有需要平台原生 API 的能力通过 protocol 抽象，由各 app target 注入实现。
- **macOS app 继续走 SPM executable + `bundle.sh`**，零回归。
- **iOS app 走 Xcode 项目**（SPM 本身不能产出 iOS .app bundle），但所有源码引用都指向 `Sources/PaseoCore` 和 `Sources/PaseoUI`，不复制源文件。

## 文件迁移清单

按当前 9954 行的分布，重新落位：

| 当前路径 | 新位置 | 修改量 |
|---|---|---|
| `Sources/PaseoMac/Network/*` (5 files, 2278 行) | `Sources/PaseoCore/Network/` | 0（纯 Foundation） |
| `Sources/PaseoMac/Logging.swift` | `Sources/PaseoCore/` | 0 |
| `Sources/PaseoMac/SettingsStore.swift` | `Sources/PaseoCore/` | 0（Keychain 跨平台） |
| `Sources/PaseoMac/SmokeTest.swift` | `Sources/PaseoMacApp/`（仅 mac CLI 模式） | 0 |
| `Sources/PaseoMac/ViewModels/ConversationViewModel.swift` (911 行) | `Sources/PaseoUI/ViewModels/` | 0 |
| `Sources/PaseoMac/ViewModels/AppViewModel.swift` (1311 行) | `Sources/PaseoUI/ViewModels/` | 小：`NSWorkspace.didWakeNotification` 抽象为 `PlatformWakeNotifier` protocol，mac 注入 NSWorkspace，iOS 注入 `UIApplication.willEnterForegroundNotification` |
| `Sources/PaseoMac/Models/PasteAndDrop.swift` (302 行) | `Sources/PaseoUI/Platform/PendingImageAttachment.swift` + `Sources/PaseoMacApp/PasteboardMac.swift` + `Sources/PaseoIOSApp/PasteboardIOS.swift` | 中：抽象出 `PlatformImage` typealias（mac=`NSImage`, iOS=`UIImage`），剪贴板读取拆到平台 target |
| `Sources/PaseoMac/ContentView.swift` (72 行) | `Sources/PaseoUI/Views/` | 0 |
| `Sources/PaseoMac/Views/ConnectSheet.swift` (76 行) | `Sources/PaseoUI/Views/` | 0 |
| `Sources/PaseoMac/Views/AgentListView.swift` (647 行) | `Sources/PaseoUI/Views/` | 小：`NSImage` 加载品牌图标 → `PlatformImage` typealias |
| `Sources/PaseoMac/Views/PreferencesView.swift` (240 行) | `Sources/PaseoUI/Views/` | 0 |
| `Sources/PaseoMac/Views/UsagePanel.swift` (272 行) | `Sources/PaseoUI/Views/` | 小：`NSWorkspace.shared.open` → `Environment(\.openURL)` |
| `Sources/PaseoMac/Views/MarkdownRender.swift` (497 行) | `Sources/PaseoUI/Views/` | 小：复制按钮的 `NSPasteboard` → `PlatformPasteboard` 抽象 |
| `Sources/PaseoMac/Views/ConversationView.swift` (1931 行) | `Sources/PaseoUI/Views/` | 中：散落 5-6 处 `NSPasteboard` / `NSWorkspace`，统一替换为平台抽象；图片预览的 `NSImage` 用 `PlatformImage` |
| `Sources/PaseoMac/Views/ComposerView.swift` (844 行) | 拆：UI 主体进 `Sources/PaseoUI/Views/ComposerView.swift`，`NSOpenPanel` 文件选择 + `NSImage` 拖拽进 `Sources/PaseoMacApp/ComposerView+Mac.swift`，iOS 对应放 `Sources/PaseoIOSApp/ComposerView+IOS.swift`（用 `PhotosPicker` + `fileImporter`） | 大：核心改造文件 |
| `Sources/PaseoMac/Views/ComposerTextView.swift` (292 行) | `NSViewRepresentable` 包 `NSTextView` 留在 `Sources/PaseoMacApp/`；iOS 版本 `Sources/PaseoIOSApp/ComposerTextView.swift` 用 `UIViewRepresentable` 包 `UITextView`（MVP 阶段可先用 SwiftUI 原生 `TextEditor`，等基础闭环跑通再换 UITextView） | 大：iOS 端要重写一份 |
| `Sources/PaseoMac/PaseoMacApp.swift` (41 行) | `Sources/PaseoMacApp/PaseoMacApp.swift` | 0 |
| 新增 | `Sources/PaseoIOSApp/PaseoIOSApp.swift` | 全新约 50 行 |

### 平台抽象层（`Sources/PaseoUI/Platform/`）

为了让共享 view 不写一堆 `#if os(macOS)`，抽出几个 protocol：

```swift
// Platform/PlatformImage.swift
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

// Platform/PlatformPasteboard.swift
public protocol PlatformPasteboard {
    func setString(_ s: String)
    func readImages() -> [PlatformImage]
}

// Platform/PlatformOpener.swift
public protocol PlatformURLOpener {
    func open(_ url: URL)
}

// Platform/PlatformWakeNotifier.swift
public protocol PlatformWakeNotifier {
    func observe(_ handler: @escaping () -> Void)
}
```

mac app 在启动时注入 `NSPasteboard` / `NSWorkspace` / `NSWorkspace.didWakeNotification` 实现，iOS app 注入 `UIPasteboard` / `UIApplication.shared.open` / `UIApplication.willEnterForegroundNotification`。

## iOS 端 UX 适配

不全盘照搬 mac 的窗口式布局：

- **导航**：iPhone 上 `NavigationSplitView` 自动降级为 `NavigationStack`，左滑 = 返回 agent 列表。iPad 保留分栏。
- **底部输入栏**：保持 mac 的 pill 风格，但 textarea 占满键盘上方安全区。
- **图片附件**：用 `PhotosPicker`（系统原生）替代 mac 上的拖拽 + `NSOpenPanel`。
- **复制 / 分享**：长按消息触发 contextMenu（同 mac），复制走 `UIPasteboard.general`。
- **连接配置**：mac 上是 Preferences 窗口，iOS 上做成 settings sheet（齿轮按钮触发）。
- **快捷键**：mac 上的 ⌘R 刷新等，iOS 下保留 `keyboardShortcut` API（外接键盘有效），不强行做手势替代。
- **去除项**：菜单栏命令（iOS 没有）、`Settings { }` scene（iOS App 协议不支持）。

## 编译产物 & 部署

| 产物 | 工具链 | 签名 |
|---|---|---|
| `PaseoMac.app` | `swift build` + `scripts/bundle.sh` | 不签（沿用现状） |
| `PaseoIOS.ipa` | `xcodebuild archive -project Apps/PaseoIOS.xcodeproj` + `xcodebuild -exportArchive` | 个人 Apple ID 自签（免费证书 7 天有效，到期重签） |

`scripts/build-ios.sh` 包装：
1. `xcodebuild archive` 产 `.xcarchive`
2. `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist`
3. 把 `.ipa` 复制到 `~/Public/Project/paseo-mac/build/`
4. 用 `xcrun devicectl device install app` 直接装到 iPhone（前提 iPhone 用 USB / Wi-Fi 配对过 mini）

后续如果要长期使用、不想 7 天重签：申请 $99/年 Apple Developer 账号，证书 1 年有效，TestFlight 90 天分发。

## 阶段拆解

### Phase 0 — 仓库重构 + Mac 端零回归
预计 0.5 天。

- [ ] 把现有 `Sources/PaseoMac/` 内容按上表拆到 `Sources/PaseoCore/` + `Sources/PaseoUI/` + `Sources/PaseoMacApp/`
- [ ] `Package.swift` 改造为多产品（library: PaseoCore, PaseoUI；executable: PaseoMacApp）
- [ ] 引入 `PlatformImage` typealias 和 `PlatformPasteboard / Opener / WakeNotifier` protocol，mac 实现注入
- [ ] `swift build` 通过，`bundle.sh` 产物在 mini 上启动测试，跟现有功能完全一致
- [ ] 跑现有 `--list-agents` smoke test 仍 PASS

### Phase 1 — iOS 最小闭环
预计 1 天。

- [ ] 新建 `Apps/PaseoIOS.xcodeproj`，引用 `Sources/PaseoCore` + `Sources/PaseoUI`
- [ ] 写 `Sources/PaseoIOSApp/PaseoIOSApp.swift`（@main + Scene + 注入 iOS 平台实现）
- [ ] 注入 `UIPasteboard / UIApplication.open / willEnterForeground` 三个 protocol 的 iOS 实现
- [ ] iOS 18 模拟器跑起来：能粘贴连接 offer、看到 agent 列表、点进会话看历史消息流式更新
- [ ] composer 用 SwiftUI 原生 `TextEditor`（MVP，先不支持图片）
- [ ] 自签部署到自己 iPhone 15 Pro，验证 relay 长连接稳定性

### Phase 2 — iOS Composer 完整化
预计 0.5-1 天。

- [ ] `ComposerTextView` 写 iOS 版（`UIViewRepresentable` 包 `UITextView`），对齐 mac 的字号/占位符/Enter 发送行为
- [ ] 图片附件：`PhotosPicker`（相册）+ `fileImporter`（文件 app）
- [ ] 长按消息 contextMenu 的复制走 `UIPasteboard`
- [ ] 跨 provider 切换按钮、模式切换、模型切换在 iOS 上验证

### Phase 3 — 长期维护机制
预计 0.5 天。

- [ ] README.zh.md / README.md 更新，说明 mac + iOS 双端
- [ ] CONTRIBUTORS / PLAN 加 iOS 章节
- [ ] `scripts/build-ios.sh` 完成，从 mini 一键打包 + 装机
- [ ] mini 上配 cron 或 systemd timer，每周自动 rebuild + 重签一次 ipa（应对 7 天证书过期）
- [ ] 未来 paseo-mac 协议升级 / view 调整，落在 `PaseoCore` / `PaseoUI` 即可，发版同时出 mac + iOS 两个产物

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| `ComposerTextView` 用 SwiftUI 原生 `TextEditor` 体验不如 mac 的 NSTextView（无图片粘贴、无富文本快捷键） | Phase 1 用 `TextEditor` 跑通 MVP，Phase 2 换 UITextView |
| iOS 后台 WebSocket 被系统杀（iOS 不允许任意后台长连接） | 接受这个限制：app 切到后台 → WS 断开；回到前台 → 自动重连 + replay missed events（`DaemonClient` 现有的重连逻辑可复用） |
| 个人证书 7 天过期，频繁重签很烦 | `scripts/build-ios.sh` + mini cron 自动化；或上 Apple Developer Program ($99/年) |
| Swift package 拆分破坏现有 mac 编译 | Phase 0 严格守住"现有 mac 行为零变更"，每步 `swift build` + `--list-agents` 验证 |
| iOS NavigationSplitView 在 iPhone 上行为细节跟 mac 不同（侧边栏抽屉 vs 真分栏） | 接受 iOS 平台习惯，不强行做成 mac 样式 |
| `swift-sodium` 在 iOS 的可用性 | Sodium 本身支持 iOS，现有 `.vendor/swift-sodium` 同一份可被 iOS target 引用 |
| 文件路径里的 `paseo-mac` 名字暗示只有 mac | 不重命名仓库（避免破坏 git remote、bookmark、本地路径），README + Package name 都说清楚同时承载两端 |

## 未涉及（明确 out-of-scope）

- 语音 / 听写
- 内嵌终端（xterm）
- 推送通知（agent 完成提醒；后续单独议）
- iPad 多窗口
- App Store 上架
- Android

## 决策点

1. **Package name 改不改**：`PaseoMac` → `PaseoClients`？倾向**不改**，仓库还叫 paseo-mac，product 名分开（`PaseoMacApp` 和 `PaseoIOSApp`），减少破坏面。
2. **iOS Composer 第一版用 `TextEditor` 还是直接上 `UITextView`**：倾向 `TextEditor`，Phase 1 出最小闭环最重要。
3. **iOS 是否复用 quota 面板**：复用。usage-api 接口 mac/iOS 共享同一个 VPS 端点，view 层零改。

---

最后更新：2026-05-20
