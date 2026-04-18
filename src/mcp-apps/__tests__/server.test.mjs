import { describe, it, expect } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createAppsServer, SERVER_INFO } from "../server.mjs";

async function connectPair() {
  const server = createAppsServer();
  const [clientTransport, serverTransport] =
    InMemoryTransport.createLinkedPair();
  const client = new Client(
    { name: "clippy-test-client", version: "0.0.0-test" },
    {
      capabilities: {
        extensions: {
          "io.modelcontextprotocol/ui": {
            mimeTypes: ["text/html;profile=mcp-app"],
          },
        },
      },
    },
  );
  await Promise.all([
    server.connect(serverTransport),
    client.connect(clientTransport),
  ]);
  return { server, client };
}

describe("createAppsServer", () => {
  it("returns an McpServer exposing SERVER_INFO name and version", async () => {
    const { server, client } = await connectPair();
    try {
      const info = client.getServerVersion();
      expect(info?.name).toBe("windows-clippy-mcp-apps");
      expect(info?.name).toBe(SERVER_INFO.name);
      expect(info?.version).toBe(SERVER_INFO.version);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("advertises the full L4 tool surface (fleet-status, commander trio, agent-catalog, broadcast, link-group, session-inspector, telemetry)", async () => {
    const { server, client } = await connectPair();
    try {
      const result = await client.listTools();
      const names = result.tools.map((t) => t.name).sort();
      expect(names).toEqual(
        [
          "clippy.agent-catalog",
          "clippy.broadcast",
          "clippy.commander.state",
          "clippy.commander.submit",
          "clippy.fleet-status",
          "clippy.link-group",
          "clippy.session-inspector",
          "clippy.telemetry",
        ].sort(),
      );
      const fleet = result.tools.find((t) => t.name === "clippy.fleet-status");
      const uri =
        fleet._meta?.ui?.resourceUri ?? fleet._meta?.["ui/resourceUri"];
      expect(uri).toBe("ui://clippy/fleet-status.html");
      const commanderState = result.tools.find(
        (t) => t.name === "clippy.commander.state",
      );
      const commanderUri =
        commanderState._meta?.ui?.resourceUri ??
        commanderState._meta?.["ui/resourceUri"];
      expect(commanderUri).toBe("ui://clippy/commander.html");
    } finally {
      await client.close();
      await server.close();
    }
  });
});
