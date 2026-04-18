# Windows Clippy MCP Apps: Cookbook

Status: v0.2.0 -- first release.

This is a hands-on walkthrough for adding a new MCP App tool to Windows
Clippy. We will build `clippy.notify`, a tool that pushes a toast
notification to the widget and exposes a minimal View at
`ui://clippy/notify.html`.

Cross-references: [architecture.md](./architecture.md) for why the
Clippy-principal model exists, and [protocol.md](./protocol.md) for the
wire envelope every tool must honor.

## Prerequisites

- Node 18+ and `npm install` completed at repo root.
- Windows 11 if you want to exercise the WPF widget end-to-end.
- Familiarity with the existing tools under `src/mcp-apps/tools/`; they
  are the best templates.

Every new tool must:

1. Wrap its handler with `wrapToolWithPrincipal` (mandatory) and
   `wrapToolWithTelemetry` (strongly recommended).
2. Advertise a `ui://clippy/<name>.html` resource.
3. Ship at least one vitest.

## Step 1: scaffold the tool module

Create `src/mcp-apps/tools/notify.mjs`:

```js
import { z } from "zod";
import {
  registerAppTool,
  registerAppResource,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";
import { appendFile, mkdir } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname } from "node:path";
import { wrapToolWithPrincipal } from "../principal.mjs";
import { wrapToolWithTelemetry } from "../telemetry.mjs";

const NOTIFY_VIEW_URI = "ui://clippy/notify.html";
const MAX_TITLE = 128;
const MAX_BODY = 1024;

export function registerNotify(server, { intentsPath, env = process.env } = {}) {
  const resolvedIntents = intentsPath || env.CLIPPY_COMMANDER_INTENTS_PATH || null;

  registerAppTool(
    server,
    "clippy.notify",
    {
      title: "Clippy Notify",
      description: "Push a toast notification to the Clippy widget.",
      inputSchema: {
        title: z.string().min(1).max(MAX_TITLE),
        body: z.string().max(MAX_BODY).optional(),
        level: z.enum(["info", "warn", "error"]).optional(),
      },
      _meta: { ui: { resourceUri: NOTIFY_VIEW_URI } },
    },
    wrapToolWithTelemetry(
      "clippy.notify",
      wrapToolWithPrincipal(async ({ title, body = "", level = "info" } = {}, extra) => {
        if (!resolvedIntents) {
          const err = new Error("[clippy.notify.intents.unavailable] no intents path");
          err.code = "clippy.notify.intents.unavailable";
          throw err;
        }
        const id = randomUUID();
        const session = extra?._meta?.clippy?.session ?? null;
        const intent = {
          id,
          kind: "notify.toast",
          title: title.slice(0, MAX_TITLE),
          body: body.slice(0, MAX_BODY),
          level,
          session,
          enqueuedAt: new Date().toISOString(),
        };
        await mkdir(dirname(resolvedIntents), { recursive: true }).catch(() => {});
        await appendFile(resolvedIntents, JSON.stringify(intent) + "\n", "utf8");
        const payload = { accepted: true, intentId: id };
        return {
          content: [{ type: "text", text: `Toast queued (id=${id}).` }],
          structuredContent: payload,
        };
      }),
    ),
  );

  registerAppResource(
    server,
    "Clippy Notify View",
    NOTIFY_VIEW_URI,
    {
      description: "Stub View for the notify tool.",
      _meta: { ui: { csp: { resourceDomains: [], connectDomains: [] } } },
    },
    async () => ({
      contents: [{ uri: NOTIFY_VIEW_URI, mimeType: RESOURCE_MIME_TYPE, text: NOTIFY_HTML }],
    }),
  );
}

const NOTIFY_HTML = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/><title>Clippy Notify</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'"/>
<style>body{font:13px/1.4 "Segoe UI",sans-serif;margin:12px;color:#111}</style>
</head><body><h1 style="font-size:14px">Clippy Notify</h1>
<p style="color:#666;font-size:11px">Call <code>clippy.notify</code> with title/body/level.</p>
</body></html>`;

export { NOTIFY_VIEW_URI };
```

Key conventions to copy from the existing tools:

- Use `z` (zod) for the input schema; cap strings with `.max(...)`.
- Declare `_meta.ui.resourceUri` on the tool descriptor.
- Always call `wrapToolWithTelemetry(name, wrapToolWithPrincipal(...))`.
- Produce both `content: [{ type: "text", ... }]` and `structuredContent`
  so hosts that do not render the View still get a useful reply.

## Step 2: register in `server.mjs`

Open `src/mcp-apps/server.mjs`. Add the import next to the others:

```js
import { registerNotify } from "./tools/notify.mjs";
```

And in `createAppsServer`, after the existing registrations:

```js
registerNotify(server);
```

Run `node scripts/smoke-apps-server.mjs` to confirm the server still
boots and `tools/list` includes `clippy.notify`.

## Step 3: add a View

For a stub View, the inline HTML returned in Step 1 is sufficient. For a
real React View, create a sibling folder under `src/mcp-apps/views/` and
copy the pattern in `src/mcp-apps/views/fleet-status/`:

```
src/mcp-apps/views/notify/
  notify.html
  main.tsx
  App.tsx
  fallback.html
  vite.config.ts
