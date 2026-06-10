import SwiftUI

/// Push-to-talk sheet (§4.4): live waveform, streaming transcript preview,
/// Insert / Insert + Return / Cancel. "Insert + Return" is the "dictate a
/// prompt to Claude Code and send it" path.
struct DictationSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Receives the final text; `appendReturn` adds the trailing newline.
    var onInsert: (String, _ appendReturn: Bool) -> Void

    @State private var engine = DictationEngine()
    @State private var levels: [Float] = Array(repeating: 0, count: 36)
    @State private var autoSendTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            switch engine.state {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Dictation Unavailable", systemImage: "mic.slash")
                } description: {
                    Text(message)
                }
            case .idle, .listening:
                WaveformView(levels: levels)
                    .frame(height: 56)
                    .padding(.horizontal, 24)

                ScrollView {
                    Text(engine.transcript.isEmpty ? "Listening…" : engine.transcript)
                        .font(.body.monospaced())
                        .foregroundStyle(engine.transcript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                }
                .frame(maxHeight: 160)
            }

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    insert(appendReturn: false)
                } label: {
                    Text("Insert").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(engine.transcript.isEmpty)

                Button {
                    insert(appendReturn: true)
                } label: {
                    Text("Insert + Return").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.transcript.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .presentationDetents([.height(330)])
        .task {
            await engine.start()
        }
        .task {
            // Drive the waveform off the engine's level at ~30fps.
            while !Task.isCancelled {
                levels.removeFirst()
                levels.append(engine.audioLevel)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        .onChange(of: engine.transcript) {
            scheduleAutoSend()
        }
        .onDisappear {
            autoSendTask?.cancel()
            engine.stop()
        }
    }

    private func insert(appendReturn: Bool) {
        autoSendTask?.cancel()
        let text = engine.transcript
        engine.stop()
        guard !text.isEmpty else { return }
        onInsert(text, appendReturn)
        dismiss()
    }

    /// Optional auto-send: 1.5s of transcript silence ends with Insert + Return.
    private func scheduleAutoSend() {
        autoSendTask?.cancel()
        guard settings.autoSendDictation, !engine.transcript.isEmpty else { return }
        autoSendTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            insert(appendReturn: true)
        }
    }
}

struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: max(4, CGFloat(level) * 56))
            }
        }
        .animation(.linear(duration: 0.03), value: levels)
        .accessibilityLabel("Microphone level")
    }
}
