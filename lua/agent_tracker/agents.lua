-- Finding and merging pane-backed agents.
--
-- Claude Code supplies native session records. Codex lifecycle hooks supply
-- tracker-owned records containing identity, pane and normalized status. Codex
-- currently defers SessionStart until the first prompt in some CLI paths, so a
-- foreground-process fallback makes a brand-new blank TUI navigable immediately;
-- the hook record replaces that provisional state as soon as it arrives.
-- Both become the same in-memory model here, then share one ancestry walk,
-- deduplication pass, ordering rule, renderer and navigation layer.

local claude = require("agent_tracker.providers.claude")
local codex = require("agent_tracker.providers.codex")
local tmux = require("agent_tracker.tmux")

local M = {}

local MAX_ANCESTRY_HOPS = 32
local MAX_RECORDS = 256
local MAX_CLAUDE_RECORD_BYTES = 65536

local function setting(value, fallback)
  if value == nil or value == "" then return fallback end
  return value
end

-- Everything needed for a tick is emitted by one sh process with marked
-- sections. Record work is bounded and every helper process handles the whole
-- source; the fork count never grows with the number of agents.
function M.gather(overrides)
  if type(overrides) == "string" then overrides = { claude_dir = overrides } end

  local resolve
  if type(overrides) == "table" then
    resolve = table.concat({
      "options=$(tmux show-options -g)",
      "providers=" .. tmux.quote(setting(overrides.providers, "claude,codex")),
      "claude_dir=" .. tmux.quote(setting(overrides.claude_dir, "~/.claude/sessions")),
      "codex_dir=" .. tmux.quote(setting(overrides.codex_dir, "")),
    }, "; ")
  else
    local options_awk = table.concat({
      "{ key=$1; value=$0; sub(/^[^ ]+[ ]/, \"\", value);",
      "if (substr(value,1,1)==\"\\\"\" && substr(value,length(value),1)==\"\\\"\")",
      "value=substr(value,2,length(value)-2);",
      "if (key==\"@agent-tracker-providers\") providers=value;",
      "else if (key==\"@agent-tracker-claude-sessions-dir\") claude=value;",
      "else if (key==\"@agent-tracker-sessions-dir\") legacy=value;",
      "else if (key==\"@agent-tracker-codex-state-dir\") codex=value }",
      "END { printf \"%s%c%s%c%s%c%s\", providers,28,claude,28,legacy,28,codex }",
    }, " ")
    resolve = table.concat({
      "options=$(tmux show-options -g)",
      "settings=$(printf '%s\\n' \"$options\" | awk " .. tmux.quote(options_awk) .. ")",
      "separator=$(printf '\\034')",
      "old_ifs=$IFS; IFS=$separator; set -f; set -- $settings; set +f; IFS=$old_ifs",
      "providers=$1; claude_dir=$2; legacy_dir=$3; codex_dir=$4",
      "providers=${providers:-claude,codex}",
      "claude_dir=${claude_dir:-${legacy_dir:-~/.claude/sessions}}",
    }, "; ")
  end

  local claude_awk = string.format(
    "FNR == 1 && length($0) <= %d && count < %d { "
      .. "name=FILENAME; sub(/^.*\\//, \"\", name); sub(/\\.json$/, \"\", name); "
      .. "print name \"\\t\" $0; count++ }",
    MAX_CLAUDE_RECORD_BYTES,
    MAX_RECORDS
  )
  local codex_awk = string.format(
    "FNR == 1 && length($0) <= %d && count < %d { "
      .. "name=FILENAME; sub(/^.*\\//, \"\", name); print name \"\\t\" $0; count++ }",
    codex.MAX_RECORD_BYTES,
    MAX_RECORDS
  )

  local script = table.concat({
    resolve,
    "case \"$claude_dir\" in \"~\"*) claude_dir=\"$HOME${claude_dir#\\~}\" ;; esac",
    "uid=$(id -u)",
    "if [ -z \"$codex_dir\" ]; then "
      .. "runtime=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}; "
      .. "runtime=${runtime%/}; "
      .. "codex_dir=$runtime/tmux-agent-tracker-$uid/codex; fi",
    "case \"$codex_dir\" in \"~\"*) codex_dir=\"$HOME${codex_dir#\\~}\" ;; esac",

    "claude_on=0; codex_on=0",
    "case ,\"$providers\", in *,claude,*) claude_on=1 ;; esac",
    "case ,\"$providers\", in *,codex,*) codex_on=1 ;; esac",

    -- GNU/busybox `stat -f` means --file-system: it rejects %Lp but writes a
    -- filesystem dump to stdout before failing, so the BSD form has to be the
    -- fallback rather than the first try. Its own failure is quiet.
    "codex_security=disabled",
    "if [ \"$codex_on\" = 1 ]; then "
      .. "codex_security=absent; "
      .. "if [ -L \"$codex_dir\" ]; then codex_security=insecure; "
      .. "elif [ -d \"$codex_dir\" ]; then "
      .. "mode=$(stat -c %a \"$codex_dir\" 2>/dev/null || stat -f %Lp \"$codex_dir\" 2>/dev/null); "
      .. "if [ -O \"$codex_dir\" ] && [ \"$mode\" = 700 ]; then codex_security=secure; "
      .. "else codex_security=insecure; fi; "
      .. "elif [ -e \"$codex_dir\" ]; then codex_security=insecure; fi; fi",

    "pane_data=$(tmux list-panes -a -F "
      .. tmux.quote(
        "#{pane_pid} #{pane_id} #{window_index} #{pane_index} #{session_name}"
          .. "\t#{@agent_name}\t#{@agent_name_session}"
          .. "\t#{pane_current_command}\t#{pane_current_path}"
      ) .. ")",
    "printf '#panes\\n%s\\n' \"$pane_data\"",
    "printf '#options\\n'",
    "printf '%s\\n' \"$options\"",
    "printf '#clients\\n'",
    "tmux list-clients -F '#{client_width} #{pane_id}'",
    "printf '#sources\\n'",
    "printf 'claude\\t%s\\t%s\\n' \"$claude_dir\" \"$claude_on\"",
    "printf 'codex\\t%s\\t%s\\n' \"$codex_dir\" \"$codex_security\"",

    "claude_data=",
    "if [ \"$claude_on\" = 1 ] && [ -d \"$claude_dir\" ]; then "
      .. "claude_data=$(cd \"$claude_dir\" && "
      .. "find . -maxdepth 1 -type f -name '*.json' -print 2>/dev/null "
      .. "| LC_ALL=C grep -E '^\\./[0-9]+\\.json$' | head -n " .. MAX_RECORDS .. " "
      .. "| xargs awk " .. tmux.quote(claude_awk) .. " 2>/dev/null); fi",
    "printf '#claude_sessions\\n%s\\n' \"$claude_data\"",

    -- `-perm /077` ("any of these bits") is the one spelling BSD, GNU and
    -- busybox find all understand; GNU rejects the older `+077` outright.
    "codex_data=",
    "if [ \"$codex_security\" = secure ]; then "
      .. "codex_data=$(cd \"$codex_dir\" && "
      .. "find . -maxdepth 1 -type f -links 1 -user \"$uid\" ! -perm /077 -name '*.json' -print 2>/dev/null "
      .. "| LC_ALL=C grep -E '^\\./[A-Za-z0-9_-]+\\.json$' | head -n " .. MAX_RECORDS .. " "
      .. "| xargs awk " .. tmux.quote(codex_awk) .. " 2>/dev/null); fi",
    "printf '#codex_sessions\\n%s\\n' \"$codex_data\"",

    "printf '#procs\\n'",
    -- A newly opened Codex TUI can exist before its deferred SessionStart hook.
    -- In that case one full process table finds the foreground Codex child of
    -- the pane shell. Otherwise the cheaper provider-record PID query remains
    -- the normal path. Exactly one ps runs in this gathering shell either way.
    "pids=$(printf '%s\\n%s\\n' \"$claude_data\" \"$codex_data\" "
      .. "| sed -n -e 's/^\\([0-9][0-9]*\\)\\t.*/\\1/p' "
      .. "-e 's/^[^\\t]*\\t.*\"pid\":[ ]*\\([0-9][0-9]*\\).*/\\1/p' "
      .. "| head -n " .. (MAX_RECORDS * 2) .. " | tr '\\n' ',')",
    -- The trailing slash is what pins this to the command field: it is followed
    -- by the pane's absolute current path, where a custom agent name of "codex"
    -- is followed by its owner key. Without it, renaming an agent to "codex"
    -- puts the expensive full-table branch on every tick for good.
    "tab=$(printf '\\t'); codex_probe=0",
    "if [ \"$codex_on\" = 1 ]; then case \"$pane_data\" in "
      .. "*\"${tab}codex${tab}/\"*) codex_probe=1 ;; esac; fi",
    "if [ \"$codex_probe\" = 1 ]; then "
      .. "ps -eo pid=,ppid=,stat=,comm= 2>/dev/null; "
      .. "else ps -o pid=,ppid= -p \"${pids}$$\" 2>/dev/null; fi",
  }, "; ")

  return tmux.capture("sh -c " .. tmux.quote(script) .. " 2>/dev/null")
