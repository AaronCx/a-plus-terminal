import Foundation
import UserNotifications

/// When an agent alert may post. Pure logic, no UNUserNotificationCenter —
/// the tests drive this directly, the shell below owns the system calls.
///
/// The policy mirrors the daemon's AgentNotifier reasoning rather than
/// reimplementing it differently: alert on the transition INTO waiting (and
/// the completion bell), never on "working" (it fires constantly), with a
/// 30-second per-session floor so a flapping agent cannot become a
/// notification storm.
struct AgentAlertPolicy {
    static let minimumInterval: TimeInterval = 30
    private var lastPosted: [UUID: Date] = [:]

    enum Trigger: Equatable {
        /// The agent moved INTO waiting from something else.
        case becameWaiting
        /// The terminal bell — agents ring it on completion.
        case bell
    }

    /// Decides, and records the post when it says yes.
    ///
    /// `appIsActive`: a user looking at the app does not need a banner about
    /// what they can see. `pipIsShowing`: same reasoning — the pop-out exists
    /// so they can watch; being told what they are watching is noise.
    mutating func shouldPost(
        session: UUID,
        trigger: Trigger,
        appIsActive: Bool,
        pipIsShowing: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !appIsActive, !pipIsShowing else { return false }
        if let last = lastPosted[session], now.timeIntervalSince(last) < Self.minimumInterval {
            return false
        }
        lastPosted[session] = now
        return true
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

    /// Called the first time an agent is DETECTED in any session — the moment
    /// notifications become meaningful, which is the sensible ask. Asking at
    /// first launch would be a permission dialog about a feature the user has
    /// not seen exist.
    func agentDetected() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    /// The agent in `session` needs the user. Posts when the policy allows.
    func agentNeedsYou(
        sessionID: UUID,
        serverID: UUID,
        serverName: String,
        meshyySessionName: String?,
        agentName: String?,
        trigger: AgentAlertPolicy.Trigger,
        appIsActive: Bool,
        pipIsShowing: Bool
    ) {
        guard policy.shouldPost(
            session: sessionID, trigger: trigger,
            appIsActive: appIsActive, pipIsShowing: pipIsShowing
        ) else { return }

        let content = UNMutableNotificationContent()
        let who = agentName ?? "The agent"
        content.title = trigger == .bell ? "\(who) finished" : "\(who) needs you"
        content.body = "In \(serverName). Tap to answer."
        content.sound = .default
        // The deep link lands the tap in the RIGHT session, not the app's
        // last state. By daemon session name when meshyy carries it — the
        // name outlives the tab — by session id otherwise.
        if let name = meshyySessionName {
            content.userInfo = ["url": "aplusterminal://server/\(serverID.uuidString)/session/\(name)"]
        } else {
            content.userInfo = ["url": "aplusterminal://session/\(sessionID.uuidString)"]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "agent-\(sessionID.uuidString)-\(trigger == .bell ? "bell" : "waiting")",
            content: content,
            trigger: nil
        ))
    }

    func sessionClosed(_ sessionID: UUID) {
        policy.forget(session: sessionID)
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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["url"] as? String, let url = URL(string: raw) else { return }
        openURL?(url)
    }
}
