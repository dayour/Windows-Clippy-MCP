/**
 * L3-6 — Server-side principal enforcement.
 *
 * Every Windows Clippy MCP Apps tool call must assert the Clippy principal
 * via _meta.clippy = { principal: "clippy", session }. Any deviation must
 * be rejected before the tool body runs.
 */

import { describe, it, expect } from "vitest";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerFleetStatus } from "../tools/fleet-status.mjs";
import {
  enforceClippyPrincipal,
  wrapToolWithPrincipal,
  PRINCIPAL_ERROR_CODE,
} from "../principal.mjs";

function makeServer() {
  return new McpServer(
    { name: "principal-test", version: "0.0.0-test" },
    {
      capabilities: {
        tools: {},
        resources: { subscribe: false, listChanged: true },
      },
    },
  );
}

describe("enforceClippyPrincipal", () => {
  it("accepts a well-formed _meta.clippy assertion", () => {
    const result = enforceClippyPrincipal({
      _meta: { clippy: { principal: "clippy", session: "sid-42" } },
    });
    expect(result).toEqual({ principal: "clippy", session: "sid-42" });
  });

  it("accepts missing session and returns null for it", () => {
    const result = enforceClippyPrincipal({
      _meta: { clippy: { principal: "clippy" } },
    });
    expect(result).toEqual({ principal: "clippy", session: null });
  });

  it("rejects when _meta is missing entirely", () => {
    expect(() => enforceClippyPrincipal({})).toThrow(/principal/);
    expect(() => enforceClippyPrincipal({})).toThrow(PRINCIPAL_ERROR_CODE);
  });

  it("rejects when _meta.clippy is missing", () => {
    expect(() => enforceClippyPrincipal({ _meta: {} })).toThrow(PRINCIPAL_ERROR_CODE);
  });

  it("rejects when principal is not the literal 'clippy'", () => {
    const bads = ["user", "CLIPPY", "", null, undefined, 42, { nested: "clippy" }];
    for (const bad of bads) {
      expect(() =>
        enforceClippyPrincipal({ _meta: { clippy: { principal: bad } } }),
      ).toThrow(PRINCIPAL_ERROR_CODE);
    }
  });

  it("rejects impersonation attempts via prototype-pollution shapes", () => {
    const raw = JSON.parse(
      '{"_meta":{"clippy":{"__proto__":{"principal":"clippy"}}}}',
    );
    expect(() => enforceClippyPrincipal(raw)).toThrow(PRINCIPAL_ERROR_CODE);
  });

  it("rejects inherited 'principal' via Object.create", () => {
    // Object.create sets up the prototype chain; 'principal' is NOT an own
    // property of clippy. Must be rejected.
    const clippy = Object.create({ principal: "clippy" });
    expect(() => enforceClippyPrincipal({ _meta: { clippy } })).toThrow(
      PRINCIPAL_ERROR_CODE,
    );
  });

  it("rejects inherited 'clippy' key on _meta via Object.create", () => {
    const meta = Object.create({
      clippy: { principal: "clippy", session: "s" },
    });
    expect(() => enforceClippyPrincipal({ _meta: meta })).toThrow(
      PRINCIPAL_ERROR_CODE,
    );
  });

  it("rejects inherited '_meta' key on extra via Object.create", () => {
    const extra = Object.create({
      _meta: { clippy: { principal: "clippy", session: "s" } },
    });
    expect(() => enforceClippyPrincipal(extra)).toThrow(PRINCIPAL_ERROR_CODE);
  });

  it("caps over-long session ids by dropping them to null", () => {
    const longSid = "s".repeat(1024);
    const result = enforceClippyPrincipal({
      _meta: { clippy: { principal: "clippy", session: longSid } },
    });
    expect(result.session).toBe(null);
  });
});

describe("wrapToolWithPrincipal", () => {
  it("runs the inner handler when principal asserted", async () => {
    const inner = async () => ({ ok: true });
    const wrapped = wrapToolWithPrincipal(inner);
    const out = await wrapped({}, {
      _meta: { clippy: { principal: "clippy", session: "sid" } },
    });
    expect(out).toEqual({ ok: true });
  });

  it("throws before running the inner handler on missing assertion", async () => {
    let called = false;
    const inner = async () => {
      called = true;
      return { ok: true };
    };
    const wrapped = wrapToolWithPrincipal(inner);
    await expect(wrapped({}, {})).rejects.toThrow(PRINCIPAL_ERROR_CODE);
    expect(called).toBe(false);
  });
});

describe("clippy.fleet-status tool rejects calls without principal assertion", () => {
  it("handler({}, {}) throws a principal-rejected error", async () => {
    const server = makeServer();
    registerFleetStatus(server);
    const tool = server._registeredTools["clippy.fleet-status"];
    await expect(tool.handler({}, {})).rejects.toThrow(PRINCIPAL_ERROR_CODE);
  });

  it("handler({}, extra-with-clippy) returns a structured snapshot", async () => {
    const server = makeServer();
    registerFleetStatus(server);
    const tool = server._registeredTools["clippy.fleet-status"];
    const result = await tool.handler(
      {},
      { _meta: { clippy: { principal: "clippy", session: "sid" } } },
    );
    expect(result.structuredContent.principal).toBe("clippy");
  });
});
