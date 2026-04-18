import { describe, it, expect } from "vitest";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  registerFleetStatus,
  RESOURCE_URI,
  EMPTY_FLEET_SNAPSHOT,
} from "../tools/fleet-status.mjs";

const CLIPPY_EXTRA = Object.freeze({
  _meta: { clippy: { principal: "clippy", session: "test-session" } },
});

function makeServer() {
  return new McpServer(
    { name: "test-apps", version: "0.0.0-test" },
    {
      capabilities: {
        tools: {},
        resources: { subscribe: true, listChanged: true },
      },
    },
  );
}

function getRegisteredTools(server) {
  return server._registeredTools ?? {};
}

function getRegisteredResources(server) {
  return server._registeredResources ?? {};
}

describe("registerFleetStatus", () => {
  it("RESOURCE_URI matches the spec URI exactly", () => {
    expect(RESOURCE_URI).toBe("ui://clippy/fleet-status.html");
  });

  it("registers exactly one tool named clippy.fleet-status", () => {
    const server = makeServer();
    registerFleetStatus(server);
    const tools = getRegisteredTools(server);
    const names = Object.keys(tools);
    expect(names).toEqual(["clippy.fleet-status"]);
  });

  it("tool metadata carries _meta.ui.resourceUri pointing at the view", () => {
    const server = makeServer();
    registerFleetStatus(server);
    const tool = getRegisteredTools(server)["clippy.fleet-status"];
    expect(tool).toBeDefined();
    const meta = tool._meta ?? tool.metadata?._meta ?? tool.annotations?._meta;
    expect(meta?.ui?.resourceUri).toBe("ui://clippy/fleet-status.html");
  });

  it("handler with no state returns a clippy-principal snapshot with a bridge-state error", async () => {
    const server = makeServer();
    registerFleetStatus(server);
    const tool = getRegisteredTools(server)["clippy.fleet-status"];
    const result = await tool.handler({}, CLIPPY_EXTRA);
    const sc = result.structuredContent;
    expect(sc.principal).toBe("clippy");
    expect(typeof sc.capturedAt).toBe("string");
    expect(sc.error).toMatch(/bridge-state not wired/);
    expect(sc.tabs).toEqual(EMPTY_FLEET_SNAPSHOT.tabs);
  });

  it("handler with a state that returns a snapshot merges capturedAt and omits error", async () => {
    const fakeSnap = {
      principal: "clippy",
      sessionId: "s1",
      tabs: { total: 3, byState: { idle: 1, running: 2, exited: 0 } },
      groups: { total: 1, active: "g1" },
      agents: { catalogSize: 5 },
      events: { recent: [] },
    };
    const state = { snapshot: async () => fakeSnap };
    const server = makeServer();
    registerFleetStatus(server, { state });
    const tool = getRegisteredTools(server)["clippy.fleet-status"];
    const result = await tool.handler({}, CLIPPY_EXTRA);
    const sc = result.structuredContent;
    expect(sc.sessionId).toBe("s1");
    expect(sc.tabs.total).toBe(3);
    expect(sc.agents.catalogSize).toBe(5);
    expect(typeof sc.capturedAt).toBe("string");
    expect(new Date(sc.capturedAt).toString()).not.toBe("Invalid Date");
    expect(sc.error).toBeUndefined();
  });

  it("resource handler returns MCP-App HTML content for the fleet view", async () => {
    const server = makeServer();
    registerFleetStatus(server);
    const entry = getRegisteredResources(server)[RESOURCE_URI];
    expect(entry).toBeDefined();
    const read = await entry.readCallback(new URL(RESOURCE_URI), {});
    expect(read.contents).toHaveLength(1);
    expect(read.contents[0].mimeType).toBe("text/html;profile=mcp-app");
    expect(read.contents[0].text).toContain("<html");
  });
});
