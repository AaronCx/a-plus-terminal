# Screenshots checklist

App Store Connect requires 6.9" (iPhone 17 Pro Max class) shots; 6.5" are
auto-scaled from them. Capture in the simulator (`Cmd+S`) or on device.

## Shot list (in display order)

- [x] 1. Terminal session running a CLI agent inside tmux (the hero shot) —
      caption: "Your AI agent, in your pocket" (brand-neutral — no third-party
      trademark in the marketing caption, per Guideline 5.2.1; uploaded to ASC)
- [ ] 2. Mid-scroll transcript with momentum — caption: "Scrolling that
      finally works in tmux"
- [ ] 3. Dictation sheet with live waveform + transcript — caption: "Speak
      your prompts — transcribed on-device"
- [ ] 4. Dynamic Island expanded with 2–3 sessions — caption: "Your sessions,
      at a glance"
- [ ] 5. Terminal tab: sessions + server list with Key badges — caption:
      "All your servers, one tap away"
- [ ] 6. Settings tab showing App Protection + "Data Not Collected" privacy
      copy — caption: "Zero data collection. Actually zero."

## Rules

- Statusbar: use `xcrun simctl status_bar override` for clean 9:41 shots
- No personal hostnames/IPs in any shot — use `mini.local` / `100.x.y.z`
  placeholders
- Dark mode for terminal shots, light mode for Settings shot
- No device frames needed (App Store renders its own)

## Before submission

- [ ] Record the 15–30s demo video for review notes (connect → tmux → scroll
      → dictate → Island tap-back)
- [ ] App icon final export via Icon Composer (human step)