end

-- Used only when the targeted process listing finds a live pid whose ancestry
-- stops before a pane (wrapper scripts and shims).
function M.full_ancestry()
  return tmux.capture("ps -eo pid=,ppid= 2>/dev/null")
end

local function split_sections(raw)
  local sections = {
    panes = {}, options = {}, clients = {}, procs = {}, sessions = {},
    claude_sessions = {}, codex_sessions = {}, sources = {},
  }
  local current
  for line in tostring(raw):gmatch("[^\n]+") do
    local marker = line:match("^#([%a_]+)$")
    if marker and sections[marker] then
      current = sections[marker]
    elseif current then
      current[#current + 1] = line
    end
  end
  return sections
end

function M.options_text(raw)
  return table.concat(split_sections(raw).options, "\n")
end

function M.sources(raw)
  local out = {}
  for _, line in ipairs(split_sections(raw).sources) do
    local provider, path, status = line:match("^([^\t]+)\t([^\t]*)\t([^\t]+)$")
    if provider then out[provider] = { path = path, status = status } end
  end
  return out
end

function M.client_width(raw)
  local narrowest
  for _, line in ipairs(split_sections(raw).clients) do
    local width = tonumber(line:match("^%s*(%d+)"))
    if width and (not narrowest or width < narrowest) then narrowest = width end
  end
  return narrowest
end

function M.active_panes(raw)
  local active = {}
  for _, line in ipairs(split_sections(raw).clients) do
    local pane = line:match("(%%%d+)%s*$")
    if pane then active[pane] = true end
  end
  return active
end

local function parse_panes(lines)
  local by_pid = {}
  for _, line in ipairs(lines) do
    local pid, pane, window_index, pane_index, rest =
      line:match("^(%d+) (%%%d+) (%d+) (%d+) (.*)$")
    if pid then
      -- The controlled fields are taken from the end so a user-entered custom
      -- name can still contain tabs without shifting command/path discovery.
      local session, custom, custom_session, current_command, current_path =
        rest:match("^([^\t]*)\t(.*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
      if not session then
        session, custom, custom_session = rest:match("^([^\t]*)\t(.*)\t([^\t]*)$")
      end
      if not session then session, custom = rest:match("^([^\t]*)\t(.*)$") end
      by_pid[tonumber(pid)] = {
        pane = pane,
        window_index = tonumber(window_index),
        pane_index = tonumber(pane_index),
        session = session or rest,
        custom = custom ~= "" and custom or nil,
        custom_session = custom_session ~= "" and custom_session or nil,
        current_command = current_command ~= "" and current_command or nil,
        current_path = current_path ~= "" and current_path or nil,
      }
    end
  end
  return by_pid
end

-- Only the two numbers are anchored. `comm` is a whole executable path on macOS
-- and a fifth of them contain spaces (`/Library/Application Support/...`), so
-- anchoring the tail as one more %S+ dropped those pids from the ancestry table
-- altogether and broke every walk that crossed one.
local function parse_procs(lines)
  local parent, detail = {}, {}
  for _, line in ipairs(lines) do
    local pid, ppid, rest = line:match("^%s*(%d+)%s+(%d+)%s*(.*)$")
    if pid then
      pid, ppid = tonumber(pid), tonumber(ppid)
      parent[pid] = ppid
      local state, comm = rest:match("^(%S+)%s+(.-)%s*$")
      if state and comm ~= "" then detail[pid] = { state = state, comm = comm } end
    end
  end
  return parent, detail
end

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

local function identity(agent)
  return table.concat({ agent.provider or "", agent.session_id or "", tostring(agent.pid or 0) }, ":")
end

-- A rename belongs to a provider session, not to the tmux pane that happens to
-- host it. Providers without a stable session id fall back to their root pid;
-- that still prevents a replacement process in the same pane inheriting it.
function M.session_key(agent)
  local provider = agent.provider or "agent"
  if type(agent.session_id) == "string" and agent.session_id ~= "" then
    return provider .. ":" .. agent.session_id
  end
  return provider .. ":pid:" .. tostring(agent.pid or 0)
end

local function preferred(a, b)
  local a_time, b_time = a.updated_at or 0, b.updated_at or 0
  if a_time ~= b_time then return a_time > b_time end
  return identity(a) > identity(b)
end

local function metadata()
  return {
    sources = {
      claude = { records = 0, valid = 0, invalid = 0, stale = 0 },
      codex = { records = 0, valid = 0, invalid = 0, stale = 0, discovered = 0 },
    },
    providers = { claude = 0, codex = 0 },
  }
end

-- `deepen` is optional and called at most once when the cheap process listing
-- contains a live record pid but not enough ancestors to place it.
function M.parse(raw, deepen)
  local sections = split_sections(raw)
  local panes_by_pid = parse_panes(sections.panes)
  local parent, process_detail = parse_procs(sections.procs)
  local meta = metadata()
  local records, unresolved = {}, false

  local function decode(lines, provider, adapter)
    for _, line in ipairs(lines) do
      local stats = meta.sources[provider]
      stats.records = stats.records + 1
      local record, reason = adapter.decode(line)
      if record then
        records[#records + 1] = record
        if parent[record.pid] and not M.resolve_pane(record.pid, parent, panes_by_pid) then
          unresolved = true
        end
      elseif reason ~= "background" then
        stats.invalid = stats.invalid + 1
      end
    end
  end

  -- #sessions is the original Claude-only seam retained for fixtures and
  -- callers; production records now have an explicit provider section.
  decode(sections.sessions, "claude", claude)
  decode(sections.claude_sessions, "claude", claude)
  decode(sections.codex_sessions, "codex", codex)

  -- A Codex foreground probe already supplied the complete table. Do not pay
  -- for the legacy wrapper fallback a second time in that branch.
  if unresolved and deepen and next(process_detail) == nil then
    for pid, ppid in tostring(deepen()):gmatch("(%d+)%s+(%d+)") do
      parent[tonumber(pid)] = tonumber(ppid)
    end
  end

  local by_pane = {}
  local function attach(agent, pane)
    agent.session_key = M.session_key(agent)
    agent.custom = pane.custom_session == agent.session_key and pane.custom or nil
    agent.stale_custom = (pane.custom ~= nil or pane.custom_session ~= nil)
      and agent.custom == nil
    agent.pane = pane.pane
    agent.session = pane.session
    agent.window_index = pane.window_index
    agent.pane_index = pane.pane_index
    agent.recorded_pane = nil
  end

  for _, agent in ipairs(records) do
    local pane = M.resolve_pane(agent.pid, parent, panes_by_pid)
    local process = process_detail[agent.pid]
    local foreground = not process
      or tostring(process.state):find("+", 1, true) ~= nil
    if pane and (not agent.recorded_pane or agent.recorded_pane == pane.pane)
        and (agent.provider ~= "codex" or foreground) then
      meta.sources[agent.provider].valid = meta.sources[agent.provider].valid + 1
      attach(agent, pane)

      local existing = by_pane[pane.pane]
      if not existing or preferred(agent, existing) then by_pane[pane.pane] = agent end
    else
      meta.sources[agent.provider].stale = meta.sources[agent.provider].stale + 1
    end
  end

  -- Codex 0.146 can defer SessionStart until the first submitted prompt. A
  -- foreground native codex process establishes presence and pane ownership,
  -- but not lifecycle status, so expose it as provisional/unknown. Hook records
  -- remain authoritative and always win this per-pane merge.
  local provisional = {}
  for pid, process in pairs(process_detail) do
    local command = tostring(process.comm):gsub("/+$", ""):match("([^/]+)$")
    local foreground = tostring(process.state):find("+", 1, true) ~= nil
    if foreground and command and command:lower() == "codex" then
      local pane = M.resolve_pane(pid, parent, panes_by_pid)
      if pane and tostring(pane.current_command):lower() == "codex"
          and not by_pane[pane.pane] then
        local existing = provisional[pane.pane]
        if not existing or pid > existing.pid then
          local cwd = pane.current_path or ""
          provisional[pane.pane] = {
            provider = "codex",
            pid = pid,
            status = "unknown",
            cwd = cwd,
            dir = cwd:gsub("/+$", ""):match("([^/]+)$") or cwd,
            updated_at = 0,
            provisional = true,
            pane_info = pane,
          }
        end
      end
    end
  end
  for pane_id, agent in pairs(provisional) do
    attach(agent, agent.pane_info)
    agent.pane_info = nil
    by_pane[pane_id] = agent
    meta.sources.codex.discovered = meta.sources.codex.discovered + 1
  end

  local list = {}
  for _, agent in pairs(by_pane) do list[#list + 1] = agent end
  table.sort(list, function(a, b)
    if a.session ~= b.session then return a.session < b.session end
    if a.window_index ~= b.window_index then return a.window_index < b.window_index end
    if a.pane_index ~= b.pane_index then return a.pane_index < b.pane_index end
    return identity(a) < identity(b)
  end)

  for index, agent in ipairs(list) do
    agent.index = index
    meta.providers[agent.provider] = (meta.providers[agent.provider] or 0) + 1
  end
  return list, meta
end

function M.list(overrides)
  return M.parse(M.gather(overrides), M.full_ancestry)
end

function M.find(list, pane)
  for _, agent in ipairs(list) do
    if agent.pane == pane then return agent end
  end
  return nil
end

return M
