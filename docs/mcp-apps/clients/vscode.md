# VS Code (Agent Mode) — Clippy MCP Apps Client Config

Status: v0.2.0. Requires VS Code Insiders with MCP Apps support, or VS Code stable
with the MCP extension installed.

Evidence status: configuration guidance only. The repo currently proves the
generic UI-capable MCP Apps host contract, but does not yet contain executable
VS Code product-host validation. See `../host-conformance.md`.

## Install prerequisite

```powershell
npm install -g @dayour/windows-clippy-mcp
```

Verify:

```powershell
npm ls -g @dayour/windows-clippy-mcp
```

## Client config

Add to your workspace `.vscode/mcp.json`:

```json
{
  "servers": {
    "windows-clippy": {
      "type": "stdio",
      "command": "npx",
      "args": ["@dayour/windows-clippy-mcp", "--apps", "--stdio"]
    }
  }
}
```

Or global `settings.json`:

```json
{
  "mcp.servers": {
    "windows-clippy": {
      "command": "npx",
      "args": ["@dayour/windows-clippy-mcp", "--apps", "--stdio"],
      "env": {}
    }
  }
}
```

## Target behavior (not yet product-verified)

After restarting VS Code, agent mode lists the 8 Clippy tools actually
registered by v0.2.0 (`clippy.fleet-status`, `clippy.commander.state`,
`clippy.commander.submit`, `clippy.broadcast`, `clippy.link-group`,
`clippy.session-inspector`, `clippy.agent-catalog`, `clippy.telemetry`). `clippy.terminal-tab`
is reserved for a future release and is not present in v0.2.0.

Invoking `clippy.fleet-status` renders `ui://clippy/fleet-status.html`
inline in the agent result pane. The View reads live CommanderHub counters
from `%LOCALAPPDATA%\WindowsClippy\fleet-state.json` if the widget is
running; otherwise counters show zero and the View displays a
"widget offline" banner.

## Principal assertion

Tool calls from VS Code must pass `_meta.clippy.principal = "clippy"`.
Clients that do not forward `_meta` are rejected with:

```
ERROR: principal assertion required (_meta.clippy.principal)
```

This is enforced by `wrapToolWithPrincipal` in `src/mcp-apps/server.mjs`.
