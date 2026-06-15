# MCP Apps Host Conformance

Status: audit baseline for `ex-3-host-conformance`.

This document separates three things that were previously mixed together:

1. product-specific proof
2. generic protocol-class proof
3. configuration guidance

If a claim is not backed by an executable harness or an observed host run, it
must be treated as an assumption, not as verified conformance.

## What is executable today

### 1. Generic UI-capable MCP Apps host profile

Runnable:

```powershell
npm run mcp-apps:host-conformance
```

The `ui-capable` section proves:

- stdio `initialize` succeeds
- the server advertises the expected tool surface
- `clippy.fleet-status` advertises `ui://clippy/fleet-status.html`
- `resources/list` and `resources/read` return the expected View
- principal enforcement rejects calls that omit `_meta.clippy`
- the server observes `ui-apps=true` capability negotiation

This is strong protocol evidence for hosts in the same class as VS Code Agent
Mode or Claude Desktop, but it is not product proof for either one.

### 2. Generic headless / non-UI host profile

The same harness proves a host that does not advertise MCP Apps UI can still:

- initialize
- discover tools
- call read-only tools successfully with `_meta.clippy`
- negotiate with `ui-apps=false`

This is the closest executable evidence we currently have for terminal-first
hosts like Goose. It does not prove Goose-specific preview behavior.

### 3. Widget host rendering

The same harness launches the in-repo `WidgetHost.exe` with an explicit
`--apps-view ui://...` override and validates that the log contains:

- `McpAppsBridge: handshake complete`
- `OnAppsViewInitialized: re-seeding mounted view post-handshake.`
- `PushMountedViewToolResultToViewAsync(...): posted <tool> bytes=...`
- `OnAppsViewInitialized: view text dump: "Clippy Fleet Status ... TOTAL TABS ..."`
- `OnAppsViewInitialized: view text dump: "Clippy Commander ... Connected to the Commander state and submit tools through the app bridge ..."`
- `OnAppsViewInitialized: view text dump: "Clippy Agent Catalog ... Search by name, id, source, or file path ..."`

This is actual product-host evidence for the widget renderer because the WPF
host, WebView2 view, bridge, and server all execute together.

## Current proof matrix

| Host / class | Config documented | Tool discovery proven | `ui://` resource proven | Render proven | Principal gate proven | Mutating tool path proven | Current proof level |
|---|---:|---:|---:|---:|---:|---:|---|
| VS Code | Yes | No product proof | No product proof | No | Yes, server-side only | Yes, server-side only | Documentation plus generic UI-host proof |
| Claude Desktop | Yes | No product proof | No product proof | No | Yes, server-side only | Yes, server-side only | Documentation plus generic UI-host proof |
| Goose | Yes | No product proof | Server-side only | No | Yes, server-side only | Yes, server-side only | Documentation plus generic headless-host proof |
| Widget host | In repo | Yes | Yes | Yes | Yes | Yes | Executable end-to-end proof |

## What is only assumed today

The following claims remain assumptions until proven by product-host runs:

- VS Code actually shows all 8 tools in Agent Mode.
- VS Code actually renders `ui://clippy/fleet-status.html` inline.
- Claude Desktop actually renders the bundled UI resource inline.
- Claude Desktop actually drops or ignores `resources/list_changed`.
- Goose actually offers an external-browser preview flow for `ui://` resources.
- Goose actually has a metadata hook that can stamp `_meta.clippy.principal`.

Those may still be true, but they are not yet engineering evidence.

## Acceptance bar for engineering excellence

A host can be called "engineering-excellence proven" only when all of the
following are true:

1. Product-host launch is exercised in automation or a repeatable operator run.
2. Tool discovery is captured from the actual host.
3. `clippy.fleet-status` is invoked from the actual host.
4. The rendered surface is captured from the actual host, not inferred from
   server-side `resources/read`.
5. A negative call without `_meta.clippy` is shown to fail as expected.
6. At least one mutating tool (`clippy.commander.submit`, `clippy.broadcast`,
   or `clippy.link-group`) is invoked and the intent-log side effect is
   validated.
7. Evidence is rerunnable with a single command or a short documented playbook.

Until a host meets all seven, its docs should say either:

- `Verified: protocol-class only`
- `Verified: widget host`
- `Unverified: configuration guidance`

and should not imply product conformance.
