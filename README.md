# tmux-agent-tracker

Keep an eye on every Claude Code session you have running, without going to look
for them.

Each Claude pane gets a small badge on its bottom border, and a numbered roster
sits in the status bar. The badge says which agent it is and what it wants:

```
✳¹ᵠ   waiting on you        yellow
✳²ᶜ   done, sitting idle    green
✳³    working               blue, with a spinner
```

Then jump straight to whichever one needs you — `prefix + Q` goes to the next
agent that is waiting, `prefix + A 3` goes to the third one.

```
┌──────────────────────┬──────────────────────┐
│ nvim                 │ claude               │
│                      │                      │
└─ 0 nvim ─────────────┴─ ✳¹ᵠ salt-data-lake ─┘
┌──────────────────────┬──────────────────────┐
│ claude               │ claude               │
└─ ✳²ᶜ luima ──────────┴─ ✳³ erp ─────────────┘
 session │ ✳¹ᵠ ✳²ᶜ ✳³ │ 14:32
```

## How it knows

Claude Code writes a small JSON file per running process to
`~/.claude/sessions/<pid>.json`, containing its status, the task name and the
working directory:

```json
{"pid":40050,"cwd":"/Users/you/kal","name":"kal-b6","status":"idle", ...}
```

The plugin reads those, walks up the process tree from each pid until it reaches
a pane, and draws what it finds. `status` is `waiting`, `idle` or `busy`, which
is exactly the three things worth knowing.

Nothing is installed into Claude Code — no hooks, no changes to `settings.json`.
If an agent exits, its pid stops resolving to a pane and it drops off the roster
on its own.

## Install

With [TPM](https://github.com/tmux-plugins/tpm), in `tmux.conf`:

```tmux
set -g @plugin 'ulas96/tmux-agent-tracker'
```

Then `prefix + I`.

**Put it after your theme.** The roster is appended to `status-right`, and
themes assign that wholesale — a theme loaded afterwards will overwrite it.

Without TPM, clone it and source the entry point:

```tmux
run-shell ~/path/to/tmux-agent-tracker/agent-tracker.tmux
```

Needs `tmux` 3.0+ and `lua` 5.1+ (LuaJIT is fine). On macOS: `brew install lua`.

## Keys

Nothing stock is overridden. `prefix + 1`, `n`, `p`, `w`, `z` and `C` still do
what tmux has always done — window switching, `choose-tree`, zoom,
`customize-mode`.

| Key | Does |
|---|---|
| `prefix + A` | agent mode, see below |
| `prefix + N` / `P` | next / previous agent, and follow it |
| `prefix + W` | back to the selected agent |
| `prefix + Z` | back to it, zoomed |
| `prefix + Q` | next agent **waiting** on you |
| `prefix + F` | next **finished** agent |
| `prefix + Tab` | flip between the last two |

`prefix + A` enters agent mode, where the bare number keys are free — the only
way to get `1`–`9` without taking `select-window` off the prefix. The status bar
shows `agent` while it is active.

| Key | Does | |
|---|---|---|
| `1`–`9` | jump to that agent | exits |
| `n` / `p` | next / previous | stays |
| `q` / `c` | next waiting / next finished | stays |
| `w` / `z` | go to selected / go and zoom | exits |
| `l` | pick from a menu | exits |
| `Tab` | last agent | stays |
| `r` | redraw now | stays |
| `Escape` | leave | |

Keys you press repeatedly to hunt through the roster keep agent mode active.
Keys that land you somewhere you are about to type in drop out of it, so your
next keystroke goes to the agent and not to a binding.

## Configure

Set any of these before the plugin loads.

```tmux
set -g @agent-tracker-icon '✳'
set -g @agent-tracker-symbol-waiting 'ᵠ'
set -g @agent-tracker-symbol-complete 'ᶜ'
set -g @agent-tracker-symbol-busy ''          # empty means animate a spinner
set -g @agent-tracker-spinner '⠂,⠄,⠆,⠇,⠋,⠉,⠈,⠉'

set -g @agent-tracker-color-waiting '#f9e2af'
set -g @agent-tracker-color-complete '#a6e3a1'
set -g @agent-tracker-color-busy '#89b4fa'
set -g @agent-tracker-color-selected '#f5c2e7'

set -g @agent-tracker-label 'dir'             # dir | name | both
set -g @agent-tracker-label-width '20'
set -g @agent-tracker-max '9'                 # roster length; the menu shows all
set -g @agent-tracker-interval '1'            # seconds

set -g @agent-tracker-keys 'on'
set -g @agent-tracker-pane-border 'on'
set -g @agent-tracker-status-append 'on'
set -g @agent-tracker-status-position 'bottom'  # or 'off' to leave yours alone
set -g @agent-tracker-alert 'off'             # message when an agent starts waiting
set -g @agent-tracker-sessions-dir '~/.claude/sessions'
```

Plain letters instead of superscripts, if your font is unhappy:

```tmux
set -g @agent-tracker-symbol-waiting 'q'
set -g @agent-tracker-symbol-complete 'c'
```

### Keeping your own status bar

`@agent-tracker-status-append 'off'` stops it touching `status-right`, and you
place the roster yourself:

```tmux
set -g status-right "#(~/.config/tmux/plugins/tmux-agent-tracker/bin/tmux-agent-tracker status) %H:%M"
```

## My setup

This is what I actually run, in `~/.config/tmux/tmux.conf`:

```tmux
set -g prefix C-a
unbind C-b
bind-key C-a send-prefix

set -g base-index 1
set -g mouse on
set -g pane-active-border-style 'fg=magenta,bg=default'
set -g pane-border-style 'fg=brightblack,bg=default'

set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'christoomey/vim-tmux-navigator'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'omerxx/catppuccin-tmux'
set -g @plugin 'ulas96/tmux-agent-tracker'   # after catppuccin, so the roster survives

run '~/.config/tmux/plugins/tpm/tpm'
```

The defaults are Catppuccin Mocha, so it drops in without further colour work.

## When nothing shows up

```sh
~/.config/tmux/plugins/tmux-agent-tracker/bin/tmux-agent-tracker doctor
```

prints the Lua and tmux it found, where it is looking, and every agent it can
see. If the list is empty, the usual reasons are that Claude Code is running
outside tmux, or that `~/.claude/sessions` is somewhere else.

The roster getting cut off the end of the bar is `status-right-length` — the
plugin raises it to 200, but a theme loaded afterwards will have lowered it
again. Load this plugin last.

## Development

```sh
lua tests/run.lua
```

No framework, just asserts. They cover the JSON decoding, the process-tree walk,
roster ordering, badge rendering and the navigation arithmetic, and they run
under 5.1 through 5.5.

## Licence

MIT
