# L3 Tactician: WebView2 Integration Report

Target: Windows Clippy v0.2.0 MCP Apps release.
Scope: L3-2 (WebView2 host), L3-3 (Node bridge), L3-4 (fleet snapshot
shape), L3-5 (list_changed signal & publish path), L3-FW-1 / L3-FW-3
(hostile-input hardening + vitest). Out of scope, tracked separately:
L3-6 server-side principal enforcement, L3-7 `/apps` slash-command
dispatch, BenchPanel/chat UI.

## Files landed

New:
- `widget/WidgetHost/McpAppsBridge.cs` — Node `src/mcp-apps/server.mjs`
  stdio JSON-RPC 2.0 client. Handshake with `protocolVersion
  "2026-01-26"` and the `io.modelcontextprotocol/ui` extension
  capability. Stamps `_meta.clippy = { principal: "clippy", session }`
  on every `tools/call`. Writes `fleet-state.json` atomically at
  `%LOCALAPPDATA%\WindowsClippy\fleet-state.json`.
- `widget/WidgetHost/FleetStateSnapshot.cs` — C# record shape mirroring
  the `DEFAULT_SNAPSHOT` in `src/mcp-apps/bridge-state.mjs`. Defense in
  depth: caps tabs at 256, groups at 64, strings at 1024 chars before
  serialization; coerces principal to literal `"clippy"`.
- `widget/WidgetHost/McpAppsHost.cs` — `UserControl` wrapping
  `Microsoft.Web.WebView2.Wpf.WebView2`. Implements the View-Host
  JSON-RPC bridge over `postMessage` and a locked-down virtual-host
  mapping with per-response CSP injection.
- `src/mcp-apps/__tests__/hostile-input.test.mjs` — six vitest cases
  locking in the L3-FW-1 caps and the L3-FW-3 round-trip serialization
  bound via the `clippy.fleet-status` tool handler.
- `docs/mcp-apps/tactician/l3-webview2-integration.md` — this report.

Modified:
- `src/mcp-apps/bridge-state.mjs` — hardened `FleetState._merge`:
  - `principal` is coerced to literal `"clippy"`.
  - Arrays are clamped: `tabs.list <= 256`, `groups.list <= 64`,
    `events.recent <= 20`.
  - Strings are capped at 1024 characters via `safeString`.
  - `__proto__`, `constructor`, `prototype` keys are dropped by
    `safeShallow` before reaching the merged state.
  - Recursion capped at 6 levels; beyond that, payloads become `null`.
  - New named exports `MAX_TABS`, `MAX_GROUPS`, `MAX_EVENTS` for test
    pinning.
- `widget/WidgetHost/MainWindow.xaml` — `SessionMeta` TextBlock is now
  collapsed by default; a `Border x:Name="AppsHostSlot"` (height 140,
  rounded 6px, themed border) takes its place in the session-meta row.
  The TextBlock is retained for `/apps-dev` toggle (L3-7 scope), hence
  `Visibility="Collapsed"` rather than deletion.
- `widget/WidgetHost/MainWindow.xaml.cs`:
  - New fields `_appsBridge`, `_appsHost`.
  - New helpers `BuildFleetSnapshot`, `PublishFleetStateToAppsHost`,
    `InitializeMcpAppsHost`.
  - `UpdateSessionMeta` gates text writes on `SessionMeta.Visibility ==
    Visibility.Visible` so collapsed runs do not churn UI.
  - `RefreshCommanderAggregateMeta` now also fires the publish + bare
    list_changed signal, on the dispatcher thread.
  - `OnClosing` disposes `_appsHost` and awaits `_appsBridge` for up to
    3 seconds before the rest of the shutdown proceeds.
  - `InitializeMcpAppsHost` runs after `Closing` is wired, so a spawn
    failure cannot block window creation.

## CSP (verbatim)

Applied on every `WebResourceRequested` whose URI host is
`clippy-ui.local`:

```
default-src 'self' https://clippy-ui.local;
script-src 'self' 'unsafe-inline' https://clippy-ui.local;
style-src 'self' 'unsafe-inline' https://clippy-ui.local;
img-src 'self' data: https://clippy-ui.local;
font-src 'self' data: https://clippy-ui.local;
connect-src 'self' https://clippy-ui.local;
frame-ancestors 'self'
```

`X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`
are also set on every response. The response is built from a byte
array read from the resolved file path so the header ships *with* the
document instead of depending on a `<meta http-equiv>` tag inside the
bundled HTML.

## ui:// to https://clippy-ui.local translation

WebView2 does not support registering arbitrary URI schemes, and MCP
Apps Views are addressed by `ui://clippy/<path>`. The host pins a
virtual hostname to the on-disk `dist/mcp-apps/views/` folder:

```csharp
core.SetVirtualHostNameToFolderMapping(
    "clippy-ui.local",
    viewsFolder,
    CoreWebView2HostResourceAccessKind.DenyCors);
```

`McpAppsHost.TranslateUiUriToHttps` rewrites `ui://clippy/<p>` into
`https://clippy-ui.local/<p>` before `Navigate`. `NavigationStarting`
rejects anything outside that origin (plus `about:blank`),
`NewWindowRequested` is hard-blocked, `PermissionRequested` denies all.

## Views folder resolution

Tried in order:
1. `AppContext.BaseDirectory\mcp-apps\views` (the `Content /
   CopyToOutputDirectory = PreserveNewest` target for
   `..\..\dist\mcp-apps\views\*.html`).
