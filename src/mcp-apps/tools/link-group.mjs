/**
 * L4-3 — clippy.link-group tool.
 *
 * Manage Commander link groups: labeled collections of terminal tabs that
 * share a keystroke broadcast. Operations:
 *   - list      -> read-only view of every group + members (from fleet state)
 *   - link      -> attach a tab to a (new or existing) group
 *   - unlink    -> detach a tab from its current group
 *   - broadcast -> dispatch a prompt to every member of a group
 *
 * Write operations queue an intent to CLIPPY_COMMANDER_INTENTS_PATH that the
 * widget's CommanderHub consumes. Read operations serve directly from the
 * FleetState snapshot.
 *
 * Intent kinds:
 *   { id, kind: "linkgroup.link", principal, session, tabKey, sessionId, label, enqueuedAt }
 *   { id, kind: "linkgroup.unlink", principal, session, tabKey, sessionId, enqueuedAt }
 *   { id, kind: "linkgroup.broadcast", principal, session, label, prompt, force, enqueuedAt }
 */
import { z } from "zod";
import {
  registerAppTool,
  registerAppResource,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";
import { appendIntent, buildIntentEnvelope } from "../intent-envelope.mjs";
import { wrapToolWithPrincipal } from "../principal.mjs";
import { wrapToolWithTelemetry } from "../telemetry.mjs";

const LINK_GROUP_VIEW_URI = "ui://clippy/link-group.html";
const MAX_LABEL_LEN = 128;
const MAX_PROMPT_LEN = 16_384;

export function registerLinkGroup(server, { state, intentsPath, env = process.env } = {}) {
  const resolvedIntents = intentsPath || env.CLIPPY_COMMANDER_INTENTS_PATH || null;

  registerAppTool(
    server,
    "clippy.link-group",
    {
      title: "Clippy Link Group",
      description:
        "Manage Commander link groups (labeled groups of terminal tabs that share broadcast input). Supports list/link/unlink/broadcast operations.",
      inputSchema: {
        op: z
          .enum(["list", "link", "unlink", "broadcast"])
          .describe("Operation to perform."),
        tabKey: z
          .string()
          .min(1)
          .max(128)
          .optional()
          .describe("Canonical target widget tabKey (required for link/unlink unless legacy sessionId is supplied)."),
        sessionId: z
          .string()
          .min(1)
          .max(256)
          .optional()
          .describe("Legacy target terminal sessionId (accepted for compatibility; tabKey is preferred)."),
        label: z
          .string()
          .min(1)
          .max(MAX_LABEL_LEN)
          .optional()
          .describe("Group label (required for link and broadcast)."),
        prompt: z
          .string()
          .min(1)
          .max(MAX_PROMPT_LEN)
          .optional()
          .describe("Prompt to broadcast to group members (required for op=broadcast)."),
        force: z
          .boolean()
          .optional()
          .describe("Dispatch broadcast even to busy tabs (default false)."),
      },
      _meta: { ui: { resourceUri: LINK_GROUP_VIEW_URI } },
    },
    wrapToolWithTelemetry(
      "clippy.link-group",
      wrapToolWithPrincipal(async (args, extra) => {
        const { op, tabKey, sessionId, label, prompt, force = false } = args ?? {};

        if (op === "list") {
          return handleList(state);
        }

        if (!resolvedIntents) {
          throw buildToolError(
            "clippy.link-group.intents.unavailable",
            "Link-group intents path is not configured. Set CLIPPY_COMMANDER_INTENTS_PATH or pass intentsPath.",
          );
        }

        if (op === "link") {
          requireTarget(tabKey, sessionId, "link");
          requireArg(label, "label", "link");
          return queueIntent(resolvedIntents, extra, {
            kind: "linkgroup.link",
            tabKey,
            sessionId,
            label: label.trim(),
          });
        }

        if (op === "unlink") {
          requireTarget(tabKey, sessionId, "unlink");
          return queueIntent(resolvedIntents, extra, {
            kind: "linkgroup.unlink",
            tabKey,
            sessionId,
          });
        }

        if (op === "broadcast") {
          requireArg(label, "label", "broadcast");
          requireArg(prompt, "prompt", "broadcast");
          return queueIntent(resolvedIntents, extra, {
            kind: "linkgroup.broadcast",
            label: label.trim(),
            prompt: String(prompt).slice(0, MAX_PROMPT_LEN),
            force: Boolean(force),
          });
        }

        throw buildToolError(
          "clippy.link-group.op.invalid",
          `Unknown op ${JSON.stringify(op)}.`,
        );
      }),
    ),
  );

  registerAppResource(
    server,
    "Clippy Link Group View",
    LINK_GROUP_VIEW_URI,
    {
      description: "Browse + mutate link groups (bundle pending).",
      _meta: { ui: { csp: { resourceDomains: [], connectDomains: [] } } },
    },
    async () => ({
      contents: [
        {
          uri: LINK_GROUP_VIEW_URI,
          mimeType: RESOURCE_MIME_TYPE,
          text: LINK_GROUP_FALLBACK_HTML,
        },
      ],
    }),
  );
}

async function handleList(state) {
  let snap = null;
  if (state && typeof state.snapshot === "function") {
    try {
      snap = await state.snapshot({ includeEvents: false });
    } catch {
      snap = null;
    }
  }
  const groups = Array.isArray(snap?.groups?.list) ? snap.groups.list : [];
  const payload = {
    total: groups.length,
    active: snap?.groups?.active ?? null,
    groups,
    capturedAt: new Date().toISOString(),
  };
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    structuredContent: payload,
  };
}

async function queueIntent(path, extra, intent) {
  const entry = buildIntentEnvelope(intent.kind, intent, extra);
  await appendIntent(path, entry);
  const payload = { accepted: true, intentId: entry.id, kind: intent.kind, intentsPath: path };
  return {
    content: [{ type: "text", text: `Link-group intent queued (id=${entry.id}, kind=${intent.kind}).` }],
    structuredContent: payload,
  };
}

function requireArg(value, name, op) {
  if (value === undefined || value === null || (typeof value === "string" && value.trim().length === 0)) {
    throw buildToolError(
      "clippy.link-group.arg.missing",
      `Operation ${op} requires argument ${name}.`,
    );
  }
}

function requireTarget(tabKey, sessionId, op) {
  if (
    (typeof tabKey === "string" && tabKey.trim().length > 0) ||
    (typeof sessionId === "string" && sessionId.trim().length > 0)
  ) {
    return;
  }

  throw buildToolError(
    "clippy.link-group.arg.missing",
    `Operation ${op} requires tabKey (preferred) or legacy sessionId.`,
  );
}

function buildToolError(code, message) {
  const err = new Error(`[${code}] ${message}`);
  err.code = code;
  return err;
}

const LINK_GROUP_FALLBACK_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/><title>Clippy Link Groups</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'"/>
<style>body{font:13px/1.4 "Segoe UI",sans-serif;margin:12px;color:#111}</style>
</head><body><h1 style="font-size:14px">Clippy Link Groups</h1>
<p style="color:#666;font-size:11px">View bundle pending. Use <code>clippy.link-group</code> tool with op=list/link/unlink/broadcast.</p>
</body></html>`;

export { LINK_GROUP_VIEW_URI, MAX_LABEL_LEN, MAX_PROMPT_LEN };
