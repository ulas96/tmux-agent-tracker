-- Finding the agents.
--
-- Claude Code writes a small JSON file per process to ~/.claude/sessions/<pid>.json
-- containing its status (busy / idle / waiting), the task name and the cwd. That
-- gives us everything except where the thing is on screen, which we get by walking
-- the process tree from the agent's pid up to a pane's pid.
--
-- A dead agent leaves its file behind but has no live pane ancestor, so stale
-- entries drop out on their own and there is no expiry to maintain.

local json = require("agent_tracker.json")
local tmux = require("agent_tracker.tmux")

local M = {}

local MAX_ANCESTRY_HOPS = 32

-- Everything we need to read, in one shell invocation, marked off with section
-- headers. This runs once a second forever, so the fork count is the thing
-- worth being careful about — options come along for the ride because they live
-- in the same tmux server we are already talking to.
function M.gather(sessions_dir)
  -- The sessions directory is itself a tmux option, so it gets resolved inside
  -- this same shell rather than costing an extra round trip to find out where
  -- to look.
  local resolve = sessions_dir
      and ("dir=" .. tmux.quote(sessions_dir))
    or table.concat({
      'dir=$(tmux show-option -gqv @agent-tracker-sessions-dir)',
      'dir=${dir:-$HOME/.claude/sessions}',
      'case "$dir" in "~"*) dir="$HOME${dir#\\~}" ;; esac',
    }, "; ")

  local script = table.concat({
    resolve,
    "printf '#panes\\n'",
    "tmux list-panes -a -F "
      .. tmux.quote("#{pane_pid} #{pane_id} #{window_index} #{pane_index} #{session_name}"),
    "printf '#options\\n'",
    "tmux show-options -g",
    "printf '#clients\\n'",
    "tmux list-clients -F '#{client_width}'",
    "printf '#procs\\n'",
    -- Session files are named <pid>.json, so the pid list comes from the
    -- filenames without anybody having to parse JSON first. Asking ps about
    -- those pids specifically costs ~6ms against ~40ms for a full process
    -- listing, which matters when this runs every second all day. Anything
    -- that fails to resolve falls back to the full listing below.
    'pids=$(ls "$dir" 2>/dev/null | sed -n "s/\\.json$//p" | tr "\\n" "," )',
    'ps -o pid=,ppid= -p "${pids}$$" 2>/dev/null',
    "printf '#sessions\\n'",
    -- awk rather than cat: the session files have no trailing newline, so cat
    -- welds the end of one JSON object onto the start of the next and both are
    -- lost. `awk 1` prints every line and terminates it.
    'awk 1 "$dir"/*.json',
  }, "; ")

  return tmux.capture("sh -c " .. tmux.quote(script) .. " 2>/dev/null")
end

-- The full process table, used only when the cheap lookup leaves an agent
-- unaccounted for (a wrapper script, a shim, anything more than one hop).
function M.full_ancestry()
  return tmux.capture("ps -eo pid=,ppid= 2>/dev/null")
end

