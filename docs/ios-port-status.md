# iOS Port — Current Status

> 最后更新：2026-05-20

## 已完成

### Phase 0 ✅ — 目录重构 + Mac 零回归
Commit: `1e23240` + `47a00ae`

- `Sources/PaseoMac/` 拆成三层：`PaseoCore/`、`PaseoUI/`、`PaseoMacApp/`
- 新增 6 个平台抽象：`PlatformImage`、`PlatformPasteboard`、`PlatformWakeNotifier`、`PlatformAttachmentOpener`、`PlatformFileReveal`、`PendingImageAttachment`（跨平台核心）
- Mac 端验证：`swift build -c release` ✅、`bundle.sh` ✅、`--list-agents` ✅（在 mini 上跑过）

### Phase 1 (部分完成) — 真正的多 target 拆分 + iOS 骨架

#### 已做 ✅
- **Package.swift** 改为真正三目标：`PaseoCore` library、`PaseoUI` library、`PaseoMacApp` executable，平台加了 `.iOS(.v17)`
- **PaseoCore/PaseoUI 全面加 `public`**（`8b5df2f`、`731e1b0`、`0bb1ea4`）
- **`Sources/PaseoIOSApp/`** 骨架写好：
  - `PaseoIOSApp.swift` — `@main` + Scene + 注入 iOS 平台实现
  - `IOSPlatform.swift` — `IOSPasteboard`、`IOSWakeNotifier`、`IOSAttachmentOpener`、`NoOpFileReveal`
  - `PendingImageAttachment+IOS.swift` — 已简化（iOS 图片处理移到 PaseoUI）
- **`Apps/project.yml`** — xcodegen 配置写好
- **`Apps/ExportOptions.plist`** — 打包配置写好
- **`scripts/build-ios.sh`** — 打包脚本写好
- **平台图片方法归位** (`50ca93c`)：`PendingImageAttachment.from(image:)`、`fromFileURL`、`thumbnail` 移到 `PaseoUI/Platform/PendingImageAttachment.swift` 的 `#if os()` 块内，PasteboardMac.swift 和 PaseoIOSApp 里的重复实现已删除
- **其他修复**：antigravity provider 替换 gemini（`aa9b98f`）、AppViewModel await 修复

#### 未完成 ❌（下次会话继续）

**当前 `swift build` 还有 2 类错误：**

**错误 1 — `AgentSnapshot` 缺 public memberwise init**

文件：`Sources/PaseoUI/ViewModels/AppViewModel.swift` 行 ~1174、1186、1198、1217

`AgentSnapshot` 是 `Decodable` struct，只有自动合成的 `init(from: Decoder)`，没有 public 的 memberwise init。`AppViewModel.swift` 里的 `private extension AgentSnapshot` 有 `withMode`、`withModel`、`withThinking`、`merging` 四个方法用 memberwise init 构造新实例，跨模块后不可见。

**修复**：在 `Sources/PaseoCore/Network/Protocol.swift` 的 `AgentSnapshot` struct 内加：

```swift
public init(
    id: String, provider: String?, cwd: String, status: String, title: String?,
    createdAt: String, updatedAt: String, lastUserMessageAt: String?,
    model: String?, thinkingOptionId: String?, effectiveThinkingOptionId: String?,
    currentModeId: String?, availableModes: [AgentMode]?, lastUsage: AgentUsage?,
    archivedAt: String?, requiresAttention: Bool?, attentionReason: String?
) {
    self.id = id; self.provider = provider; self.cwd = cwd; self.status = status
    self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt
    self.lastUserMessageAt = lastUserMessageAt; self.model = model
    self.thinkingOptionId = thinkingOptionId
    self.effectiveThinkingOptionId = effectiveThinkingOptionId
    self.currentModeId = currentModeId; self.availableModes = availableModes
    self.lastUsage = lastUsage; self.archivedAt = archivedAt
    self.requiresAttention = requiresAttention; self.attentionReason = attentionReason
}
```

