-- bxc.live — the VM's desktop, as a window inside Neovim.
--
-- There is no graphics protocol to rely on here, so the window is a character grid: each
-- cell is a colour block, and the grid is mapped back onto the VM's 1280x800 screen. That
-- makes the window *addressable* — the cursor becomes a pointer, which is what turns a
-- viewer into something you can drive, the way omp.nvim's pane is something you can type
-- into.
--
-- Pipeline per frame: GET /desktop/screenshot -> png -> chafa -> ANSI -> virt_text chunks.
-- Everything except the PNG fetch is local and cheap.
local M = {}

local config = require("bxc.config")
local proof = require("bxc.proof")
local http = require("bxc.http")

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("bxc.live")

local SCREEN_W, SCREEN_H = 1280, 800

local state = {
  win = nil,
  buf = nil,
  timer = nil,
  in_flight = false,
  cols = 0,
  rows = 0,
  frame = nil,
  last_error = nil,
  frames = 0,
  started = nil,
}

local function hl()
  vim.api.nvim_set_hl(0, "BxcLiveArt", { fg = "#d5c4a1", default = true })
  vim.api.nvim_set_hl(0, "BxcLiveHeader", { fg = "#8ec07c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "BxcLiveFoot", { fg = "#928374", default = true })
  vim.api.nvim_set_hl(0, "BxcLiveErr", { fg = "#fb4934", default = true })
end

local function art_rows() return state.rows end
local ART_START = 1 -- row 0 is the header, art occupies 1..rows, footer after

--- Cell -> screen pixel, the inverse of how chafa laid the image out.
function M.cell_to_px(row, col)
  local rows = math.max(state.rows, 1)
  local cols = math.max(state.cols, 1)
  local x = math.floor((col + 0.5) * SCREEN_W / cols)
  local y = math.floor((row + 0.5) * SCREEN_H / rows)
  return math.min(math.max(x, 0), SCREEN_W - 1), math.min(math.max(y, 0), SCREEN_H - 1)
end

local function set_header()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local sandbox = http.sandbox() or "no sandbox"
  local elapsed = state.started and (os.time() - state.started) or 0
  local text = string.format(
    " %s · %.1f fps · %d frames · %ds%s",
    sandbox,
    1000 / math.max(config.options.live.refresh_ms, 1),
    state.frames,
    elapsed,
    state.last_error and ("  ⚠ " .. state.last_error) or ""
  )
  vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { text })
  vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, {
    end_col = #text,
    hl_group = state.last_error and "BxcLiveErr" or "BxcLiveHeader",
  })
end

