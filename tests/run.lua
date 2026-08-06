-- Tests. Run with `lua tests/run.lua` from the repo root.
--
-- No framework on purpose: these are asserts against pure functions, and the
-- point is that they run anywhere Lua does.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local json = require("agent_tracker.json")
local agents = require("agent_tracker.agents")
local codex_hook = require("agent_tracker.codex_hook")
local codex_provider = require("agent_tracker.providers.codex")
local render = require("agent_tracker.render")
local nav = require("agent_tracker.nav")
local config = require("agent_tracker.config")
local tmux_api = require("agent_tracker.tmux")

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
  check("json: trailing input is rejected", json.decode('{} trailing') == nil)
  local encoded = assert(json.encode({ text = "a\nb", null = json.null, list = { 1, true } }))
  local roundtrip = assert(json.decode(encoded))
  equals("json: encode string escapes", roundtrip.text, "a\nb")
  equals("json: encode array", roundtrip.list[2], true)
  equals("json: encode null", roundtrip.null, json.null)
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
equals("roster: Claude provider tagged", roster[1].provider, "claude")

do
  local names = {}
  for _, agent in ipairs(roster) do names[agent.name] = true end
  check("roster: background job excluded", not names["batch"])
  check("roster: dead agent excluded", not names["ghost"])
end

