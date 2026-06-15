/**
 * L4-7/L4-8 — Telemetry + structured logging foundation.
 *
 * Every MCP Apps tool call receives:
 *   - a trace id (propagated through _meta.clippy.trace)
 *   - a latency measurement
 *   - a counter increment on the tool name + status
 *   - a structured log line on stderr suitable for log-collection pipelines
 *
 * Counters are accumulated in-process and surfaced via the
 * `clippy.telemetry` tool, which the Fleet Status view consumes.
 *
 * Trace id format: 16 hex chars (w3c trace-context style, half length for
 * log-friendliness). Generated with crypto.randomUUID when available,
 * falling back to Math.random for non-crypto runtimes.
 */
import { randomUUID, randomBytes } from "node:crypto";

export const TELEMETRY_EVENT_VERSION = 1;

const counters = new Map();
const recentEvents = [];
const MAX_RECENT_EVENTS = 100;

export function resetTelemetry() {
  counters.clear();
  recentEvents.length = 0;
}

export function getTelemetrySnapshot() {
  const counterEntries = [];
  for (const [key, value] of counters.entries()) {
    counterEntries.push({ key, ...value });
  }
  counterEntries.sort((a, b) => a.key.localeCompare(b.key));
  return {
    version: TELEMETRY_EVENT_VERSION,
    counters: counterEntries,
    recent: recentEvents.slice(-20),
    capturedAt: new Date().toISOString(),
  };
}

export function newTraceId() {
  try {
    const buf = randomBytes(8);
    return buf.toString("hex");
  } catch {
    return Math.random().toString(16).slice(2, 18).padEnd(16, "0");
  }
}

/**
 * Extract (or synthesize) a trace id from the extra._meta.clippy.trace.
 * If absent, a new id is generated — the caller should merge it back so
 * downstream spans correlate.
 */
export function traceIdFromExtra(extra) {
  if (!extra || typeof extra !== "object") return newTraceId();
  const meta = extra._meta;
  if (!meta || typeof meta !== "object") return newTraceId();
  const clippy = meta.clippy;
  if (!clippy || typeof clippy !== "object") return newTraceId();
  const trace = clippy.trace;
  if (typeof trace === "string" && /^[0-9a-fA-F]{8,32}$/.test(trace)) return trace;
  return newTraceId();
}

function bumpCounter(key, deltaCount = 1, durationMs = 0) {
  const existing = counters.get(key);
  if (!existing) {
    counters.set(key, {
      count: deltaCount,
      totalDurationMs: durationMs,
      lastAt: new Date().toISOString(),
    });
    return;
  }
  existing.count += deltaCount;
  existing.totalDurationMs += durationMs;
  existing.lastAt = new Date().toISOString();
}

function recordEvent(event) {
  recentEvents.push(event);
  if (recentEvents.length > MAX_RECENT_EVENTS) {
    recentEvents.splice(0, recentEvents.length - MAX_RECENT_EVENTS);
  }
}

/**
 * Emit a structured log line to stderr. Single-line JSON so log collectors
 * can parse without buffering. Includes level, tool, trace, session, duration,
 * and any extra attributes the caller provides.
 */
export function emitStructuredLog({
  level = "info",
  event,
  tool,
  traceId,
  session = null,
  durationMs,
  status,
  attrs = {},
}) {
  const line = {
    t: new Date().toISOString(),
    level,
    event,
    tool,
    trace: traceId,
    session,
    durationMs,
    status,
    ...attrs,
  };
  try {
    if (process.env.CLIPPY_TELEMETRY_SILENT === '1') return;
    process.stderr.write(`[clippy-telemetry] ${JSON.stringify(line)}\n`);
  } catch {
    // stderr closed; swallow — telemetry must never throw into a tool path.
  }
}

/**
 * Wrap an async tool handler to emit telemetry around each invocation.
 *
 * Usage:
 *   registerAppTool(server, "clippy.foo", {...},
 *     wrapToolWithTelemetry("clippy.foo",
 *       wrapToolWithPrincipal(async (args, extra) => {...})));
 */
export function wrapToolWithTelemetry(toolName, handler) {
  return async function telemetered(...args) {
    const extra = args.length >= 2 ? args[1] : args[0];
    const traceId = traceIdFromExtra(extra);
    const session = extractSession(extra);
    const startedAt = performanceNow();
    emitStructuredLog({
      level: "info",
      event: "tool.start",
      tool: toolName,
      traceId,
      session,
      durationMs: 0,
      status: "running",
    });
    try {
      const result = await handler.apply(this, args);
      const durationMs = Math.round(performanceNow() - startedAt);
      bumpCounter(`${toolName}.ok`, 1, durationMs);
      recordEvent({
        tool: toolName,
        traceId,
        session,
        durationMs,
        status: "ok",
        at: new Date().toISOString(),
      });
      emitStructuredLog({
        level: "info",
        event: "tool.end",
        tool: toolName,
        traceId,
        session,
        durationMs,
        status: "ok",
      });
      return result;
    } catch (err) {
      const durationMs = Math.round(performanceNow() - startedAt);
      const code = err?.code || "unknown";
      bumpCounter(`${toolName}.err`, 1, durationMs);
      bumpCounter(`${toolName}.err.${code}`, 1, 0);
      recordEvent({
        tool: toolName,
        traceId,
        session,
        durationMs,
        status: "err",
        code,
        at: new Date().toISOString(),
      });
      emitStructuredLog({
        level: "error",
        event: "tool.end",
        tool: toolName,
        traceId,
        session,
        durationMs,
        status: "err",
        attrs: { code, message: err?.message || String(err) },
      });
      throw err;
    }
  };
}

function extractSession(extra) {
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

function performanceNow() {
  try {
    return performance.now();
  } catch {
    return Date.now();
  }
}

export { bumpCounter, recordEvent };
