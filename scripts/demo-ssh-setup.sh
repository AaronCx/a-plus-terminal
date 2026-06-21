#!/usr/bin/env bash
# demo-ssh-setup.sh — stand up a throwaway, locked-down SSH box for App Store
# review of a+Terminal (Guideline 2.1). Run as root on a FRESH Ubuntu 24.04 VM:
#
#     scp scripts/demo-ssh-setup.sh root@<ip>:
#     ssh root@<ip> 'bash demo-ssh-setup.sh "<single-use-password>"'
#
# Creates user `demo` (password from $1, no sudo), enables SSH password auth for
# `demo` only, firewalls to 22/tcp, enables fail2ban, and makes `demo`'s login
# auto-attach a tmux session pre-seeded with a long, scrollable transcript so a
# reviewer immediately sees the gesture→tmux-scroll feature. Idempotent.
#
# Tear the VM down after the app is "Ready for Sale". The password is single-use.
set -euo pipefail

[ "$(id -u)" = "0" ]  || { echo "ERROR: run as root." >&2; exit 1; }
PW="${1:-}"
[ -n "$PW" ]          || { echo "ERROR: usage: demo-ssh-setup.sh <password>" >&2; exit 1; }

RAW_SEED="https://raw.githubusercontent.com/AaronCx/a-plus-terminal/main/scripts/demo-seed-transcript.sh"

echo "==> installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y tmux openssh-server ufw fail2ban curl ca-certificates

echo "==> creating user 'demo' (no sudo)"
id demo >/dev/null 2>&1 || useradd -m -s /bin/bash demo
echo "demo:${PW}" | chpasswd
# Ensure demo has no elevated privileges (do not touch /etc/sudoers.d).
deluser demo sudo  >/dev/null 2>&1 || true
gpasswd -d demo sudo >/dev/null 2>&1 || true

echo "==> hardening sshd (password auth for 'demo' only)"
cat > /etc/ssh/sshd_config.d/zz-demo-review.conf <<'SSHD'
# a+Terminal review demo: global is key-only; only `demo` may use a password.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
Match User demo
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
SSHD
sshd -t
systemctl restart ssh

echo "==> firewall (only 22/tcp) + fail2ban"
ufw allow 22/tcp
ufw --force enable
cat > /etc/fail2ban/jail.d/sshd.local <<'F2B'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
F2B
systemctl enable --now fail2ban
systemctl restart fail2ban || true

echo "==> message of the day"
cat > /etc/motd <<'MOTD'

  a+Terminal — App Store review demo server
  -----------------------------------------
  This is a temporary, public demo box for evaluating the a+Terminal iOS app.
  Your login auto-attaches a tmux session ("demo") with a scrollable transcript.
  Two-finger pan up/down in the app to scroll it — that is the headline feature.

MOTD

echo "==> seeding tmux transcript + auto-attach for 'demo'"
DEMO_HOME=/home/demo
# Fetch the seed from the public repo; fall back to a minimal inline version.
if ! curl -fsSL "$RAW_SEED" -o "$DEMO_HOME/demo-seed-transcript.sh"; then
  cat > "$DEMO_HOME/demo-seed-transcript.sh" <<'SEED'
#!/usr/bin/env bash
for i in $(seq 1 200); do printf 'demo transcript line %03d — scroll me with a two-finger pan\n' "$i"; done
echo "Welcome to the a+Terminal review demo — two-finger pan to scroll."
SEED
fi
chmod +x "$DEMO_HOME/demo-seed-transcript.sh"

# tmux: enable mouse so the app's gesture→SGR-wheel bridge scrolls scrollback.
cat > "$DEMO_HOME/.tmux.conf" <<'TMUX'
set -g mouse on
set -g history-limit 10000
TMUX

# On session creation: print the transcript, then drop to an interactive shell.
cat > "$DEMO_HOME/.tmux-demo-init.sh" <<'INIT'
#!/usr/bin/env bash
"$HOME/demo-seed-transcript.sh" 2>/dev/null || true
exec bash -i
INIT
chmod +x "$DEMO_HOME/.tmux-demo-init.sh"

# On interactive login: attach (or create) the 'demo' tmux session. Guard nesting.
cat > "$DEMO_HOME/.bash_profile" <<'PROFILE'
[ -f ~/.bashrc ] && . ~/.bashrc
if [ -z "${TMUX:-}" ] && [[ $- == *i* ]]; then
    tmux attach -t demo 2>/dev/null || tmux new -s demo "$HOME/.tmux-demo-init.sh"
fi
PROFILE

chown -R demo:demo "$DEMO_HOME"

IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo '<server-ip>')"
cat <<SUMMARY

==========================================================
  a+Terminal review demo server is READY.
  Paste these into App Store Connect → Review Notes:

      Host:     ${IP}
      Port:     22
      Username: demo
      Password: ${PW}
      Auth:     Password

  (Verify from a clean device before submitting. Destroy
   the VM after the app is Ready for Sale.)
==========================================================
SUMMARY
