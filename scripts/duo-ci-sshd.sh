#!/bin/bash
# A throwaway sshd on 127.0.0.1 for the Duo UI test (DuoLayoutUITests), so a
# CI runner can open a REAL terminal session without any secret: fresh host
# and client keys every run, loopback only, this user only, key auth only.
#
# The login runs a shell whose background job writes the pty size the SERVER
# sees (`stty size` -> "rows cols") to ~/.aplus-duo/grid.txt whenever it
# changes, and prints it into the terminal too, so screenshots show it.
# The UI test reads the seed and the grid from ~/.aplus-duo — the simulator
# shares the host filesystem — so the private key never passes through the
# environment or a build setting (which xcodebuild would echo into the log).
#
# Usage: scripts/duo-ci-sshd.sh start|stop
set -euo pipefail

dir="$HOME/.aplus-duo"
port="${APLUS_DUO_SSHD_PORT:-2222}"

case "${1:-}" in
stop)
  if [ -f "$dir/sshd.pid" ]; then
    pid=$(cat "$dir/sshd.pid")
    kill "$pid" 2>/dev/null || sudo -n kill "$pid" 2>/dev/null || true
  fi
  rm -rf "$dir"
  exit 0
  ;;
start) ;;
*) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac

rm -rf "$dir"
mkdir -p "$dir"
chmod 700 "$dir"
ssh-keygen -q -t ed25519 -N '' -C aplus-duo-host -f "$dir/host_ed25519"
ssh-keygen -q -t ed25519 -N '' -C aplus-duo-client -f "$dir/client_ed25519"
cp "$dir/client_ed25519.pub" "$dir/authorized_keys"
chmod 600 "$dir/authorized_keys"

# The login shell. Interactive logins get the grid reporter; anything else
# (the readiness probe below) just runs its command.
cat > "$dir/login.sh" <<'SH'
#!/bin/bash
grid="$HOME/.aplus-duo/grid.txt"
if [ ! -t 0 ]; then exec /bin/sh -c "${SSH_ORIGINAL_COMMAND:-true}"; fi
# A background job's stdin is /dev/null, so it asks the tty by name.
tty=$(tty)
(
  last=""
  while :; do
    now=$(stty size < "$tty" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$last" ]; then
      printf '%s\n' "$now" > "$grid.tmp" && mv "$grid.tmp" "$grid"
      set -- $now
      printf '\r\n[duo grid] %s cols x %s rows\r\n' "$2" "$1"
      last="$now"
    fi
    sleep 0.3
  done
) &
export PS1='duo$ '
exec /bin/zsh -f -i
SH
chmod 755 "$dir/login.sh"

cat > "$dir/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_ed25519
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
AllowUsers $USER
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitRootLogin no
ForceCommand $dir/login.sh
LogLevel VERBOSE
EOF

# Unprivileged first: an sshd run by this user can log in only this user,
# which is all the test needs. Root (passwordless sudo, as on CI) is the
# fallback for an sshd that refuses to start without it.
/usr/sbin/sshd -f "$dir/sshd_config" -E "$dir/sshd.log" \
  || sudo -n /usr/sbin/sshd -f "$dir/sshd_config" -E "$dir/sshd.log"

# Ready = a real key login runs a command.
for _ in $(seq 1 20); do
  if ssh -q -i "$dir/client_ed25519" -p "$port" -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null -o BatchMode=yes "$USER@127.0.0.1" true; then
    break
  fi
  sleep 0.5
done
ssh -q -i "$dir/client_ed25519" -p "$port" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes "$USER@127.0.0.1" true \
  || { echo "sshd never accepted the key" >&2; cat "$dir/sshd.log" >&2; exit 1; }

# TestSeed's server JSON; the UI test hands it and the key to the app.
printf '{"name":"Duo","host":"127.0.0.1","port":%s,"username":"%s"}\n' "$port" "$USER" > "$dir/server.json"
echo "duo sshd up on 127.0.0.1:$port for $USER"