```

The Vite config uses `vite-plugin-singlefile` so the entire bundle
collapses into a single HTML file at
`dist/mcp-apps/views/notify.html`. CSP remains
`default-src 'self'`. Update your `readViewHtml` to prefer the bundled
path and fall back to `notify/fallback.html`.

Wire `build:views` for the new view by adding a script to
`package.json`:

```json
"build:views:notify": "vite build --config src/mcp-apps/views/notify/vite.config.ts"
```

## Step 4: wire the widget

Because `clippy.notify` uses the shared intent log, the widget side must
recognize the new `kind`.

In `widget/WidgetHost/McpAppsBridge.cs`, extend the `DispatchIntentLine`
switch (around line 537):

```csharp
if (string.Equals(kind, "notify.toast", StringComparison.Ordinal))
{
    DispatchNotify(root, id);
    return;
}
```

Add a new event:

```csharp
public event EventHandler<NotifyIntent>? NotifyIntentReceived;
```

And a record + dispatcher that mirrors `CommanderIntent` and
`BroadcastIntent` conventions. Consume the event in
`widget/WidgetHost/MainWindow.xaml.cs` by subscribing in the same place
`CommanderIntentReceived` and `BroadcastIntentReceived` are wired and
calling your toast-display helper.

For pure side-channel features that do not require the widget,
skip this step; external hosts can still read the intent JSONL and act.

Remember: **do not** add an alternate write path. All toolbar / hotkey
paths must route through `McpAppsBridge.PublishIntentAsync`
(the L4-9 invariant; see [architecture.md](./architecture.md)).

## Step 5: write the vitest

Create `src/mcp-apps/__tests__/notify.test.mjs`:

```js
import { describe, it, expect, beforeEach } from "vitest";
import { tmpdir } from "node:os";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerNotify } from "../tools/notify.mjs";
import { PRINCIPAL_ERROR_CODE } from "../principal.mjs";

function makeServer() {
  return new McpServer(
    { name: "notify-test", version: "0.0.0-test" },
    { capabilities: { tools: {}, resources: { listChanged: true } } },
  );
}

function callTool(server, name, args, meta) {
  const handler = server._registeredTools?.[name]?.callback
    ?? server.server._requestHandlers.get("tools/call");
  return handler(args, { _meta: meta });
}

describe("clippy.notify", () => {
  let dir, intentsPath;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "notify-"));
    intentsPath = join(dir, "intents.jsonl");
  });

  it("rejects calls missing _meta.clippy.principal", async () => {
    const srv = makeServer();
    registerNotify(srv, { intentsPath });
    await expect(callTool(srv, "clippy.notify", { title: "hi" }, {}))
      .rejects.toMatchObject({ code: PRINCIPAL_ERROR_CODE });
  });

  it("appends a notify.toast intent on a valid call", async () => {
    const srv = makeServer();
    registerNotify(srv, { intentsPath });
    const meta = { clippy: { principal: "clippy", session: "sid-1" } };
    const res = await callTool(srv, "clippy.notify", { title: "hi" }, meta);
    expect(res.structuredContent.accepted).toBe(true);
    const line = readFileSync(intentsPath, "utf8").trim();
    expect(JSON.parse(line)).toMatchObject({ kind: "notify.toast", title: "hi" });
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns a typed error when no intents path is configured", async () => {
    const srv = makeServer();
    registerNotify(srv, { env: {} });
    const meta = { clippy: { principal: "clippy" } };
    await expect(callTool(srv, "clippy.notify", { title: "hi" }, meta))
      .rejects.toMatchObject({ code: "clippy.notify.intents.unavailable" });
  });
});
```

Run the suite:

```
npm run test:apps
```

Follow the pattern in `src/mcp-apps/__tests__/principal.test.mjs` or
`commander.test.mjs` if the helper shape drifts.

## Step 6: smoke test

Stdio smoke test (no widget):

```
node scripts/smoke-apps-server.mjs
```

You should see the server boot, respond to `initialize`, and list
`clippy.notify` under `tools/list`. The script exits non-zero on any
protocol failure.

Manual end-to-end test with the widget:

1. Build the widget: open `Windows-Clippy-MCP.sln` and build
   `WidgetHost` in Debug, or run your existing `npm run start:widget`.
2. Launch the widget. The bridge spawns `node src/mcp-apps/server.mjs`
   automatically.
3. From an external MCP Apps client (or a quick throwaway Node client),
   send:

   ```json
   {
     "method": "tools/call",
     "params": {
       "name": "clippy.notify",
       "arguments": { "title": "hello", "body": "from the cookbook" },
       "_meta": { "clippy": { "principal": "clippy" } }
     }
   }
   ```

4. Confirm the intent appears in
   `%LOCALAPPDATA%\WindowsClippy\commander-intents.jsonl` and that the
   widget raises your toast.
5. Inspect telemetry via the `clippy.telemetry` tool; the counters
   should include `clippy.notify.ok`.

## Checklist before opening a PR

- [ ] New file under `src/mcp-apps/tools/` with `registerXxx` export.
- [ ] Registration added to `createAppsServer` in `server.mjs`.
- [ ] Handler wrapped in `wrapToolWithPrincipal` and
      `wrapToolWithTelemetry`.
- [ ] Stable `ui://clippy/<name>.html` resource, CSP-strict.
- [ ] Vitest covering: principal reject, happy path, at least one
      typed error.
- [ ] Widget-side dispatch (if intent-driven) plumbed through
      `McpAppsBridge.DispatchIntentLine`; no alternate write paths.
- [ ] Smoke test via `scripts/smoke-apps-server.mjs` passes.
- [ ] Table of tools in [architecture.md](./architecture.md) updated.

That is the full loop. Subsequent releases will add a `clippy.terminal-tab`
tool and expand the View surfaces; the steps above apply unchanged.
