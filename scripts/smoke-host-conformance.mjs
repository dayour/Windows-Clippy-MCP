/**
 * Host conformance smoke battery for Windows Clippy MCP Apps.
 *
 * Purpose:
 * - Prove what the repo can verify today, inside this environment.
 * - Separate generic MCP Apps protocol-class proof from real product-host proof.
 * - Add a real widget-host render probe, because that is the only host we can
 *   exercise end-to-end locally without relying on third-party desktop apps.
 *
 * This script intentionally does NOT claim to validate VS Code, Claude Desktop,
 * or Goose as products. It validates host classes:
 *   1. ui-capable stdio MCP Apps host
 *   2. headless/non-ui stdio MCP host
 *   3. in-repo WidgetHost WebView2 renderer
 */
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve, join } from "node:path";
import { existsSync, readFileSync, statSync } from "node:fs";
import os from "node:os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");
const SERVER_ENTRY = resolve(REPO_ROOT, "src", "mcp-apps", "server.mjs");
const WIDGET_EXE = resolve(
  REPO_ROOT,
  "widget",
  "WidgetHost",
  "bin",
  "Debug",
  "net8.0-windows",
  "WidgetHost.exe",
);
const APPDATA = process.env.APPDATA || join(os.homedir(), "AppData", "Roaming");
const WIDGET_LOG = join(APPDATA, "Windows-Clippy-MCP", "logs", "widgethost.log");

const failures = [];

function assert(cond, msg) {
  if (!cond) failures.push(msg);
  console.log(`${cond ? "PASS" : "FAIL"} ${msg}`);
}

function delay(ms) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, ms));
}

function summarize(label, facts) {
  console.log(`\n[${label}]`);
  for (const fact of facts) {
    console.log(`- ${fact}`);
  }
}

function buildClient(caps, clientName) {
  const child = spawn(process.execPath, [SERVER_ENTRY], {
    cwd: REPO_ROOT,
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      CLIPPY_TELEMETRY_SILENT: "",
    },
  });

  const pending = new Map();
  const stderrLines = [];
  let nextId = 1;
  let buffer = "";

  function send(method, params) {
    const id = nextId++;
    child.stdin.write(
      JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n",
    );
    return new Promise((resolveSend, rejectSend) => {
      pending.set(id, { resolveSend, rejectSend });
    });
  }

  function notify(method, params) {
    child.stdin.write(
      JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n",
    );
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
        const { resolveSend, rejectSend } = pending.get(obj.id);
        pending.delete(obj.id);
        if (obj.error) rejectSend(obj.error);
        else resolveSend(obj.result);
      }
    }
  });

  child.stderr.on("data", (chunk) => {
    const text = chunk.toString("utf8");
    process.stderr.write(`[${clientName}] ${text}`);
    stderrLines.push(...text.split(/\r?\n/).filter(Boolean));
  });

  async function initialize() {
    const init = await send("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: caps,
      clientInfo: { name: clientName, version: "0.0.1" },
    });
    notify("notifications/initialized", {});
    await delay(50);
    return init;
  }

  async function close() {
    try {
      child.kill("SIGTERM");
    } catch {
      /* ignore */
    }
    await delay(150);
  }

  return { send, initialize, close, stderrLines };
}

async function runUiCapableProfile() {
  const client = buildClient(
    {
      extensions: {
        "io.modelcontextprotocol/ui": {
          mimeTypes: ["text/html;profile=mcp-app"],
        },
      },
    },
    "clippy-conformance-ui-host",
  );
  try {
    const init = await client.initialize();
    assert(
      init?.serverInfo?.name === "windows-clippy-mcp-apps",
      "ui host profile: initialize returns windows-clippy-mcp-apps",
    );
    const tools = await client.send("tools/list", {});
    const resources = await client.send("resources/list", {});
    const fleetTool = tools.tools?.find((tool) => tool.name === "clippy.fleet-status");
    const fleetResource = resources.resources?.find(
      (resource) => resource.uri === "ui://clippy/fleet-status.html",
    );
    const resourceRead = await client.send("resources/read", {
      uri: "ui://clippy/fleet-status.html",
    });
    const toolCall = await client.send("tools/call", {
      name: "clippy.fleet-status",
      arguments: {},
      _meta: { clippy: { principal: "clippy", session: "host-proof-ui" } },
    });
    const negative = await client.send("tools/call", {
      name: "clippy.fleet-status",
      arguments: {},
    });
    const negativeText =
      negative?.content?.map((item) => item?.text ?? "").join(" ") ?? "";

    assert(
      tools.tools?.length >= 8,
      "ui host profile: tools/list exposes the full tool surface",
    );
    assert(
      fleetTool?._meta?.ui?.resourceUri === "ui://clippy/fleet-status.html" ||
        fleetTool?._meta?.["ui/resourceUri"] === "ui://clippy/fleet-status.html",
      "ui host profile: fleet-status advertises ui://clippy/fleet-status.html",
    );
    assert(
      !!fleetResource,
      "ui host profile: resources/list exposes ui://clippy/fleet-status.html",
    );
    assert(
      resourceRead?.contents?.[0]?.mimeType === "text/html;profile=mcp-app",
      "ui host profile: resources/read returns MCP Apps HTML MIME type",
    );
    assert(
      toolCall?.structuredContent?.principal === "clippy",
      "ui host profile: fleet-status call returns structuredContent.principal=clippy",
    );
    assert(
      negative?.isError === true &&
        /clippy\.principal\.rejected|principal/i.test(negativeText),
      "ui host profile: missing _meta.clippy is rejected",
    );
    assert(
      client.stderrLines.some((line) => /ui-apps=true/.test(line)),
      "ui host profile: server observed ui-apps=true negotiation",
    );

    summarize("ui-capable profile", [
      "Proves the stdio server behaves correctly for a generic MCP Apps host that advertises the UI extension.",
      "Does not prove any specific desktop product renders the view correctly.",
    ]);
  } finally {
    await client.close();
  }
}

