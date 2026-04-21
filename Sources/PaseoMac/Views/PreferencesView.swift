import SwiftUI

/// Content of the native `Settings` scene (⌘,) — a single General tab with
/// the three appearance knobs. Live-updates the conversation view because
/// both read from the injected `SettingsStore`.
struct PreferencesView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        TabView {
            Form {
                Section("Typography") {
                    Slider(
                        value: $settings.fontScale,
                        in: SettingsStore.fontScaleRange,
                        step: 0.05
                    ) {
                        Text("Font size")
                    } minimumValueLabel: {
                        Text("A").font(.caption)
                    } maximumValueLabel: {
                        Text("A").font(.title2)
                    }
                    HStack {
                        Text("Font scale")
                        Spacer()
                        Text(String(format: "%.2f×", settings.fontScale))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: $settings.paragraphLineSpacing,
                        in: SettingsStore.lineSpacingRange,
                        step: 0.5
                    ) {
                        Text("Line spacing")
                    }
                    HStack {
                        Text("Paragraph line spacing")
                        Spacer()
                        Text(String(format: "%.1f pt", settings.paragraphLineSpacing))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Section("Layout") {
                    Slider(
                        value: $settings.bubbleGap,
                        in: SettingsStore.bubbleGapRange,
                        step: 1
                    ) {
                        Text("Bubble gap")
                    }
                    HStack {
                        Text("Gap between bubbles")
                        Spacer()
                        Text(String(format: "%.0f pt", settings.bubbleGap))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            settings.resetToDefaults()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(8)
            .tabItem { Label("General", systemImage: "slider.horizontal.3") }
        }
        .frame(minWidth: 460, minHeight: 340)
    }
}
