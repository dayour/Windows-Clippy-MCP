# L2-7 MCP Apps Vitest Suite

Scope: unit + in-process protocol tests for the `windows-clippy-mcp-apps`
server and the `clippy.fleet-status` tool. Complements (does not replace)
`scripts/smoke-apps-server.mjs`, which spawns the real stdio server.

## How to run

```
npm install --ignore-scripts
npm run test:apps
```

Result: **2 files, 8 tests, 0 failures** (captured 2025-11-21).

## Layout

- `vitest.config.mjs` - ESM config, `include: src/mcp-apps/**/*.{test,spec}.{js,mjs,ts,tsx}`, `environment: node`.
- `src/mcp-apps/__tests__/fleet-status.test.mjs` - 6 tool-level tests.
- `src/mcp-apps/__tests__/server.test.mjs` - 2 protocol-level tests driven via `InMemoryTransport` + `Client`.
- `package.json` - adds `vitest@^1.6.0` to `devDependencies` and a `test:apps` script. The existing `test` script is left untouched so Python/terminal integration checks still run separately.

## fleet-status.test.mjs

1. **RESOURCE_URI matches the spec URI exactly**
   Guards the contract with UI hosts: `ui://clippy/fleet-status.html` is what Claude/VS Code/widget hosts look up. A drift here silently breaks View rendering.

2. **registers exactly one tool named clippy.fleet-status**
   Confirms `registerFleetStatus` registers precisely the Commander tool this file is responsible for - no accidental extras from `registerAppTool`, and the canonical tool name remains `clippy.fleet-status`.

3. **tool metadata carries `_meta.ui.resourceUri`**
   The MCP-Apps extension requires that a tool advertise its renderable View via `_meta.ui.resourceUri` (spec key `ui/resourceUri`). If this is missing, hosts will list the tool but never mount its UI.

4. **no-state handler returns clippy-principal snapshot with bridge-state error**
   Verifies the L2-5 stub contract: when bridge-state is not wired, the tool still returns `principal: "clippy"`, an ISO `capturedAt`, and a machine-inspectable `error` string containing `bridge-state not wired`. This keeps callers robust during staged rollout.

5. **handler with mock state merges capturedAt and omits error**
   Proves the happy path: a state that implements `state.snapshot()` has its result passed through with `capturedAt` added, and no error field leaks through. This is the shape Commander's real bridge-state will emit in L2-5.

6. **resource handler returns MCP-App HTML content**
   The `ui://clippy/fleet-status.html` resource must return `contents[0].mimeType === "text/html;profile=mcp-app"` and a body containing `<html`. Hosts dispatch on the MIME; the HTML presence guards against a future regression where the fallback ladder silently returns empty text.

## server.test.mjs

Uses `InMemoryTransport.createLinkedPair()` from `@modelcontextprotocol/sdk/inMemory.js` to connect a real `Client` to the real `createAppsServer()` output in-process. This exercises the MCP protocol end-to-end without spawning a subprocess.

7. **createAppsServer exposes SERVER_INFO name and version**
   After `initialize`, `client.getServerVersion()` returns `windows-clippy-mcp-apps` at the version declared by `SERVER_INFO`. Locks the server identity that hosts rely on for capability gating.

8. **tools/list returns exactly one tool - clippy.fleet-status - with ui resourceUri**
   Drives a real `tools/list` request across the in-memory transport and asserts both the single-tool shape and that `_meta.ui.resourceUri` round-trips through the protocol layer (not just local registration). This catches any future regression where the `_meta` key gets stripped during serialization.

## Notes on private-API usage

`fleet-status.test.mjs` reads `server._registeredTools` and `server._registeredResources` to assert registration. These are underscore-prefixed on `McpServer` but are stable-in-practice: they are the only paths the SDK itself uses to index tools/resources, and they are touched on every `setRequestHandler` the SDK wires during `tools/list` and `resources/read`. The protocol-level assertions in `server.test.mjs` intentionally avoid those internals so the suite is not solely dependent on reflection. If the SDK ever renames those maps, tests 2-6 will need an update; tests 1, 7, 8 will not.

## No source patches required

Neither `server.mjs` nor `fleet-status.mjs` was modified. The initial test failures were all in the test file itself (wrong field names - `callback` vs `handler`, resource lookup pattern). The server/tool contract held on the first real run.
