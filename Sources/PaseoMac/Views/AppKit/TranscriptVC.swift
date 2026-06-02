import SwiftUI
import AppKit

// MARK: - Transcript host (AppKit shell → SwiftUI content)
//
// History: the transcript started as the pure-SwiftUI `TranscriptView`
// (ScrollView + VStack), which renders CORRECTLY — the only complaint was
// occasional blank space with long content. Two AppKit container experiments
// (NSTableView with sizeThatFits row heights, then NSScrollView+NSStackView with
// NSHostingView per turn) were attempts to fix that, but both reintroduced worse
// height-measurement artifacts: overlap, bottom truncation, jitter. Measuring
// SwiftUI height from AppKit is the root cause of that whole bug class.
//
// So the transcript is back to the pure-SwiftUI `TranscriptView`, hosted in a
// single NSHostingView so it still lives as one island inside the AppKit
// ConversationVC shell ("AppKit 打底 + SwiftUI 显示内容"). SwiftUI owns scrolling
// and its own scroll-to-bottom button. The AppKit-side scroll API (currentScrollY
// / restoreScroll / scrollToBottomPublic) is kept as no-ops for ConversationVC
// compatibility; scrollState stays "at bottom" so ConversationVC's overlay button
// stays hidden (TranscriptView draws its own jump button).

final class TranscriptVC: NSViewController {
    let app: AppViewModel
    let settings: SettingsStore
    let onOpenFile: (String) -> Void

    private var host: NSHostingView<AnyView>!

    private weak var boundVM: ConversationViewModel?
    private var agentProvider: String?
    private var workspaceCwd: String?
    private var pending = false

    /// Kept only for ConversationVC's overlay-button API. The hosted SwiftUI
    /// TranscriptView has its own scroll-to-bottom button, so we leave this in the
    /// "at bottom" state, which keeps ConversationVC's overlay hidden + inert.
    let scrollState = TranscriptScrollState()

    init(app: AppViewModel, settings: SettingsStore, onOpenFile: @escaping (String) -> Void) {
        self.app = app
        self.settings = settings
        self.onOpenFile = onOpenFile
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        host = NSHostingView(rootView: content())
        view = host
    }

    /// restoreY is accepted for API compatibility but ignored — SwiftUI owns scroll
    /// position and lands at the bottom on (re)bind, which is the chat default.
    func bind(vm: ConversationViewModel?, agentProvider: String?, workspaceCwd: String?,
              pending: Bool, restoreY: CGFloat? = nil) {
        self.boundVM = vm
        self.agentProvider = agentProvider
        self.workspaceCwd = workspaceCwd
        self.pending = pending
        host.rootView = content()
    }

    private func content() -> AnyView {
        if let vm = boundVM {
            return AnyView(
                TranscriptView(vm: vm, agentProvider: agentProvider,
                               workspaceCwd: workspaceCwd, onOpenFile: onOpenFile)
                    .id(vm.agentId)
                    .environment(app).environment(settings)
                    .environment(\.accent, settings.accentPalette)
            )
        }
        return AnyView(
            TranscriptEmptyView(pending: pending)
                .environment(app).environment(settings)
                .environment(\.accent, settings.accentPalette)
        )
    }

    // No-op scroll API kept for ConversationVC compatibility (SwiftUI owns scroll).
    var currentScrollY: CGFloat { 0 }
    func restoreScroll(_ y: CGFloat) {}
    func scrollToBottomPublic() {}
}

// MARK: - Observable scroll state (kept for ConversationVC's overlay-button API)

@Observable
final class TranscriptScrollState {
    var isAtBottom: Bool = true
}

// MARK: - Empty / pending overlay

struct TranscriptEmptyView: View {
    let pending: Bool
    @Environment(AppViewModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            if pending {
                if let err = app.creatingAgentError {
                    DSIcon(name: "alert", size: 28).foregroundStyle(DS.orange)
                    Text("无法启动会话").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text)
                    Text(err).font(.system(size: 13)).foregroundStyle(DS.text2).multilineTextAlignment(.center).padding(.horizontal, 40)
                } else if let text = app.creatingAgentText {
                    UserTurnView(group: TurnGroup(id: "creating", isUser: true, text: text, images: app.creatingAgentImages))
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在启动会话…").font(.system(size: 13)).foregroundStyle(DS.text2) }
                } else {
                    DSIcon(name: "chat", size: 34, weight: .light).foregroundStyle(DS.text3)
                    Text("输入消息开始对话").font(.system(size: 14)).foregroundStyle(DS.text2)
                }
            } else {
                DSIcon(name: "chat", size: 32, weight: .light).foregroundStyle(DS.text3)
                Text(app.connectionState == .connected ? "从侧栏选择一个会话" : "未连接")
                    .font(.system(size: 14)).foregroundStyle(DS.text2)
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
