# bxc.nvim

**Your BoxCompute VM's desktop, live inside Neovim — plus a phase-by-phase audit trail of
what the agent did to it.**

Ask an agent to work on a remote VM and you get two bad options: trust the transcript, or
open a browser and squint at a stream. This plugin makes the desktop a *window in your
editor* — addressable, so your cursor is the pointer — and records every action as a phase
with a screenshot attached, so the run can be reviewed afterwards or watched from a phone.

```
┌─ bxc · live VM ─────────────────────────────────────┐
│ sbx_7bf7a38d… · 1.4 fps · 212 frames · 96s           │
│ ░░░░░▓▓▓░░░░░░░▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░▓█▓░░░░░░░▓████▓░░░░░░░░░░░░░░▓▓▓░░░░░░░░░░░░░░ │  ← the VM's screen,
│ ░░░░▓█▓░░░░░░▓██▓░░▓▓░░░░░░░░░░░▓███▓░░░░░░░░░░░░░░ │    each cell a colour
│ ░░░░░▓▓▓░░░░░░░▓▓▓▓░░░░░░░░░░░░░░░▓▓▓░░░░░░░░░░░░░░ │    block, cursor = px
│ <CR> click · m move · t type · K key · u/d scroll · q│
└─────────────────────────────────────────────────────┘
```

## How it fits together

Three layers, one contract between them — a JSONL phase log:

```
   agent (omp, Claude Code, anything that speaks MCP)
        │  stdio MCP
        ▼
   mcp/bxc-mcp.mjs ──── REST ────► api.boxcompute.ai
        │                          /sandboxes/{id}/desktop/{start,actions,screenshot,viewer}
        │                          /sandboxes/{id}/execute
        │  appends
        ▼
   ~/.omp/bxc/events.jsonl  +  ~/.omp/bxc/shots/*.png
        │  tailed (fs_event + 1s poll fallback)
        ▼
   lua/bxc/*  ──►  :BxcWindow (live desktop)   :Bxc (phase rail)   :BxcProof (screenshot)
                   └── optional: each proof pushed to Telegram as it happens
```

The important property: **the editor never needs a credential of its own beyond a read of the
same token file**, and the log is plain text. You can `:BxcLog`, `grep` it, commit it, or
build another frontend on it.

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`, `vim.uv`)
- Node ≥ 18 for the MCP server (global `fetch`/`FormData`, no dependencies)
- [`chafa`](https://hpjansson.org/chafa/) for in-editor rendering — `apt install chafa`,
  `brew install chafa`, `scoop install chafa`. Without it, proofs open in your OS image
  viewer and the live window will not render.
- A BoxCompute **API key** (`bc_live_…`). See [Auth](#auth-the-two-surface-split).
- The target VM must be **`large` or bigger** — the desktop does not exist on `small`.

## Install

### 1. The MCP server (agent side)

Point your agent's MCP config at the server. For omp (`~/.omp/agent/mcp.json`):

```json
{
  "mcpServers": {
    "bxc": {
      "command": "node",
      "args": ["/absolute/path/to/bxc.nvim/mcp/bxc-mcp.mjs"],
      "env": {
        "BXC_SANDBOX_ID": "sbx_xxxxxxxxxxxxxxxxxxxx",
        "BXC_HOME": "/home/you/.omp/bxc"
      }
    }
  }
}
```

The key is found automatically — `BXC_TOKEN`, then `$BXC_HOME/token`, then
`~/boxcompute/credential` (what `bxc auth` writes). Keep it out of the JSON.

### 2. The plugin (editor side)

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "hafizrein/bxc.nvim",
  config = function()
    require("bxc").setup({
      sandbox = "sbx_xxxxxxxxxxxxxxxxxxxx",
      -- home = "~/.omp/bxc",         -- must match BXC_HOME
      live = { refresh_ms = 700, width = 118, height = 40 },
    })
  end,
  cmd = { "Bxc", "BxcWindow", "BxcProof", "BxcLive", "BxcStatus" },
}
```

Or by path, without a plugin manager:

```vim
set runtimepath+=/absolute/path/to/bxc.nvim
command! -bang BxcWindow lua require("bxc.live").open({ split = vim.v.bang == 1 })
```

## Commands

| Command | What it does |
|---|---|
| `:BxcWindow` | The live VM desktop as a floating window. `:BxcWindow!` puts it in a vertical split. |
| `:Bxc` | The phase rail — one row per action; `<CR>` shows that phase's screenshot. |
| `:BxcProof` | Screenshot proof for the newest phase, no rail needed. |
| `:BxcLive` | Opens the BoxCompute live viewer link in your browser (a real VNC-class stream). |
| `:BxcStatus` | Diagnoses the wiring: paths, phase count, renderer in use, last phase. |
| `:BxcLog` | The raw `events.jsonl`. |
| `:BxcClear` | Truncates the log. |

### In the live window

| Key | Action |
|---|---|
| `<CR>` | click at the cell under the cursor |
| `m` | move the pointer to the cursor |
| `t` | type text into the VM (US-ASCII; the API refuses the rest) |
| `K` | send a named key (`Return`, `Tab`, `Escape`, `Page_Down`, `F1`…`F12`, a single char) |
| `u` / `d` | scroll up / down 3 wheel steps at the cursor |
| `R` | force a frame · `q` close |

