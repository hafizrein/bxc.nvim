#!/usr/bin/env node
/**
 * bxc-mcp — BoxCompute desktop control as an MCP stdio server, with a phase log.
 *
 * The point of this file: every action can return the *post-action screenshot in the
 * same round trip* (`screenshot: "png"` on POST /desktop/actions), so each call is one
 * auditable phase: do something -> get the picture that proves it. Each phase is appended
 * to $BXC_HOME/events.jsonl, which bxc.nvim tails to draw the sidebar. The PNG itself is
 * written to $BXC_HOME/shots/ so the editor never needs the bytes over the wire.
 *
 * Config (all optional except the sandbox / token pair):
 *   BXC_SANDBOX_ID  sbx_...        — target VM
 *   BXC_TOKEN       bc_live_...    — API key; else $BXC_HOME/token, else ~/boxcompute/credential
 *   BXC_HOME        ~/.omp/bxc     — events.jsonl + shots/ live here
 *   BXC_API         https://api.boxcompute.ai/api/v2
 *
 * No dependencies. Node >= 18 (global fetch).
 */
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const API = (process.env.BXC_API || "https://api.boxcompute.ai/api/v2").replace(/\/$/, "");
const SANDBOX = process.env.BXC_SANDBOX_ID || "";
const HOME = process.env.BXC_HOME || path.join(os.homedir(), ".omp", "bxc");
const SHOTS = path.join(HOME, "shots");
const EVENTS = path.join(HOME, "events.jsonl");
const LOG_VERSION = 1;
const SERVER = { name: "bxc", version: "1.0.0" };
const PROTOCOL = "2025-06-18";

/* ── proof push (optional) ────────────────────────────────────────────────────
 * "send pics here so I can see what has been done": when enabled, every captured
 * screenshot is pushed to a chat as it happens, so the run can be watched from a phone.
 *   BXC_NOTIFY        off | telegram | hermes   (default off)
 *   BXC_TG_TOKEN      bot token        (telegram backend)
 *   BXC_TG_CHAT       chat id          (telegram backend)
 *   BXC_NOTIFY_MIN_MS minimum gap between pushes, default 1200
 * Failures are swallowed into stderr on purpose: a chat outage must never fail a desktop
 * action that already happened.
 */
const NOTIFY = (process.env.BXC_NOTIFY || "off").toLowerCase();
const TG_TOKEN = process.env.BXC_TG_TOKEN || "";
const TG_CHAT = process.env.BXC_TG_CHAT || "";
const NOTIFY_MIN_MS = Number(process.env.BXC_NOTIFY_MIN_MS || 1200);
let lastPushAt = 0;

