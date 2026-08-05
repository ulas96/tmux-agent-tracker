-- The adapter for tracker-owned Codex hook records. It deliberately knows
-- nothing about Codex transcripts or rollout files.

local json = require("agent_tracker.json")

local M = {}

M.MAX_RECORD_BYTES = 8192
M.MAX_TEXT_BYTES = 4096

local STATUS = { idle = true, busy = true, waiting = true, unknown = true }

local function clean_text(value, limit)
  return type(value) == "string"
    and #value <= limit
    and not value:find("[%z\1-\31\127]")
end

local function basename(path)
  return (tostring(path):gsub("/+$", ""):match("([^/]+)$")) or path
end

function M.valid_session_id(value)
  return type(value) == "string"
    and #value > 0
    and #value <= 128
    and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

function M.decode(line)
  if type(line) ~= "string" or #line > M.MAX_RECORD_BYTES + 140 then
    return nil, "oversized"
  end

  local filename, body = line:match("^([^\t]+)\t(.*)$")
  if not filename then return nil, "missing filename" end
  local source_id = filename:match("^([A-Za-z0-9_-]+)%.json$")
  if not source_id then return nil, "invalid filename" end

  local record = json.decode(body)
  if type(record) ~= "table"
      or record.schema ~= 1
      or record.provider ~= "codex"
      or not M.valid_session_id(record.session_id)
      or record.session_id ~= source_id
      or type(record.pid) ~= "number"
      or record.pid <= 0
      or record.pid % 1 ~= 0
      or type(record.pane) ~= "string"
      or not record.pane:match("^%%%d+$")
      or not clean_text(record.cwd, M.MAX_TEXT_BYTES)
      or not clean_text(record.name, 128)
      or not STATUS[record.status]
      or type(record.updated_at) ~= "number"
      or record.updated_at < 0
      or record.updated_at ~= record.updated_at then
    return nil, "malformed"
  end

  local waiting = record.waiting_for
  if waiting == json.null then waiting = nil end
  if waiting ~= nil and waiting ~= "approval" then return nil, "malformed" end
  if record.status == "waiting" and waiting ~= "approval" then return nil, "malformed" end
  if record.status ~= "waiting" and waiting ~= nil then return nil, "malformed" end

  -- Schema 1 originally stored the provider fallback "codex". That is not a
  -- chat title, so expose it as absent and let the renderer use the cwd's
  -- basename. A future real session title remains available as `name`.
  local name = record.name ~= "" and record.name ~= "codex" and record.name or nil

  return {
    provider = "codex",
    pid = record.pid,
    session_id = record.session_id,
    name = name,
    status = record.status,
    waiting_for = waiting,
    cwd = record.cwd,
    dir = basename(record.cwd),
    updated_at = record.updated_at,
    recorded_pane = record.pane,
  }
end

return M
