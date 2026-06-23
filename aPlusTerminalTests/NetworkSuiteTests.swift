import XCTest
import Network
@testable import aPlusTerminal

final class WakeOnLANTests: XCTestCase {
    func testParseMACAcceptsCommonFormats() throws {
        let expected: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        XCTAssertEqual(try WakeOnLAN.parseMAC("aa:bb:cc:dd:ee:ff"), expected)
        XCTAssertEqual(try WakeOnLAN.parseMAC("AA-BB-CC-DD-EE-FF"), expected)
        XCTAssertEqual(try WakeOnLAN.parseMAC("aabbccddeeff"), expected)
        XCTAssertEqual(try WakeOnLAN.parseMAC("  aa:bb:cc:dd:ee:ff  "), expected)
    }

    func testParseMACRejectsBadInput() {
        for bad in ["", "aa:bb:cc", "zz:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:ff:00"] {
            XCTAssertThrowsError(try WakeOnLAN.parseMAC(bad), bad)
        }
    }

    func testMagicPacketLayout() throws {
        let mac = try WakeOnLAN.parseMAC("01:02:03:04:05:06")
        let packet = WakeOnLAN.magicPacket(mac: mac)
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        for repetition in 0..<16 {
            let start = 6 + repetition * 6
            XCTAssertEqual(Array(packet[start..<(start + 6)]), mac, "repetition \(repetition)")
        }
    }
}

final class ReachabilityTests: XCTestCase {
    /// A live local listener must read as reachable — hermetic, no sshd needed.
    func testOpenPortIsReachable() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        defer { listener.cancel() }

        // Wait for the listener to bind and publish its port.
        var port: UInt16 = 0
        for _ in 0..<50 {
            if let bound = listener.port?.rawValue, bound != 0 {
                port = bound
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotEqual(port, 0, "listener never bound")

        let up = await ServerReachability.isReachable(host: "127.0.0.1", port: Int(port), timeout: 3)
        XCTAssertTrue(up)
    }

    func testClosedPortIsUnreachable() async {
        // Reserve a port by binding a listener, then close it — nothing is
        // listening there for the duration of the probe.
        let listener = try? NWListener(using: .tcp, on: .any)
        listener?.start(queue: .global())
        var port: UInt16 = 1
        for _ in 0..<50 where (listener?.port?.rawValue ?? 0) == 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        port = listener?.port?.rawValue ?? 1
        listener?.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let up = await ServerReachability.isReachable(host: "127.0.0.1", port: Int(port), timeout: 2)
        XCTAssertFalse(up)
    }
}

final class ServerModelTests: XCTestCase {
    /// Server lists saved by builds that predate macAddress must keep decoding.
    func testLegacyServerJSONDecodesWithoutMACAddress() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"mini",
          "host":"10.0.0.2","port":22,"username":"user"}]
        """
        let servers = try JSONDecoder().decode([Server].self, from: Data(legacy.utf8))
        XCTAssertEqual(servers.count, 1)
        XCTAssertNil(servers[0].macAddress)
        XCTAssertEqual(servers[0].displayAddress, "10.0.0.2")
    }

    func testMACAddressRoundTripsThroughJSON() throws {
        var server = Server(name: "mini", host: "10.0.0.2", username: "user")
        server.macAddress = "aa:bb:cc:dd:ee:ff"
        let data = try JSONEncoder().encode([server])
        let decoded = try JSONDecoder().decode([Server].self, from: data)
        XCTAssertEqual(decoded[0].macAddress, "aa:bb:cc:dd:ee:ff")
    }
}
