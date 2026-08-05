-- Reads @agent-tracker-* options out of tmux.
--
-- One `tmux show -g` gives us every option that has been set; anything missing
-- falls back to the defaults below. That keeps it to a single fork per run
-- instead of one per lookup.

local tmux = require("agent_tracker.tmux")

local M = {}

M.prefix = "@agent-tracker-"

M.defaults = {
  -- appearance
  ["icon"] = "✳",
  ["symbol-waiting"] = "ᵠ",
  ["symbol-complete"] = "ᶜ",
  ["symbol-busy"] = "",
  ["symbol-unknown"] = "·",
  ["spinner"] = "⠂,⠄,⠆,⠇,⠋,⠉,⠈,⠉",

  ["color-waiting"] = "#f9e2af",
  ["color-complete"] = "#a6e3a1",
  ["color-busy"] = "#89b4fa",
  ["color-unknown"] = "#6c7086",
  ["color-selected"] = "#f5c2e7",

  -- what the pane border label says: dir | name | both
  ["label"] = "dir",
  ["label-width"] = "20",

  -- the agent bar shows the task name itself, so it wants a tighter budget
  -- bar-width is the most a name may take, not what it will take: the bar
  -- shrinks names to fit the narrowest attached client, so this can be generous.
  ["bar-label"] = "name",
  ["bar-width"] = "18",
  ["bar-separator"] = "  ",

  -- behaviour
  ["max"] = "9",
  ["interval"] = "1",
  ["sessions-dir"] = "~/.claude/sessions",

  -- wiring, all opt-out
  ["keys"] = "on",
  ["pane-border"] = "on",
  ["bar"] = "on",
  -- Put the bar on the window's last row instead of in the status line, so the
  -- panes sit between your theme at the top and the agents at the bottom. Costs
  -- a placeholder pane per window; see bottombar.lua.
  ["bottom-bar"] = "off",
  -- Left alone by default. Both status lines share one position whatever we do,
  -- so there is nothing to gain by overriding what somebody already set.
  ["status-position"] = "off",
  ["alert"] = "off",
}

local cache

-- `tmux show -g` prints `name value`, with the value quoted when it contains
-- anything interesting. We only care about our own keys, so everything else is
-- skipped rather than parsed properly.
local function parse_options(text)
  local found = {}
  for line in text:gmatch("[^\n]+") do
    local name, value = line:match("^(@agent%-tracker%-[%w%-]+)%s+(.*)$")
    if name then
      local unquoted = value:match('^"(.*)"$')
      if unquoted then
        value = unquoted:gsub("\\(.)", "%1")
      end
      found[name:sub(#M.prefix + 1)] = value
    end
  end
  return found
end

M.parse_options = parse_options

-- Fill the cache from an option dump somebody else already paid for, so the
-- once-a-second path doesn't fork just to re-read what it just read.
function M.seed(text)
  cache = parse_options(text)
  return cache
end

function M.load()
  if cache then return cache end
  cache = parse_options(tmux.query("show-options -g"))
  return cache
end

-- Reads a key with no default behind it, e.g. the stored selection.
function M.raw(key)
  local value = M.load()[key]
  if value == nil or value == "" then return nil end
  return value
end

function M.get(key)
  local set = M.load()
  local value = set[key]
  if value == nil or value == "" then
    return M.defaults[key]
  end
  return value
end

function M.number(key)
  return tonumber(M.get(key)) or tonumber(M.defaults[key]) or 0
end

function M.enabled(key)
  local value = M.get(key)
  return value == "on" or value == "1" or value == "true" or value == "yes"
end

-- Splits a comma separated option into a list, e.g. the spinner frames.
function M.list(key)
  local out = {}
  for item in (M.get(key) or ""):gmatch("[^,]+") do
    out[#out + 1] = item
  end
  return out
end

function M.sessions_dir()
  local dir = M.get("sessions-dir")
  local home = os.getenv("HOME") or ""
  return (dir:gsub("^~", home))
end

return M