**错误 2 — `AgentMode`/`AgentUsage` 可能也需要 public init**

在修错误 1 之后再跑 `swift build` 看是否还有残余错误。

**错误解决后的下一步：iOS Simulator 构建**

1. mini 上装 xcodegen（如未装）：`brew install xcodegen`（但 mini 没有 Homebrew，可能需要手动安装 xcodegen，或者用 Mint、或者直接下载 binary release）
2. `cd Apps && xcodegen generate --spec project.yml`
3. `xcodebuild build -project Apps/PaseoIOS.xcodeproj -scheme PaseoIOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep -E 'error:|Build succeeded|FAILED'`
4. 修 iOS 编译错误（主要是 `#if os(macOS)` 缺 `#else`、UIKit/AppKit 交叉引用等）

## mini 环境注意事项

- mini 没有 Homebrew（`brew` 不可用）
- mini 没有 `pkg-config`
- mini `.vendor/swift-sodium/Package.swift` 已在 mini 上**本地修改**（不在 git 里，因为 `.vendor/` 是 gitignored）改成了 `binaryTarget` 用 xcframework，每次 `git reset --hard` 后需要重新写这个文件：

```swift
// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "swift-sodium",
    products: [
        .library(name: "Clibsodium", targets: ["Clibsodium"])
    ],
    targets: [
        .binaryTarget(
            name: "Clibsodium",
            path: "Clibsodium.xcframework"
        )
    ]
)
```

一键写入 mini 的命令（在 VPS 上执行）：
```bash
ssh mini "python3 -c \"
content = '''// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: \\\\\"swift-sodium\\\\\",
    products: [
        .library(name: \\\\\"Clibsodium\\\\\", targets: [\\\\\"Clibsodium\\\\\"])
    ],
    targets: [
        .binaryTarget(
            name: \\\\\"Clibsodium\\\\\",
            path: \\\\\"Clibsodium.xcframework\\\\\"
        )
    ]
)
'''
open('/Users/cc/Public/Project/paseo-mac/.vendor/swift-sodium/Package.swift','w').write(content)
print('done')
\""
```

## 分支状态

- 分支：`feat/ios-port`
- VPS 领先 origin 5 个 commit（**未 push 到 GitHub**，等用户验证后再 push）
- mini 当前 HEAD：`50ca93c`（最新）

## 文件结构（当前）

```
Sources/
  PaseoCore/          ← Foundation+Sodium library，全 public API
    Network/          (5 files)
    Logging.swift
    SettingsStore.swift
  PaseoUI/            ← SwiftUI library，全 public API
    Platform/
      PlatformImage.swift
      PlatformPasteboard.swift
      PlatformWakeNotifier.swift
      PlatformAttachmentOpener.swift
      PlatformFileReveal.swift
      PendingImageAttachment.swift   ← 包含 from(image:)/fromFileURL/#if os() 分支
    ViewModels/
      AppViewModel.swift
      ConversationViewModel.swift
    Views/             (9 files)
  PaseoMacApp/        ← macOS executable
    PaseoMacApp.swift
    ComposerTextView.swift
    SmokeTest.swift
    PasteboardMac.swift   ← PasteboardHelper + MacPasteboard（已去掉重复的 from/fromFileURL）
    MacWakeNotifier.swift
    MacAttachmentOpener.swift
    MacFileReveal.swift
  PaseoIOSApp/        ← iOS app skeleton（还不能单独 build，等 Xcode project）
    PaseoIOSApp.swift
    IOSPlatform.swift
    PendingImageAttachment+IOS.swift  ← 仅剩 1 行（内容已移到 PaseoUI）
Apps/
  project.yml         ← xcodegen spec
  ExportOptions.plist
scripts/
  bundle.sh           ← macOS 打包（现有）
  build-ios.sh        ← iOS 打包（新增，待验证）
```
