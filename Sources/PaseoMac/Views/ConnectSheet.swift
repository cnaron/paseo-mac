import SwiftUI

/// First-run / reconnect UI for pasting a relay pairing offer.
/// Accepted formats (handled by `ConnectionOffer.parse`):
///   - Plain JSON: `{"v":2,"serverId":"...","daemonPublicKeyB64":"...","relay":{"endpoint":"..."}}`
///   - Base64 of the above
///   - URL: `https://app.paseo.sh/#offer=<base64>` or `paseo://...`
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var app
    @Environment(SettingsStore.self) private var settings

    @State private var offerRaw: String = ""
    @State private var submitting: Bool = false
    @State private var localError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Color(hex: 0x7D8DF0), Color(hex: 0x5566D6)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "network").font(.system(size: 17, weight: .medium)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接到 Paseo Daemon").font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.text)
                    Text("粘贴来自守护进程的配对 offer").font(.system(size: 12.5)).foregroundStyle(DS.text3)
                }
                Spacer(minLength: 0)
                IconButton(icon: "x", box: 28, glyph: 16, help: "关闭") { dismiss() }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)

            Rectangle().fill(DS.divider).frame(height: 1)

            // Body
            VStack(alignment: .leading, spacing: 14) {
                Text("在 Paseo 应用 → 设置 → 配对设备 生成一个 offer，然后粘贴到下方。offer 将此客户端的公钥绑定到守护进程——所有流量经 relay 端对端加密。")
                    .font(.system(size: 13)).foregroundStyle(DS.text2)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: 0xFAF9F7))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.dividerStrong, lineWidth: 1))
                    if offerRaw.isEmpty {
                        Text("粘贴 offer JSON、base64 或 https://app.paseo.sh/#offer=… 链接")
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(DS.textFaint)
                            .padding(.horizontal, 13).padding(.top, 11)
                    }
                    TextEditor(text: $offerRaw)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(.clear)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                }
                .frame(minHeight: 110)

                if let err = errorText() {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DS.red).font(.system(size: 14))
                        Text(err).font(.system(size: 13)).foregroundStyle(DS.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)

            Rectangle().fill(DS.divider).frame(height: 1)

            // Footer
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(DS.hover, in: RoundedRectangle(cornerRadius: 8))

                let canConnect = !submitting && !offerRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(submitting ? "连接中…" : "连接") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(canConnect ? .white : DS.text3)
                    .padding(.horizontal, 18).frame(height: 32)
                    .background(canConnect ? settings.accentPalette.accent : DS.dividerStrong,
                                in: RoundedRectangle(cornerRadius: 8))
                    .disabled(!canConnect)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(minWidth: 520)
        .background(DS.contentBG)
        .preferredColorScheme(.light)
        .onAppear {
            if let saved = app.savedOfferRaw { offerRaw = saved }
        }
    }

    private func errorText() -> String? {
        if let l = localError { return l }
        if case .failed(let m) = app.connectionState { return m }
        return nil
    }

    private func submit() {
        localError = nil
        submitting = true
        let raw = offerRaw
        Task { @MainActor in
            await app.connect(withOfferRaw: raw)
            submitting = false
            if case .connected = app.connectionState { dismiss() }
        }
    }
}
