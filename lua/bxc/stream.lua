-- bxc.stream — omp's live session, as a window: what it is doing, as it does it,
-- with the screenshots it receives rendered inline in the output.
--
-- Source of truth is omp's own session transcript (`~/.omp/agent/sessions/<project>/<ts>.jsonl`),
-- which it appends to while the agent works. That choice matters: it works whether omp runs in
-- omp.nvim's pane, in a tmux split, or one-shot, because the transcript is written by omp
-- itself. No hooks, no wrappers, nothing to install on the agent side.
--
-- Record shapes seen in a live transcript (29 records, omp 18.22.2):
--   {type="message", message={role="user",       content=[{type="text", text=…}]}}
--   {type="message", message={role="assistant",  content=[{type="thinking"},{type="toolCall",
--        name="write", arguments={path="xd://mcp__bxc_act", content="{\"action\":…}", i="Typing pwd"},
--        intent="Typing pwd into terminal"}]}}
--   {type="message", message={role="toolResult", content=[{type="text", text="{\"ok\":true,…}"},
--        {type="image", data="blob:sha256:<hash>", mimeType="image/png"}]}}
-- Images are blob references: <agentDir>/blobs/<hash>.png.
local M = {}

local config = require("bxc.config")
local proof = require("bxc.proof")

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("bxc.stream")

local state = {
  buf = nil,
  win = nil,
  timer = nil,
  offset = 0,
  session = nil,
  pending = "",
  items = 0,
  images = 0,
  blobs = nil,
}

local function hl()
  -- Link to the standard groups so the pane inherits the user's colorscheme instead of
  -- shipping a palette that clashes with LazyVim (it will pick up whatever theme is live).
  local function link(from, to)
    vim.api.nvim_set_hl(0, from, { link = to, default = true })
  end
  link("BxcStreamHead", "Title")
  link("BxcStreamUser", "Special")
  link("BxcStreamAgent", "Normal")
  link("BxcStreamTool", "Function")
  link("BxcStreamResult", "String")
  link("BxcStreamErr", "DiagnosticError")
  link("BxcStreamDim", "Comment")
  link("BxcStreamArt", "Normal")
end

-- ── locating + tailing the transcript ───────────────────────────────────────

local function omp_agent_dir()
  -- The transcript lives beside agent.db, which is also where blobs/ sits.
  local candidates = {
    vim.fs.joinpath(vim.fn.expand("~"), ".omp", "agent"),
    vim.fs.joinpath(vim.env.BXC_AGENT_DIR or "", ""),
  }
  for _, dir in ipairs(candidates) do
    if dir ~= "" and uv.fs_stat(vim.fs.joinpath(dir, "sessions")) then
      return dir
    end
  end
  local s = config.options.stream and config.options.stream.sessions_dir
  if s then
    return vim.fn.fnamemodify(s, ":h")
  end
  return vim.fs.joinpath(vim.fn.expand("~"), ".omp", "agent")
end

local function sessions_root()
  local cfg = config.options.stream or {}
  if cfg.sessions_dir then
    return cfg.sessions_dir
  end
  return vim.fs.joinpath(omp_agent_dir(), "sessions")
end

--- Newest transcript across all project dirs, preferring the agent's current project.
function M.newest_session()
  local root = sessions_root()
  local best, best_mtime = nil, 0
  local function scan(dir)
    local scan_handle = uv.fs_scandir(dir)
    if not scan_handle then
      return
    end
    while true do
      local name, kind = uv.fs_scandir_next(scan_handle)
      if not name then
        break
      end
      local path = vim.fs.joinpath(dir, name)
      if kind == "directory" then
        scan(path)
      elseif name:match("%.jsonl$") then
        local stat = uv.fs_stat(path)
        if stat and (stat.mtime.sec or 0) >= best_mtime then
          best, best_mtime = path, stat.mtime.sec or 0
        end
      end
    end
  end
  scan(root)
  return best
end

