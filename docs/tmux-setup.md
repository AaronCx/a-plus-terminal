# Recommended tmux setup for a+Terminal

a+Terminal translates swipes into mouse wheel events when the remote app asks for
mouse reporting. tmux only asks when mouse mode is on, so add this to
`~/.tmux.conf` on the host:

```tmux
set -g mouse on
```

Then reload tmux (`tmux source-file ~/.tmux.conf` or restart the server).

With mouse mode on, a swipe in a+Terminal scrolls tmux's own copy-mode history —
your agent's transcript scrolls exactly like on desktop, with momentum.

Without it, a+Terminal falls back to sending arrow keys on the alternate screen
(3 lines per ~18pt of travel), which works for `less`/`vim` but can't reach
tmux scrollback.

a+Terminal shows a one-time hint the first time it detects this situation
(alternate screen, no mouse reporting). The behavior is configurable in
Settings → Scrolling.