2. Dev fallback: walk up to 8 parents from `BaseDirectory` looking for
   `dist\mcp-apps\views` with a `fleet-status.html` inside.
3. Temp fallback folder under `%TEMP%\WindowsClippy\mcp-apps-fallback`,
   seeded with a static "VIEW BUNDLE MISSING" HTML banner.

## JSON-RPC handshake trace (observed)

```
host -> server   initialize { protocolVersion: "2026-01-26",
                              capabilities.extensions["io.modelcontextprotocol/ui"]: { mimeTypes: ["text/html;profile=mcp-app"] } }
server -> host   { result: { protocolVersion, capabilities, serverInfo } }
host -> server   notifications/initialized
(steady state)
host -> server   tools/call { name: "clippy.fleet-status", arguments: {},
                              _meta.clippy: { principal: "clippy", session: "<commander-sid>" } }
server -> host   { result: { structuredContent: { principal: "clippy", ... } } }
host -> view     PostWebMessage "{ jsonrpc: 2.0, id: <viewId>, result: <forwarded> }"
```

`_meta.clippy.principal` is always `"clippy"`, hardcoded in
`McpAppsBridge.BuildToolCallParams`. The server does not yet enforce
this (L3-6); it only reads it defensively from the fleet-state file.

## Hostile-input test results

`npm run test:apps`

```
Test Files  3 passed (3)
     Tests  14 passed (14)
```

Breakdown:
- `src/mcp-apps/__tests__/fleet-status.test.mjs` — 6/6 (unchanged).
- `src/mcp-apps/__tests__/server.test.mjs` — 2/2 (unchanged).
- `src/mcp-apps/__tests__/hostile-input.test.mjs` — 6/6 (new):
  1. principal merged from attacker input is coerced to `"clippy"`.
  2. `tabs.list` > 256 entries is clamped to 256.
  3. `__proto__` / `constructor` / `prototype` keys are dropped, no
     prototype pollution observable on `Object.prototype`.
  4. Oversize strings are truncated to 1024 chars.
  5. Non-finite / NaN counters become 0.
  6. End-to-end: the `clippy.fleet-status` tool handler, given a merged
     state, emits a `structuredContent` payload whose `tabs.list.length
     <= 256` and `groups.list.length <= 64`.

## L3-5 notification wire: covered here, what remains

Covered:
- Widget to file: `McpAppsBridge.PublishFleetStateAsync(snapshot)`
  atomically rewrites `fleet-state.json` on every
  `CommanderHub.GroupsChanged`, `SessionRegistered`,
  `SessionUnregistered` event.
- Host to View: `McpAppsHost.PostResourceListChangedAsync` fires a
  *bare* `notifications/resources/list_changed` (no payload). Views are
  responsible for re-fetching via `resources/read` or `tools/call`.

Remaining (deferred):
- Server to Host push of `notifications/resources/list_changed` when
  the file mtime advances. Today the widget drives both sides (file
  write + view signal), so the notification path is effectively a
  widget-local fire. A future todo should:
  1. Add a file watcher (or `FleetState.subscribe`) inside the Node
     server that emits `notifications/resources/list_changed` on the
     stdio channel.
  2. Route that notification through
     `McpAppsBridge.NotificationReceived` into
     `McpAppsHost.PostResourceListChangedAsync` so the view re-fetches
     even if the widget UI never toggled.
- Private `clippy/notifications/event-stream` channel — the Host side
  is implemented (`PostEventStreamAsync`); no producer is wired yet.
  The first consumer will likely be CopilotEvent rebroadcast.

## Deviations from brief

1. `BuildToolCallParams` is hand-rolled as a `StringBuilder`, not an
   anonymous-type `JsonSerializer.Serialize` call. Reason:
   `_meta.clippy.principal` cannot be expressed as an anonymous-type
   member name without a backing dictionary, and we specifically want
   the literal `"clippy"` to appear in the wire bytes so a grep over
   captured traffic always finds it.
2. `McpAppsBridge.StartAsync` eagerly writes the first snapshot to
   `fleet-state.json` *before* spawning Node so the server's first
   `FleetState._readFromPath` sees real widget state, not
   `DEFAULT_SNAPSHOT`. Brief did not prescribe this ordering; it
   removes an otherwise reliable first-render flash of default data.
3. `AppsHostSlot` is styled (dark background, rounded border) so the
   view surface reads visually as a panel while loading. Brief asked
   only for a height-140 `Border`.
4. `dotnet build -c Debug` reports one CS0067 warning in
   `ConPtyConnection.cs` (unused `SessionCardUpdated` event). This is
   pre-existing, unchanged by this landing, and deliberately untouched.
5. The vitest `hostile-input` test originally failed on
   `Object.prototype.hasOwnProperty.call(tab, "constructor")` because
   `bridge-state.mjs` was using `.map(safeShallow)` which bound each
   array index as the `depth` argument; entry 6+ hit the recursion cap
   and became `null`. Fix was to wrap with an explicit lambda
   `(v) => safeShallow(v)` so depth resets cleanly per element.

## Validation output tails

```
> npm run test:apps
Test Files  3 passed (3)
     Tests  14 passed (14)

> node scripts/smoke-apps-server.mjs
ALL PASS

> cd widget\WidgetHost
> dotnet build -c Debug /nologo
WidgetHost -> E:\Windows-Clippy-MCP\widget\WidgetHost\bin\Debug\net8.0-windows\WidgetHost.dll
Build succeeded.
    1 Warning(s)    (pre-existing CS0067 in ConPtyConnection.cs)
    0 Error(s)
```
