# Claude Desktop — Clippy MCP Apps Client Config

Status: v0.2.0. Requires Claude Desktop with MCP Apps extension support
(Anthropic's `@modelcontextprotocol/ext-apps/host` must be available in
the Claude Desktop runtime).

Evidence status: configuration guidance only. The repo currently proves the
generic UI-capable MCP Apps host contract, but does not yet contain executable
Claude Desktop product-host validation. See `../host-conformance.md`.

## Install prerequisite

```powershell
npm install -g @dayour/windows-clippy-mcp
```

## Client config

Edit `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "windows-clippy": {
      "command": "npx",
      "args": ["@dayour/windows-clippy-mcp", "--apps", "--stdio"]
    }
  }
}
```

Restart Claude Desktop.

## Target behavior (not yet product-verified)

All 8 Clippy tools registered in v0.2.0 appear in the tool picker
(`clippy.fleet-status`, `clippy.commander.state`, `clippy.commander.submit`,
`clippy.broadcast`, `clippy.link-group`, `clippy.session-inspector`,
`clippy.agent-catalog`, `clippy.telemetry`). Invoking `clippy.fleet-status` renders the bundled
UIResource inline. `clippy.commander.submit` is rejected unless the caller
passes `_meta.clippy.principal = "clippy"` and a `session` string.

## Limitations (v0.2.0)

- Claude Desktop does not currently forward `resources/list_changed`
  notifications; Views refresh on next tool call instead.
- `clippy.terminal-tab` is reserved for a future release and is not
  registered in v0.2.0.
- Views that require live widget backends (`commander`, `broadcast`,
  `link-group`, `session-inspector`) fall back to read-only snapshots
  when invoked from Claude Desktop standalone.