local function blob_path(ref)
  if type(ref) ~= "string" then
    return nil
  end
  local hash = ref:match("blob:sha256:(%x+)")
  if not hash then
    return nil
  end
  local dir = vim.fs.joinpath(omp_agent_dir(), "blobs")
  for _, candidate in ipairs({ hash .. ".png", hash }) do
    local path = vim.fs.joinpath(dir, candidate)
    if uv.fs_stat(path) then
      return path
    end
  end
  return nil
end

--- The bxc tools hand back the screenshot path in their JSON; prefer it over the blob,
--- because it is the exact file the phase log refers to.
local function shot_from_text(text)
  if type(text) ~= "string" then
    return nil
  end
  local path = text:match('"shot"%s*:%s*"([^"]+)"')
  if path and uv.fs_stat(path) then
    return path
  end
  return nil
end

-- ── rendering ───────────────────────────────────────────────────────────────

local function append(lines, groups)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local start = vim.api.nvim_buf_line_count(state.buf)
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, start, -1, false, lines)
  for i, group in ipairs(groups) do
    if group then
      vim.api.nvim_buf_set_extmark(state.buf, ns, start + i - 1, 0, {
        end_col = #lines[i],
        hl_group = group,
      })
    end
  end
  state.items = state.items + 1
end

local function append_art(path, label)
  local cfg = config.options.stream or {}
  local cols = cfg.art_cols or 54
  local rows = cfg.art_rows or 13

  if label and label ~= "" then
    append({ "   ⤷ " .. label }, { "BxcStreamDim" })
  end

  -- A terminal with the kitty graphics protocol (ghostty, kitty, wezterm) gets the real
  -- PNG drawn in the buffer; everything else falls back to chafa colour blocks, which is
  -- what Windows Terminal needs.
  local snacks_ok, snacks = pcall(require, "snacks.image")
  if snacks_ok and snacks.supports and snacks.supports(path) then
    local placement_ok, placement = pcall(require, "snacks.image.placement")
    if placement_ok and placement and placement.new then
      local first = vim.api.nvim_buf_line_count(state.buf)
      local blanks = {}
      for _ = 1, rows do
        table.insert(blanks, "")
      end
      vim.bo[state.buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.buf, first, -1, false, blanks)
      local placed = pcall(placement.new, state.buf, path, {
        pos = { first + 1, 2 },
        width = cols,
        height = rows,
      })
      if placed then
        state.images = state.images + 1
        return
      end
      -- fall through to chafa if the placement failed for any reason
    end
  end

  local chunks = proof.chafa_rows(path, cols, rows)
  if not chunks then
    append({ "   (image: " .. vim.fn.fnamemodify(path, ":t") .. ")" }, { "BxcStreamDim" })
    return
  end
  state.images = state.images + 1
  local first = vim.api.nvim_buf_line_count(state.buf)
  local blanks = {}
  for _ = 1, #chunks do
    table.insert(blanks, "")
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, first, -1, false, blanks)
  for idx, chunk in ipairs(chunks) do
    vim.api.nvim_buf_set_extmark(state.buf, ns, first + idx - 1, 0, {
      virt_text = chunk,
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 20,
    })
  end
end

local function summarize_call(name, args)
  local path = args.path or ""
  local target = path:gsub("^xd://", "")
  local intent = args.i or args.intent
  local detail = ""
  if args.content and args.content ~= "" then
    local ok, decoded = pcall(vim.json.decode, args.content)
    if ok and type(decoded) == "table" then
      if decoded.action and decoded.action.type then
        local a = decoded.action
        if a.type == "type" then
          detail = string.format("type %q", tostring(a.text))
        elseif a.type == "click" then
          detail = string.format("click (%s,%s)", tostring(a.x), tostring(a.y))
        elseif a.type == "key" then
          detail = "key " .. tostring(a.key)
        elseif a.type == "scroll" then
          detail = "scroll " .. tostring(a.direction)
        else
          detail = a.type
        end
      elseif decoded.path then
        detail = vim.fn.fnamemodify(tostring(decoded.path), ":t")
      elseif decoded.argv then
        detail = "exec " .. table.concat(decoded.argv, " "):sub(1, 40)
      elseif decoded.label then
        detail = tostring(decoded.label)
      end
    else
      detail = tostring(args.content):gsub("%s+", " "):sub(1, 40)
    end
  end
  local head = string.format("  → %s", target ~= "" and target or name)
  if detail ~= "" then
    head = head .. "  " .. detail
  end
  return head, intent
