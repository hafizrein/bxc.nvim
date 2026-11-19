-- bxc.events — the phase log reader.
--
-- bxc-mcp appends one JSON object per line to $BXC_HOME/events.jsonl. This module is the
-- only thing that knows that file's shape, so the sidebar and the proof viewer stay dumb.
local M = {}

local uv = vim.uv or vim.loop

--- Parse the log, tolerating a half-written last line (a write is not atomic).
--- @param path string
--- @return table[] phases, string? error
function M.read(path)
  local fh, err = io.open(path, "r")
  if not fh then
    return {}, err
  end
  local phases = {}
  for line in fh:lines() do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      local ok, decoded = pcall(vim.json.decode, trimmed)
      if ok and type(decoded) == "table" then
        table.insert(phases, decoded)
      end
    end
  end
  fh:close()
  return phases, nil
end

--- Watch the log for appends. Directory events only: an fs_event on the file itself is
--- dropped by editors and by atomic replaces, so watch the parent and filter by name.
--- @param path string
--- @param on_change fun()
--- @return table handle  { stop = fun() }
function M.watch(path, on_change)
  local dir = vim.fn.fnamemodify(path, ":h")
  local name = vim.fn.fnamemodify(path, ":t")
  vim.fn.mkdir(dir, "p")

  local handle = { stop = function() end, timer = nil, fs = nil }
  local debounce = nil

  local function fire()
    -- Two events usually arrive per append (write + attr); collapse them.
    if debounce then
      return
    end
    debounce = uv.new_timer()
    debounce:start(
      60,
      0,
      vim.schedule_wrap(function()
        if debounce then
          debounce:stop()
          debounce:close()
          debounce = nil
        end
        pcall(on_change)
      end)
    )
  end

  local fs = uv.new_fs_event()
  if fs then
    local ok = pcall(function()
      fs:start(dir, {}, vim.schedule_wrap(function(err, filename)
        if err then
          return
        end
        if filename == nil or filename == name or filename == "" then
          fire()
        end
      end))
    end)
    if ok then
      handle.fs = fs
    end
  end

  -- Timer as well as fs_event: a mounted/network path or a watcher limit would otherwise
  -- leave the panel permanently stale, which is worse than a 1 s poll.
  local timer = uv.new_timer()
  timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      local stat = uv.fs_stat(path)
      if stat and stat.mtime and stat.mtime.sec then
        local stamp = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec)
        if handle._stamp and handle._stamp ~= stamp then
          fire()
        end
        handle._stamp = stamp
      end
    end)
  )
  handle.timer = timer

  handle.stop = function()
    if handle.fs then
      pcall(function()
        handle.fs:stop()
        handle.fs:close()
      end)
      handle.fs = nil
    end
    if handle.timer then
      pcall(function()
        handle.timer:stop()
        handle.timer:close()
      end)
      handle.timer = nil
    end
  end
  return handle
end

--- Icons per tool, deliberately few: they are a glance aid, not decoration.
M.icons = {
  bxc_act = "◆",
  bxc_shot = "▣",
  bxc_exec = "⌘",
  bxc_desktop_start = "▶",
  bxc_viewer = "◉",
  bxc_phases = "≡",
}

--- One sidebar row per phase.
--- @param phase table
--- @param width integer available text width
--- @return string line, string hl
function M.row(phase, width)
  local icon = M.icons[phase.tool] or "·"
  local mark = phase.ok == false and "✗" or "✓"
  local hl = phase.ok == false and "BxcFail" or "BxcOk"
  local seq = string.format("%3d", tonumber(phase.seq) or 0)
  local title = tostring(phase.title or phase.tool or "?")
  local detail = tostring(phase.detail or "")
  local ms = tonumber(phase.ms)
  local timing = ms and (ms >= 1000 and string.format("%.1fs", ms / 1000) or (ms .. "ms")) or ""
  local shot = phase.shot and "▸" or " "

  local head = string.format(" %s %s %s  ", seq, mark, icon)
  local tail = string.format("%s %s %s", shot, timing, detail)
  local room = width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(tail) - 1
  if room < 8 then
    room = 8
  end
  if vim.fn.strdisplaywidth(title) > room then
    title = vim.fn.strcharpart(title, 0, room - 1) .. "…"
  end
  local pad = room - vim.fn.strdisplaywidth(title)
  return head .. title .. string.rep(" ", math.max(pad, 1)) .. tail, hl
end

--- "3s ago" style age for the header line.
function M.age(iso)
  if not iso then
    return "never"
  end
  local secs = os.time() - (vim.fn.strptime("%Y-%m-%dT%H:%M:%S", (iso:gsub("%..*$", ""))) or os.time())
  if secs < 0 then
    secs = 0
  end
  if secs < 60 then
    return secs .. "s ago"
  elseif secs < 3600 then
    return math.floor(secs / 60) .. "m ago"
  end
  return math.floor(secs / 3600) .. "h ago"
end

return M
