import { describe, it, expect, beforeEach } from "vitest";
import {
  newTraceId,
  traceIdFromExtra,
  wrapToolWithTelemetry,
  getTelemetrySnapshot,
  resetTelemetry,
} from "../telemetry.mjs";

describe("telemetry", () => {
  beforeEach(() => {
    resetTelemetry();
  });

  it("newTraceId produces a 16-hex-char id", () => {
    const id = newTraceId();
    expect(id).toMatch(/^[0-9a-f]{16}$/);
  });

  it("traceIdFromExtra picks a caller-supplied trace when valid", () => {
    const id = traceIdFromExtra({
      _meta: { clippy: { trace: "deadbeefcafef00d" } },
    });
    expect(id).toBe("deadbeefcafef00d");
  });

  it("traceIdFromExtra synthesizes a new id when missing", () => {
    const id = traceIdFromExtra({});
    expect(id).toMatch(/^[0-9a-f]{16}$/);
  });

  it("traceIdFromExtra rejects malformed trace and regenerates", () => {
    const id = traceIdFromExtra({ _meta: { clippy: { trace: "not-a-trace" } } });
    expect(id).not.toBe("not-a-trace");
    expect(id).toMatch(/^[0-9a-f]{16}$/);
  });

  it("wrapToolWithTelemetry records ok and err counters", async () => {
    const handler = wrapToolWithTelemetry("test.tool", async (args) => {
      if (args.fail) throw new Error("boom");
      return { content: [{ type: "text", text: "ok" }] };
    });
    await handler({ fail: false });
    await handler({ fail: false });
    try {
      await handler({ fail: true });
    } catch {
      /* expected */
    }
    const snap = getTelemetrySnapshot();
    const byKey = Object.fromEntries(snap.counters.map((c) => [c.key, c]));
    expect(byKey["test.tool.ok"].count).toBe(2);
    expect(byKey["test.tool.err"].count).toBe(1);
    expect(byKey["test.tool.ok"].totalDurationMs).toBeGreaterThanOrEqual(0);
  });

  it("wrapToolWithTelemetry does not swallow handler errors", async () => {
    const handler = wrapToolWithTelemetry("explode", async () => {
      throw new Error("kaboom");
    });
    await expect(handler({})).rejects.toThrow("kaboom");
  });

  it("getTelemetrySnapshot returns recent events (bounded)", async () => {
    const handler = wrapToolWithTelemetry("ring", async () => ({
      content: [{ type: "text", text: "x" }],
    }));
    for (let i = 0; i < 25; i++) await handler({});
    const snap = getTelemetrySnapshot();
    expect(snap.recent.length).toBeLessThanOrEqual(20);
    expect(snap.recent.every((e) => e.tool === "ring")).toBe(true);
  });
});
