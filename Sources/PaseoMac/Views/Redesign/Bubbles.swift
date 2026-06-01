import SwiftUI
import AppKit

// MARK: - Turn model
//
// One visual turn. A user turn is a single bubble; an assistant turn carries an
// ordered list of sub-blocks (reasoning / tools / markdown / cards) rendered
// under a single avatar header — matching the prototype's assistant-turn shape.

enum TurnBlock: Identifiable {
    case markdown(String, text: String, streaming: Bool)
    case reasoning(String, text: String)
    case tools(String, [ConversationViewModel.ToolInfo])
    case permission(String, requestId: String?)
    case attention(String, text: String)
    case todo(String, text: String)
    case error(String, text: String)

    var id: String {
        switch self {
        case .markdown(let id, _, _), .reasoning(let id, _), .tools(let id, _),
             .permission(let id, _), .attention(let id, _), .todo(let id, _), .error(let id, _):
            return id
        }
    }
}

struct TurnGroup: Identifiable {
    let id: String
    let isUser: Bool
    var text: String = ""
    var timestamp: String? = nil
    var messageId: String? = nil
    var images: [PendingImageAttachment] = []
    var provider: String? = nil
    var blocks: [TurnBlock] = []
    var modelUsed: String? = nil
    var durationSec: TimeInterval? = nil
    var isActive: Bool = false       // true while this is the live-streaming last turn
    var turnStartedAt: Date? = nil   // elapsed timer origin; set only when isActive

    var copyText: String {
        blocks.compactMap { if case .markdown(_, let t, _) = $0 { return t } else { return nil } }
            .joined(separator: "\n\n")
    }
}

// MARK: - Per-turn extras

/// Context-window ring (prototype `ContextRing`).
struct ContextRing: View {
    let pct: Double
    var size: CGFloat = 15
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Circle().stroke(DS.dividerStrong, lineWidth: 2.2)
            Circle().trim(from: 0, to: min(max(pct, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
    private var color: Color { pct >= 0.9 ? DS.red : pct >= 0.7 ? DS.orange : accent.accent }
}

/// Turn status pill (prototype `TurnPill`): working dots+elapsed / done check+dur.
struct TurnPill: View {
    var working: Bool
    var elapsed: String? = nil
    var duration: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if working {
                ThinkingDots(color: DS.orange, dot: 5)
                Text("Working…\(elapsed.map { " " + $0 } ?? "")").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DS.text2)
            } else {
                DSIcon(name: "check-sm", size: 13, weight: .bold).foregroundStyle(DS.greenSoftTX)
                Text("完成\(duration.map { " · " + $0 } ?? "")").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DS.greenSoftTX)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(working ? Color(hex: 0xF1F1EF) : DS.greenSoftBG, in: Capsule())
    }
}

/// Pre-content "Thinking…" indicator on the rail.
struct ThinkingRail: View {
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            DSIcon(name: "clock", size: 13).foregroundStyle(DS.text3).frame(width: 26, alignment: .center)
            HStack(spacing: 6) {
                Text("Thinking").font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.text2)
                ThinkingDots(color: DS.text3, dot: 4)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - User turn (prototype `UserTurn`)

struct UserTurnView: View {
    let group: TurnGroup
    var onOpenFile: (String) -> Void = { _ in }
    @Environment(\.accent) private var accent
    @State private var expanded = false
    private var long: Bool { group.text.count > 280 }

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 7) {
                if let stamp = formatStamp(group.timestamp) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().strokeBorder(accent.accent, lineWidth: 1.5).frame(width: 17, height: 17)
                            DSIcon(name: "check-sm", size: 11, weight: .bold).foregroundStyle(accent.accent)
                        }
                        Text(stamp).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DS.text2)
                    }
                }
                if !group.images.isEmpty { UserBubbleImages(images: group.images) }
                if !group.text.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(displayText)
                            .font(.system(size: 15.5)).foregroundStyle(DS.text)
                            .lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 15).padding(.vertical, 11)
                            .background(accent.tint, in: UnevenRoundedRectangle(
                                cornerRadii: .init(topLeading: 15, bottomLeading: 15, bottomTrailing: 5, topTrailing: 15)))
                            .frame(maxWidth: 540, alignment: .trailing)
                        if long {
                            Button(expanded ? "收起" : "展开") { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                                .font(.system(size: 12.5)).foregroundStyle(accent.accent).buttonStyle(.plain)
                        }
                    }
                    .contextMenu {
                        Button("复制文本") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(group.text, forType: .string)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var displayText: String { long && !expanded ? String(group.text.prefix(240)) + "…" : group.text }
}

