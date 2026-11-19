-- bxc.sidebar — the activity panel: one row per phase, click for the proof.
local M = {}

local config = require("bxc.config")
local events = require("bxc.events")
local proof = require("bxc.proof")

local ns = vim.api.nvim_create_namespace("bxc.sidebar")

-- Per-buffer render state, keyed by bufnr: a second :Bxc after :q must not resurrect a dead
-- window, and the line->phase map must never drift from the buffer it describes.
local views = {}

local function opts()
  return config.options
end

local function hl()
  vim.api.nvim_set_hl(0, "BxcHeader", { fg = "#8ec07c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "BxcDim", { fg = "#928374", default = true })
  vim.api.nvim_set_hl(0, "BxcOk", { fg = "#b8bb26", default = true })
  vim.api.nvim_set_hl(0, "BxcFail", { fg = "#fb4934", bold = true, default = true })
  vim.api.nvim_set_hl(0, "BxcProofNormal", { bg = "#1d2021", default = true })
  vim.api.nvim_set_hl(0, "BxcProofMeta", { fg = "#a89984", default = true })
  vim.api.nvim_set_hl(0, "BxcProofArt", { fg = "#d5c4a1", default = true })
end

--- Latest phase carrying a viewer URL, for `:BxcLive`.
function M.latest_viewer(phases)
  for i = #phases, 1, -1 do
    local url = phases[i].url
    if url and url ~= "" then
      return url
    end
  end
  return nil
end

local function render(view)
  local buf = view.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local phases, err = events.read(config.events_file())
  if #phases > opts().max_phases then
    phases = vim.list_slice(phases, #phases - opts().max_phases + 1, #phases)
  end
  view.phases = phases

  local width = opts().width
  local lines, map, marks = {}, {}, {}

  -- push() is the only writer, so a highlight can never point at a row that moved.
  local function push(text, group)
    table.insert(lines, text)
    if group then
      marks[#marks + 1] = { row = #lines - 1, group = group }
    end
  end

  local rule = string.rep("─", math.max(width, 8))
  push(" bxc", "BxcHeader")
  local sandbox = opts().sandbox or (phases[#phases] and phases[#phases].sandbox) or "sandbox not set"
  push(" " .. sandbox, "BxcDim")

  if err then
    push(" waiting for " .. vim.fn.fnamemodify(config.events_file(), ":~:."), "BxcDim")
  elseif #phases == 0 then
    push(" no phases yet", "BxcDim")
    push(" ask the agent to use a bxc_* tool", "BxcDim")
  else
    local last = phases[#phases]
    local state = last.ok == false and "last phase FAILED" or "live"
    push(string.format(" %d phases · %s · %s", #phases, state, events.age(last.ts)),
      last.ok == false and "BxcFail" or "BxcOk")
  end
  push(string.format(" follow %s", opts().follow and "on" or "off"), "BxcDim")
  push(rule, "BxcDim")

  for _, phase in ipairs(phases) do
    local line, group = events.row(phase, width)
    push(line, group)
    map[#lines] = phase
  end

  push(rule, "BxcDim")
  local keys = opts().keys
  push(string.format(" %s proof · %s live · %s follow", keys.proof, keys.live, keys.follow), "BxcDim")

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    local text = lines[mark.row + 1] or ""
    vim.api.nvim_buf_set_extmark(buf, ns, mark.row, 0, {
      end_col = #text,
      hl_group = mark.group,
    })
  end
  view.map = map

  local win = vim.fn.bufwinid(buf)
  if win ~= -1 and opts().follow and #phases > 0 then
    -- Sit on the last phase row, not on the footer.
    vim.api.nvim_win_set_cursor(win, { #lines - 2, 0 })
  end
end

local function phase_at_cursor(view)
  local win = vim.fn.bufwinid(view.buf)
  if win == -1 then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return view.map[row]
end

function M.refresh()
  local view = views[vim.api.nvim_get_current_buf()]
  if view then
    render(view)
  end
end

--- Open (or focus) the sidebar.
function M.open()
  hl()
  local existing
  for buf in pairs(views) do
    if vim.api.nvim_buf_is_valid(buf) then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        existing = win
      end
    else
      views[buf] = nil
    end
  end
  if existing then
    vim.api.nvim_set_current_win(existing)
    return existing
  end

  vim.cmd("botright " .. opts().width .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "bxc"

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true

  local view = { buf = buf, win = win, map = {}, phases = {} }
  views[buf] = view

  local keys = opts().keys
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "bxc: " .. desc })
  end
  map(keys.proof, function()
    local phase = phase_at_cursor(view)
    if phase then
      proof.open(phase, { home = config.home() })
    else
      vim.notify("bxc: no phase on this line", vim.log.levels.WARN)
    end
  end, "show proof")
  map(keys.live, function()
    local url = M.latest_viewer(view.phases or {})
    if url then
      vim.ui.open(url)
    else
      vim.notify("bxc: no viewer url yet — the agent must call bxc_viewer", vim.log.levels.WARN)
    end
  end, "open live desktop viewer")
  map(keys.follow, function()
    opts().follow = not opts().follow
    render(view)
    vim.notify("bxc: follow " .. (opts().follow and "on" or "off"), vim.log.levels.INFO)
  end, "toggle follow")
  map(keys.refresh, function()
    render(view)
  end, "refresh")
  map(keys.clear, function()
    local fh = io.open(config.events_file(), "w")
    if fh then
      fh:close()
    end
    render(view)
    vim.notify("bxc: cleared phase log", vim.log.levels.INFO)
  end, "clear phase log")
  map(keys.close, function()
    vim.api.nvim_win_close(win, true)
  end, "close sidebar")

  render(view)

  view.watcher = events.watch(config.events_file(), function()
    if not vim.api.nvim_buf_is_valid(buf) then
      if view.watcher then
        view.watcher.stop()
      end
      views[buf] = nil
      return
    end
    render(view)
  end)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if view.watcher then
        view.watcher.stop()
      end
      views[buf] = nil
    end,
  })

  return win
end

function M.toggle()
  for buf in pairs(views) do
    if vim.api.nvim_buf_is_valid(buf) then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        vim.api.nvim_win_close(win, true)
        return
      end
    end
  end
  M.open()
end

--- Show the proof for the newest phase without opening the sidebar.
function M.proof_latest()
  local phases = events.read(config.events_file())
  if #phases == 0 then
    vim.notify("bxc: no phases recorded", vim.log.levels.WARN)
    return
  end
  proof.open(phases[#phases], { home = config.home() })
end

--- Test hook: render a buffer with given phases without touching disk.
function M._render_for_test(view)
  render(view)
end

return M
