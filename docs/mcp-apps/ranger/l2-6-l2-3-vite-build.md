# L2-6 + L2-3: Vite build pipeline and Fleet Status React View

Status: PASS. Build green, smoke test green, bundle served from dist.

## Scope

- L2-6: Vite single-file build pipeline for MCP Apps Views.
- L2-3: First View (`clippy.fleet-status`) implemented as a React 18 app
  consuming the real `@modelcontextprotocol/ext-apps/react` surface.

## Files created

- `src/mcp-apps/views/fleet-status/fleet-status.html` - Vite HTML entry. Named
  `fleet-status.html` (not `index.html`) so the emitted artifact lands at
  `dist/mcp-apps/views/fleet-status.html` without any rename step.
- `src/mcp-apps/views/fleet-status/main.tsx` - React 18 `createRoot` bootstrap.
- `src/mcp-apps/views/fleet-status/App.tsx` - Single-component View. Uses
  `useApp` and registers `app.ontoolresult` + `app.onerror` inside
  `onAppCreated`. Renders Clippy Fleet Status header, connection pill, and a
  two-column counter grid (total tabs, idle/running/exited, groups, active
  group, agent catalog, capturedAt). Placeholder state when no structured
  content has arrived; warning row when `snapshot.error` is present. All
  styling via an inline `<style>` element (theme-aware via
  `prefers-color-scheme` and `--mcp-ui-color-*` CSS vars so it picks up the
  MCP Apps host theme when present).
- `src/mcp-apps/views/fleet-status/vite.config.ts` - Vite 5 config with
  `@vitejs/plugin-react` and `vite-plugin-singlefile`. Output pinned to
  `<repo>/dist/mcp-apps/views`, `emptyOutDir: false`, `assetsInlineLimit:
  100_000_000`, `cssCodeSplit: false`, `target: es2020`,
  `rollupOptions.output.inlineDynamicImports: true`. No sourcemaps emitted.
- `src/mcp-apps/views/tsconfig.json` - scoped tsconfig (jsx `react-jsx`,
  moduleResolution `bundler`, target `ES2020`, `strict: true`).
- `src/mcp-apps/views/fleet-status/README.md` - View-local notes (including
  the Node >= 20 requirement inherited from ext-apps).

## ext-apps/react hooks used

Only `useApp` from `@modelcontextprotocol/ext-apps/react`. That is the entire
React surface actually exposed by ext-apps 1.6.0:

- `useApp` (used here)
- `useAutoResize` (not needed - `useApp` enables `autoResize: true` by default)
- `useDocumentTheme`
- `useHostStyleVariables` / `useHostFonts`

There is no `useCallTool`, no `useResources`, no `useStructuredContent`.
Structured content reaches a View via a host-pushed notification
(`ui/notifications/tool-result`), which the `App` instance exposes as the
`ontoolresult` event. We register that handler inside the `onAppCreated`
callback exactly as documented in `useApp.d.ts`, and store the
`structuredContent` in React state.

## package.json changes

- Added scripts: `build:views`, `build` (aliases `build:views`),
  `mcp-apps:server`, `mcp-apps:smoke`.
- Added devDependencies: `vite@^5.4.10`, `@vitejs/plugin-react@^4.3.4`,
  `vite-plugin-singlefile@^2.0.3`, `react@^18.3.1`, `react-dom@^18.3.1`,
  `@types/react@^18.3.12`, `@types/react-dom@^18.3.1`, `typescript@^5.6.3`.
- `engines.node` intentionally NOT bumped (still `>=16.0.0` for the Python /
  widget entry points). The Node >= 20 requirement for anything touching
  ext-apps is documented in `src/mcp-apps/views/fleet-status/README.md`.
- No `"type": "module"` added at root. React view files are `.tsx`; Vite
  config is `.ts` (Vite handles ESM loading natively).

## Tool handler path sync

`src/mcp-apps/tools/fleet-status.mjs` already resolves `VIEW_BUNDLE_PATH` to
`<repo>/dist/mcp-apps/views/fleet-status.html`. The Vite config writes to
exactly that path. No change to `fleet-status.mjs` was required.

## Verification

- `npm install --ignore-scripts`: 61 packages added, clean.
- `npm run build:views`:
  ```
  vite v5.4.21 building for production...
  169 modules transformed.
  [plugin vite:singlefile] Inlining: fleet-status-*.js
  ../../../../dist/mcp-apps/views/fleet-status.html  269.82 kB
  built in 1.31s
  ```
- `dist/mcp-apps/views/fleet-status.html`: **269,829 bytes** (~263.5 KiB),
  fully inlined. Zero `<script src="http...">`, zero `<link href="http...">`,
  zero `sourceMappingURL` comments. Contains the `Clippy Fleet Status` header
  and the compiled `useApp` / `ontoolresult` wiring.
- `node scripts/smoke-apps-server.mjs`: ALL PASS. The tool handler's
  fallback chain now resolves the built artifact first (fallback.html is 666
  bytes; what the resource returned is 269KB HTML containing the bundle).

## ext-apps/react quirks found

1. `useApp` is the only React entry point. Apps pull input from the host,
   they do not push tool calls. The View subscribes to `ontoolresult` and
   reads `params.structuredContent`.
2. The handler must be registered inside `onAppCreated` (not in a
   `useEffect`) because `useApp` deliberately does not re-run on option
   changes. Late `addEventListener` calls are still supported on the
   returned `app` instance, but registering in `onAppCreated` guarantees we
   do not miss the first notification after the initialize handshake.
3. `vite-plugin-singlefile` v2 `inlinePattern` is `string[]` of glob
   patterns, not `RegExp[]`. A `RegExp` entry crashes picomatch with
   "Expected pattern to be a non-empty string". Default behavior already
   inlines all emitted chunks, so `inlinePattern` is omitted.
4. Vite warns "The CJS build of Vite's Node API is deprecated." Harmless
   for now - triggered because the root `package.json` has no `"type":
   "module"`. Switching to ESM globally would break the existing CJS
   widget/bin scripts, so we accept the warning.

## Bundle size budget

269,829 bytes. Budget was 500 KB. Headroom: ~240 KB. React 18 + JSX runtime
is the dominant cost (~140 KB minified, ~45 KB gzipped). If the View grows
significantly, switch to preact/compat via alias before bloating past the
budget.
