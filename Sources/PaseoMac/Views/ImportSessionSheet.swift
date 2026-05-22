import SwiftUI

/// Lists Claude/Codex/OpenCode/Pi sessions discovered on the daemon's
/// filesystem and lets the user import one into Paseo. Mirrors the
/// upstream "Import existing CLI sessions" home-screen flow but as a
/// modal sheet — Paseo for Mac doesn't have the React app's home tiles
/// yet, and a sheet is the lightest way to land the feature.
///
/// Requires daemon ≥ 0.1.79; older daemons return an empty list (with a
/// hint surfaced through `importSheetError`).
struct ImportSessionSheet: View {
    @Environment(AppViewModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import session").font(.title2).bold()
                Spacer()
                Button {
                    Task { await app.openImportSheet() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh list")
                .disabled(app.importSheetLoading)
            }
            Text("Continue a Claude, Codex, OpenCode, or Pi session you started from the terminal. The daemon scans your local provider history files and lists any that aren't already paired with a Paseo agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if app.importSheetLoading {
                HStack { ProgressView(); Text("Scanning…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else if let err = app.importSheetError, app.importSheetEntries.isEmpty {
                ContentUnavailableView(
                    "No sessions found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(err)
                )
                .frame(maxHeight: 200)
            } else {
                List(app.importSheetEntries) { session in
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await app.importSession(session) }
                        }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }

            HStack {
                Spacer()
                Button("Close") { app.dismissImportSheet(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct SessionRow: View {
    let session: ImportableSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.providerLabel)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Text(session.title ?? "Untitled")
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(relativeActivity)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let preview = session.lastPromptPreview ?? session.firstPromptPreview, !preview.isEmpty {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Text(session.cwd)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
    }

    private var relativeActivity: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: session.lastActivityAt)
            ?? ISO8601DateFormatter().date(from: session.lastActivityAt)
        guard let date else { return session.lastActivityAt }
        let style = RelativeDateTimeFormatter()
        style.unitsStyle = .abbreviated
        return style.localizedString(for: date, relativeTo: Date())
    }
}