async function pushProof(file, caption) {
  if (NOTIFY === "off" || !file) return;
  const wait = NOTIFY_MIN_MS - (Date.now() - lastPushAt);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastPushAt = Date.now();
  try {
    if (NOTIFY === "telegram") {
      if (!TG_TOKEN || !TG_CHAT) throw new Error("BXC_TG_TOKEN / BXC_TG_CHAT unset");
      const form = new FormData();
      form.append("chat_id", TG_CHAT);
      form.append("caption", caption.slice(0, 1024));
      form.append("photo", new Blob([fs.readFileSync(file)], { type: "image/png" }), path.basename(file));
      const res = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendPhoto`, {
        method: "POST",
        body: form,
      });
      if (!res.ok) throw new Error(`telegram ${res.status}: ${(await res.text()).slice(0, 200)}`);
      const body = await res.json().catch(() => ({}));
      process.stderr.write(`bxc-mcp: proof pushed to telegram (message_id ${body?.result?.message_id})\n`);
    } else if (NOTIFY === "hermes") {
      await new Promise((resolve, reject) => {
        const child = spawn("hermes", ["send", "--to", `telegram:${TG_CHAT}`, `${caption}\nMEDIA:${file}`], {
          stdio: "ignore",
        });
        child.on("error", reject);
        child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`hermes send exit ${code}`))));
      });
    }
  } catch (err) {
    process.stderr.write(`bxc-mcp: proof push failed (${err.message})\n`);
  }
}

fs.mkdirSync(SHOTS, { recursive: true });

/* ── credential ───────────────────────────────────────────────────────────── */

function readToken() {
  if (process.env.BXC_TOKEN) return process.env.BXC_TOKEN.trim();
  const candidates = [
    path.join(HOME, "token"),
    path.join(os.homedir(), "boxcompute", "credential"),
  ];
  for (const file of candidates) {
    try {
      const raw = fs.readFileSync(file, "utf8").trim();
      // ~/boxcompute/credential may be the bare token or a JSON blob; accept both.
      if (raw.startsWith("{")) {
        const parsed = JSON.parse(raw);
        const tok = parsed.token || parsed.apiKey || parsed.api_key || parsed.access_token;
        if (tok) return String(tok).trim();
      } else if (raw) {
        return raw.split(/\r?\n/)[0].trim();
      }
    } catch {
      /* not there; try the next candidate */
    }
  }
  throw new Error(
    "no BoxCompute credential: set BXC_TOKEN, or write it to " +
      path.join(HOME, "token") +
      ", or ~/boxcompute/credential",
  );
}

/* ── phase log ────────────────────────────────────────────────────────────── */

function stamp() {
  // 20261119T213012123Z — sortable, filename-safe, no colons (Windows).
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.(\d{3})Z$/, "$1Z");
}

function nextSeq() {
  let seq = 0;
  try {
    const lines = fs.readFileSync(EVENTS, "utf8").trimEnd().split("\n");
    const last = JSON.parse(lines[lines.length - 1]);
    seq = Number(last.seq) || 0;
  } catch {
    /* empty or missing log starts at 0 */
  }
  return seq + 1;
}

function logPhase(event) {
  const record = {
    v: LOG_VERSION,
    seq: nextSeq(),
    ts: new Date().toISOString(),
    sandbox: SANDBOX || null,
    ...event,
  };
  fs.appendFileSync(EVENTS, JSON.stringify(record) + "\n");
  return record;
}

function saveShot(base64, kind) {
  const file = path.join(SHOTS, `${stamp()}-${kind}.png`);
  fs.writeFileSync(file, Buffer.from(base64, "base64"));
  // The sidebar wants a path it can render; relative keeps the log portable.
  return { file, rel: path.relative(HOME, file).split(path.sep).join("/") };
}

/* ── HTTP ─────────────────────────────────────────────────────────────────── */

async function api(method, route, body) {
  const token = readToken();
  const res = await fetch(`${API}${route}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let payload = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = { raw: text.slice(0, 2000) };
  }
  if (!res.ok) {
    const code = payload?.code || payload?.error?.code || "";
    const msg = payload?.error?.message || payload?.message || payload?.error || text.slice(0, 300);
    throw new Error(`HTTP ${res.status}${code ? " " + code : ""}: ${msg}`);
  }
  return payload;
}

/** GET returning raw bytes (the screenshot route is image/png, not JSON). */
async function apiBytes(route) {
  const token = readToken();
  const res = await fetch(`${API}${route}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "image/png" },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} reading ${route}`);
  const buf = Buffer.from(await res.arrayBuffer());
  return buf;
}

function needSandbox() {
  if (!SANDBOX) throw new Error("BXC_SANDBOX_ID is not set");
  return `/sandboxes/${SANDBOX}`;
}

/* ── action summaries (what the sidebar shows) ────────────────────────────── */

function describeAction(action, result) {
  const a = action || {};
  switch (a.type) {
    case "click":
      return `click${a.x != null ? ` (${a.x}, ${a.y})` : ""} · ${a.button || "left"}×${a.clicks || 1}`;
    case "move":
      return `move (${a.x}, ${a.y})`;
    case "type":
      return `type "${String(a.text || "").slice(0, 60)}"`;
    case "key":
      return `key ${a.key}${a.modifiers?.length ? "+" + a.modifiers.join("+") : ""}`;
    case "scroll":
      return `scroll ${a.direction} ×${a.amount || 3}`;
    default:
      return a.type || "action";
  }
}

/* ── tools ────────────────────────────────────────────────────────────────── */

const TOOLS = [
  {
    name: "bxc_status",
    description:
      "VM and desktop state for the sandbox. Free and safe: never starts or wakes the VM.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "bxc_desktop_start",
    description:
      "Start the VM's sway desktop (idempotent). Requires a running VM, and is refused while a browser preview holds the VM.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "bxc_act",
    description:
      "Perform one desktop input action (click/move/type/key/scroll) and, by default, return the screenshot taken right after it. Coordinates are pixels on the 1280x800 screen. Typing is US-ASCII only.",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "object",
          description:
            'One of {"type":"click","x":0-1279,"y":0-799,"button":"left|middle|right","clicks":1|2},' +
            ' {"type":"move","x","y"}, {"type":"type","text"}, ' +
            '{"type":"key","key":"Return|Tab|Escape|BackSpace|...|F1..F12|single char","modifiers":["ctrl"|"alt"|"shift"|"super"]}, ' +
            '{"type":"scroll","direction":"up|down|left|right","amount":1-15,"x","y"}',
        },
        screenshot: {
          type: "boolean",
          description: "Return the post-action screenshot (default true).",
        },
        settle_ms: {
          type: "integer",
          description: "How long the screen may settle after the input, 0-2000 (default 300).",
        },
      },
      required: ["action"],
      additionalProperties: false,
    },
  },
  {
    name: "bxc_shot",
    description: "Take a screenshot of the desktop without sending any input.",
    inputSchema: {
      type: "object",
      properties: {
        label: { type: "string", description: "Short label for this phase in the sidebar." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "bxc_viewer",
    description:
      "Get (or refresh) a live desktop viewer URL — a page that streams the desktop and accepts input. This is the 'watch it work' window.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "bxc_exec",
    description:
      "Run a shell command inside the VM (argv form, cwd under /workspace, 900 s max). Use for launching apps (e.g. `swaymsg exec foot`) and for browser work over CDP inside the VM.",
    inputSchema: {
      type: "object",
      properties: {
        argv: {
          type: "array",
          items: { type: "string" },
          minItems: 1,
          description: 'Command as argv, e.g. ["bash","-lc","swaymsg exec foot"].',
        },
        cwd: { type: "string", description: "Defaults to /workspace." },
        timeout_s: { type: "integer" },
        label: { type: "string", description: "Short label for this phase." },
      },
      required: ["argv"],
      additionalProperties: false,
    },
  },
  {
    name: "bxc_phases",
    description: "Read back the last N recorded phases from the event log.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer" } },
      additionalProperties: false,
    },
  },
];

