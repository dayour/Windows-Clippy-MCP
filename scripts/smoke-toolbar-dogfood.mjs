/**
 * L5-5 toolbar dogfood smoke battery.
 *
 * Exercises the mutating Commander MCP Apps tools end-to-end (submit,
 * broadcast, link/unlink, session-inspector) and validates that every
 * intent written to commander-intents.jsonl conforms to the protocol
 * envelope documented in docs/mcp-apps/protocol.md:
 *
 *     { id, kind, principal, session, enqueuedAt, ...kind-specific }
 *
 * Pattern mirrors scripts/smoke-apps-server.mjs: spawn the stdio
 * MCP Apps server, run the initialize / notifications/initialized
 * handshake, call each tool with a valid _meta.clippy principal, then
 * read the JSONL file back and assert schema conformance per record.
 *
 * Exit code:
 *   0 -- all assertions passed
 *   1 -- at least one assertion failed (details on stderr)
 *
 * The script does NOT modify production code; it consumes the installed
 * server.mjs exactly as any external MCP Apps host would.
 */
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve, join } from "node:path";
import { readFileSync, existsSync, mkdirSync, writeFileSync, statSync } from "node:fs";
import { randomUUID } from "node:crypto";
import os from "node:os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");
const SERVER_ENTRY = resolve(REPO_ROOT, "src", "mcp-apps", "server.mjs");

// Must match widget McpAppsBridge.BuildCommanderIntentsPath():
// %LOCALAPPDATA%\WindowsClippy\commander-intents.jsonl
const LOCAL_APPDATA =
  process.env.LOCALAPPDATA || join(os.homedir(), "AppData", "Local");
const INTENTS_PATH = join(
  LOCAL_APPDATA,
  "WindowsClippy",
  "commander-intents.jsonl",
);

// Ensure the directory exists and the file is present (same contract the
// widget enforces via EnsureCommanderIntentsFile). We do NOT truncate:
// the smoke test appends and then validates only the new tail.
mkdirSync(dirname(INTENTS_PATH), { recursive: true });
if (!existsSync(INTENTS_PATH)) {
  writeFileSync(INTENTS_PATH, "", "utf8");
}
const baselineSize = statSync(INTENTS_PATH).size;

const child = spawn(process.execPath, [SERVER_ENTRY], {
  stdio: ["pipe", "pipe", "pipe"],
  env: {
    ...process.env,
    CLIPPY_COMMANDER_INTENTS_PATH: INTENTS_PATH,
    CLIPPY_TELEMETRY_SILENT: "", // keep telemetry stderr visible
  },
});

const pending = new Map();
let nextId = 1;
let buffer = "";
const telemetryEvents = [];

function send(method, params) {
  const id = nextId++;
  const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });
  child.stdin.write(msg + "\n");
  return new Promise((res, rej) => pending.set(id, { res, rej }));
}

function notify(method, params) {
  const msg = JSON.stringify({ jsonrpc: "2.0", method, params });
  child.stdin.write(msg + "\n");
}

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  let idx;
  while ((idx = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj.id != null && pending.has(obj.id)) {
      const { res, rej } = pending.get(obj.id);
      pending.delete(obj.id);
      if (obj.error) rej(obj.error);
      else res(obj.result);
    }
  }
});

child.stderr.on("data", (c) => {
  const s = c.toString("utf8");
  process.stderr.write("[server] " + s);
  for (const line of s.split("\n")) {
    const match = line.match(/\[clippy-telemetry\]\s*(\{.*\})/);
    if (match) {
      try {
        telemetryEvents.push(JSON.parse(match[1]));
      } catch {
        /* ignore malformed telemetry line */
      }
    }
  }
});

const failures = [];
function assert(cond, msg) {
  if (!cond) failures.push(msg);
  console.log(`${cond ? "PASS" : "FAIL"} ${msg}`);
}

const SESSION = "smoke-session-" + randomUUID().slice(0, 8);
const CLIPPY_META = {
  clippy: { principal: "clippy", session: SESSION },
};

