-- A very small JSON codec.
--
-- We read provider session records and write the much smaller Codex bridge
-- records, so this handles objects, arrays, strings, numbers, booleans and null
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
    if skip_space(str, pos) <= #str then error("trailing input") end
    return result
  end)
  if not ok then return nil, value end
  return value
end

local encode_escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encode_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    return encode_escapes[char] or string.format("\\u%04x", char:byte())
  end) .. '"'
end

local function is_array(value)
  local count, greatest = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
    if key > greatest then greatest = key end
  end
  return count > 0 and greatest == count
end

local encode_value

local function encode_table(value, seen)
  if seen[value] then error("cyclic table") end
  seen[value] = true

  local out = {}
  if is_array(value) then
    for index = 1, #value do
      out[#out + 1] = encode_value(value[index], seen)
    end
    seen[value] = nil
    return "[" .. table.concat(out, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then error("object key is not a string") end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    out[#out + 1] = encode_string(key) .. ":" .. encode_value(value[key], seen)
  end
  seen[value] = nil
  return "{" .. table.concat(out, ",") .. "}"
end

function encode_value(value, seen)
  local kind = type(value)
  if value == json.null then return "null" end
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "string" then return encode_string(value) end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("non-finite number")
    end
    return tostring(value)
  end
  if kind == "table" then return encode_table(value, seen) end
  error("unsupported value type " .. kind)
end

-- Returns nil plus a message rather than throwing. Hook telemetry must never
-- interfere with Codex just because a record could not be serialized.
function json.encode(value)
  local ok, encoded = pcall(encode_value, value, {})
  if not ok then return nil, encoded end
  return encoded
end

return json
