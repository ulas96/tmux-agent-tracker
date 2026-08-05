-- Claude Code's native session-file adapter.

local json = require("agent_tracker.json")

local M = {}

local function basename(path)
  return (tostring(path):gsub("/+$", ""):match("([^/]+)$")) or path
end

function M.decode(line)
  -- Production collection prefixes the source filename's pid so it can build
  -- one targeted ps query without parsing JSON in the shell. Older fixtures and
  -- callers still hand us the original bare record.
  local source_pid, body = line:match("^(%d+)\t(.*)$")
  local record = json.decode(body or line)
  if type(record) ~= "table" or type(record.pid) ~= "number" then
    return nil, "malformed"
  end
  if record.pid <= 0 or record.pid % 1 ~= 0 then return nil, "malformed" end
  if source_pid and tonumber(source_pid) ~= record.pid then return nil, "malformed" end
  if record.kind == "bg" then return nil, "background" end

  local cwd = type(record.cwd) == "string" and record.cwd or ""
  local name = type(record.name) == "string" and record.name ~= "" and record.name or nil
  return {
    provider = "claude",
    pid = record.pid,
    session_id = type(record.sessionId) == "string" and record.sessionId or nil,
    name = name,
    status = type(record.status) == "string" and record.status or "unknown",
    waiting_for = type(record.waitingFor) == "string" and record.waitingFor or nil,
    cwd = cwd,
    dir = basename(cwd),
    version = record.version,
    updated_at = tonumber(record.statusUpdatedAt) or tonumber(record.updatedAt) or 0,
  }
end

return M
