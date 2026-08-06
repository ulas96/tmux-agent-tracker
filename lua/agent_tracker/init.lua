-- Command dispatch. Everything tmux calls comes through here.

local agents = require("agent_tracker.agents")
local bottombar = require("agent_tracker.bottombar")
local codex_hook = require("agent_tracker.codex_hook")
local config = require("agent_tracker.config")
local nav = require("agent_tracker.nav")
local render = require("agent_tracker.render")
local tmux = require("agent_tracker.tmux")

local M = {}

local BADGE = "@agent_badge"
local LABEL = "@agent_label"
local NAME = "@agent_name"
local NAME_SESSION = "@agent_name_session"
local BAR_TEXT = "@agent_bar_text"
local TRACKED = "@agent-tracker-panes"
local SEEN = "@agent-tracker-seen"
local CHECKED = "@agent-tracker-checked"

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

-- A finished agent stays loud until you have actually been to its pane: sitting
-- in it is what checks it off. Flags the rest as `unchecked` for the renderer
-- and returns the new value of the option, which the caller writes.
--
-- The list is rebuilt from the agents that are still complete, so an agent that
-- goes busy again drops its tick and the next thing it finishes is loud too —
-- no expiry, and nothing to clean up when a pane dies.
function M.check_off(list, active, previous)
  local checked = {}
  for pane in (previous or ""):gmatch("%%%d+") do checked[pane] = true end

  local still = {}
  for _, agent in ipairs(list) do
    if render.status_key(agent) == "complete" then
      if active[agent.pane] or checked[agent.pane] then
        still[#still + 1] = agent.pane
      else
        agent.unchecked = true
      end
    end
  end
  return table.concat(still, " ")
end

-- `extra` is whatever else this tick needs written; it rides in the same
-- invocation rather than costing a fork of its own.
local function paint_panes(list, opts, frame, extra)
  local commands = { extra }
  local live = {}

  for _, agent in ipairs(list) do
    live[agent.pane] = true
    commands[#commands + 1] =
      tmux.set_pane_option(agent.pane, BADGE, render.pane_badge(agent, opts, frame))
    commands[#commands + 1] =
      tmux.set_pane_option(agent.pane, LABEL, render.label(agent, opts))
    if agent.stale_custom then
      commands[#commands + 1] = tmux.unset_pane_option(agent.pane, NAME)
      commands[#commands + 1] = tmux.unset_pane_option(agent.pane, NAME_SESSION)
    end
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

-- The poll that drives everything: repaint the pane badges, then print whatever
-- the caller wants on the bar. Whichever of these tmux is running, it runs once
-- per status-interval for the whole server.
local function poll(draw)
  local raw = agents.gather()
  config.seed(agents.options_text(raw))
  nav.use(config.raw("selected"), config.raw("previous"))

  local list = agents.parse(raw, agents.full_ancestry)
  local opts = render.options()
  local frame = render.frame()

  local checked = M.check_off(list, agents.active_panes(raw), config.raw("checked"))
  paint_panes(list, opts, frame, tmux.set_global_option(CHECKED, checked))
  announce(list, opts)

  local text = draw(list, opts, frame, nav.selected_pane(), agents.client_width(raw))

  -- With the bar down on a pane border, tmux reads it out of an option and
  -- redraws it itself; the status line is only here to keep the poll ticking,
  -- so it prints nothing.
  if config.enabled("bottom-bar") then
    tmux.set_global(BAR_TEXT, text)
    -- The placeholders are put back from here as well as from the hooks. A
    -- session's first window fires no after-new-window, so a server that had
    -- only ever been started, never added to, would sit there without a bar at
    -- all. Checking costs one listing and finds nothing to do almost every time.
    bottombar.ensure()
    return
  end

  io.write(text)
end

-- The dedicated agent bar: task names with their status, no icons, no indices.
function commands.status()
  poll(render.bar)
end

-- The compact badge form, for placing inside an existing status line by hand.
function commands.roster()
  poll(render.roster)
end

function commands.list()
  local list, opts = load()
  for _, agent in ipairs(list) do
    print(render.describe(agent, opts))
  end
  if #list == 0 then print("no tracked agents running") end
end

local function go(agent)
  if not agent then
    tmux.tmux("display-message " .. tmux.quote("no matching agent"))
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
    tmux.tmux("display-message " .. tmux.quote("no matching agent"))
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
  -- `tmux -V` rather than the #{version} format: this exists to decide what an
  -- old tmux will accept, so it has to be something every old tmux answers. One
  -- extra fork on a keypress, against once a second on the poll — which is why
  -- this is asked here and not carried along in agents.gather().
  nav.menu(list, opts, tmux.query("-V"))
end

function commands.refresh()
  refresh_status()
end

-- Moving panes with tmux's own keys should move the selection too. The hook
-- fires only for panes carrying @agent_badge, so the pane is known to be an
-- agent and there is nothing to gather: two option writes and a redraw.
-- nav.select only wants a pane id off the agent it is given.
function commands.select(pane)
  if not pane or pane == "" then return end
  nav.select({ pane = pane })
  refresh_status()
end

-- Renaming happens in two hops because the name has to come from a tmux prompt:
-- `rename` opens it, the prompt's template stages what was typed and calls
-- `rename-to`. Neither hop carries the pane id — the target is whatever is
-- selected, and the selection cannot move while the prompt has the keyboard.
function commands.rename()
  local list, opts = load()
  local agent = nav.current(list)
  if not agent then
    tmux.tmux("display-message " .. tmux.quote("no tracked agents running"))
    return
  end

  tmux.tmux(table.concat({
    "command-prompt",
    "-I " .. tmux.quote(render.bar_name(agent, opts)),
    "-p " .. tmux.quote("rename agent " .. agent.index .. ":"),
    tmux.quote(nav.rename_template(nav.script())),
  }, " "))
end

-- Empty input clears the override and hands the agent back its reported chat
-- name or directory fallback, so there is no separate "unrename".
--
-- The prompt leaves the name in a tmux option rather than passing it as an
-- argument, so it never reaches a shell; an argument is still accepted for
-- calling this by hand. The staging option is cleared either way, in the write
-- the rename was going to cost anyway.
commands["rename-to"] = function(name)
  local list = load()
  if not name or name == "" then name = config.raw("rename-input") end

  local agent = nav.current(list)
  local writes = { tmux.set_global_option(nav.RENAME_INPUT, "") }
  if agent and name and name ~= "" then
    writes[#writes + 1] = tmux.set_pane_option(agent.pane, NAME, name)
    writes[#writes + 1] = tmux.set_pane_option(agent.pane, NAME_SESSION, agent.session_key)
  elseif agent then
    writes[#writes + 1] = tmux.unset_pane_option(agent.pane, NAME)
    writes[#writes + 1] = tmux.unset_pane_option(agent.pane, NAME_SESSION)
  end

  tmux.batch(writes)
  if agent then refresh_status() end
end

-- Put a bar pane on every window that is missing one, or has had one shoved out
-- of place by a layout change. Safe to call repeatedly; the layout hook does.
function commands.ensure()
  config.load()
  if not config.enabled("bottom-bar") then return end
  if bottombar.ensure() > 0 then refresh_status() end
end

function commands.teardown()
  bottombar.teardown()
end

local function hook_script()
  local script = nav.script()
  local bin = script:match("^(.*)/tmux%-agent%-tracker$")
  return bin and (bin .. "/tmux-agent-tracker-codex-hook")
    or "tmux-agent-tracker-codex-hook"
end

-- Prints privacy-safe provider readiness and the same liveness-checked roster
-- the bar uses. It never prints session ids, hook payloads or state contents.
function commands.doctor()
  config.load()
  local providers = table.concat(config.providers(), ",")
  local raw = agents.gather({
    providers = providers,
    claude_dir = config.claude_sessions_dir(),
    codex_dir = config.codex_state_dir() or "",
  })
  config.seed(agents.options_text(raw))
  nav.use(config.raw("selected"), config.raw("previous"))

  local list, meta = agents.parse(raw, agents.full_ancestry)
  local opts = render.options()
  local sources = agents.sources(raw)
  local claude_source = sources.claude or { path = config.claude_sessions_dir(), status = "0" }
  local codex_source = sources.codex or { path = config.codex_state_dir() or "", status = "absent" }
  local cstats = meta.sources.codex

  local bridge, codex_notice = codex_hook.readiness(
    codex_hook.configured(hook_script()), cstats)

  print("lua             " .. _VERSION)
  print("tmux            " .. (tmux.query("-V"):gsub("%s+$", "")))
  print("providers       " .. providers)
  print("claude source   " .. claude_source.path
    .. " (" .. meta.sources.claude.records .. " records)")
  print("codex bridge    " .. bridge)
  print("codex state     " .. codex_source.path
    .. " (" .. cstats.valid .. " valid, " .. cstats.invalid .. " invalid, "
    .. cstats.stale .. " stale, " .. (cstats.discovered or 0)
    .. " live provisional; " .. codex_source.status .. ")")
  if codex_notice then print("codex notice    " .. codex_notice) end
  print("agents found    " .. #list .. " (claude " .. (meta.providers.claude or 0)
    .. ", codex " .. (meta.providers.codex or 0) .. ")")
  for _, agent in ipairs(list) do
    print("  [" .. agent.provider .. "] " .. render.describe(agent, opts))
  end

  if #list == 0 then
    print("")
    print("nothing found. start a supported CLI inside a tmux pane.")
    if config.provider_enabled("claude") then
      print("Claude is auto-discovered from " .. claude_source.path .. ".")
    end
    if config.provider_enabled("codex") then
      print("Codex requires the trusted hook bridge printed by codex-hook-config.")
    end
  end
end

-- Codex invokes this through the dedicated launcher. Success and malformed
-- input are intentionally silent so hook telemetry cannot enter the UI/model.
commands["codex-hook"] = function()
  codex_hook.handle(codex_hook.read_stdin())
end

-- Read-only by design: users merge this into a reviewed hooks.json themselves.
commands["codex-hook-config"] = function(state_dir)
  local output = codex_hook.config_json(hook_script(), state_dir)
  if output then print(output) end
end

function M.run(argv)
  local name = argv[1] or "status"
  -- `goto` is a Lua keyword in 5.2+, so the function is spelled goto_ and the
  -- command line still says goto.
  local handler = commands[name] or commands[name .. "_"]
  if not handler then
    io.stderr:write("tmux-agent-tracker: unknown command '" .. name .. "'\n")
    io.stderr:write("commands: status roster list goto next prev focus zoom waiting complete last menu rename rename-to select refresh ensure teardown doctor codex-hook codex-hook-config\n")
    return 1
  end
  handler(argv[2])
  return 0
end

return M