end

local function handle_record(rec)
  if type(rec) ~= "table" then
    return
  end
  local msg = rec.message
  if type(msg) ~= "table" then
    return
  end
  local role = msg.role
  local content = msg.content
  if type(content) ~= "table" then
    return
  end

  if role == "user" then
    for _, block in ipairs(content) do
      if block.type == "text" and block.text then
        local text = vim.split(block.text, "\n", { plain = true })
        local lines = { "❯ " .. (text[1] or "") }
        for i = 2, #text do
          table.insert(lines, "  " .. text[i])
        end
        append(lines, { "BxcStreamUser" })
      end
    end
    return
  end

  if role == "assistant" then
    for _, block in ipairs(content) do
      if block.type == "text" and block.text and block.text ~= "" then
        local body = block.text:gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("\r", "")
        local text = vim.split(body, "\n", { plain = true })
        local lines, groups = {}, {}
        for _, line in ipairs(text) do
          table.insert(lines, "  " .. line)
          table.insert(groups, "BxcStreamAgent")
        end
        append(lines, groups)
        -- The agent often *writes* its proof into the message as markdown
        -- (![after Return](/path/shot.png)) rather than relying on the tool result.
        -- Render those images too, otherwise the "screenshot in the output" only
        -- appears for tool results and the prose reads like a broken link.
        for alt, path in body:gmatch("!%[([^%]]*)%]%(([^%s%)]+)%)") do
          if uv.fs_stat(path) then
            append_art(path, alt ~= "" and alt or nil)
          end
        end
      elseif block.type == "toolCall" then
        local head, intent = summarize_call(block.name or "?", block.arguments or {})
        local lines, groups = { head }, { "BxcStreamTool" }
        if intent and intent ~= "" then
          table.insert(lines, "     " .. intent)
          table.insert(groups, "BxcStreamDim")
        end
        append(lines, groups)
      end
    end
    return
  end

  if role == "toolResult" then
    local ok, text, image_path
    for _, block in ipairs(content) do
      if block.type == "text" and block.text then
        text = block.text
        ok = not block.text:match('^ERROR')
      elseif block.type == "image" then
        image_path = shot_from_text(text) or blob_path(block.data)
      end
    end
    local snippet = ""
    if text then
      -- Tool output can carry terminal escapes (a shell tool reading a live tty emits
      -- DECSET codes). Strip them: they render as literal ^[[?25h noise in the stream.
      -- omp stores some of these already caret-escaped ("^[[?25l"), so both forms go.
      text = text
        :gsub("\27%[[%d;?]*[a-zA-Z]", "")
        :gsub("%^%[%[[%d;?]*%a", "")
        :gsub("\27%][^\7]*\7", "")
        :gsub("\r", "")
      local first_line = vim.split(text, "\n", { plain = true })[1] or ""
      snippet = first_line:sub(1, 68)
    end
    if snippet ~= "" then
      append({ "  ← " .. snippet }, { ok and "BxcStreamResult" or "BxcStreamErr" })
    end
    if image_path then
      append_art(image_path, nil)
    elseif text then
      -- Plenty of tool results carry the screenshot as a bare PATH rather than an image
      -- block: omp's eval/bash tools echo "/root/.omp/bxc/shots/....png" verbatim, and the
      -- bxc tools return {"shot": "..."} as text. Without this the stream showed the path
      -- and nothing else, which reads as "no screenshot at all".
      local shown = 0
      for path in text:gmatch("(/[%w%._%-/]+%.png)") do
        if shown >= 2 then
          break
        end
        if vim.uv.fs_stat(path) then
          append_art(path, nil)
          shown = shown + 1
        end
      end
    end
  end
end

--- Read whatever was appended since the last poll, one whole line at a time.
function M.poll()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local cfg = config.options.stream or {}
  if cfg.follow_newest ~= false then
    local newest = M.newest_session()
    if newest and newest ~= state.session then
      -- A new session started: switch to it rather than mixing two runs together.
      state.session, state.offset, state.pending = newest, 0, ""
      append({ "", "── session " .. vim.fn.fnamemodify(newest, ":t"):sub(1, 24) .. " ──" }, { "BxcStreamDim" })
    end
  end
  if not state.session then
    return
  end
  local stat = uv.fs_stat(state.session)
  if not stat then
    return
  end
  if stat.size < state.offset then
    state.offset = 0
    state.pending = ""
  end
  if stat.size == state.offset then
    return
  end
  local fh = io.open(state.session, "r")
  if not fh then
    return
  end
  fh:seek("set", state.offset)
  local chunk = fh:read("*a") or ""
  state.offset = fh:seek()
  fh:close()

  local data = state.pending .. chunk
  local last_nl = data:match(".*()\n")
  if not last_nl then
    state.pending = data
    return
  end
  state.pending = data:sub(last_nl + 1)
  for line in data:sub(1, last_nl):gmatch("[^\n]+") do
    local decoded_ok, rec = pcall(vim.json.decode, line)
    if decoded_ok then
      pcall(handle_record, rec)
    end
  end

  if (cfg.follow or true) and state.win and vim.api.nvim_win_is_valid(state.win) then
    local last = vim.api.nvim_buf_line_count(state.buf)
    pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(last, 1), 0 })
  end