local function split_sections(raw)
  local sections = { panes = {}, options = {}, clients = {}, procs = {}, sessions = {} }
  local current

  for line in raw:gmatch("[^\n]+") do
    local marker = line:match("^#(%a+)$")
    if marker and sections[marker] then
      current = sections[marker]
    elseif current then
      current[#current + 1] = line
    end
  end

  return sections
end

-- The @agent-tracker-* block out of the same read, for config to chew on.
function M.options_text(raw)
  return table.concat(split_sections(raw).options, "\n")
end

-- tmux runs a status line's #() once and shows the result to every client, so
-- the bar has to fit the narrowest one attached or it gets cut off there.
function M.client_width(raw)
  local narrowest
  for _, line in ipairs(split_sections(raw).clients) do
    local width = tonumber(line:match("^%s*(%d+)%s*$"))
    if width and (not narrowest or width < narrowest) then
      narrowest = width
    end
  end
  return narrowest
end

-- session_name is last in the format string because it is the only field that
-- can contain spaces.
local function parse_panes(lines)
  local by_pid = {}
  for _, line in ipairs(lines) do
    local pid, pane, window_index, pane_index, session =
      line:match("^(%d+) (%%%d+) (%d+) (%d+) (.*)$")
    if pid then
      by_pid[tonumber(pid)] = {
        pane = pane,
        window_index = tonumber(window_index),
        pane_index = tonumber(pane_index),
        session = session,
      }
    end
  end
  return by_pid
end

local function parse_procs(lines)
  local parent = {}
  for _, line in ipairs(lines) do
    local pid, ppid = line:match("^%s*(%d+)%s+(%d+)%s*$")
    if pid then parent[tonumber(pid)] = tonumber(ppid) end
  end
  return parent
end

-- Climb from an agent's pid until we hit a pid that owns a pane.
function M.resolve_pane(pid, parent, panes_by_pid)
  local at, hops = pid, 0
  while at and at > 1 and hops < MAX_ANCESTRY_HOPS do
    local pane = panes_by_pid[at]
    if pane then return pane end
    at = parent[at]
    hops = hops + 1
  end
  return nil
end

local function basename(path)
  return (tostring(path):gsub("/+$", ""):match("([^/]+)$")) or path
end

-- Newest wins when two session files land on the same pane, which happens
-- briefly when an agent is restarted in place.
local function newer(a, b)
  return (a.updated_at or 0) > (b.updated_at or 0)
end

-- `deepen` is optional and only called if the cheap process listing left an
-- agent unresolved; leaving it out keeps this function pure for the tests.
function M.parse(raw, deepen)
  local sections = split_sections(raw)
  local panes_by_pid = parse_panes(sections.panes)
  local parent = parse_procs(sections.procs)

  local records, unresolved = {}, false
  for _, line in ipairs(sections.sessions) do
    local record = json.decode(line)
    -- Background jobs are real sessions but they have no pane of their own, so
    -- there is nowhere to jump to. Skip them rather than show a dead entry.
    if type(record) == "table" and record.pid and record.kind ~= "bg" then
      records[#records + 1] = record
      -- A pid missing from the listing altogether is simply dead — its session
      -- file outlived it — and no amount of extra looking will place it. Only a
      -- pid that is alive but whose chain stops short is worth a second query,
      -- otherwise every stale file on disk would drag in a full ps every tick.
      if parent[record.pid] and not M.resolve_pane(record.pid, parent, panes_by_pid) then
        unresolved = true
      end
    end
  end

  -- Someone is running claude behind a wrapper, or has since exited. One full
  -- process listing tells us which, and it only happens when it has to.
  if unresolved and deepen then
    for pid, ppid in tostring(deepen()):gmatch("(%d+)%s+(%d+)") do
      parent[tonumber(pid)] = tonumber(ppid)
    end
  end

  local by_pane = {}
  for _, record in ipairs(records) do
    local pane = M.resolve_pane(record.pid, parent, panes_by_pid)
    if pane then
      local agent = {
        pid = record.pid,
        session_id = record.sessionId,
        name = record.name or "claude",
        status = record.status or "unknown",
        waiting_for = record.waitingFor,
        cwd = record.cwd or "",
        dir = basename(record.cwd or ""),
        version = record.version,
        updated_at = tonumber(record.statusUpdatedAt) or tonumber(record.updatedAt) or 0,
        pane = pane.pane,
        session = pane.session,
        window_index = pane.window_index,
        pane_index = pane.pane_index,
      }
      local existing = by_pane[pane.pane]
      if not existing or newer(agent, existing) then
        by_pane[pane.pane] = agent
      end
    end
  end

  local agents = {}
  for _, agent in pairs(by_pane) do
    agents[#agents + 1] = agent
  end

  -- Stable ordering is what makes "agent 3" mean the same agent five minutes
  -- from now: sort by where the pane is, never by status or activity.
  table.sort(agents, function(a, b)
    if a.session ~= b.session then return a.session < b.session end
    if a.window_index ~= b.window_index then return a.window_index < b.window_index end
    return a.pane_index < b.pane_index
  end)

  for position, agent in ipairs(agents) do
    agent.index = position
  end

  return agents
end

function M.list(sessions_dir)
  return M.parse(M.gather(sessions_dir), M.full_ancestry)
end

function M.find(agents, pane)
  for _, agent in ipairs(agents) do
    if agent.pane == pane then return agent end
  end
  return nil
end

return M
