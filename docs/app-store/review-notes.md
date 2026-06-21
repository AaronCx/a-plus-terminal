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

Notes:
- No account or signup is required. The app collects zero data; the only network
  traffic is your own SSH connection to the host above.
- The Tip Jar (Settings) is optional consumable IAP; nothing in the app is paywalled.

This demo server is temporary and will be taken offline after review. Thank you!
```

---

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
