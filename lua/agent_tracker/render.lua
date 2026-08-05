-- Turning agents into the strings tmux draws.
--
-- Every function here is pure and takes its settings as an argument, so the
-- tests can render a roster without a tmux server anywhere in sight.

local config = require("agent_tracker.config")

local M = {}

local SUPERSCRIPT = { "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" }

-- Claude reports busy / idle / waiting. Anything we don't recognise still gets
-- drawn, just with the fallback glyph, so a new state upstream is a cosmetic
-- surprise rather than a missing agent.
local STATUS_KEYS = {
  waiting = "waiting",
  idle = "complete",
  busy = "busy",
}

function M.status_key(agent)
  return STATUS_KEYS[agent.status] or "unknown"
end

function M.options()
  return {
    icon = config.get("icon"),
    symbols = {
      waiting = config.get("symbol-waiting"),
      complete = config.get("symbol-complete"),
      busy = config.get("symbol-busy"),
      unknown = config.get("symbol-unknown"),
    },
    colors = {
      waiting = config.get("color-waiting"),
      complete = config.get("color-complete"),
      busy = config.get("color-busy"),
      unknown = config.get("color-unknown"),
      selected = config.get("color-selected"),
    },
    spinner = config.list("spinner"),
    label = config.get("label"),
    label_width = config.number("label-width"),
    max = config.number("max"),
  }
end

local function utf8_chars(str)
  local chars = {}
  for char in tostring(str):gmatch("[\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = char
  end
  return chars
end

function M.truncate(str, width)
  local chars = utf8_chars(str)
  if width <= 0 or #chars <= width then return str end
  return table.concat(chars, "", 1, math.max(width - 1, 1)) .. "…"
end

function M.superscript(index)
  return SUPERSCRIPT[index] or tostring(index)
end

-- `frame` is passed in rather than read from the clock so the tests are not
-- racing a spinner.
function M.symbol(agent, opts, frame)
  local key = M.status_key(agent)
  local symbol = opts.symbols[key] or ""

  -- An empty busy symbol means "animate instead", which is the default: a
  -- working agent reads as alive without adding a letter to decode.
  if key == "busy" and symbol == "" then
    local frames = opts.spinner
    if #frames > 0 then
      symbol = frames[(frame % #frames) + 1]
    end
  end

  return symbol, key
end

function M.badge(agent, opts, frame)
  local symbol = M.symbol(agent, opts, frame)
  return opts.icon .. M.superscript(agent.index) .. symbol
end

function M.label(agent, opts)
  local text
  if opts.label == "name" then
    text = agent.name
  elseif opts.label == "both" then
    text = agent.dir .. " " .. agent.name
  else
    text = agent.dir
  end
  return M.truncate(text or "", opts.label_width)
end

local function style(color, extra)
  return "#[fg=" .. color .. (extra or "") .. "]"
end

function M.styled_badge(agent, opts, frame, selected)
  local symbol, key = M.symbol(agent, opts, frame)
  local color = opts.colors[key] or opts.colors.unknown
  local body = opts.icon .. M.superscript(agent.index) .. symbol
  return style(color, selected and ",reverse,bold" or "") .. body .. "#[default]"
end

-- The bottom-border label for a single pane: badge plus a short name.
function M.pane_badge(agent, opts, frame)
  local symbol, key = M.symbol(agent, opts, frame)
  local color = opts.colors[key] or opts.colors.unknown
  return style(color)
    .. opts.icon
    .. M.superscript(agent.index)
    .. symbol
    .. "#[default]"
end

-- The roster that goes in the status bar.
function M.roster(agents, opts, frame, selected_pane)
  local parts = {}
  for _, agent in ipairs(agents) do
    if opts.max > 0 and agent.index > opts.max then break end
    parts[#parts + 1] = M.styled_badge(agent, opts, frame, agent.pane == selected_pane)
  end
  return table.concat(parts, " ")
end

-- Human-readable one-liner, used by the picker menu and `agents` on the CLI.
function M.describe(agent, opts)
  local symbol = M.symbol(agent, opts, 0)
  local where = agent.session .. ":" .. agent.window_index .. "." .. agent.pane_index
  local detail = agent.waiting_for and (" (" .. agent.waiting_for .. ")") or ""
  return string.format(
    "%d %s%s  %s  %s%s",
    agent.index,
    opts.icon,
    symbol,
    where,
    M.truncate(agent.name or "", 40),
    detail
  )
end

function M.frame()
  return os.time()
end

return M