/// Image grid inside a sent user message.
private struct UserBubbleImages: View {
    let images: [PendingImageAttachment]
    @State private var zoom: PendingImageAttachment? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(images) { img in
                if let ns = NSImage(contentsOf: img.fileURL) {
                    Image(nsImage: ns).resizable().interpolation(.high).scaledToFill()
                        .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(DS.divider, lineWidth: 1))
                        .onTapGesture { zoom = img }
                }
            }
        }
        .sheet(item: $zoom) { img in
            if let ns = NSImage(contentsOf: img.fileURL) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: ns).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: 900, maxHeight: 720).padding(24)
                    IconButton(icon: "x", glyph: 18) { zoom = nil }.padding(12)
                }
            }
        }
    }
}

// MARK: - Assistant turn (prototype `AssistantTurn`, reference header)

struct AssistantTurnView: View {
    let group: TurnGroup
    var isStreaming: Bool = false
    var workspaceCwd: String? = nil
    var onOpenFile: (String) -> Void = { _ in }
    var pendingPermission: PermissionRequestPayload? = nil
    var resolvedIds: Set<String> = []
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}
    var onSubmitAnswers: ([String: String]) -> Void = { _ in }
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ProviderGlyph(provider: group.provider, size: 22).frame(width: 26, height: 26, alignment: .top)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    if let stamp = formatStamp(group.timestamp) {
                        Text(stamp).font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(DS.text2)
                    }
                    Text(profileLine).font(.system(size: 12)).foregroundStyle(DS.text3)
                }
                ForEach(group.blocks) { block in blockView(block) }
                if !group.isActive, let dur = group.durationSec {
                    TurnPill(working: false, duration: formatDurBubble(dur))
                }
                if !(isStreaming || group.isActive), !group.copyText.isEmpty { copyButton }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private func blockView(_ b: TurnBlock) -> some View {
        switch b {
        case .markdown(_, let text, let streaming):
            MDView(text: text, isStreaming: streaming, workspaceCwd: workspaceCwd, onOpenFile: onOpenFile)
        case .reasoning(_, let text):
            DisclosureBlock(label: "Thinking · \(wordCount(text)) words", body0: text, think: true)
        case .tools(_, let tools):
            ToolClusterView(tools: tools, workspaceCwd: workspaceCwd, onOpenFile: onOpenFile)
        case .attention(_, let text):
            AttentionCardView(text: text)
        case .todo(_, let text):
            HStack(alignment: .top, spacing: 8) {
                DSIcon(name: "checklist", size: 14).foregroundStyle(DS.text3)
                Text(text).font(.system(size: 13.5)).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
        case .error(_, let text):
            Text(text).font(.system(size: 14)).foregroundStyle(DS.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .permission(_, let reqId):
            permissionView(reqId)
        }
    }

    @ViewBuilder private func permissionView(_ reqId: String?) -> some View {
        if let rid = reqId, resolvedIds.contains(rid) {
            EmptyView()
        } else if let pp = pendingPermission, let aq = pp.askUserQuestion {
            AskQuestionCardView(questions: aq.questions, onSubmit: onSubmitAnswers, onSkip: onDeny)
        } else if pendingPermission != nil {
            PermissionCardView(
                title: "Permission Required",
                reason: pendingPermission?.description ?? pendingPermission?.name,
                command: nil, onAllow: onAllow, onDeny: onDeny
            )
        } else {
            EmptyView()
        }
    }

    private func formatDurBubble(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.0fs", t) : String(format: "%dm %ds", Int(t) / 60, Int(t) % 60)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(group.copyText, forType: .string)
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
        } label: {
            HStack(spacing: 4) {
                DSIcon(name: didCopy ? "check-sm" : "copy", size: 12)
                Text(didCopy ? "Copied" : "Copy").font(.system(size: 12))
            }
            .foregroundStyle(DS.text3)
        }
        .buttonStyle(.plain)
    }

    private var profileLine: String {
        if let m = group.modelUsed, !m.isEmpty { return prettyModel(m) }
        switch group.provider {
        case "gemini": return "Gemini"; case "codex": return "Codex"; case "claude", nil: return "default"
        default: return group.provider?.capitalized ?? "default"
        }
    }
    private func wordCount(_ t: String) -> Int { t.split(whereSeparator: \.isWhitespace).count }
}

