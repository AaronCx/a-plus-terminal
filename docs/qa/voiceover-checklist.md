# VoiceOver pass — Settings & core flows

Status from the PR 12 audit. Re-verify on device with VoiceOver on
(Settings → Accessibility → VoiceOver) before each release.

## Audited and labeled in code

| Element | Label | Where |
|---|---|---|
| Add server `+` | "Add Server" | TerminalTabView toolbar |
| Session close ✕ | "Close Session" | SessionRow |
| Ctrl sticky key | "Control" + selected trait when armed | KeyAccessoryBar |
| tmux prefix key | "tmux prefix Control-B" | KeyAccessoryBar |
| Paste key | "Paste" | KeyAccessoryBar |
| Mic | "Dictate" | KeyAccessoryBar |
| Keyboard toggle | "Toggle Keyboard" | KeyAccessoryBar |
| Waveform | "Microphone level" | DictationSheet |
| Font sliders | Visible text labels via `Slider(label:)` | SettingsScreen |
| Terminal preview | "Terminal font preview" | SettingsScreen |
| tmux hint dismiss | "Dismiss Hint" | TmuxMouseHintBanner |

## Reads correctly via visible text (no extra labels needed)

- Settings toggles (Toggle uses its title), theme picker, legal links,
  support link, tip/subscription product buttons (name + price),
  server rows (name + user@host), session rows (name + start time).

## Known limitations (V1)

- The terminal canvas itself is SwiftTerm's `TerminalView`; VoiceOver support
  for terminal content is upstream's domain and limited — consistent with
  other iOS terminals.
- Dictation transcript preview is plain `Text` and is readable, but live
  updates announce only on focus change.
