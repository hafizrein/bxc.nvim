-- bxc.http — the few calls the editor itself makes.
--
-- The plugin is allowed one dependency it always has: curl. It never stores a credential in
-- the repo; the token is read from the same three places bxc-mcp reads it, so one file
-- configures both halves.
local M = {}

local uv = vim.uv or vim.loop

local function config()
  return require("bxc.config")
end

--- Token lookup, mirroring bxc-mcp: env -> <home>/token -> ~/boxcompute/credential.
function M.token()
  if config().options.token and config().options.token ~= "" then
    return config().options.token
  end
  if vim.env.BXC_TOKEN and vim.env.BXC_TOKEN ~= "" then
    return vim.env.BXC_TOKEN
  end
  local candidates = {
    vim.fs.joinpath(config().home(), "token"),
    vim.fs.joinpath(vim.fn.expand("~"), "boxcompute", "credential"),
  }
  for _, file in ipairs(candidates) do
    local fh = io.open(file, "r")
    if fh then
      local raw = fh:read("*a") or ""
      fh:close()
      raw = vim.trim(raw)
      if raw ~= "" then
        if raw:sub(1, 1) == "{" then
          local ok, parsed = pcall(vim.json.decode, raw)
          if ok and type(parsed) == "table" then
            return parsed.token or parsed.apiKey or parsed.api_key or parsed.access_token
          end
        else
          return (raw:gsub("%s.*$", ""))
        end
      end
    end
  end
  return nil
end

function M.api()
  return (config().options.api or "https://api.boxcompute.ai/api/v2"):gsub("/$", "")
end

function M.sandbox()
  return config().options.sandbox or vim.env.BXC_SANDBOX_ID
end

local function curl_argv()
  return vim.fn.executable("curl") == 1 and "curl" or nil
end

--- GET a binary route into a file. Returns true on success.
function M.get_bytes(route, outfile, timeout_ms)
  local bin = curl_argv()
  if not bin then
    return false, "curl not found"
  end
  local token = M.token()
  if not token then
    return false, "no BoxCompute token"
  end
  local res = vim.system({
    bin,
    "-sS",
    "--max-time",
    tostring(math.floor((timeout_ms or 15000) / 1000)),
    "-H",
    "Authorization: Bearer " .. token,
    "-H",
    "Accept: image/png",
    "-o",
    outfile,
    M.api() .. route,
  }):wait()
  if res.code ~= 0 then
    return false, (res.stderr or "curl failed"):gsub("%s+$", "")
  end
  local stat = uv.fs_stat(outfile)
  if not stat or stat.size < 100 then
    return false, "empty screenshot"
  end
  return true
end

--- POST a JSON body. Returns parsed table or nil + error.
function M.post_json(route, body, timeout_ms)
  local bin = curl_argv()
  if not bin then
    return nil, "curl not found"
  end
  local token = M.token()
  if not token then
    return nil, "no BoxCompute token"
  end
  local tmp = vim.fn.tempname() .. ".json"
  local fh = io.open(tmp, "w")
  fh:write(vim.json.encode(body or {}))
  fh:close()
  local res = vim.system({
    bin,
    "-sS",
    "--max-time",
    tostring(math.floor((timeout_ms or 20000) / 1000)),
    "-H",
    "Authorization: Bearer " .. token,
    "-H",
    "Content-Type: application/json",
    "-d",
    "@" .. tmp,
    M.api() .. route,
  }):wait()
  pcall(os.remove, tmp)
  if res.code ~= 0 then
    return nil, (res.stderr or "curl failed"):gsub("%s+$", "")
  end
  local ok, parsed = pcall(vim.json.decode, res.stdout or "")
  if not ok then
    return nil, "unparseable response: " .. tostring(res.stdout):sub(1, 200)
  end
  return parsed
end

--- One desktop input action. `shot` asks the API to return the post-action screenshot too.
function M.action(action, opts)
  opts = opts or {}
  local sandbox = M.sandbox()
  if not sandbox then
    return nil, "no sandbox configured (bxc.setup{ sandbox = 'sbx_...' })"
  end
  local body = { action = action }
  if opts.screenshot then
    body.screenshot = "png"
    body.settleMs = opts.settle_ms or 250
  end
  local res, err = M.post_json("/sandboxes/" .. sandbox .. "/desktop/actions", body)
  if not res then
    return nil, err
  end

  -- Record manual input in the same phase log the agent writes, so the rail and the
  -- Telegram history tell one story instead of two.
  local shot = nil
  if res.screenshot and res.screenshot.data then
    local name = os.date("!%Y%m%dT%H%M%S") .. "-ui.png"
    local rel = "shots/" .. name
    local abs = vim.fs.joinpath(config().home(), rel)
    vim.fn.mkdir(vim.fs.joinpath(config().home(), "shots"), "p")
    local out = io.open(abs, "wb")
    if out then
      out:write(vim.base64.decode(res.screenshot.data))
      out:close()
      shot = rel
    end
  end
  M.log_phase({
    tool = "bxc_ui",
    ok = true,
    title = action.type == "click"
        and string.format("ui click (%s, %s)", tostring(action.x), tostring(action.y))
      or ("ui " .. tostring(action.type)),
    shot = shot,
    pointer = res.pointer,
  })
  return res
end

--- Append a phase line in the exact shape bxc-mcp writes (so one reader serves both).
function M.log_phase(phase)
  local file = config().events_file()
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local seq = 0
  local fh = io.open(file, "r")
  if fh then
    local last = nil
    for line in fh:lines() do
      if vim.trim(line) ~= "" then
        last = line
      end
    end
    fh:close()
    if last then
      local ok, decoded = pcall(vim.json.decode, last)
      if ok and decoded and decoded.seq then
        seq = tonumber(decoded.seq) or 0
      end
    end
  end
  local record = vim.tbl_extend("force", {
    v = 1,
    seq = seq + 1,
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    sandbox = M.sandbox(),
  }, phase)
  local out = io.open(file, "a")
  if out then
    out:write(vim.json.encode(record) .. "\n")
    out:close()
  end
  return record
end

return M
