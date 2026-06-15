/**
 * L2-4/L2-2 smoke test: boot the Apps server over stdio and exchange
 * the minimum protocol handshake (initialize + tools/list + resources/list).
 *
 * This is not a vitest test — it's a standalone node script that proves
 * the server correctly serves a Clippy tool and a ui:// resource via
 * StdioServerTransport. Vitest suite lands in L2-7.
 */
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SERVER_ENTRY = resolve(__dirname, "..", "src", "mcp-apps", "server.mjs");

const child = spawn(process.execPath, [SERVER_ENTRY], {
  stdio: ["pipe", "pipe", "pipe"],
});

const pending = new Map();
let nextId = 1;
let buffer = "";

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

child.stderr.on("data", (c) => process.stderr.write("[server] " + c));

const failures = [];
function assert(cond, msg) {
  if (!cond) failures.push(msg);
  console.log(`${cond ? "PASS" : "FAIL"} ${msg}`);
}

async function run() {
  const init = await send("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {
      extensions: {
        "io.modelcontextprotocol/ui": {
          mimeTypes: ["text/html;profile=mcp-app"],
        },
      },
    },
    clientInfo: { name: "clippy-smoke", version: "0.0.1" },
  });
  assert(init?.serverInfo?.name === "windows-clippy-mcp-apps", "serverInfo.name");
  assert(init?.serverInfo?.version === "0.2.0", "serverInfo.version");
  assert(!!init?.capabilities?.tools, "tools capability advertised");
  assert(!!init?.capabilities?.resources, "resources capability advertised");

  notify("notifications/initialized", {});

  const tools = await send("tools/list", {});
  const fleet = tools.tools?.find((t) => t.name === "clippy.fleet-status");
  assert(!!fleet, "tools/list contains clippy.fleet-status");
  const uiMeta =
    fleet?._meta?.ui?.resourceUri || fleet?._meta?.["ui/resourceUri"];
  assert(
    uiMeta === "ui://clippy/fleet-status.html",
    `tool carries ui resourceUri (got ${uiMeta})`,
  );

  const resources = await send("resources/list", {});
  const fleetRes = resources.resources?.find(
    (r) => r.uri === "ui://clippy/fleet-status.html",
  );
  assert(!!fleetRes, "resources/list contains ui://clippy/fleet-status.html");

  const read = await send("resources/read", {
    uri: "ui://clippy/fleet-status.html",
  });
  const body = read.contents?.[0];
  assert(body?.mimeType === "text/html;profile=mcp-app", "resource MIME type");
  assert(
    typeof body?.text === "string" && body.text.includes("<html"),
    "resource body is HTML",
  );

  const callResult = await send("tools/call", {
    name: "clippy.fleet-status",
    arguments: {},
    _meta: { clippy: { principal: "clippy", session: "smoke-session" } },
  });
  const structured = callResult.structuredContent;
  assert(structured?.principal === "clippy", "tool structuredContent.principal");
  assert(
    typeof structured?.capturedAt === "string",
    "tool structuredContent.capturedAt is ISO string",
  );

  // Negative: tools/call without _meta.clippy must be rejected by L3-6 guard.
  // MCP SDK converts a thrown handler error into { isError: true, content: [...] }
  // rather than a JSON-RPC error envelope, so we inspect the result shape.
  const negative = await send("tools/call", {
    name: "clippy.fleet-status",
    arguments: {},
  });
  const negativeText = negative?.content?.map((c) => c?.text ?? "").join(" ") ?? "";
  assert(
    negative?.isError === true,
    "tools/call without _meta.clippy is flagged isError",
  );
  assert(
    /clippy\.principal\.rejected|principal/i.test(negativeText),
    `rejection carries principal error (got ${negativeText.slice(0, 120)})`,
  );

  child.kill("SIGTERM");
}

run()
  .then(() => {
    setTimeout(() => {
      console.log(
        `\n${failures.length === 0 ? "ALL PASS" : "FAILURES: " + failures.length}`,
      );
      process.exit(failures.length === 0 ? 0 : 1);
    }, 100);
  })
  .catch((err) => {
    console.error("RUNNER ERROR", err);
    child.kill("SIGTERM");
    process.exit(1);
  });
