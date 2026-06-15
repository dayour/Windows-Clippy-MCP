/**
 * L4-6 — clippy.session-inspector tool.
 *
 * Read-only deep inspection of a single fleet entity. Given a kind + id,
 * return the full slice from the current FleetState snapshot. Supports:
 *   - kind=commander         (returns commander slice; id optional)
 *   - kind=tab, id=tabKey or legacy sessionId (returns matching tab entry)
 *   - kind=group, id=label   (returns matching group entry + member tabKeys/sessionIds)
 *   - kind=agent, id=agentId (returns matching agent catalog entry)
 *
 * The canonical debugging surface for any MCP host: "show me the raw state
 * of this thing" without having to parse the whole fleet snapshot.
 */
import { z } from "zod";
import {
  registerAppTool,
  registerAppResource,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";
import { wrapToolWithPrincipal } from "../principal.mjs";
import { wrapToolWithTelemetry } from "../telemetry.mjs";

const INSPECTOR_VIEW_URI = "ui://clippy/session-inspector.html";

export function registerSessionInspector(server, { state } = {}) {
  registerAppTool(
    server,
    "clippy.session-inspector",
    {
      title: "Clippy Session Inspector",
      description:
        "Inspect a single fleet entity (commander, tab, group, or agent) by kind + id. Read-only deep view of its current state slice.",
      inputSchema: {
        kind: z
          .enum(["commander", "tab", "group", "agent"])
          .describe("Entity kind to inspect."),
        id: z
          .string()
          .min(1)
          .max(256)
          .optional()
          .describe(
            "Identifier for the entity: tabKey (preferred) or sessionId, group label, or agent id. Optional for kind=commander.",
          ),
      },
      _meta: { ui: { resourceUri: INSPECTOR_VIEW_URI } },
    },
    wrapToolWithTelemetry(
      "clippy.session-inspector",
      wrapToolWithPrincipal(async ({ kind, id } = {}) => {
        const snap = await readSnapshot(state);
        const found = lookup(snap, kind, id);
        const payload = {
          kind,
          id: id ?? null,
          found: Boolean(found),
          entity: found,
          capturedAt: new Date().toISOString(),
        };
        return {
          content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
          structuredContent: payload,
        };
      }),
    ),
  );

  registerAppResource(
    server,
    "Clippy Session Inspector View",
    INSPECTOR_VIEW_URI,
    {
      description: "Drill into a single fleet entity (bundle pending).",
      _meta: { ui: { csp: { resourceDomains: [], connectDomains: [] } } },
    },
    async () => ({
      contents: [
        {
          uri: INSPECTOR_VIEW_URI,
          mimeType: RESOURCE_MIME_TYPE,
          text: INSPECTOR_FALLBACK_HTML,
        },
      ],
    }),
  );
}

async function readSnapshot(state) {
  if (!state || typeof state.snapshot !== "function") return null;
  try {
    return await state.snapshot({ includeEvents: false });
  } catch {
    return null;
  }
}

function lookup(snap, kind, id) {
  if (!snap) return null;
  if (kind === "commander") {
    if (!snap.commander) return null;
    if (!id || id === snap.commander.sessionId) {
      return snap.commander;
    }
    return null;
  }
  if (kind === "tab") {
    if (!id) return null;
    const list = Array.isArray(snap.tabs?.list) ? snap.tabs.list : [];
    return (
      list.find(
        (t) =>
          t &&
          typeof t === "object" &&
          (t.tabKey === id || t.sessionId === id),
      ) ?? null
    );
  }
  if (kind === "group") {
    if (!id) return null;
    const list = Array.isArray(snap.groups?.list) ? snap.groups.list : [];
    return list.find((g) => g && typeof g === "object" && g.label === id) ?? null;
  }
  if (kind === "agent") {
    if (!id) return null;
    const list = Array.isArray(snap.agents?.catalog) ? snap.agents.catalog : [];
    return list.find((a) => a && typeof a === "object" && a.id === id) ?? null;
  }
  return null;
}

const INSPECTOR_FALLBACK_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/><title>Clippy Session Inspector</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'"/>
<style>body{font:13px/1.4 "Segoe UI",sans-serif;margin:12px;color:#111}</style>
</head><body><h1 style="font-size:14px">Clippy Session Inspector</h1>
<p style="color:#666;font-size:11px">View bundle pending. Use <code>clippy.session-inspector</code> tool with kind + id.</p>
</body></html>`;

export { INSPECTOR_VIEW_URI };
