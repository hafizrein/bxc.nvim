#!/usr/bin/env node
/**
 * Smoke test for bxc-mcp — drives the real server over stdio against a real VM.
 *
 *   BXC_SANDBOX_ID=sbx_... BXC_TOKEN=... node tests/mcp-smoke.mjs
 *
 * Exits non-zero on the first failed assertion. Prints one line per check so a failure
 * points at the layer (protocol, tool, log, screenshot) rather than "it broke".
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const SERVER = path.join(import.meta.dirname, "..", "mcp", "bxc-mcp.mjs");
const HOME = process.env.BXC_HOME || path.join(process.env.HOME || ".", ".omp", "bxc");
const EVENTS = path.join(HOME, "events.jsonl");
const SHOTS = path.join(HOME, "shots");

let failures = 0;
const check = (ok, label, extra = "") => {
  if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? "  — " + extra : ""}`);
};

const child = spawn(process.execPath, [SERVER], {
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env,
});

let buffer = "";
const pending = new Map();
let idc = 0;

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString();
  let idx;
  while ((idx = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      console.log("non-JSON on stdout:", line.slice(0, 120));
      continue;
    }
    const waiter = pending.get(msg.id);
    if (waiter) {
      pending.delete(msg.id);
      waiter(msg);
    }
  }
});
child.stderr.on("data", (c) => process.env.BXC_DEBUG && process.stderr.write(c));

function rpc(method, params, timeoutMs = 45000) {
  const id = ++idc;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for ${method}`));
    }, timeoutMs);
    pending.set(id, (msg) => {
      clearTimeout(timer);
      if (msg.error) reject(new Error(`${method}: ${msg.error.message}`));
      else resolve(msg.result);
    });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

const call = async (name, args = {}) => {
  const res = await rpc("tools/call", { name, arguments: args });
  const textPart = (res.content || []).find((c) => c.type === "text");
  const imagePart = (res.content || []).find((c) => c.type === "image");
  return { text: textPart?.text || "", image: imagePart, isError: !!res.isError, raw: res };
};

const phases = () => {
  try {
    return fs.readFileSync(EVENTS, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  } catch {
    return [];
  }
};

try {
  // 1. protocol
  const init = await rpc("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "bxc-smoke", version: "0" },
  });
  check(init?.serverInfo?.name === "bxc", "initialize returns serverInfo", JSON.stringify(init?.serverInfo));
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

  const list = await rpc("tools/list");
  check(Array.isArray(list?.tools) && list.tools.length >= 6, `tools/list returns ${list?.tools?.length} tools`);

  // 2. status — must not wake or bill anything
  const status = await call("bxc_status");
  check(!status.isError && /"state"/.test(status.text), "bxc_status returns VM state", status.text.slice(0, 90));

  // 3. screenshot through the standalone route
  const shot = await call("bxc_shot", { label: "smoke boot" });
  check(!shot.isError, "bxc_shot succeeds", shot.text.slice(0, 90));
  check(!!shot.image?.data, "bxc_shot returns image content for the model");

  // 4. action + proof in ONE round trip
  const typed = await call("bxc_act", { action: { type: "type", text: "uname -a" }, settle_ms: 250 });
  check(!typed.isError, "bxc_act type succeeds", typed.text.slice(0, 90));
  check(!!typed.image?.data, "bxc_act returns the post-action screenshot");

  const enter = await call("bxc_act", { action: { type: "key", key: "Return" }, settle_ms: 600 });
  check(!enter.isError, "bxc_act key Return succeeds", enter.text.slice(0, 60));

  // 5. the phase log is the UI contract. bxc_status is deliberately NOT logged — reading
  // state should not spam the rail — so the shot + two actions make exactly three phases.
  const log = phases();
  check(log.length >= 3, `events.jsonl has ${log.length} phases`);
  const last = log[log.length - 1];
  check(typeof last.seq === "number" && !!last.ts && !!last.tool, "phase record has seq/ts/tool");
  check(
    log.every((p, i) => i === 0 || p.seq === log[i - 1].seq + 1),
    "phase seq numbers are contiguous"
  );
  const withShot = log.filter((p) => p.shot);
  check(withShot.length >= 3, `${withShot.length} phases carry a screenshot path`);
  const exists = withShot.every((p) => fs.existsSync(path.join(HOME, p.shot)));
  check(exists, "every recorded shot path exists on disk");
  if (withShot.length) {
    const bytes = fs.statSync(path.join(HOME, withShot[withShot.length - 1].shot)).size;
    check(bytes > 2000, `latest png is a real image (${bytes} bytes)`);
  }

  // 6. error path must be logged, not thrown
  const before = phases().length;
  const bad = await call("bxc_act", { action: { type: "key", key: "NotAKey" } });
  check(bad.isError || /ERROR/.test(bad.text), "invalid key returns an error result");
  const afterLog = phases();
  check(afterLog.length === before + 1 && afterLog[afterLog.length - 1].ok === false, "failed call is logged as ok:false");
} catch (err) {
  failures++;
  console.log("FAIL  harness threw:", err.message);
} finally {
  child.stdin.end();
  child.kill();
}

console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
