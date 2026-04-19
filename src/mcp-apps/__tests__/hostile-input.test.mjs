/**
 * L3-FW-3: hostile-input hardening for the MCP Apps server.
 *
 * Exercises FleetState._merge and the clippy.fleet-status tool handler with
 * malformed, oversized, and adversarial state payloads to prove the result
 * stays bounded, serializable, and principal-locked to "clippy".
 */

import { describe, it, expect } from "vitest";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { FleetState, MAX_TABS, MAX_GROUPS, MAX_AGENTS } from "../bridge-state.mjs";
import { registerFleetStatus } from "../tools/fleet-status.mjs";

function makeServer() {
  return new McpServer(
    { name: "hostile-test", version: "0.0.0-test" },
    {
      capabilities: {
        tools: {},
        resources: { subscribe: false, listChanged: true },
      },
    },
  );
}

describe("FleetState hostile-input merge (L3-FW-1)", () => {
  it('coerces principal to literal "clippy" regardless of input shape', async () => {
    const bads = [{}, [], null, undefined, 42, "evil", "CLIPPY", true];
    for (const bad of bads) {
      const s = new FleetState({ source: async () => ({ principal: bad }) });
      const snap = await s.snapshot();
      expect(snap.principal).toBe("clippy");
    }
  });

  it("caps tabs.list at 256 entries and groups.list at 64 entries", async () => {
    const s = new FleetState({
      source: async () => ({
        principal: "clippy",
        tabs: {
          list: Array.from({ length: 10_000 }, (_, i) => ({
            id: `t${i}`,
            displayName: `tab-${i}`,
          })),
        },
        groups: {
          list: Array.from({ length: 5_000 }, (_, i) => ({
            id: `g${i}`,
            members: [],
          })),
        },
      }),
    });
    const snap = await s.snapshot();
    expect(snap.tabs.list.length).toBe(MAX_TABS);
    expect(snap.tabs.list.length).toBeLessThanOrEqual(256);
    expect(snap.groups.list.length).toBe(MAX_GROUPS);
    expect(snap.groups.list.length).toBeLessThanOrEqual(64);
  });

  it("drops __proto__ / constructor / prototype keys during merge", async () => {
    const s = new FleetState({
      source: async () =>
        JSON.parse(
          '{"principal":"clippy","tabs":{"list":[{"id":"ok","constructor":"bad","__proto__":{"polluted":true}}]}}',
        ),
    });
    const snap = await s.snapshot();
    // Global prototype not polluted.
    expect({}.polluted).toBeUndefined();
    // Emitted tab entry has no dangerous own keys.
    const tab = snap.tabs.list[0];
    expect(tab.id).toBe("ok");
    expect(Object.prototype.hasOwnProperty.call(tab, "constructor")).toBe(
      false,
    );
    expect(Object.prototype.hasOwnProperty.call(tab, "__proto__")).toBe(false);
  });

  it("truncates oversized free-form strings to a bounded length", async () => {
    const huge = "x".repeat(1024 * 1024);
    const s = new FleetState({
      source: async () => ({
        principal: "clippy",
        sessionId: huge,
        groups: { active: huge },
      }),
    });
    const snap = await s.snapshot();
    expect(typeof snap.sessionId).toBe("string");
    expect(snap.sessionId.length).toBeLessThanOrEqual(2048);
    expect(typeof snap.groups.active).toBe("string");
    expect(snap.groups.active.length).toBeLessThanOrEqual(2048);
  });

  it("reduces non-finite counters to 0", async () => {
    const s = new FleetState({
      source: async () => ({
        principal: "clippy",
        tabs: {
          total: "not-a-number",
          byState: { idle: -5, running: NaN, exited: Infinity },
        },
      }),
    });
    const snap = await s.snapshot();
    expect(snap.tabs.total).toBe(0);
    expect(snap.tabs.byState.idle).toBe(0);
    expect(snap.tabs.byState.running).toBe(0);
    expect(snap.tabs.byState.exited).toBe(0);
  });

  it("normalizes agent catalogs to structured entries and backfills legacy string lists", async () => {
    const s = new FleetState({
      source: async () => ({
        principal: "clippy",
        agents: {
          active: "assistant",
          list: ["assistant", { id: "builder", displayName: "Builder", source: "bundled" }],
        },
      }),
    });
    const snap = await s.snapshot();
    expect(snap.agents.catalogSize).toBe(2);
    expect(snap.agents.catalog).toEqual([
      {
        id: "assistant",
        displayName: "assistant",
        filePath: "",
        source: "unknown",
        isActive: true,
      },
      {
        id: "builder",
        displayName: "Builder",
        filePath: "",
        source: "bundled",
        isActive: false,
      },
    ]);
  });

  it("caps agent catalog length and strips malformed entries", async () => {
    const s = new FleetState({
      source: async () => ({
        principal: "clippy",
        agents: {
          catalog: [
            ...Array.from({ length: MAX_AGENTS + 25 }, (_, i) => ({
              id: `agent-${i}`,
              displayName: `Agent ${i}`,
              filePath: `/agents/${i}.md`,
              source: i % 2 === 0 ? "user" : "bundled",
            })),
            null,
            42,
            { displayName: "missing-id" },
          ],
        },
      }),
    });
    const snap = await s.snapshot();
    expect(snap.agents.catalog.length).toBe(MAX_AGENTS);
    expect(snap.agents.catalog[0]).toEqual({
      id: "agent-0",
      displayName: "Agent 0",
      filePath: "/agents/0.md",
      source: "user",
      isActive: false,
    });
  });
});

describe("clippy.fleet-status hostile-input tool handler (L3-FW-3)", () => {
  const CLIPPY_EXTRA = Object.freeze({
    _meta: { clippy: { principal: "clippy", session: "test-session" } },
  });

  it("produces a bounded, JSON-serializable tool result", async () => {
    const state = new FleetState({
      source: async () => ({
        principal: { evil: true },
        sessionId: "x".repeat(8_000),
        tabs: {
          total: 99_999,
          list: Array.from({ length: 5_000 }, (_, i) => ({
            id: `t${i}`,
            displayName: `tab-${i}`,
            constructor: "bad",
          })),
        },
        groups: {
          list: Array.from({ length: 1_000 }, (_, i) => ({ id: `g${i}` })),
        },
      }),
    });
    const server = makeServer();
    registerFleetStatus(server, { state });
    const tool = server._registeredTools["clippy.fleet-status"];
    const result = await tool.handler({}, CLIPPY_EXTRA);
    const sc = result.structuredContent;

    expect(sc.principal).toBe("clippy");
    expect(sc.tabs.list.length).toBeLessThanOrEqual(256);
    expect(sc.groups.list.length).toBeLessThanOrEqual(64);

    // Tab entries stripped of dangerous keys.
    for (const tab of sc.tabs.list) {
      expect(Object.prototype.hasOwnProperty.call(tab, "constructor")).toBe(
        false,
      );
    }

    // Whole result round-trips through JSON cleanly and stays under a
    // hard ceiling so a malicious bridge cannot exhaust the Node server
    // or WebView2 channel.
    const serialized = JSON.stringify(result);
    expect(typeof serialized).toBe("string");
    expect(serialized.length).toBeLessThan(64 * 1024);
  });
});
