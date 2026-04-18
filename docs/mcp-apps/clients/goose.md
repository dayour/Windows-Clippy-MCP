# Goose (Block) — Clippy MCP Apps Client Config

Status: v0.2.0. Requires Goose >= 1.0 with MCP Apps extension support.
See https://block.github.io/goose/ for installation.

## Install prerequisite

```powershell
npm install -g @dayour/windows-clippy-mcp
```

## Client config

Add to `~/.config/goose/config.yaml`:

```yaml
extensions:
  windows-clippy:
    type: stdio
    cmd: npx
    args:
      - "@dayour/windows-clippy-mcp"
      - "--apps"
      - "--stdio"
    enabled: true
```

Reload Goose:

```powershell
goose configure
```

## Expected behavior

Goose discovers the 8 Clippy tools registered in v0.2.0
(`clippy.fleet-status`, `clippy.commander.state`, `clippy.commander.submit`,
`clippy.broadcast`, `clippy.link-group`, `clippy.session-inspector`,
`clippy.agent-catalog`, `clippy.telemetry`). Because Goose is
primarily a terminal client, the inline View rendering is limited — Goose
renders the structured tool result (JSON) and provides a link to open the
`ui://` resource in an external browser via its Apps UI preview endpoint.

## Principal

Goose passes `_meta.client = "goose"` by default. To assert Clippy as the
principal (required for Commander-authoritative tools), configure Goose to
add `_meta.clippy.principal = "clippy"` via its tool-metadata hook.

## Recommended usage

Goose is ideal for headless, scripted Clippy invocations:

```bash
goose run "use clippy.fleet-status to report the active terminal count"
```

Invocations that mutate state (`clippy.commander.submit`,
`clippy.broadcast`, `clippy.link-group`) require the widget to be running
locally; Goose returns the tool result but UI side-effects materialize in
the widget, not in Goose.
