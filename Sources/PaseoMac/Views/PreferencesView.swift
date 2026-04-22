import SwiftUI

struct PreferencesView: View {
    @Environment(SettingsStore.self) private var settings

    @AppStorage("paseomac.usageApiUrl")   private var usageApiUrl:   String = ""
    @AppStorage("paseomac.usageApiToken") private var usageApiToken: String = ""

    var body: some View {
        @Bindable var settings = settings
        TabView {
            // MARK: General tab
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

                    Slider(
                        value: $settings.composerHeight,
                        in: SettingsStore.composerHeightRange,
                        step: 2
                    ) {
                        Text("Composer height")
                    }
                    HStack {
                        Text("Composer height")
                        Spacer()
                        Text(String(format: "%.0f pt", settings.composerHeight))
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

            // MARK: Integration tab
            Form {
                Section("Claude Usage") {
                    TextField("Endpoint URL", text: $usageApiUrl)
                        .font(.system(.body, design: .monospaced))
                    SecureField("Token", text: $usageApiToken)
                        .font(.system(.body, design: .monospaced))
                    Text("Point to a VPS endpoint that proxies the Anthropic usage API and returns JSON with five_hour/seven_day utilization. The sidebar quota panel appears only when configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(8)
            .tabItem { Label("Integration", systemImage: "network") }
        }
        .frame(minWidth: 460, minHeight: 340)
    }
}