async function runHeadlessProfile() {
  const client = buildClient({}, "clippy-conformance-headless-host");
  try {
    const init = await client.initialize();
    assert(
      init?.serverInfo?.name === "windows-clippy-mcp-apps",
      "headless profile: initialize succeeds without UI capability",
    );
    const tools = await client.send("tools/list", {});
    const resources = await client.send("resources/list", {});
    const toolCall = await client.send("tools/call", {
      name: "clippy.fleet-status",
      arguments: {},
      _meta: { clippy: { principal: "clippy", session: "host-proof-headless" } },
    });

    assert(
      tools.tools?.some((tool) => tool.name === "clippy.fleet-status"),
      "headless profile: tools remain callable without UI capability",
    );
    assert(
      resources.resources?.some(
        (resource) => resource.uri === "ui://clippy/fleet-status.html",
      ),
      "headless profile: ui:// resources are still listed server-side",
    );
    assert(
      toolCall?.isError !== true &&
        typeof toolCall?.structuredContent?.capturedAt === "string",
      "headless profile: read-only fleet-status succeeds with principal assertion",
    );
    assert(
      client.stderrLines.some((line) => /ui-apps=false/.test(line)),
      "headless profile: server observed ui-apps=false negotiation",
    );

    summarize("headless profile", [
      "Proves the server still works for non-UI or UI-unaware hosts.",
      "Does not prove Goose-specific preview UX, external-browser handoff, or product text rendering.",
    ]);
  } finally {
    await client.close();
  }
}

async function runWidgetProbe({
  profileName,
  resourceUri,
  expectedTexts,
}) {
  if (process.platform !== "win32") {
    console.log(`SKIP ${profileName}: non-Windows platform`);
    return;
  }
  if (!existsSync(WIDGET_EXE)) {
    assert(false, `${profileName}: missing executable at ${WIDGET_EXE}`);
    return;
  }

  const baseline = existsSync(WIDGET_LOG) ? statSync(WIDGET_LOG).size : 0;
  const widget = spawn(WIDGET_EXE, ["--no-welcome", "--apps-view", resourceUri], {
    cwd: dirname(WIDGET_EXE),
    stdio: "ignore",
    windowsHide: true,
  });

  try {
    await delay(15000);
  } finally {
    try {
      widget.kill("SIGTERM");
    } catch {
      /* ignore */
    }
    await delay(500);
  }

  const appended = existsSync(WIDGET_LOG)
    ? readFileSync(WIDGET_LOG).slice(baseline).toString("utf8")
    : "";

  assert(
    appended.includes("McpAppsBridge: handshake complete"),
    `${profileName}: bridge completed MCP handshake`,
  );
  assert(
    appended.includes("OnAppsViewInitialized: re-seeding mounted view post-handshake.") ||
      appended.includes("OnAppsViewInitialized: re-seeding mounted view post-handshake (marshalled).") ||
      appended.includes("OnAppsViewInitialized: view text dump:") ||
      appended.includes("OnAppsViewInitialized: view text dump (t+8s):"),
    `${profileName}: view completed ui/initialize handshake`,
  );
  assert(
    appended.includes("PushMountedViewToolResultToViewAsync(") &&
      appended.includes(`resource=${resourceUri}`),
    `${profileName}: host posted tool result into the WebView`,
  );
  assert(
    appended.includes("OnAppsViewInitialized: view text dump") &&
      expectedTexts.every((text) => appended.includes(text)),
    `${profileName}: rendered view text contains expected content`,
  );

  summarize(profileName, [
    `Proves the in-repo WPF/WebView2 host launches, negotiates MCP Apps, pushes tool results, and renders ${resourceUri}.`,
    "This is actual product-host evidence, not just a simulated protocol client.",
  ]);
}

async function main() {
  console.log("Windows Clippy MCP Apps host conformance smoke");
  console.log(`repo=${REPO_ROOT}`);
  console.log(`node=${process.version}`);

  await runUiCapableProfile();
  await runHeadlessProfile();
  await runWidgetProbe({
    profileName: "widget profile: fleet-status",
    resourceUri: "ui://clippy/fleet-status.html",
    expectedTexts: ["Clippy Fleet Status", "TOTAL TABS"],
  });
  await runWidgetProbe({
    profileName: "widget profile: commander",
    resourceUri: "ui://clippy/commander.html",
    expectedTexts: [
      "Clippy Commander",
      "Connected to the Commander state and submit tools through the app bridge.",
    ],
  });
  await runWidgetProbe({
    profileName: "widget profile: agent-catalog",
    resourceUri: "ui://clippy/agent-catalog.html",
    expectedTexts: [
      "Clippy Agent Catalog",
      "Search by name, id, source, or file path.",
    ],
  });

  console.log("\nAcceptance summary");
  console.log(
    "- Proven now: generic ui-capable host profile, generic headless host profile, widget render paths for fleet-status, commander, and agent-catalog.",
  );
  console.log(
    "- Not proven by this script: VS Code product UI, Claude Desktop product UI, Goose product UX.",
  );

  console.log(`\n${failures.length === 0 ? "ALL PASS" : "FAILURES: " + failures.length}`);
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error("RUNNER ERROR", error);
  process.exit(1);
});
