-- Entry point. The shell shim hands us the plugin root via arg[0].

local root = arg[0]:match("^(.*)/lua/main%.lua$") or "."

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

os.exit(require("agent_tracker").run(arg))
