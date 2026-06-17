# App Review notes (Guideline 2.1 — App Completeness)

Paste a tailored version of this into App Store Connect → App Review Information → Notes.

---

a+Terminal is an SSH terminal. Like other terminal apps on the App Store
(Terminal#, Termius, Blink Shell, La Terminal), it requires the user's **own
SSH server** — there is no demo account because there are no accounts: the
app connects directly from the device to a server the user controls.

To evaluate the app without a server:

1. All UI is reachable without a connection: server management (Settings →
   keys are generated on-device), the Settings tab, the dictation sheet
   (works fully offline — speech recognition is on-device only).
2. A demo video showing the full connect → tmux → scroll → dictate → Live
   Activity flow is available at: **[VIDEO LINK — record before submission]**

Notes for specific features:

- **Voice dictation** uses `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition = true`. Audio never leaves the device.
- **Live Activity** is local-only (no push tokens).
- **Tips** are one-time consumable donations through StoreKit 2. They unlock
  no features; nothing is paywalled. Consumable tip jars are well-precedented
  (e.g. Apollo, Overcast).
- **Privacy label is "Data Not Collected"** — the app has no analytics, no
  crash SDKs, no accounts, and no first-party server. The only network
  traffic is the SSH connection the user initiates to their own host.

Do **not** ship or reference a fake demo host — reviewers may probe it.
