/**
 * L4-1 — clippy.commander tool trio.
 *
 * Exposes Clippy's independent Commander session (the orchestrator that
 * reasons, delegates, and drives the tab fleet) as an MCP App surface. The
 * Commander is NOT the terminal — it has its own LLM session, its own
 * conversation history, and its own principal. Sending a prompt here goes
 * to Clippy-the-agent, which then decides whether to spawn a tab, broadcast,
 * link a group, or reply inline.
 *
 * State flow (read):
 *   Widget CommanderSession -> MainWindow.BuildFleetSnapshot (commander slice)
 *     -> fleet-state.json -> FleetState.snapshot().commander -> this tool
 *
 * Intent flow (write):
 *   External host / view -> clippy.commander.submit tool -> append JSON line
 *   to CLIPPY_COMMANDER_INTENTS_PATH -> widget FileSystemWatcher picks up ->
 *   CommanderSession.TrySubmitPrompt. Append-only log so the widget can
 *   replay and de-duplicate via intent id.
 *
 * Contract:
 *   { id, kind: "commander.submit", principal, session, prompt, mode, enqueuedAt }
 *
 * The view (`ui://clippy/commander.html`) is wired in L4-commander-view; this
 * module ships the tool + resource skeleton so conformance tests can already
 * verify the shape. The view currently returns the fleet-status fallback
 * until the dedicated view bundle lands.
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
import {
  appendIntent,
  buildIntentEnvelope,
  COMMANDER_MODES,
} from "../intent-envelope.mjs";
import { wrapToolWithPrincipal } from "../principal.mjs";
import { wrapToolWithTelemetry } from "../telemetry.mjs";

const COMMANDER_VIEW_URI = "ui://clippy/commander.html";
const MAX_PROMPT_LEN = 16_384;
const __dirname = dirname(fileURLToPath(import.meta.url));
const VIEW_BUNDLE_PATH = resolve(
  __dirname,
  "..",
  "..",
  "..",
  "dist",
  "mcp-apps",
  "views",
  "commander.html",
);
const VIEW_FALLBACK_PATH = resolve(
  __dirname,
  "..",
  "views",
  "commander",
  "fallback.html",
);

const EMPTY_COMMANDER_SLICE = Object.freeze({
  sessionId: null,
  displayName: "Clippy Commander",
  model: null,
  agent: null,
  mode: "Agent",
  isReady: false,
  isBusy: false,
  latestPrompt: "",
  latestReply: "",
  latestToolSummary: "",
  lastError: "",
  historyCount: 0,
  history: [],
});

/**
 * @param {import("@modelcontextprotocol/sdk/server/mcp.js").McpServer} server
 * @param {{ state: { snapshot: Function }, intentsPath?: string, env?: NodeJS.ProcessEnv }} opts
 */
