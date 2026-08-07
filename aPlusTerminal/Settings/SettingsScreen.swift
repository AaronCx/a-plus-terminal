import SwiftUI

/// Settings tab (§4.6) — cards in spec order: Support (tips), Application,
/// Terminal, App Protection, Theme, Scrolling,
/// Support, Legal, version footer.
struct SettingsScreen: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(TipStore.self) private var tipStore
    @Environment(ProfileStore.self) private var profiles
    @Environment(BackgroundExitDiagnostics.self) private var exitDiagnostics
    @Environment(PiPCoordinator.self) private var pip

    private let supportURL = URL(string: "https://github.com/AaronCx/a-plus-terminal/issues")!
    // Trailing slash matches the GitHub Pages canonical URL (and SupportView).
    private let privacyPolicyURL = URL(string: "https://aaroncx.github.io/a-plus-terminal/privacy/")!

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
                    Toggle("Agent icons", isOn: $settings.agentMascotIcons)
                } header: {
                    Text("Agent & Multiplexer")
                } footer: {
                    Text("a+Terminal is agent-agnostic. Auto-detect names whichever CLI agent it sees (Claude Code, Codex, aider, Gemini CLI, Hermes…). Set a default here or per server. Agent icons: sessions and the Live Activity show the detected agent's icon instead of the terminal glyph.")
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

                // Hidden entirely on hardware without PiP (brief §3.2).
                if PiPCoordinator.isSupported {
                    Section {
                        Toggle("Pop-Out Sessions (beta)", isOn: $settings.popOutSessions)
                        if settings.popOutSessions {
                            Toggle("Auto pop-out on app switch", isOn: $settings.autoPopOutOnAppSwitch)
                        }
                    } header: {
                        Text("Pop-Out")
                    } footer: {
                        Text("Watch a session in a small floating window while you use other apps — view-only, with a tap to jump back in. Auto pop-out opens it for the session you're viewing when you switch away.")
                    }
                    .onChange(of: settings.popOutSessions) { _, isOn in
                        if !isOn { pip.masterToggleTurnedOff() }
                    }
                }

                Section {
                    Toggle("Capture console output", isOn: $settings.previewConsoleCapture)
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Shows the previewed page's console.log messages in a pane inside the preview, since a phone has no developer tools. This works by injecting a small script into your own page — it's the only part of Preview that does, which is why it's a choice. Off = nothing is injected and no messages are captured. Nothing leaves your device either way.")
                }

                Section {
                    Toggle("Use meshyy when available (beta)", isOn: $settings.meshyyTransport)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Keeps your session alive on the server, so it survives the app being suspended or the network dropping, and replays what you missed. Needs meshyyd on the host; without it nothing changes. Turn this off to get the normal SSH behaviour back.")
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

                Section {
                    Link(destination: supportURL) {
                        Label("Report an Issue", systemImage: "questionmark.circle")
                    }
                    // Device-truth diagnostics row: how the previous process
                    // run ended (clean vs. suspected background kill).
                    // Deliberately visible in TestFlight/App Store builds so
                    // a background-kill report can be read straight off the
                    // phone after reproducing — no Xcode attach needed.
                    // Plain local text; nothing leaves the device.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Exit")
                        Text(exitDiagnostics.previousExitSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Support")
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

                // Version footer — "which build am I on" must be answerable
                // in-app (TestFlight builds are otherwise indistinguishable).
                Section {
                } footer: {
                    Text(AppVersion.current)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Settings")
            // Settings never hides the tab bar — asserting it explicitly
            // guards against any future writer latching the shared bar
            // hidden underneath this tab.
            .toolbar(.visible, for: .tabBar)
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