const text = (s) => ({ type: "text", text: s });
const image = (base64, mimeType = "image/png") => ({ type: "image", data: base64, mimeType });

async function callTool(name, args) {
  const started = Date.now();
  try {
    switch (name) {
      case "bxc_status": {
        const [vm, desk] = await Promise.all([
          api("GET", needSandbox()),
          api("GET", `${needSandbox()}/desktop`).catch((e) => ({ error: String(e.message) })),
        ]);
        const s = vm.sandbox || vm;
        return [
          text(
            JSON.stringify(
              {
                sandbox: s.id,
                name: s.name,
                state: s.state,
                size: s.size,
                desktop: desk?.desktop || desk,
              },
              null,
              2,
            ),
          ),
        ];
      }

      case "bxc_desktop_start": {
        const res = await api("POST", `${needSandbox()}/desktop/start`, {});
        logPhase({
          tool: "bxc_desktop_start",
          ok: true,
          title: "desktop start",
          detail: res?.desktop?.state || "started",
          ms: Date.now() - started,
        });
        return [text(JSON.stringify(res))];
      }

      case "bxc_act": {
        const wantShot = args?.screenshot !== false;
        const body = { action: args?.action };
        if (wantShot) {
          body.screenshot = "png";
          body.settleMs = args?.settle_ms ?? 300;
        }
        const res = await api("POST", `${needSandbox()}/desktop/actions`, body);
        const title = describeAction(args?.action, res);
        let shot = null;
        if (res?.screenshot?.data) shot = saveShot(res.screenshot.data, "act");
        const rec = logPhase({
          tool: "bxc_act",
          ok: true,
          title,
          detail: body.settleMs != null ? `settle ${body.settleMs}ms` : "",
          pointer: res?.pointer || null,
          shot: shot?.rel || null,
          ms: Date.now() - started,
        });
        if (shot?.file) await pushProof(shot.file, `#${rec.seq} ${title}`);
        const out = [text(JSON.stringify({ ok: true, action: title, pointer: res?.pointer, shot: shot?.file }))];
        if (res?.screenshot?.data) out.push(image(res.screenshot.data, res.screenshot.mimeType));
        return out;
      }

      case "bxc_shot": {
        const buf = await apiBytes(`${needSandbox()}/desktop/screenshot`);
        const b64 = buf.toString("base64");
        const shot = saveShot(b64, "shot");
        const rec = logPhase({
          tool: "bxc_shot",
          ok: true,
          title: args?.label || "screenshot",
          detail: `${(buf.length / 1024).toFixed(0)} KiB`,
          shot: shot.rel,
          ms: Date.now() - started,
        });
        await pushProof(shot.file, `#${rec.seq} ${args?.label || "screenshot"}`);
        return [text(JSON.stringify({ ok: true, shot: shot.file })), image(b64)];
      }

      case "bxc_viewer": {
        const res = await api("POST", `${needSandbox()}/desktop/viewer`, {});
        const url = res?.url || res?.viewer?.url || res?.link;
        logPhase({
          tool: "bxc_viewer",
          ok: true,
          title: "live viewer",
          detail: url ? "link issued" : "no url in response",
          url: url || null,
          ms: Date.now() - started,
        });
        return [text(JSON.stringify(res))];
      }

      case "bxc_exec": {
        const body = {
          argv: args?.argv,
          cwd: args?.cwd || "/workspace",
          timeoutSeconds: args?.timeout_s ?? 120,
        };
        const res = await api("POST", `${needSandbox()}/execute`, body);
        const r = res?.result || res;
        logPhase({
          tool: "bxc_exec",
          ok: (r?.exitCode ?? 0) === 0,
          title: args?.label || (args?.argv || []).slice(-1)[0] || "exec",
          detail: `exit ${r?.exitCode ?? "?"}`,
          ms: Date.now() - started,
        });
        return [text(JSON.stringify(r).slice(0, 12000))];
      }

      case "bxc_phases": {
        const n = Math.max(1, Math.min(200, args?.limit ?? 10));
        let lines = [];
        try {
          lines = fs.readFileSync(EVENTS, "utf8").trimEnd().split("\n").slice(-n);
        } catch {
          return [text("no phases recorded yet")];
        }
        return [text(lines.join("\n"))];
      }

      default:
        throw new Error(`unknown tool: ${name}`);
    }
  } catch (err) {
    logPhase({
      tool: name,
      ok: false,
      title: name.replace(/^bxc_/, ""),
      detail: String(err.message).slice(0, 200),
      error: String(err.message),
      ms: Date.now() - started,
    });
    return { content: [text(`ERROR: ${err.message}`)], isError: true };
  }
}

