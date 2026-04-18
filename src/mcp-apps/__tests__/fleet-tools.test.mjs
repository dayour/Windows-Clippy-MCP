import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerBroadcast } from "../tools/broadcast.mjs";
import { registerLinkGroup } from "../tools/link-group.mjs";
import { registerSessionInspector } from "../tools/session-inspector.mjs";
import { FleetState } from "../bridge-state.mjs";

const CLIENT_CAPS = {
  capabilities: {
    extensions: {
      "io.modelcontextprotocol/ui": {
        mimeTypes: ["text/html;profile=mcp-app"],
      },
    },
  },
};

async function buildServer(registerFn, opts) {
  const server = new McpServer(
    { name: "clippy-fleet-test", version: "0.0.0-test" },
    { capabilities: { tools: {}, resources: { listChanged: true } } },
  );
  registerFn(server, opts);
  return server;
}

async function connect(server) {
  const [ct, st] = InMemoryTransport.createLinkedPair();
  const client = new Client(
    { name: "clippy-test-client", version: "0.0.0-test" },
    CLIENT_CAPS,
  );
  await Promise.all([server.connect(st), client.connect(ct)]);
  return client;
}

const CLIPPY_META = { clippy: { principal: "clippy", session: "s-test" } };

describe("clippy.broadcast", () => {
  let tmp, intentsPath;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "clippy-broadcast-"));
    intentsPath = join(tmp, "intents.jsonl");
  });
  afterEach(() => rmSync(tmp, { recursive: true, force: true }));

  it("queues a broadcast intent with mode=all when no selector", async () => {
    const state = new FleetState();
    const server = await buildServer(registerBroadcast, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.broadcast",
        arguments: { prompt: "build everything" },
        _meta: CLIPPY_META,
      });
      expect(result.isError).not.toBe(true);
      expect(result.structuredContent.accepted).toBe(true);
      expect(result.structuredContent.resolvedTargetMode).toBe("all");
      const lines = readFileSync(intentsPath, "utf8").trim().split("\n");
      const entry = JSON.parse(lines[0]);
      expect(entry.kind).toBe("broadcast.send");
      expect(entry.targets.mode).toBe("all");
      expect(entry.prompt).toBe("build everything");
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("queues a broadcast intent with explicit sessionIds", async () => {
    const state = new FleetState();
    const server = await buildServer(registerBroadcast, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.broadcast",
        arguments: { prompt: "ls -la", sessionIds: ["tab-a", "tab-b"] },
        _meta: CLIPPY_META,
      });
      expect(result.isError).not.toBe(true);
      const entry = JSON.parse(readFileSync(intentsPath, "utf8").trim());
      expect(entry.targets.mode).toBe("ids");
      expect(entry.targets.ids).toEqual(["tab-a", "tab-b"]);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("queues a broadcast intent with a group label", async () => {
    const fleetPath = join(tmp, "fleet-state.json");
    writeFileSync(fleetPath, JSON.stringify({
      groups: { list: [{ label: "build-farm", members: ["tab-1", "tab-2", "tab-3"] }] },
    }));
    const state = new FleetState({ path: fleetPath });
    const server = await buildServer(registerBroadcast, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.broadcast",
        arguments: { prompt: "npm run build", group: "build-farm" },
        _meta: CLIPPY_META,
      });
      expect(result.structuredContent.resolvedTargetMode).toBe("group");
      expect(result.structuredContent.resolvedTargetCount).toBe(3);
      const entry = JSON.parse(readFileSync(intentsPath, "utf8").trim());
      expect(entry.targets.mode).toBe("group");
      expect(entry.targets.label).toBe("build-farm");
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("rejects when both sessionIds and group are supplied", async () => {
    const state = new FleetState();
    const server = await buildServer(registerBroadcast, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.broadcast",
        arguments: { prompt: "x", sessionIds: ["a"], group: "g" },
        _meta: CLIPPY_META,
      });
      expect(result.isError).toBe(true);
      expect(existsSync(intentsPath)).toBe(false);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("enforces principal check", async () => {
    const state = new FleetState();
    const server = await buildServer(registerBroadcast, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.broadcast",
        arguments: { prompt: "x" },
      });
      expect(result.isError).toBe(true);
      expect(existsSync(intentsPath)).toBe(false);
    } finally {
      await client.close();
      await server.close();
    }
  });
});

