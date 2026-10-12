import Foundation
import UserNotifications

/// When an agent alert may post. Pure logic, no UNUserNotificationCenter —
/// the tests drive this directly, the shell below owns the system calls.
///
/// The policy is the LAST gate. What reaches it is already an explicit signal
/// from the agent (`TerminalSession.noteAgentSignal`) — never the timing
/// heuristic — and it adds a 30-second per-session floor so a chatty agent
/// cannot become a notification storm.
struct AgentAlertPolicy {
    static let minimumInterval: TimeInterval = 30
    /// The floor this instance applies. The static default everywhere except
    /// DEBUG live tests, which lower it so repeats are counted, not masked.
    var minimumInterval: TimeInterval = AgentAlertPolicy.minimumInterval
    private var lastPosted: [UUID: Date] = [:]

    enum Trigger: Equatable {
        /// A bare BEL: the agent wants attention and did not say why.
        case bell
        /// OSC 9 / OSC 777: the agent's own words.
        case message(title: String?, body: String)
        /// OSC 7501 `blocked`: it needs an answer (permission, question, auth).
        case blocked(kind: String?)
        /// OSC 7501 `done`: the turn finished.
        case finished

        /// Request-identifier suffix: one pending banner per kind per session.
        var slug: String {
            switch self {
            case .bell: return "bell"
            case .message: return "message"
            case .blocked: return "blocked"
            case .finished: return "finished"
            }
        }
    }

    /// What the policy decided, with the reason when it said no — logged, so
    /// a missing (or extra) notification can be explained after the fact.
    enum Decision: Equatable {
        case post
        case appActive
        case pipShowing
        case floor
    }

    /// Decides, and records the post when it says yes.
    ///
    /// `appIsActive`: a user looking at the app does not need a banner about
    /// what they can see. `pipIsShowing`: same reasoning — the pop-out exists
    /// so they can watch; being told what they are watching is noise.
    mutating func decide(
        session: UUID,
        trigger: Trigger,
        appIsActive: Bool,
        pipIsShowing: Bool,
        now: Date = Date()
    ) -> Decision {
        if appIsActive { return .appActive }
        if pipIsShowing { return .pipShowing }
        if let last = lastPosted[session], now.timeIntervalSince(last) < minimumInterval {
            return .floor
        }
        lastPosted[session] = now
        return .post
    }

    mutating func shouldPost(
        session: UUID,
        trigger: Trigger,
        appIsActive: Bool,
        pipIsShowing: Bool,
        now: Date = Date()
    ) -> Bool {
        decide(session: session, trigger: trigger, appIsActive: appIsActive,
               pipIsShowing: pipIsShowing, now: now) == .post
    }

    mutating func forget(session: UUID) {
        lastPosted.removeValue(forKey: session)
    }
}

/// The UNUserNotificationCenter shell. Owns authorization and posting;
/// decisions belong to the policy above.
@MainActor
final class AgentAlertCenter: NSObject {
    static let shared = AgentAlertCenter()

    private var policy = AgentAlertPolicy()
    private var authorizationRequested = false
    /// Injected in tests; the real router in the app.
    var openURL: ((URL) -> Void)?

    override init() {
        super.init()
        #if DEBUG
        if let floor = AgentAlertProbe.floorOverride {
            policy.minimumInterval = floor
        }
        #endif
    }

