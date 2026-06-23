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

    @MainActor
    static func applyIfRequested(servers: ServerStore, keys: KeyStore) {
        let env = ProcessInfo.processInfo.environment
        guard let json = env["APLUSTERMINAL_TEST_SERVER"],
              let pemBase64 = env["APLUSTERMINAL_TEST_PRIVATE_KEY"],
              let pemData = Data(base64Encoded: pemBase64),
              let pem = String(data: pemData, encoding: .utf8),
              let seed = try? JSONDecoder().decode(SeedServer.self, from: Data(json.utf8)) else {
            print("TESTSEED: guard 1 failed")
            return
        }
        guard !servers.servers.contains(where: { $0.name == seed.name }) else {
            print("TESTSEED: already seeded")
            return
        }
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
}
#endif
