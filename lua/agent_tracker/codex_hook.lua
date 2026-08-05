-- Event-driven Codex bridge. The hook reads lifecycle JSON and writes only the
-- minimal tracker contract; it never opens transcript_path or persists prompt,
-- assistant, tool, auth or environment content.

local json = require("agent_tracker.json")
local codex = require("agent_tracker.providers.codex")
local tmux = require("agent_tracker.tmux")

local M = {}

M.MAX_INPUT_BYTES = 65536
M.UPDATED_AT_UNIT = "seconds"

local TRANSITIONS = {
  SessionStart = { status = "idle" },
  UserPromptSubmit = { status = "busy" },
  PreToolUse = { status = "busy" },
  PermissionRequest = { status = "waiting", waiting_for = "approval" },
  PostToolUse = { status = "busy" },
  Stop = { status = "idle" },
  SessionEnd = { remove = true },
}

local function env_get(env, key)
  if env then return env[key] end
  return os.getenv(key)
end

local function clean_text(value, limit)
  return type(value) == "string"
    and #value <= limit
    and not value:find("[%z\1-\31\127]")
end

local function command_ok(command)
  local a, _, c = os.execute(command .. " >/dev/null 2>&1")
  return a == true or a == 0 or c == 0
end

local function uid(env)
  local value = env_get(env, "AGENT_TRACKER_UID") or env_get(env, "UID")
  if tostring(value or ""):match("^%d+$") then return tostring(value) end
  return (tmux.capture("id -u 2>/dev/null"):match("(%d+)") or "")
end

function M.state_dir(env)
  local explicit = env_get(env, "AGENT_TRACKER_CODEX_STATE_DIR")
  if explicit and explicit ~= "" then return explicit end

  local user = uid(env)
  if user == "" then return nil end
  local runtime = env_get(env, "XDG_RUNTIME_DIR")
    or env_get(env, "TMPDIR")
    or "/tmp"
  runtime = runtime:gsub("/+$", "")
  return runtime .. "/tmux-agent-tracker-" .. user .. "/codex"
end

local function valid_dir(path)
  return clean_text(path, 4096) and path:sub(1, 1) == "/" and path ~= "/"
end

-- The final directory must be real, owned by this user and exactly 0700.
-- `umask` in the dedicated launcher covers creation; chmod here keeps direct
-- CLI invocation and diagnostics equally strict.
function M.secure_dir(path)
  if not valid_dir(path) then return false end
  local q = tmux.quote(path)
  return command_ok(table.concat({
    "umask 077",
    "[ ! -L " .. q .. " ]",
    "mkdir -p " .. q,
    "[ -d " .. q .. " ]",
    "[ -O " .. q .. " ]",
    "[ ! -L " .. q .. " ]",
    "chmod 700 " .. q,
    "mode=$(stat -f %Lp " .. q .. " 2>/dev/null || stat -c %a " .. q .. " 2>/dev/null)",
    "[ \"$mode\" = 700 ]",
  }, " && "))
end

local function basename(path)
  return (tostring(path):gsub("/+$", ""):match("([^/]+)$")) or ""
end

local function native_codex(comm)
  local name = basename(comm):lower()
  return name == "codex" or name:match("^codex%-[a-z0-9_%-]+$") ~= nil
end

local function node_codex(comm, args)
  local name = basename(comm):lower()
  if name ~= "node" and name ~= "nodejs" then return false end
  return tostring(args):match("[/\\]@openai[/\\]codex[/\\]bin[/\\]codex%.js[%s\"']") ~= nil
    or tostring(args):match("[/\\]@openai[/\\]codex[/\\]bin[/\\]codex%.js$") ~= nil
end

function M.parse_processes(raw)
  local processes = {}
  for line in tostring(raw):gmatch("[^\n]+") do
    local pid, ppid, comm, args = line:match("^%s*(%d+)%s+(%d+)%s+(%S+)%s*(.*)$")
    if pid then
      processes[tonumber(pid)] = {
        ppid = tonumber(ppid),
        comm = comm,
        args = args,
      }
    end
  end
  return processes
end

-- Start at the hook process's parent and accept only an executable identity:
-- the native binary name, or node running the package's exact bin path. Shell
-- commands whose arguments merely mention the word "codex" do not match.
function M.find_codex_pid(hook_pid, raw)
  local processes = type(raw) == "table" and raw or M.parse_processes(raw)
  local current = processes[tonumber(hook_pid)]
  current = current and current.ppid or nil
  local hops, seen = 0, {}
  while current and current > 1 and hops < 32 and not seen[current] do
    seen[current] = true
    local process = processes[current]
    if not process then return nil end
    if native_codex(process.comm) or node_codex(process.comm, process.args) then return current end
    current = process.ppid
    hops = hops + 1
  end
  return nil
end

function M.discover_pid(env, process_text)
  local hook_pid = tonumber(env_get(env, "AGENT_TRACKER_HOOK_PID"))
  if not hook_pid then return nil end
  local raw = process_text or tmux.capture("ps -eo pid=,ppid=,comm=,args= 2>/dev/null")
  return M.find_codex_pid(hook_pid, raw)
end

function M.transition(event)
  return TRANSITIONS[event]
end

