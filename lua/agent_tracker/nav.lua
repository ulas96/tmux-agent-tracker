-- Selection and movement.
--
-- The selected agent is kept in a global tmux option rather than a state file:
-- tmux already outlives every client, cleans up when the server dies, and lets
-- the status line read the value for free.

local config = require("agent_tracker.config")
local render = require("agent_tracker.render")
local tmux = require("agent_tracker.tmux")

local M = {}

local SELECTED = "@agent-tracker-selected"
local PREVIOUS = "@agent-tracker-previous"

-- When the caller has already read the global options for other reasons it can
-- hand the selection over rather than making us fork to ask again.
local override

function M.use(pane, previous)
  override = { selected = pane, previous = previous }
end

function M.selected_pane()
  local pane = override and override.selected or tmux.get_global(SELECTED)
  if not pane or pane == "" then return nil end
  return pane
end

function M.select(agent)
  if not agent then return end
  local current = M.selected_pane()
  if current and current ~= agent.pane then
    tmux.set_global(PREVIOUS, current)
    if override then override.previous = current end
  end
  tmux.set_global(SELECTED, agent.pane)
  if override then override.selected = agent.pane end
end

-- Falls back to the first agent so that every binding does something sensible
-- on a fresh tmux server, and recovers when the selected pane has gone away.
function M.current(agents)
  if #agents == 0 then return nil end
  local pane = M.selected_pane()
  for _, agent in ipairs(agents) do
    if agent.pane == pane then return agent end
  end
  return agents[1]
end

function M.by_index(agents, index)
  return agents[index]
end

function M.step(agents, delta)
  if #agents == 0 then return nil end
  local current = M.current(agents)
  local position = ((current.index - 1 + delta) % #agents) + 1
  return agents[position]
end

-- Walks forward from wherever we are to the next agent in a given state, so
-- pressing it repeatedly cycles through everything that is waiting.
function M.next_with_status(agents, wanted)
  if #agents == 0 then return nil end
  local start = M.current(agents).index
  for offset = 1, #agents do
    local candidate = agents[((start - 1 + offset) % #agents) + 1]
    if render.status_key(candidate) == wanted then return candidate end
  end
  return nil
end

function M.previous_agent(agents)
  local pane = override and override.previous or tmux.get_global(PREVIOUS)
  for _, agent in ipairs(agents) do
    if agent.pane == pane then return agent end
  end
  return nil
end

-- select-window and select-pane take a pane id and work out the window and
-- session themselves; switch-client is only needed when the agent lives in a
-- different tmux session, and is harmless when it doesn't.
function M.jump(agent)
  if not agent then return false end
  tmux.batch({
    "switch-client -t " .. tmux.quote(agent.session),
    "select-window -t " .. tmux.quote(agent.pane),
    "select-pane -t " .. tmux.quote(agent.pane),
  })
  return true
end

function M.zoom(agent)
  if not M.jump(agent) then return false end
  -- resize-pane -Z toggles, so check first: pressing the zoom binding twice
  -- should leave you zoomed, not flip back out.
  if tmux.display(agent.pane, "#{window_zoomed_flag}") ~= "1" then
    tmux.tmux("resize-pane -Z -t " .. tmux.quote(agent.pane))
  end
  return true
end

function M.script()
  local configured = config.get("script")
  if configured and configured ~= "" then return configured end
  -- Running straight out of a clone, before the tmux entry point has been
  -- sourced: work the path out from how we were started.
  local root = arg and arg[0] and arg[0]:match("^(.*)/lua/main%.lua$")
  return root and (root .. "/bin/tmux-agent-tracker") or "tmux-agent-tracker"
end

-- Where the rename prompt stages what was typed.
M.RENAME_INPUT = "@agent-tracker-rename-input"

-- The template the rename prompt runs when you press enter.
--
-- The typed name is staged in a tmux option rather than interpolated into the
-- run-shell argument. tmux substitutes %% before parsing, so a name that lands
-- inside a shell command reaches `sh`: `$(...)` in a rename would have run.
-- Staged this way it never leaves tmux, and the worst a stray quote does is
-- drop the rename.
--
-- The template says %% and nothing else with a % in it: tmux substitutes %1..%9
-- there too, which would chew a pane id like %19 in half.
function M.rename_template(script)
  return "set-option -gq " .. M.RENAME_INPUT .. " \"%%\" ; run-shell "
    .. tmux.quote(script .. " rename-to")
end

-- display-menu grew -s/-S/-H, and the menu-style options they override, in tmux
-- 3.4. Below that they are not "ignored" — the whole command fails on the
-- unknown flag and the picker never opens, which is worse than a stock-coloured
-- one. An unreadable version is treated as new enough: a menu in the wrong
-- colours beats no menu on a build we cannot identify.
function M.styles_supported(version)
  local major, minor = tostring(version or ""):match("(%d+)%.(%d+)")
  if not major then return true end
  major, minor = tonumber(major), tonumber(minor)
  return major > 3 or (major == 3 and minor >= 4)
end

-- tmux has no menu-style option to inherit from — the picker is stock colours
-- unless display-menu is told otherwise — so the theming has to travel on the
-- command. Each flag is passed only when there is a value behind it, leaving
-- tmux's own defaults in place for anyone who has set nothing.
function M.menu_styles(opts, version)
  local flags = {}
  local colors = opts.colors or {}

  if not M.styles_supported(version) then return flags end

  if (opts.module_style or "") ~= "" then
    flags[#flags + 1] = "-s " .. tmux.quote(opts.module_style)
  end
  if (colors.selected or "") ~= "" then
    flags[#flags + 1] = "-H " .. tmux.quote(
      "fg=" .. (opts.ink or "default") .. ",bg=" .. colors.selected .. ",bold"
    )
  end
  if (colors.busy or "") ~= "" then
    flags[#flags + 1] = "-S " .. tmux.quote("fg=" .. colors.busy)
  end

  return flags
end

function M.menu(agents, opts, version)
  if #agents == 0 then
    tmux.tmux("display-message " .. tmux.quote("no tracked agents running"))
    return
  end

  local parts = { "display-menu -T " .. tmux.quote(" agents ") .. " -x C -y C" }
  for _, flag in ipairs(M.menu_styles(opts, version)) do
    parts[#parts + 1] = flag
  end
  for _, agent in ipairs(agents) do
    local key = agent.index <= 9 and tostring(agent.index) or ""
    parts[#parts + 1] = table.concat({
      tmux.quote(render.describe(agent, opts)),
      tmux.quote(key),
      tmux.quote("run-shell " .. tmux.quote(M.script() .. " goto " .. agent.index)),
    }, " ")
  end

  tmux.tmux(table.concat(parts, " "))
end

return M