-- Provider adapters merge into one roster, ordered only by tmux location.
do
  local mixed = FIXTURE:gsub("#sessions", function() return table.concat({
    " 70000  3161",
    "#codex_sessions",
    'session_a.json\t{"schema":1,"provider":"codex","session_id":"session_a",'
      .. '"pid":70000,"pane":"%1","cwd":"/Users/u/codex-project","name":"codex",'
      .. '"status":"waiting","waiting_for":"approval","updated_at":60}',
    "#sessions",
  }, "\n") end, 1)

  local list, meta = agents.parse(mixed)
  equals("mixed: one merged roster", #list, 4)
  local tracked = agents.find(list, "%1")
  equals("mixed: Codex provider tagged", tracked.provider, "codex")
  equals("mixed: Codex status normalized", tracked.status, "waiting")
  check("mixed: provider fallback is not a chat name", tracked.name == nil)
  equals("mixed: unnamed Codex session uses folder in bar",
    render.bar_name(tracked, { bar_label = "name", bar_width = 30 }), "codex-project")
  equals("mixed: generic approval detail", tracked.waiting_for, "approval")
  equals("mixed: sorted before later windows", tracked.index, 2)
  equals("mixed: Claude count", meta.providers.claude, 3)
  equals("mixed: Codex count", meta.providers.codex, 1)

  local wrong = mixed:gsub('"pane":"%%1"', function() return '"pane":"%99"' end, 1)
  local wrong_list, wrong_meta = agents.parse(wrong)
  equals("mixed: wrong recorded pane skipped", #wrong_list, 3)
  equals("mixed: wrong pane is stale", wrong_meta.sources.codex.stale, 1)

  local future = mixed:gsub('"schema":1', '"schema":2', 1)
  local future_list, future_meta = agents.parse(future)
  equals("mixed: future schema skipped", #future_list, 3)
  equals("mixed: future schema invalid", future_meta.sources.codex.invalid, 1)

  local duplicate = mixed:gsub("#sessions", function() return table.concat({
    'session_z.json\t{"schema":1,"provider":"codex","session_id":"session_z",'
      .. '"pid":70001,"pane":"%1","cwd":"/Users/u/newer","name":"codex",'
      .. '"status":"busy","waiting_for":null,"updated_at":61}',
    "#sessions",
  }, "\n") end, 1):gsub("#codex_sessions", " 70001  3161\n#codex_sessions", 1)
  local deduped = agents.parse(duplicate)
  equals("mixed: newest valid record wins pane", agents.find(deduped, "%1").session_id, "session_z")
  equals("mixed: duplicate is still one agent", #deduped, 4)

  for _, status in ipairs({ "idle", "busy", "waiting", "unknown" }) do
    local waiting = status == "waiting" and '"approval"' or "null"
    local line = 'all_states.json\t{"schema":1,"provider":"codex",'
      .. '"session_id":"all_states","pid":1,"pane":"%1","cwd":"/tmp/p",'
      .. '"name":"codex","status":"' .. status .. '","waiting_for":'
      .. waiting .. ',"updated_at":1}'
    equals("mixed: Codex adapter accepts " .. status,
      codex_provider.decode(line).status, status)
  end
end

-- --- Codex hook bridge ------------------------------------------------------

do
  local expected = {
    SessionStart = "idle",
    UserPromptSubmit = "busy",
    PreToolUse = "busy",
    PermissionRequest = "waiting",
    PostToolUse = "busy",
    Stop = "idle",
  }
  for event, status in pairs(expected) do
    equals("hook transition: " .. event, codex_hook.transition(event).status, status)
  end
  check("hook transition: SessionEnd removes", codex_hook.transition("SessionEnd").remove)
  check("hook transition: unknown is ignored", codex_hook.transition("NewEvent") == nil)

  local direct = table.concat({
    "100 101 /tmp/tmux-agent-tracker /tmp/tmux-agent-tracker codex-hook",
    "101 200 /bin/sh sh -c tracker",
    "200 1 /opt/codex /opt/codex",
  }, "\n")
  equals("hook pid: native binary through shell", codex_hook.find_codex_pid(100, direct), 200)

  local node = table.concat({
    "100 101 tracker tracker",
    "101 201 sh sh -c tracker",
    "201 1 node /usr/bin/node /opt/lib/node_modules/@openai/codex/bin/codex.js",
  }, "\n")
  equals("hook pid: package node shape", codex_hook.find_codex_pid(100, node), 201)

  local unrelated = table.concat({
    "100 101 tracker tracker",
    "101 202 sh sh -c tracker",
    "202 1 bash bash -c 'echo codex'",
  }, "\n")
  check("hook pid: argument substring does not match",
    codex_hook.find_codex_pid(100, unrelated) == nil)

  local payload = {
    hook_event_name = "PermissionRequest",
    session_id = "session_safe",
    cwd = "/tmp/project",
    prompt = "must never persist",
    tool_input = { command = "must never persist" },
    transcript_path = "/private/transcript.jsonl",
    model = "model-name",
  }
  local minimal = codex_hook.record(payload, 4242, "%7", 1785957000)
  local wire = assert(json.encode(minimal))
  equals("hook record: normalized status", minimal.status, "waiting")
  equals("hook record: generic waiting reason", minimal.waiting_for, "approval")
  check("hook record: prompt omitted", not wire:find("must never persist", 1, true))
  check("hook record: transcript omitted", not wire:find("transcript", 1, true))
  check("hook record: model omitted", not wire:find("model-name", 1, true))

  local decoded = codex_provider.decode("session_safe.json\t" .. wire)
  equals("hook record: provider accepts its contract", decoded.session_id, "session_safe")
  check("hook record: invalid session id rejected",
    codex_provider.decode("bad.json\t" .. wire:gsub("session_safe", "bad/id")) == nil)

  local config_json = assert(codex_hook.config_json("/tmp/plugin's path/hook"))
  local hook_config = assert(json.decode(config_json))
  equals("hook config: all seven events", (function()
    local count = 0
    for _ in pairs(hook_config.hooks) do count = count + 1 end
    return count
  end)(), 7)
  equals("hook config: conservative timeout",
    hook_config.hooks.SessionEnd[1].hooks[1].timeout, 3)
  check("hook config: absolute path shell quoted",
    hook_config.hooks.Stop[1].hooks[1].command:find("plugin", 1, true) ~= nil
      and hook_config.hooks.Stop[1].hooks[1].command:find("'\\''", 1, true) ~= nil)
  local custom_config = assert(json.decode(assert(
    codex_hook.config_json("/tmp/hook", "/tmp/private state")
  )))
  check("hook config: explicit state path carried safely",
    custom_config.hooks.Stop[1].hooks[1].command:find(
      "AGENT_TRACKER_CODEX_STATE_DIR='/tmp/private state'", 1, true
    ) ~= nil)
end

-- Exercise the real atomic file boundary in a throwaway directory. This stays
-- outside Codex config and never needs a running tmux server.
do
  local root = os.tmpname() .. "-tmux agent tracker's state"
  os.remove(root)
  local state = root .. "/state"
  local env = {
    AGENT_TRACKER_CODEX_STATE_DIR = state,
    AGENT_TRACKER_HOOK_PID = "9000",
    AGENT_TRACKER_UID = "501",
    TMUX_PANE = "%7",
  }
  local function payload(event, session)
    return assert(json.encode({
      hook_event_name = event,
      session_id = session or "hook_file",
      cwd = "/tmp/project",
      prompt = "private prompt",
      tool_input = { command = "private command" },
    }))
  end
  local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
  end

  local target = state .. "/hook_file.json"
  -- The gate everything else here depends on. `stat -f` is BSD-only and its GNU
  -- and busybox namesake prints a filesystem dump before failing, so getting the
  -- order wrong makes every write below a silent no-op on Linux.
  check("hook dir: a fresh 0700 state directory is accepted",
    codex_hook.secure_dir(state))
  check("hook file: SessionStart succeeds quietly",
    codex_hook.handle(payload("SessionStart"), env, { pid = 4242, now = 100 }))
  equals("hook file: SessionStart is idle", assert(json.decode(read(target))).status, "idle")

  local transitions = {
    UserPromptSubmit = "busy",
    PermissionRequest = "waiting",
    PreToolUse = "busy",
    PostToolUse = "busy",
    Stop = "idle",
  }
  local moment = 101
  for event, status in pairs(transitions) do
    check("hook file: " .. event .. " writes", codex_hook.handle(
      payload(event), env, { pid = 4242, now = moment }
    ))
    local record = assert(json.decode(read(target)))
    equals("hook file status: " .. event, record.status, status)
    if event == "PermissionRequest" then
      equals("hook file: approval is generic", record.waiting_for, "approval")
    end
    moment = moment + 1
  end

  local contents = read(target)
  check("hook file: prompt payload absent", not contents:find("private prompt", 1, true))
  check("hook file: tool payload absent", not contents:find("private command", 1, true))
  -- GNU form first: its BSD counterpart fails quietly, where `stat -f %Lp` on
  -- GNU/busybox prints a whole filesystem dump before exiting non-zero.
  local function mode_of(path)
    return tmux_api.capture(
      "stat -c %a " .. tmux_api.quote(path) .. " 2>/dev/null || stat -f %Lp "
        .. tmux_api.quote(path) .. " 2>/dev/null"
    ):match("(%d+)")
  end
  local dir_mode = mode_of(state)
  local file_mode = mode_of(target)
  equals("hook file: directory mode", dir_mode, "700")
  equals("hook file: record mode", file_mode, "600")

  -- PreToolUse and PostToolUse fire twice per tool call, inside the turn the
  -- user is waiting on, so they must not pay for a process table. The pid comes
  -- back out of the record instead — except on SessionStart, which is the event
  -- a resumed session fires and the one moment the pid behind an id can move.
  local elsewhere = "9000 8000 sh sh\n8000 1 codex /usr/bin/codex\n"
  check("hook pid: a mid-session event still writes", codex_hook.handle(
    payload("Stop"), env, { process_text = elsewhere, now = 130 }))
  equals("hook pid: and reuses the recorded pid rather than rediscovering",
    assert(json.decode(read(target))).pid, 4242)
  check("hook pid: SessionStart rediscovers", codex_hook.handle(
    payload("SessionStart"), env, { process_text = elsewhere, now = 131 }))
  equals("hook pid: so a resumed session picks up its new process",
    assert(json.decode(read(target))).pid, 8000)

  check("hook file: missing TMUX_PANE is a no-op", codex_hook.handle(
    payload("SessionStart", "outside_tmux"), {
      AGENT_TRACKER_CODEX_STATE_DIR = state,
      AGENT_TRACKER_HOOK_PID = "9001",
    }, { pid = 4242, now = 110 }
  ))
  check("hook file: outside tmux creates nothing",
    read(state .. "/outside_tmux.json") == nil)
  check("hook file: malformed input is a no-op", codex_hook.handle("{oops", env))
  check("hook file: oversized input is a no-op",
    codex_hook.handle(string.rep("x", codex_hook.MAX_INPUT_BYTES + 1), env))
  check("hook file: unknown event is a no-op",
    codex_hook.handle(payload("FutureEvent", "future"), env))
  check("hook file: invalid session id is a no-op", codex_hook.handle(
    payload("SessionStart", "bad/session"), env, { pid = 4242, now = 111 }
  ))
  local bad_pane = {}
  for key, value in pairs(env) do bad_pane[key] = value end
  bad_pane.TMUX_PANE = "pane-7"
  check("hook file: invalid pane is a no-op", codex_hook.handle(
    payload("SessionStart", "bad_pane"), bad_pane, { pid = 4242, now = 112 }
  ))

  check("hook file: SessionEnd removes exact record",
    codex_hook.handle(payload("SessionEnd"), env, { now = 120 }))
  check("hook file: record removed", read(target) == nil)

  local sentinel = root .. "/sentinel"
  local sentinel_file = assert(io.open(sentinel, "wb"))
  sentinel_file:write("keep")
  sentinel_file:close()
  os.execute("ln -s " .. tmux_api.quote(sentinel) .. " " .. tmux_api.quote(target))
  check("hook file: symlink destination rejected", not codex_hook.handle(
    payload("SessionStart"), env, { pid = 4242, now = 121 }
  ))
  equals("hook file: symlink target untouched", read(sentinel), "keep")

  local debris = tmux_api.capture(
    "find " .. tmux_api.quote(state) .. " -maxdepth 1 -name '*.tmp' -print"
  )
  equals("hook file: no temporary debris", debris, "")

  os.execute("rm -r " .. tmux_api.quote(root))
end

-- The hot-path command has one targeted process query and no per-record shell
-- loop, even with paths containing spaces and quotes.
do
  local capture = tmux_api.capture
  tmux_api.capture = function(command) return command end
  local command = agents.gather({
    providers = "claude,codex",
    claude_dir = "/tmp/Claude's sessions",
    codex_dir = "/tmp/Codex state",
  })
  tmux_api.capture = capture

  equals("gather: one targeted ps branch",
    select(2, command:gsub("ps %-o pid=,ppid=", "")), 1)
  equals("gather: one full ps branch for blank Codex",
    select(2, command:gsub("ps %-eo pid=,ppid=,stat=,comm=", "")), 1)
  check("gather: ps branches are mutually exclusive",
    command:find('if %[ "%$codex_probe" = 1 %]; then') ~= nil
      and command:find("else ps %-o pid=,ppid=") ~= nil)
  check("gather: no per-record shell loop", not command:find("for "))
  check("gather: quoted path survives", command:find("Claude", 1, true) ~= nil)
  check("gather: rename owner rides with pane data",
    command:find("#{@agent_name_session}", 1, true) ~= nil)
  -- The trailing slash is the pane's current path. Without it the probe also
  -- matches an agent someone renamed to "codex", and the expensive branch then
  -- runs on every tick for the life of the server.
  check("gather: the Codex probe only matches the command field",
    command:find("${tab}codex${tab}/", 1, true) ~= nil)
  -- One spelling of -perm, because GNU find rejects the BSD `+077` outright.
  equals("gather: one portable permission filter",
    select(2, command:gsub("%-perm /077", "")), 1)
  check("gather: no unportable permission filter", not command:find("-perm +077", 1, true))
end

-- Codex currently defers SessionStart until the first prompt on some CLI
-- startup paths. The foreground process makes a blank TUI visible immediately;
-- its first hook record replaces the provisional unknown state.
do
  local blank = table.concat({
    "#panes",
    "68612 %21 5 0 work\t\t\tcodex\t/Users/u/new-project",
    "#sources",
    "codex\t/tmp/state\tsecure",
    "#procs",
    "68612 2462 S+ -zsh",
    "75645 68612 S+ codex",
  }, "\n")
  local list, meta = agents.parse(blank)
  equals("Codex provisional: blank TUI appears", #list, 1)
  equals("Codex provisional: provider", list[1].provider, "codex")
  equals("Codex provisional: foreground pid", list[1].pid, 75645)
  equals("Codex provisional: pane", list[1].pane, "%21")
  equals("Codex provisional: cwd label", list[1].dir, "new-project")
  equals("Codex provisional: unknown until hook", list[1].status, "unknown")
  check("Codex provisional: explicitly marked", list[1].provisional)
  equals("Codex provisional: doctor count", meta.sources.codex.discovered, 1)

  local stopped = blank:gsub("75645 68612 S%+ codex", "75645 68612 T codex")
  equals("Codex provisional: stopped old job excluded", #agents.parse(stopped), 0)

  local unrelated = blank:gsub("\t\t\tcodex\t", "\t\t\tzsh\t")
  equals("Codex provisional: non-Codex pane excluded", #agents.parse(unrelated), 0)

  -- `ps -o comm=` prints a whole executable path on macOS, and a fifth of them
  -- have spaces in it. Anchoring the tail of the line as one more field dropped
  -- every one of those pids out of the ancestry table.
  local spaced = table.concat({
    "#panes",
    "68612 %21 5 0 work\t\t\tcodex\t/Users/u/new-project",
    "#procs",
    "68612 2462 S+ /Applications/My Terminal.app/Contents/MacOS/zsh",
    "75645 68612 S+ /Users/u/Application Support/bin/codex",
  }, "\n")
  local spaced_list = agents.parse(spaced)
  local spaced_first = spaced_list[1] or {}
  equals("spaced comm: a Codex installed under a path with spaces is found",
    #spaced_list, 1)
  equals("spaced comm: ancestry survives a shell with spaces in its path",
    spaced_first.pane, "%21")
  equals("spaced comm: it is still the Codex process that was matched",
    spaced_first.pid, 75645)

  local hook_section = table.concat({
    "#codex_sessions",
    'session_new.json\t{"schema":1,"provider":"codex","session_id":"session_new",'
      .. '"pid":75645,"pane":"%21","cwd":"/Users/u/new-project","name":"codex",'
      .. '"status":"busy","waiting_for":null,"updated_at":10}',
    "#sources",
  }, "\n")
  local tracked = blank:gsub("#sources", function() return hook_section end, 1)
  local authoritative, tracked_meta = agents.parse(tracked)
  equals("Codex provisional: hook state replaces fallback", #authoritative, 1)
  equals("Codex provisional: authoritative status", authoritative[1].status, "busy")
  check("Codex provisional: authoritative is not provisional",
    not authoritative[1].provisional)
  equals("Codex provisional: no fallback counted with hook",
    tracked_meta.sources.codex.discovered, 0)

  local old_hook_section = hook_section
    :gsub('"pid":75645', '"pid":70000')
    :gsub('"status":"busy"', '"status":"idle"')
  local restarted = blank
    :gsub("75645 68612 S%+ codex", "70000 68612 T codex\n75645 68612 S+ codex")
    :gsub("#sources", function() return old_hook_section end, 1)
  local replacement, replacement_meta = agents.parse(restarted)
  equals("Codex provisional: foreground restart replaces stopped record",
    replacement[1].pid, 75645)
  check("Codex provisional: foreground restart is provisional",
    replacement[1].provisional)
  equals("Codex provisional: stopped record is stale",
    replacement_meta.sources.codex.stale, 1)
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

do
  local full_but_unresolved = table.concat({
    "#panes",
    "3161 %1 1 0 work\t\t\tcodex\t/Users/u/project",
    "#procs",
    "3161 1 S+ -zsh",
    "70000 9999 S codex",
    "#codex_sessions",
    'session_old.json\t{"schema":1,"provider":"codex","session_id":"session_old",'
      .. '"pid":70000,"pane":"%1","cwd":"/Users/u/project","name":"codex",'
      .. '"status":"idle","waiting_for":null,"updated_at":10}',
  }, "\n")
  local calls = 0
  agents.parse(full_but_unresolved, function() calls = calls + 1; return "" end)
  equals("fallback: full Codex table is never queried twice", calls, 0)
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
  symbols = { waiting = "ᵠ", complete = "ᶜ", unchecked = "ᶜ", busy = "", unknown = "·" },
  colors = {
    waiting = "yellow", complete = "green", unchecked = "orange", busy = "blue",
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

-- The same options dressed as a theme's modules. Word colours throughout so the
-- assertions below stay readable.
local PILL = setmetatable({
  module_style = "fg=white,bg=grey",
  separators = { "<", ">" },
  ink = "black",
  ground = "navy",
}, { __index = OPTS })

do
  -- Nothing set: byte-identical to the plain coloured text the plugin has always
  -- drawn. This is the guard on shipping the pills off by default.
  equals("module: unset is plain text",
    render.module("yellow", "ᵠ", "name", "nameᵠ", OPTS, false),
    "#[fg=yellow]nameᵠ#[default]")
  equals("module: unset selection still reverses",
    render.module("yellow", "ᵠ", "name", "nameᵠ", OPTS, true),
    "#[fg=yellow,reverse,bold]nameᵠ#[default]")

  -- A style but no caps: flat pills, no particular font needed.
  local flat = setmetatable({ separators = {} }, { __index = PILL })
  equals("module: style without caps",
    render.module("yellow", "ᵠ", "name", "nameᵠ", flat, false),
    "#[fg=black,bg=yellow]ᵠ #[fg=white,bg=grey] name#[default]")

  -- The full grammar. The glyph sits against the opening cap and the name
  -- against the closing one, which is how the themes space theirs; the closing
  -- cap takes the pill's own background so it reads as the end of the pill
  -- rather than a stray block of colour.
  equals("module: full pill",
    render.module("yellow", "ᵠ", "name", "nameᵠ", PILL, false),
    "#[fg=yellow,bg=navy]<#[fg=black,bg=yellow]ᵠ "
      .. "#[fg=white,bg=grey] name#[fg=grey,bg=navy]>#[default]")
  equals("module: selection recolours rather than reversing",
    render.module("yellow", "ᵠ", "name", "nameᵠ", PILL, true),
    "#[fg=yellow,bg=navy]<#[fg=black,bg=yellow]ᵠ "
      .. "#[fg=black,bg=pink,bold] name#[fg=pink,bg=navy]>#[default]")

  equals("module: plain costs one column", render.overhead(OPTS), 1)
  equals("module: flat pill costs five", render.overhead(flat, 3), 5)
  equals("module: capped pill costs seven", render.overhead(PILL, 3), 7)
  equals("module: two-digit indices cost a column more", render.overhead(PILL, 12), 8)
end

do
  equals("roster: plain tier unchanged",
    render.roster(roster, OPTS, 0, nil),
    "#[fg=green]✳¹ᶜ#[default] #[fg=blue]✳²⠂#[default] #[fg=yellow]✳³ᵠ#[default]")

  -- Dressed it is a single module however many agents are on it, and the icon
  -- takes the loudest status: yellow the moment something is waiting.
  local pilled = render.roster(roster, PILL, 0, nil)
  equals("roster: one pill for the whole roster", select(2, pilled:gsub("<", "")), 1)
  check("roster: accent is the loudest status",
    pilled:find("^#%[fg=yellow,bg=navy]<") ~= nil, pilled)
  check("roster: badges keep their own colours inside the pill",
    pilled:find("#%[fg=green%]¹ᶜ") ~= nil, pilled)
end

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

  local dressed = setmetatable({
    module_style = PILL.module_style,
    separators = PILL.separators,
    ink = PILL.ink,
    ground = PILL.ground,
  }, { __index = opts })

  equals("bar: name then status, no icon or index",
    render.bar_entry(roster[3], opts, 0, false),
    "#[fg=yellow]zk auth" .. "ᵠ" .. "#[default]")

  equals("bar: dressed, the number rides in the accent block with the glyph padded",
    render.bar_entry(roster[3], dressed, 0, false),
    "#[fg=yellow,bg=navy]<#[fg=black,bg=yellow]3 ᵠ "
      .. "#[fg=white,bg=grey] zk auth#[fg=grey,bg=navy]>#[default]")

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

  -- Once the names are at the floor the tail is counted instead of overflowing.
  do
    local many = {}
    for index = 1, 30 do
      many[index] = { index = index, name = "agent " .. index, dir = "d", status = "busy", pane = "%" .. index }
    end
    local uncapped = setmetatable({ max = 0 }, { __index = opts })
    local crowded = render.bar(many, uncapped, 0, nil, 80):gsub("#%[[^%]]*%]", "")
    local columns = select(2, crowded:gsub("[^\128-\191]", ""))
    check("bar: crowded output still fits", columns <= 80, "rendered " .. columns .. " columns")
    check("bar: the hidden tail is counted", crowded:find("%+%d+") ~= nil, crowded)
  end

  -- Pills cost six columns an entry, so the same must hold with them on or the
  -- dressing is what pushes the bar off the edge of the screen.
  do
    local narrow = render.bar(roster, dressed, 0, nil, 40):gsub("#%[[^%]]*%]", "")
    local count = select(2, narrow:gsub("[^\128-\191]", ""))
    check("fit: dressed output fits the client width", count <= 40, "rendered " .. count .. " columns")

    local many = {}
    for index = 1, 30 do
      many[index] = { index = index, name = "agent " .. index, dir = "d", status = "busy", pane = "%" .. index }
    end
    local uncapped = setmetatable({ max = 0 }, { __index = dressed })
    local crowded = render.bar(many, uncapped, 0, nil, 80):gsub("#%[[^%]]*%]", "")
    local columns = select(2, crowded:gsub("[^\128-\191]", ""))
    check("bar: dressed and crowded still fits", columns <= 80, "rendered " .. columns .. " columns")

    local selected = render.bar(roster, dressed, 0, "%19")
    check("bar: dressed selection uses color-selected", selected:find("bg=pink") ~= nil, selected)
    check("bar: dressed selection does not reverse", selected:find("reverse") == nil, selected)
  end
end

-- --- checking a finished agent off ------------------------------------------

do
  local tracker = require("agent_tracker.init")

  local CLIENTS = table.concat({ "#clients", "239 %10", "180 %99" }, "\n")

  equals("clients: narrowest width still parses", agents.client_width(CLIENTS), 180)
  local looking = agents.active_panes(CLIENTS)
  check("clients: a client's pane is active", looking["%10"] and looking["%99"])
  check("clients: nothing else is", looking["%1"] == nil)

  local function agent(pane, status) return { pane = pane, status = status } end

  -- Finished in a pane you are not sitting in: loud, and nothing written down.
  local list = { agent("%1", "idle"), agent("%2", "busy") }
  equals("check: an unlooked-at completion is not checked off",
    tracker.check_off(list, {}, nil), "")
  check("check: and is flagged", list[1].unchecked == true)
  equals("check: which renders as its own status", render.status_key(list[1]), "unchecked")
  check("check: a busy agent is never flagged", list[2].unchecked == nil)

  list = { agent("%1", "idle") }
  equals("check: the pane you are in is checked off",
    tracker.check_off(list, { ["%1"] = true }, nil), "%1")
  check("check: so it is not flagged", list[1].unchecked == nil)

  list = { agent("%1", "idle") }
  equals("check: and stays checked once you leave", tracker.check_off(list, {}, "%1"), "%1")
  check("check: still not flagged", list[1].unchecked == nil)

  -- Back to work: the tick is dropped, so whatever it finishes next is loud again.
  equals("check: going busy drops the tick",
    tracker.check_off({ agent("%1", "busy") }, {}, "%1"), "")

  -- The point of all of it.
  equals("check: the badge goes orange",
    render.roster({ { index = 1, pane = "%1", status = "idle", unchecked = true } }, OPTS, 0, nil),
    "#[fg=orange]✳¹ᶜ#[default]")

  local loud = { agent("%1", "busy"), agent("%2", "idle") }
  tracker.check_off(loud, {}, nil)
  equals("check: it outranks busy on the roster icon", render.loudest(loud, OPTS), "orange")
end

-- --- renaming ---------------------------------------------------------------

do
  local renamed = agents.parse(table.concat({
    "#panes",
    "3161 %1 1 0 work\tshipping api\tclaude:chat_a",
    "4051 %10 3 2 my session",          -- no tab at all: older format string
    "8888 %30 4 0 work\tprevious chat\tclaude:old_chat",
    "#procs",
    "  3161     1",
    "  4051     1",
    "  8888     1",
    " 40050  3161",
    " 44444  4051",
    " 55555  8888",
    "#sessions",
    '{"pid":40050,"sessionId":"chat_a","cwd":"/Users/u/kal","name":"zk auth","status":"busy","kind":"interactive"}',
    '{"pid":44444,"cwd":"/Users/u/luima","name":"trees","status":"busy","kind":"interactive"}',
    '{"pid":55555,"sessionId":"new_chat","cwd":"/Users/u/fresh","status":"busy","kind":"interactive"}',
  }, "\n"))

  -- Sorted by session name, so "my session" lands ahead of "work".
  local named = agents.find(renamed, "%1")
  local plain = agents.find(renamed, "%10")
  local replacement = agents.find(renamed, "%30")

  equals("rename: session-owned name carried", named.custom, "shipping api")
  equals("rename: stable session key carried", named.session_key, "claude:chat_a")
  equals("rename: session name still parses", named.session, "work")
  check("rename: absent means nil", plain.custom == nil)
  equals("rename: spaces in a session name survive", plain.session, "my session")
  check("rename: old session name does not reach replacement", replacement.custom == nil)
  check("rename: mismatched owner is marked for cleanup", replacement.stale_custom)

  local opts = { bar_label = "name", bar_width = 20, label = "dir", label_width = 20 }
  equals("rename: the bar shows it", render.bar_name(named, opts), "shipping api")
  equals("rename: the pane border shows it", render.label(named, opts), "shipping api")
  equals("rename: chat title wins over folder", render.bar_name(plain, opts), "trees")
  equals("rename: unnamed replacement uses folder", render.bar_name(replacement, opts), "fresh")
end

-- The name typed at the rename prompt is user text, and tmux substitutes %%
-- before it parses. Anything reaching a shell command reaches `sh` with it.
do
  local template = nav.rename_template("/opt/bin/tmux-agent-tracker")
  check("rename: the typed name is staged in a tmux option",
    template:find('set-option -gq @agent-tracker-rename-input "%%"', 1, true) ~= nil)
  check("rename: nothing typed reaches a shell command",
    not template:match("run%-shell.*$"):find("%%", 1, true))
  check("rename: the callback carries no name argument",
    template:find("rename-to'", 1, true) ~= nil)
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

-- Following tmux's own pane movement writes the same two options a binding
-- does. The previous slot is what Tab flips back to, so re-selecting the pane
-- you are already on must not overwrite it with itself.
do
  local wrote = {}
  local set = tmux.set_global
  tmux.set_global = function(name, value) wrote[name] = value end

  selection = "%10"
  nav.select({ pane = "%19" })
  equals("nav: select remembers the pane left behind", wrote["@agent-tracker-previous"], "%10")
  equals("nav: select stores the new pane", wrote["@agent-tracker-selected"], "%19")

  wrote = {}
  nav.select({ pane = "%10" })
  check("nav: reselecting the current pane leaves previous alone",
    wrote["@agent-tracker-previous"] == nil)

  tmux.set_global = set
end

-- The picker's colours travel on display-menu flags that only exist from tmux
-- 3.4. Older tmux rejects the command outright rather than ignoring them, so
-- every flag has to be dropped together — and an unrecognisable version has to
-- keep them, or a menu nobody could have coloured would be the safe default.
do
  check("nav: 3.4 takes the style flags", nav.styles_supported("tmux 3.4"))
  check("nav: 3.5a takes them", nav.styles_supported("tmux 3.5a"))
  check("nav: 4.0 takes them", nav.styles_supported("tmux 4.0"))
  check("nav: 3.3a does not", not nav.styles_supported("tmux 3.3a"))
  check("nav: 3.0 does not", not nav.styles_supported("tmux 3.0"))
  check("nav: 2.9 does not", not nav.styles_supported("tmux 2.9"))
  check("nav: an unreadable version is assumed new", nav.styles_supported("tmux next"))
  check("nav: no version at all is assumed new", nav.styles_supported(nil))

  equals("nav: styled menu passes all three flags", #nav.menu_styles(PILL, "tmux 3.5a"), 3)
  equals("nav: old tmux gets none of them", #nav.menu_styles(PILL, "tmux 3.3a"), 0)
  -- Still nothing to pass when there is nothing to style, new tmux or not.
  equals("nav: plain options style nothing but the selection",
    #nav.menu_styles(OPTS, "tmux 3.5a"), 2)
end

-- --- the bottom bar's placeholder panes -------------------------------------

do
  local bottombar = require("agent_tracker.bottombar")

  -- window pane top width height window_width zoomed mark
  equals("lock: a private runtime directory is used as it is",
    bottombar.lock_path({ XDG_RUNTIME_DIR = "/run/user/501/" }),
    "/run/user/501/tmux-agent-tracker-ensure.lock")
  equals("lock: TMPDIR is next, and is already per-user on macOS",
    bottombar.lock_path({ TMPDIR = "/var/folders/ab/T" }),
    "/var/folders/ab/T/tmux-agent-tracker-ensure.lock")
  -- A fixed name in a shared /tmp is a neighbour's to take: mkdir is the lock,
  -- so whoever creates it first keeps your bar off for the life of the server.
  equals("lock: a shared /tmp is namespaced per user",
    bottombar.lock_path({ USER = "ada" }),
    "/tmp/tmux-agent-tracker-ada-ensure.lock")

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

  local found = 0
  for _ in pairs(windows) do found = found + 1 end
  equals("bottombar: windows found", found, 4)
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

  -- wanting() runs on every poll and decides whether to spend anything at all,
  -- so a false positive costs two processes a second, forever.
  local function wanting(text)
    return bottombar.wanting(bottombar.parse(text))
  end

  check("wanting: a healthy window wants nothing",
    not wanting("@1 %1 0 100 20 100 0 \n@1 %2 21 100 0 100 0 1"))
  check("wanting: a window with no bar wants one",
    wanting("@1 %1 0 100 20 100 0 "))
  check("wanting: a drifted bar wants fixing",
    wanting("@1 %1 0 50 20 100 0 \n@1 %2 0 50 20 100 0 1"))
  check("wanting: a duplicated bar wants fixing",
    wanting("@1 %1 0 100 20 100 0 \n@1 %2 21 100 0 100 0 1\n@1 %3 21 100 0 100 0 1"))
  check("wanting: a zoomed window is left alone",
    not wanting("@1 %1 0 100 20 100 1 "))
  check("wanting: a window of nothing but bar is left alone",
    not wanting("@1 %2 0 100 0 100 0 1"))
  check("wanting: one bad window among good ones is enough",
    wanting("@1 %1 0 100 20 100 0 \n@1 %2 21 100 0 100 0 1\n@2 %3 0 100 20 100 0 "))

  -- tmux-resurrect saves panes but not pane options, so a restored placeholder
  -- comes back the right shape with no mark on it. Left unclaimed it would sit
  -- there for good while a second bar got built on top of it.
  local restored = bottombar.parse("@1 %1 0 100 20 100 0 \n@1 %2 21 100 0 100 0 ")
  equals("orphan: recognised by shape", #restored["@1"].orphans, 1)
  equals("orphan: not counted as content", restored["@1"].others, 1)
  equals("orphan: does not move the floor", restored["@1"].lowest, 0)
  check("orphan: one in the right place is adoptable",
    bottombar.healthy(restored["@1"].orphans[1], restored["@1"]))
  check("orphan: a window holding only one wants dealing with", wanting(
    "@1 %1 0 100 20 100 0 \n@1 %2 21 100 0 100 0 "))
  check("orphan: a stray beside a good bar wants dealing with", wanting(
    "@1 %1 0 100 20 100 0 \n@1 %2 21 100 0 100 0 1\n@1 %3 22 100 0 100 0 "))

  -- A real pane is never mistaken for one: zero content rows is the tell.
  local ordinary = bottombar.parse("@1 %1 0 100 20 100 0 \n@1 %2 21 100 5 100 0 ")
  equals("orphan: a pane with rows is not one", #ordinary["@1"].orphans, 0)
  equals("orphan: it counts as content instead", ordinary["@1"].others, 2)
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

  config.seed(table.concat({
    "@agent-tracker-providers claude,codex",
    "@agent-tracker-sessions-dir /tmp/legacy",
    "@agent-tracker-claude-sessions-dir /tmp/specific",
    "@agent-tracker-codex-state-dir /tmp/codex",
  }, "\n"))
  equals("config: provider list", table.concat(config.providers(), ","), "claude,codex")
  check("config: Codex enabled", config.provider_enabled("codex"))
  equals("config: provider-specific Claude dir wins",
    config.claude_sessions_dir(), "/tmp/specific")
  equals("config: explicit Codex dir", config.codex_state_dir(), "/tmp/codex")

  config.seed("@agent-tracker-sessions-dir /tmp/legacy")
  equals("config: legacy Claude dir remains supported",
    config.claude_sessions_dir(), "/tmp/legacy")

  -- tmux applies status-bg over status-style, so a theme that sets only the
  -- former must not come back as the stock green nobody asked for.
  config.seed("status-bg #011628\nstatus-style bg=green,fg=black")
  equals("config: status-bg beats status-style", config.status_bg(), "#011628")

  config.seed('status-style "bg=#1e1e2e,fg=#cdd6f4"')
  equals("config: falls back to status-style", config.status_bg(), "#1e1e2e")

  config.seed("status-bg default")
  equals("config: nothing usable is default", config.status_bg(), "default")

  -- Every shipped frame has to be centred in its cell, or the spinner drifts
  -- against an edge and wobbles there once a second: only dots 2,3,5,6 (the
  -- middle two rows), and at least one from each dot column. Bit per dot, and
  -- the arithmetic is longhand because 5.1 has no bitwise operators.
  local centred = true
  for _, frame in ipairs(config.list("spinner")) do
    local _, b2, b3 = frame:byte(1, 3)
    local dots = ((b2 or 0) % 64 * 64 + (b3 or 0) % 64) % 256
    local lit = {}
    for _, dot in ipairs({ 1, 2, 4, 8, 16, 32, 64, 128 }) do
      lit[dot] = math.floor(dots / dot) % 2 == 1
    end
    local edges = lit[1] or lit[8] or lit[64] or lit[128]   -- dots 1, 4, 7, 8
    local left, right = lit[2] or lit[4], lit[16] or lit[32]  -- dots 2,3 and 5,6
    if edges or not (left and right) then centred = false end
  end
  check("config: every default spinner frame is centred in its cell", centred)
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
