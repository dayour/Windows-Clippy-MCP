# Changelog

All notable changes to **Windows Clippy MCP** will be recorded here.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.0 - MCP Apps Native Release

### Added
- **MCP Apps server surface** (`src/mcp-apps/`): 8 first-class tools, all advertising `ui://clippy/*.html` Views and asserting the Clippy principal on every write.
  - `clippy.fleet-status` (read) - live tab / group / commander counters.
  - `clippy.agent-catalog` (read) - bundled and user agents.
  - `clippy.commander.state` / `clippy.commander.submit` - Commander session snapshot and prompt submission.
  - `clippy.broadcast` (write) - fan out prompts to all tabs, a group, or an id list.
  - `clippy.link-group` (read + link/unlink/broadcast writes) - group membership management.
  - `clippy.session-inspector` (read) - commander / tab / group / agent introspection.
  - `clippy.telemetry` (read) - recent tool-call traces with start/end events and durations.
- **Widget as MCP Apps host**: WebView2-embedded Views with strict CSP; inline tool-result and `resources/list_changed` notifications.
- **Shared intent pipeline**: `McpAppsBridge.PublishIntentAsync` is the single write path into `commander-intents.jsonl`. Slash commands (`/link`, `/unlink`, `/broadcast`, `/group`) and external MCP clients are routed through an identical watcher -> handler pipeline.
- **Principal enforcement**: every write tool rejects missing `_meta.clippy` assertion with `clippy.principal.rejected`.
- **Telemetry wrapper**: `wrapToolWithTelemetry` stamps each invocation with a trace id; `tool.start` + `tool.end` events with duration and status; `CLIPPY_TELEMETRY_SILENT=1` opts out of stderr in CI.
- **Observability**: widget writes `%APPDATA%\Windows-Clippy-MCP\logs\widgethost.log` with trace-correlated intent ids and dispatch outcomes.
- **CSP-strict fallback HTML** for every View URI so hosts without the React bundle still render a compliant response.

### Changed
- Toolbar slash commands no longer call `CommanderHub` directly. They publish intents through `McpAppsBridge.PublishIntentAsync` and fail closed if the Apps sidecar is unavailable. The UI is now a client of its own MCP tools.
- Commander is now an independent session with its own LLM loop - it no longer pipes the chat box straight to the active terminal.
- Fleet state and commander slice are republished as MCP Apps resources on every change.

### Fixed
- (Pre-existing) runtime `--no-alt-screen` flag leaking into Copilot prompt runtime.
- Bundled agents overwrite stale user copies when content changes.

### Security
- Zero-trust iframe sandbox (`sandbox="allow-scripts"`, no `allow-same-origin`).
- Principal assertion hardened against prototype inheritance bypass.
- Hostile-input contract tests for injected state sources.

### Test posture
- Vitest: 53/53 across 7 files (`telemetry`, `principal`, `fleet-status`, `hostile-input`, `commander`, `server`, `fleet-tools`).
- `dotnet build widget/WidgetHost`: clean (1 pre-existing warning).
- End-to-end live smoke reproduced three times across L2 / L3 / L4 with log evidence.

### Migration notes
- MCP clients should now advertise `_meta.clippy = { sessionId, principal: "clippy" }` on all write-class tool calls. Missing assertions yield a structured error instead of silently executing.
- The widget requires the MCP Apps sidecar (Node) to dispatch `/link`, `/unlink`, `/broadcast`, `/group`. If the sidecar is disabled, these commands fail closed with a clear operator message.

## 0.1.x

Earlier development releases. See git history.
