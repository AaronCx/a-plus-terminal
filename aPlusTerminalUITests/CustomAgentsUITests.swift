import XCTest

/// Settings › Agents, driven like a user: create, edit, delete, import. No
/// SSH and no live host, so — unlike the live QA suites — these run on every
/// `make test`, CI included.
///
/// Each test starts from a clean slate (`APLUSTERMINAL_TEST_RESET_AGENTS=1`
/// wipes the user profiles file and user icons before the store loads),
/// proven by `launchProvingAgentSeed` rather than assumed, and relaunches
/// WITHOUT the reset to prove what was saved is what comes back. The form is
/// driven once (create); edit and delete start from agents seeded through
/// the profiles file, which keeps each test to the one thing it checks.
final class CustomAgentsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_RESET_AGENTS"] = "1"
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - Helpers

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openAgents(file: StaticString = #filePath, line: UInt = #line) {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "tab bar", file: file, line: line)
        settingsTab.tap()
        let link = app.buttons["settings.agents"]
        var swipes = 0
        while !(link.exists && link.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Agents row in Settings", file: file, line: line)
        link.tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "Agents screen", file: file, line: line)
    }

    /// Launch on a proven clean (or seeded) slate.
    private func launchSeeded(agents: [(id: String, name: String, marker: String)] = [],
                              file: StaticString = #filePath, line: UInt = #line) {
        if !agents.isEmpty {
            let entries = agents.map {
                #"{"id":"\#($0.id)","displayName":"\#($0.name)","detectionMarkers":["\#($0.marker)"]}"#
            }
            app.launchEnvironment["APLUSTERMINAL_TEST_AGENT_PROFILES"] =
                #"{"agents":["# + entries.joined(separator: ",") + "]}"
        }
        XCTAssertNotNil(app.launchProvingAgentSeed(),
                        "the app never proved it applied this test's agents reset/seed", file: file, line: line)
    }

    /// Terminates and launches again on the SAME data: no reset this time.
    private func relaunchKeepingData() {
        app.relaunchWithoutAgentSeed()
    }

    private var anyCustomRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agents.row.'")).firstMatch
    }

    /// The DEBUG import row sits at the bottom of the list; tapping it scrolls
    /// the Custom section away, and a List row off screen doesn't exist for
    /// XCUITest. Scroll back up before asserting on custom rows, or "nothing
    /// imported" would pass for the wrong reason.
    private func scrollToCustomSection() {
        let add = app.buttons["agents.add"]
        var swipes = 0
        while !(add.exists && add.isHittable) && swipes < 4 {
            app.swipeDown()
            swipes += 1
        }
        XCTAssertTrue(add.isHittable, "back at the Custom section")
    }

    /// Fails fast and clearly if the reset didn't take, instead of letting a
    /// leftover agent from an earlier run decide the outcome.
    private func assertStartsWithNoCustomAgents(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["agents.add"].waitForExistence(timeout: 5), "Add Agent button", file: file, line: line)
        XCTAssertFalse(anyCustomRow.exists, "precondition: the reset left no custom agents", file: file, line: line)
    }

    private func agentRow(named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'agents.row.' AND label CONTAINS %@", name)).firstMatch
    }

    private func createAgent(name: String, marker: String, screenshot: Bool = false) {
        let add = app.buttons["agents.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add Agent button")
        add.tap()
        let nameField = app.textFields["agentForm.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "editor sheet")
        let save = app.buttons["agentForm.save"]
        XCTAssertFalse(save.isEnabled, "Save needs a name and a marker")
        nameField.tap()
        nameField.typeText(name)
        XCTAssertFalse(save.isEnabled, "a name alone is not enough: nothing to recognize it by")
        let markerField = app.textFields["agentForm.newMarker"]
        markerField.tap()
        markerField.typeText(marker)
        app.buttons["agentForm.addMarker"].tap()
        XCTAssertTrue(save.isEnabled)
        if screenshot { shot("agents-02-editor") }
        save.tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "sheet dismissed")
    }

    // MARK: - Tests

    func testCreatedAgentAppearsInList() {
        launchSeeded()
        openAgents()
        assertStartsWithNoCustomAgents()
        shot("agents-01-empty")
        createAgent(name: "Test Bot", marker: "TestBot v1 Ready", screenshot: true)
        let row = agentRow(named: "Test Bot")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "new agent listed under Custom")
        shot("agents-03-listed")
        XCTAssertTrue(row.label.contains("testbot v1 ready"), "marker stored lowercased: \(row.label)")
    }

    func testEditedNamePersistsAcrossRelaunch() {
        launchSeeded(agents: [("custom-edit-me-ui0001", "Edit Me", "editme")])
        openAgents()
        let row = agentRow(named: "Edit Me")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let nameField = app.textFields["agentForm.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        // Cursor to the end, then erase whatever is there.
        nameField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        nameField.typeText("Renamed Bot")
        app.buttons["agentForm.save"].tap()
        XCTAssertTrue(agentRow(named: "Renamed Bot").waitForExistence(timeout: 5))

        relaunchKeepingData()
        openAgents()
        XCTAssertTrue(agentRow(named: "Renamed Bot").waitForExistence(timeout: 5), "edit survived relaunch")
        XCTAssertFalse(agentRow(named: "Edit Me").exists, "old name gone")
    }

    func testDeletePersistsAcrossRelaunch() {
        // Seeded through the profiles file, so both rows are on disk before
        // the delete: its relaunch check can't pass for the wrong reason.
        launchSeeded(agents: [("custom-doomed-bot-ui0002", "Doomed Bot", "doomedbot"),
                              ("custom-keeper-bot-ui0003", "Keeper Bot", "keeperbot")])
        openAgents()
        XCTAssertTrue(agentRow(named: "Doomed Bot").waitForExistence(timeout: 5))
        XCTAssertTrue(agentRow(named: "Keeper Bot").exists)

        agentRow(named: "Doomed Bot").swipeLeft()
        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 3), "swipe-to-delete action")
        swipeDelete.tap()
        // The dialog exposes its button twice on iOS 26 (sheet + popover
        // backing), so take the first match rather than demanding one.
        let confirm = app.buttons["Delete Agent"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "delete asks for confirmation")
        confirm.tap()
        XCTAssertTrue(agentRow(named: "Doomed Bot").waitForNonExistence(timeout: 5))

        relaunchKeepingData()
        openAgents()
        XCTAssertTrue(agentRow(named: "Keeper Bot").waitForExistence(timeout: 5), "the other agent stays")
        XCTAssertFalse(agentRow(named: "Doomed Bot").exists, "delete survived relaunch")
    }

    /// The import completion path, fed a damaged file through the DEBUG hook
    /// (the system document picker can't be driven reliably): an error
    /// alert, no crash, nothing imported.
    func testMalformedImportShowsErrorNotCrash() {
        app.launchEnvironment["APLUSTERMINAL_TEST_IMPORT_AGENTS_JSON"] = #"{"agents": [ {"id": "#
        launchSeeded()
        openAgents()
        assertStartsWithNoCustomAgents()
        let hook = app.buttons["agents.debugImport"]
        var swipes = 0
        while !(hook.exists && hook.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(hook.waitForExistence(timeout: 5), "DEBUG import hook row")
        hook.tap()

        let alert = app.alerts["Couldn't Import Agents"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "malformed import shows an error alert")
        let message = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'valid agents file'")).firstMatch
        XCTAssertTrue(message.exists, "user-presentable reason in the alert")
        alert.buttons["OK"].tap()
        XCTAssertEqual(app.state, .runningForeground, "still running")
        XCTAssertTrue(app.navigationBars["Agents"].exists)
        scrollToCustomSection()
        XCTAssertFalse(anyCustomRow.exists, "nothing imported")
    }

    func testValidImportAddsAgent() {
        app.launchEnvironment["APLUSTERMINAL_TEST_IMPORT_AGENTS_JSON"] =
            #"{"agents":[{"id":"custom-imported-bot","displayName":"Imported Bot","detectionMarkers":["importedbot"]}]}"#
        launchSeeded()
        openAgents()
        assertStartsWithNoCustomAgents()
        let hook = app.buttons["agents.debugImport"]
        var swipes = 0
        while !(hook.exists && hook.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        hook.tap()
        let alert = app.alerts["Imported 1 Agent"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        scrollToCustomSection()
        XCTAssertTrue(app.buttons["agents.row.custom-imported-bot"].waitForExistence(timeout: 5))

        relaunchKeepingData()
        openAgents()
        XCTAssertTrue(app.buttons["agents.row.custom-imported-bot"].waitForExistence(timeout: 5), "import persisted")
    }
}
