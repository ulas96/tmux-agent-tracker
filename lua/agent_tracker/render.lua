-- Turning agents into the strings tmux draws.
--
-- Every function here is pure and takes its settings as an argument, so the
-- tests can render a roster without a tmux server anywhere in sight.

local config = require("agent_tracker.config")

local M = {}

local SUPERSCRIPT = { "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" }

-- Providers normalize to busy / idle / waiting. Anything unrecognised still
-- draws with the fallback glyph, so a new state upstream is cosmetic rather
-- than a missing agent.
local STATUS_KEYS = {
  waiting = "waiting",
  idle = "complete",
  busy = "busy",
}

-- Only the drawing path flags `unchecked` (init.check_off), so navigation and
-- the CLI still see a finished agent as plain "complete" — `prefix + F` has to
-- find the ones you have not looked at, not skip them.
function M.status_key(agent)
  if agent.unchecked then return "unchecked" end
  return STATUS_KEYS[agent.status] or "unknown"
end

function M.options()
  return {
    icon = config.get("icon"),
    symbols = {
      waiting = config.get("symbol-waiting"),
      complete = config.get("symbol-complete"),
      unchecked = config.get("symbol-unchecked"),
      busy = config.get("symbol-busy"),
      unknown = config.get("symbol-unknown"),
    },
    colors = {
      waiting = config.get("color-waiting"),
      complete = config.get("color-complete"),
      unchecked = config.get("color-unchecked"),
      busy = config.get("color-busy"),
      unknown = config.get("color-unknown"),
      selected = config.get("color-selected"),
    },
    spinner = config.list("spinner"),
    module_style = config.get("module-style"),
    separators = config.list("separators"),
    -- The dark the theme cuts its own module glyphs out of. Even a transparent
    -- bar needs this: a glyph sitting on an accent has to be legible against
    -- it, and the terminal's default foreground is the wrong end of the range.
    ink = config.status_bg(),
    -- What fills the gap behind a cap. The bar on a pane border is meant to
    -- float in the pane area rather than frame it, so there it stays
    -- transparent; in the status line it joins the band the theme drew.
    ground = config.enabled("bottom-bar") and "default" or config.status_bg(),
    reserve = config.enabled("bottom-bar") and 0 or nil,
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

-- The name users see has one provider-independent precedence: an explicit
-- rename for this session, then the provider's chat title, then the project
-- directory. Provider words such as "codex" are not useful session names.
local function nonempty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

function M.agent_name(agent)
  return nonempty(agent.custom)
    or nonempty(agent.name)
    or nonempty(agent.dir)
    or nonempty(agent.provider)
    or "agent"
end

function M.label(agent, opts)
  local text, custom = nil, nonempty(agent.custom)
  local name, dir = nonempty(agent.name), nonempty(agent.dir)
  if custom then
    text = custom
  elseif opts.label == "name" then
    text = M.agent_name(agent)
  elseif opts.label == "both" then
    if dir and name and name ~= dir then
      text = dir .. " " .. name
    else
      text = M.agent_name(agent)
    end
  else
    text = dir or M.agent_name(agent)
  end
  return M.truncate(text or "", opts.label_width)
end

local function style(color, extra)
  return "#[fg=" .. color .. (extra or "") .. "]"
end

local function field(spec, key)
  return spec:match(key .. "=([^,%s]+)")
end

-- One module in the shape most themes draw them: a cap, the status glyph cut
-- out of an accent, then the name on a quieter background, then a closing cap.
--
--   #[fg=ACCENT,bg=GROUND]<#[fg=INK,bg=ACCENT]G #[MODULE] NAME#[fg=PILL,bg=GROUND]>
--
-- The glyph is flush against the opening cap with the pad after it, and the name
-- flush against the closing one with the pad before: that is how every powerline
-- theme spaces a module, and the pill reads as lopsided if it is done the other
-- way round.
--
-- `plain` is what to draw when there is no module-style to build a pill out of,
-- and it is the caller's own concatenation because the orders differ: a bar
-- entry trails its status glyph, a roster leads with the icon. Without
-- module-style this is the plain coloured text the plugin has always drawn,
-- byte for byte, which is what keeps it safe as the shipped default.
function M.module(accent, glyph, text, plain, opts, selected)
  local spec = opts.module_style or ""
  if spec == "" then
    return style(accent, selected and ",reverse,bold" or "") .. plain .. "#[default]"
  end

  local ink = opts.ink or "default"
  local ground = opts.ground or "default"
  local caps = opts.separators or {}
  local left, right = caps[1] or "", caps[2] or ""

  -- Selection recolours the pill rather than reversing it: reverse video against
  -- an accent background lands somewhere nobody chose.
  local pill = spec
  if selected then
    pill = "fg=" .. ink .. ",bg=" .. (opts.colors.selected or accent) .. ",bold"
  end
  local pill_bg = field(pill, "bg") or ground

  local out = {}
  if left ~= "" then
    out[#out + 1] = "#[fg=" .. accent .. ",bg=" .. ground .. "]" .. left
  end
  out[#out + 1] = "#[fg=" .. ink .. ",bg=" .. accent .. "]" .. glyph .. " "
  out[#out + 1] = "#[" .. pill .. "] " .. text
  if right ~= "" then
    out[#out + 1] = "#[fg=" .. pill_bg .. ",bg=" .. ground .. "]" .. right
  end
  out[#out + 1] = "#[default]"
  return table.concat(out)
end

-- Columns a single entry costs on top of its name. A pill pays for both caps,
-- its index and status glyph and the pad either side of them; plain text pays
-- for the glyph alone. fit() and capacity() both budget with this, so turning
-- the pills on shrinks the names instead of running off the edge of the screen.
--
-- `count` is how many are on the bar, which is also the widest index on it: past
-- nine agents every entry is budgeted two columns for the number, so the ones
-- still on a single digit are simply a column to the good.
function M.overhead(opts, count)
  if (opts.module_style or "") == "" then return 1 end
  local caps = opts.separators or {}
  return 4 + #tostring(count or 1)
    + #utf8_chars(caps[1] or "")
    + #utf8_chars(caps[2] or "")
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

-- A badge that only sets a colour, for sitting inside a module that has already
-- established a background. The usual `#[default]` would drop the pill.
local function badge_body(agent, opts, frame, selected)
  local symbol = M.symbol(agent, opts, frame)
  local key = M.status_key(agent)
  local color = opts.colors[key] or opts.colors.unknown
  return style(color, selected and ",bold" or "")
    .. M.superscript(agent.index)
    .. symbol
end

local LOUDNESS = { waiting = 4, unchecked = 3, busy = 2, complete = 1, unknown = 0 }

-- The roster is one pill, so its icon takes the loudest status on it: it goes
-- yellow the moment an agent is waiting on an answer, which is the one state
-- worth noticing out of the corner of an eye.
function M.loudest(agents, opts)
  local best, color = -1, opts.colors.unknown
  for _, agent in ipairs(agents) do
    local key = M.status_key(agent)
    local rank = LOUDNESS[key] or 0
    if rank > best then
      best, color = rank, opts.colors[key] or opts.colors.unknown
    end
  end
  return color
end

-- The roster of badges, for anyone placing it inside an existing status line.
-- As a pill it is a single module rather than one per agent: it sits beside
-- whatever else that line carries, and nine separate caps would swamp them.
function M.roster(agents, opts, frame, selected_pane)
  local shown = {}
  for _, agent in ipairs(agents) do
    if opts.max > 0 and agent.index > opts.max then break end
    shown[#shown + 1] = agent
  end

  if (opts.module_style or "") == "" then
    local parts = {}
    for _, agent in ipairs(shown) do
      parts[#parts + 1] = M.styled_badge(agent, opts, frame, agent.pane == selected_pane)
    end
    return table.concat(parts, " ")
  end

  local parts = {}
  for _, agent in ipairs(shown) do
    parts[#parts + 1] = badge_body(agent, opts, frame, agent.pane == selected_pane)
  end
  return M.module(
    M.loudest(shown, opts),
    opts.icon,
    table.concat(parts, " "),
    "",
    opts,
    false
  )
end

-- A renamed agent keeps its name whatever bar-label says: you typed it, you
-- meant it.
function M.bar_name(agent, opts)
  local text, custom = nil, nonempty(agent.custom)
  local name, dir = nonempty(agent.name), nonempty(agent.dir)
  if custom then
    text = custom
  elseif opts.bar_label == "dir" then
    text = dir or M.agent_name(agent)
  elseif opts.bar_label == "both" then
    if dir and name and name ~= dir then
      text = dir .. "/" .. name
    else
      text = M.agent_name(agent)
    end
  else
    text = M.agent_name(agent)
  end
  return M.truncate(text or "", opts.bar_width)
end

-- One entry on the dedicated agent bar: the task name with its status on it.
--
-- Dressed as a pill the number rides in the accent block, because that is the
-- key you press to get there and the bar is where you go looking for it. Plain
-- it is left off: position in the bar is the index, and without a background to
-- separate it a leading digit just runs into the name.
--
-- The pad between the two is what centres the status glyph in the accent block:
-- module() already leaves a column after it, so without one before it the glyph
-- hangs off the number with all its air on one side — which a one-cell spinner
-- shows up more than a letter does.
function M.bar_entry(agent, opts, frame, selected)
  local symbol, key = M.symbol(agent, opts, frame)
  local color = opts.colors[key] or opts.colors.unknown
  local name = M.bar_name(agent, opts)
  return M.module(color, agent.index .. " " .. symbol, name, name .. symbol, opts, selected)
end

local MIN_NAME = 4
local RESERVE = 12  -- leading pad and the agent-mode indicator on the right

-- bar-width is a ceiling, not a fixed size. Past a certain number of agents the
-- names have to give way or the ones on the end drop off the edge of the screen
-- without a word, which is the one thing a status bar must not do.
-- Neither the leading pad nor the agent-mode indicator exists on a pane border,
-- so the bottom bar gets those columns back — which is most of what the pills
-- cost it.
local function reserved(opts)
  return opts.reserve or RESERVE
end

function M.fit(count, opts, avail)
  if not avail or count == 0 then return opts.bar_width end
  local separators = (count - 1) * #(opts.bar_separator or "  ")
  local budget = avail - reserved(opts) - separators - (count * M.overhead(opts, count))
  local each = math.floor(budget / count)
  if each < MIN_NAME then each = MIN_NAME end
  if each > opts.bar_width then each = opts.bar_width end
  return each
end

-- How many entries of a given name width the line has room for. Only ever bites
-- once fit() has hit the floor and there is no shrinking left to do.
function M.capacity(width, opts, avail, count)
  local each = width + M.overhead(opts, count) + #(opts.bar_separator or "  ")
  return math.max(math.floor((avail - reserved(opts)) / each), 1)
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
    local room = M.capacity(width, opts, avail, #shown)
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
    M.truncate(M.agent_name(agent), 40),
    detail
  )
end

function M.frame()
  return os.time()
end

return M
