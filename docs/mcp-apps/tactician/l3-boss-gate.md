# L3 Tactician — Boss Gate: PASS (72.1/100)

> "The Commander Fight" — Widget becomes its own MCP Apps host. Fleet Status
> View rendered inline via WebView2, Clippy is the principal inside its own
> widget. Live counters tick from real CommanderHub data.

## Verdict

**PASS** on attempt 3 (rubber-duck `l3-commander-fight`, 2026-04-18).
Weighted total **72.1/100** (threshold 70).

| Criterion  | Weight | Score | Weighted |
|------------|--------|-------|----------|
| Build      | 0.20   | 95    | 19.0     |
| Conformance| 0.25   | 82    | 20.5     |
| Integration| 0.20   | 78    | 15.6     |
| Live smoke | 0.20   | 70    | 14.0     |
| Observability | 0.15 | 20   |  3.0     |
| **Total**  |        |       | **72.1** |

Attempts: 1 (37.25 critical-fail), 2 (66.1 rubric-fail), **3 (72.1 PASS)**.

## What shipped

### L3-1 — WebView2 NuGet
`Microsoft.Web.WebView2` pinned in `widget/WidgetHost/WidgetHost.csproj`.
Cold start delta within budget.

### L3-2 — `McpAppsHost.cs`
WebView2-based host rendering `ui://clippy/fleet-status.html`. Key pieces:
- `SetVirtualHostNameToFolderMapping` maps `ui://` → `https://clippy-ui.local/`.
- CSP enforced via `WebResourceRequested` (not `<meta>`): `default-src 'self'
  https://clippy-ui.local; script-src 'self' 'unsafe-inline'
  https://clippy-ui.local; connect-src 'self' https://clippy-ui.local;
  frame-ancestors 'self'`.
- `iframe sandbox="allow-scripts"` only; no `allow-same-origin`.
- `PostInitializeResponseAsync` emits SDK-schema-correct `McpUiInitializeResult`
  (`protocolVersion`, `hostInfo`, `hostCapabilities`, `hostContext`) + passthrough
  `principal{kind,id,session}`.
- `ViewInitialized` event fires from `ui/notifications/initialized` so the host
  can re-seed state after the SDK wires `ontoolresult`.
- `DumpViewTextAsync()` exposes live DOM text for evidence + L4 diagnostics.

### L3-3 — `McpAppsBridge.cs`
JSON-line bridge to the Node MCP Apps server. Extended protocol:
`mcp-apps.tool.call`, `mcp-apps.tool.result`, `mcp-apps.notification`,
`mcp-apps.view.mount`, `mcp-apps.view.unmount`. Reuses existing stdio terminal
bridge plumbing.

### L3-4 — Fleet Status inline + `/apps-dev` fallback
`MainWindow.xaml` ships `AppsHostSlot` (`McpAppsHost`) + `SessionMeta` (text
fallback). `/apps-dev` slash toggles visibility. Both panels read from the
same `RefreshCommanderAggregateMeta()` snapshot — structural parity, single
data source.

### L3-5 — Notification wire
- Per-mount `ui/notifications/tool-result` via `PushFleetToolResultToViewAsync`.
- Bare `notifications/resources/list_changed` signal (no delta envelope —
  views re-fetch via `resources/read`, per spec).
- Private `clippy/notifications/event-stream` for general CommanderHub events
  that don't map to a specific tool call in flight.

### L3-6 — Principal assertion (tamper-proof)
`src/mcp-apps/principal.mjs` uses `Object.prototype.hasOwnProperty.call` at
every key-access step. Fixes the inherited-property bypass where
`Object.create({ principal: 'clippy' })` formerly passed. Three regression
tests added (`npm run test:apps`: 28/28 pass).

### L3-7 — Slash commands
`/apps list`, `/apps mount <uri>`, `/apps unmount`, `/apps inspect <uri>`,
and `/apps-dev` all wired in `MainWindow.xaml.cs`. `inspect` unwraps the
`result` envelope so operator output is human-readable.

## ViewBridgeShim: WebView2 / ext-apps SDK compatibility layer

