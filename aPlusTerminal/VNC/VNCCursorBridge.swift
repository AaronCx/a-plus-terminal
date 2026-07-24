import CoreGraphics
import Foundation
import os

/// Streams the remote Mac's REAL pointer position into a VNC monitor over
/// SSH. macOS screen sharing tells a VNC client nothing about the cursor
/// (probe-verified: no compositing, no shape, no position), so without this
/// the overlay can only show positions the app itself injected. When the
/// user links their saved SSH server for the same machine, a single exec
/// channel runs one persistent JXA process that emits "x,y,screenW,screenH"
/// lines (top-left origin) a few times a second — the overlay then tracks
/// the physical mouse and anything host-side automation moves.
@MainActor
final class VNCCursorBridge {
    /// One persistent osascript (no per-sample process spawn); JXA `delay`
    /// paces it. stdout writes are unbuffered so lines stream immediately.
    static let remoteCommand = #"""
    osascript -l JavaScript -e 'ObjC.import("Cocoa");var out=$.NSFileHandle.fileHandleWithStandardOutput;while(true){var p=$.NSEvent.mouseLocation;var f=$.NSScreen.mainScreen.frame.size;var s=Math.round(p.x)+","+Math.round(f.height-p.y)+","+Math.round(f.width)+","+Math.round(f.height)+"\n";out.writeData($(s).dataUsingEncoding($.NSUTF8StringEncoding));delay(0.25)}'
    """#

    /// A parsed sample: pointer position and the host screen size it lives
    /// in, both in the host's points, top-left origin.
    struct Sample: Equatable {
        var position: CGPoint
        var screen: CGSize
    }

    /// "x,y,w,h" → Sample. Nil on malformed lines (never trusts the wire).
    nonisolated static func parse(line: String) -> Sample? {
        let parts = line.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0,
              parts.allSatisfy({ $0.isFinite }) else { return nil }
        return Sample(
            position: CGPoint(x: parts[0], y: parts[1]),
            screen: CGSize(width: parts[2], height: parts[3])
        )
    }

    /// Host-screen sample → framebuffer pixels (they differ on Retina hosts
    /// where the framebuffer is the pixel grid).
    nonisolated static func framebufferPoint(for sample: Sample, framebuffer: CGSize) -> CGPoint {
        CGPoint(
            x: sample.position.x / sample.screen.width * framebuffer.width,
            y: sample.position.y / sample.screen.height * framebuffer.height
        )
    }

    private let log = Logger(subsystem: "com.aaroncx.aplusterminal", category: "vnc-cursor-bridge")
    private let makeLines: () async throws -> AsyncThrowingStream<String, Error>
    private var task: Task<Void, Never>?

    /// Fired (main actor) per sample.
    var onSample: ((Sample) -> Void)?

    /// `makeLines` seam: production connects SSH and streams the remote
    /// command; tests inject scripted lines.
    init(makeLines: @escaping () async throws -> AsyncThrowingStream<String, Error>) {
        self.makeLines = makeLines
    }

    /// Production factory: dedicated SSH connection with the linked server's
    /// stored credentials (mirrors the terminal path's resolution).
    static func forLinkedServer(
        _ server: Server,
        keyStore: KeyStore,
        passwords: PasswordStore
    ) -> VNCCursorBridge {
        VNCCursorBridge {
            let auth: SSHConnection.AuthMethod
            if let keyID = server.keyID {
                auth = .key(try keyStore.storedPrivateKey(for: keyID))
            } else if let ref = server.passwordRef, let password = passwords.password(for: ref) {
                auth = .password(password)
            } else {
                throw SSHConnectionError.notConnected
            }
            let connection = SSHConnection()
            try await connection.connect(SSHConnection.Configuration(
                host: server.host,
                port: server.port,
                username: server.username,
                auth: auth,
                knownHostKey: server.knownHostKey,
                connectTimeout: 15
            ))
            return try await connection.streamCommandLines(VNCCursorBridge.remoteCommand)
        }
    }

    /// One connect attempt + one quiet retry; a dead bridge degrades to the
    /// build-34 behavior (injected-position-only cursor), never to an error
    /// card — the monitor itself is unaffected.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            for attempt in 1...2 {
                guard let self, !Task.isCancelled else { return }
                do {
                    let lines = try await self.makeLines()
                    for try await line in lines {
                        guard !Task.isCancelled else { return }
                        if let sample = Self.parse(line: line) {
                            self.onSample?(sample)
                        }
                    }
                } catch {
                    self.log.info("cursor bridge attempt \(attempt) ended: \(error.localizedDescription, privacy: .public)")
                }
                if attempt == 1 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            self?.log.info("cursor bridge offline — overlay falls back to injected positions")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
