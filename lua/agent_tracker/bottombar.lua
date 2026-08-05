-- The agent bar as a pane on the last row of the window.
--
-- tmux keeps every status line at one end of the screen, so a bar at the bottom
-- while the theme is at the top cannot be a status line at all. What can live
-- down there is a pane, and a pane one row high has, with pane-border-status
-- bottom, exactly zero rows of content and one row of border — which is drawn
-- across the full width on the window's last row. So the border is the bar, and
-- the pane behind it is an inert placeholder that never draws anything.
--
-- That costs one row, the same as a status line would, and needs no process per
-- window to paint it: the text comes from a global option the poll updates, and
-- tmux redraws the border itself.

local tmux = require("agent_tracker.tmux")

local M = {}

M.MARK = "@agent_bar"

-- Something that sits there forever without waking up. The pane exists only to
-- own a border; if this exits, the pane closes and the bar goes with it.
M.HOLDER = "while :; do sleep 86400; done"

local function trim(str)
  return (tostring(str):gsub("%s+$", ""))
end

-- One listing of every pane, with the geometry needed to tell a good bar pane
-- from one a layout change has thrown across the window.
M.FORMAT = "#{window_id} #{pane_id} #{pane_top} #{pane_width} #{pane_height} "
  .. "#{window_width} #{window_zoomed_flag} #{@agent_bar}"

function M.parse(out)
  local windows = {}
  for line in out:gmatch("[^\n]+") do
    local window, pane, top, width, height, window_width, zoomed, mark =
      line:match("^(@%d+) (%%%d+) (%-?%d+) (%d+) (%d+) (%d+) (%d) ?(.*)$")
    if window then
      local w = windows[window]
      if not w then
        w = { id = window, width = tonumber(window_width), zoomed = zoomed == "1", bars = {}, lowest = -1 }
        windows[window] = w
      end
      if trim(mark) == "1" then
        w.bars[#w.bars + 1] =
          { id = pane, top = tonumber(top), width = tonumber(width), height = tonumber(height) }
      else
        w.others = (w.others or 0) + 1
        if tonumber(top) > w.lowest then w.lowest = tonumber(top) end
      end
    end
  end
  return windows
end

function M.survey()
  return M.parse(tmux.query("list-panes -a -F " .. tmux.quote(M.FORMAT)))
end

-- Spanning the window, below everything else, and with no content rows of its
-- own. That last part is the whole trick: with pane-border-status bottom a
-- one-row pane is all border, so the bar costs a single row and nothing is
-- wasted underneath it.
function M.healthy(bar, window)
  return bar.width == window.width and bar.top > window.lowest and bar.height == 0
end

function M.create(window_id)
  local pane = trim(tmux.query(
    "split-window -t " .. tmux.quote(window_id) .. " -d -f -v -l 1 -P -F '#{pane_id}' "
      .. tmux.quote(M.HOLDER)
  ))
  if pane:match("^%%%d+$") then
    tmux.tmux("set-option -pq -t " .. pane .. " " .. M.MARK .. " 1")
    return pane
  end
  return nil
end

-- Splitting and killing panes both fire window-layout-changed, which is the
-- hook that calls this, so a run always provokes more runs. Being idempotent is
-- not enough on its own: several of them in flight at once would each look, all
-- see no bar, and all make one. mkdir is the atomic test-and-set every unix
-- has, so only one of them proceeds and the rest return immediately.
local function lock_path()
  local tmp = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  return tmp .. "/tmux-agent-tracker-ensure.lock"
end

local function succeeded(ok, _, code)
  return ok == true or ok == 0 or code == 0
end

local function acquire()
  local path = lock_path()
  -- A run that was killed leaves the directory behind and would wedge this for
  -- good, so anything older than a minute is treated as abandoned.
  os.execute("find " .. tmux.quote(path) .. " -maxdepth 0 -mmin +1 -prune -exec rmdir {} + 2>/dev/null")
  return succeeded(os.execute("mkdir " .. tmux.quote(path) .. " 2>/dev/null"))
end

local function release()
  os.execute("rmdir " .. tmux.quote(lock_path()) .. " 2>/dev/null")
end

function M.ensure()
  if not acquire() then return 0 end

  local ok, changed = pcall(M.reconcile)
  release()

  if not ok then error(changed, 0) end
  return changed
end

-- Only ever touches a window that is actually wrong, so the extra runs our own
-- splitting sets off find nothing to do and the whole thing settles.
function M.reconcile()
  local changed = 0

  for _, window in pairs(M.survey()) do
    -- A window showing nothing but the bar would close when we replaced it, and
    -- splitting a zoomed window would silently unzoom it.
    if (window.others or 0) > 0 and not window.zoomed then
      local keep
      for _, bar in ipairs(window.bars) do
        if not keep and M.healthy(bar, window) then
          keep = bar
        else
          -- Anything else gets replaced rather than adjusted. resize-pane -y 1
          -- leaves one row of *content* plus a border, where split-window -l 1
          -- gives the zero-content pane we want, so a resize could never reach
          -- a healthy state and every hook would try again forever.
          tmux.tmux("kill-pane -t " .. bar.id)
          changed = changed + 1
        end
      end

      if not keep then
        if M.create(window.id) then changed = changed + 1 end
      end
    end
  end

  return changed
end

-- Take the bar panes away again, for turning the option off without restarting.
function M.teardown()
  for _, window in pairs(M.survey()) do
    for _, bar in ipairs(window.bars) do
      tmux.tmux("kill-pane -t " .. bar.id)
    end
  end
end

return M