end

local function header()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local name = state.session and vim.fn.fnamemodify(state.session, ":t") or "waiting for a session…"
  local text = string.format(" omp · %s · %d events · %d screenshots", name:sub(1, 46), state.items, state.images)
  -- The buffer stays modifiable for the life of the window: this is a live tail, not a
  -- document. Toggling modifiable here caused nvim_buf_set_lines errors on every tick.
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { text })
  vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, { end_col = #text, hl_group = "BxcStreamHead" })
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

--- Open (or focus) the live agent stream. opts.session pins a specific transcript.
function M.open(opts)
  opts = opts or {}
  hl()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return state.win
  end
  local cfg = config.options.stream or {}

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "bxcstream"
  pcall(vim.api.nvim_buf_set_name, buf, "bxc://omp-stream")

  local width = cfg.width or 78
  vim.cmd("botright " .. width .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = true -- prose and art both want wrapping off/on differently; keep prose readable
  vim.wo[win].winfixwidth = true
  vim.wo[win].cursorline = false

  state.buf, state.win = buf, win
  state.offset, state.pending, state.items, state.images = 0, "", 0, 0
  state.session = opts.session or M.newest_session()

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "" })
  header()
  if state.session then
    append({ "", "── session " .. vim.fn.fnamemodify(state.session, ":t"):sub(1, 24) .. " ──" }, { "BxcStreamDim" })
    -- Catch up on everything already in the transcript.
    state.offset = 0
    M.poll()
    state.offset = uv.fs_stat(state.session) and uv.fs_stat(state.session).size or state.offset
  else
    append({ "", "  no omp session found under " .. sessions_root(), "" }, { "BxcStreamDim" })
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "bxc stream: " .. desc })
  end
  map("q", function()
    M.close()
  end, "close")
  map("R", function()
    state.offset = 0
    state.pending = ""
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, {})
    M.poll()
  end, "reload transcript")
  map("G", function()
    local last = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(last, 1), 0 })
  end, "jump to newest")

  local t = uv.new_timer()
  t:start(
    cfg.refresh_ms or 400,
    cfg.refresh_ms or 400,
    vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      M.poll()
      header()
    end)
  )
  state.timer = t

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      M.close()
    end,
  })

  return win
end

function M.info()
  return {
    open = state.win ~= nil,
    session = state.session,
    items = state.items,
    images = state.images,
    offset = state.offset,
  }
end

return M
