# Security Policy

a+Terminal is a privacy-first SSH client. It collects no data, makes no
third-party network calls, and keeps all keys and passwords in the iOS
Keychain on-device. Because security is core to the app, vulnerability reports
are very welcome.

## Supported versions

The latest App Store / TestFlight release is supported. Fixes ship in a new
release rather than as back-patches.

## Reporting a vulnerability

Please report security issues **privately** rather than opening a public issue:

- Preferred: open a [GitHub Security Advisory](https://github.com/AaronCx/a-plus-terminal/security/advisories/new)
  (Security → Advisories → "Report a vulnerability").

Include steps to reproduce and the affected version/build where possible. You
can expect an initial response within a few days. Confirmed issues are fixed in
the next release and credited unless you prefer to remain anonymous.

## Host-key verification (trust-on-first-use)

a+Terminal pins a server's host key on the first connection and **hard-fails**
on any later mismatch (no "accept anyway" path), surfacing the expected vs.
presented fingerprints. The first connection itself is trusted silently — the
common trust-on-first-use model for mobile SSH clients — so the protection is
against a key *changing* under you, not against a MITM on the very first
connect. If a server is legitimately reinstalled, remove and re-add it to
re-pin. (A future enhancement could prompt to confirm the fingerprint on first
connect; the mismatch protection is the property that matters most today.)

## Scope

In scope: the app's handling of SSH credentials/keys, host-key verification
(trust-on-first-use pinning), Keychain storage, attachment upload, and any path
that could leak data off-device. Out of scope: vulnerabilities in the user's
own SSH servers or networks, and issues requiring a jailbroken device.
