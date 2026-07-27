# App Review notes (Guideline 2.1 — App Completeness)

a+Terminal is an SSH client, so the reviewer needs a server to connect to. We
stand up a temporary, locked-down demo box (`scripts/demo-ssh-setup.sh`) and put
its credentials in the Review Notes. **Fill the `<<HOST>>` / `<<USER>>` /
`<<PASSWORD>>` placeholders below from the script's output, then paste this whole
block into App Store Connect → App Review Information → Notes.**

Do **not** commit real credentials — keep placeholders here; the live values go
straight into App Store Connect.

---

```
a+Terminal is an SSH client. To evaluate it you'll connect to a live demo server
we've set up for review. The connection is the app's core function.

1. Open the app, Terminal tab, tap "+" (Add Server).
2. Enter:
     Host:     <<HOST>>
     Port:     22
     Username: <<USER>>
     Password: <<PASSWORD>>
   (Authentication: Password)
3. Save, then tap the server to connect. You'll land in a live shell that
   auto-attaches a tmux session with a long transcript.
4. To see the headline feature: with two fingers, pan up/down on the terminal.
   The transcript scrolls smoothly — this is tmux scrollback driven by the app's
   gesture-to-mouse bridge, the main reason this app exists.
5. Optional: tap the microphone in the key bar to dictate a command; transcription
   is 100% on-device (no audio leaves the phone).
6. Optional — Monitor (VNC, beta, off by default): the "+" menu → "Add
   Monitor (VNC)" adds a view-only screen-sharing session to a computer the
   user controls. Its screen can be popped out into a floating
   Picture-in-Picture window (live video of the remote screen) via the
   picture-in-picture button — PiP starts only from that user tap (or the
   system's app-switch auto-PiP if the user turns that sub-toggle on), never
   programmatically. It stays view-only until the user turns on Control.
7. Optional — Pop-Out Sessions (beta, off by default): with the toggle on
   (Settings → Pop-Out), a connected terminal session can be popped out into
   a floating window that continuously shows the session name, a running
   status indicator, a live elapsed-time clock, and the most recent lines of
   output — an at-a-glance monitor of a long-running task. It is a monitoring
   surface, not a remote-control surface: it forwards no input. Same
   user-initiated PiP start rule as above.

8. Optional — Preview: if you start any web server on the demo box (for
   example `python3 -m http.server 8000`), tap the "Preview" button in the
   terminal toolbar. a+Terminal forwards that port over the SSH connection
   you already opened and renders the page in-app. This is a development
   preview of the user's own server, not a web browser: it can only ever
   load loopback addresses (127.0.0.1 / localhost), it stores no cookies or
   site data, and any attempt to navigate elsewhere is blocked and offered
   to Safari instead.

Notes:
- No account or signup is required. The app collects zero data; the only network
  traffic is your own connection to your own machines (the SSH host above, and —
  if you try Monitor mode — a VNC screen-sharing connection to a computer you
  own). Monitors open view-only; an explicit in-monitor Control toggle lets the
  user send their own taps/keystrokes to their own machine. Clipboard contents
  are never sent.
- The Tip Jar (Settings) is optional consumable IAP; nothing in the app is paywalled.

This demo server is temporary and will be taken offline after review. Thank you!
```

---

## Localhost preview — why it is not a web browser (Guidelines 4.7, 2.5.6)

The preview renders a development server running on the machine the user is
already SSH'd into. Three properties keep it a developer tool rather than an
embedded browser, and all three are enforced in code, not by convention:

1. **Loopback only, on both ends.** The SSH channel always dials
   `127.0.0.1:<port>` on the *remote* box — never a host the page names. On
   the phone, the `WKNavigationDelegate` allows navigation only to loopback
   hosts (`localhost`, `127.0.0.0/8`, `::1`); everything else is cancelled and
   offered to Safari. Lookalikes such as `localhost.evil.com` are rejected by
   the same check, which is unit-tested.
2. **Nothing persists.** `websiteDataStore = .nonPersistent()`, so no cookies,
   localStorage, or caches survive the sheet. There is no `WKUIDelegate`, so
   `target=_blank` opens nothing. This is what keeps the app's "Data Not
   Collected" declaration accurate.
3. **The listener is not on the network.** The phone-side listener is pinned
   with `NWParameters.requiredLocalEndpoint = 127.0.0.1`, so the user's dev
   server is never republished to the Wi-Fi. This was verified empirically
   against a wildcard-bound control (the control was reachable from another
   address on the same host; the pinned listener was refused) and is covered
   by a test that fails if the bind ever widens.

**App Transport Security:** no ATS exception was required. Plain-HTTP loads to
`http://127.0.0.1:<port>` inside `WKWebView` are permitted with the shipped
Info.plist untouched, confirmed by an on-simulator spike before the feature was
designed. The app therefore ships with **no** `NSAllowsArbitraryLoads`,
`NSAllowsArbitraryLoadsInWebContent`, `NSAllowsLocalNetworking`, or
`NSExceptionDomains` entries — if a future change appears to need one, that is a
signal the loopback-only invariant has been broken somewhere.

The feature is also foreground-only: iOS suspends the app, the listener dies
with it. That is stated plainly in the UI rather than left for users to discover.

## Backup demo video

A 28-second screen recording (connect → tmux → scroll) is also available if the
demo server is unreachable for any reason:
https://github.com/AaronCx/a-plus-terminal/releases/download/review-demo/aplus-demo.mp4

## Standing up the demo server — Oracle Cloud Always Free (manual)

Free forever, real public IP, no Tailscale/Funnel needed. The setup script runs
unchanged on the Always Free Ubuntu image.

1. **Create the instance** at cloud.oracle.com → Compute → Instances → Create:
   - Image: **Ubuntu 24.04**. Shape: an **Always Free** one —
     `VM.Standard.A1.Flex` (Arm, 1 OCPU/6 GB is plenty) or `VM.Standard.E2.1.Micro`.
   - Add your SSH **public** key (you'll log in as user `ubuntu`).
   - Networking: the default VCN Security List already allows ingress **TCP 22**.
     If you changed it, add an ingress rule: Source `0.0.0.0/0`, TCP, dest port 22.
2. **Run the setup** (you log in as `ubuntu`, so use `sudo`):
   ```sh
   scp scripts/demo-ssh-setup.sh ubuntu@<public-ip>:
   ssh ubuntu@<public-ip> 'sudo bash demo-ssh-setup.sh "<single-use-password>"'
   ```
   It prints the Host / Username (`demo`) / Password to paste into ASC.
3. From a clean device (not your tailnet), add the server in a+Terminal with those
   creds and confirm you land in tmux and can two-finger pan-scroll. (If you can't,
   neither can the reviewer.)
4. Copy the printed Host/User/Password into the Review Notes block above (replacing
   the placeholders) in App Store Connect.
5. Submit / resubmit.

   Note: the script enables `ufw` allowing only 22; on Oracle that coexists with
   the cloud Security List. If SSH ever seems blocked, check **both** the Security
   List (cloud-side) and `ufw status` (host-side).

## Teardown

After the app is **"Ready for Sale," destroy the VM.** The password was
single-use, so nothing else needs rotating.
