# BACKLOG

## Canvas Frontend

- Full-screen terminal apps do not restore deterministically after browser refresh.
  Current repros include `vim`, `vi`, `less`, `htop`, and similar TUI apps inside `ab-front`.
  The current reconnect path mixes scrollback replay, live PTY output, and resize-based redraw, which creates race conditions and intermittent garbage like `?2048;0$y`.
  Product expectation:
  - full-screen terminal apps must restore correctly after browser refresh
  - recovery must be deterministic and must not corrupt the terminal buffer
  Open design options to evaluate:
  - terminal-state snapshot/restore
  - tmux/screen-based persistence model
  - another deterministic PTY/TUI recovery design