/// Collapsible disclosure (已完成工作 / Thinking).
struct DisclosureBlock: View {
    let label: String
    let body0: String
    var think: Bool = false
    var defaultOpen: Bool = false
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    DSIcon(name: "chevron-right", size: 14).foregroundStyle(DS.text3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(label).font(.system(size: 13.5)).foregroundStyle(DS.text2)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if open {
                Text(body0)
                    .font(.system(size: 13.5)).foregroundStyle(DS.text2).italic(think)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, think ? 14 : 21)
                    .overlay(alignment: .leading) { if think { Rectangle().fill(DS.dividerStrong).frame(width: 2) } }
            }
        }
        .onAppear { open = defaultOpen }
    }
}

// MARK: - Tool cluster (prototype `ToolCluster`)

struct ToolClusterView: View {
    let tools: [ConversationViewModel.ToolInfo]
    var workspaceCwd: String? = nil
    var onOpenFile: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.offset) { i, info in
                ToolRow(info: info, onOpenFile: onOpenFile)
                if i < tools.count - 1 { Rectangle().fill(DS.divider).frame(height: 1) }
            }
        }
        .dsCard(radius: DS.R.card, fill: Color(hex: 0xFCFCFB), border: DS.divider)
    }
}

private struct ToolRow: View {
    let info: ConversationViewModel.ToolInfo
    var onOpenFile: (String) -> Void
    @State private var open = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            Button { if info.hasDetail { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } } label: {
                HStack(spacing: 9) {
                    Image(systemName: info.iconName).font(.system(size: 13)).foregroundStyle(DS.text2).frame(width: 16)
                    Text(info.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                    target
                    badge
                    statusView
                    Spacer(minLength: 0)
                    if info.hasDetail {
                        DSIcon(name: "chevron-right", size: 14).foregroundStyle(DS.textFaint).rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(hover ? DS.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }

            if open, info.hasDetail {
                Rectangle().fill(DS.divider).frame(height: 1)
                detail.background(Color.white)
            }
        }
    }

    @ViewBuilder private var target: some View {
        if let t = info.target, !t.isEmpty {
            if t.hasPrefix("/") {
                Button { onOpenFile(t) } label: {
                    Text(truncated(t)).font(DS.mono(12.5)).foregroundStyle(DS.greenSoftTX).underline().lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain)
            } else {
                Text(truncated(t)).font(DS.mono(12.5)).foregroundStyle(DS.text3).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var badge: some View {
        switch info.detailKind {
        case .plain(_, let mono) where mono: pill("Script", DS.badgeScriptBG, DS.badgeScriptTX)
        case .beforeAfter, .unifiedDiff: pill("Edit", DS.badgeEditBG, DS.badgeEditTX)
        default: EmptyView()
        }
    }
    private func pill(_ s: String, _ bg: Color, _ fg: Color) -> some View {
        Text(s).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 2).background(bg, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private var statusView: some View {
        switch info.status {
        case "running": ThinkingDots(color: DS.text2, dot: 4)
        case "failed", "error": DSIcon(name: "x", size: 14).foregroundStyle(DS.red)
        case "canceled": Text("canceled").font(.system(size: 11)).foregroundStyle(DS.orange)
        default: DSIcon(name: "check-sm", size: 14, weight: .semibold).foregroundStyle(DS.green)
        }
    }

    @ViewBuilder private var detail: some View {
        switch info.detailKind {
        case .none: EmptyView()
        case .plain(let text, let mono):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(mono ? DS.mono(12) : .system(size: 13)).foregroundStyle(Color(hex: 0x3A3A3D))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .beforeAfter(let b, let a): BeforeAfterView(before: b, after: a)
        case .unifiedDiff(let d): DiffView(text: d)
        }
    }

    private func truncated(_ s: String, max: Int = 64) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max/2 - 1)) + "…" + String(s.suffix(max/2 - 1))
    }
}

// MARK: - Diff / before-after (prototype `.diff-*`)

private struct DiffView: View {
    let text: String
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(DS.mono(12)).foregroundStyle(fg(line))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 1).background(bg(line))
            }
        }
        .padding(.vertical, 4)
    }
    private func fg(_ l: String) -> Color {
        if l.hasPrefix("+++") || l.hasPrefix("---") { return DS.text3 }
        if l.hasPrefix("+") { return DS.diffAddTX }
        if l.hasPrefix("-") { return DS.diffDelTX }
        if l.hasPrefix("@@") { return DS.diffHunkTX }
        return DS.text
    }
    private func bg(_ l: String) -> Color {
        if l.hasPrefix("+++") || l.hasPrefix("---") { return .clear }
        if l.hasPrefix("+") { return DS.diffAddBG }
        if l.hasPrefix("-") { return DS.diffDelBG }
        if l.hasPrefix("@@") { return DS.diffHunkBG }
        return .clear
    }
}

