-- Everything that shells out lives here, so the rest of the plugin can be
-- tested by handing it plain strings.

local M = {}

-- Wrap a value for /bin/sh. Task names come from the user and end up in tmux
-- menu labels and option values, so this is not optional.
function M.quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.capture(command)
  local pipe = io.popen(command, "r")
  if not pipe then return "" end
  local output = pipe:read("*a") or ""
  pipe:close()
  return output
end

function M.run(command)
  os.execute(command .. " >/dev/null 2>&1")
end

function M.tmux(args)
  M.run("tmux " .. args)
end

function M.query(args)
  return M.capture("tmux " .. args .. " 2>/dev/null")
end

-- `tmux display -p` against a specific target, trimmed.
function M.display(target, format)
  local out = M.query("display-message -p -t " .. M.quote(target) .. " " .. M.quote(format))
  return (out:gsub("%s+$", ""))
end

function M.set_global(name, value)
  M.tmux("set-option -gq " .. M.quote(name) .. " " .. M.quote(value))
end

function M.get_global(name)
  local out = M.query("show-option -gqv " .. M.quote(name))
  return (out:gsub("\n$", ""))
end

-- Sends one tmux invocation with many commands joined by `;` rather than one
-- process per pane. With a dozen agents that is the difference between 1 and 13
-- forks every status-line tick.
function M.batch(commands)
  if #commands == 0 then return end
  M.run("tmux " .. table.concat(commands, " \\; "))
end

-- Same as set_global, but returns the command for batching instead of running it.
function M.set_global_option(name, value)
  return "set-option -gq " .. M.quote(name) .. " " .. M.quote(value)
end

function M.set_pane_option(pane, name, value)
  return "set-option -pq -t " .. M.quote(pane) .. " " .. M.quote(name) .. " " .. M.quote(value)
end

function M.unset_pane_option(pane, name)
  return "set-option -pqu -t " .. M.quote(pane) .. " " .. M.quote(name)
end

return M
