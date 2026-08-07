import SwiftUI
import UniformTypeIdentifiers

/// Bring-your-own agent icons: pick an image file per agent, stored in the
/// App Group so the Live Activity draws it too. The app ships only original
/// or licensed default marks; whatever a user imports is their own copy and
/// never leaves the device — consistent with zero data collection.
struct CustomAgentIconsView: View {
    @Environment(ProfileStore.self) private var profiles

    /// Which agent the picker is choosing for. SEPARATE from the sheet's
    /// presentation flag: the sheet's dismissal writes false through the
    /// binding, and that write can land before the completion handler reads
    /// the id — the pick silently did nothing. Presentation and payload are
    /// now different variables so dismissal cannot erase the payload.
    @State private var pendingAgent: String?
    @State private var showImporter = false
    @State private var refresh = 0
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                ForEach(profiles.agents.filter { $0.id != "generic" }) { agent in
                    HStack {
                        iconPreview(for: agent.id)
                            .id(refresh)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName)
                            Text(CustomAgentIconStore.imageURL(for: agent.id) != nil
                                    ? "Custom icon" : "Default icon")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose…") {
                            pendingAgent = agent.id
                            showImporter = true
                        }
                        .buttonStyle(.borderless)
                        if CustomAgentIconStore.imageURL(for: agent.id) != nil {
                            Button(role: .destructive) {
                                CustomAgentIconStore.clear(for: agent.id)
                                refresh += 1
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Reset to default")
                        }
                    }
                }
            } footer: {
                Text("Pick any image from Files (PNG with transparency looks best; it's stored square at 360px). Custom icons show in the session list and Live Activity when an agent is detected, stay on this device, and never leave it.")
            }
            if let importError {
                Section {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Custom Agent Icons")
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image]
        ) { result in
            guard let id = pendingAgent else {
                importError = "Lost track of which agent was being changed — try again."
                return
            }
            pendingAgent = nil
            switch result {
            case .failure(let error):
                importError = "Couldn't open that file: \(error.localizedDescription)"
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // iCloud Drive files may not be materialized on this device;
                // a plain read fails silently. Coordinated reading downloads
                // and blocks until the bytes exist — the failure the silent
                // path hid was exactly this.
                var data: Data?
                var coordError: NSError?
                NSFileCoordinator().coordinate(
                    readingItemAt: url, options: [], error: &coordError
                ) { actual in
                    data = try? Data(contentsOf: actual)
                }
                if let data, CustomAgentIconStore.save(data, for: id) {
                    importError = nil
                    refresh += 1
                } else {
                    importError = "Couldn't read \(url.lastPathComponent)"
                        + (coordError.map { " — \($0.localizedDescription)" } ?? "")
                        + ". If it's in iCloud, open it once in Files so it downloads, then retry."
                }
            }
        }
    }

    @ViewBuilder
    private func iconPreview(for id: String) -> some View {
        if let url = CustomAgentIconStore.imageURL(for: id),
           let ui = UIImage(contentsOfFile: url.path) {
            Image(uiImage: ui)
                .resizable().scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image("agent-\(id)")
                .resizable().scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
