-- A very small JSON decoder.
--
-- We only ever read Claude Code's session files, which are a single flat object
-- per line, so this handles objects, arrays, strings, numbers, booleans and null
-- and nothing more. It exists instead of a pattern match because task names are
-- user text and regularly contain quotes:
--
--     {"name":"Fix the \"foo\" bug","status":"idle"}
--
-- which a naive `"name":"(.-)"` gets wrong.

local json = {}

local escapes = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

-- UTF-8 encoder for \uXXXX escapes. Lua 5.1 has no utf8 library and we need to
-- keep working on LuaJIT, so this is done by hand.
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  return string.char(
    0xE0 + math.floor(cp / 0x1000),
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

local function skip_space(str, pos)
  local _, stop = str:find("^[ \t\r\n]*", pos)
  return stop + 1
end

local decode_value

local function decode_string(str, pos)
  local parts, at = {}, pos + 1
  while true do
    local char = str:sub(at, at)
    if char == "" then
      error("unterminated string")
    elseif char == '"' then
      return table.concat(parts), at + 1
    elseif char == "\\" then
      local esc = str:sub(at + 1, at + 1)
      if esc == "u" then
        local code = tonumber(str:sub(at + 2, at + 5), 16)
        if not code then error("malformed \\u escape") end
        -- ponytail: surrogate pairs are encoded as two replacement-ish sequences
        -- rather than combined. Claude's session files are plain text; revisit if
        -- emoji ever show up in a task name.
        parts[#parts + 1] = utf8_char(code)
        at = at + 6
      elseif escapes[esc] then
        parts[#parts + 1] = escapes[esc]
        at = at + 2
      else
        error("unknown escape \\" .. esc)
      end
    else
      -- grab the whole run of ordinary characters in one go
      local chunk, next_at = str:match('^([^"\\]+)()', at)
      parts[#parts + 1] = chunk
      at = next_at
    end
  end
end

local function decode_object(str, pos)
  local out = {}
  local at = skip_space(str, pos + 1)
  if str:sub(at, at) == "}" then return out, at + 1 end

  while true do
    at = skip_space(str, at)
    if str:sub(at, at) ~= '"' then error("expected object key") end

    local key
    key, at = decode_string(str, at)

    at = skip_space(str, at)
    if str:sub(at, at) ~= ":" then error("expected ':' after key") end

    out[key], at = decode_value(str, at + 1)

    at = skip_space(str, at)
    local char = str:sub(at, at)
    if char == "}" then return out, at + 1 end
    if char ~= "," then error("expected ',' or '}'") end
    at = at + 1
  end
end

local function decode_array(str, pos)
  local out = {}
  local at = skip_space(str, pos + 1)
  if str:sub(at, at) == "]" then return out, at + 1 end

  while true do
    out[#out + 1], at = decode_value(str, at)

    at = skip_space(str, at)
    local char = str:sub(at, at)
    if char == "]" then return out, at + 1 end
    if char ~= "," then error("expected ',' or ']'") end
    at = at + 1
  end
end

function decode_value(str, pos)
  local at = skip_space(str, pos)
  local char = str:sub(at, at)

  if char == '"' then return decode_string(str, at) end
  if char == "{" then return decode_object(str, at) end
  if char == "[" then return decode_array(str, at) end

  if str:sub(at, at + 3) == "true" then return true, at + 4 end
  if str:sub(at, at + 4) == "false" then return false, at + 5 end
  -- null becomes json.null so that a present-but-null key is distinguishable
  -- from a missing one; callers that don't care just get a truthy sentinel.
  if str:sub(at, at + 3) == "null" then return json.null, at + 4 end

  local number, next_at = str:match("^(%-?%d+%.?%d*[eE]?[-+]?%d*)()", at)
  if number and tonumber(number) then return tonumber(number), next_at end

  error("unexpected character '" .. char .. "' at position " .. at)
end

json.null = setmetatable({}, { __tostring = function() return "null" end })

-- Returns the decoded value, or nil plus a message. Never throws, because the
-- status line calls this once a second on files somebody else is writing.
function json.decode(str)
  if type(str) ~= "string" or str:match("^%s*$") then
    return nil, "empty input"
  end
  local ok, value = pcall(function()
    local result, pos = decode_value(str, 1)
    return result
  end)
  if not ok then return nil, value end
  return value
end

return json