local function validate(payload, pane)
  return type(payload) == "table"
    and codex.valid_session_id(payload.session_id)
    and clean_text(payload.cwd, codex.MAX_TEXT_BYTES)
    and payload.cwd:sub(1, 1) == "/"
    and type(pane) == "string"
    and pane:match("^%%%d+$") ~= nil
end

function M.record(payload, pid, pane, now)
  local transition = TRANSITIONS[payload.hook_event_name]
  if not transition or transition.remove then return nil end
  return {
    schema = 1,
    provider = "codex",
    session_id = payload.session_id,
    pid = pid,
    pane = pane,
    cwd = payload.cwd,
    name = "codex",
    status = transition.status,
    waiting_for = transition.waiting_for or json.null,
    updated_at = now,
  }
end

local function target_path(dir, session_id)
  return dir .. "/" .. session_id .. ".json"
end

local function is_symlink(path)
  return command_ok("[ -L " .. tmux.quote(path) .. " ]")
end

function M.remove_record(dir, session_id)
  local target = target_path(dir, session_id)
  if is_symlink(target) then return false end
  local ok, _, code = os.remove(target)
  -- Missing is already the desired idempotent state.
  return ok ~= nil or code == 2
end

function M.write_record(dir, record, env)
  local encoded = json.encode(record)
  if not encoded or #encoded > codex.MAX_RECORD_BYTES then return false end

  local target = target_path(dir, record.session_id)
  if is_symlink(target) then return false end

  local hook_pid = tostring(env_get(env, "AGENT_TRACKER_HOOK_PID") or "0")
  if not hook_pid:match("^%d+$") then return false end
  local temp = dir .. "/." .. record.session_id .. "." .. hook_pid
    .. "." .. tostring(record.updated_at) .. ".tmp"
  if is_symlink(temp) then return false end

  local file = io.open(temp, "wb")
  if not file then return false end
  local ok = file:write(encoded)
  local closed = file:close()
  if not ok or not closed then
    os.remove(temp)
    return false
  end
  if is_symlink(temp)
      or not command_ok("chmod 600 " .. tmux.quote(temp))
      or is_symlink(target) then
    os.remove(temp)
    return false
  end
  if not os.rename(temp, target) then
    os.remove(temp)
    return false
  end
  return true
end

-- All malformed/unsupported input is a quiet no-op. Telemetry must never
-- change Codex's control flow, model context or terminal output.
function M.handle(input, env, dependencies)
  local ok, result = pcall(function()
    if type(input) ~= "string" or #input == 0 or #input > M.MAX_INPUT_BYTES then return true end
    local payload = json.decode(input)
    if type(payload) ~= "table" then return true end
    local transition = TRANSITIONS[payload.hook_event_name]
    if not transition then return true end

    local pane = env_get(env, "TMUX_PANE")
    if not validate(payload, pane) then return true end
    local dir = M.state_dir(env)
    if not dir or not M.secure_dir(dir) then return true end

    if transition.remove then return M.remove_record(dir, payload.session_id) end

    local deps = dependencies or {}
    local pid = deps.pid or M.discover_pid(env, deps.process_text)
    if type(pid) ~= "number" or pid <= 1 or pid % 1 ~= 0 then return true end
    local now = deps.now or os.time()
    return M.write_record(dir, M.record(payload, pid, pane, now), env)
  end)
  return ok and result ~= false
end

function M.read_stdin()
  local input = io.stdin:read(M.MAX_INPUT_BYTES + 1)
  return input or ""
end

local HOOK_EVENTS = {
  "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
  "PostToolUse", "Stop", "SessionEnd",
}

function M.config_table(handler, state_dir)
  local command = tmux.quote(handler)
  if state_dir and state_dir ~= "" then
    if not valid_dir(state_dir) then return nil, "state directory must be an absolute safe path" end
    command = "AGENT_TRACKER_CODEX_STATE_DIR=" .. tmux.quote(state_dir) .. " " .. command
  end
  local hooks = {}
  for _, event in ipairs(HOOK_EVENTS) do
    hooks[event] = {
      {
        hooks = {
          {
            type = "command",
            command = command,
            timeout = 3,
          },
        },
      },
    }
  end
  return {
    description = "Minimal tmux-agent-tracker lifecycle telemetry; stores no conversation content.",
    hooks = hooks,
  }
end

function M.config_json(handler, state_dir)
  local value, err = M.config_table(handler, state_dir)
  if not value then return nil, err end
  return json.encode(value)
end

local function read_bounded(path, limit)
  local file = io.open(path, "rb")
  if not file then return nil end
  local data = file:read(limit + 1) or ""
  file:close()
  if #data > limit then return nil end
  return data
end

-- Privacy-safe readiness check: look only for the exact installed handler
-- string in bounded config files and never print or return their contents.
function M.configured(handler, env)
  local home = env_get(env, "CODEX_HOME")
  if not home or home == "" then
    local user_home = env_get(env, "HOME")
    home = user_home and (user_home .. "/.codex") or nil
  end
  if not home then return false end
  for _, name in ipairs({ "hooks.json", "config.toml" }) do
    local data = read_bounded(home .. "/" .. name, 262144)
    if data and data:find(handler, 1, true) then return true end
  end
  return false
end

return M
