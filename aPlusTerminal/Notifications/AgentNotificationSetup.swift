import SwiftUI
import UIKit

/// What a user has to do on the server for agent notifications to exist at
/// all. Claude Code's default channel ("auto") sends nothing over SSH or
/// inside tmux, so without this setting a+Terminal never hears from it.
enum AgentNotificationSetup {
    /// The exact text the Copy button puts on the pasteboard: the JSON
    /// key/value pair to add to `~/.claude/settings.json`.
    static let settingLine = #""preferredNotifChannel": "terminal_bell""#
    static let settingsPath = "~/.claude/settings.json"
}

/// The one-time card shown over the terminal the first time Claude Code is
/// detected. Settings → Notifications → "Set up Claude Code" shows the same
/// content as a page.
struct NotificationSetupCard: View {
    var onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Get notified by Claude Code")
                    .font(.subheadline.weight(.semibold))
                Text("To get notified, run this on your server: add this line to \(AgentNotificationSetup.settingsPath) (inside the outer { }):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingLineRow(copied: $copied)
                Text("Claude Code then rings a few seconds into a permission prompt, and a+Terminal turns the ring into a notification. It rings again about a minute after it finishes, but iOS has usually suspended a+Terminal by then: that one usually arrives only while a pop-out keeps the app running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss Notification Setup")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityIdentifier("notificationSetupCard")
    }
}

/// The setting in monospace with a Copy button.
struct SettingLineRow: View {
    @Binding var copied: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(AgentNotificationSetup.settingLine)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Button(copied ? "Copied" : "Copy") {
                UIPasteboard.general.string = AgentNotificationSetup.settingLine
                copied = true
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .accessibilityIdentifier("copyNotificationSetting")
        }
        .padding(8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Settings → Notifications → "Set up Claude Code": the card's content,
/// plus the one case where tmux needs configuring.
struct NotificationSetupDetailView: View {
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("To get notified, run this on your server: add this line to \(AgentNotificationSetup.settingsPath) (inside the outer { }):")
                SettingLineRow(copied: $copied)
            } footer: {
                Text("Claude Code then rings the terminal bell a few seconds into a permission prompt, and a+Terminal turns the bell into a notification. It rings again about a minute after it finishes, but iOS has usually suspended a+Terminal by then: that one usually arrives only while a pop-out keeps the app running. The bell needs no tmux configuration.")
            }
            Section {
                Text("If you pick the \"iterm2\" or \"ghostty\" channel instead, Claude Code sends a notification sequence with its message rather than a bell. Inside tmux those sequences are dropped unless you add set -g allow-passthrough on to ~/.tmux.conf.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Other channels")
            }
        }
        .navigationTitle("Set Up Claude Code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Notifications.
struct NotificationSettingsSection: View {
    @Environment(\.openURL) private var openURL
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, sending, scheduled, denied
    }

    var body: some View {
        Section {
            NavigationLink("Set up Claude Code") {
                NotificationSetupDetailView()
            }
            Button {
                testState = .sending
                Task {
                    switch await AgentAlertCenter.shared.sendTestNotification() {
                    case .scheduled: testState = .scheduled
                    case .denied: testState = .denied
                    }
                }
            } label: {
                HStack {
                    Text("Send test notification")
                    Spacer()
                    if testState == .sending {
                        ProgressView()
                    }
                }
            }
            .disabled(testState == .sending)
            .accessibilityIdentifier("sendTestNotification")
            if testState == .scheduled {
                Text("Arrives in \(Int(AgentAlertCenter.testNotificationDelay)) seconds — leave the app now to see it on the Lock Screen, or stay to see the banner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if testState == .denied {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications are off for a+Terminal. Turn them on in iOS Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Notifications come only from the agent's own signal — the terminal bell or a notification sequence it sends — never from guessing at its output. They arrive only while a+Terminal is still running: for a short time after you leave it, or while a pop-out keeps it running. They do not arrive once iOS suspends the app. A pop-out of a session's terminal mutes that session: you are already watching it.")
        }
    }
}
