#if DEBUG
import Foundation

/// DEBUG-only launch seeding for live UI tests: lets the test harness inject
/// a server entry and SSH key via launch environment, so XCUITests can drive
/// a real SSH session without scripting the onboarding UI. Compiled out of
/// release builds entirely.
enum TestSeed {
    struct SeedServer: Decodable {
        let name: String
        let host: String
        let port: Int
        let username: String
    }

    /// VNC live QA: seed a monitor server (credentials via env, Keychain-
    /// backed like production), auto-open it, and optionally auto-enable
    /// Control and inject one tap — the headless end-to-end loop that lets
    /// the harness SEE the cursor overlay and verify input against a real
    /// host before anything ships.
    @MainActor
    static func applyVNCIfRequested(servers: ServerStore, passwords: PasswordStore, vncManager: VNCMonitorManager) {
        let env = ProcessInfo.processInfo.environment
        guard let json = env["APLUSTERMINAL_TEST_VNC_SERVER"],
              let seed = try? JSONDecoder().decode(SeedServer.self, from: Data(json.utf8)) else { return }
        var server = servers.servers.first(where: { $0.name == seed.name && $0.kind == .vncMonitor })
            ?? Server(name: seed.name, host: seed.host, port: seed.port, username: seed.username,
                      kind: .vncMonitor, vncAuthMethod: .ard)
        if let password = env["APLUSTERMINAL_TEST_VNC_PASSWORD"], !password.isEmpty {
            let ref = server.passwordRef ?? UUID()
            try? passwords.setPassword(password, for: ref)
            server.passwordRef = ref
        }
        // Link the seeded SSH server as the cursor bridge (harness verifies
        // the physical-pointer overlay end to end).
        if env["APLUSTERMINAL_TEST_VNC_LINK_SSH"] == "1",
           let sshSeed = servers.servers.first(where: { $0.kind == .ssh }) {
            server.cursorBridgeSSHServerID = sshSeed.id
        }
        if servers.server(for: server.id) == nil {
            servers.add(server)
        } else {
            servers.update(server)
        }
        print("TESTSEED: vnc monitor seeded")
        guard let openMS = env["APLUSTERMINAL_TEST_VNC_AUTOOPEN_MS"].flatMap(UInt64.init) else { return }
        let seededServer = server
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: openMS * 1_000_000)
            let session = vncManager.open(server: seededServer)
            print("TESTSEED: vnc monitor opened")
            // "x,y,delayMs" — enable Control and tap once.
            if let tap = env["APLUSTERMINAL_TEST_VNC_AUTOTAP"] {
                let parts = tap.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 3 else { return }
                try? await Task.sleep(nanoseconds: UInt64(parts[2]) * 1_000_000)
                session.setControlEnabled(true)
                session.sendTap(at: CGPoint(x: parts[0], y: parts[1]))
                print("TESTSEED: vnc autotap sent at \(parts[0]),\(parts[1])")
            }
        }
    }

    @MainActor
    static func applyIfRequested(servers: ServerStore, keys: KeyStore, router: DeepLinkRouter, settings: AppSettings? = nil) {
        let env = ProcessInfo.processInfo.environment
        // Pop-out live QA: enable the beta toggles from the environment so a
        // headless harness (devicectl launch, no UI driving) can exercise
        // the system auto-pop-out path end to end.
        if env["APLUSTERMINAL_TEST_ENABLE_POPOUT"] == "1", let settings {
            settings.popOutSessions = true
            settings.autoPopOutOnAppSwitch = true
            print("TESTSEED: pop-out toggles enabled")
        }
        guard let json = env["APLUSTERMINAL_TEST_SERVER"],
              let pemBase64 = env["APLUSTERMINAL_TEST_PRIVATE_KEY"],
              let pemData = Data(base64Encoded: pemBase64),
              let pem = String(data: pemData, encoding: .utf8),
              let seed = try? JSONDecoder().decode(SeedServer.self, from: Data(json.utf8)) else {
            print("TESTSEED: guard 1 failed")
            return
        }
        // Seed only when the server is absent — but fall through either way so
        // the connect trigger below schedules whether the server was inserted
        // this launch or survived from a previous run.
        if servers.servers.contains(where: { $0.name == seed.name }) {
            print("TESTSEED: already seeded")
        } else {
            // Reuse an existing seeded key rather than importing a duplicate: the
            // server could have been deleted while the "uitest" key persisted, and
            // re-importing every launch would accumulate orphaned keys.
            let keyID: UUID
            if let existing = keys.keys.first(where: { $0.name == "uitest" }) {
                keyID = existing.id
            } else {
                do {
                    keyID = try keys.importKey(named: "uitest", openSSHPrivateKey: pem).id
                } catch {
                    print("TESTSEED: import failed \(error)")
                    return
                }
            }
            servers.add(Server(name: seed.name, host: seed.host, port: seed.port, username: seed.username, keyID: keyID))
            print("TESTSEED: seeded ok")
        }

        // UI-test hook: after a delay, fire the same router request an App
        // Intent or aplusterminal://connect deep link produces — the exact
        // production path (connectServerID → onChange → consume), so tests
        // can reproduce deep-link-while-on-Settings without Shortcuts/APNs.
        if let msString = env["APLUSTERMINAL_TEST_CONNECT_AFTER_MS"], let ms = UInt64(msString),
           let seeded = servers.servers.first(where: { $0.name == seed.name }) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                print("TESTSEED: firing connect request for \(seeded.name)")
                router.requestConnect(toServer: seeded.id)
            }
        }
    }
}
#endif
