# Windows Clippy MCP Apps: Wire Protocol

Status: v0.2.0 -- first release.

This document is the authoritative reference for the wire protocol spoken
between `widget/WidgetHost/McpAppsBridge.cs` (the C# client) and
`src/mcp-apps/server.mjs` (the Node server). External MCP Apps hosts
(Claude Desktop, VS Code, ChatGPT) that drive Clippy tools must follow
the same envelope.

See also: [architecture.md](./architecture.md) and
[cookbook.md](./cookbook.md).

## Base protocol

- **MCP core:** JSON-RPC 2.0 per MCP 2024-11-05. The bridge advertises
  `protocolVersion = "2026-01-26"` (see `McpAppsBridge.cs` line 42) but
  all method names, framing, and capability negotiation follow the
  original 2024-11-05 contract.
- **Apps extension:** `@modelcontextprotocol/ext-apps` v1.6.0. The server
  imports `registerAppTool`, `registerAppResource`, and `getUiCapability`
  from `@modelcontextprotocol/ext-apps/server`.

On `initialize`, the server logs whether the client advertised the Apps
UI capability:

```
[clippy-apps] client capabilities negotiated extension=<id> ui-apps=<bool>
```

## Clippy `_meta` extensions

Every `tools/call` originating from the widget carries a `_meta.clippy`
block. The server rejects calls without it.

### `_meta.clippy.principal`

Required. Must be the literal string `"clippy"`. Any other value produces
a structured error:

```
[clippy.principal.rejected] Windows Clippy tool calls must assert the
Clippy principal: principal must equal "clippy", received <value>
```

Error code: `clippy.principal.rejected`
(`src/mcp-apps/principal.mjs`, `PRINCIPAL_ERROR_CODE`).

### `_meta.clippy.session`

Optional. String, 1 to 256 characters. Identifies the Commander session
that authored the call. The bridge always stamps this with the active
Commander session id (`McpAppsBridge.BuildToolCallParams`). Telemetry and
intent-log entries propagate the session field so downstream consumers
can correlate actions to a specific Commander run.

### `_meta.clippy.trace`

Optional. Hex string, 8-32 characters. A caller-supplied trace id for
distributed tracing. If absent, `telemetry.mjs` generates a fresh 16-hex
id via `crypto.randomBytes(8)`. Emitted on every `tool.start` /
`tool.end` log line as `trace`.

### `_meta.ui.resourceUri`

Declared on the **server** side when registering a tool. Points the host
at the corresponding View:

```js
_meta: { ui: { resourceUri: "ui://clippy/fleet-status.html" } }
```

Resource URIs in use (see tool modules under `src/mcp-apps/tools/`):

- `ui://clippy/fleet-status.html`
- `ui://clippy/commander.html`
- `ui://clippy/broadcast.html`
- `ui://clippy/link-group.html`
- `ui://clippy/session-inspector.html`
- `ui://clippy/agent-catalog.html`

## Example `tools/call` envelope

```json
{
  "jsonrpc": "2.0",
  "id": 17,
  "method": "tools/call",
  "params": {
    "name": "clippy.commander.submit",
    "arguments": { "prompt": "rebuild all tabs", "mode": "Agent" },
    "_meta": {
      "clippy": {
        "principal": "clippy",
        "session": "cmdr-2f9a",
        "trace": "a1b2c3d4e5f60708"
      }
    }
  }
}
```

See `McpAppsBridge.BuildToolCallParams` (lines 263-280) for the exact
serializer. Note that `_meta.clippy` lives on the `params` object at the
same level as `arguments`, **not** nested under `arguments`.

## Intent envelope schema

Mutating tools (`clippy.commander.submit`, `clippy.broadcast`,
`clippy.link-group` with `op` in `link|unlink|broadcast`) do not act
directly. They append a JSONL record to
`%LOCALAPPDATA%\WindowsClippy\commander-intents.jsonl` (configurable via
`CLIPPY_COMMANDER_INTENTS_PATH`). The widget tails the file, deduplicates
by `id`, and dispatches.

Fields are root-level on the intent object -- **not** nested under
`payload`.

```json
{
  "id": "<uuid>",
  "kind": "<kind>",
  "session": "<commander-session-id-or-null>",
  "enqueuedAt": "2025-01-15T12:34:56.789Z",
  "...": "kind-specific fields"
}
```

### Kinds in v0.2.0

| Kind                    | Fields (in addition to common)                                        | Source tool                                    |
|-------------------------|-----------------------------------------------------------------------|------------------------------------------------|
| `commander.submit`      | `prompt`, `mode` (nullable `"Agent"` or `"Plan"`)                     | `clippy.commander.submit`                      |
| `broadcast.send`        | `prompt`, `targets: { mode: "ids"\|"group"\|"all", ids?, label? }`, `force` | `clippy.broadcast`                        |
| `linkgroup.link`        | `sessionId`, `label`                                                  | `clippy.link-group` (`op="link"`)              |
| `linkgroup.unlink`      | `sessionId`                                                           | `clippy.link-group` (`op="unlink"`)            |
| `linkgroup.broadcast`   | `label`, `prompt`, `force`                                            | `clippy.link-group` (`op="broadcast"`)         |

`clippy.link-group` with `op="list"` is read-only and does not emit an
intent.

### Widget-side dispatch

`McpAppsBridge.DispatchIntentLine` (line 526) inspects the `kind`:

- `commander.submit` -> `CommanderIntentReceived` event.
- `broadcast.send` -> `BroadcastIntentReceived` event.
- `linkgroup.*` -> `LinkGroupIntentReceived` event (the suffix after
  `linkgroup.` is the op name).

Events are consumed in `MainWindow.xaml.cs`.

## Telemetry log lines

Every wrapped tool invocation emits two JSONL records to **stderr** with
the prefix `[clippy-telemetry]`. This is separate from the MCP transport;
stdout carries JSON-RPC only.

```json
{
  "t": "2025-01-15T12:34:56.789Z",
  "level": "info",
  "event": "tool.start",
  "tool": "clippy.fleet-status",
  "trace": "a1b2c3d4e5f60708",
  "session": "cmdr-2f9a",
  "durationMs": 0,
  "status": "running"
}
```

```json
{
  "t": "2025-01-15T12:34:56.812Z",
  "level": "info",
  "event": "tool.end",
  "tool": "clippy.fleet-status",
  "trace": "a1b2c3d4e5f60708",
  "session": "cmdr-2f9a",
  "durationMs": 23,
  "status": "ok"
}
```

Error paths add `code` and `message` attributes and set
`level="error"`, `status="err"`. Set env `CLIPPY_TELEMETRY_SILENT=1` to
suppress the stream (tests use this).

Events are `tool.start` and `tool.end`. Counters are accumulated in
`src/mcp-apps/telemetry.mjs` and returned by the `clippy.telemetry` tool.

## Principal enforcement contract

`wrapToolWithPrincipal(handler)` is the single chokepoint. It inspects
the SDK-provided `extra` argument on every tool dispatch and throws
`PRINCIPAL_ERROR_CODE` before the handler body runs. Accepts both SDK
arities:

- `(args, extra)` when the tool declares an input schema.
- `(extra)` when it does not.

New tools MUST wrap their handler (see the cookbook). The wrapper is
`export`ed from `src/mcp-apps/principal.mjs`.

## Fleet state write path

The widget is the authoritative writer; the server is the reader.

- **Write:** `MainWindow.BuildFleetSnapshot` builds a
  `FleetStateSnapshot`, which `McpAppsBridge.PublishFleetStateAsync`
  serializes to `%LOCALAPPDATA%\WindowsClippy\fleet-state.json` (see
  `BuildFleetStatePath`).
- **Read:** `FleetState._readFromPath` (in
  `src/mcp-apps/bridge-state.mjs`) uses `statSync().mtimeMs` as a cache
  key and re-parses on change. Hostile-input hardening (L3-FW-1) clamps
  list lengths, strips prototype-pollution keys, and coerces
  `principal` to `"clippy"` regardless of file content.

### Known issue: L4-FW-1

On concurrent writes (widget and an external state producer racing),
`PublishFleetStateAsync` can fail with `EACCES` on Windows. It is
non-blocking -- the widget logs and retries on the next snapshot -- but
tracked as **L4-FW-1** for a future fix (likely a named-mutex guard or
atomic-rename pattern). Tools reading the file tolerate a brief stale
read; the next `includeEvents` pull will reconverge.

## Continue reading

- [architecture.md](./architecture.md) -- the why and the high-level
  picture.
- [cookbook.md](./cookbook.md) -- how to add a new Clippy MCP App.
