# Integration guide

End to end: from an empty `tmux.conf` to a working agent bar, with a check after
every step so you find out immediately which one did not take.

The [README](README.md) is the tour. This is the runbook.

---

## Contents

- [How the pieces fit](#how-the-pieces-fit)
- [1. Prerequisites](#1-prerequisites)
- [2. Install](#2-install)
- [Codex hook setup](#codex-hook-setup)
- [3. Choose where the bar goes](#3-choose-where-the-bar-goes)
- [4. Reload and verify](#4-reload-and-verify)
- [5. Check the keys](#5-check-the-keys)
- [6. Watch a status change](#6-watch-a-status-change)
- [Configuration reference](#configuration-reference)
- [Matching your theme](#matching-your-theme)
- [Command reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Living with other plugins](#living-with-other-plugins)
- [Uninstalling](#uninstalling)
- [Testing a change](#testing-a-change)

---

## How the pieces fit

Worth two minutes before you start, because every failure below is one of these
links coming loose.

```
  Claude Code ── native ~/.claude/sessions/<pid>.json ──┐
                                                        ├─ merged records
  Codex CLI ── foreground process ── provisional presence ─┐
            └─ trusted hooks ── minimal lifecycle state ───┘
      │
      ├─ no prompts, messages, tool data or transcripts
      └─ pid + foreground/recorded pane are checked for liveness
      ▼
  tmux status line
      │  runs #(tmux-agent-tracker status) every status-interval
      ▼
  the poll  ── reads both bounded sources in the same gather command
            ── walks ppid up from each pid until it reaches a pane
            ── writes @agent_badge on each agent's pane
            └─ prints the bar, or stores it in @agent_bar_text
      ▼
  what you see
      ── pane borders   drawn from #{@agent_badge}
      └─ the agent bar  a status line, or a pane border on the last row
```

Three things follow from this, and they explain most of the troubleshooting:

- **The status line is the clock.** Nothing polls on its own. If the status line
  is off, or the plugin never got its `#()` onto it, everything freezes with no
  error.
- **The supported CLI has to be running inside tmux**, because the link from an
  agent to a pane is the process tree. An agent started outside tmux is invisible.
- **Nothing is installed into Claude Code.** No hooks, no `settings.json`
  changes. Codex hooks are a separate, explicit, reviewed opt-in.

---

## 1. Prerequisites

```sh
tmux -V                 # 3.0 or newer
lua -v || luajit -v     # 5.1 or newer; LuaJIT is fine
ls ~/.claude/sessions   # at least one <pid>.json while Claude Code is running
# Codex is optional; its hook bridge is configured after installing the plugin
```

Developed and tested against tmux 3.5a with Lua 5.5 and LuaJIT.

3.0 is a real floor, not a guess: the per-pane options the badges are written to
arrived there. One thing wants newer — the picker (`M-a l`) is coloured with
`display-menu` flags that only exist from 3.4, so below that it opens in tmux's
own colours instead. Nothing else changes.

If `lua` is missing:

| | |
|---|---|
| macOS | `brew install lua` |
| Debian/Ubuntu | `sudo apt install lua5.4` |
| Arch | `sudo pacman -S lua` |
| Fedora | `sudo dnf install lua` |

Any interpreter works; set `AGENT_TRACKER_LUA=/path/to/lua` to pin a particular
one. Nothing else is needed — no LuaRocks, no modules, no build step.

If `~/.claude/sessions` is empty, start Claude Code in a tmux pane and look
again. If it lives somewhere else, note the path for
`@agent-tracker-sessions-dir` below.

---

## 2. Install

### With TPM

```tmux
set -g @plugin 'ulas96/tmux-agent-tracker'
```

Then `prefix + I`.

> **Load it after your theme.** The plugin adds a status line and appends to
> `status-right`; a theme sourced afterwards assigns those wholesale and wipes it
> out. In practice: put this `@plugin` line *below* your theme's.

### Without TPM

```sh
git clone https://github.com/ulas96/tmux-agent-tracker ~/.tmux/plugins/tmux-agent-tracker
```

```tmux
run-shell ~/.tmux/plugins/tmux-agent-tracker/agent-tracker.tmux
```

Again, after your theme.

### Check it

Paths from here on say `~/.tmux/plugins/`, which is where TPM puts things. If
your `tmux.conf` lives under `~/.config/tmux/`, TPM follows it there and the
same paths read `~/.config/tmux/plugins/` — substitute throughout.

```sh
ls -l ~/.tmux/plugins/tmux-agent-tracker/agent-tracker.tmux
```

The executable bit must be set. TPM *executes* a plugin's `.tmux` file rather
than sourcing it; without `+x` it fails with status 126 and takes the rest of the
TPM run down with it, so your theme silently stops loading too. `chmod +x` fixes
it.

### Codex hook setup

Claude discovery is already active. Codex tracking is opt-in: the plugin never
edits `~/.codex/config.toml` or `~/.codex/hooks.json` during startup.

First print and inspect the current official `hooks.json` shape with the
absolute handler path for this installation:

```sh
tracker=~/.tmux/plugins/tmux-agent-tracker/bin/tmux-agent-tracker
"$tracker" codex-hook-config > /tmp/tmux-agent-tracker-hooks.json
chmod 600 /tmp/tmux-agent-tracker-hooks.json
```

If `~/.codex/hooks.json` does not exist, explicitly install the reviewed file:

```sh
mkdir -p ~/.codex
install -m 600 /tmp/tmux-agent-tracker-hooks.json ~/.codex/hooks.json
```

If it does exist, make a timestamped backup and merge the generated event
groups into its top-level `hooks` object. Preserve its `description` and every
unrelated hook. Each of these events must contain the tracker command exactly
once: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`,
`PostToolUse`, `Stop`, and `SessionEnd`. Do not copy the whole generated file
over an existing one. Malformed existing JSON should be repaired manually, not
replaced.

Restart Codex, enter `/hooks`, review the source and exact absolute command, and
trust it. Codex skips non-managed hooks until their current definition is
trusted; changing the plugin path or hook definition requires review again.
See Codex's current [hooks reference](https://learn.chatgpt.com/docs/hooks) for
the event schema and trust behavior.

The bridge stores only schema/provider, Codex session id, root CLI PID,
`TMUX_PANE`, cwd, the fallback name `codex`, normalized status, generic
`waiting_for: approval`, and a Unix-seconds update timestamp. It never stores or reads
prompt/assistant/tool content, `transcript_path`, auth data, or environment
dumps. The default state directory is:

```text
${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-agent-tracker-${UID}/codex/
```

The directory and files must remain user-only. `doctor` reports an insecure
directory but does not print record contents or session ids.

Codex CLI may defer `SessionStart` until the first prompt. Before that happens,
the poll recognizes only an exact foreground `codex` process attached to a tmux
pane and shows it with the gray `·` unknown state. The first hook record replaces
that provisional entry with authoritative lifecycle status.

---

## 3. Choose where the bar goes

One decision, and it is worth making deliberately because tmux constrains it.

**tmux keeps every status line at one end of the screen.** `status-position` is a
single value for the whole block — not an array — so however many status lines
you ask for, they all sit at the top or all at the bottom.

### Option A — a status line of its own (default)

The agent bar is a second status line, sitting next to your theme's: directly
under it at the top, or the last row of the screen at the bottom. Nothing to
configure.

```
 session │ 1:erp 2:luima │ 14:32     <- your theme
 fix-the-login-bugᵠ  kal-b6ᶜ         <- agents
 ┌───────────────┬───────────────┐
 │ panes below   │               │
```

### Option B — theme at the top, agents at the bottom

```tmux
set -g @agent-tracker-bottom-bar 'on'
```

Puts your panes *between* the two. Since the bottom one cannot be a status line,
it is a pane: with `pane-border-status bottom`, a pane one row high has **zero**
rows of content and one row of border drawn full width across the window's last
row. The border is the bar; the pane behind it is an inert placeholder. Costs one
row, the same as a status line.

```
 session │ 1:erp 2:luima │ 14:32     <- your theme, top
 ┌───────────────┬───────────────┐
 │ panes between │               │
 └─ ✳¹ᵠ luima ───┴─ ✳²ᶜ erp ─────┘
 fix-the-login-bugᵠ  kal-b6ᶜ         <- agents, last row
```

What you are taking on:

- a placeholder pane per window, each holding an idle `sleep` loop
- `tmux-resurrect` saves them like any other pane — see
  [Living with other plugins](#living-with-other-plugins)
- `pane-border-status` goes to `bottom` for every pane, since the border is what
  draws it — `@agent-tracker-pane-border off` drops the badges but keeps the bar

tmux's own pane navigation skips a zero-height pane, so you cannot land in one by
accident, and a hook puts the placeholder back when a window is created or
`select-layout` throws it out of position.

---

## 4. Reload and verify

```sh
tmux source-file ~/.tmux.conf     # or ~/.config/tmux/tmux.conf
```

Then work down this list. Each check has an expected answer; the first one that
disagrees is your problem, and the [troubleshooting](#troubleshooting) section is
keyed to them.

### 4.1 Does the plugin see your agents?

```sh
~/.tmux/plugins/tmux-agent-tracker/bin/tmux-agent-tracker doctor
```

```
lua             Lua 5.4
tmux            tmux 3.5a
providers       claude,codex
claude source   /home/you/.claude/sessions (2 records)
codex bridge    configured
codex state     /run/user/1000/tmux-agent-tracker-1000/codex (1 valid, 0 invalid, 0 stale; secure)
agents found    3 (claude 2, codex 1)
  [claude] 1 ✳ᶜ  work:1.2  fix-the-login-bug
  [codex] 2 ✳ᵠ  work:2.0  codex (approval)
```

`agents found 0` with a non-zero file count means the pids in those files do not
resolve to panes — the agents are dead, or running outside tmux.

Run this from inside tmux. It talks to whichever server `$TMUX` points at, so
from a plain shell it will query your default server, which may not be the one
you are looking at.

### 4.2 Is the poll actually running?

The single most useful check, because a frozen bar looks identical to an empty
one.

```sh
tmux set -gu @agent-tracker-panes    # clear it
sleep 3
tmux show -gv @agent-tracker-panes   # should have come back
```

A list of pane ids means the status line is driving the poll. Empty means it is
not — see [nothing ever appears](#nothing-ever-appears).

### 4.3 Are the pane badges being written?

```sh
tmux list-panes -a -F '#{pane_id} #{@agent_badge} #{@agent_label}'
```

Agent panes show `✳¹ᵠ` and a label; everything else is blank. Blank *everywhere*
means the poll is not running (4.2) or found nothing (4.1).

### 4.4 Is the bar wired up?

Option A:

```sh
tmux show -gv status                  # 2
tmux show -gv 'status-format[1]'      # contains tmux-agent-tracker
```

Option B:

```sh
tmux show -gv status                                    # on
tmux show -gv status-right | grep -c 'tracker status'   # exactly 1
tmux list-panes -a -F '#{pane_id} h=#{pane_height} w=#{pane_width} bar=#{@agent_bar}'
```

Every window needs exactly one `bar=1` pane, with `h=0` and a width equal to
`#{window_width}`.

> `tmux display -p` does **not** execute `#()`, so rendering a format by hand
> shows a blank where the bar should be. That is the tool, not a fault. To see
> the real text: `tmux show -gv @agent_bar_text` (option B), or run
> `tmux-agent-tracker status` directly (option A).

---

## 5. Check the keys

```sh
tmux list-keys -T agent | wc -l      # 20
tmux list-keys -T root | grep M-a    # agent mode, no prefix
```

Nothing stock is overridden. `prefix + 1`, `n`, `p`, `w`, `z` and `C` still do
exactly what tmux has always done.

**Direct:**

| Key | Does |
|---|---|
| `M-a` | agent mode, no prefix needed |
| `prefix + a` / `A` | agent mode, for terminals that swallow Meta |
| `prefix + N` / `P` | next / previous agent, and follow it |
| `prefix + W` | back to the selected agent |
| `prefix + Z` | back to it, zoomed |
| `prefix + Q` | next agent **waiting** on you |
| `prefix + F` | next **finished** agent |
| `prefix + Tab` | flip between the last two |

**Agent mode** — the status bar shows `agent` while it is active:

| Key | Does | |
|---|---|---|
| `1`–`9` | jump to that agent | exits |
| `n` / `p` | next / previous | stays |
| `q` / `c` | next waiting / next finished | stays |
| `w` / `z` | go to selected / go and zoom | exits |
| `l` | pick from a menu | exits |
| `r` | rename the selected agent | exits |
| `R` | redraw now | stays |
| `Tab` | last agent | stays |
| `Escape` | leave | |

Keys you press repeatedly to hunt through the roster keep the mode active. Keys
that land you somewhere you are about to type in drop out of it, so your next
keystroke reaches the agent and not a binding.

On macOS, `M-a` needs the terminal to send Option as Meta: Terminal.app →
Settings → Profiles → Keyboard → *Use Option as Meta key*; iTerm2 → Profiles →
Keys → Left Option → *Esc+*. Ghostty, WezTerm and Alacritty do it already. If
yours does not, `prefix + a` is the same thing.

---

## 6. Watch a status change

The real end-to-end test — it exercises every link in the chain at once.

1. Give an agent something slow to do. Its entry turns blue and the glyph
   animates: `⠂ ⠄ ⠆ ⠇`.
2. Wait for it to ask you something. It turns **yellow** with `ᵠ`, within about a
   second.
3. From any other pane, press `prefix + Q`. You land on it.
4. Answer it. It goes blue again, then **green** with `ᶜ` when it finishes.

| State | Glyph | Colour | From |
|---|---|---|---|
| waiting on you | `ᵠ` | yellow | `"status":"waiting"` |
| working | spinner | blue | `"status":"busy"` |
| done, idle | `ᶜ` | green | `"status":"idle"` |
| unrecognised | `·` | grey | anything else |

That last row is deliberate: if either provider adds a state, it still draws,
with a fallback glyph, rather than the agent vanishing. Codex waiting currently
means the documented `PermissionRequest` approval boundary; other UI-specific
questions are not claimed as detectable.

---

## Configuration reference

Every option is `@agent-tracker-*` and must be set **before** the plugin loads.

### Appearance

| Option | Default | |
|---|---|---|
| `icon` | `✳` | the mark on pane badges |
| `symbol-waiting` | `ᵠ` | |
| `symbol-complete` | `ᶜ` | finished, and you have been to look |
| `symbol-unchecked` | `ᶜ` | finished, and you have not |
| `symbol-busy` | *(empty)* | empty means animate the spinner |
| `symbol-unknown` | `·` | a status the plugin does not recognise |
| `spinner` | `⠒,⠢,⠤,⠔` | comma separated frames; these four are centred in the cell |
| `color-waiting` | `#f9e2af` | |
| `color-complete` | `#a6e3a1` | |
| `color-unchecked` | `#fab387` | the orange that says "unread" |
| `color-busy` | `#89b4fa` | |
| `color-unknown` | `#6c7086` | |
| `color-selected` | `#f5c2e7` | |
| `module-style` | *(empty)* | set it to draw each agent as a pill; see [Matching your theme](#matching-your-theme) |
| `separators` | *(empty)* | the caps on either end of a pill, as a comma pair |

Defaults are Catppuccin Mocha, so it drops into a Catppuccin setup with no colour
work. If your font renders the superscripts as boxes, plain letters work fine:

```tmux
set -g @agent-tracker-symbol-waiting 'q'
set -g @agent-tracker-symbol-complete 'c'
```

### Labels

| Option | Default | |
|---|---|---|
| `label` | `dir` | pane border: `dir`, `name` or `both` |
| `label-width` | `20` | |
| `bar-label` | `name` | agent bar: `name`, `dir` or `both` |
| `bar-width` | `18` | a **ceiling**, not a size |
| `bar-separator` | two spaces | between entries |

`bar-width` is a ceiling because tmux runs a status line's `#()` once and shows
the result to every client. The bar measures the narrowest attached client and
shrinks names to fit, so a wide monitor and a narrow laptop can share a session
without the agents on the right falling off the second one. Past the point where
shrinking runs out, the tail is counted (`+3`) rather than dropped silently.

A renamed agent (`M-a r`) keeps its name whatever `bar-label` says. The rename
belongs to that provider session, not to its pane, so a replacement agent does
not inherit it. With the default `bar-label name`, an unrenamed agent uses its
provider-reported chat name and falls back to the working folder when none is
available.

### Behaviour

| Option | Default | |
|---|---|---|
| `max` | `0` | entries on the bar; `0` is all of them |
| `interval` | `1` | seconds between polls; sets `status-interval` |
| `providers` | `claude,codex` | comma-separated adapters; set `claude` to disable Codex polling |
| `claude-sessions-dir` | *(empty)* | provider-specific Claude source; wins over the legacy alias |
| `sessions-dir` | `~/.claude/sessions` | backward-compatible Claude source alias |
| `codex-state-dir` | *(empty)* | secure per-user runtime default; override for diagnostics/tests |
| `alert` | `off` | `display-message` when an agent starts waiting |

`alert` is off on purpose: with a handful of agents running, a message every time
one of them wants something gets old fast.

When `codex-state-dir` is overridden, pass the same absolute directory to
`codex-hook-config /absolute/private/state-dir` before merging it. The generated
command carries the override without calling tmux from the hook path.

### Wiring

| Option | Default | |
|---|---|---|
| `keys` | `on` | all bindings, including the agent table |
| `follow` | `on` | tmux's own pane moves change the selection too |
| `pane-border` | `on` | badges on pane borders; `off` also drops the pane title |
| `bar` | `on` | the dedicated status line |
| `bottom-bar` | `off` | last row of the window instead |
| `status-position` | `off` | `off` keeps yours; or `top` / `bottom` |

`status-position` defaults to `off` because both status lines land at the same
end whatever the plugin does, so overriding it only takes the choice away from
whoever set it.

### Placing the bar yourself

```tmux
set -g @agent-tracker-bar 'off'
set -g status-right "#(~/.tmux/plugins/tmux-agent-tracker/bin/tmux-agent-tracker roster) %H:%M"
set -g status-right-length 200
```

`roster` prints the compact `✳¹ᵠ ✳²ᶜ` badges, which is the form that fits on a
shared line; `status` prints the names. Both run the same single poll, so pick
one — running both does the work twice for no benefit. Raise
`status-right-length` past its 40 column default or the badges get cut off.

---

## Matching your theme

By default the bar is plain coloured text, which needs no particular font and
suits a bare tmux. If your theme draws its status modules as pills, two options
turn the same shape on:

```tmux
set -g @agent-tracker-separators ','        # U+E0B6, U+E0B4
set -g @agent-tracker-module-style 'fg=#cdd6f4,bg=#313244'
```

`separators` are the caps on either end; `module-style` is what the name sits on.
Caps with no `module-style` have nothing to cap, so `module-style` is the switch
that turns the whole thing on. The separator glyphs need a Nerd Font.

Spell the colours out rather than leaning on your theme's variables — a theme
update should not quietly restyle this.

---

## Command reference

```
tmux-agent-tracker <command>
```

| Command | |
|---|---|
| `status` | the agent bar; what the status line runs |
| `roster` | the compact `✳¹ᵠ` badge form |
| `list` | one line per agent, for a shell |
| `doctor` | what it can see, and where it looked |
| `codex-hook-config` | print the reviewed `hooks.json` definition; changes nothing |
| `goto N` | jump to agent N |
| `next` / `prev` | move the selection and follow it |
| `focus` / `zoom` | back to the selected agent, plain or zoomed |
| `waiting` / `complete` | next agent in that state |
| `last` | flip between the last two |
| `menu` | the picker |
| `rename` | prompt to rename the selected agent |
| `refresh` | redraw now |
| `ensure` | put missing bottom-bar placeholders back |
| `teardown` | remove every bottom-bar placeholder |

All of them talk to the tmux server `$TMUX` points at, so run them from inside
tmux.

---

## Troubleshooting

### Nothing ever appears

Work through [4.1](#41-does-the-plugin-see-your-agents) and
[4.2](#42-is-the-poll-actually-running) first — they separate "found no agents"
from "never looked".

If `doctor` finds agents but the bar stays empty, the poll is not being driven.
In order of likelihood:

1. **A theme loaded after this plugin.** The usual cause. Themes assign `status`,
   `status-position` and `status-right` wholesale. Move the `@plugin` line below
   your theme's and reload.
2. **The status line is off.** `tmux show -gv status` — `off` means nothing polls.
3. **No client attached.** A detached session never redraws its status line, so
   `#()` never runs. Expected; it catches up on attach.

### Codex does not appear

Run `doctor`, then check these in order:

1. `codex bridge not detected`: install/merge the printed config, restart Codex,
   and trust the exact definition in `/hooks`.
2. No state records: the Codex CLI must be interactive and running inside tmux;
   detached `codex exec`, cloud, app and IDE sessions are not supported surfaces.
3. `insecure`: remove symlinks and restore the state directory to mode `0700`
   and files to `0600`; insecure records are skipped.
4. `stale`: the recorded PID exited, its ancestry no longer reaches the pane,
   or the pane id was reused. This is rejected deliberately, not an mtime delay.
5. `invalid`: a partial/oversized/future-schema record was skipped. A later hook
   normally replaces it atomically; restart the Codex turn if it persists.

If hooks were merged more than once, `/hooks` may show duplicate tracker
commands. Keep one exact tracker handler per event: matching hooks run
concurrently, so duplicates can make state transitions race.

### The whole top status line went blank

Recoverable, but you cannot get the default back by unsetting.

`status-format` is an **array** option: `set -gu 'status-format[0]'` *removes* the
element rather than restoring the default, and tmux then reports it as empty with
no way to ask what it had been. Appending to that leaves the line holding one
`#()` that draws no characters — a blank bar and no error anywhere.

To recover, read the default off a server started with no config at all:

```sh
tmux -L probe -f /dev/null new-session -d
tmux -L probe show -gv 'status-format[0]' > /tmp/default-format0
tmux -L probe kill-server
tmux set-option -g 'status-format[0]' "$(cat /tmp/default-format0)"
```

A probe server started *without* `-f /dev/null` reads your config back and hands
you the same broken value, which is worth knowing before you debug it twice.

The plugin does not touch `status-format[0]` any more, for exactly this reason.

### Everything updates twice a second

Two pollers:

```sh
tmux show -gv status-right | grep -c 'tracker status'    # want 1
```

Reload your config; the guard is idempotent and settles at one. If it does not,
something appended by hand is still in there.

### bottom-bar: no bar on the last row

```sh
tmux-agent-tracker ensure
```

should fix it immediately and tells you the automatic path is not firing. It runs
from five hooks *and* from the poll, so a persistent failure usually means the
poll is not running — back to [4.2](#42-is-the-poll-actually-running).

Also check `pane-border-status` is still `bottom`; the border is what draws the
bar, so a later `set -g pane-border-status off` takes the bar with it.

### bottom-bar: stray one-row panes after a restart

Handled automatically — but worth knowing what it is doing.

`tmux-resurrect` saves panes and not pane *options*, so a restored placeholder
comes back the right shape with nothing marking it as ours. The poll recognises
one by shape instead: zero content rows and the full window width, which nothing
a person would use ever looks like. The first one in the right place is adopted
as the bar and any others are closed, so you get neither a stray row nor a second
bar built on top of it.

If you do end up with rows nobody owns, `teardown` now takes those too.

### The bar is cut off at the right

Only affects the shared-line setup. `status-right-length` defaults to 40; raise
it to 200.

### Boxes instead of glyphs

Superscripts (`ᵠ` `ᶜ`) and braille spinner frames need reasonable Unicode
coverage; the powerline caps need a Nerd Font. Swap for plain letters — see
[appearance](#appearance).

### TPM reports 126, and the theme stopped loading too

The `.tmux` file lost its executable bit. `chmod +x` it. TPM executes plugin entry
files, and one failing takes down the rest of that run.

### `doctor` shows agents you are not looking at

It follows `$TMUX`. From a plain shell it queries the default server. Run it
inside the tmux you mean.

---

## Living with other plugins

### Themes (Catppuccin, Dracula, Powerline, …)

Load this one **after**. Themes assign `status`, `status-position`,
`status-right` and friends outright, so whichever runs last wins. This is the
single most common integration failure.

### tmux-resurrect / tmux-continuum

No interaction in the default setup.

With `bottom-bar on`, resurrect saves the placeholder panes — it stores the pane
but not the pane option marking it as ours, so after a restore they come back
anonymous. The poll adopts them by shape rather than building duplicates
alongside, so this needs nothing from you. Nothing is written to the resurrect
save that would confuse anything else.

### Anything using the same tmux hooks

Every hook the plugin wires is **appended**, never assigned: `after-select-pane`
always, and with `bottom-bar on` also `after-new-window`,
`window-layout-changed`, `after-kill-pane`, `session-created` and
`client-attached`. Whatever you or another plugin already had on them keeps
running. Each append is guarded, so re-sourcing your config does not stack
copies.

To see what is on one:

```sh
tmux show-hooks -g window-layout-changed
```

### vim-tmux-navigator

None. Its `C-h/j/k/l` are `select-pane`, and tmux's directional navigation skips
zero-height panes, so the placeholder is not reachable — verified, not assumed.

### Anything binding capitals on the prefix

The direct bindings are `A N P W Z Q F Tab` plus `a`, and `M-a` on the root
table. All are unbound in stock tmux 3.5a. `C` is deliberately left alone because
tmux 3.2+ binds it to `customize-mode`, which is why "next finished agent" is
`F`. If you have your own, either rebind yours or set
`@agent-tracker-keys 'off'` and bind what you want to the
[commands](#command-reference).

---

## Uninstalling

```tmux
# remove the @plugin line, then
set -g @agent-tracker-bottom-bar 'off'
```

```sh
tmux-agent-tracker teardown     # only if you used bottom-bar
```

Then restart the tmux server, or reload and reset by hand:

```sh
tmux set -g status on
tmux set -gu 'status-format[1]'
tmux set -g pane-border-status off
```

Options the plugin sets are all `@agent-tracker-*`, `@agent_badge`,
`@agent_label`, `@agent_name`, `@agent_name_session`, `@agent_bar` and
`@agent_bar_text`; they die with the server.
Nothing was written to Claude Code.

If you enabled Codex tracking, use `/hooks` to disable it or remove only the
exact tracker handler entries from `~/.codex/hooks.json`; preserve unrelated
hooks. Once all Codex sessions have exited, the tracker-owned runtime directory
may be removed. Disabling Codex polling alone is non-destructive:

```tmux
set -g @agent-tracker-providers 'claude'
```

---

## Testing a change

```sh
lua tests/run.lua
luajit tests/run.lua      # 5.1 semantics, worth running too
```

Plain asserts, no framework, so they run anywhere Lua does.

To exercise a real install without touching your own tmux, use a throwaway server
and a fake agent — this is how the integration itself is verified:

```sh
ROOM=$(mktemp -d); mkdir -p "$ROOM/sessions"
git clone . "$ROOM/plugin"

cat > "$ROOM/tmux.conf" <<EOF
set -g @agent-tracker-sessions-dir '$ROOM/sessions'
run-shell '$ROOM/plugin/agent-tracker.tmux'
EOF

tmux -L probe -f "$ROOM/tmux.conf" new-session -d -x 100 -y 30 'sleep 10000'
pid=$(tmux -L probe display -p '#{pane_pid}')
cat > "$ROOM/sessions/$pid.json" <<EOF
{"pid":$pid,"cwd":"/tmp/myproject","kind":"interactive","name":"fix-the-login-bug","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":1}
EOF

# a status line only redraws for an attached client, so attach one on a pty
script -q /dev/null tmux -L probe attach >/dev/null 2>&1 &
sleep 4
tmux -L probe run-shell "$ROOM/plugin/bin/tmux-agent-tracker doctor > $ROOM/out"
cat "$ROOM/out"

tmux -L probe kill-server
```

The two things that will waste your time otherwise: a **detached** session never
runs `#()`, and `tmux display -p` never expands it.
