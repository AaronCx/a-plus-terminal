import XCTest
@testable import aPlusTerminal

final class ServerStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("servers-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(ServerStore(fileURL: fileURL).servers.isEmpty)
    }

    func testMigratesLegacyTmuxTargetKey() throws {
        // A server saved by a pre-refactor build used "lastTmuxTarget".
        let json = """
        {"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,"username":"u","lastTmuxTarget":"work"}
        """
        let server = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
        XCTAssertEqual(server.lastMultiplexerTarget, "work", "legacy lastTmuxTarget must migrate")

        // And it re-encodes under the new key only (no legacy key leaks back).
        let reencoded = try JSONEncoder().encode(server)
        let dict = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertEqual(dict?["lastMultiplexerTarget"] as? String, "work")
        XCTAssertNil(dict?["lastTmuxTarget"], "must not re-write the legacy key")
    }

    func testAddPersistsAcrossInstances() {
        let store = ServerStore(fileURL: fileURL)
        let server = Server(name: "Mac mini", host: "100.79.92.82", username: "acx", keyID: UUID())
        store.add(server)

        let reloaded = ServerStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.servers, [server])
    }

    func testUpdateReplacesMatchingServer() {
        let store = ServerStore(fileURL: fileURL)
        var server = Server(name: "Mac mini", host: "100.79.92.82", username: "acx")
        store.add(server)

        server.lastMultiplexerTarget = "main"
        server.knownHostKey = "ssh-ed25519 AAAAexample"
        store.update(server)

        let reloaded = ServerStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.servers.first?.lastMultiplexerTarget, "main")
        XCTAssertEqual(reloaded.servers.first?.knownHostKey, "ssh-ed25519 AAAAexample")
    }

    func testRemoveDeletesServer() {
        let store = ServerStore(fileURL: fileURL)
        let server = Server(name: "Mac mini", host: "100.79.92.82", username: "acx")
        store.add(server)
        store.remove(id: server.id)

        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertTrue(ServerStore(fileURL: fileURL).servers.isEmpty)
    }

    func testDisplayAddressOmitsDefaultPort() {
        XCTAssertEqual(Server(name: "a", host: "h", username: "u").displayAddress, "h")
        XCTAssertEqual(Server(name: "a", host: "h", port: 2222, username: "u").displayAddress, "h:2222")
    }

    func testGroupPersists() {
        let store = ServerStore(fileURL: fileURL)
        var server = Server(name: "mini", host: "h", username: "u")
        server.group = "Home"
        store.add(server)
        XCTAssertEqual(ServerStore(fileURL: fileURL).servers.first?.group, "Home")
    }

    func testLegacyJSONWithoutPasswordRefDecodes() throws {
        // Server lists written before password auth existed must keep loading.
        let legacy = """
        [{"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,"username":"u"}]
        """
        try legacy.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ServerStore(fileURL: fileURL)
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertNil(store.servers[0].passwordRef)
    }

    func testStoredJSONContainsNoPrivateKeyMaterial() throws {
        let store = ServerStore(fileURL: fileURL)
        store.add(Server(name: "Mac mini", host: "100.79.92.82", username: "acx", keyID: UUID()))

        let json = try String(contentsOf: fileURL, encoding: .utf8)
        // The server file references keys only by UUID — no key blobs.
        XCTAssertFalse(json.contains("PRIVATE KEY"))
        XCTAssertFalse(json.contains("ssh-ed25519"))
    }
}
