-- bxc — BoxCompute desktop phases, in the editor.
--
-- Layering: bxc-mcp (tool surface, writes phases) -> events.jsonl (bus) -> this UI.
-- Nothing here talks to the network or holds a credential; the plugin only reads the log
-- the MCP server writes, which is why it works the same on Linux, macOS and Windows.
local M = {}

local config = require("bxc.config")

M.commands_defined = false

--- Define the :Bxc* commands. Idempotent: plugin/bxc.lua and setup() both call it.
function M.commands()
  if M.commands_defined then
    return
  end
  M.commands_defined = true

  local function sidebar()
    return require("bxc.sidebar")
  end

  vim.api.nvim_create_user_command("Bxc", function()
    sidebar().open()
  end, { desc = "bxc: open the phase sidebar" })

  vim.api.nvim_create_user_command("BxcToggle", function()
    sidebar().toggle()
  end, { desc = "bxc: toggle the phase sidebar" })

  vim.api.nvim_create_user_command("BxcProof", function()
    sidebar().proof_latest()
  end, { desc = "bxc: screenshot proof for the newest phase" })

  vim.api.nvim_create_user_command("BxcWindow", function(cmd)
    local live = require("bxc.live")
    live.open({ split = cmd.bang })
  end, { bang = true, desc = "bxc: live VM desktop window (:BxcWindow! for a split)" })

  vim.api.nvim_create_user_command("BxcStream", function(cmd)
    local stream = require("bxc.stream")
    stream.open({ session = cmd.args ~= "" and cmd.args or nil })
  end, { nargs = "?", complete = "file", desc = "bxc: omp's live session, with screenshots inline" })

  vim.api.nvim_create_user_command("BxcLive", function()
    local events = require("bxc.events")
    local phases = events.read(config.events_file())
    local url = sidebar().latest_viewer(phases)
    if url then
      vim.ui.open(url)
    else
      vim.notify("bxc: no live viewer url yet — the agent must call bxc_viewer", vim.log.levels.WARN)
    end
  end, { desc = "bxc: open the live desktop viewer" })

  vim.api.nvim_create_user_command("BxcLog", function()
    vim.cmd.edit(vim.fn.fnameescape(config.events_file()))
  end, { desc = "bxc: open the raw phase log" })

  vim.api.nvim_create_user_command("BxcClear", function()
    local fh = io.open(config.events_file(), "w")
    if fh then
      fh:close()
    end
    pcall(sidebar().refresh)
    vim.notify("bxc: cleared " .. config.events_file(), vim.log.levels.INFO)
  end, { desc = "bxc: truncate the phase log" })

  vim.api.nvim_create_user_command("BxcStatus", function()
    local report = M.status()
    vim.notify(table.concat(report, "\n"), vim.log.levels.INFO, { title = "bxc" })
  end, { desc = "bxc: diagnose the wiring" })
end

--- Everything needed to answer "why is nothing showing up?", in order of likely cause.
--- @return string[]
function M.status()
  local events = require("bxc.events")
  local proof = require("bxc.proof")
  local home = config.home()
  local file = config.events_file()
  local phases = events.read(file)
  local stat = vim.uv.fs_stat(file)
  local shots = 0

  local shot_dir = vim.fs.joinpath(home, "shots")
  local scan = vim.uv.fs_scandir(shot_dir)
  if scan then
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end
      if name:match("%.png$") then
        shots = shots + 1
      end
    end
  end

  local renderer = proof.pick_renderer()
  local lines = {
    "home:        " .. home,
    "events:      " .. file .. (stat and "  (" .. #phases .. " phases)" or "  (missing)"),
    "shots:       " .. shot_dir .. string.format("  (%d png)", shots),
    "renderer:    " .. renderer,
    "follow:      " .. tostring(config.options.follow),
    "sandbox:     " .. tostring(config.options.sandbox or "(set from the log)"),
  }
  if not stat then
    table.insert(lines, "")
    table.insert(lines, "No log yet. The MCP server writes it — add bxc to the agent's MCP")
    table.insert(lines, "config and point BXC_HOME at the same directory (see README).")
  elseif #phases > 0 then
    local last = phases[#phases]
    table.insert(lines, "")
    table.insert(lines, string.format("last phase: %s %s (%s ago)", tostring(last.tool), tostring(last.title), events.age(last.ts)))
  end
  if renderer == "external" then
    table.insert(lines, "")
    table.insert(lines, "Renderer is 'external': screenshots open outside the editor.")
    table.insert(lines, "Install chafa for in-editor colour art, or use a kitty/wezterm terminal.")
  end
  return lines
end

--- @param opts? table see bxc.config.defaults
function M.setup(opts)
  config.setup(opts)
  M.commands()
  return M
end

return M
