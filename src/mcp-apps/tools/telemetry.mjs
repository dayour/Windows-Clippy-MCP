/**
 * L4-7 — clippy.telemetry tool.
 *
 * Surfaces the accumulated tool-call counters + recent event log collected
 * by telemetry.wrapToolWithTelemetry. No view — this is a data tool that the
 * Fleet Status View and Session Inspector View both read.
 *
 * Principal required: every caller must assert _meta.clippy.principal="clippy".
 */
import { z } from "zod";
import { registerAppTool } from "@modelcontextprotocol/ext-apps/server";
import { wrapToolWithPrincipal } from "../principal.mjs";
import {
  wrapToolWithTelemetry,
  getTelemetrySnapshot,
  resetTelemetry,
} from "../telemetry.mjs";

export function registerTelemetry(server) {
  registerAppTool(
    server,
    "clippy.telemetry",
    {
      title: "Clippy Telemetry",
      description:
        "Return tool-call counters, per-tool latency, recent event ring buffer, and last-seen timestamps for observability.",
      inputSchema: {
        reset: z
          .boolean()
          .optional()
          .describe(
            "If true, reset counters after capturing a snapshot (admin use only).",
          ),
      },
      _meta: { ui: { resourceUri: "ui://clippy/fleet-status.html" } },
    },
    wrapToolWithTelemetry(
      "clippy.telemetry",
      wrapToolWithPrincipal(async ({ reset = false } = {}) => {
        const snapshot = getTelemetrySnapshot();
        if (reset) resetTelemetry();
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
}
