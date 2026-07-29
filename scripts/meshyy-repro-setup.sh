#!/usr/bin/env bash
# Sets up a LOCAL reproduction of the meshyy path: a real SSH connection from the
# simulator to this Mac, against a real meshyyd.
#
# Exists because five builds were shipped to a device to chase a bug that a count on
# the daemon would have shown in seconds. The simulator sandbox cannot read ~/.ssh, so
# the key is handed over as a raw seed in /tmp.
set -euo pipefail
KEY="$HOME/.ssh/aplus_probe"
SEED="/tmp/aplus-probe-seed.b64"

if ! nc -z 127.0.0.1 22 2>/dev/null; then
    echo "Remote Login is off — enable it in System Settings > General > Sharing" >&2
    exit 1
fi

[[ -f "$KEY" ]] || ssh-keygen -t ed25519 -f "$KEY" -N "" -C "aplus-meshyy-repro (safe to delete)" -q
if ! grep -qF "$(cut -d' ' -f2 "$KEY.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    cat "$KEY.pub" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
    echo "authorized the probe key"
fi

# The simulator cannot parse an OpenSSH private key, so hand it the raw 32-byte seed.
python3 - "$KEY" "$SEED" <<'PY'
import base64, struct, sys, pathlib
raw = pathlib.Path(sys.argv[1])
blob = base64.b64decode("".join(l for l in raw.read_text().splitlines() if "---" not in l))
off = len(b"openssh-key-v1\0")
def s(b, o):
    (n,) = struct.unpack(">I", b[o:o+4]); return b[o+4:o+4+n], o+4+n
_, off = s(blob, off); _, off = s(blob, off); _, off = s(blob, off)
off += 4
_, off = s(blob, off)
priv, _ = s(blob, off)
o = 8
_, o = s(priv, o); _, o = s(priv, o); key, _ = s(priv, o)
pathlib.Path(sys.argv[2]).write_text(base64.b64encode(key[:32]).decode())
PY
chmod 644 "$SEED"

# The simulator's NSUserName() is not necessarily this Mac's login name, and the
# username is what sshd matches the key against — so state it rather than guess.
printf '%s' "$USER" > /tmp/aplus-probe-user.txt
chmod 644 /tmp/aplus-probe-user.txt

pgrep -f "meshyyd serve" >/dev/null || { echo "meshyyd is not running — scripts/install-agent.sh --release in the meshyy repo" >&2; exit 1; }
echo "ready: probe key authorized, seed at $SEED, meshyyd up"
