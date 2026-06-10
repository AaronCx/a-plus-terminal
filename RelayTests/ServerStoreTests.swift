import XCTest
@testable import Relay

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

        server.lastTmuxTarget = "main"
        server.knownHostKey = "ssh-ed25519 AAAAexample"
        store.update(server)

        let reloaded = ServerStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.servers.first?.lastTmuxTarget, "main")
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

    func testStoredJSONContainsNoPrivateKeyMaterial() throws {
        let store = ServerStore(fileURL: fileURL)
        store.add(Server(name: "Mac mini", host: "100.79.92.82", username: "acx", keyID: UUID()))

        let json = try String(contentsOf: fileURL, encoding: .utf8)
        // The server file references keys only by UUID — no key blobs.
        XCTAssertFalse(json.contains("PRIVATE KEY"))
        XCTAssertFalse(json.contains("ssh-ed25519"))
    }
}
