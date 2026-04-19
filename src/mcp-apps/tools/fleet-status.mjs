/**
 * clippy.fleet-status — first MCP App tool (L2-2).
 *
 * Returns current Commander fleet state as structured content AND references
 * ui://clippy/fleet-status.html for hosts that can render the View.
 *
 * State access: via a BridgeState snapshot (L2-5). For this foundational
 * scaffold the state fallback is deterministic so unit tests (L2-7) can
 * snapshot both the structured result and the resource HTML.
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { z } from "zod";
import {
  registerAppTool,
  registerAppResource,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";
import { wrapToolWithPrincipal } from "../principal.mjs";
import { wrapToolWithTelemetry } from "../telemetry.mjs";

const RESOURCE_URI = "ui://clippy/fleet-status.html";

const __dirname = dirname(fileURLToPath(import.meta.url));
const VIEW_BUNDLE_PATH = resolve(
  __dirname,
  "..",
  "..",
  "..",
  "dist",
  "mcp-apps",
  "views",
  "fleet-status.html",
);
const VIEW_FALLBACK_PATH = resolve(
  __dirname,
  "..",
  "views",
  "fleet-status",
  "fallback.html",
);

const EMPTY_FLEET_SNAPSHOT = Object.freeze({
  principal: "clippy",
  sessionId: null,
  tabs: { total: 0, byState: { idle: 0, running: 0, exited: 0 } },
  groups: { total: 0, active: null },
  agents: { catalogSize: 0, active: null, catalog: [] },
  events: { recent: [] },
  capturedAt: null,
});

export function registerFleetStatus(server, { state } = {}) {
  registerAppTool(
    server,
    "clippy.fleet-status",
    {
      title: "Clippy Fleet Status",
      description:
        "Return the current Commander fleet state (tabs, groups, agent catalog) for Clippy's orchestration view.",
      inputSchema: {
        includeEvents: z
          .boolean()
          .optional()
          .describe("Include the 20 most recent Commander events"),
      },
      _meta: {
        ui: {
          resourceUri: RESOURCE_URI,
        },
      },
    },
    wrapToolWithTelemetry(
      "clippy.fleet-status",
      wrapToolWithPrincipal(async ({ includeEvents = false } = {}) => {
        const snapshot = await captureFleet(state, { includeEvents });
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(snapshot, null, 2),
            },
          ],
          structuredContent: snapshot,
        };
      }),
    ),
  );

  registerAppResource(
    server,
    "Fleet Status View",
    RESOURCE_URI,
    {
      description:
        "Interactive Clippy fleet orchestration panel. Live tab/group/agent counters.",
      _meta: {
        ui: {
          csp: {
            resourceDomains: [],
            connectDomains: [],
          },
        },
      },
    },
    async () => {
      const html = await readViewHtml();
      return {
        contents: [
          {
            uri: RESOURCE_URI,
            mimeType: RESOURCE_MIME_TYPE,
            text: html,
          },
        ],
      };
    },
  );
}

async function captureFleet(state, { includeEvents }) {
  if (state && typeof state.snapshot === "function") {
    try {
      const snap = await state.snapshot({ includeEvents });
      return { ...snap, capturedAt: new Date().toISOString() };
    } catch (err) {
      return {
        ...EMPTY_FLEET_SNAPSHOT,
        capturedAt: new Date().toISOString(),
        error: `bridge-state unavailable: ${err?.message || String(err)}`,
      };
    }
  }
  return {
    ...EMPTY_FLEET_SNAPSHOT,
    capturedAt: new Date().toISOString(),
    error: "bridge-state not wired (L2-5 pending)",
  };
}

async function readViewHtml() {
  for (const candidate of [VIEW_BUNDLE_PATH, VIEW_FALLBACK_PATH]) {
    try {
      return await readFile(candidate, "utf-8");
    } catch (err) {
      if (err?.code !== "ENOENT") throw err;
    }
  }
  return DEFAULT_FALLBACK_HTML;
}

const DEFAULT_FALLBACK_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Clippy Fleet Status</title>
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'" />
  <style>
    body { font: 13px/1.4 "Segoe UI", sans-serif; margin: 12px; color: #111; background: #fff; }
    h1 { font-size: 14px; margin: 0 0 8px; }
    p.note { color: #666; font-size: 11px; margin: 0 0 8px; }
  </style>
</head>
<body>
  <h1>Clippy Fleet Status</h1>
  <p class="note">View bundle not yet built. Run <code>npm run build:views</code> to produce the real interactive panel.</p>
</body>
</html>
`;

export { RESOURCE_URI, EMPTY_FLEET_SNAPSHOT };
