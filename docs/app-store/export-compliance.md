# Export compliance (encryption)

a+Terminal uses only **standard, widely-available encryption**: SSH via SwiftNIO
SSH / Citadel and Apple's OS-provided CryptoKit. It implements no proprietary or
non-standard cryptography of its own. On that basis it qualifies for the
encryption exemption in Category 5, Part 2 — the app calls standard protocols
(SSH/TLS) and the operating system's crypto rather than supplying its own.
No export license, no Encryption Registration Number (ERN), and no annual
self-classification report is required.

## App Store Connect answers

| Question | Answer |
|---|---|
| Does your app use encryption? | **Yes** |
| Does your app qualify for any of the exemptions provided in Category 5, Part 2? | **Yes** — it only uses encryption within standard protocols (SSH/TLS) and Apple's OS crypto |
| Is your app going to be available in France? | Yes (standard exemption covers it) |

`ITSAppUsesNonExemptEncryption` is already set to `NO` in the Info.plist
(see `project.yml`), so App Store Connect won't re-ask per build. Because the
app qualifies for the exemption, there is nothing further to file.

## Note: open-source basis (optional, not required)

a+Terminal's source is published under the MIT License at
<https://github.com/AaronCx/a-plus-terminal>. If a belt-and-suspenders posture
is ever wanted, publicly-available encryption source code can be notified to BIS
under 15 CFR §740.13(e) — a **one-time** email (not an annual report) to
`crypt@bis.doc.gov` and `enc@nsa.gov` with the repository URL. This is
optional; the standard-protocol / OS-crypto exemption above already covers the
shipped app.
