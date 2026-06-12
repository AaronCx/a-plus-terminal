import SwiftUI

/// Bonjour discovery sheet: lists `_ssh._tcp` services on the local network;
/// picking one resolves it and hands a prefilled server to the caller.
struct DiscoveryView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (Server) -> Void

    @State private var browser = BonjourBrowser()
    @State private var resolvingID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if browser.services.isEmpty {
                    ContentUnavailableView(
                        "Searching…",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Looking for SSH servers advertising on your network. On a Mac, enable System Settings › Sharing › Remote Login.")
                    )
                }
                ForEach(browser.services) { service in
                    Button {
                        select(service)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .font(.body.weight(.medium))
                                Text("SSH service")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if resolvingID == service.id {
                                ProgressView()
                            }
                        }
                    }
                    .tint(.primary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                Section {
                } footer: {
                    Text("Discovery uses Bonjour on your local network only — nothing leaves it.")
                }
            }
            .navigationTitle("Discover Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    private func select(_ service: BonjourBrowser.DiscoveredService) {
        resolvingID = service.id
        errorMessage = nil
        Task {
            defer { resolvingID = nil }
            guard let (host, port) = await BonjourBrowser.resolve(service.endpoint) else {
                errorMessage = "Couldn't resolve \(service.name). Make sure you're on the same network."
                return
            }
            onSelect(Server(name: service.name, host: host, port: port, username: ""))
            dismiss()
        }
    }
}
