import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerCommander } from "../tools/commander.mjs";
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

async function buildServer({ state, intentsPath }) {
  const server = new McpServer(
    { name: "clippy-commander-test", version: "0.0.0-test" },
    { capabilities: { tools: {}, resources: { listChanged: true } } },
  );
  registerCommander(server, { state, intentsPath });
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

describe("clippy.commander tools", () => {
  let tmp;
  let intentsPath;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "clippy-commander-"));
    intentsPath = join(tmp, "intents.jsonl");
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it("clippy.commander.state returns empty slice when no fleet-state file present", async () => {
    const state = new FleetState();
    const server = await buildServer({ state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.commander.state",
        arguments: { historyLimit: 4 },
        _meta: { clippy: { principal: "clippy", session: "s-test" } },
      });
      expect(result.isError).not.toBe(true);
      const payload = result.structuredContent;
      expect(payload.displayName).toBe("Clippy Commander");
      expect(payload.history).toEqual([]);
      expect(payload.historyCount).toBe(0);
      expect(payload.capturedAt).toMatch(/T/);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("clippy.commander.state forwards commander slice from FleetState", async () => {
    const fleetPath = join(tmp, "fleet-state.json");
    const snapshot = {
      sessionId: "cmd-001",
      commander: {
        sessionId: "cmd-001",
        displayName: "Clippy",
        model: "gpt-5",
        agent: "default",
        mode: "Agent",
        isReady: true,
        isBusy: false,
        latestPrompt: "hello",
        latestReply: "world",
        history: [
          { role: "user", text: "hello" },
          { role: "assistant", text: "world" },
        ],
      },
    };
    writeFileSync(fleetPath, JSON.stringify(snapshot));
    const state = new FleetState({ path: fleetPath });
    const server = await buildServer({ state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.commander.state",
        arguments: {},
        _meta: { clippy: { principal: "clippy", session: "cmd-001" } },
      });
      const payload = result.structuredContent;
      expect(payload.model).toBe("gpt-5");
      expect(payload.historyCount).toBe(2);
      expect(payload.history.length).toBe(2);
      expect(payload.isReady).toBe(true);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("clippy.commander.submit appends a JSON line to the intents log", async () => {
    const state = new FleetState();
    const server = await buildServer({ state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.commander.submit",
        arguments: { prompt: "launch a build" },
        _meta: { clippy: { principal: "clippy", session: "cmd-abc" } },
      });
      expect(result.isError).not.toBe(true);
      expect(result.structuredContent.accepted).toBe(true);
      expect(typeof result.structuredContent.intentId).toBe("string");
      expect(existsSync(intentsPath)).toBe(true);
      const lines = readFileSync(intentsPath, "utf8").trim().split("\n");
      expect(lines.length).toBe(1);
      const entry = JSON.parse(lines[0]);
      expect(entry.kind).toBe("commander.submit");
      expect(entry.prompt).toBe("launch a build");
      expect(entry.session).toBe("cmd-abc");
      expect(entry.id).toBe(result.structuredContent.intentId);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("clippy.commander.submit rejects when intents path is unset", async () => {
    const state = new FleetState();
    const server = new McpServer(
      { name: "clippy-commander-test", version: "0.0.0-test" },
      { capabilities: { tools: {}, resources: { listChanged: true } } },
    );
    registerCommander(server, { state, env: {} });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.commander.submit",
        arguments: { prompt: "no-op" },
        _meta: { clippy: { principal: "clippy", session: "cmd-z" } },
      });
      expect(result.isError).toBe(true);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("clippy.commander.submit enforces principal check", async () => {
    const state = new FleetState();
    const server = await buildServer({ state, intentsPath });
    const client = await connect(server);
    try {
      const result = await client.callTool({
        name: "clippy.commander.submit",
        arguments: { prompt: "no-principal" },
        // no _meta.clippy — should be rejected by wrapToolWithPrincipal
      });
      expect(result.isError).toBe(true);
      expect(existsSync(intentsPath)).toBe(false);
    } finally {
      await client.close();
      await server.close();
    }
  });
});
