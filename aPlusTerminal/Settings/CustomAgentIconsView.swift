import SwiftUI
import UniformTypeIdentifiers

/// Bring-your-own agent icons: pick an image file per agent, stored in the
/// App Group so the Live Activity draws it too. The app ships only original
/// or licensed default marks; whatever a user imports is their own copy and
/// never leaves the device — consistent with zero data collection.
struct CustomAgentIconsView: View {
    @Environment(ProfileStore.self) private var profiles

    @State private var importing: String?
    @State private var refresh = 0

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
                        Button("Choose…") { importing = agent.id }
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
                Text("Pick any image from Files (PNG with transparency looks best; it's stored square at 360px). Custom icons show in the session list and Live Activity, stay on this device, and never leave it.")
            }
        }
        .navigationTitle("Custom Agent Icons")
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: [.image]
        ) { result in
            guard let id = importing else { return }
            importing = nil
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                CustomAgentIconStore.save(data, for: id)
                refresh += 1
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