    /// Called the first time an agent is DETECTED in any session — a profile
    /// marker matched, or a program announced itself over OSC 7501 — the
    /// moment notifications become meaningful, which is the sensible ask.
    /// Asking at first launch would be a permission dialog about a feature
    /// the user has not seen exist.
    func agentDetected() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    /// The agent in `session` needs the user. Posts when the policy allows.
    /// `daemonSessionName` is the resumable transport's session name when one
    /// carries the session; always nil in a build without it (`MESHYY` unset).
    func agentNeedsYou(
        sessionID: UUID,
        serverID: UUID,
        serverName: String,
        daemonSessionName: String?,
        agentName: String?,
        trigger: AgentAlertPolicy.Trigger,
        appIsActive: Bool,
        pipIsShowing: Bool
    ) {
        let decision = policy.decide(
            session: sessionID, trigger: trigger,
            appIsActive: appIsActive, pipIsShowing: pipIsShowing
        )
        agentAlertLog.notice("policy session=\(sessionID.logTag, privacy: .public) trigger=\(String(describing: trigger), privacy: .public) decision=\(String(describing: decision), privacy: .public) appActive=\(appIsActive, privacy: .public) pip=\(pipIsShowing, privacy: .public)")
        #if DEBUG
        AgentAlertProbe.shared.noteWouldPost()
        #endif
        guard decision == .post else { return }

        let content = Self.content(for: trigger, agentName: agentName, serverName: serverName)
        // The deep link lands the tap in the RIGHT session, not the app's
        // last state. By daemon session name when meshyy carries it — the
        // name outlives the tab — by session id otherwise.
        #if MESHYY
        if let name = daemonSessionName {
            content.userInfo = ["url": "aplusterminal://server/\(serverID.uuidString)/session/\(name)"]
        } else {
            content.userInfo = ["url": "aplusterminal://session/\(sessionID.uuidString)"]
        }
        #else
        content.userInfo = ["url": "aplusterminal://session/\(sessionID.uuidString)"]
        #endif
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "agent-\(sessionID.uuidString)-\(trigger.slug)",
            content: content,
            trigger: nil
        ))
        agentAlertLog.notice("posted session=\(sessionID.logTag, privacy: .public) trigger=\(String(describing: trigger), privacy: .public)")
        #if DEBUG
        AgentAlertProbe.shared.notePost()
        #endif
    }

    /// Title and body for one trigger. A bare bell says only that the agent
    /// wants attention — Claude Code rings the same bell for "may I?" and for
    /// "done", so claiming either would be a guess.
    static func content(for trigger: AgentAlertPolicy.Trigger, agentName: String?, serverName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let who = agentName ?? "The agent"
        switch trigger {
        case .bell:
            content.title = "\(who) wants your attention"
            content.body = "In \(serverName). Tap to open the session."
        case .message(let title, let body):
            content.title = title ?? who
            content.body = body.isEmpty ? "In \(serverName)." : "\(body) — \(serverName)"
        case .blocked(let kind):
            content.title = "\(who) needs you"
            switch kind {
            case "permission": content.body = "Waiting for your permission in \(serverName)."
            case "question": content.body = "Waiting for your answer in \(serverName)."
            case "auth": content.body = "Needs you to sign in again in \(serverName)."
            default: content.body = "In \(serverName). Tap to answer."
            }
        case .finished:
            content.title = "\(who) finished"
            content.body = "In \(serverName)."
        }
        content.sound = .default
        return content
    }

    func sessionClosed(_ sessionID: UUID) {
        policy.forget(session: sessionID)
    }

    // MARK: - Test notification

    static let testNotificationID = "agent-test"
    /// Long enough to leave the app and see it land on the Lock Screen or as
    /// a banner; it also shows in the foreground (see `willPresent`).
    static let testNotificationDelay: TimeInterval = 5

    enum TestNotificationResult: Equatable {
        case scheduled
        /// Notifications are off for the app; only iOS Settings can fix it.
        case denied
    }

    /// Settings → Notifications → "Send test notification": asks for
    /// permission if it was never asked, then schedules a clearly-labelled
    /// notification a few seconds out.
    func sendTestNotification() async -> TestNotificationResult {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            authorizationRequested = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            return .denied
        }
        let content = UNMutableNotificationContent()
        content.title = "Test notification"
        content.body = "This is how a+Terminal tells you an agent needs you."
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: Self.testNotificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Self.testNotificationDelay, repeats: false)
        ))
        agentAlertLog.notice("test notification scheduled")
        return .scheduled
    }
}

extension AgentAlertCenter: @preconcurrency UNUserNotificationCenterDelegate {
    /// A tap on the notification routes its deep link.
    ///
    /// NOT `nonisolated` — that one keyword was the crash-on-every-tap. The
    /// compiler's ObjC bridge awaits this method and then invokes UIKit's
    /// completion handler on whatever executor the task ended on; nonisolated
    /// ended it on the cooperative pool, and UIKit's completion performs a
    /// state-restoration snapshot that hard-asserts the main thread →
    /// NSException → abort, ~70ms AFTER the deep link had already routed
    /// successfully. Inheriting the class's @MainActor makes the bridge hop
    /// to main before it calls back into UIKit. Reproduced 3-for-3 in the
    /// simulator, with and without a matching server; the openurl path never
    /// crashed because it has no UIKit completion to misdeliver.
    /// Agent alerts never reach here — the policy does not post while the
    /// app is active — but the test notification may land with the user
    /// still in Settings, and a test that shows nothing proves nothing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier == Self.testNotificationID ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["url"] as? String, let url = URL(string: raw) else { return }
        openURL?(url)
    }
}
