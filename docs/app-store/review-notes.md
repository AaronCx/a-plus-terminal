# App Review notes (Guideline 2.1 — App Completeness)

Paste a tailored version of this into App Store Connect → App Review Information → Notes.

---

a+Terminal is an SSH terminal. It is a **general-purpose** SSH terminal, not
tied to any one AI tool and not affiliated with any AI vendor. Agents such as
Claude Code, Codex, aider, Gemini CLI, and Hermes are simply CLI programs the
user may choose to run over the connection; the app ships profiles for them but
is a plain terminal.

Like other terminal apps on the App Store
(Terminal#, Termius, Blink Shell, La Terminal), it requires the user's **own
SSH server** — there is no demo account because there are no accounts: the
app connects directly from the device to a server the user controls.

To evaluate the app without a server:

1. All UI is reachable without a connection: server management (Settings →
   keys are generated on-device), the Settings tab, the dictation sheet
   (works fully offline — speech recognition is on-device only).
2. A demo video showing the app connecting over SSH and running a live tmux
   session (typing, output, the accessory bar) is available at:
   https://github.com/AaronCx/a-plus-terminal/releases/download/review-demo/aplus-demo.mp4
   (Recorded in the iOS Simulator against a local SSH server. Dictation and
   Live Activities are on-device features; dictation works offline via Apple's
   on-device speech recognition.)

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
