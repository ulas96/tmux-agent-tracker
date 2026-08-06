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
  # The poll still has to be driven by something tmux refreshes on a timer, and
  # with the bar down on a pane border the status line is all that is left. This
  # prints nothing, so it costs the theme no room.
  #
  # It hangs off status-right and not status-format, because status-format is an
  # array: unsetting an element removes it rather than restoring the default, and
  # tmux will not tell you what that default was — which leaves the whole top bar
  # blank with no way to put it back.
  tmux set-option -g status on
  tmux set-option -gu 'status-format[1]'
  # Matched on the plugin's name and not on "$tracker", because $tracker is not
  # stable: TPM loads through a symlink, so the same install resolves to the
  # link one time and its target the next (and on a case-insensitive filesystem
  # can differ only in case). Comparing paths appends a second copy and the poll
  # then runs twice a second for as long as tmux is up.
  case "$(tmux show-option -gv status-right)" in
    *"bin/tmux-agent-tracker status"*) ;;   # already appended on an earlier load
    *) tmux set-option -ga status-right "#($tracker status)" ;;
  esac
elif enabled bar on; then
  tmux set-option -g status 2
  # Line 0 is left exactly as the theme built it.
  # No fg/bg of its own: left alone the line inherits status-style, so it shares
  # the theme's band instead of cutting a strip of terminal background across it.
  tmux set-option -gq status-format[1] \
    "#[align=left] #($tracker status)#[align=right]#{?#{==:#{client_key_table},agent},#[reverse] agent #[noreverse] ,}"
fi

# --- pane borders -----------------------------------------------------------

# The badge is written to a per-pane option by the status-line poll, so this
# format string spawns nothing of its own no matter how many panes are open.
# In bottom-bar mode the border is also the bar, so the block still has to run
# with the badges off — otherwise the format is left at tmux's default and the
# bar pane shows a pane title instead of the bar.
if enabled pane-border on || enabled bottom-bar off; then
  tmux set-option -g pane-border-status bottom

  if enabled pane-border on; then
    # `default` on a pane border means pane-border-style, not the terminal's own
    # foreground. A theme that dims its borders — or paints them the background
    # to stop the badges sitting on a ruled grid — would take the label down with
    # them, so the label names a colour: the one the pills put their text on when
    # there is one, and the terminal's otherwise.
    label_fg="$(option module-style default)"
    case "$label_fg" in
      *fg=*)
        label_fg="${label_fg#*fg=}"
        label_fg="${label_fg%%,*}"
        ;;
      *) label_fg="default" ;;
    esac

    # A bar pane's border is the agent bar; everything else gets its badge. The
    # bar text comes from a global option, which resolves in a pane-scoped format
    # just as a per-pane one does, so all the windows share a single value.
    normal='#{?@agent_badge,#{@agent_badge} #[fg='"$label_fg"']#{@agent_label},'
    normal="$normal"'#{?pane_active,#[reverse],}#{pane_index}#[noreverse,fg='"$label_fg"'] #{pane_title}}'
  else
    normal=''
  fi

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
  # after-new-window is not fired for the first window of a session, so a server
  # that had only ever been started would never get a bar from these alone.
  # session-created and client-attached cover that; the poll covers everything
  # else, and all of them are cheap when there is nothing to do.
  #
  # Appended rather than set, for the same reason as after-select-pane below:
  # these are popular hooks and replacing them silently breaks whatever else is
  # on them. Appending needs the same guard, or every re-source stacks a copy.
  for hook in after-new-window window-layout-changed after-kill-pane \
              session-created client-attached; do
    case "$(tmux show-hooks -g "$hook")" in
      *"tmux-agent-tracker ensure"*) ;;
      *) tmux set-hook -ga "$hook" "run-shell -b '$tracker ensure'" ;;
    esac
  done
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
  # M-a is a prefix of its own: it opens the agent table, where a single key is
  # the whole command (M-a n, M-a 1). prefix + a does the same, for terminals
  # that swallow Meta.
  tmux bind-key -n M-a $stay
  tmux bind-key a $stay
  tmux bind-key A $stay
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
  # Not backgrounded: both of these open a prompt or a menu, which needs the
  # client run-shell is attached to.
  tmux bind-key -T agent r run-shell "$tracker rename"

  # The separator has to reach tmux as the literal two characters \; — a bare
  # `;` would be eaten by tmux's own parser as the end of the bind-key command,
  # which silently binds half of this and runs the other half right now.
  sep='\;'
  tmux bind-key -T agent n $run "$tracker next" "$sep" $stay
  tmux bind-key -T agent p $run "$tracker prev" "$sep" $stay
  tmux bind-key -T agent q $run "$tracker waiting" "$sep" $stay
  tmux bind-key -T agent c $run "$tracker complete" "$sep" $stay
  tmux bind-key -T agent Tab $run "$tracker last" "$sep" $stay
  tmux bind-key -T agent R $run "$tracker refresh" "$sep" $stay

  tmux bind-key -T agent Escape display-message "agent mode off"
fi

# --- following tmux's own pane movement --------------------------------------

# Landing on an agent's pane by any of tmux's own means — a select-pane binding,
# vim-tmux-navigator, a mouse click — moves the tracker's selection there too, so
# the bar and prefix+Tab agree with where you actually are.
#
# The condition reads @agent_badge, the per-pane option the poll already writes,
# so the fork only happens on the pane switches that land on an agent — never on
# ordinary ones.
#
# Appended rather than set: after-select-pane is a popular hook and replacing it
# would silently break whatever else is on it. Appending needs the same guard
# status-right has, or every re-source stacks another copy.
if enabled follow on; then
  case "$(tmux show-hooks -g after-select-pane)" in
    *"tmux-agent-tracker select"*) ;;
    *) tmux set-hook -ga after-select-pane \
         "if -F '#{@agent_badge}' 'run-shell -b \"$tracker select #{pane_id}\"'" ;;
  esac
fi

# Paint once now rather than waiting out the first status interval.
tmux run-shell -b "$tracker status >/dev/null"
