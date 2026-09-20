-- mem_report.lua - how much memory this app costs just to *compile*.
--
-- The badge parses and compiles the whole of main.lua before on_enter runs,
-- and that compile is what fails with "Lua memory limit exceeded". Source
-- bytes are a bad proxy for it: build.py strips 28% of the source and the
-- compiled footprint does not move by a single byte. This measures the thing
-- that actually matters - what a compiled chunk retains - by loading it
-- without running it and weighing the heap either side.
--
--     lua tools/mem_report.lua                  # main.lua and goose_duel.lua
--     lua tools/mem_report.lua goose_duel.lua
--     lua tools/mem_report.lua --max 44         # fail above 44 KB retained
--
-- Exits non-zero if any file exceeds the ceiling, so it can gate a build.
--
-- This host is 64-bit; the badge is a 32-bit ESP32 whose pointers, and so
-- whose Proto/TString/Table overheads, are roughly half the size. Treat the
-- number as a RELATIVE budget for comparing two versions of this app, never
-- as a prediction of the badge's own `lua_used`.

local DEFAULT_FILES = { "main.lua", "goose_duel.lua" }
-- Calibrated against the badge, not chosen: commit a996e29 measures 47.0 KB
-- and boots at heap_kb=48; the next commit measures 48.0 KB and was the one
-- that first failed with "Lua memory limit exceeded" at startup. The cliff is
-- somewhere in that 1 KB. Anything at or below 47.0 is in known-good
-- territory; this ceiling leaves a little room and fails the build above it.
local DEFAULT_MAX_KB = 47.5

local files, max_kb = {}, DEFAULT_MAX_KB

local i = 1
while arg[i] do
  local a = arg[i]
  if a == "--max" then
    i = i + 1
    max_kb = tonumber(arg[i]) or error("--max needs a number of KB")
  else
    files[#files + 1] = a
  end
  i = i + 1
end
if #files == 0 then files = DEFAULT_FILES end

-- Strip the --[==[badge-app ... ]==] manifest header that the shipped bundle
-- carries. It is a comment, so Lua would accept it, but the badge stores the
-- two halves separately and only compiles the code half.
local function read_code(path)
  local f = io.open(path, "r")
  if not f then return nil, path .. ": cannot open" end
  local src = f:read("a")
  f:close()
  return (src:gsub("^%-%-%[==%[.-%]==%]", ""))
end

local function measure(src)
  collectgarbage()
  collectgarbage()
  local before = collectgarbage("count")
  local chunk, err = load(src, "=main")
  if not chunk then return nil, err end
  collectgarbage()
  collectgarbage()
  local retained = collectgarbage("count") - before
  -- string.dump both ways: the difference is debug info (line numbers, local
  -- and upvalue names), which the badge also holds because it compiles from
  -- source and has no way to strip it.
  local full = #string.dump(chunk)
  local bare = #string.dump(chunk, true)
  return { retained = retained, bytecode = full, debug = full - bare }, nil
end

local failed = false

-- One file per process. Lua interns strings globally, so a second chunk
-- measured in the same state gets every literal it shares with the first one
-- for free and reads ~2 KB light. Re-exec ourselves instead of lying.
if #files > 1 then
  local lua, this = arg[-1] or "lua", arg[0]
  for _, path in ipairs(files) do
    local ok = os.execute(string.format("%s %s --max %s %s",
      lua, this, max_kb, path))
    if not ok then failed = true end
  end
  os.exit(failed and 1 or 0)
end

for _, path in ipairs(files) do
  local src, err = read_code(path)
  if not src then
    io.stderr:write(err, "\n")
    failed = true
  else
    local m, lerr = measure(src)
    if not m then
      io.stderr:write(path, ": ", lerr, "\n")
      failed = true
    else
      local over = m.retained > max_kb
      if over then failed = true end
      print(string.format(
        "%-16s source %6d B   retained %6.1f KB   bytecode %6d B (debug %d B)%s",
        path, #src, m.retained, m.bytecode, m.debug,
        over and string.format("   OVER %.0f KB", max_kb) or ""))
    end
  end
end

if failed then
  io.stderr:write(string.format(
    "mem_report: over the %.0f KB compile budget - cut code, not comments\n",
    max_kb))
  os.exit(1)
end