describe("clippy.link-group", () => {
  let tmp, intentsPath;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "clippy-linkgroup-"));
    intentsPath = join(tmp, "intents.jsonl");
  });
  afterEach(() => rmSync(tmp, { recursive: true, force: true }));

  it("op=list returns groups from fleet state", async () => {
    const fleetPath = join(tmp, "fleet.json");
    writeFileSync(fleetPath, JSON.stringify({
      groups: {
        active: "ci",
        list: [
          { label: "ci", members: ["t1", "t2"] },
          { label: "dev", members: ["t3"] },
        ],
      },
    }));
    const state = new FleetState({ path: fleetPath });
    const server = await buildServer(registerLinkGroup, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.link-group",
        arguments: { op: "list" },
        _meta: CLIPPY_META,
      });
      expect(result.isError).not.toBe(true);
      expect(result.structuredContent.total).toBe(2);
      expect(result.structuredContent.active).toBe("ci");
      expect(result.structuredContent.groups[0].label).toBe("ci");
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("op=link queues a linkgroup.link intent", async () => {
    const state = new FleetState();
    const server = await buildServer(registerLinkGroup, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.link-group",
        arguments: { op: "link", sessionId: "tab-42", label: "ops" },
        _meta: CLIPPY_META,
      });
      expect(result.structuredContent.kind).toBe("linkgroup.link");
      const entry = JSON.parse(readFileSync(intentsPath, "utf8").trim());
      expect(entry.kind).toBe("linkgroup.link");
      expect(entry.sessionId).toBe("tab-42");
      expect(entry.label).toBe("ops");
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("op=broadcast queues a linkgroup.broadcast intent", async () => {
    const state = new FleetState();
    const server = await buildServer(registerLinkGroup, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.link-group",
        arguments: { op: "broadcast", label: "ops", prompt: "deploy staging" },
        _meta: CLIPPY_META,
      });
      expect(result.structuredContent.kind).toBe("linkgroup.broadcast");
      const entry = JSON.parse(readFileSync(intentsPath, "utf8").trim());
      expect(entry.kind).toBe("linkgroup.broadcast");
      expect(entry.label).toBe("ops");
      expect(entry.prompt).toBe("deploy staging");
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("op=link rejects when sessionId missing", async () => {
    const state = new FleetState();
    const server = await buildServer(registerLinkGroup, { state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.link-group",
        arguments: { op: "link", label: "ops" },
        _meta: CLIPPY_META,
      });
      expect(result.isError).toBe(true);
    } finally {
      await client.close();
      await server.close();
    }
  });
});

describe("clippy.session-inspector", () => {
  let tmp;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "clippy-inspector-"));
  });
  afterEach(() => rmSync(tmp, { recursive: true, force: true }));

  it("inspects commander when no id provided", async () => {
    const fleetPath = join(tmp, "fleet.json");
    writeFileSync(fleetPath, JSON.stringify({
      commander: { sessionId: "cmd-1", model: "gpt-5", displayName: "Clippy" },
    }));
    const state = new FleetState({ path: fleetPath });
    const server = await buildServer(registerSessionInspector, { state });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.session-inspector",
        arguments: { kind: "commander" },
        _meta: CLIPPY_META,
      });
      expect(result.structuredContent.found).toBe(true);
      expect(result.structuredContent.entity.sessionId).toBe("cmd-1");
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("inspects a tab by sessionId", async () => {
    const fleetPath = join(tmp, "fleet.json");
    writeFileSync(fleetPath, JSON.stringify({
      tabs: { list: [{ sessionId: "tab-a", displayName: "Alpha" }, { sessionId: "tab-b", displayName: "Beta" }] },
    }));
    const state = new FleetState({ path: fleetPath });
    const server = await buildServer(registerSessionInspector, { state });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.session-inspector",
        arguments: { kind: "tab", id: "tab-b" },
        _meta: CLIPPY_META,
      });
      expect(result.structuredContent.found).toBe(true);
      expect(result.structuredContent.entity.displayName).toBe("Beta");
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("reports not-found for missing entity", async () => {
    const state = new FleetState();
    const server = await buildServer(registerSessionInspector, { state });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.session-inspector",
        arguments: { kind: "tab", id: "nope" },
        _meta: CLIPPY_META,
      });
      expect(result.structuredContent.found).toBe(false);
      expect(result.structuredContent.entity).toBe(null);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("inspects an agent by id", async () => {
    const fleetPath = join(tmp, "fleet.json");
    writeFileSync(fleetPath, JSON.stringify({
      agents: { catalog: [{ id: "clippy-commander", displayName: "Clippy" }, { id: "assistant", displayName: "Asst" }] },
    }));
    const state = new FleetState({ path: fleetPath });
    const server = await buildServer(registerSessionInspector, { state });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.session-inspector",
        arguments: { kind: "agent", id: "assistant" },
        _meta: CLIPPY_META,
      });
      expect(result.structuredContent.found).toBe(true);
      expect(result.structuredContent.entity.displayName).toBe("Asst");
    } finally {
      await client.close();
      await server.close();
    }
  });
});