Manual input is written back into the same phase log (`tool: "bxc_ui"`), so the rail and the
Telegram history tell one story instead of two.

## Config

```lua
require("bxc").setup({
  home = "~/.omp/bxc",          -- events.jsonl + shots/  (match BXC_HOME)
  events_file = nil,            -- override the log path directly
  sandbox = "sbx_…",            -- also read from $BXC_SANDBOX_ID
  api = "https://api.boxcompute.ai/api/v2",
  token = nil,                  -- else $BXC_TOKEN, else <home>/token, else ~/boxcompute/credential

  live = {
    refresh_ms = 700,           -- poll interval; each frame is one screenshot request
    width = 118,
    height = 40,
    split = false,
  },

  width = 42,                   -- phase rail columns
  follow = true,                -- keep the newest phase in view
  max_phases = 400,
  render = { chain = { "snacks", "image_nvim", "chafa", "external" } },
})
```

### Rendering

`render.chain` is tried in order:

1. **`snacks`** — `snacks.nvim`'s image module (kitty / wezterm / ghostty).
2. **`image_nvim`** — `3rd/image.nvim` if installed.
3. **`chafa`** — works in *any* terminal, including Windows Terminal. chafa's 256-colour
   SGR output is parsed and re-emitted as `virt_text` chunks with per-colour highlight
   groups, because Neovim does not interpret ANSI escapes inside a buffer. Without this
   step you get `^[[38;5;…` garbage instead of a picture.
4. **`external`** — hands the PNG to the OS.

## Proof push (Telegram)

Every captured screenshot can be pushed to a chat as it happens — useful when the run is
long and you are not at the machine.

```bash
export BXC_NOTIFY=telegram
export BXC_TG_TOKEN=123456:ABC…      # bot token
export BXC_TG_CHAT=123456789         # chat id
export BXC_NOTIFY_MIN_MS=1200        # throttle, default 1200
```

`BXC_NOTIFY=hermes` shells out to `hermes send --to telegram:<chat>` instead, if you run
[Hermes Agent](https://github.com/NousResearch/hermes-agent). A failed push is written to
stderr and never fails the desktop action that already happened.

## Auth: the two-surface split

BoxCompute is authenticated in two different ways and mixing them up costs an hour:

| Surface | Accepts |
|---|---|
| `https://mcp.boxcompute.ai/mcp` (MCP, 24 tools, no desktop) | **OAuth** (DCR + PKCE), or an API key |
| `https://api.boxcompute.ai/api/v2` (REST — where desktop lives) | **API key only** (`Authorization: Bearer bc_live_…`) |

An OAuth token from `hermes mcp login boxcompute` works for MCP and returns
`401 INVALID_API_KEY` on REST. Key management is not in the public v2 spec, so the key comes
from the app or the CLI:

```bash
npm i -g @boxcompute/cli
bxc auth          # device flow: approve a URL, key lands in ~/boxcompute/credential
```

## Cost and safety

- `sandbox_list` / `sandbox_get` are free and never wake a VM. **`file_read` and
  `file_list` do start a stopped VM** and bill compute — check state first.
- The desktop exists only on `large` and up: small ≈ $0.05/h, large ≈ $0.15/h, billed
  per second. A stopped VM costs disk only.
- `desktop/start` is refused while a browser preview holds the VM.
- Input is **never retried** by the server. After `DESKTOP_INPUT_UNCERTAIN` or a lost
  response, take a screenshot before repeating an action — `bxc_shot` exists for that.
- Coordinates are screenshot pixels on a 1280×800 screen. Typing is US-ASCII.

## Tests

Both suites run against a **real VM**, because every interesting failure in this project was
in the API's behaviour rather than in the code's shape.

```bash
# MCP server: protocol, tools, log integrity, error path (16 checks)
BXC_SANDBOX_ID=sbx_… BXC_HOME=~/.omp/bxc node tests/mcp-smoke.mjs

# Plugin: event parsing, ANSI conversion, phase->row map, cell->px, live frames (28 checks)
BXC_SANDBOX_ID=sbx_… BXC_HOME=~/.omp/bxc nvim --headless --clean -l tests/ui-smoke.lua
```

## Verified

- Linux, Neovim 0.12.4, Node 26, chafa 1.14.0, Ubuntu 26.04 VM (sway @ 1280×800).
- MCP suite: 16/16. UI suite: 28/28, including a real frame fetched and painted.
- Phase log integrity asserted: contiguous `seq`, every recorded `shot` path exists, failed
  calls recorded with `ok: false`.
- **Windows is not yet verified** in this repo — the code paths are there (`curl.exe`,
  `%LOCALAPPDATA%` handled by `vim.fs`), but the suites have only been run on Linux.

## Design notes

- **The screenshot comes back in the same round trip as the action.** `desktop/actions`
  accepts `screenshot: "png"`, so a phase is one request, not two — which is also why the
  live window is honest about latency: one frame = one request.
- **The log is the interface.** The plugin is a renderer for a text file; a different
  frontend (tmux, a web page, a chat bot) needs no changes to the MCP server.
- **The cursor is the pointer.** Cell → pixel is arithmetic, not a guess, so clicking in a
  character grid is exact rather than approximate.

## License

MIT — see [LICENSE](LICENSE).
