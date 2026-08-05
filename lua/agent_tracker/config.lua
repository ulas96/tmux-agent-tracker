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
  -- Finished, and you have not been back to look: same glyph, louder colour.
  ["symbol-unchecked"] = "ᶜ",
  ["symbol-busy"] = "",
  ["symbol-unknown"] = "·",
  -- A braille cell is a 2x4 dot grid, and a frame is only centred in its column
  -- if it lights both dot columns and neither the top row (dots 1,4) nor the
  -- bottom (7,8). That leaves dots 2,3,5,6 — the middle four — and the four
  -- frames below are every balanced pair of them: a two-dot bar turning 45° a
  -- frame around the centre of the cell, with equal air on all four sides.
  -- Frames that light one column only make the spinner jitter sideways.
  ["spinner"] = "⠒,⠢,⠤,⠔",

  ["color-waiting"] = "#f9e2af",
  ["color-complete"] = "#a6e3a1",
  ["color-unchecked"] = "#fab387",
  ["color-busy"] = "#89b4fa",
  ["color-unknown"] = "#6c7086",
  ["color-selected"] = "#f5c2e7",

  -- Powerline dressing, both off by default: plain coloured text needs no
  -- particular font and suits a bare tmux, which is what most people have.
  -- Set them to match a theme that draws its modules as pills:
  --   set -g @agent-tracker-separators ','          # U+E0B6, U+E0B4
  --   set -g @agent-tracker-module-style 'fg=#cdd6f4,bg=#313244'
  -- The separators are the caps on either end; module-style is what the name
  -- itself sits on. Caps without a module-style have nothing to cap, so
  -- module-style is the switch that turns the whole shape on.
  ["separators"] = "",
  ["module-style"] = "",

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
  -- Every live agent goes on the bar; the names shrink to make room rather than
  -- the ones on the end vanishing. Set a number to cap it again.
  ["max"] = "0",
  ["interval"] = "1",
  ["providers"] = "claude,codex",
  -- `sessions-dir` is the original Claude option. A provider-specific value
  -- wins when present; keeping the alias avoids a migration flag day.
  ["sessions-dir"] = "~/.claude/sessions",
  ["claude-sessions-dir"] = "",
  ["codex-state-dir"] = "",

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
local theme_cache

-- The theme's own options, worth picking up out of the same dump so a pill can
-- be painted in the colour the status line already uses. Kept in a table of
-- their own rather than alongside ours, so that an @agent-tracker-status-bg
-- could never be mistaken for tmux's status-bg.
local THEME_KEYS = {
  ["status-bg"] = true,
  ["status-style"] = true,
}

local function unquote(value)
  local inner = value:match('^"(.*)"$')
  if inner then return (inner:gsub("\\(.)", "%1")) end
  return value
end

-- `tmux show -g` prints `name value`, with the value quoted when it contains
-- anything interesting. We only care about a handful of keys, so everything
-- else is skipped rather than parsed properly.
local function parse_options(text)
  local found, theme = {}, {}
  for line in text:gmatch("[^\n]+") do
    -- No brackets in the name pattern, so the status-format array — the one
    -- option here whose value runs to hundreds of characters — never matches.
    local name, value = line:match("^([%w@%-]+)%s+(.*)$")
    if name and name:sub(1, #M.prefix) == M.prefix then
      found[name:sub(#M.prefix + 1)] = unquote(value)
    elseif name and THEME_KEYS[name] then
      theme[name] = unquote(value)
    end
  end
  return found, theme
end

M.parse_options = parse_options

-- Fill the cache from an option dump somebody else already paid for, so the
-- once-a-second path doesn't fork just to re-read what it just read.
function M.seed(text)
  cache, theme_cache = parse_options(text)
  return cache
end

function M.load()
  if cache then return cache end
  cache, theme_cache = parse_options(tmux.query("show-options -g"))
  return cache
end

-- What the theme paints its status line with, for cutting a glyph out of an
-- accent or filling the gap behind a powerline cap.
--
-- tmux keeps status-bg as an option in its own right and applies it over
-- status-style, so a theme that sets one wins even though status-style still
-- reads as the stock `bg=green` it was never asked about. Ask in that order or
-- every catppuccin user gets a green pill.
function M.status_bg()
  M.load()
  local theme = theme_cache or {}
  local bg = theme["status-bg"]
  if not bg or bg == "" or bg == "default" then
    bg = (theme["status-style"] or ""):match("bg=([^,%s]+)")
  end
  if not bg or bg == "" then return "default" end
  return bg
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
    local trimmed = item:match("^%s*(.-)%s*$")
    if trimmed ~= "" then out[#out + 1] = trimmed end
  end
  return out
end

local function expand_home(dir)
  local home = os.getenv("HOME") or ""
  return (dir:gsub("^~", home))
end

function M.providers()
  return M.list("providers")
end

function M.provider_enabled(wanted)
  for _, provider in ipairs(M.providers()) do
    if provider == wanted then return true end
  end
  return false
end

function M.claude_sessions_dir()
  local dir = M.raw("claude-sessions-dir")
    or M.raw("sessions-dir")
    or M.defaults["sessions-dir"]
  return expand_home(dir)
end

-- Backward-compatible API used by older callers and integrations.
M.sessions_dir = M.claude_sessions_dir

function M.codex_state_dir()
  local dir = M.raw("codex-state-dir")
  return dir and expand_home(dir) or nil
end

return M
