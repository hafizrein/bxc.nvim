-- bxc.proof — show a phase's screenshot inside the editor.
--
-- Neovim does not interpret ANSI escapes in buffer text, so "just shell out to chafa" gives
-- you ^[[38;5;… garbage. This module parses chafa's SGR output and re-emits it as
-- virt_text chunks with per-colour highlight groups, which renders as real colour blocks in
-- any terminal — no graphics protocol needed. Terminals that *do* have one (kitty/wezterm via
-- snacks.image or image.nvim) are used first when available.
local M = {}

local config = require("bxc.config")

-- ── ANSI 256 → #rrggbb ───────────────────────────────────────────────────────

local BASIC = {
  [0] = "#000000", [1] = "#cd0000", [2] = "#00cd00", [3] = "#cdcd00",
  [4] = "#0000ee", [5] = "#cd00cd", [6] = "#00cdcd", [7] = "#e5e5e5",
  [8] = "#7f7f7f", [9] = "#ff0000", [10] = "#00ff00", [11] = "#ffff00",
  [12] = "#5c5cff", [13] = "#ff00ff", [14] = "#00ffff", [15] = "#ffffff",
}

local function ansi_to_hex(n)
  n = tonumber(n)
  if not n then
    return nil
  end
  if BASIC[n] then
    return BASIC[n]
  end
  if n >= 16 and n <= 231 then
    local i = n - 16
    local steps = { 0, 95, 135, 175, 215, 255 }
    local r = steps[math.floor(i / 36) + 1]
    local g = steps[math.floor((i % 36) / 6) + 1]
    local b = steps[(i % 6) + 1]
    return string.format("#%02x%02x%02x", r, g, b)
  end
  if n >= 232 and n <= 255 then
    local v = 8 + (n - 232) * 10
    return string.format("#%02x%02x%02x", v, v, v)
  end
  return nil
end

local group_cache = {}

local function color_group(hex)
  local name = "BxcFg" .. hex:gsub("#", "")
  if not group_cache[name] then
    vim.api.nvim_set_hl(0, name, { fg = hex })
    group_cache[name] = true
  end
  return name
end

--- Turn one line of ANSI into virt_text chunks: { {text, group}, ... }
--- Understands \e[38;5;Nm, \e[38;2;r;g;bm, \e[39m and \e[0m; anything else is dropped
--- from the escape and its text kept, so a format change degrades to plain art.
function M.ansi_chunks(line)
  local chunks = {}
  local group = "BxcProofArt"
  local buffer = {}
  local i = 1

  local function flush()
    if #buffer > 0 then
      table.insert(chunks, { table.concat(buffer), group })
      buffer = {}
    end
  end

  while i <= #line do
    local sgr = line:find("\27%[([%d;]*)m", i)
    if not sgr then
      local rest = line:sub(i)
      -- chafa separates cells with a space; keep it, it is part of the art.
      if rest ~= "" then
        table.insert(buffer, rest)
      end
      break
    end
    local before = line:sub(i, sgr - 1)
    if before ~= "" then
      table.insert(buffer, before)
    end
    local params = line:match("\27%[([%d;]*)m", sgr)
    local parts = {}
    for p in (params or ""):gmatch("[^;]+") do
      table.insert(parts, tonumber(p))
    end
    local handled = false
    if parts[1] == 38 and parts[2] == 5 and parts[3] then
      local hex = ansi_to_hex(parts[3])
      if hex then
        flush()
        group = color_group(hex)
        handled = true
      end
    elseif parts[1] == 38 and parts[2] == 2 and parts[3] and parts[4] and parts[5] then
      flush()
      group = color_group(string.format("#%02x%02x%02x", parts[3], parts[4], parts[5]))
      handled = true
    elseif parts[1] == 0 or parts[1] == 39 or (params == "") then
      flush()
      group = "BxcProofArt"
      handled = true
    end
    if not handled then
      -- Unrelated SGR (bold/background/etc): drop the escape, keep the text.
    end
    i = sgr + (line:match("\27%[[%d;]*m", sgr) or ""):len()
  end
  flush()
  return chunks
end

-- ── renderers ───────────────────────────────────────────────────────────────

local function has(bin)
  return vim.fn.executable(bin) == 1
end

local function term_has_graphics()
  local prog = (vim.env.TERM_PROGRAM or ""):lower()
  return prog:find("kitty") or prog:find("wezterm") or prog:find("ghostty") or vim.env.KITTY_WINDOW_ID ~= nil
end

--- Preferred renderer for this machine, in priority order.
function M.pick_renderer()
  local order = config.options.render.chain or {}
  local available = {
    snacks = function()
      if not term_has_graphics() then
        return false
      end
      local ok = pcall(require, "snacks.image")
      return ok
    end,
    image_nvim = function()
      local ok = pcall(require, "image")
      return ok
    end,
    chafa = function()
      return has("chafa")
    end,
    external = function()
      return true
    end,
  }
  for _, name in ipairs(order) do
    local check = available[name]
    if check and check() then
      return name
    end
  end
  return "external"
end

--- chafa → ANSI → virt_text chunks. Returns a list of chunk-lists, one per row.
function M.chafa_rows(path, cols, rows)
  if not has("chafa") then
    return nil
  end
  local res = vim.system({
    "chafa",
    "--format", "symbols",
    "--symbols", "block", -- block glyphs, not the default symbol alphabet: at 40-55
    -- columns the symbol alphabet reads as noise, blocks read as a picture
    "--colors", "256",
    "--size", string.format("%dx%d", cols, rows),
    "--stretch",
    path,
  }, { text = true }):wait()
  if res.code ~= 0 or not res.stdout or res.stdout == "" then
    return nil
  end
  local out = {}
  for line in res.stdout:gmatch("[^\n]*") do
    if line ~= "" then
      table.insert(out, M.ansi_chunks(line))
    end
  end
  return out
end

-- ── the float ───────────────────────────────────────────────────────────────

local state = { win = nil, buf = nil }

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf = nil, nil
end

local function metadata(phase)
  local pointer = phase.pointer and string.format("pointer %s,%s", phase.pointer.x, phase.pointer.y) or ""
  local ms = tonumber(phase.ms)
  local timing = ms and (ms >= 1000 and string.format("%.1fs", ms / 1000) or (ms .. "ms")) or ""
  return {
    string.format("phase %s · %s · %s", tostring(phase.seq or "?"), tostring(phase.tool or "?"), tostring(phase.title or "")),
    table.concat(vim.tbl_filter(function(s)
      return s ~= ""
    end, { timing, pointer, tostring(phase.detail or "") }), "  ·  "),
    tostring(phase.shot or "(no screenshot for this phase)"),
  }
end

--- Open (or reuse) the proof float for one phase.
--- @param phase table
--- @param ctx? table { home = string }
function M.open(phase, ctx)
  if not phase then
    return
  end
  ctx = ctx or {}
  local home = ctx.home or config.home()
  local shot_abs = phase.shot and vim.fs.joinpath(home, phase.shot) or nil

  M.close()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "bxcproof"

  local meta = metadata(phase)
  local lines = { meta[1], meta[2], meta[3], "" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace("bxc.proof.meta"), 0, 0, {
    end_row = 2,
    hl_group = "BxcProofMeta",
  })

  local renderer = M.pick_renderer()
  local art_rows, art_start = nil, 4
  local have_shot = shot_abs and vim.uv.fs_stat(shot_abs) ~= nil

  if have_shot and renderer == "chafa" then
    local cols = math.min(math.max(vim.o.columns - 12, 40), 110)
    local rows = math.min(math.max(vim.o.lines - 14, 12), 34)
    art_rows = M.chafa_rows(shot_abs, cols, rows)
  end

  local width = math.max(vim.fn.strdisplaywidth(meta[1]) + 4, 56)
  local height = 3

  if art_rows then
    -- Reserve the rows first so the float can be sized before the chunks land.
    local blank = {}
    for _ = 1, #art_rows do
      table.insert(blank, "")
    end
    vim.api.nvim_buf_set_lines(buf, art_start, -1, false, blank)
    local ns = vim.api.nvim_create_namespace("bxc.proof.art")
    for idx, chunks in ipairs(art_rows) do
      local row = art_start + idx - 1
      local text_width = 0
      for _, chunk in ipairs(chunks) do
        text_width = text_width + vim.fn.strdisplaywidth(chunk[1])
      end
      width = math.max(width, text_width + 2)
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_text = chunks,
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
    end
    height = art_start + #art_rows
  elseif have_shot and renderer ~= "external" then
    -- A graphics-protocol terminal: let the image plugin draw it.
    local ok = pcall(function()
      local img = require("image")
      img.from_file(shot_abs, { window = 0, buffer = buf, with_virtual_padding = true })
    end)
    if not ok then
      table.insert(lines, "(renderer '" .. renderer .. "' failed to load the image)")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      height = #lines
    else
      height = art_start + 20
    end
  elseif not have_shot then
    table.insert(lines, phase.ok == false and "no screenshot: this phase failed before capture" or "no screenshot recorded")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    height = #lines
  end

  width = math.min(width, vim.o.columns - 6)
  height = math.min(height, vim.o.lines - 6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " bxc proof ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].cursorline = false
  vim.wo[win].winhl = "Normal:BxcProofNormal"

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("q", M.close, "close proof")
  map("<Esc>", M.close, "close proof")
  map("o", function()
    if shot_abs and vim.uv.fs_stat(shot_abs) then
      vim.ui.open(shot_abs)
    else
      vim.notify("bxc: no screenshot file for this phase", vim.log.levels.WARN)
    end
  end, "open screenshot externally")
  map("y", function()
    if shot_abs then
      vim.fn.setreg("+", shot_abs)
      vim.notify("bxc: copied " .. shot_abs, vim.log.levels.INFO)
    end
  end, "yank screenshot path")

  state.win, state.buf = win, buf
  return win
end

return M
