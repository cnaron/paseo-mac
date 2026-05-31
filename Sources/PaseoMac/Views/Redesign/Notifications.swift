import SwiftUI
import Observation

// MARK: - Notification model (prototype `notifications.jsx` + data.jsx)

enum NotifKind: String, Sendable {
    case permission, question, done, error

    var iconName: String {
        switch self {
        case .permission: return "shield"
        case .question:   return "question-chat"
        case .done:       return "check-sm"
        case .error:      return "alert"
        }
    }
    var color: Color {
        switch self {
        case .permission: return DS.orange
        case .question:   return AccentPalette.terracotta.accent
        case .done:       return DS.greenSoftTX
        case .error:      return DS.red
        }
    }
    var bg: Color {
        switch self {
        case .permission: return DS.orangeSoftBG
        case .question:   return AccentPalette.terracotta.tint
        case .done:       return DS.greenSoftBG
        case .error:      return DS.redSoftBG
        }
    }
}

struct AppNotification: Identifiable, Sendable {
    let id: String
    let chatId: String
    let provider: String?
    let kind: NotifKind
    let title: String
    let body: String
    let time: String
    var unread: Bool
}

@MainActor
@Observable
final class NotificationStore {
    var items: [AppNotification] = []
    var toasts: [AppNotification] = []

    var unreadCount: Int { items.filter(\.unread).count }

    func push(_ n: AppNotification) {
        items.insert(n, at: 0)
        toasts.append(n)
    }
    func dismissToast(_ id: String) { toasts.removeAll { $0.id == id } }
    func markRead(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].unread = false }
        dismissToast(id)
    }
    func clearAll() {
        items = items.map { var n = $0; n.unread = false; return n }
        toasts = []
    }
}

// MARK: - Toast stack (top-right macOS banners)

struct ToastStack: View {
    let store: NotificationStore
    var onOpen: (AppNotification) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.toasts) { n in
                ToastView(n: n, onOpen: onOpen, onClose: { store.dismissToast(n.id) })
            }
        }
        .frame(width: 332)
        .padding(.top, 14)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(!store.toasts.isEmpty)
    }
}

private struct ToastView: View {
    let n: AppNotification
    var onOpen: (AppNotification) -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 9).fill(n.kind.bg)
                .frame(width: 34, height: 34)
                .overlay(DSIcon(name: n.kind.iconName, size: 18).foregroundStyle(n.kind.color))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(n.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(n.time).font(.system(size: 11)).foregroundStyle(DS.text3)
                }
                Text(n.body).font(.system(size: 12.5)).foregroundStyle(DS.text2).lineLimit(2)
                if n.kind == .permission {
                    HStack(spacing: 8) {
                        Button { onClose() } label: { Text("允许").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 28).background(DS.green, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                        Button { onClose() } label: { Text("拒绝").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.text).padding(.horizontal, 14).frame(height: 28).background(DS.hover, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                    }
                    .padding(.top, 7)
                }
            }
            Button(action: onClose) { DSIcon(name: "x", size: 13).foregroundStyle(DS.text3) }
                .buttonStyle(.plain).frame(width: 18, height: 18)
        }
        .padding(.init(top: 13, leading: 14, bottom: 13, trailing: 13))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(n) }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

// MARK: - Header bell + notification center

struct NotifBell: View {
    let store: NotificationStore
    var onOpen: (AppNotification) -> Void = { _ in }
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                DSIcon(name: "bell", size: 18).foregroundStyle(DS.text2).frame(width: 28, height: 28)
                if store.unreadCount > 0 {
                    Text("\(store.unreadCount)")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(minWidth: 15, minHeight: 15)
                        .padding(.horizontal, 2)
                        .background(DS.red, in: Capsule())
                        .overlay(Capsule().strokeBorder(DS.contentBG, lineWidth: 2))
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help("通知")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            NotificationCenter(store: store, onOpen: { n in open = false; onOpen(n) })
                .frame(width: 320)
        }
    }
}

private struct NotificationCenter: View {
    let store: NotificationStore
    var onOpen: (AppNotification) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("通知").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text)
                Spacer()
                Button { store.clearAll() } label: {
                    Text("全部标为已读").font(.system(size: 12)).foregroundStyle(AccentPalette.terracotta.accent)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            Divider()
            if store.items.isEmpty {
                Text("暂无通知").font(.system(size: 13)).foregroundStyle(DS.text3)
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.items) { n in
                            NotifRow(n: n) { store.markRead(n.id); onOpen(n) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }
}

private struct NotifRow: View {
    let n: AppNotification
    var onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                if n.unread { Circle().fill(AccentPalette.terracotta.accent).frame(width: 6, height: 6).padding(.top, 6) }
                else { Color.clear.frame(width: 6) }
                RoundedRectangle(cornerRadius: 8).fill(n.kind.bg).frame(width: 30, height: 30)
                    .overlay(DSIcon(name: n.kind.iconName, size: 15).foregroundStyle(n.kind.color))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(n.title).font(.system(size: 13, weight: n.unread ? .semibold : .medium)).foregroundStyle(DS.text).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(n.time).font(.system(size: 11)).foregroundStyle(DS.text3)
                    }
                    Text(n.body).font(.system(size: 12)).foregroundStyle(DS.text2).lineLimit(1)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(hover ? DS.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
