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

# Only if asked. Both status lines land wherever this points, so leaving it
# alone means whatever the user already chose keeps working.
position="$(option status-position off)"
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
#
# Unless bottom-bar is on, in which case the bar lives on the last row of the
# window instead and the status line only has to keep the poll ticking.
if enabled bottom-bar off; then
  # An invisible #() on the theme's own line: the poll has to be driven by
  # something tmux refreshes, and this is the only thing left once the bar has
  # moved off the status line. It prints nothing.
  #
  # Unset before appending, or every reload of tmux.conf leaves another copy
  # behind and the poll runs once more per second than it did before.
  tmux set-option -gu 'status-format[0]'
  tmux set-option -gqa 'status-format[0]' "#($tracker status)"
  tmux set-option -g status on
elif enabled bar on; then
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

  # A bar pane's border is the agent bar; everything else gets its badge. The
  # bar text comes from a global option, which resolves in a pane-scoped format
  # just as a per-pane one does, so all the windows share a single value.
  normal='#{?@agent_badge,#{@agent_badge} #[fg=default]#{@agent_label},#{?pane_active,#[reverse],}#{pane_index}#[default] #{pane_title}}'
  if enabled bottom-bar off; then
    tmux set-option -g pane-border-format "#{?@agent_bar,#{@agent_bar_text},$normal}"
  else
    tmux set-option -g pane-border-format "$normal"
  fi
fi

# --- the bottom bar's placeholder panes --------------------------------------

if enabled bottom-bar off; then
  # A layout change re-places the bar pane rather than resizing it, and a new
  # window has none at all, so both have to put it back. ensure only acts on a
  # window that is actually wrong, which is what stops these hooks — which its
  # own splitting and killing fire — from chasing their own tail.
  tmux set-hook -g after-new-window "run-shell -b '$tracker ensure'"
  tmux set-hook -g window-layout-changed "run-shell -b '$tracker ensure'"
  tmux set-hook -g after-kill-pane "run-shell -b '$tracker ensure'"
  tmux run-shell -b "$tracker ensure"
fi

# --- keys -------------------------------------------------------------------

if enabled keys on; then
  run="run-shell -b"

  stay="switch-client -T agent"

  # Direct bindings, capitals only. The lowercase and numeric prefix keys are
  # stock tmux — select-window, next-window, choose-tree, zoom — and taking
  # them would cost more than it gains. C is left alone too (customize-mode),
  # so "next finished agent" is F.
  tmux bind-key -n M-a $stay                       # enter agent mode, no prefix
  tmux bind-key A $stay                            # ...or via the prefix
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
