import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Add or edit a custom agent: name, icon, how to recognize it, and the
/// timing knobs behind an Advanced disclosure. Nothing touches the store
/// until Save; Cancel leaves no trace (the icon is staged in memory).
struct AgentEditorView: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppSettings.self) private var settings
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss

    /// Nil when adding.
    let original: AgentProfile?

    private enum IconEdit {
        case unchanged
        /// Already normalized (square, 360px PNG) for preview and write.
        case set(Data)
        case remove
    }

    @State private var name: String
    @State private var markers: [String]
    @State private var newMarker = ""
    @State private var busyMarkers: [String]
    @State private var newBusyMarker = ""
    @State private var quietInterval: Double
    @State private var burstThreshold: Int
    @State private var showAdvanced: Bool
    @State private var icon: IconEdit = .unchanged
    @State private var showPhotos = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showFiles = false
    @State private var errorTitle = "Couldn't Save Agent"
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    /// The id a NEW agent got on its first successful save. If a later step
    /// failed and the user taps Save again, the same agent is updated
    /// instead of a duplicate being created.
    @State private var createdID: String?

    init(original: AgentProfile?) {
        self.original = original
        _name = State(initialValue: original?.displayName ?? "")
        _markers = State(initialValue: original?.detectionMarkers ?? [])
        _busyMarkers = State(initialValue: original?.busyMarkers ?? [])
        _quietInterval = State(initialValue: original?.quietInterval ?? AgentProfile.defaultQuietInterval)
        _burstThreshold = State(initialValue: original?.burstThreshold ?? AgentProfile.defaultBurstThreshold)
        // Open Advanced when there is something non-default in it.
        _showAdvanced = State(initialValue: !(original?.busyMarkers.isEmpty ?? true)
            || original?.quietInterval != nil || original?.burstThreshold != nil)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Markers as they'll be saved, including one typed but not yet added.
    private var finalMarkers: [String] { AgentProfile.normalizedMarkers(markers + [newMarker]) }
    private var canSave: Bool { !trimmedName.isEmpty && !finalMarkers.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Agent name", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("agentForm.name")
                }

                iconSection
                recognizeSection
                advancedSection

                if original != nil {
                    Section {
                        Button("Delete Agent", role: .destructive) {
                            confirmDelete = true
                        }
                        .accessibilityIdentifier("agentForm.delete")
                    }
                }
            }
            .navigationTitle(original == nil ? "New Agent" : "Edit Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("agentForm.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("agentForm.save")
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $pickedPhoto, matching: .images)
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    stageIcon(data, source: "That photo")
                    pickedPhoto = nil
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                switch result {
                case .failure(let error):
                    errorMessage = "Couldn't open that file: \(error.localizedDescription)"
                case .success(let url):
                    let read = CoordinatedFileRead.read(url)
                    if let data = read.data {
                        stageIcon(data, source: url.lastPathComponent)
                    } else {
                        errorMessage = read.failureMessage(for: url)
                    }
                }
            }
            .confirmationDialog(
                "Delete \(original?.displayName ?? "agent")?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Agent", role: .destructive) { delete() }
                    .accessibilityIdentifier("agentForm.confirmDelete")
            } message: {
                Text("Its icon is removed too. Servers set to this agent go back to the default.")
            }
            .alert(
                errorTitle,
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var iconSection: some View {
        Section {
            HStack(spacing: 16) {
                iconPreview
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("agentForm.iconPreview")
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        showPhotos = true
                    } label: {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("agentForm.iconPhotos")
                    Button {
                        showFiles = true
                    } label: {
                        Label("Choose from Files", systemImage: "folder")
                    }
                    .accessibilityIdentifier("agentForm.iconFiles")
                    if hasIcon {
                        Button("Remove Icon", role: .destructive) {
                            icon = .remove
                        }
                        .accessibilityIdentifier("agentForm.iconRemove")
                    }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Icon")
        } footer: {
            Text("Cropped to a square from the center. Without one, the generic agent icon is used. Your icon stays on this device and is never included in exported files.")
        }
    }

    private var recognizeSection: some View {
        Section {
            ForEach(markers, id: \.self) { marker in
                Text(marker)
                    .font(.body.monospaced())
            }
            .onDelete { markers.remove(atOffsets: $0) }
            HStack {
                TextField("Command name or startup text", text: $newMarker)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addMarker)
                    .accessibilityIdentifier("agentForm.newMarker")
                Button("Add", action: addMarker)
                    .disabled(newMarker.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("agentForm.addMarker")
            }
        } header: {
            Text("How to recognize it")
        } footer: {
            Text("a+Terminal recognizes agents from what appears in the terminal: the command name you launch it with (as your shell echoes it back), or text it prints when it starts, such as a version banner. Add at least one. Case doesn't matter; pick something distinctive, since a short common word can match unrelated output.")
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Busy text")
                        .font(.subheadline.weight(.medium))
                    Text("Text the agent shows while it is still working (e.g. a spinner hint). While it's on screen, a quiet pause isn't read as waiting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(busyMarkers, id: \.self) { marker in
                    Text(marker)
                        .font(.body.monospaced())
                }
                .onDelete { busyMarkers.remove(atOffsets: $0) }
                HStack {
                    TextField("Busy text", text: $newBusyMarker)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addBusyMarker)
                        .accessibilityIdentifier("agentForm.newBusyMarker")
                    Button("Add", action: addBusyMarker)
                        .disabled(newBusyMarker.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("agentForm.addBusyMarker")
                }
                Stepper(
                    value: $quietInterval,
                    in: AgentProfile.quietIntervalRange,
                    step: 0.5
                ) {
                    LabeledContent("Quiet before waiting",
                                   value: quietInterval.formatted(.number.precision(.fractionLength(1))) + " s")
                }
                .accessibilityIdentifier("agentForm.quietInterval")
                Stepper(
                    value: $burstThreshold,
                    in: AgentProfile.burstThresholdRange,
                    step: 50
                ) {
                    LabeledContent("Output that means working", value: "\(burstThreshold) bytes")
                }
                .accessibilityIdentifier("agentForm.burstThreshold")
                Button("Reset to Defaults") {
                    quietInterval = AgentProfile.defaultQuietInterval
                    burstThreshold = AgentProfile.defaultBurstThreshold
                }
                .disabled(quietInterval == AgentProfile.defaultQuietInterval
                          && burstThreshold == AgentProfile.defaultBurstThreshold)
                .accessibilityIdentifier("agentForm.resetTiming")
            }
            .accessibilityIdentifier("agentForm.advanced")
        } footer: {
            Text("Status comes from output timing: a burst of output means working, then quiet means waiting for you. The defaults (2 s, 200 bytes) suit most tools.")
        }
    }

    // MARK: - Icon

    private var hasIcon: Bool {
        switch icon {
        case .set: return true
        case .remove: return false
        case .unchanged:
            return original.map { CustomAgentIconStore.imageURL(for: $0.id) != nil } ?? false
        }
    }

    @ViewBuilder
    private var iconPreview: some View {
        switch icon {
        case .set(let png):
            if let ui = UIImage(data: png) {
                Image(uiImage: ui).resizable().scaledToFit()
            } else {
                Image(CustomAgentIconStore.genericAssetName).resizable().scaledToFit()
            }
        case .remove:
            Image(CustomAgentIconStore.genericAssetName).resizable().scaledToFit()
        case .unchanged:
            if let original {
                AgentIconView(profileID: original.id, size: 64)
            } else {
                Image(CustomAgentIconStore.genericAssetName).resizable().scaledToFit()
            }
        }
    }

    private func stageIcon(_ data: Data?, source: String) {
        guard let data, let png = CustomAgentIconStore.normalizedPNG(from: data) else {
            errorMessage = "\(source) couldn't be read as an image. Try another one."
            return
        }
        icon = .set(png)
    }

    // MARK: - Actions

    private func addMarker() {
        markers = AgentProfile.normalizedMarkers(markers + [newMarker])
        newMarker = ""
    }

    private func addBusyMarker() {
        busyMarkers = AgentProfile.normalizedMarkers(busyMarkers + [newBusyMarker])
        newBusyMarker = ""
    }

    private func save() {
        errorTitle = "Couldn't Save Agent"
        // The id is generated ONCE, here, and never edited: it keys the icon
        // file and every server that picks this agent.
        var profile = original ?? createdID.flatMap { profiles.agent(id: $0) } ?? AgentProfile(
            id: AgentProfile.makeCustomID(displayName: trimmedName, avoiding: Set(profiles.agents.map(\.id))),
            displayName: "", detectionMarkers: [], attachTemplate: "{path} ", builtIn: false)
        profile.displayName = trimmedName
        profile.detectionMarkers = finalMarkers
        profile.busyMarkers = AgentProfile.normalizedMarkers(busyMarkers + [newBusyMarker])
        profile.quietInterval = quietInterval == AgentProfile.defaultQuietInterval ? nil : quietInterval
        profile.burstThreshold = burstThreshold == AgentProfile.defaultBurstThreshold ? nil : burstThreshold
        do {
            try profiles.upsert(profile)
            if original == nil { createdID = profile.id }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        switch icon {
        case .unchanged:
            break
        case .set(let png):
            guard CustomAgentIconStore.write(png: png, for: profile.id) else {
                errorMessage = "The agent was saved, but its icon couldn't be stored. Try choosing it again."
                return
            }
        case .remove:
            CustomAgentIconStore.clear(for: profile.id)
        }
        dismiss()
    }

    private func delete() {
        guard let original else { return }
        errorTitle = "Couldn't Delete Agent"
        do {
            try profiles.deleteAgent(id: original.id, settings: settings, servers: servers)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