private struct BeforeAfterView: View {
    let before: String
    let after: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("── before ──", before)
            section("── after ──", after)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func section(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DS.mono(12)).foregroundStyle(DS.text3)
            Text(text).font(DS.mono(12)).foregroundStyle(DS.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Interaction cards (prototype `.icard.*`)

struct InteractionCard<Content: View>: View {
    let icon: String
    let iconBG: Color
    let iconFG: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8).fill(iconBG).frame(width: 28, height: 28)
                    .overlay(DSIcon(name: icon, size: 16).foregroundStyle(iconFG))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    if let s = subtitle { Text(s).font(.system(size: 12.5)).foregroundStyle(DS.text2) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            content().padding(.horizontal, 14).padding(.bottom, 14)
        }
        .dsCard(radius: DS.R.card, fill: DS.contentBG, border: DS.divider)
        .dsShadow(DS.shadowCard)
    }
}

struct PermissionCardView: View {
    let title: String
    let reason: String?
    let command: String?
    var onAllow: () -> Void
    var onDeny: () -> Void
    @State private var resolved: String? = nil

    var body: some View {
        InteractionCard(icon: "shield", iconBG: DS.orangeSoftBG, iconFG: DS.orange,
                        title: title, subtitle: reason) {
            VStack(alignment: .leading, spacing: 12) {
                if let cmd = command, !cmd.isEmpty {
                    Text("$ \(cmd)").font(DS.mono(12.5)).foregroundStyle(DS.chipTX)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color(hex: 0xFBFBFA), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.divider, lineWidth: 1))
                }
                if let r = resolved {
                    Text(r == "allow" ? "已允许" : "已拒绝").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(r == "allow" ? DS.greenSoftTX : DS.red)
                } else {
                    HStack(spacing: 9) {
                        Button { resolved = "allow"; onAllow() } label: {
                            HStack(spacing: 7) { DSIcon(name: "check-sm", size: 15, weight: .semibold); Text("Allow") }
                                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 32).background(DS.green, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                        Button { resolved = "deny"; onDeny() } label: {
                            Text("Deny").font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.text)
                                .padding(.horizontal, 16).frame(height: 32).background(DS.hover, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct AttentionCardView: View {
    let text: String
    var body: some View {
        InteractionCard(icon: "alert", iconBG: DS.redSoftBG, iconFG: DS.red, title: "Attention Required") {
            if !text.isEmpty {
                Text(text).font(.system(size: 13.5)).foregroundStyle(DS.text2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct AskQuestionCardView: View {
    let questions: [AskUserQuestion.Question]
    var onSubmit: ([String: String]) -> Void
    var onSkip: () -> Void
    @Environment(\.accent) private var accent
    @State private var answers: [String: String] = [:]
    @State private var done = false

    private var canSubmit: Bool {
        questions.allSatisfy { !(answers[$0.header] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        InteractionCard(icon: "question-chat", iconBG: accent.tint, iconFG: accent.accent, title: "Question from agent") {
            if done {
                HStack(spacing: 7) { DSIcon(name: "check-sm", size: 15, weight: .semibold).foregroundStyle(DS.greenSoftTX); Text("已提交").foregroundStyle(DS.greenSoftTX) }
                    .font(.system(size: 13.5))
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(questions) { q in
                        VStack(alignment: .leading, spacing: 6) {
                            if !q.header.isEmpty { Text(q.header).font(.system(size: 12)).foregroundStyle(DS.text3) }
                            Text(q.question).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.text).textSelection(.enabled)
                            Text((q.multiSelect ?? false) ? "可多选" : "单选").font(.system(size: 11.5)).foregroundStyle(DS.text3)
                            FlowChips(options: q.options.map(\.label), selected: answers[q.header]) { answers[q.header] = $0 }
                            TextField("Other (type a custom answer)…", text: Binding(
                                get: { answers[q.header] ?? "" }, set: { answers[q.header] = $0 }))
                                .textFieldStyle(.roundedBorder).controlSize(.small)
                        }
                    }
                    HStack(spacing: 9) {
                        Button { done = true; onSubmit(answers) } label: {
                            Text("Submit").font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 32).background(canSubmit ? accent.accent : DS.dividerStrong, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(!canSubmit)
                        Button { done = true; onSkip() } label: {
                            Text("Skip").font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.text)
                                .padding(.horizontal, 16).frame(height: 32).background(DS.hover, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Wrap-flow option chips for AskUserQuestion.
struct FlowChips: View {
    let options: [String]
    let selected: String?
    var onPick: (String) -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        FlexWrap(spacing: 8, lineSpacing: 8) {
            ForEach(options, id: \.self) { opt in
                let on = selected == opt
                Button { onPick(opt) } label: {
                    Text(opt).font(.system(size: 13)).foregroundStyle(on ? accent.press : DS.text)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(on ? accent.tint : DS.contentBG, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? accent.accent : DS.dividerStrong, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }
}

struct TodoCardView: View {
    let title: String
    let items: [(text: String, state: String)]
    @Environment(\.accent) private var accent

    var body: some View {
        InteractionCard(icon: "checklist", iconBG: DS.greenSoftBG, iconFG: DS.greenSoftTX, title: title) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(it.state == "doing" ? accent.accent : DS.textFaint, lineWidth: 1.5)
                                .frame(width: 16, height: 16)
                            if it.state == "done" { RoundedRectangle(cornerRadius: 5).fill(DS.green).frame(width: 16, height: 16); DSIcon(name: "check-sm", size: 11, weight: .bold).foregroundStyle(.white) }
                            if it.state == "doing" { Circle().fill(accent.accent).frame(width: 6, height: 6) }
                        }
                        Text(it.text).font(.system(size: 13.5))
                            .foregroundStyle(it.state == "done" ? DS.text3 : DS.text)
                            .strikethrough(it.state == "done")
                        if it.state == "doing" { Text("进行中").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent.accent) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - helpers

func formatStamp(_ iso: String?) -> String? {
    guard let iso, let date = parseISODate(iso) else { return nil }
    let f = DateFormatter()
    f.dateFormat = "M/d/yyyy h:mm a"
    f.amSymbol = "AM"; f.pmSymbol = "PM"
    return f.string(from: date)
}

func prettyModel(_ raw: String) -> String {
    var s = raw
    if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
    s = s.replacingOccurrences(of: "[1m]", with: " 1M").replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: "")
    let parts = s.split(separator: "-")
    if parts.count >= 3 {
        let rest = parts.dropFirst(3).joined(separator: " ")
        return "\(parts[0].capitalized) \(parts[1]).\(parts[2])\(rest.isEmpty ? "" : " \(rest)")"
    }
    return raw
}
