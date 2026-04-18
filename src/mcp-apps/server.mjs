/**
 * Windows Clippy MCP Apps Server — stdio entry (L2-4)
 *
 * Serves Commander orchestration tools + UIResources to any MCP Apps host
 * (Claude Desktop, VS Code, ChatGPT, in-widget McpAppsHost).
 *
 * Invocation:
 *   node src/mcp-apps/server.mjs
 *   npx @dayour/windows-clippy-mcp --apps --stdio
 *
 * SDK evidence:
 *   @modelcontextprotocol/ext-apps/server -> registerAppTool, registerAppResource, getUiCapability
 *   (dist/src/server/index.d.ts lines 183, 308, 358; verified in L1 Boss gate v2 PASS)
 *
 * Principal: Clippy (the Commander session), not the human operator.
 * Every tool invocation resolves its principal to the active Commander session id
 * via bridge-state (L2-5). No tool accepts an unauthenticated principal.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  registerAppTool,
  registerAppResource,
  getUiCapability,
  RESOURCE_MIME_TYPE,
  EXTENSION_ID,
} from "@modelcontextprotocol/ext-apps/server";

import { registerFleetStatus } from "./tools/fleet-status.mjs";
import { registerCommander } from "./tools/commander.mjs";
import { registerAgentCatalog } from "./tools/agent-catalog.mjs";
import { registerBroadcast } from "./tools/broadcast.mjs";
import { registerLinkGroup } from "./tools/link-group.mjs";
import { registerSessionInspector } from "./tools/session-inspector.mjs";
import { registerTelemetry } from "./tools/telemetry.mjs";
import { FleetState } from "./bridge-state.mjs";

const SERVER_INFO = {
  name: "windows-clippy-mcp-apps",
  version: "0.2.0",
};

/**
 * Build a fully-registered MCP Apps server instance, without connecting a transport.
 * Exposed for tests (Vitest in L2-7) and for in-process embedding inside the widget (L3).
 */
export function createAppsServer({ state } = {}) {
  const server = new McpServer(SERVER_INFO, {
    capabilities: {
      tools: {},
      resources: { subscribe: false, listChanged: true },
      logging: {},
    },
    instructions:
      "Windows Clippy MCP Apps server. Principal is the Clippy Commander session. " +
      "Tools return structured content plus ui:// resources for interactive Views.",
  });

  const fleetState = state ?? new FleetState();
  registerFleetStatus(server, { state: fleetState });
  registerCommander(server, { state: fleetState });
  registerAgentCatalog(server, { state: fleetState });
  registerBroadcast(server, { state: fleetState });
  registerLinkGroup(server, { state: fleetState });
  registerSessionInspector(server, { state: fleetState });
  registerTelemetry(server);

  server.server.oninitialized = () => {
    const clientCaps = server.server.getClientCapabilities();
    const uiCap = getUiCapability(clientCaps);
    const supports = Boolean(uiCap?.mimeTypes?.includes(RESOURCE_MIME_TYPE));
    logToStderr(
      `client capabilities negotiated extension=${EXTENSION_ID} ui-apps=${supports}`,
    );
  };

  return server;
}

/**
 * CLI entry: connect to stdio and block until the transport closes.
 */
export async function main() {
  const server = createAppsServer();
  const transport = new StdioServerTransport();

  process.on("SIGINT", () => {
    void server.close().finally(() => process.exit(0));
  });
  process.on("SIGTERM", () => {
    void server.close().finally(() => process.exit(0));
  });

  await server.connect(transport);
  logToStderr(`${SERVER_INFO.name}@${SERVER_INFO.version} listening on stdio`);
}

function logToStderr(line) {
  process.stderr.write(`[clippy-apps] ${line}\n`);
}

const isDirectInvocation =
  import.meta.url === `file://${process.argv[1]?.replace(/\\/g, "/")}` ||
  (process.argv[1] && process.argv[1].endsWith("server.mjs"));

if (isDirectInvocation) {
  main().catch((err) => {
    logToStderr(`fatal: ${err?.stack || err?.message || String(err)}`);
    process.exit(1);
  });
}

export { SERVER_INFO };