export function registerCommander(server, { state, intentsPath, env = process.env } = {}) {
  const resolvedIntents = intentsPath || env.CLIPPY_COMMANDER_INTENTS_PATH || null;

  registerAppTool(
    server,
    "clippy.commander.state",
    {
      title: "Clippy Commander State",
      description:
        "Return Clippy's Commander session state: active model/agent/mode, busy flag, transcript history, and latest reply.",
      inputSchema: {
        historyLimit: z
          .number()
          .int()
          .min(0)
          .max(64)
          .optional()
          .describe("Trim transcript history to the N most recent entries (default 24)."),
      },
      _meta: { ui: { resourceUri: COMMANDER_VIEW_URI } },
    },
    wrapToolWithTelemetry(
      "clippy.commander.state",
      wrapToolWithPrincipal(async ({ historyLimit = 24 } = {}) => {
        const slice = await readCommanderSlice(state);
        const trimmedHistory = Array.isArray(slice.history)
          ? slice.history.slice(-Math.max(0, historyLimit))
          : [];
        const payload = {
          ...slice,
          history: trimmedHistory,
          historyCount: Array.isArray(slice.history) ? slice.history.length : 0,
          capturedAt: new Date().toISOString(),
        };
        return {
          content: [
            { type: "text", text: JSON.stringify(payload, null, 2) },
          ],
          structuredContent: payload,
        };
      }),
    ),
  );

  registerAppTool(
    server,
    "clippy.commander.submit",
    {
      title: "Clippy Commander: Submit Prompt",
      description:
        "Queue a prompt for Clippy's Commander session. Clippy reasons independently and may delegate to terminal tabs, broadcast to a group, or reply inline.",
      inputSchema: {
        prompt: z
          .string()
          .min(1)
          .max(MAX_PROMPT_LEN)
          .describe("Natural-language instruction for Clippy."),
        mode: z
          .enum(COMMANDER_MODES)
          .optional()
          .describe("Override Commander mode for this one prompt (default: current session mode)."),
      },
      _meta: { ui: { resourceUri: COMMANDER_VIEW_URI } },
    },
    wrapToolWithTelemetry(
      "clippy.commander.submit",
      wrapToolWithPrincipal(async ({ prompt, mode } = {}, extra) => {
        if (!resolvedIntents) {
          throw buildToolError(
            "clippy.commander.intents.unavailable",
            "Commander intents path is not configured. Set CLIPPY_COMMANDER_INTENTS_PATH or pass intentsPath when constructing the server.",
          );
        }
        const intent = buildIntentEnvelope(
          "commander.submit",
          {
            prompt: String(prompt).slice(0, MAX_PROMPT_LEN),
            mode: mode ?? null,
          },
          extra,
        );
        await appendIntent(resolvedIntents, intent);
        const payload = {
          accepted: true,
          intentId: intent.id,
          intentsPath: resolvedIntents,
        };
        return {
          content: [
            {
              type: "text",
              text: `Commander intent queued (id=${intent.id}).`,
            },
          ],
          structuredContent: payload,
        };
      }),
    ),
  );

  registerAppResource(
    server,
    "Clippy Commander View",
    COMMANDER_VIEW_URI,
    {
      description:
        "Interactive Commander chat surface: Clippy's conversation history, model/agent/mode selector, and delegation controls.",
      _meta: {
        ui: { csp: { resourceDomains: [], connectDomains: [] } },
      },
    },
    async () => {
      const html = await readViewHtml();
      return {
        contents: [
          {
            uri: COMMANDER_VIEW_URI,
            mimeType: RESOURCE_MIME_TYPE,
            text: html,
          },
        ],
      };
    },
  );
}

async function readCommanderSlice(state) {
  if (!state || typeof state.snapshot !== "function") {
    return { ...EMPTY_COMMANDER_SLICE };
  }
  try {
    const snap = await state.snapshot({ includeEvents: false });
    if (snap && typeof snap === "object" && snap.commander && typeof snap.commander === "object") {
      return { ...EMPTY_COMMANDER_SLICE, ...snap.commander };
    }
    return { ...EMPTY_COMMANDER_SLICE, sessionId: snap?.sessionId ?? null };
  } catch (err) {
    return {
      ...EMPTY_COMMANDER_SLICE,
      lastError: `commander slice unavailable: ${err?.message || String(err)}`,
    };
  }
}

function buildToolError(code, message) {
  const err = new Error(`[${code}] ${message}`);
  err.code = code;
  return err;
}

async function readViewHtml() {
  for (const candidate of [VIEW_BUNDLE_PATH, VIEW_FALLBACK_PATH]) {
    try {
      return await readFile(candidate, "utf-8");
    } catch (err) {
      if (err?.code !== "ENOENT") throw err;
    }
  }
  return COMMANDER_FALLBACK_HTML;
}

const COMMANDER_FALLBACK_HTML = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/>
<title>Clippy Commander</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'"/>
<style>
body{font:13px/1.4 "Segoe UI",sans-serif;margin:12px;color:#111;background:#fff}
h1{font-size:14px;margin:0 0 8px}
p.note{color:#666;font-size:11px;margin:0 0 8px}
</style>
</head><body>
<h1>Clippy Commander</h1>
<p class="note">Commander view bundle pending (L4-1 view build). Tool surface is live: call <code>clippy.commander.state</code> or <code>clippy.commander.submit</code>.</p>
</body></html>`;

export { COMMANDER_VIEW_URI, EMPTY_COMMANDER_SLICE, MAX_PROMPT_LEN };
