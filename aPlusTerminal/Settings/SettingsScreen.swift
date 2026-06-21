import SwiftUI

/// Settings tab (§4.6) — cards in spec order: Support (tips), Application,
/// Terminal, App Protection, Theme, Scrolling,
/// Support, Legal.
struct SettingsScreen: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(TipStore.self) private var tipStore
    @Environment(ProfileStore.self) private var profiles

    private let supportURL = URL(string: "https://github.com/AaronCx/a-plus-terminal/issues")!
    private let privacyPolicyURL = URL(string: "https://aaroncx.github.io/a-plus-terminal/privacy")!

    var body: some View {
        @Bindable var theme = theme
        @Bindable var settings = settings
        NavigationStack {
            Form {
                SupportCardLink()

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
                    Text("a+terminal ~ % echo Example text")
                        .font(.system(size: theme.terminalFontSize, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Terminal font preview")
                } header: {
                    Text("Terminal")
                }


                Section("Theme") {
                    Picker("Appearance", selection: $theme.theme) {
                        ForEach(AppTheme.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }

                Section {
                    Picker("Default agent", selection: $settings.defaultAgentProfileID) {
                        Text("Auto-detect").tag("auto")
                        ForEach(profiles.agents) { agent in
                            Text(agent.displayName).tag(agent.id)
                        }
                        Text("None").tag("none")
                    }
                    Picker("Default multiplexer", selection: $settings.defaultMultiplexerProfileID) {
                        ForEach(profiles.multiplexers) { mux in
                            Text(mux.displayName).tag(mux.id)
                        }
                    }
                } header: {
                    Text("Agent & Multiplexer")
                } footer: {
                    Text("a+Terminal is agent-agnostic. Auto-detect names whichever CLI agent it sees (Claude Code, Codex, aider, Gemini CLI, Hermes…). Set a default here or per server.")
                }

                Section {
                    Toggle("Send scroll as mouse wheel in full-screen apps", isOn: $settings.scrollWheelBridge)
                    Toggle("Auto-reattach multiplexer", isOn: $settings.autoReattachMultiplexer)
                    Toggle("Auto-send dictation after 1.5s silence", isOn: $settings.autoSendDictation)
                } header: {
                    Text("Scrolling & Behavior")
                } footer: {
                    Text("Auto-reattach multiplexer: when a connection resumes, return to your running session (tmux/zellij/screen) instead of a fresh shell — picking from your live sessions when more than one is open. Off = always a fresh shell. Swipes scroll natively when the app requests mouse reporting; dictation is processed entirely on this device.")
                }

                Section {
                    NavigationLink("Customize key bar") {
                        KeyBarSettingsView()
                    }
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Add, remove, or reorder the keys shown in the bar above the keyboard (Esc, Ctrl, C-b, arrows…). The mic and keyboard buttons always stay.")
                }

                Section("SSH Keys") {
                    NavigationLink("Manage Keys") {
                        KeysView()
                    }
                }

                Section("Support") {
                    Link(destination: supportURL) {
                        Label("Report an Issue", systemImage: "questionmark.circle")
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

/// Build 14 — edit the accessory key bar: reorder, remove, add, reset.
struct KeyBarSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                ForEach(settings.keyBarItems) { item in
                    Text(item.label)
                }
                .onMove { settings.keyBarItems.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { settings.keyBarItems.remove(atOffsets: $0) }
            } header: {
                Text("In the bar")
            } footer: {
                Text("Drag to reorder, swipe to remove.")
            }

            let available = KeyBarItem.allCases.filter { !settings.keyBarItems.contains($0) }
            if !available.isEmpty {
                Section("Add a key") {
                    ForEach(available) { item in
                        Button {
                            settings.keyBarItems.append(item)
                        } label: {
                            Label(item.label, systemImage: "plus.circle")
                        }
                    }
                }
            }

            Section {
                Button("Reset to default") {
                    settings.keyBarItems = KeyBarItem.defaultItems
                }
                .disabled(settings.keyBarItems == KeyBarItem.defaultItems)
            }
        }
        .navigationTitle("Key Bar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
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
