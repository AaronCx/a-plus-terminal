import SwiftUI
import LocalAuthentication

/// App Protection (§4.6): Face ID/Touch ID (with passcode fallback) on launch
/// and on foreground after 60 seconds in the background.
struct AppLockGate<Content: View>: View {
    static var relockInterval: TimeInterval { 60 }

    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @ViewBuilder var content: Content

    @State private var locked = false
    @State private var didEvaluateLaunch = false
    @State private var backgroundedAt: Date?
    @State private var unlockError: String?

    var body: some View {
        ZStack {
            content

            if locked {
                LockScreenOverlay(errorMessage: unlockError) {
                    Task { await unlock() }
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            guard !didEvaluateLaunch else { return }
            didEvaluateLaunch = true
            if settings.appProtection {
                locked = true
                Task { await unlock() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard settings.appProtection else { return }
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > Self.relockInterval {
                    locked = true
                    Task { await unlock() }
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    private func unlock() async {
        unlockError = nil
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set: nothing to protect with — fail open rather than
            // brick the app.
            locked = false
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock a-Terminal"
            )
            if success {
                locked = false
            }
        } catch {
            unlockError = "Authentication failed. Try again."
        }
    }
}

struct LockScreenOverlay: View {
    var errorMessage: String?
    var onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("a-Terminal is locked")
                    .font(.headline)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Unlock", action: onUnlock)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
