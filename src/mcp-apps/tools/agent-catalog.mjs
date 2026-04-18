/**
 * L4-5 — clippy.agent-catalog tool.
 *
 * Enumerate the bundled + user agents available to Clippy's Commander and
 * terminal fleet. View bundle (`ui://clippy/agent-catalog.html`) ships in a
 * follow-up; this module exposes the tool + resource skeleton so any host
 * can list agents and (in future) trigger an agent switch via
 * `clippy.commander.submit` with a /agent slash.
 */
import { z } from "zod";
import {
  registerAppTool,
  registerAppResource,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";
import { wrapToolWithPrincipal } from "../principal.mjs";
import { wrapToolWithTelemetry } from "../telemetry.mjs";

const AGENT_CATALOG_VIEW_URI = "ui://clippy/agent-catalog.html";

export function registerAgentCatalog(server, { state } = {}) {
  registerAppTool(
    server,
    "clippy.agent-catalog",
    {
      title: "Clippy Agent Catalog",
      description:
        "List every agent available to Clippy's Commander and fleet (bundled + user), including display names and active flag.",
      inputSchema: {
        filter: z.string().max(128).optional().describe("Substring match on agent id or display name."),
        limit: z.number().int().min(1).max(500).optional().describe("Trim the returned list."),
      },
      _meta: { ui: { resourceUri: AGENT_CATALOG_VIEW_URI } },
    },
    wrapToolWithTelemetry(
      "clippy.agent-catalog",
      wrapToolWithPrincipal(async ({ filter, limit } = {}) => {
        const snapshot = state && typeof state.snapshot === "function"
          ? await state.snapshot({ includeEvents: false })
          : null;
        const raw = Array.isArray(snapshot?.agents?.catalog) ? snapshot.agents.catalog : [];
        const active = snapshot?.agents?.active ?? null;
        const filtered = filter
          ? raw.filter((a) => {
              const hay = `${a.id || ""} ${a.displayName || ""}`.toLowerCase();
              return hay.includes(String(filter).toLowerCase());
            })
          : raw;
        const clipped = typeof limit === "number" ? filtered.slice(0, limit) : filtered;
        const payload = {
          active,
          catalogSize: raw.length,
          returned: clipped.length,
          agents: clipped,
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
    "Clippy Agent Catalog View",
    AGENT_CATALOG_VIEW_URI,
    {
      description: "Browseable list of Clippy agents (stub view; bundle pending).",
      _meta: { ui: { csp: { resourceDomains: [], connectDomains: [] } } },
    },
    async () => ({
      contents: [
        {
          uri: AGENT_CATALOG_VIEW_URI,
          mimeType: RESOURCE_MIME_TYPE,
          text: CATALOG_FALLBACK_HTML,
        },
      ],
    }),
  );
}

const CATALOG_FALLBACK_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/><title>Clippy Agents</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'"/>
<style>body{font:13px/1.4 "Segoe UI",sans-serif;margin:12px;color:#111}</style>
</head><body><h1 style="font-size:14px">Clippy Agents</h1>
<p style="color:#666;font-size:11px">View bundle pending. Use <code>clippy.agent-catalog</code> tool for data.</p>
</body></html>`;

export { AGENT_CATALOG_VIEW_URI };
