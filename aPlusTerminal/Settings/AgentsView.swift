import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Agents. Built-in agents (icon override as before) and the
/// user's own agents: add, edit, delete, import and export. Agent identity is
/// data — a custom agent is just a profile the user wrote here, recognized
/// the same way as a built-in, from what appears in the terminal.
///
/// Icons: the app ships only original doodles; whatever a user picks is
/// their own copy, kept in the App Group for the Live Activity and never
/// exported or uploaded — consistent with zero data collection.
struct AgentsView: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppSettings.self) private var settings
    @Environment(ServerStore.self) private var servers

    /// What the single file importer is for. One importer, a payload chosen
    /// before presenting it: SwiftUI drops all but one `.fileImporter` on a
    /// view, and the payload is SEPARATE from the presentation flag because
    /// the sheet's dismissal writes false through the binding before the
    /// completion runs (the #147 lost-pick bug).
    private enum ImportPurpose: Equatable {
        case agents
        case icon(String)
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @State private var editing: AgentEditorTarget?
    @State private var pendingDelete: AgentProfile?
    @State private var importPurpose: ImportPurpose?
    @State private var showImporter = false
    @State private var importerTypes: [UTType] = [.json]
    @State private var exportDocument: ProfileBundleDocument?
    @State private var showExporter = false
    @State private var notice: Notice?
    @State private var iconRefresh = 0
    /// Built-in icon from Photos: target id kept apart from the flag, as above.
    @State private var photoTarget: String?
    @State private var showPhotos = false
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        List {
            if let loadError = profiles.loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("agents.loadError")
                }
            }

            Section {
                ForEach(profiles.customAgents) { agent in
                    Button {
                        editing = AgentEditorTarget(agent: agent)
                    } label: {
                        customRow(agent)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("agents.row.\(agent.id)")
                }
                .onDelete { offsets in
                    pendingDelete = offsets.map { profiles.customAgents[$0] }.first
                }
                Button {
                    editing = AgentEditorTarget(agent: nil)
                } label: {
                    Label("Add Agent", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("agents.add")
            } header: {
                Text("Custom")
            } footer: {
                Text("Add any command-line tool as an agent. a+Terminal recognizes it from what appears in the terminal and shows its name and icon on the session and the Live Activity. Changes apply to sessions you open afterwards.")
            }

            Section {
                ForEach(profiles.builtInAgents) { agent in
                    builtInRow(agent)
                }
            } header: {
                Text("Built-in")
            } footer: {
                Text("Pick any image from Photos or Files for any agent. It's cropped to a square from the center and stored at 360px (PNG with transparency looks best). Icons show in the session list and Live Activity when an agent is detected, stay on this device, and are never exported or uploaded. Agent names, icons and mascots are trademarks or artwork of their respective owners; a+Terminal is independent and not affiliated with, sponsored by, or endorsed by any of them.")
            }

            #if DEBUG
            if TestSeed.agentImportTestFileRequested {
                Section {
                    Button("Import Test File") {
                        handleImport(TestSeed.agentImportTestFile(), purpose: .agents)
                    }
                    .accessibilityIdentifier("agents.debugImport")
                }
            }
            #endif
        }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        presentImporter(for: .agents)
                    } label: {
                        Label("Import Agents…", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("agents.import")
                    Button {
                        exportDocument = ProfileBundleDocument(
                            data: profiles.exportData(agentIDs: profiles.customAgents.map(\.id)))
                        showExporter = true
                    } label: {
                        Label("Export Custom Agents…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(profiles.customAgents.isEmpty)
                    .accessibilityIdentifier("agents.export")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Import or Export")
                }
                .accessibilityIdentifier("agents.menu")
            }
        }
        .sheet(item: $editing) { target in
            AgentEditorView(original: target.agent)
        }
        .onChange(of: editing) { _, target in
            // The editor may have changed or deleted an icon.
            if target == nil { iconRefresh += 1 }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "agent")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { agent in
            Button("Delete Agent", role: .destructive) {
                delete(agent)
            }
            .accessibilityIdentifier("agents.confirmDelete")
        } message: { _ in
            Text("Its icon is removed too. Servers set to this agent go back to the default.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importerTypes) { result in
            guard let purpose = importPurpose else {
                notice = Notice(title: "Couldn't Import", message: "Lost track of what was being imported — try again.")
                return
            }
            importPurpose = nil
            handleImport(result, purpose: purpose)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "a+Terminal agents"
        ) { result in
            if case .failure(let error) = result {
                notice = Notice(title: "Couldn't Export Agents", message: error.localizedDescription)
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item, let id = photoTarget else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                if let data, CustomAgentIconStore.save(data, for: id) {
                    iconRefresh += 1
                } else {
                    notice = Notice(title: "Couldn't Use That Image", message: "The photo couldn't be read as an image. Try another one.")
                }
                pickedPhoto = nil
                photoTarget = nil
            }
        }
        .alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            ),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Rows

    private func customRow(_ agent: AgentProfile) -> some View {
        HStack {
            AgentIconView(profileID: agent.id)
                .id(iconRefresh)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                Text(agent.detectionMarkers.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func builtInRow(_ agent: AgentProfile) -> some View {
        let hasCustomIcon = CustomAgentIconStore.imageURL(for: agent.id) != nil
        return HStack {
            AgentIconView(profileID: agent.id)
                .id(iconRefresh)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                Text(hasCustomIcon ? "Custom icon" : "Default icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Choose…") {
                Button {
                    photoTarget = agent.id
                    showPhotos = true
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    presentImporter(for: .icon(agent.id))
                } label: {
                    Label("Files", systemImage: "folder")
                }
            }
            .accessibilityIdentifier("agents.chooseIcon.\(agent.id)")
            if hasCustomIcon {
                Button(role: .destructive) {
                    CustomAgentIconStore.clear(for: agent.id)
                    iconRefresh += 1
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset to default")
                .accessibilityIdentifier("agents.resetIcon.\(agent.id)")
            }
        }
    }

    // MARK: - Actions

    private func presentImporter(for purpose: ImportPurpose) {
        importPurpose = purpose
        importerTypes = purpose == .agents ? [.json] : [.image]
        showImporter = true
    }

    /// The one completion path for picked files. The DEBUG test hook calls
    /// this too, with a file the app wrote itself, so the error path a
    /// malformed file takes is exactly the one a real pick takes.
    private func handleImport(_ result: Result<URL, Error>, purpose: ImportPurpose) {
        let url: URL
        switch result {
        case .failure(let error):
            notice = Notice(title: "Couldn't Open That File", message: error.localizedDescription)
            return
        case .success(let picked):
            url = picked
        }
        let read = CoordinatedFileRead.read(url)
        guard let data = read.data else {
            notice = Notice(title: "Couldn't Open That File", message: read.failureMessage(for: url))
            return
        }
        switch purpose {
        case .agents:
            do {
                let imported = try profiles.importBundle(data)
                let names = imported.map(\.displayName).joined(separator: ", ")
                notice = Notice(
                    title: imported.count == 1 ? "Imported 1 Agent" : "Imported \(imported.count) Agents",
                    message: "\(names). Pick icons for them here; icons aren't part of exported files.")
            } catch {
                notice = Notice(title: "Couldn't Import Agents", message: error.localizedDescription)
            }
        case .icon(let id):
            if CustomAgentIconStore.save(data, for: id) {
                iconRefresh += 1
            } else {
                notice = Notice(title: "Couldn't Use That Image", message: "\(url.lastPathComponent) couldn't be read as an image.")
            }
        }
    }

    private func delete(_ agent: AgentProfile) {
        do {
            try profiles.deleteAgent(id: agent.id, settings: settings, servers: servers)
        } catch {
            notice = Notice(title: "Couldn't Delete Agent", message: error.localizedDescription)
        }
        pendingDelete = nil
    }
}

/// Sheet payload: nil agent = Add Agent.
struct AgentEditorTarget: Identifiable, Equatable {
    let id = UUID()
    let agent: AgentProfile?
}

/// An agent's icon as every in-app surface draws it: the user's PNG, the
/// bundled doodle, or the generic doodle — never an empty slot.
struct AgentIconView: View {
    let profileID: String
    var size: CGFloat = 28

    var body: some View {
        let source = CustomAgentIconStore.source(forIconName: "agent-\(profileID)")
        image(for: source)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }

    private func image(for source: CustomAgentIconStore.Source) -> Image {
        if case .custom(let url) = source, let ui = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: ui)
        }
        return Image(source.assetName)
    }
}

/// Reads a user-picked file: security-scoped access plus a coordinated read.
/// iCloud Drive files may not be materialized on this device, and a plain
/// read fails silently; coordinated reading downloads and blocks until the
/// bytes exist.
enum CoordinatedFileRead {
    struct Result {
        var data: Data?
        var error: NSError?

        func failureMessage(for url: URL) -> String {
            "Couldn't read \(url.lastPathComponent)"
                + (error.map { " — \($0.localizedDescription)" } ?? "")
                + ". If it's in iCloud, open it once in Files so it downloads, then retry."
        }
    }

    static func read(_ url: URL) -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { actual in
            data = try? Data(contentsOf: actual)
        }
        return Result(data: data, error: coordError)
    }
}

/// JSON wrapper so an agents bundle can be written via fileExporter.
struct ProfileBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
