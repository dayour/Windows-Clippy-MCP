# Clippy Fleet Status View (L2-3)

Single-file HTML bundle built with Vite + React 18. Produced by:

```
npm run build:views
```

Output lands at `dist/mcp-apps/views/fleet-status.html` and is served by
`src/mcp-apps/tools/fleet-status.mjs` via the `ui://clippy/fleet-status.html`
resource.

## Runtime requirements

The Apps server and any host that loads this View require Node >= 20 (the
`@modelcontextprotocol/ext-apps` package's engines field). The root
`package.json` still advertises `>=16.0.0` for the existing Python/widget
entry points; the MCP Apps surface is stricter. Do not attempt to run
`npm run build:views` or `npm run mcp-apps:server` on older Node.

## ext-apps/react surface actually used

Only `useApp` is used. Tool results stream in through `app.ontoolresult`
registered inside `onAppCreated`; the notification params are a standard MCP
`CallToolResult`, so `structuredContent` holds the fleet snapshot.

There is no `useCallTool` / `useResources` hook in ext-apps 1.6.0. Views
subscribe to host-pushed tool results, they do not call tools themselves.
