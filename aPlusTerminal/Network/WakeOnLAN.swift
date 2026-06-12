import Foundation
import Network

/// Wake-on-LAN magic packet: 6×0xFF followed by the MAC address ×16.
enum WakeOnLAN {
    enum WoLError: LocalizedError, Equatable {
        case invalidMAC

        var errorDescription: String? {
            "Enter the MAC address as six pairs, e.g. aa:bb:cc:dd:ee:ff."
        }
    }

    /// Accepts colon-, dash-, or unseparated hex (case-insensitive).
    static func parseMAC(_ raw: String) throws -> [UInt8] {
        let hex = raw.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard hex.count == 12 else { throw WoLError.invalidMAC }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw WoLError.invalidMAC }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func magicPacket(mac: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: mac)
        }
        return packet
    }

    /// Sends the magic packet by UDP unicast to the server's address and, on
    /// networks where the OS allows it, the limited-broadcast address.
    /// iOS gates broadcast behind the multicast entitlement — the broadcast
    /// attempt failing is expected and harmless; unicast still wakes hosts
    /// whose ARP entry is alive on the router.
    static func wake(macAddress: String, host: String, port: UInt16 = 9) async throws {
        let packet = magicPacket(mac: try parseMAC(macAddress))
        await send(packet, to: host, port: port)
        await send(packet, to: "255.255.255.255", port: port)
    }

    private static func send(_ packet: Data, to host: String, port: UInt16) async {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        defer { connection.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = SendGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { _ in
                        resumed.resumeOnce { continuation.resume() }
                    })
                case .failed, .cancelled:
                    resumed.resumeOnce { continuation.resume() }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                resumed.resumeOnce { continuation.resume() }
            }
        }
    }
}

private final class SendGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
