import SwiftUI
import UniformTypeIdentifiers

/// Settings → Diagnostics → Scroll trace. Everything here is local until the
/// user shares it: the system share sheet, or an upload to a connected
/// server's SFTP inbox over that session's own SSH connection.
struct ScrollTraceView: View {
    @Environment(ScrollTraceStore.self) private var store
    @Environment(SessionManager.self) private var sessions

    @State private var confirmClear = false
    /// Per-session outcome of "Send to inbox", shown inline.
    @State private var inboxResults: [UUID: String] = [:]
    @State private var sending: Set<UUID> = []

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Toggle("Record scroll trace", isOn: $store.isEnabled)
                    .accessibilityIdentifier("scrollTrace.toggle")
            } footer: {
                Text("Recorded only on this iPhone. Nothing leaves it unless you share it.")
            }

            Section("Recorded") {
                LabeledContent("Records", value: "\(store.records.count)")
                LabeledContent("Newest", value: newestText)
                ForEach(recentRecords) { record in
                    Text(Self.summary(of: record))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                ShareLink(
                    item: ScrollTraceExport(store: store),
                    preview: SharePreview("a+Terminal scroll trace")
                ) {
                    Label("Share trace", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("scrollTrace.share")

                ForEach(Array(connectedSessions.enumerated()), id: \.element.id) { index, session in
                    Button {
                        send(to: session)
                    } label: {
                        Label("Send to \(session.server.name) inbox", systemImage: "tray.and.arrow.up")
                    }
                    .disabled(sending.contains(session.id))
                    .accessibilityIdentifier("scrollTrace.sendInbox.\(index)")
                    if let result = inboxResults[session.id] {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Share")
            } footer: {
                Text("\"Send to inbox\" uploads the trace over that session's SSH connection to ~/.aplusterminal-inbox/ on the server. Nothing is typed into the terminal.")
            }

            Section {
                Button("Clear trace", role: .destructive) {
                    confirmClear = true
                }
                .accessibilityIdentifier("scrollTrace.clear")
            }
        }
        .navigationTitle("Scroll trace")
        .confirmationDialog("Clear the scroll trace?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear trace", role: .destructive) {
                store.clear()
            }
        } message: {
            Text("Deletes all \(store.records.count) records from this iPhone.")
        }
    }

    private var connectedSessions: [TerminalSession] {
        sessions.sessions.filter { $0.state == .connected }
    }

    private var recentRecords: [ScrollTrace.Record] {
        Array(store.records.suffix(5).reversed())
    }

    private var newestText: String {
        guard let newest = store.records.last else { return "—" }
        return newest.startedAt.formatted(date: .abbreviated, time: .standard)
    }

    private func send(to session: TerminalSession) {
        sending.insert(session.id)
        inboxResults[session.id] = "Sending…"
        Task {
            defer { sending.remove(session.id) }
            do {
                let data = try await store.exportData()
                let path = try await session.uploadDiagnostic(data, filename: ScrollTraceStore.exportFileName())
                inboxResults[session.id] = "Sent to \(path)"
            } catch {
                inboxResults[session.id] = "Failed: \(error.localizedDescription)"
            }
        }
    }

    /// One line per record: time, route, transport, state, belief.
    static func summary(of record: ScrollTrace.Record) -> String {
        let time = record.startedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
        let route = record.declineReason.map { "declined(\($0.rawValue))" } ?? record.route.rawValue
        var line = "\(time) \(route) \(record.transport.rawValue) \(record.transportState.rawValue)"
        if record.meshyyTransportFinished == true {
            line += "(finished, tab \(record.rawSessionState))"
        }
        if let belief = record.belief {
            line += " · mouse \(belief.mouseMode) alt \(belief.altScreen ? "on" : "off") kb \(belief.keyboardVisible ? "on" : "off")"
            if belief.isScrolledBack == true {
                line += " scrolled-back"
            }
            if let pty = record.lastPtyResize,
               !pty.ok || pty.rows != belief.rows || pty.cols != belief.cols {
                line += " · pty \(pty.cols)x\(pty.rows)\(pty.ok ? "" : " failed") vs \(belief.cols)x\(belief.rows)"
            }
        }
        if record.totalBytes > 0 {
            line += " · \(record.totalBytes)B"
        }
        if let latency = record.maxSendLatencyMs, latency >= 250 {
            line += " · send waited \(latency)ms"
        }
        if record.sendOK > 0 {
            line += record.msToFirstInboundAfterSend.map { " · reply \($0)ms" } ?? " · no reply"
        }
        if record.sendFailed > 0 {
            line += " · \(record.sendFailed) send failed"
        }
        return line
    }
}

/// The trace as a `.json` file for the share sheet, written when the share
/// actually happens (so it is never stale).
struct ScrollTraceExport: Transferable {
    let store: ScrollTraceStore

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { export in
            SentTransferredFile(try await export.makeFile())
        }
    }

    @MainActor
    private func makeFile() async throws -> URL {
        try await store.exportFileURL()
    }
}

/// Races a user-initiated diagnostics upload against a deadline. The upload
/// is cancelled on timeout but not awaited: a socket that never answers must
/// not keep the button spinning.
enum DiagnosticUploadRace {
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "SSH connection not responding" }
    }

    @MainActor
    static func run(
        timeout: Duration,
        _ operation: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        final class Once {
            var continuation: CheckedContinuation<String, Error>?
            func resume(_ result: Result<String, Error>) {
                continuation?.resume(with: result)
                continuation = nil
            }
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            once.continuation = continuation
            let work = Task { @MainActor in
                do {
                    once.resume(.success(try await operation()))
                } catch {
                    once.resume(.failure(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard once.continuation != nil else { return }
                work.cancel()
                once.resume(.failure(TimedOut()))
            }
        }
    }
}