The ext-apps SDK's `PostMessageTransport` defaults to
`new N(window.parent, window.parent)` and strictly filters inbound messages
by `event.source === this.eventSource`. In a WebView2 top-level document,
`window.parent === window`, so the SDK's default works structurally — but
nothing routes messages between the view and the host.

**Shim strategy** (injected via `AddScriptToExecuteOnDocumentCreatedAsync`):

1. **Outbound**: patch `window.postMessage` to forward via
   `chrome.webview.postMessage`. Do NOT call the original postMessage
   (would loop the message back into the SDK's own listener).
2. **Inbound**: subscribe to `chrome.webview.addEventListener('message', ...)`,
   re-dispatch as `new MessageEvent('message', { data, origin, source: window })`.
   `source: window` satisfies both:
   - Chromium's MessageEvent constructor (requires Window or MessagePort —
     rejects EventTarget subclasses with `TypeError`).
   - SDK's strict identity check (`window === window.parent === eventSource`).
3. **Debug channel**: `__clippy_debug__:<tag>:<payload>` prefix for shim
   observability. `OnWebMessageReceived` intercepts before JSON parse.

## Live-smoke evidence

DOM dumps via `McpAppsHost.DumpViewTextAsync()` after handshake completion:

```
[22:42:38.692] McpAppsHost[view]: ui/initialize id=0
[22:42:38.710] McpAppsHost[view]: ui/notifications/initialized
[22:42:38.710] OnAppsViewInitialized: re-seeding fleet state post-handshake.

[22:42:41.735] view text dump (t+3s): "Clippy Fleet Status
CONNECTED
1  TOTAL TABS
0  IDLE
1  RUNNING
0  EXITED
0  GROUPS
none  ACTIVE GROUP
75  AGENT CATALOG
3:42:38 PM  CAPTURED"

[22:42:46.763] view text dump (t+8s): "... 3:42:45 PM CAPTURED"
```

Evidence validates:
- Initial render: **CONNECTED** pill (not "CONNECTING" placeholder).
- Real counters from live CommanderHub state (1 tab, 75 agents).
- Live tick: CAPTURED timestamp advanced 3:42:38 → 3:42:45, proving view
  consumed successive post-handshake tool-result pushes (the 30+
  `posted tool-result bytes=518` log entries are actually applied to DOM).

## Carry-forward defects to L4

1. **[MEDIUM] `PublishFleetStateAsync` EACCES on file publish** — noisy
   `Access to the path is denied` errors in log. Non-blocking for the
   in-process WebView2 path but hurts indirect refresh paths.
2. **[MEDIUM] Dual update model is host-specific** — live `tool-result`
   pushes work inside the widget because we own the view lifecycle. For
   cross-host parity (VS Code / Claude Desktop rendering the same View),
   we need a portable refresh contract.
3. **[MEDIUM] Observability at 20/100** — structured trace IDs,
   per-tool-call latency/status counters, and host↔bridge↔server
   correlation deferred to L4-7/L4-8.
4. **[LOW] Debounce pre-handshake tool-result flood** — 30+ discarded
   pushes before `ui/notifications/initialized` land. Cosmetic for now.

## Security audit summary

- CSP enforced at response-header layer (not `<meta>`). Confirmed via
  DevTools Network panel and `WebResourceRequested` instrumentation.
- iframe sandbox: `allow-scripts` only. No `allow-same-origin`,
  `allow-top-navigation`, or `allow-popups`.
- Virtual host isolation: `clippy-ui.local` resolves only to the packaged
  views folder; no fallback to arbitrary URLs.
- Principal assertions: every tool call server-side verifies `_meta.clippy.
  principal === "clippy"` using own-property checks; three regression
  tests cover the inherited-property and prototype-pollution vectors.
- Escape attempts blocked during security sub-gate: `window.external`
  (undefined in WebView2 when ObjectForScripting not set), parent navigation
  (blocked by frame-ancestors CSP), shell execution (no WebView2 API surface
  exposes it).

## Next level

Advance to **L4 Commander** — every Commander capability becomes an MCP App:
broadcast, link-group, agent catalog, session inspector, per-tab terminal
view. Eat our own dog food: the widget's BenchPanel becomes a View.

Gate file: `docs/mcp-apps/commander/l4-boss-gate.md` (to be written).
