# Live QA: the localhost preview tunnel

`aPlusTerminalTests/PreviewLiveTests.swift` moves real bytes through a real SSH
connection to a real dev server. It skips unless the fixture below exists, so
`make test` and CI stay hermetic.

Everything here is throwaway and local. It deliberately does **not** enable
macOS Remote Login or touch `~/.ssh` — the test gets its own sshd on a high
port and its own key.

## 1. A throwaway sshd on port 2222

```sh
S=/tmp/aplus-preview-qa; rm -rf "$S"; mkdir -p "$S"; cd "$S"
ssh-keygen -q -t ed25519 -f host_ed25519   -N "" -C testhost
ssh-keygen -q -t ed25519 -f client_ed25519 -N "" -C testclient
cp client_ed25519.pub authorized_keys
chmod 600 authorized_keys host_ed25519 client_ed25519

cat > sshd_config <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $S/host_ed25519
AuthorizedKeysFile $S/authorized_keys
PidFile $S/sshd.pid
PasswordAuthentication no
UsePAM no
PubkeyAuthentication yes
AllowTcpForwarding yes
StrictModes no
EOF

/usr/sbin/sshd -f "$S/sshd_config" -E "$S/sshd.log"
ssh -p 2222 -i "$S/client_ed25519" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null "$USER"@127.0.0.1 'echo SSH_OK'
```

Runs as your own user — no `sudo`, no system settings changed. Stop it with
`kill $(cat "$S/sshd.pid")`.

## 2. A Vite app with a large asset

```sh
mkdir -p /tmp/aplus-preview-app/public && cd /tmp/aplus-preview-app
npm init -y >/dev/null && npm i -D vite >/dev/null
printf '<!doctype html><html><head><title>preview-live</title></head><body><h1 id="marker">MARKER_V1</h1><script type="module" src="/main.js"></script></body></html>' > index.html
printf "import { label } from './label.js'\ndocument.getElementById('marker').textContent = label\n" > main.js
printf "export const label = 'MARKER_V1'\n" > label.js
# 4 MiB, for the truncation regression test
python3 -c "open('public/big.txt','w').write((('abcdefghijklmnopqrstuvwxyz0123456789'*32+chr(10))*4000)[:4*1024*1024])"
node_modules/.bin/vite --port 5173 --strictPort --host 127.0.0.1 &
```

`public/` is scanned at startup — if you add `big.txt` to a running server,
restart it or Vite serves the SPA fallback instead (a 214-byte `index.html`,
which makes the size assertion fail confusingly).

## 3. The fixture

The tests read a JSON file rather than environment variables. `TEST_RUNNER_`-
prefixed variables are forwarded to the **UI-test runner** process; these are
app-hosted unit tests, so those variables never arrive and every assertion
silently skips.

```sh
python3 - <<PY
import json
json.dump({"host":"127.0.0.1","port":2222,"user":"$USER",
           "keyPEM":open("/tmp/aplus-preview-qa/client_ed25519").read(),
           "devPort":5173},
          open("/private/tmp/aplusterminal-preview-live.json","w"))
PY
chmod 644 /private/tmp/aplusterminal-preview-live.json
```

## 4. Run

```sh
make generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project aPlusTerminal.xcodeproj -scheme aPlusTerminal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:aPlusTerminalTests/PreviewLiveTests test
```

Delete the fixture afterwards — it contains a private key, throwaway or not:

```sh
rm -f /private/tmp/aplusterminal-preview-live.json
```

## What this does and does not prove

**Proves:** a Vite module graph executes through the tunnel; a 4 MiB asset
arrives byte-for-byte (the regression guard for the teardown truncation bug); a
WebSocket upgrade survives the channel, both raw and from the page; `lsof`
ground truth finds the dev server on a real host.

**Does not prove: port-matched HMR.** The Simulator shares the host's network
stack, so the Mac's dev server already owns `127.0.0.1:5173` on the very
loopback the app binds. The forward therefore always takes its collision
fallback here and the ports cannot match — which is exactly the condition under
which Vite's hardcoded `localhost:<devPort>` HMR socket does not reconnect. That
is a property of running both ends on one machine. On a real iPhone the phone's
`5173` is free, so this is an on-device check.

## Gotcha worth remembering

Vite 5.4.12+ (CVE-2025-24010) rejects any WebSocket upgrade that carries an
`Origin` header without a `?token=`, with a bare `400 Bad Request`. Browsers
always send `Origin`, so a hand-rolled `new WebSocket(...)` fails every time and
looks precisely like "the tunnel dropped the upgrade". The token is emitted into
`/@vite/client`. This cost an hour and nearly bought an ATS exception the app
does not need — confirmed by reverting it and watching nothing change.
