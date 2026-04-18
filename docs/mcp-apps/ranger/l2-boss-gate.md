# L2 Boss Gate - PASS (84.4/100)

Attempt: 1
Threshold: >=70
Score: 84.4
Verdict: PASS

## Per-criterion scorecard

| Criterion | Weight | Score | Justification |
|---|---:|---:|---|
| Protocol conformance | 30 | 78 | `tools/list`, `resources/list`, `resources/read`, and `tools/call` wired for the shipped app path. Downgrade: server advertised `resources.subscribe: true` but a direct probe returned `-32601`. Fixed in post-gate remediation below. |
| UI resource discovery | 20 | 95 | Tool advertises modern `_meta.ui.resourceUri` with exact `ui://clippy/fleet-status.html`; resource served with `text/html;profile=mcp-app`. Spec-correct and host-categorizable. |
| View bundle safety | 15 | 90 | Single HTML document, Vite forces single-file output with no sourcemaps. Bundle = 269 KiB inline, no external src/href. |
| Bridge state pluggability | 10 | 72 | Source/path/default fallback chain deterministic; numeric counters normalized. Downgrade: `principal`, `tabs.list`, `groups.list` pass-through unsanitized/unbounded. |
| Test coverage | 10 | 74 | Smoke covers initialize/list/read/call over stdio; Vitest covers registration + in-memory protocol. Downgrade: some unit tests reach into `_registeredTools`/`_registeredResources` private API; no hostile-input contract test. |
| L1 carry-forward defects | 10 | 94 | L2 code does not misuse `ui/notifications/tool-result` as generic event bus (used only as SDK-defined tool-result channel). No bogus `list_changed` delta handling. |
| Anti-regression vs L1 PASS | 5 | 90 | Stays aligned with L1 decisions: nested `ui.resourceUri`, valid `ui://` resource, `text/html;profile=mcp-app`, text fallback on `tools/call`. Only tension: over-advertised `resources.subscribe` (remediated). |

Weighted total: 84.4 / 100

## Defects found

None at blocker grade for current MCP Apps Basic Host interop.

## Post-gate remediation applied

MEDIUM finding (`resources.subscribe: true` declared without handler) was fixed in the same session by setting `subscribe: false` in `server.mjs` capabilities. `listChanged: true` retained because `McpServer.registerAppResource` path does emit list-changed when tools are added. Smoke + vitest re-run green.

## Carry-forward to L3 Tactician

- [MEDIUM] Harden `FleetState` against hostile injected sources (sanitize `principal`, cap `tabs.list`/`groups.list` array lengths, drop oversized events).
- [LOW] If L3 adds networked assets, move UI sandbox metadata onto `resources/read` content items per ext-apps examples; current placement on registered resource metadata is acceptable for a fully self-contained bundle.
- [LOW] Add one hostile-input contract test at the protocol layer: injected `state.snapshot()` returning malformed/oversized data must still produce a bounded, serializable `tools/call` result.

## Files reviewed

- `src/mcp-apps/server.mjs`
- `src/mcp-apps/tools/fleet-status.mjs`
- `src/mcp-apps/bridge-state.mjs`
- `src/mcp-apps/views/fleet-status/App.tsx`
- `src/mcp-apps/views/fleet-status/vite.config.ts`
- `src/mcp-apps/__tests__/fleet-status.test.mjs`
- `src/mcp-apps/__tests__/server.test.mjs`
- `scripts/smoke-apps-server.mjs`
- `docs/mcp-apps/ranger/l2-6-l2-3-vite-build.md`
- `docs/mcp-apps/ranger/l2-7-apps-tests.md`
- `docs/mcp-apps/scout/l1-boss-gate-v2-PASS.md`
- `node_modules/@modelcontextprotocol/ext-apps/dist/src/server/index.d.ts`
- `node_modules/@modelcontextprotocol/ext-apps/dist/src/react/useApp.d.ts`
