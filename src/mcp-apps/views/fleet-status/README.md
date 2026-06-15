# Clippy Fleet Status View (L2-3)

Single-file HTML bundle built with Vite 8 + React 19. Produced by:

```
npm run build:views
```

Output lands at `dist/mcp-apps/views/fleet-status.html` and is served by
`src/mcp-apps/tools/fleet-status.mjs` via the `ui://clippy/fleet-status.html`
resource.

## Runtime requirements

The Apps server and any host that loads this View targets Node 25.7.0 or
newer. Do not attempt to run `npm run build:views` or
`npm run mcp-apps:server` on older Node.

## ext-apps/react surface actually used

Only `useApp` is used. Tool results stream in through `app.ontoolresult`
registered inside `onAppCreated`; the notification params are a standard MCP
`CallToolResult`, so `structuredContent` holds the fleet snapshot.

There is no `useCallTool` / `useResources` hook in ext-apps 1.7.2. Views
subscribe to host-pushed tool results, they do not call tools themselves.
