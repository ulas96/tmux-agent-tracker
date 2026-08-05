-- Command dispatch. Everything tmux calls comes through here.

local agents = require("agent_tracker.agents")
local config = require("agent_tracker.config")
local nav = require("agent_tracker.nav")
local render = require("agent_tracker.render")
local tmux = require("agent_tracker.tmux")

local M = {}

local BADGE = "@agent_badge"
local LABEL = "@agent_label"
local TRACKED = "@agent-tracker-panes"
local SEEN = "@agent-tracker-seen"

-- One gather, then everything else is parsing. config.seed means the option
-- lookups that follow cost nothing.
-- One gather, then everything else is parsing: the option dump rides along in
-- the same read, so config lookups after this cost nothing.
local function load()
  local raw = agents.gather()
  config.seed(agents.options_text(raw))
  -- The selection lives in a global option too, so it arrived with the rest.
  nav.use(config.raw("selected"), config.raw("previous"))
  return agents.parse(raw, agents.full_ancestry), render.options()
end

local function refresh_status()
  tmux.tmux("refresh-client -S")
end

-- Writes one user option per agent pane and clears the ones that stopped being
-- agents, all in a single tmux invocation. The pane border format then only has
-- to read #{@agent_badge}, which costs nothing to redraw.
local function paint_panes(list, opts, frame)
  local commands = {}
  local live = {}

  for _, agent in ipairs(list) do
    live[agent.pane] = true
    commands[#commands + 1] =
      tmux.set_pane_option(agent.pane, BADGE, render.pane_badge(agent, opts, frame))
    commands[#commands + 1] =
      tmux.set_pane_option(agent.pane, LABEL, render.label(agent, opts))
  end

  for pane in (config.raw("panes") or ""):gmatch("%%%d+") do
    if not live[pane] then
      commands[#commands + 1] = tmux.unset_pane_option(pane, BADGE)
      commands[#commands + 1] = tmux.unset_pane_option(pane, LABEL)
    end
  end

  -- Remember what we painted so the next tick knows what to clear, in the same
  -- invocation as the painting itself.
  local panes = {}
  for _, agent in ipairs(list) do
    panes[#panes + 1] = agent.pane
  end
  commands[#commands + 1] = tmux.set_global_option(TRACKED, table.concat(panes, " "))

  tmux.batch(commands)
end

-- Optional nudge when an agent starts waiting on you. Off by default: with nine
-- agents running, a message every time one of them wants something gets old.
local function announce(list, opts)
  if not config.enabled("alert") then return end

  local before = {}
  for pane, status in (config.raw("seen") or ""):gmatch("(%%%d+)=(%a+)") do
    before[pane] = status
  end

  local now = {}
  for _, agent in ipairs(list) do
    local key = render.status_key(agent)
    now[#now + 1] = agent.pane .. "=" .. key
    if key == "waiting" and before[agent.pane] ~= "waiting" then
      tmux.tmux("display-message " .. tmux.quote(render.describe(agent, opts)))
    end
  end

  tmux.set_global(SEEN, table.concat(now, " "))
end

local commands = {}

function commands.status()
  local list, opts = load()
  local frame = render.frame()

  paint_panes(list, opts, frame)
  announce(list, opts)

  io.write(render.roster(list, opts, frame, nav.selected_pane()))
end

function commands.list()
  local list, opts = load()
  for _, agent in ipairs(list) do
    print(render.describe(agent, opts))
  end
  if #list == 0 then print("no claude agents running") end
end

local function go(agent)
  if not agent then
    tmux.tmux("display-message " .. tmux.quote("no matching claude agent"))
    return
  end
  nav.select(agent)
  nav.jump(agent)
  refresh_status()
end

function commands.goto_(index)
  local list = load()
  go(nav.by_index(list, tonumber(index) or 0))
end

function commands.next()
  local list = load()
  go(nav.step(list, 1))
end

function commands.prev()
  local list = load()
  go(nav.step(list, -1))
end

-- Go to whatever is currently selected without moving the selection. Useful
-- after you have wandered off into a different window.
function commands.focus()
  local list = load()
  go(nav.current(list))
end

function commands.zoom()
  local list = load()
  local agent = nav.current(list)
  if not agent then
    tmux.tmux("display-message " .. tmux.quote("no matching claude agent"))
    return
  end
  nav.select(agent)
  nav.zoom(agent)
  refresh_status()
end

function commands.waiting()
  local list = load()
  go(nav.next_with_status(list, "waiting"))
end

function commands.complete()
  local list = load()
  go(nav.next_with_status(list, "complete"))
end

function commands.last()
  local list = load()
  go(nav.previous_agent(list) or nav.step(list, 1))
end

function commands.menu()
  local list, opts = load()
  nav.menu(list, opts)
end

function commands.refresh()
  refresh_status()
end

-- Prints what the plugin can see. First stop when the status bar is empty.
function commands.doctor()
  local dir = config.sessions_dir()
  print("lua           " .. _VERSION)
  print("tmux          " .. (tmux.query("-V"):gsub("%s+$", "")))
  print("sessions dir  " .. dir)

  local raw = agents.gather(dir)
  local sessions = select(2, raw:gsub("\n%s*{", "\n{"))
  print("session files " .. tostring(sessions))

  local list, opts = load()
  print("agents found  " .. #list)
  for _, agent in ipairs(list) do
    print("  " .. render.describe(agent, opts))
  end

  if #list == 0 then
    print("")
    print("nothing found. is claude code running inside a tmux pane?")
    print("check that " .. dir .. " has a .json file per running session.")
  end
end

function M.run(argv)
  local name = argv[1] or "status"
  -- `goto` is a Lua keyword in 5.2+, so the function is spelled goto_ and the
  -- command line still says goto.
  local handler = commands[name] or commands[name .. "_"]
  if not handler then
    io.stderr:write("tmux-agent-tracker: unknown command '" .. name .. "'\n")
    io.stderr:write("commands: status list goto next prev focus zoom waiting complete last menu refresh doctor\n")
    return 1
  end
  handler(argv[2])
  return 0
end

return M