/* ── MCP stdio loop (newline-delimited JSON-RPC) ──────────────────────────── */

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

const rl = createInterface({ input: process.stdin });
rl.on("line", async (line) => {
  const raw = line.trim();
  if (!raw) return;
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    return send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
  }
  const { id, method, params } = msg;

  // Notifications carry no id and must never get a response.
  if (id === undefined || id === null) {
    if (method === "notifications/initialized") {
      process.stderr.write(`bxc-mcp ready · sandbox=${SANDBOX || "(unset)"} · log=${EVENTS}\n`);
    }
    return;
  }

  try {
    if (method === "initialize") {
      return send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: params?.protocolVersion || PROTOCOL,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER,
          instructions:
            "BoxCompute desktop tools. Every action can return its own screenshot; each call is " +
            "logged as a phase that the editor sidebar shows. Take a screenshot before repeating an " +
            "action whose result is uncertain — the server never retries input.",
        },
      });
    }
    if (method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
    if (method === "tools/call") {
      const out = await callTool(params?.name, params?.arguments || {});
      // callTool returns a bare content array on success, {content,isError} on failure.
      const result = Array.isArray(out) ? { content: out } : { content: out.content, isError: !!out.isError };
      return send({ jsonrpc: "2.0", id, result });
    }
    if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
    return send({ jsonrpc: "2.0", id, error: { code: -32601, message: `unknown method ${method}` } });
  } catch (err) {
    return send({ jsonrpc: "2.0", id, error: { code: -32603, message: String(err.message || err) } });
  }
});
rl.on("close", () => process.exit(0));
