-- Tests. Run with `lua tests/run.lua` from the repo root.
--
-- No framework on purpose: these are asserts against pure functions, and the
-- point is that they run anywhere Lua does.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local json = require("agent_tracker.json")
local agents = require("agent_tracker.agents")
local render = require("agent_tracker.render")
local nav = require("agent_tracker.nav")
local config = require("agent_tracker.config")

local passed, failed = 0, 0

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL  " .. name .. (detail and ("\n      " .. tostring(detail)) or ""))
  end
end

local function equals(name, actual, expected)
  check(name, actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- --- json -------------------------------------------------------------------

do
  local value = json.decode('{"a":1,"b":"two","c":true,"d":null,"e":[1,2]}')
  equals("json: number", value.a, 1)
  equals("json: string", value.b, "two")
  equals("json: bool", value.c, true)
  equals("json: null sentinel", value.d, json.null)
  equals("json: array", value.e[2], 2)

  -- The reason this decoder exists: task names are user text.
  local quoted = json.decode('{"name":"Fix the \\"foo\\" bug","status":"idle"}')
  equals("json: embedded quotes", quoted.name, 'Fix the "foo" bug')
  equals("json: key after quoted value", quoted.status, "idle")

  local escaped = json.decode('{"p":"a\\\\b\\tc\\nd"}')
  equals("json: escapes", escaped.p, "a\\b\tc\nd")

  equals("json: unicode escape", json.decode('{"u":"\\u00e7"}').u, "ç")
  equals("json: negative", json.decode('{"n":-12.5}').n, -12.5)
  equals("json: big int", json.decode('{"t":1785894201290}').t, 1785894201290)

  check("json: bad input returns nil", json.decode("{oops") == nil)
  check("json: empty returns nil", json.decode("") == nil)
  equals("json: real session line",
    json.decode('{"pid":40050,"sessionId":"2d3f","cwd":"/Users/u/kal","version":"2.1.222",'
      .. '"kind":"interactive","name":"kal-b6","status":"idle","statusUpdatedAt":178}').name,
    "kal-b6")
end

-- --- process ancestry -------------------------------------------------------

do
  local parent = { [40050] = 7696, [7696] = 2462, [999] = 1 }
  local panes = { [7696] = { pane = "%19" } }

  equals("ancestry: one hop", agents.resolve_pane(40050, parent, panes).pane, "%19")
  equals("ancestry: pid is the pane", agents.resolve_pane(7696, parent, panes).pane, "%19")
  check("ancestry: unrelated pid", agents.resolve_pane(999, parent, panes) == nil)

  -- A cycle in the table must not hang the status line.
  local looped = { [5] = 6, [6] = 5 }
  check("ancestry: cycle terminates", agents.resolve_pane(5, looped, {}) == nil)
end

-- --- roster -----------------------------------------------------------------

local FIXTURE = table.concat({
  "#panes",
  "3161 %1 1 0 work",
  "7696 %19 5 3 work",
  "4051 %10 3 2 work",
  "8888 %30 1 0 other",
  "#procs",
  "  3161     1",
  "  7696     1",
  "  4051     1",
  "  8888     1",
  " 40050  7696",
  " 44444  4051",
  " 55555  8888",
  " 66666     1",
  "#sessions",
  '{"pid":40050,"cwd":"/Users/u/kal","name":"zk auth","status":"waiting","kind":"interactive","waitingFor":"input needed","statusUpdatedAt":30}',
  '{"pid":44444,"cwd":"/Users/u/luima","name":"commitment tree","status":"busy","kind":"interactive","statusUpdatedAt":20}',
  '{"pid":55555,"cwd":"/Users/u/erp","name":"invoices","status":"idle","kind":"interactive","statusUpdatedAt":10}',
  -- background job: real session, but no pane of its own to jump to
  '{"pid":66666,"cwd":"/Users/u/bg","name":"batch","status":"busy","kind":"bg","statusUpdatedAt":40}',
  -- dead agent: file is still on disk, its pid has no live pane
  '{"pid":77777,"cwd":"/Users/u/gone","name":"ghost","status":"idle","kind":"interactive","statusUpdatedAt":50}',
}, "\n")

local roster = agents.parse(FIXTURE)

equals("roster: only live pane-backed agents", #roster, 3)
equals("roster: ordered by session then window", roster[1].dir, "erp")
equals("roster: second is window 3", roster[2].dir, "luima")
equals("roster: third is window 5", roster[3].dir, "kal")
equals("roster: index assigned", roster[3].index, 3)
equals("roster: pane carried", roster[3].pane, "%19")
equals("roster: waitingFor carried", roster[3].waiting_for, "input needed")
equals("roster: cwd basename", roster[1].dir, "erp")

do
  local names = {}
  for _, agent in ipairs(roster) do names[agent.name] = true end
  check("roster: background job excluded", not names["batch"])
  check("roster: dead agent excluded", not names["ghost"])
end

-- An agent behind a wrapper process is not in the cheap ps output, so parse has
-- to reach for the full listing — and only then.
do
  local nested = table.concat({
    "#panes",
    "3161 %1 1 0 work",
    "#procs",
    "  3161     1",
    " 40050  9999",
    "#sessions",
    '{"pid":40050,"cwd":"/Users/u/kal","name":"wrapped","status":"idle","kind":"interactive"}',
  }, "\n")

  local shallow = agents.parse(nested)
  equals("fallback: unresolved without it", #shallow, 0)

  local calls = 0
  local deep = agents.parse(nested, function()
    calls = calls + 1
    return " 9999  3161\n"          -- the wrapper hangs off the pane's shell
  end)
  equals("fallback: resolves through wrapper", #deep, 1)
  equals("fallback: called once", calls, 1)
  equals("fallback: lands on the right pane", deep[1].pane, "%1")
end

do
  local calls = 0
  agents.parse(FIXTURE, function() calls = calls + 1; return "" end)
  equals("fallback: not called when all resolve", calls, 0)
end

-- Two session files pointing at one pane: the newer one wins.
do
  local restarted = FIXTURE .. "\n"
    .. '{"pid":40051,"cwd":"/Users/u/kal","name":"restarted","status":"busy","kind":"interactive","statusUpdatedAt":99}'
  -- 40051 has no parent entry, so give it one pointing at the same pane
  restarted = restarted:gsub("#sessions", " 40051  7696\n#sessions", 1)
  local list = agents.parse(restarted)
  equals("roster: newest wins per pane", list[3].name, "restarted")
  equals("roster: still three agents", #list, 3)
end

-- --- rendering --------------------------------------------------------------

local OPTS = {
  icon = "✳",
  symbols = { waiting = "ᵠ", complete = "ᶜ", busy = "", unknown = "·" },
  colors = {
    waiting = "yellow", complete = "green", busy = "blue",
    unknown = "grey", selected = "pink",
  },
  spinner = { "⠂", "⠄", "⠆" },
  label = "dir",
  label_width = 20,
  max = 9,
}

equals("render: waiting is q", render.badge(roster[3], OPTS, 0), "✳³ᵠ")
equals("render: idle is c", render.badge(roster[1], OPTS, 0), "✳¹ᶜ")
equals("render: busy spins", render.badge(roster[2], OPTS, 0), "✳²⠂")
equals("render: spinner advances", render.badge(roster[2], OPTS, 1), "✳²⠄")
equals("render: spinner wraps", render.badge(roster[2], OPTS, 3), "✳²⠂")

equals("render: status key waiting", render.status_key(roster[3]), "waiting")
equals("render: status key idle maps to complete", render.status_key(roster[1]), "complete")
equals("render: unknown status still renders",
  render.badge({ index = 1, status = "wat" }, OPTS, 0), "✳¹·")

equals("render: superscript beyond nine", render.superscript(12), "12")
equals("render: truncate", render.truncate("abcdefgh", 4), "abc…")
equals("render: truncate leaves short alone", render.truncate("abc", 4), "abc")
equals("render: truncate counts characters not bytes", render.truncate("çççççç", 3), "çç…")

check("render: roster contains colour", render.roster(roster, OPTS, 0, nil):find("yellow") ~= nil)
check("render: selected is reversed", render.roster(roster, OPTS, 0, "%19"):find("reverse") ~= nil)
check("render: unselected is not", render.roster(roster, OPTS, 0, nil):find("reverse") == nil)

do
  local capped = {}
  for i = 1, 12 do capped[i] = { index = i, status = "idle" } end
  local narrow = { max = 3 }
  for key, value in pairs(OPTS) do if narrow[key] == nil then narrow[key] = value end end
  local _, count = render.roster(capped, narrow, 0, nil):gsub("✳", "")
  equals("render: roster respects max", count, 3)
end

-- --- the agent bar ----------------------------------------------------------

do
  local opts = {}
  for key, value in pairs(OPTS) do opts[key] = value end
  opts.bar_label, opts.bar_width, opts.bar_separator = "name", 12, "  "

  equals("bar: name then status, no icon or index",
    render.bar_entry(roster[3], opts, 0, false),
    "#[fg=yellow]zk auth" .. "ᵠ" .. "#[default]")

  equals("bar: long names are shortened",
    render.bar_name({ name = "luima-security-remediation", dir = "x" }, opts),
    "luima-secur…")

  equals("bar: dir label", render.bar_name(roster[1], { bar_label = "dir", bar_width = 20 }), "erp")

  check("bar: selected is reversed",
    render.bar(roster, opts, 0, "%19"):find("reverse") ~= nil)
  check("bar: separated", render.bar(roster, opts, 0, nil):find("  ") ~= nil)

  -- Width is a ceiling that gives way as agents pile up.
  equals("fit: plenty of room uses the ceiling", render.fit(3, opts, 300), 12)
  equals("fit: no width known uses the ceiling", render.fit(3, opts, nil), 12)
  check("fit: cramped shrinks", render.fit(9, opts, 100) < 12)
  equals("fit: never below the floor", render.fit(40, opts, 80), 4)

  -- The whole point: everything still fits on the line.
  local narrow = render.bar(roster, opts, 0, nil, 40):gsub("#%[[^%]]*%]", "")
  local count = select(2, narrow:gsub("[^\128-\191]", ""))
  check("fit: output fits the client width", count <= 40, "rendered " .. count .. " columns")
end

-- --- navigation -------------------------------------------------------------

-- nav reads the selection from tmux; stub that out so the maths is testable.
local selection = nil
local tmux = require("agent_tracker.tmux")
tmux.get_global = function(name)
  if name == "@agent-tracker-selected" then return selection or "" end
  return ""
end
tmux.set_global = function() end

selection = nil
equals("nav: defaults to first", nav.current(roster).index, 1)

selection = "%10"
equals("nav: finds selection", nav.current(roster).index, 2)
equals("nav: next", nav.step(roster, 1).index, 3)
equals("nav: prev", nav.step(roster, -1).index, 1)

selection = "%19"
equals("nav: next wraps", nav.step(roster, 1).index, 1)
selection = "%30"
equals("nav: prev wraps", nav.step(roster, -1).index, 3)

selection = "%30"
equals("nav: next waiting", nav.next_with_status(roster, "waiting").index, 3)
equals("nav: next complete skips self", nav.next_with_status(roster, "complete").index, 1)
check("nav: no match returns nil", nav.next_with_status(roster, "nope") == nil)

selection = nil
check("nav: empty roster is safe", nav.step({}, 1) == nil)
check("nav: current of empty is nil", nav.current({}) == nil)

equals("nav: by index", nav.by_index(roster, 2).dir, "luima")
check("nav: out of range", nav.by_index(roster, 99) == nil)

-- --- the bottom bar's placeholder panes -------------------------------------

do
  local bottombar = require("agent_tracker.bottombar")

  -- window pane top width height window_width zoomed mark
  local windows = bottombar.parse(table.concat({
    "@1 %1 0 100 20 100 0 ",      -- ordinary pane
    "@1 %2 21 100 0 100 0 1",     -- a healthy bar: full width, lowest, no rows
    "@2 %3 0 50 20 100 0 ",       -- two panes side by side
    "@2 %4 0 50 20 100 0 ",
    "@2 %5 21 50 0 100 0 1",      -- a bar a layout left half width
    "@3 %6 0 100 20 100 1 ",      -- zoomed window
    "@4 %7 0 100 20 100 0 ",
    "@4 %8 21 100 2 100 0 1",     -- right place, but a layout gave it rows
  }, "\n"))

  equals("bottombar: windows found", 4, 4)
  equals("bottombar: bar detected", windows["@1"].bars[1].id, "%2")
  equals("bottombar: non-bar panes counted", windows["@1"].others, 1)
  equals("bottombar: lowest non-bar top", windows["@1"].lowest, 0)
  equals("bottombar: zoom noticed", windows["@3"].zoomed, true)
  equals("bottombar: unmarked panes are not bars", #windows["@3"].bars, 0)

  check("bottombar: healthy bar passes",
    bottombar.healthy(windows["@1"].bars[1], windows["@1"]))
  check("bottombar: half-width bar fails",
    not bottombar.healthy(windows["@2"].bars[1], windows["@2"]))
  check("bottombar: bar with content rows fails",
    not bottombar.healthy(windows["@4"].bars[1], windows["@4"]),
    "resize-pane cannot reach height 0, so this must be replaced not adjusted")

  -- A bar that ended up above a normal pane is out of position.
  local above = bottombar.parse("@9 %1 21 100 20 100 0 \n@9 %2 0 100 0 100 0 1")
  check("bottombar: bar above a pane fails", not bottombar.healthy(above["@9"].bars[1], above["@9"]))
end

-- --- config -----------------------------------------------------------------

do
  local parsed = config.parse_options(table.concat({
    "status-position top",
    "@agent-tracker-icon A",
    '@agent-tracker-label-width "30"',
    '@agent-tracker-spinner "a,b,c"',
    "@other-plugin-thing 5",
  }, "\n"))

  equals("config: reads our keys", parsed["icon"], "A")
  equals("config: unquotes", parsed["label-width"], "30")
  check("config: ignores other plugins", parsed["thing"] == nil)
end

-- --- quoting ----------------------------------------------------------------

-- Task names reach the shell, so this needs to hold.
equals("tmux: quotes", tmux.quote("plain"), "'plain'")
equals("tmux: escapes single quotes", tmux.quote("it's"), "'it'\\''s'")
check("tmux: neutralises command substitution",
  tmux.quote("$(rm -rf /)"):find("%$%(") ~= nil and tmux.quote("$(x)"):sub(1, 1) == "'")

-- ----------------------------------------------------------------------------

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
