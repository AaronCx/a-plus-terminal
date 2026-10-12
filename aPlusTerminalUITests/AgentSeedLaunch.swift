import XCTest

extension XCUIApplication {
    /// Launches with whatever agents seed `launchEnvironment` carries
    /// (`APLUSTERMINAL_TEST_RESET_AGENTS`, `_AGENT_PROFILES`, icon) and
    /// PROVES this launch applied it, relaunching when it didn't.
    ///
    /// On the simulator the app has come up without any of the test's
    /// launch environment (seen with `ps -E` on the app process, typically
    /// the first launch of an `xcodebuild` invocation). The seed then never
    /// ran, and the test worked on whatever an earlier run left on disk:
    /// failing from a clean state, or passing on stale data. TestSeed echoes
    /// a per-launch nonce through an invisible `testSeed.agents` label only
    /// after every requested step succeeded; no matching nonce, no proof.
    ///
    /// Returns the attempt that proved the seed, or nil when none did
    /// (the caller fails the test with a clear message).
    func launchProvingAgentSeed(attempts: Int = 3) -> Int? {
        let nonce = UUID().uuidString.lowercased()
        launchEnvironment["APLUSTERMINAL_TEST_SEED_NONCE"] = nonce
        for attempt in 1...attempts {
            if attempt > 1 { terminate() }
            launch()
            let marker = staticTexts["testSeed.agents"]
            if marker.waitForExistence(timeout: 10) {
                if marker.label == nonce {
                    if attempt > 1 { print("AGENTSEED: proved on attempt \(attempt)") }
                    return attempt
                }
                if marker.label == "failed-\(nonce)" {
                    print("AGENTSEED: the app reported a failed seed step")
                    return nil  // a write failed in the app; relaunching won't fix it
                }
            }
            print("AGENTSEED: attempt \(attempt) launched without its seed (marker: \(marker.exists ? marker.label : "absent"))")
        }
        return nil
    }

    /// Relaunch on the SAME data, with no seed: what was saved must be what
    /// comes back.
    func relaunchWithoutAgentSeed() {
        terminate()
        for key in ["APLUSTERMINAL_TEST_RESET_AGENTS", "APLUSTERMINAL_TEST_AGENT_PROFILES",
                    "APLUSTERMINAL_TEST_AGENT_ICON_ID", "APLUSTERMINAL_TEST_AGENT_ICON_BASE64",
                    "APLUSTERMINAL_TEST_IMPORT_AGENTS_JSON", "APLUSTERMINAL_TEST_SEED_NONCE"] {
            launchEnvironment.removeValue(forKey: key)
        }
        launch()
    }
}
