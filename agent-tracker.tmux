#!/usr/bin/env bash
# tmux-agent-tracker — TPM entry point.
#
# Sourced once by tmux at startup. Wires up the status line, the pane borders
# and the key bindings, then gets out of the way; everything after this is Lua.
set -e

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tracker="$root/bin/tmux-agent-tracker"

# Read an @agent-tracker-* option, falling back to a default.
option() {
  local value
  value="$(tmux show-option -gqv "@agent-tracker-$1")"
  [ -n "$value" ] && echo "$value" || echo "$2"
}

enabled() {
  case "$(option "$1" "$2")" in
    on | 1 | true | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# The Lua side needs to know where it lives so the picker menu can call back
# into it.
tmux set-option -gq "@agent-tracker-script" "$tracker"

# --- status line ------------------------------------------------------------

interval="$(option interval 1)"
tmux set-option -g status-interval "$interval"

position="$(option status-position bottom)"
if [ "$position" != "off" ]; then
  tmux set-option -g status-position "$position"
fi

# The agents get a status line of their own rather than being squeezed onto the
# end of the theme's. tmux stacks status lines: line 0 is the theme, line 1 is
# ours, and it sits on the outer edge — the very bottom of the screen when
# status-position is bottom.
#
# Both lines share one position. tmux has a single status-position for the whole
# block ("not an array"), so one line at the top and another at the bottom is not
# something it can do, however many lines you ask for.
if enabled bar on; then
  tmux set-option -g status 2
  # Line 0 is left exactly as the theme built it.
  tmux set-option -gq status-format[1] \
    "#[align=left]#[fg=default,bg=default] #($tracker status)#[align=right]#{?#{==:#{client_key_table},agent},#[reverse] agent #[noreverse] ,}"
fi

# --- pane borders -----------------------------------------------------------

# The badge is written to a per-pane option by the status-line poll, so this
# format string spawns nothing of its own no matter how many panes are open.
if enabled pane-border on; then
  tmux set-option -g pane-border-status bottom
  tmux set-option -g pane-border-format \
    '#{?@agent_badge,#{@agent_badge} #[fg=default]#{@agent_label},#{?pane_active,#[reverse],}#{pane_index}#[default] #{pane_title}}'
fi

# --- keys -------------------------------------------------------------------

if enabled keys on; then
  run="run-shell -b"

  stay="switch-client -T agent"

  # Direct bindings, capitals only. The lowercase and numeric prefix keys are
  # stock tmux — select-window, next-window, choose-tree, zoom — and taking
  # them would cost more than it gains. C is left alone too (customize-mode),
  # so "next finished agent" is F.
  tmux bind-key A $stay                            # enter agent mode
  tmux bind-key N $run "$tracker next"             # next agent, and follow
  tmux bind-key P $run "$tracker prev"             # previous agent, and follow
  tmux bind-key W $run "$tracker focus"            # back to the selected agent
  tmux bind-key Z $run "$tracker zoom"             # back to it, zoomed
  tmux bind-key Q $run "$tracker waiting"          # next one asking a question
  tmux bind-key F $run "$tracker complete"         # next finished one
  tmux bind-key Tab $run "$tracker last"           # flip between two agents

  # Agent mode: a key table where the bare number keys are ours. This is the
  # only way to get `1`..`9` without stealing select-window from the prefix.
  #
  # tmux drops back to the root table after any key that doesn't re-enter, and
  # that is used deliberately here: keys that land you somewhere you intend to
  # type (digits, w, z, l) exit, so your next keystroke reaches the agent. Keys
  # you press repeatedly to hunt through the roster (n, p, q, c) stay.
  for n in 1 2 3 4 5 6 7 8 9; do
    tmux bind-key -T agent "$n" run-shell -b "$tracker goto $n"
  done

  tmux bind-key -T agent w $run "$tracker focus"
  tmux bind-key -T agent z $run "$tracker zoom"
  tmux bind-key -T agent l run-shell "$tracker menu"

  # The separator has to reach tmux as the literal two characters \; — a bare
  # `;` would be eaten by tmux's own parser as the end of the bind-key command,
  # which silently binds half of this and runs the other half right now.
  sep='\;'
  tmux bind-key -T agent n $run "$tracker next" "$sep" $stay
  tmux bind-key -T agent p $run "$tracker prev" "$sep" $stay
  tmux bind-key -T agent q $run "$tracker waiting" "$sep" $stay
  tmux bind-key -T agent c $run "$tracker complete" "$sep" $stay
  tmux bind-key -T agent Tab $run "$tracker last" "$sep" $stay
  tmux bind-key -T agent r $run "$tracker refresh" "$sep" $stay

  tmux bind-key -T agent Escape display-message "agent mode off"
fi

# Paint once now rather than waiting out the first status interval.
tmux run-shell -b "$tracker status >/dev/null"
