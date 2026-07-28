import MeshyyCore
import MeshyyKit
import XCTest
@testable import aPlusTerminal

/// Drives a REAL meshyy session from an iOS process against a real `meshyyd`.
///
/// **Why this exists when meshyy has 176 tests of its own.** Every one of those runs
/// macOS-to-macOS, in one process, against a daemon it started itself. This app is the
/// first iOS client, and "Network framework QUIC works between two macOS processes" is
/// not evidence that it works from an iOS process to a macOS daemon. Different
/// platform, different sandbox, different network stack path. That gap is exactly the
/// kind that reaches TestFlight, so it is closed here before shipping rather than by a
/// user.
///
/// Skips cleanly with no fixtures, so CI stays green:
///
///     ./scripts/meshyy-live-fixtures.sh && make test
///
/// Tokens are single-use and short-TTL, so the fixtures must be minted immediately
/// before each run — a stale one is a refused attach, not a false pass.
@MainActor
final class MeshyyLiveTests: XCTestCase {
    /// One fixture per attach, because **a token is single-use**. The first version of
    /// this file handed the same fixture to both tests and the second attach was
    /// refused — which reads exactly like a broken transport and was a broken harness.
    ///
    /// Each test also uses its own session name, so one test shutting its session down
    /// cannot strand the other.
    /// A token older than this is past meshyy's 60s TTL and would be refused.
    ///
    /// Skipping on age rather than letting the attach fail is the difference between
    /// "these tests need setup" and "the transport is broken" — and the two look
    /// identical from a red X. `make test` builds before it runs, which is long enough
    /// to expire a token minted beforehand, so plain `make test` skips these and
    /// `make test-meshyy-live` (build → mint → run, in that order) runs them.
    private static let tokenTTL: TimeInterval = 45

    private func liveBootstrap(_ fixture: String) throws -> BootstrapResponse {
        let path = "/tmp/meshyy-live-\(fixture).json"
        guard let json = try? String(contentsOfFile: path, encoding: .utf8), !json.isEmpty else {
            throw XCTSkip("""
                no live meshyy bootstrap at \(path) — run `make test-meshyy-live`
                """)
        }
        let minted = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if let minted, Date().timeIntervalSince(minted) > Self.tokenTTL {
            throw XCTSkip("""
                the bootstrap at \(path) is \(Int(Date().timeIntervalSince(minted)))s old and \
                meshyy tokens expire after 60s — run `make test-meshyy-live`, which builds \
                first and mints second
                """)
        }
        return try BootstrapResponse.parse(json)
    }

    /// The whole point: an iOS process opens QUIC to the daemon, types, and sees the
    /// shell's answer come back.
    func testIOSClientDrivesARealDaemonOverQUIC() async throws {
        let bootstrap = try liveBootstrap("drive")
        try bootstrap.validate()

        let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
        let received = Received()
        let collector = Task {
            for await event in await session.events {
                if case .output(let bytes) = event { await received.append(bytes) }
            }
        }
        defer { collector.cancel() }

        try await session.attach(bootstrap: bootstrap, sshHost: "127.0.0.1")

        // A marker split in two, so the command's own echo cannot satisfy the
        // assertion — the same trick the QUIC transport tests use.
        let marker = "MESHYY" + "-IOS-LIVE-OK"
        try await session.send(Array("printf '%s%s\\n' 'MESHYY' '-IOS-LIVE-OK'\n".utf8))

        let arrived = await received.waitForText(marker, timeout: 25)
        let text = await received.text
        XCTAssertTrue(
            arrived,
            "an iOS process could not drive a real meshyyd over QUIC. Got: \(text.suffix(400).debugDescription)"
        )

        await session.shutdown(reason: "test finished")
    }

