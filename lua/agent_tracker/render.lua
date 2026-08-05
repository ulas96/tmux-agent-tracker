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
    bar_label = config.get("bar-label"),
    bar_width = config.number("bar-width"),
    bar_separator = config.get("bar-separator"),
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
  if agent.custom then
    text = agent.custom
  elseif opts.label == "name" then
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

-- The roster of badges, for anyone placing it inside an existing status line.
function M.roster(agents, opts, frame, selected_pane)
  local parts = {}
  for _, agent in ipairs(agents) do
    if opts.max > 0 and agent.index > opts.max then break end
    parts[#parts + 1] = M.styled_badge(agent, opts, frame, agent.pane == selected_pane)
  end
  return table.concat(parts, " ")
end

-- A renamed agent keeps its name whatever bar-label says: you typed it, you
-- meant it.
function M.bar_name(agent, opts)
  local text
  if agent.custom then
    text = agent.custom
  elseif opts.bar_label == "dir" then
    text = agent.dir
  elseif opts.bar_label == "both" then
    text = agent.dir .. "/" .. agent.name
  else
    text = agent.name
  end
  return M.truncate(text or "", opts.bar_width)
end

-- One entry on the dedicated agent bar: the task name with its status hanging
-- off the top right, and no icon or index in front of it. Position in the bar
-- is the index, and the pane's own border badge carries the number.
function M.bar_entry(agent, opts, frame, selected)
  local symbol, key = M.symbol(agent, opts, frame)
  local color = opts.colors[key] or opts.colors.unknown
  return style(color, selected and ",reverse,bold" or "")
    .. M.bar_name(agent, opts)
    .. symbol
    .. "#[default]"
end

local MIN_NAME = 4
local RESERVE = 12  -- leading pad and the agent-mode indicator on the right

-- bar-width is a ceiling, not a fixed size. Past a certain number of agents the
-- names have to give way or the ones on the end drop off the edge of the screen
-- without a word, which is the one thing a status bar must not do.
function M.fit(count, opts, avail)
  if not avail or count == 0 then return opts.bar_width end
  local separators = (count - 1) * #(opts.bar_separator or "  ")
  local symbols = count                      -- one status glyph each
  local budget = avail - RESERVE - separators - symbols
  local each = math.floor(budget / count)
  if each < MIN_NAME then each = MIN_NAME end
  if each > opts.bar_width then each = opts.bar_width end
  return each
end

-- How many entries of a given name width the line has room for. Only ever bites
-- once fit() has hit the floor and there is no shrinking left to do.
function M.capacity(width, opts, avail)
  local each = width + 1 + #(opts.bar_separator or "  ")   -- name, glyph, gap
  return math.max(math.floor((avail - RESERVE) / each), 1)
end

function M.bar(agents, opts, frame, selected_pane, avail)
  local shown = {}
  for _, agent in ipairs(agents) do
    if opts.max > 0 and agent.index > opts.max then break end
    shown[#shown + 1] = agent
  end

  local width = M.fit(#shown, opts, avail)

  -- Past the floor the tail is counted rather than run off the edge, because a
  -- bar that silently loses agents is worse than one that admits it.
  local hidden = 0
  if avail then
    local room = M.capacity(width, opts, avail)
    if #shown > room then
      hidden = #shown - room
      for position = #shown, room + 1, -1 do
        shown[position] = nil
      end
    end
  end

  local sized = setmetatable({ bar_width = width }, { __index = opts })

  local parts = {}
  for _, agent in ipairs(shown) do
    parts[#parts + 1] = M.bar_entry(agent, sized, frame, agent.pane == selected_pane)
  end
  if hidden > 0 then
    parts[#parts + 1] = style(opts.colors.unknown) .. "+" .. hidden .. "#[default]"
  end
  return table.concat(parts, opts.bar_separator or "  ")
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
    M.truncate(agent.custom or agent.name or "", 40),
    detail
  )
end

function M.frame()
  return os.time()
end

return M