async function callTool(name, args, opts = {}) {
  const includeMeta = opts.includeMeta !== false;
  const payload = { name, arguments: args };
  if (includeMeta) payload._meta = CLIPPY_META;
  return send("tools/call", payload);
}

async function run() {
  // Handshake
  const init = await send("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {
      extensions: {
        "io.modelcontextprotocol/ui": {
          mimeTypes: ["text/html;profile=mcp-app"],
        },
      },
    },
    clientInfo: { name: "clippy-smoke-toolbar", version: "0.0.1" },
  });
  assert(
    init?.serverInfo?.name === "windows-clippy-mcp-apps",
    "serverInfo.name is windows-clippy-mcp-apps",
  );
  notify("notifications/initialized", {});

  // 1. clippy.commander.submit
  // Protocol declares the canonical Commander modes Agent|Plan|Swarm.
  // Legacy "code" is intentionally rejected.
  const submitRes = await callTool("clippy.commander.submit", {
    prompt: "smoke test",
    mode: "Swarm",
  });
  assert(
    !submitRes?.isError && submitRes?.structuredContent?.accepted === true,
    "clippy.commander.submit returned accepted=true",
  );

  // 2. clippy.broadcast (sessionIds selector).
  const broadcastRes = await callTool("clippy.broadcast", {
    prompt: "fleet hi",
    sessionIds: ["pane-1", "pane-2"],
  });
  assert(
    !broadcastRes?.isError && broadcastRes?.structuredContent?.accepted === true,
    "clippy.broadcast returned accepted=true",
  );

  // 3. clippy.link-group op=link
  const linkRes = await callTool("clippy.link-group", {
    op: "link",
    sessionId: "pane-1",
    label: "engineering",
  });
  assert(
    !linkRes?.isError && linkRes?.structuredContent?.accepted === true,
    "clippy.link-group op=link returned accepted=true",
  );

  // 4. clippy.link-group op=unlink
  const unlinkRes = await callTool("clippy.link-group", {
    op: "unlink",
    sessionId: "pane-1",
  });
  assert(
    !unlinkRes?.isError && unlinkRes?.structuredContent?.accepted === true,
    "clippy.link-group op=unlink returned accepted=true",
  );

  // 5. clippy.session-inspector (read-only; does NOT emit an intent)
  const inspectRes = await callTool("clippy.session-inspector", {
    kind: "tab",
    id: "pane-1",
  });
  assert(
    !inspectRes?.isError,
    "clippy.session-inspector returned a non-error result",
  );
  assert(
    inspectRes?.structuredContent !== undefined ||
      Array.isArray(inspectRes?.content),
    "clippy.session-inspector returned structuredContent or content",
  );

  // 6. Negative: omit _meta.clippy -> principal rejection
  const negative = await callTool(
    "clippy.commander.submit",
    { prompt: "should be rejected" },
    { includeMeta: false },
  );
  const negativeText =
    negative?.content?.map((c) => c?.text ?? "").join(" ") ?? "";
  assert(
    negative?.isError === true,
    "tools/call without _meta.clippy flagged isError=true",
  );
  assert(
    /clippy\.principal\.rejected|principal/i.test(negativeText),
    `principal rejection carries principal error text (got: ${negativeText.slice(0, 140)})`,
  );

  // Allow file-system flush
  await new Promise((r) => setTimeout(r, 200));

  child.kill("SIGTERM");
  await new Promise((r) => setTimeout(r, 200));
}

function readNewIntents() {
  const stat = statSync(INTENTS_PATH);
  if (stat.size <= baselineSize) return [];
  const buf = readFileSync(INTENTS_PATH, "utf8");
  // Slice from baseline byte offset; Node read is utf8-decoded so recompute
  // by scanning lines instead.
  const allLines = buf.split("\n").filter((l) => l.trim().length > 0);
  // Crude but safe: re-read only the tail since baselineSize bytes.
  const fd = readFileSync(INTENTS_PATH);
  const tail = fd.slice(baselineSize).toString("utf8");
  return tail
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l, idx) => {
      try {
        return { raw: l, parsed: JSON.parse(l), lineNo: idx + 1 };
      } catch (err) {
        return { raw: l, parseError: err.message, lineNo: idx + 1 };
      }
    });
}

