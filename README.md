# tmux-agent-tracker

[![tests](https://github.com/ulas96/tmux-agent-tracker/actions/workflows/tests.yml/badge.svg)](https://github.com/ulas96/tmux-agent-tracker/actions/workflows/tests.yml)
[![MIT licence](https://img.shields.io/github/license/ulas96/tmux-agent-tracker)](LICENSE)

Keep an eye on every Claude Code and Codex CLI session you have running, without
going to look for them.

<!-- Record a demo, drop it at docs/demo.gif, and uncomment:
![tmux-agent-tracker](docs/demo.gif)
-->

The agents get a status line of their own: each one's task name, with what it
wants hanging off the top right corner.

```
✳¹ᵠ   waiting on you        yellow
✳²ᶜ   done, not looked at   orange
✳³ᶜ   done, and you have    green
✳⁴    working               blue, with a spinner
```

A finished agent stays orange until you have actually been to its pane — the one
you are sitting in is checked off, so orange means "this one has something you
have not read". Set it working again and it goes back to orange when it next
finishes.

Every tracked pane also gets a numbered badge on its bottom border, so you can
see which agent is which. Then jump straight to whichever one needs you —
`prefix + Q` goes to the next agent that is waiting, `prefix + A 3` to the third.

```
┌──────────────────────┬──────────────────────┐
│ nvim                 │ codex                │
│                      │                      │
└─ 0 nvim ─────────────┴─ ✳¹ᵠ salt-data-lake ─┘
┌──────────────────────┬──────────────────────┐
│ claude               │ codex                │
└─ ✳²ᶜ luima ──────────┴─ ✳³ erp ─────────────┘
```

The two bars sit together at whichever end you keep your status line:

```
 session │ 1:erp 2:luima 3:kal │ 14:32          <- your theme, untouched
 five-salt-gradesᵠ  luima-securityᶜ  kal-b6ᶜ    <- the agent bar
```

or with `@agent-tracker-bottom-bar 'on'`, at opposite ends with the panes
between them:

```
 session │ 1:erp 2:luima 3:kal │ 14:32          <- your theme, at the top
┌──────────────────────┬──────────────────────┐
│ claude               │ codex                │
└─ ✳¹ᵠ luima ──────────┴─ ✳²ᶜ erp ────────────┘
 five-salt-gradesᵠ  luima-securityᶜ  kal-b6ᶜ    <- the agent bar, last row
```

Every live session gets a slot. Names shrink to fit — the bar sizes itself to
the narrowest attached client — and once they are as short as they usefully go,
the remainder is counted as a `+3` on the end rather than quietly falling off
the edge.

By default your `status-position` is left alone and the agent bar goes directly
next to your theme — the row under it at the top, or the last row at the bottom.

### Theme at the top, agents at the bottom

```tmux
set -g @agent-tracker-bottom-bar 'on'
```

Puts the panes *between* the two, which is worth explaining because tmux has no
setting for it. `status-position` is a single value for the whole status block —
not an array — so however many status lines you ask for, they all sit at the same
end. A bar at the bottom while the theme is at the top cannot be a status line.

What can live down there is a pane. With `pane-border-status bottom`, a pane one
row high has *zero* rows of content and one row of border, drawn full width
across the window's last row. So the border is the bar, and the pane behind it is
an inert placeholder that draws nothing and costs a single row — the same as a
status line would.

It holds up in practice: tmux's own pane navigation skips a zero-height pane, so
you cannot land in it, and a hook puts the placeholder back when a new window
appears or `select-layout` throws it out of position. What you are trading away:

- a placeholder pane per window, each holding an idle `sleep` loop
- `tmux-resurrect` saves them like any other pane. It does not save the pane
  option marking them as ours, so they come back anonymous; they are recognised
  by shape and adopted instead of being rebuilt alongside, which needs nothing
  from you.

Turning `@agent-tracker-pane-border` off still leaves the bar: the badge row
under every other pane goes away, the bar pane's border stays.

## How it knows

| Provider | Discovery | Scope |
|---|---|---|
| Claude Code | native `~/.claude/sessions/<pid>.json` records | interactive tmux panes; automatic |
| Codex CLI | foreground process for immediate presence; trusted hooks for lifecycle state | local interactive CLI in tmux; presence automatic, state opt-in |

Claude Code writes a small JSON file per running process containing its status,
task name and working directory:

```json
{"pid":40050,"cwd":"/Users/you/kal","name":"kal-b6","status":"idle", ...}
```

Codex does not expose an equivalent stable status file. Its documented
lifecycle hooks call the bundled bridge, which stores only provider, session id,
PID, tmux pane id, cwd, normalized status and a Unix-seconds update timestamp. It never reads
or stores prompts, assistant messages, tool inputs/results, transcripts,
credentials or environment dumps.

Some Codex CLI startup paths defer `SessionStart` until the first prompt. A
brand-new foreground `codex` process therefore appears immediately as a gray
unknown entry; its first trusted hook event replaces that provisional presence
with real busy, waiting or complete state.

The poll reads both sources in one bounded gathering pass, walks each PID up the
process tree to its tmux pane, merges the records and draws one roster. A dead PID
or a Codex record whose ancestry no longer reaches its recorded pane is dropped;
mtime is not treated as proof of life.

Nothing is installed into Claude Code. Immediate Codex presence is automatic;
lifecycle-state setup is opt-in because Codex asks you to review and trust
non-managed hooks.

## Install

With [TPM](https://github.com/tmux-plugins/tpm), in `tmux.conf`:

```tmux
set -g @plugin 'ulas96/tmux-agent-tracker'
```

Then `prefix + I`.

**Put it after your theme.** The agent bar is a second status line, and themes
set `status` and `status-position` wholesale — one loaded afterwards will undo
it.

Without TPM, clone it and source the entry point:

```tmux
run-shell ~/path/to/tmux-agent-tracker/agent-tracker.tmux
```

Needs `tmux` 3.0+ and `lua` 5.1+ (LuaJIT is fine). On macOS: `brew install lua`.
The one thing that wants newer is the picker's colours — `display-menu` only
learnt to take them in tmux 3.4, so below that `M-a l` opens in tmux's own.

TPM installs to `~/.tmux/plugins/`, or `~/.config/tmux/plugins/` if that is where
your `tmux.conf` lives. Paths below use the second; substitute if yours differ.

[INTEGRATION.md](INTEGRATION.md) is the step by step version, with a check after
each one and a troubleshooting section keyed to them.

### Enable Codex CLI tracking

The tmux plugin never edits Codex configuration at startup. Print the current,
absolute hook definition explicitly:

```sh
tracker=~/.config/tmux/plugins/tmux-agent-tracker/bin/tmux-agent-tracker
"$tracker" codex-hook-config > /tmp/tmux-agent-tracker-hooks.json
```

Review that file, then either install it as `~/.codex/hooks.json` when no hook
file exists, or merge its seven event groups into the existing top-level
`hooks` object. Do not replace unrelated hooks. Re-running the merge must keep
only one tracker handler per event. Start/restart Codex, open `/hooks`, inspect
the source and exact command, and trust it; untrusted hooks are skipped.
This follows Codex's current [lifecycle hooks documentation](https://learn.chatgpt.com/docs/hooks).

The bridge covers `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PermissionRequest`, `PostToolUse`, `Stop` and `SessionEnd`. Codex records use
`idle` for a stopped turn, which renders through the existing finished/unread
behavior. Approval waiting is best-effort: `PermissionRequest` is tracked, but
other UI-specific questions may not emit that event.

An unprompted new Codex TUI is still shown immediately with the gray `·` state.
That entry is process-backed and provisional until Codex emits its first hook.

To disable tracking without deleting state:

```tmux
set -g @agent-tracker-providers 'claude'
```

To uninstall the bridge, disable/remove only the exact tracker entries shown by
`/hooks`, then remove its state directory after Codex sessions have exited. The
default is `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-agent-tracker-${UID}/codex`.

## Keys

Nothing stock is overridden. `prefix + 1`, `n`, `p`, `w`, `z` and `C` still do
what tmux has always done — window switching, `choose-tree`, zoom,
`customize-mode`.

| Key | Does |
|---|---|
| `M-a` | agent mode, see below — its own prefix, no tmux prefix needed |
| `prefix + a` | the same, for terminals that swallow Meta |
| `prefix + N` / `P` | next / previous agent, and follow it |
| `prefix + W` | back to the selected agent |
| `prefix + Z` | back to it, zoomed |
| `prefix + Q` | next agent **waiting** on you |
| `prefix + F` | next **finished** agent |
| `prefix + Tab` | flip between the last two |

`M-a` acts as a prefix of its own: press it, then one key is the whole command —
`M-a n` for the next agent, `M-a 1` for the first. The bare number keys are free
in there, which is the only way to get `1`–`9` without taking `select-window` off
the tmux prefix. The status bar shows `agent` while it is active.

On macOS the terminal has to send Option as Meta or `M-a` never reaches tmux:
Ghostty `macos-option-as-alt = left`; iTerm2 → Profiles → Keys → Left Option →
*Esc+*; Terminal.app → Profiles → Keyboard → *Use Option as Meta key*.

| Key | Does | |
|---|---|---|
| `1`–`9` | jump to that agent | exits |
| `n` / `p` | next / previous | stays |
| `q` / `c` | next waiting / next finished | stays |
| `w` / `z` | go to selected / go and zoom | exits |
| `l` | pick from a menu | exits |
| `Tab` | last agent | stays |
| `r` | rename the selected agent | exits |
| `R` | redraw now | stays |
| `Escape` | leave | |

`r` opens a prompt with the current name in it. What you type becomes the name
on the bar and pane border; submitting it empty hands naming back to the
provider. The override is tagged with the current agent session, so closing an
agent and starting another in the same pane cannot carry the old name across.

Without an override, the bar uses the chat name reported by the provider. If the
provider has no chat name, as with the current Codex hook data, it uses the
working folder's name instead.

Keys you press repeatedly to hunt through the roster keep agent mode active.
Keys that land you somewhere you are about to type in drop out of it, so your
next keystroke goes to the agent and not to a binding.

Moving between panes tmux's own way counts too: walk into an agent's pane with
`prefix + →`, vim-tmux-navigator's `C-l`, or a mouse click, and that agent
becomes the selected one. So `prefix + Tab` flips back to where you came from
and the bar highlights where you actually are, whichever way you got there.
`@agent-tracker-follow 'off'` leaves the selection where the bindings put it.

## Configure

Set any of these before the plugin loads.

```tmux
set -g @agent-tracker-icon '✳'
set -g @agent-tracker-symbol-waiting 'ᵠ'
set -g @agent-tracker-symbol-complete 'ᶜ'
set -g @agent-tracker-symbol-unchecked 'ᶜ'    # finished, and you have not been
set -g @agent-tracker-symbol-busy ''          # empty means animate a spinner
set -g @agent-tracker-symbol-unknown '·'      # a status we do not recognise
set -g @agent-tracker-spinner '⠒,⠢,⠤,⠔'        # frames, centred in the cell

set -g @agent-tracker-color-waiting '#f9e2af'
set -g @agent-tracker-color-complete '#a6e3a1'
set -g @agent-tracker-color-unchecked '#fab387'
set -g @agent-tracker-color-busy '#89b4fa'
set -g @agent-tracker-color-unknown '#6c7086'
set -g @agent-tracker-color-selected '#f5c2e7'

set -g @agent-tracker-module-style ''         # empty = plain text; see below
set -g @agent-tracker-separators ''           # the caps, as a comma pair

set -g @agent-tracker-label 'dir'             # pane border: dir | name | both
set -g @agent-tracker-label-width '20'

set -g @agent-tracker-bar-label 'name'        # agent bar: name | dir | both
set -g @agent-tracker-bar-width '18'          # a ceiling; names shrink to fit
set -g @agent-tracker-bar-separator '  '

set -g @agent-tracker-max '0'                 # 0 = every live agent; N caps it
set -g @agent-tracker-interval '1'            # seconds
set -g @agent-tracker-providers 'claude,codex'
set -g @agent-tracker-claude-sessions-dir ''  # specific option; empty uses legacy below
set -g @agent-tracker-codex-state-dir ''      # empty = secure per-user runtime default

set -g @agent-tracker-keys 'on'
set -g @agent-tracker-follow 'on'             # tmux pane moves change the selection
set -g @agent-tracker-pane-border 'on'
set -g @agent-tracker-bar 'on'                # the dedicated status line
set -g @agent-tracker-bottom-bar 'off'        # or the window's last row instead
set -g @agent-tracker-status-position 'off'   # 'off' keeps yours; or 'top'/'bottom'
set -g @agent-tracker-alert 'off'             # message when an agent starts waiting
set -g @agent-tracker-sessions-dir '~/.claude/sessions'  # legacy Claude alias
```

If you override `codex-state-dir`, regenerate the hook definition with the same
absolute path so writer and poll agree:

```sh
"$tracker" codex-hook-config /absolute/private/state-dir
```

Plain letters instead of superscripts, if your font is unhappy:

```tmux
set -g @agent-tracker-symbol-waiting 'q'
set -g @agent-tracker-symbol-complete 'c'
```

### Matching a powerline theme

Out of the box each agent is coloured text, which needs no particular font.
Themes that draw their modules as pills — catppuccin, powerline, most of the
popular ones — want the same shape here, and two options give it:

```tmux
set -g @agent-tracker-module-style 'fg=#cdd6f4,bg=#313244'
set -g @agent-tracker-separators ','        # U+E0B6, U+E0B4 — needs a Nerd Font
```

`module-style` is the switch: with it set, each agent becomes a module with its
status glyph cut out of the status colour and its name on that background. The
picker menu takes the same colours. `separators` adds the caps on either end —
set it to `''` for flat pills, or leave both unset for the plain text above.

The colour behind the caps is read from your own `status-bg`, so the bar joins
the band your theme already draws rather than cutting a strip across it. Pills
cost about five columns per agent; the bar shrinks names to pay for them.

### Keeping your own status bar

`@agent-tracker-bar 'off'` stops it adding a status line at all, and you place
the output wherever you want it. `status` prints the names, `roster` prints the
compact `✳¹ᵠ ✳²ᶜ` badges, which is the one that fits on a shared line:

```tmux
set -g status-right "#(~/.config/tmux/plugins/tmux-agent-tracker/bin/tmux-agent-tracker roster) %H:%M"
```

Whichever you use runs the same single poll, so pick one — running both doubles
the work for no benefit. Raise `status-right-length` past its 40 column default
or the badges get cut off.

## My setup

This is what I actually run, in `~/.config/tmux/tmux.conf`:

```tmux
set -g prefix C-a
unbind C-b
bind-key C-a send-prefix

set -g base-index 1
set -g mouse on
set -g status-position top    # the agent bar lands on the row underneath
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

prints provider readiness, secure-source counts, and every live pane-backed
agent it can see. For Claude, an empty list usually means it is outside tmux or
the sessions directory moved. For Codex, `live provisional` confirms a blank TUI
was found before its first hook; otherwise check `/hooks` trust, that the CLI is
inside tmux, and that `codex state` is not reported as insecure.

No second status line at all usually means a theme loaded after this plugin and
set `status` back to `on`. Load this plugin last.

## Development

```sh
lua tests/run.lua
```

No framework, just asserts. They cover the JSON codec, both provider adapters,
hook transitions and PID matching, process-tree merging, roster ordering, badge
rendering and navigation arithmetic, and run under Lua 5.1 through 5.5 plus
LuaJIT.

## Licence

MIT
