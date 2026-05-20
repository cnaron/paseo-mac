import SwiftUI
import PaseoCore

/// First-run / reconnect UI for pasting a relay pairing offer.
/// Accepted formats (handled by `ConnectionOffer.parse`):
///   - Plain JSON: `{"v":2,"serverId":"...","daemonPublicKeyB64":"...","relay":{"endpoint":"..."}}`
///   - Base64 of the above
///   - URL: `https://app.paseo.sh/#offer=<base64>` or `paseo://...`
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var app

    @State private var offerRaw: String = ""
    @State private var submitting: Bool = false
    @State private var localError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Paseo Daemon")
                .font(.title2).bold()

            Text("Paste a pairing offer from the daemon (Paseo app → Settings → Pair device). The offer pins this client to the daemon's public key — traffic goes through the relay server end-to-end encrypted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $offerRaw)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            if let err = errorText() {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? "Connecting…" : "Connect") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || offerRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 340)
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
            if case .connected = app.connectionState {
                dismiss()
            }
        }
    }
}