function validateEnvelope(rec) {
  const errs = [];
  const o = rec.parsed;
  if (!o || typeof o !== "object") {
    errs.push("record is not a JSON object");
    return errs;
  }
  if (typeof o.id !== "string" || o.id.length < 8) {
    errs.push(`id missing or too short (got: ${JSON.stringify(o.id)})`);
  }
  if (typeof o.kind !== "string" || !o.kind) {
    errs.push(`kind missing (got: ${JSON.stringify(o.kind)})`);
  }
  if (o.principal !== "clippy") {
    errs.push(`principal must equal "clippy" (got: ${JSON.stringify(o.principal)})`);
  }
  if (!("session" in o)) {
    errs.push("session field missing (required by protocol.md)");
  } else if (o.session !== SESSION) {
    errs.push(`session must equal caller Commander session ${SESSION} (got: ${JSON.stringify(o.session)})`);
  }
  if (typeof o.enqueuedAt !== "string") {
    errs.push(`enqueuedAt missing or not string (got: ${typeof o.enqueuedAt})`);
  } else if (Number.isNaN(Date.parse(o.enqueuedAt))) {
    errs.push(`enqueuedAt not parseable as DateTime (got: ${o.enqueuedAt})`);
  }
  // linkgroup.* kinds must preserve sessionId alongside session (per
  // NormalizeIntentJson contract and task requirement).
  if (typeof o.kind === "string" && o.kind.startsWith("linkgroup.")) {
    if (o.kind === "linkgroup.link" || o.kind === "linkgroup.unlink") {
      if (typeof o.sessionId !== "string" || !o.sessionId) {
        errs.push(`${o.kind} missing sessionId pass-through`);
      }
    }
  }
  return errs;
}

run()
  .then(() => {
    setTimeout(() => {
      console.log("\n--- Intent envelope validation ---");
      const records = readNewIntents();
      console.log(`New intents appended this run: ${records.length}`);
      let conformant = 0;
      for (const rec of records) {
        if (rec.parseError) {
          assert(false, `line ${rec.lineNo} failed to parse: ${rec.parseError}`);
          continue;
        }
        const errs = validateEnvelope(rec);
        const kind = rec.parsed?.kind ?? "<no-kind>";
        if (errs.length === 0) {
          conformant++;
          assert(true, `intent ${rec.lineNo} kind=${kind} schema conformant`);
        } else {
          for (const e of errs) {
            assert(false, `intent ${rec.lineNo} kind=${kind}: ${e}`);
          }
        }
      }

      // Expected intent count: 4 mutating tool calls (commander.submit,
      // broadcast.send, linkgroup.link, linkgroup.unlink). The negative-path
      // call is rejected before any write, session-inspector is read-only.
      assert(
        records.length >= 4,
        `wrote >= 4 intents this run (actual: ${records.length})`,
      );

      console.log("\n--- Telemetry summary ---");
      const toolStarts = telemetryEvents.filter(
        (e) => e?.event === "tool.start",
      ).length;
      const toolEnds = telemetryEvents.filter(
        (e) => e?.event === "tool.end",
      ).length;
      console.log(
        `telemetry events: start=${toolStarts} end=${toolEnds} total=${telemetryEvents.length}`,
      );
      assert(
        toolStarts >= 6 && toolEnds >= 6,
        `telemetry observed tool.start>=6 and tool.end>=6 (got start=${toolStarts} end=${toolEnds})`,
      );

      console.log(
        `\n${failures.length === 0 ? "ALL PASS" : "FAILURES: " + failures.length}`,
      );
      console.log(
        `SUMMARY intents_validated=${records.length} schema_conformant=${conformant} telemetry_start=${toolStarts} telemetry_end=${toolEnds} assertions_failed=${failures.length}`,
      );
      process.exit(failures.length === 0 ? 0 : 1);
    }, 150);
  })
  .catch((err) => {
    console.error("RUNNER ERROR", err);
    try {
      child.kill("SIGTERM");
    } catch {}
    process.exit(1);
  });
