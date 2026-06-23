**a+Terminal Privacy Policy**

**a+Terminal collects no data. None.**

• No analytics or telemetry
• No crash reporting services
• No accounts or sign-in
• No advertising or tracking SDKs
• No servers operated by us

The only traffic a+Terminal sends off your network is the SSH connection **you** initiate to **your own** servers. That traffic is end-to-end encrypted with standard SSH and goes directly from your iPhone to your server — never through us, because there is no "us" in the middle.

**On your local network**, a few convenience features talk only to your own machines and never to any third party: server status indicators (and the optional Home-screen widget) check reachability by briefly opening a TCP connection to a saved server's host and port — no data is sent in that probe; "Discover on Network" browses for advertised SSH services when you open it; and "Wake Server" sends a Wake-on-LAN packet when you tap it. All of this stays on your network.

**Attaching an image or file** sends the selected item over that same existing SSH connection to your own server; it is sent nowhere else.

**Voice dictation** is transcribed entirely on your iPhone using Apple's on-device speech recognition. a+Terminal refuses to run dictation if on-device recognition is unavailable — it never falls back to cloud transcription.

**Your keys and servers** stay on your device: SSH private keys live in the iOS Keychain (this device only, excluded from backups; they leave the Keychain only when you explicitly reveal, copy, or export them in Manage Keys), and your server list is a local file containing no secrets.

**Purchases** (tips) are handled by Apple through the App Store. We never see your payment details.

If you have questions, use the support link in the app's Settings tab (it opens the public GitHub issue tracker). Anything you post there is the only way information ever reaches us: when you choose to share it.

_Last updated: June 2026_
