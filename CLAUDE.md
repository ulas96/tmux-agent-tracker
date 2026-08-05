# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
lua tests/run.lua                 # the whole suite; asserts, no framework, no single-test flag
bin/tmux-agent-tracker doctor     # what the plugin can see: lua, tmux, sessions dir, agents
bin/tmux-agent-tracker status     # what the status line prints, on stdout
bin/tmux-agent-tracker list       # human-readable roster
tmux source-file ~/.tmux.conf     # re-run agent-tracker.tmux after editing it
```

Tests must pass under Lua 5.1 through 5.5 and LuaJIT. That rules out `goto` as an
identifier (hence `commands.goto_` in `init.lua`), the `utf8` library (json.lua
encodes codepoints by hand), and integer division.

## Architecture

A tmux status line runs `bin/tmux-agent-tracker status` once per second for the
whole server. **Every design decision here is downstream of that.**

`agent-tracker.tmux` (bash, TPM entry point) runs once at startup: sets
`status-format`, `pane-border-format`, the key bindings and the hooks. It never
computes anything — it only points tmux at the Lua.

`lua/agent_tracker/init.lua` is the command dispatch. `poll()` is the hot path:

1. `agents.gather()` — **one** `sh -c` that emits `#panes`/`#options`/`#clients`/
   `#procs`/`#sessions` sections. Pane list, option dump, client widths and the
   process table all ride in that single fork, so nothing downstream may shell out
   to re-read them. `config.seed()` and `nav.use()` exist purely to fill caches
   from this one read.
2. `agents.parse()` — decode the session JSON, walk each pid up the process tree
   to a pane pid, dedupe per pane (newest wins), sort by session/window/pane so
   "agent 3" stays agent 3. `full_ancestry()` is a second `ps` that only fires
   when a live pid failed to resolve (wrapper scripts).
3. `check_off()` — a finished agent renders as `unchecked` (orange) until a
   client is sitting in its pane. The set of checked-off panes is rebuilt from
   the agents that are *still* complete, so going busy again clears the tick and
   nothing needs expiring. Only the drawing path flags it, so `next_with_status`
   and the CLI still see plain `complete`.
4. `paint_panes()` — writes `@agent_badge`/`@agent_label` per pane in a single
   batched `tmux` invocation. The border format just reads the option, so redraws
   cost nothing regardless of pane count.

Layering: `tmux.lua` is the only module that shells out. `render.lua` and
`nav.lua`'s arithmetic are pure and take options as arguments — that is what lets
`tests/run.lua` render a roster and step through it with no tmux server.

State (selection, previous, painted panes, last-seen statuses) lives in global
tmux options, not files: tmux outlives clients, cleans up on server death, and the
status line can read the values for free.

### Where the agent data comes from

`~/.claude/sessions/<pid>.json`, written by Claude Code itself — no hooks, nothing
installed into Claude Code. A dead agent's file lingers but its pid no longer
resolves to a pane, so stale entries drop out with no expiry logic.

### The two bar modes

Default: the agent bar is status line 1 (`set -g status 2`), which tmux puts at
whichever end `status-position` names. Both lines share one position — tmux has no
per-line setting.

`@agent-tracker-bottom-bar on`: the bar is instead the *border* of a one-row
placeholder pane on the window's last row (`bottombar.lua`), so it can sit at the
bottom while the theme is at the top. `M.healthy` encodes what a correct bar pane
looks like (full width, lowest, **zero** content rows — `resize-pane` cannot reach
height 0, so a wrong one is killed and recreated, never adjusted). `ensure` is
called from layout hooks that its own splitting fires, so it is guarded by a
`mkdir` lock and only touches windows that are actually wrong.

## Conventions

- Task names are user text that reaches `sh`, tmux menus and option values. Route
  every interpolation through `tmux.quote()`.
- Comments explain *why* a thing is shaped the way it is (fork counts, tmux
  quirks, ordering guarantees), not what the line does. Match that.
- `ponytail:` comments mark deliberate shortcuts with their ceiling.
- New behaviour needs an assert in `tests/run.lua` against the pure function, plus
  a fixture line if it changes parsing.