    /// The property the whole feature is for: bytes produced while the client is away
    /// are replayed when it comes back.
    ///
    /// This is what an SSH session structurally cannot do — a dropped SSH connection
    /// has lost that output — so it is the one behaviour worth proving on the real
    /// thing rather than trusting from a unit test.
    func testOutputProducedWhileDetachedIsReplayedOnReattach() async throws {
        let bootstrap = try liveBootstrap("replay-a")
        let session = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
        let received = Received()
        let collector = Task {
            for await event in await session.events {
                if case .output(let bytes) = event { await received.append(bytes) }
            }
        }
        defer { collector.cancel() }

        try await session.attach(bootstrap: bootstrap, sshHost: "127.0.0.1")
        // Wait for the shell to be live rather than for a specific prompt character —
        // the prompt is whatever the user's shell renders, and asserting on "$" made
        // this hang for 15s on a zsh "%" before failing for the wrong reason.
        try await session.send(Array("printf '%s%s\\n' 'SHELL' '-READY'\n".utf8))
        // Hoisted: XCTAssert's autoclosure cannot be async.
        let shellReady = await received.waitForText("SHELL-READY", timeout: 20)
        XCTAssertTrue(shellReady, "the shell never came up, so there is nothing to detach from")

        // Ask for output that lands AFTER we are gone, then leave. `detach` keeps the
        // daemon's shell running and its ring buffer filling — that is the difference
        // from `shutdown`.
        try await session.send(Array("(sleep 2; printf '%s%s\\n' 'WHILE' '-AWAY-42') &\n".utf8))
        try await Task.sleep(for: .milliseconds(300))
        await session.detach(reason: "test detaching")

        // Gone for long enough that the output is definitely produced without us.
        try await Task.sleep(for: .seconds(4))

        // A fresh token — they are single-use — and reattach to the same session.
        let second = try liveBootstrap("replay-b")
        try await session.attach(bootstrap: second, sshHost: "127.0.0.1")

        let replayed = await received.waitForText("WHILE-AWAY-42", timeout: 25)
        let text = await received.text
        XCTAssertTrue(
            replayed,
            "output produced while detached was not replayed — the one thing meshyy "
                + "exists to do. Got: \(text.suffix(400).debugDescription)"
        )
        await session.shutdown(reason: "test finished")
    }
}

extension MeshyyLiveTests {
    /// THE REPORTED SCENARIO: close the app, open it again, and find your shell.
    ///
    /// This differs from the detach/reattach test above in the way that matters. That
    /// one keeps ONE `MeshyySession` alive across the gap, so `consumedOffset` survives
    /// and the daemon replays precisely what was missed. This one builds a COMPLETELY
    /// NEW session, which is what an app relaunch does: offset 0, no history, exactly
    /// the state a user gets when they kill the app and reopen it.
    ///
    /// Written because the feature was reported as "not staying in shell, it's just
    /// booting a new shell". The daemon side checks out — the pty survives, the pid is
    /// stable across attaches — so the question is what a fresh client actually SEES,
    /// and that is a different code path (`freshAttach`, which replays from the
    /// clear-screen anchor) than the one the other test covers.
    func testAFreshClientSeesTheExistingSessionRatherThanANewShell() async throws {
        let first = try liveBootstrap("relaunch-a")
        let sessionA = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
        let receivedA = Received()
        let collectorA = Task {
            for await event in await sessionA.events {
                if case .output(let bytes) = event { await receivedA.append(bytes) }
            }
        }
        defer { collectorA.cancel() }

        try await sessionA.attach(bootstrap: first, sshHost: "127.0.0.1")
        try await sessionA.send(Array("printf '%s%s\\n' 'BEFORE' '-RELAUNCH-77'\n".utf8))
        let printed = await receivedA.waitForText("BEFORE-RELAUNCH-77", timeout: 20)
        XCTAssertTrue(printed, "the marker never printed, so there is nothing to come back to")

        // The app goes away WITHOUT ending the session — a detach, which is what
        // suspend does now.
        await sessionA.detach(reason: "app relaunching")
        collectorA.cancel()
        try await Task.sleep(for: .seconds(1))

        // A brand-new client. No offset, no history — an app that was just launched.
        let second = try liveBootstrap("relaunch-b")
        let sessionB = MeshyySession(size: TerminalSize(cols: 80, rows: 24))
        let receivedB = Received()
        let collectorB = Task {
            for await event in await sessionB.events {
                if case .output(let bytes) = event { await receivedB.append(bytes) }
            }
        }
        defer { collectorB.cancel() }
        try await sessionB.attach(bootstrap: second, sshHost: "127.0.0.1")

        let sawIt = await receivedB.waitForText("BEFORE-RELAUNCH-77", timeout: 20)
        let text = await receivedB.text
        XCTAssertTrue(sawIt, """
            a freshly-launched client did NOT see what the session had already printed — \
            it looks like a new shell even though the daemon still holds the old one. \
            Got: \(text.suffix(300).debugDescription)
            """)

        // And it must be usable, not just a replayed picture.
        try await sessionB.send(Array("printf '%s%s\\n' 'AFTER' '-RELAUNCH-88'\n".utf8))
        let live = await receivedB.waitForText("AFTER-RELAUNCH-88", timeout: 20)
        XCTAssertTrue(live, "the reattached session does not accept input — it is a picture, not a shell")
        await sessionB.shutdown(reason: "test finished")
    }
}

/// Accumulates delivered bytes off the session's event stream.
private actor Received {
    private var bytes: [UInt8] = []

    func append(_ chunk: [UInt8]) { bytes += chunk }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    func waitForText(_ needle: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return text.contains(needle)
    }
}