local function set_footer()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local row = ART_START + state.rows
  local text = " <CR> click · m move · t type · K key · u/d scroll · R refresh · q close"
  vim.api.nvim_buf_set_lines(state.buf, row, row + 1, false, { text })
  vim.api.nvim_buf_set_extmark(state.buf, ns, row, 0, { end_col = #text, hl_group = "BxcLiveFoot" })
end

local function paint(chunks_rows)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  for idx, chunks in ipairs(chunks_rows) do
    local row = ART_START + idx - 1
    if row < ART_START + state.rows then
      vim.api.nvim_buf_set_extmark(state.buf, ns, row, 0, {
        virt_text = chunks,
        virt_text_pos = "overlay",
        hl_mode = "combine",
        priority = 10,
      })
    end
  end
end

--- One frame: fetch the screenshot, convert to colour blocks, paint.
function M.tick()
  if state.in_flight or not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  if vim.fn.executable("chafa") ~= 1 then
    state.last_error = "chafa missing"
    set_header()
    return
  end
  if not http.sandbox() or not http.token() then
    state.last_error = "no sandbox/token"
    set_header()
    return
  end
  state.in_flight = true

  local png = vim.fs.joinpath(vim.fn.stdpath("cache") or vim.fn.tempname(), "bxc-live-frame.png")
  vim.fn.mkdir(vim.fn.fnamemodify(png, ":h"), "p")

  vim.system({
    "curl", "-sS", "--max-time", "10",
    "-H", "Authorization: Bearer " .. http.token(),
    "-H", "Accept: image/png",
    "-o", png,
    http.api() .. "/sandboxes/" .. http.sandbox() .. "/desktop/screenshot",
  }, { text = true }, function(res)
    vim.schedule(function()
      state.in_flight = false
      if res.code ~= 0 then
        state.last_error = (res.stderr or "fetch failed"):gsub("%s+$", ""):sub(1, 60)
        set_header()
        return
      end
      local rows = proof.chafa_rows(png, state.cols, state.rows)
      if not rows then
        state.last_error = "chafa decode failed"
        set_header()
        return
      end
      state.last_error = nil
      state.frames = state.frames + 1
      state.frame = png
      paint(rows)
      set_header()
    end)
  end)
end

local function start_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  local t = uv.new_timer()
  local ms = math.max(config.options.live.refresh_ms, 150)
  t:start(ms, ms, vim.schedule_wrap(function() M.tick() end))
  state.timer = t
end

local function cursor_cell()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  local pos = vim.api.nvim_win_get_cursor(state.win) -- 1-based row
  local row = pos[1] - 1 - ART_START
  local col = pos[2]
  if row < 0 or row >= state.rows then
    return nil
  end
  return row, col
end

local function act(action, opts)
  local res, err = http.action(action, opts)
  if not res then
    state.last_error = tostring(err):sub(1, 60)
    set_header()
    return nil
  end
  state.last_error = nil
  vim.defer_fn(function() M.tick() end, 120)
  return res
end

local function keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "bxc live: " .. desc })
  end

  map("<CR>", function()
    local row, col = cursor_cell()
    if not row then
      return
    end
    local x, y = M.cell_to_px(row, col)
    act({ type = "click", x = x, y = y, button = "left", clicks = 1 }, { screenshot = true })
  end, "click at cursor")

  map("m", function()
    local row, col = cursor_cell()
    if not row then
      return
    end
    local x, y = M.cell_to_px(row, col)
    act({ type = "move", x = x, y = y }, { screenshot = true })
  end, "move pointer to cursor")

  map("t", function()
    vim.ui.input({ prompt = "type into VM: " }, function(input)
      if input and input ~= "" then
        act({ type = "type", text = input }, { screenshot = true })
      end
    end)
  end, "type text")

  map("K", function()
    vim.ui.input({ prompt = "key (Return/Tab/Escape/Up/Down/...) : " }, function(input)
      if input and input ~= "" then
        act({ type = "key", key = input }, { screenshot = true })
      end
    end)
  end, "send key")

  map("u", function()
    local row, col = cursor_cell()
    if not row then
      return
    end
    local x, y = M.cell_to_px(row, col)
    act({ type = "scroll", direction = "up", amount = 3, x = x, y = y }, { screenshot = true })
  end, "scroll up")

  map("d", function()
    local row, col = cursor_cell()
    if not row then
      return
    end
    local x, y = M.cell_to_px(row, col)
    act({ type = "scroll", direction = "down", amount = 3, x = x, y = y }, { screenshot = true })
  end, "scroll down")

  map("R", function() M.tick() end, "refresh now")
  map("q", function() M.close() end, "close")
end

--- Open the live window. opts.split = true puts it in a vertical split instead of a float.
function M.open(opts)
  opts = opts or {}
  hl()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return state.win
  end
  if not http.sandbox() then
    vim.notify("bxc: no sandbox configured — bxc.setup{ sandbox = 'sbx_...' }", vim.log.levels.ERROR)
    return nil
  end

  local cfg = config.options.live
  local width = math.min(cfg.width or 118, vim.o.columns - 4)
  local height = math.min(cfg.height or 40, vim.o.lines - 6)
  state.cols = width - 2
  state.rows = height - 3

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "bxclive"

  -- Fixed grid: header + art + footer. Lines exist so extmarks have somewhere to sit.
  local lines = {}
  for _ = 1, height do
    table.insert(lines, "")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win
  if opts.split then
    vim.cmd("botright " .. (width + 2) .. "vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  else
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
      col = math.max(math.floor((vim.o.columns - width) / 2), 0),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " bxc · live VM ",
      title_pos = "center",
    })
  end
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = true
  vim.wo[win].winhl = "Normal:BxcProofNormal,CursorLine:PmenuSel"

  state.win, state.buf = win, buf
  state.started = os.time()
  state.frames = 0

  keymaps(buf)
  set_header()
  set_footer()
  vim.api.nvim_win_set_cursor(win, { ART_START + math.floor(state.rows / 2), math.floor(state.cols / 2) })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
      end
      state.win, state.buf = nil, nil
    end,
  })

  M.tick()
  start_timer()
  return win
end

function M.close()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf = nil, nil
end

--- Test/inspection hook.
function M.info()
  return {
    open = state.win ~= nil,
    cols = state.cols,
    rows = state.rows,
    frames = state.frames,
    error = state.last_error,
    frame_file = state.frame,
    art_rows = art_rows(),
  }
end

return M
