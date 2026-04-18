/**
 * L4-2 — clippy.broadcast tool.
 *
 * Fan a single prompt out to multiple terminal tabs at once. Used when
 * Clippy's Commander decides the same instruction should hit every terminal
 * in a group (e.g., "build the project" across six tabs running different
 * repos), or a specific explicit subset.
 *
 * Target selection precedence:
 *   1. Explicit `sessionIds`: send only to these tab sessionIds
 *   2. `group`: resolve group label from fleet state and broadcast to members
 *   3. Default (no selector): broadcast to every known terminal tab
 *
 * Intent log contract (consumed by widget in L4-9 toolbar retrofit):
 *   { id, kind: "broadcast.send", prompt, targets: { mode, ids|label }, force, enqueuedAt }
 *
 * The widget's CommanderHub.BroadcastAsync is the sink. Tools here validate,
 * stamp a uuid, and queue. No fire-and-hope — every intent is durable until
 * the widget picks it up (append-only JSONL, dedup by id on the widget side).
 */
import { z } from "zod";
import { appendFile, mkdir } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname } from "node:path";
import {
  registerAppTool,
  registerAppResource,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";
import { wrapToolWithPrincipal } from "../principal.mjs";
import { wrapToolWithTelemetry } from "../telemetry.mjs";

const BROADCAST_VIEW_URI = "ui://clippy/broadcast.html";
const MAX_PROMPT_LEN = 16_384;
const MAX_TARGETS = 64;

export function registerBroadcast(server, { state, intentsPath, env = process.env } = {}) {
  const resolvedIntents = intentsPath || env.CLIPPY_COMMANDER_INTENTS_PATH || null;

  registerAppTool(
    server,
    "clippy.broadcast",
    {
      title: "Clippy Broadcast",
      description:
        "Fan a prompt out to multiple terminal tabs simultaneously. Select targets by explicit sessionIds, by group label, or leave empty to hit every tab.",
      inputSchema: {
        prompt: z
          .string()
          .min(1)
          .max(MAX_PROMPT_LEN)
          .describe("The prompt to dispatch to every selected tab."),
        sessionIds: z
          .array(z.string().min(1).max(256))
          .max(MAX_TARGETS)
          .optional()
          .describe("Explicit tab sessionIds to target. Mutually exclusive with `group`."),
        group: z
          .string()
          .min(1)
          .max(128)
          .optional()
          .describe("Link-group label. Resolves to its current members on the widget side."),
        force: z
          .boolean()
          .optional()
          .describe("Dispatch even if a tab is currently busy (default false)."),
      },
      _meta: { ui: { resourceUri: BROADCAST_VIEW_URI } },
    },
    wrapToolWithTelemetry(
      "clippy.broadcast",
      wrapToolWithPrincipal(async ({ prompt, sessionIds, group, force = false } = {}, extra) => {
        if (!resolvedIntents) {
          throw buildToolError(
            "clippy.broadcast.intents.unavailable",
            "Broadcast intents path is not configured. Set CLIPPY_COMMANDER_INTENTS_PATH or pass intentsPath when constructing the server.",
          );
        }

        if (Array.isArray(sessionIds) && sessionIds.length > 0 && group) {
          throw buildToolError(
            "clippy.broadcast.selector.conflict",
            "Specify either `sessionIds` or `group`, not both.",
          );
        }

        const targets = buildTargetSelector(sessionIds, group);
        const resolution = await previewResolution(state, targets);

        const id = randomUUID();
        const session = readSessionFromExtra(extra);
        const intent = {
          id,
          kind: "broadcast.send",
          prompt: String(prompt).slice(0, MAX_PROMPT_LEN),
          targets,
          force: Boolean(force),
          session,
          enqueuedAt: new Date().toISOString(),
        };
        await appendIntent(resolvedIntents, intent);

        const payload = {
          accepted: true,
          intentId: id,
          targets,
          resolvedTargetCount: resolution.count,
          resolvedTargetMode: resolution.mode,
          intentsPath: resolvedIntents,
        };
        return {
          content: [
            {
              type: "text",
              text: `Broadcast queued (id=${id}, mode=${resolution.mode}, targets~${resolution.count}).`,
            },
          ],
          structuredContent: payload,
        };
      }),
    ),
  );

  registerAppResource(
    server,
    "Clippy Broadcast View",
    BROADCAST_VIEW_URI,
    {
      description:
        "Select targets (explicit tabs or a group) and dispatch a prompt to them in one keystroke.",
      _meta: { ui: { csp: { resourceDomains: [], connectDomains: [] } } },
    },
    async () => ({
      contents: [
        {
          uri: BROADCAST_VIEW_URI,
          mimeType: RESOURCE_MIME_TYPE,
          text: BROADCAST_FALLBACK_HTML,
        },
      ],
    }),
  );
}

function buildTargetSelector(sessionIds, group) {
  if (Array.isArray(sessionIds) && sessionIds.length > 0) {
    return { mode: "ids", ids: sessionIds.slice(0, MAX_TARGETS) };
  }
  if (typeof group === "string" && group.trim().length > 0) {
    return { mode: "group", label: group.trim() };
  }
  return { mode: "all" };
}

async function previewResolution(state, targets) {
  if (targets.mode === "ids") {
    return { mode: "ids", count: targets.ids.length };
  }
  if (!state || typeof state.snapshot !== "function") {
    return { mode: targets.mode, count: 0 };
  }
  try {
    const snap = await state.snapshot({ includeEvents: false });
    if (targets.mode === "all") {
      return { mode: "all", count: Array.isArray(snap?.tabs?.list) ? snap.tabs.list.length : 0 };
    }
    if (targets.mode === "group") {
      const groupList = Array.isArray(snap?.groups?.list) ? snap.groups.list : [];
      const found = groupList.find(
        (g) => g && typeof g === "object" && g.label === targets.label,
      );
      if (found && Array.isArray(found.members)) {
        return { mode: "group", count: found.members.length };
      }
      return { mode: "group", count: 0 };
    }
  } catch {
    return { mode: targets.mode, count: 0 };
  }
  return { mode: targets.mode, count: 0 };
}

function readSessionFromExtra(extra) {
  if (!extra || typeof extra !== "object") return null;
  const meta = extra._meta;
  if (!meta || typeof meta !== "object") return null;
  const clippy = meta.clippy;
  if (!clippy || typeof clippy !== "object") return null;
  const session = clippy.session;
  return typeof session === "string" && session.length > 0 && session.length <= 256
    ? session
    : null;
}

async function appendIntent(path, intent) {
  try {
    await mkdir(dirname(path), { recursive: true });
  } catch {
    /* dir exists or cannot be created; let appendFile surface the error */
  }
  await appendFile(path, JSON.stringify(intent) + "\n", "utf8");
}

function buildToolError(code, message) {
  const err = new Error(`[${code}] ${message}`);
  err.code = code;
  return err;
}

const BROADCAST_FALLBACK_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/><title>Clippy Broadcast</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'"/>
<style>body{font:13px/1.4 "Segoe UI",sans-serif;margin:12px;color:#111}</style>
</head><body><h1 style="font-size:14px">Clippy Broadcast</h1>
<p style="color:#666;font-size:11px">View bundle pending. Use <code>clippy.broadcast</code> tool to dispatch.</p>
</body></html>`;

export { BROADCAST_VIEW_URI, MAX_PROMPT_LEN, MAX_TARGETS };
