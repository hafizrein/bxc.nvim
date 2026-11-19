-- UI smoke test. Run:
--   BXC_SANDBOX_ID=sbx_... nvim --headless --clean -l tests/ui-smoke.lua
--
-- Exercises the parts that are easy to get subtly wrong and impossible to eyeball in CI:
-- the phase -> row map, the ANSI -> highlight conversion, the cell -> pixel inverse, and
-- whether a live frame actually arrives through the timer + curl + chafa pipeline.

local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/after")

local failures = 0
local function check(ok, label, extra)
  if not ok then
    failures = failures + 1
  end
  io.write(string.format("%s  %s%s\n", ok and "PASS" or "FAIL", label, extra and ("  — " .. tostring(extra)) or ""))
end

local home = vim.env.BXC_HOME or vim.fs.joinpath(vim.env.HOME, ".omp", "bxc")
local sandbox = vim.env.BXC_SANDBOX_ID

require("bxc").setup({
  home = home,
  sandbox = sandbox,
  live = { refresh_ms = 400, width = 90, height = 26 },
})

-- ── 1. events parsing ────────────────────────────────────────────────────────
local events = require("bxc.events")
local phases, err = events.read(vim.fs.joinpath(home, "events.jsonl"))
check(err == nil, "events.read opens the log", err)
check(#phases >= 3, ("events.read parsed %d phases"):format(#phases))

-- ── 2. row formatting ────────────────────────────────────────────────────────
if #phases > 0 then
  local line, group = events.row(phases[#phases], 42)
  check(#line > 5, "events.row produces a row", line)
  check(group == "BxcOk" or group == "BxcFail", "row carries a highlight group", group)
  local failed = { seq = 9, tool = "bxc_act", title = "boom", ok = false }
  local _, fgroup = events.row(failed, 42)
  check(fgroup == "BxcFail", "failed phase renders with BxcFail", fgroup)
end

-- ── 3. ANSI -> chunks (chafa gives us 256-colour SGR) ────────────────────────
local proof = require("bxc.proof")
local chunks = proof.ansi_chunks("\27[38;5;196m██\27[0m\27[38;5;46m██\27[0m")
check(#chunks == 2, ("ansi_chunks splits into %d runs"):format(#chunks), vim.inspect(chunks))
check(chunks[1][1] == "██", "chunk text preserved", chunks[1] and chunks[1][1])
check(chunks[1][2] ~= chunks[2][2], "distinct colours -> distinct groups", chunks[1][2] .. " vs " .. chunks[2][2])
local truecolor = proof.ansi_chunks("\27[38;2;10;20;30mAA\27[0m")
check(#truecolor == 1 and truecolor[1][2]:match("^BxcFg0a141e$") ~= nil, "truecolor SGR mapped to a hex group", truecolor[1] and truecolor[1][2])

-- ── 4. proof float for the newest phase ─────────────────────────────────────
if #phases > 0 then
  local withShot = nil
  for i = #phases, 1, -1 do
    if phases[i].shot then
      withShot = phases[i]
      break
    end
  end
  check(withShot ~= nil, "a phase carries a screenshot")
  if withShot then
    local abs = vim.fs.joinpath(home, withShot.shot)
    check(vim.uv.fs_stat(abs) ~= nil, "screenshot file exists", abs)
    proof.open(withShot, { home = home })
    local ok_win = proof and vim.api.nvim_list_wins()
    local floats = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        table.insert(floats, w)
      end
    end
    check(#floats >= 1, ("proof opened a floating window (%d floats)"):format(#floats))
    if #floats >= 1 then
      local buf = vim.api.nvim_win_get_buf(floats[#floats])
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      check(text:find("phase", 1, true) ~= nil, "proof window shows phase metadata")
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local art = 0
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_text then
          art = art + 1
        end
      end
      check(art > 0, ("proof window painted %d art rows"):format(art))
    end
    proof.close()
  end
end

-- ── 5. sidebar ───────────────────────────────────────────────────────────────
require("bxc.sidebar").open()
local sbuf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "bxc" then
    sbuf = b
  end
end
check(sbuf ~= nil, "sidebar buffer exists")
if sbuf then
  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  local joined = table.concat(lines, "\n")
  check(#lines > 4, ("sidebar rendered %d lines"):format(#lines))
  check(joined:find("bxc", 1, true) ~= nil, "sidebar header present")
  local hasTitle = false
  for _, p in ipairs(phases) do
    if p.title and joined:find(p.title:sub(1, 12), 1, true) then
      hasTitle = true
      break
    end
  end
  check(hasTitle, "sidebar lists phase titles from the log")
end

-- ── 6. live window: real frames ─────────────────────────────────────────────
local live = require("bxc.live")
local http = require("bxc.http")
check(http.token() ~= nil, "http.token() resolved a credential from disk")
check(http.sandbox() ~= nil, "http.sandbox() resolved", http.sandbox())

-- cell -> pixel inverse
live.open({})
local info = live.info()
check(info.open, "live window opened")
check(info.cols > 10 and info.rows > 5, ("live grid %dx%d cells"):format(info.cols, info.rows))
local x0, y0 = live.cell_to_px(0, 0)
local xm, ym = live.cell_to_px(info.rows - 1, info.cols - 1)
check(x0 < xm and y0 < ym, ("cell->px is monotonic: (%d,%d) .. (%d,%d)"):format(x0, y0, xm, ym))
check(xm < 1280 and ym < 800, "cell->px stays inside the 1280x800 screen")

local got = vim.wait(12000, function()
  return (live.info().frames or 0) > 0
end, 200)
local afterInfo = live.info()
check(got and afterInfo.frames > 0, ("live pulled %d frame(s)"):format(afterInfo.frames or 0), afterInfo.error)

if afterInfo.frames > 0 then
  local lbuf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "bxclive" then
      lbuf = b
    end
  end
  check(lbuf ~= nil, "live buffer exists")
  if lbuf then
    local marks = vim.api.nvim_buf_get_extmarks(lbuf, -1, 0, -1, { details = true })
    local art = 0
    for _, m in ipairs(marks) do
      if m[4] and m[4].virt_text then
        art = art + 1
      end
    end
    check(art > 0, ("live window painted %d art rows"):format(art))
  end
end
live.close()
check(not live.info().open, "live window closed cleanly")

io.write(failures == 0 and "\nALL UI CHECKS PASSED\n" or ("\n" .. failures .. " UI CHECK(S) FAILED\n"))
os.exit(failures == 0 and 0 or 1)
