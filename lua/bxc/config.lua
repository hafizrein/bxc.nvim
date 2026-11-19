-- bxc.config — defaults and user options.
local M = {}

M.defaults = {
  -- Where bxc-mcp writes events.jsonl + shots/. Must match BXC_HOME for the MCP server.
  home = nil, -- default: ~/.omp/bxc
  events_file = nil, -- default: <home>/events.jsonl
  sandbox = nil, -- sbx_... ; also read from $BXC_SANDBOX_ID
  api = nil, -- default: https://api.boxcompute.ai/api/v2
  token = nil, -- else $BXC_TOKEN, else <home>/token, else ~/boxcompute/credential

  -- The live VM window (:BxcWindow). refresh_ms is a poll interval, not a frame rate:
  -- each frame is one screenshot fetch, so keep it honest rather than fast.
  live = {
    refresh_ms = 700,
    width = 118,
    height = 40,
    split = false, -- true = vertical split instead of a float
  },

  width = 42, -- sidebar columns
  follow = true, -- keep the newest phase in view
  auto_open = false, -- open the sidebar by itself when a new phase appears
  max_phases = 400, -- ring limit for what the sidebar renders

  keys = {
    proof = "<CR>",
    live = "L",
    follow = "f",
    refresh = "r",
    clear = "C",
    close = "q",
  },

  -- Renderer priority for screenshots. "chafa" works in every terminal (ANSI -> colour
  -- blocks); "external" always works because it hands the PNG to the OS.
  render = {
    chain = { "snacks", "image_nvim", "chafa", "external" },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.home()
  return M.options.home
    or vim.fs.joinpath(vim.fn.expand("~"), ".omp", "bxc")
end

function M.events_file()
  return M.options.events_file or vim.fs.joinpath(M.home(), "events.jsonl")
end

return M
