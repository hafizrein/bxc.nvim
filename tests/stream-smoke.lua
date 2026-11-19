-- Stream smoke test — run against a REAL omp transcript + blob store:
--   nvim --headless --clean -l tests/stream-smoke.lua
-- Verifies the parts that make the feature real: omp's record shapes are parsed, and the
-- screenshots it received actually get drawn as colour art in the buffer.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(root)

local failures = 0
local function check(ok, label, extra)
  if not ok then
    failures = failures + 1
  end
  io.write(string.format("%s  %s%s\n", ok and "PASS" or "FAIL", label, extra and ("  — " .. tostring(extra)) or ""))
end

require("bxc").setup({
  sandbox = vim.env.BXC_SANDBOX_ID,
  home = vim.env.BXC_HOME,
  stream = { width = 100, art_cols = 44, art_rows = 11 },
})

local stream = require("bxc.stream")
local session = stream.newest_session()
check(session ~= nil, "found an omp session transcript", session)
if not session then
  os.exit(1)
end

stream.open({ session = session })
vim.wait(2500, function()
  return stream.info().items > 0
end)

local info = stream.info()
check(info.items >= 5, ("parsed %d events from the transcript"):format(info.items))
check(info.images >= 1, ("rendered %d screenshot(s) inline"):format(info.images))

local buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "bxcstream" then
    buf = b
  end
end
check(buf ~= nil, "stream buffer exists")

if buf then
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  check(#lines > 10, ("stream buffer has %d lines"):format(#lines))
  check(text:find("❯", 1, true) ~= nil, "user prompt rendered")
  check(text:find("→", 1, true) ~= nil, "tool calls rendered as arrows")
  check(text:find("←", 1, true) ~= nil, "tool results rendered")
  check(text:find("mcp__bxc", 1, true) ~= nil, "bxc tool names appear in the stream")

  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  local art_rows = 0
  for _, m in ipairs(marks) do
    if m[4] and m[4].virt_text then
      art_rows = art_rows + 1
    end
  end
  check(art_rows >= 10, ("%d inline art rows painted (screenshots)"):format(art_rows))

  io.write("\n--- first 30 lines of the stream window ---\n")
  for i = 1, math.min(30, #lines) do
    io.write(string.format("%3d| %s\n", i, lines[i]))
  end
end

stream.close()
check(not stream.info().open, "stream closed cleanly")
io.write(failures == 0 and "\nALL STREAM CHECKS PASSED\n" or ("\n" .. failures .. " STREAM CHECK(S) FAILED\n"))
os.exit(failures == 0 and 0 or 1)
