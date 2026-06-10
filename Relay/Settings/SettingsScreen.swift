import SwiftUI

/// Settings tab (§4.6) — cards in spec order: Tip Jar, Supporter,
/// Application, Terminal, App Protection, Theme, Scrolling, Support, Legal.
struct SettingsScreen: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(TipStore.self) private var tipStore

    private let supportEmail = "chillzs51@gmail.com"
    private let privacyPolicyURL = URL(string: "https://aaroncx.github.io/Relay/privacy")!

    var body: some View {
        @Bindable var theme = theme
        @Bindable var settings = settings
        NavigationStack {
            Form {
                TipJarView()
                SupporterView()

                Section("Application") {
                    LabeledSlider(
                        label: "App font size",
                        value: $theme.appFontSize,
                        range: 14...22,
                        onReset: { theme.resetAppFontSize() }
                    )
                }

                Section {
                    LabeledSlider(
                        label: "Terminal font size",
                        value: $theme.terminalFontSize,
                        range: 9...22,
                        onReset: { theme.resetTerminalFontSize() }
                    )
                    Text("relay ~ % echo Example text")
                        .font(.system(size: theme.terminalFontSize, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Terminal font preview")
                } header: {
                    Text("Terminal")
                }

                Section {
                    Toggle("Require Face ID / Touch ID", isOn: $settings.appProtection)
                } header: {
                    Text("App Protection")
                } footer: {
                    Text("Locks Relay on launch and when returning after 60 seconds in the background. Uses your device passcode as fallback.")
                }

                Section("Theme") {
                    Picker("Appearance", selection: $theme.theme) {
                        ForEach(AppTheme.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }

                Section {
                    Toggle("Send scroll as mouse wheel in full-screen apps", isOn: $settings.scrollWheelBridge)
                    Toggle("Auto-reattach tmux", isOn: $settings.autoReattachTmux)
                    Toggle("Auto-send dictation after 1.5s silence", isOn: $settings.autoSendDictation)
                } header: {
                    Text("Scrolling & Behavior")
                } footer: {
                    Text("Swipes scroll tmux and Claude Code history natively when the app requests mouse reporting. Dictation is processed entirely on this device.")
                }

                Section("Support") {
                    Link(destination: URL(string: "mailto:\(supportEmail)?subject=Relay%20Support")!) {
                        Label("Email Support", systemImage: "envelope")
                    }
                }

                Section("Legal") {
                    NavigationLink("Privacy Policy") {
                        BundledDocumentView(resource: "PrivacyPolicy", title: "Privacy Policy")
                    }
                    NavigationLink("License Agreement") {
                        BundledDocumentView(resource: "LicenseAgreement", title: "License Agreement")
                    }
                    Link(destination: privacyPolicyURL) {
                        Label("Privacy Policy (Web)", systemImage: "safari")
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                if tipStore.loadState != .loaded {
                    await tipStore.load()
                }
            }
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value))pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Reset", action: onReset)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            Slider(value: $value, in: range, step: 1) {
                Text(label)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Renders a markdown document bundled with the app — legal docs work fully
/// offline, no server involved.
struct BundledDocumentView: View {
    let resource: String
    let title: String

    var body: some View {
        ScrollView {
            if let text = loadDocument() {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                ContentUnavailableView("Document Missing", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadDocument() -> AttributedString? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
    }
}
