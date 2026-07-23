# App Privacy questionnaire answers

App Store Connect → App Privacy.

## Headline answer

**Data Not Collected** — check "No, we do not collect data from this app" for
every category.

## Why this is truthful

| Vector | Status |
|---|---|
| Analytics / telemetry | None. No SDKs, no first-party metrics. |
| Crash reporting | None. (Apple's opt-in crash reports to the developer don't count as collection by the app.) |
| Accounts / identifiers | None. No sign-in, no device identifiers read. |
| Server-side anything | We operate no servers. |
| SSH traffic | Goes only to user-configured hosts, initiated by the user. Not "collection" — we never see it. |
| VNC monitor traffic | Same posture as SSH: a direct, user-initiated, view-only connection to the user's own machine (no input sent). We never see it. |
| Dictation | `requiresOnDeviceRecognition = true`; never falls back to Apple's servers. |
| Purchases | Processed by Apple. The app sees entitlements only, on-device. |
| Private keys / server list | Keychain (ThisDeviceOnly) + local JSON. Never sync, never leave the device. |

## Privacy manifests

Both targets ship `PrivacyInfo.xcprivacy` with:

- `NSPrivacyCollectedDataTypes = []`
- `NSPrivacyTracking = false`
- Accessed-API reasons: UserDefaults `CA92.1`, file timestamps `C617.1`

If a future change adds a data flow, update BOTH the questionnaire and the
manifests in the same PR.
