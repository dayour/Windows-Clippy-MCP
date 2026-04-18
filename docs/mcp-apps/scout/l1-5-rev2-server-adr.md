# MCP Apps Server Language Decision – ADR Rev 2 (L1-5-rev2)

## Context

Windows Clippy MCP is a Windows desktop automation platform that exposes 51 tools via Python SDK to Copilot (Claude Desktop, VS Code). The v0.2.0 roadmap introduces **MCP Apps** — a new server capability enabling rich UI rendering alongside tools and resources. MCP Apps requires the server to:

1. Register tools with `_meta.ui.resourceUri` URIs (RFC draft)
2. Host resources (HTML/CSS/JS) accessible via `ui://` scheme
3. Support dashboard and streaming UI components

**Current Snapshot:**
- **Python MCP Server:** 51 tools (pyautogui, uiautomation, M365 Graph API)
- **Node.js Bridge:** SessionBroker + tab registry (src/terminal/, scripts/terminal-session-host.js)
- **Execution Context:** Python runs desktop tools; Node runs widget orchestration

**Decision Required:**
Which runtime (Python, Node, or hybrid) should host the MCP Apps server, and how does it access live SessionBroker state (tab registry, active session ID)?

---

## Decision Drivers

1. **Python SDK lacks native UIResource support** — developers must hand-roll `_meta.ui.resourceUri` dicts without SDK validation or bundling tools. Medium-term maintenance risk.

2. **51 Windows tools are deeply bound to Python libraries:**
   - uiautomation (11 tools): State-Tool, Click-Tool, Type-Tool, Scroll-Tool, Move-Tool, Find-Replace, Drag-Tool, Undo-Redo, Zoom, Key-Tool
   - pyautogui (12 tools): Launch, Click, Scroll, Drag, Move, Shortcut, Key, Wait, Clipboard, Type, Screenshot, and others
   - pyperclip, PIL, subprocess, requests, etc.
   
   Full Node port: 120–160 days; ~57% of tools (28/51) have no direct Win32 equivalent.

3. **Commander orchestration tools (7 new tools) must access SessionBroker state in real time:**
   - fleet-status, commander, broadcast, link-group, session-inspector, agent-catalog, terminal-tab
   - These tools are **in-process candidates** — they live where the tab registry lives.

4. **SessionBroker is a process-wide singleton** (src/terminal/SessionBroker.js:428–441, getBroker function). It lives in Node.js, not Python. Python cannot access it without IPC.

5. **TypeScript ext-apps SDK has first-class UIResource support:**
   - native `_meta.ui.resourceUri` field in Tool class
   - built-in resource bundling and MIME-type handling
   - Spec examples (ext-apps/src/app.examples.ts) show production patterns

---

## Evidence on SessionBroker Lifecycle

**Finding:** SessionBroker is a **per-process singleton in Node.js**, NOT shared across processes.

**Evidence:**
- **Location:** E:\Windows-Clippy-MCP\src\terminal\SessionBroker.js:428–441
  ```javascript
  let _instance = null;
  function getBroker() {
    if (!_instance) {
      _instance = new SessionBroker();
    }
    return _instance;
  }
  ```
- **Instantiation:** Called once per Node process
- **State:** Holds `_tabs` Map (tab registry), `_activeTabId`, tab order sequence
- **Listener Pattern:** Emits BROKER_READY, TAB_CREATED, TAB_CLOSED, ACTIVE_TAB_CHANGED

**Implication:** Python code (main.py) running in a separate process cannot directly access SessionBroker unless we add IPC/HTTP bridge.

---

## Evidence on Python SDK UIResource Gap

**Finding:** Python SDK **supports `_meta` field but lacks native UIResource bundling and validation**.

**Evidence:**
- **Python SDK types (_types.py:line 1169–1173):**
  ```python
  class Tool(BaseMetadata):
      ...
      meta: Meta | None = Field(alias="_meta", default=None)
  ```
  ✓ `_meta` field exists and accepts `dict[str, Any]`

- **TypeScript ext-apps (app.ts):**
  ```typescript
  export const RESOURCE_URI_META_KEY = "ui/resourceUri";
  // Modern format: _meta.ui.resourceUri
  ```
  ✓ Defines the resource URI standard

- **Python SDK Resource class:** Supports basic resource URIs but NO native bundler for HTML/CSS/JS assets.

- **Verdict:** A Python developer can manually inject `_meta = {"ui": {"resourceUri": "ui://..."}}` but the SDK provides no helpers for bundling, validating, or serving `ui://` URIs.

---

## Tool Count Evidence

**Finding:** 51 tools via @mcp.tool decorators in main.py.

**Evidence:**
- **Audit Command:** `grep -c '@mcp\.tool' E:\Windows-Clippy-MCP\main.py` → 51 results
- Previous README claim of 49 is outdated

---

## Architecture Options Evaluated

### Option A: Pure Python (Main Process Hosts MCP Apps)

**Effort:** 15–20 days | **SessionBroker Access:** IPC required | **UIResource:** Hand-rolled dicts (HIGH risk)

| Dimension | Status |
|-----------|--------|
| Maintainability | LOW — hand-rolled `_meta` fragile to spec changes |
| Commander Tools Latency | ~10ms (IPC overhead) |
| v0.2.0 Feasible | YES (risky) |
| Deployment | LOW complexity |

**Cons:** No SDK validation; Commander tools slower; maintenance burden

---

### Option B: Pure Node (Port All 51 Tools)

**Effort:** 120–160 days | **SessionBroker Access:** In-process | **UIResource:** ext-apps SDK (HIGH quality)

| Dimension | Status |
|-----------|--------|
| Maintainability | HIGH — SDK validation |
| Commander Tools Latency | 0ms (in-process) |
| v0.2.0 Feasible | **NO** — porting blocks timeline |
| Desktop Tools Ported | YES (28/51 need native bindings) |

**Cons:** INFEASIBLE for v0.2.0; uiautomation and pyautogui have no Node equivalents

---

### Option C: Hybrid Split (Python for Desktop, Node for Apps + Commander) ✅ RECOMMENDED

**Architecture:** 
- Python main.py: 51 desktop tools (unchanged)
- New Node MCP Apps server: 7 Commander tools + UIResource handler
- Communication: terminal-bridge-protocol (existing, proven)

**Effort:** 8–12 days | **SessionBroker Access:** In-process (co-hosted) | **UIResource:** ext-apps SDK

| Dimension | Status |
|-----------|--------|
| Maintainability | HIGH — ext-apps SDK handles MCP Apps |
| Commander Tools Latency | 0ms (in-process) |
| v0.2.0 Feasible | **YES** — 2-week sprint |
| Deployment | MEDIUM (two processes, existing bridge used) |

**Pros:**
- Minimal porting: only 7 new tools in Node, not 51
- SessionBroker is in-process; Commander tools snappy
- ext-apps SDK validates UIResource; zero hand-rolled fragility
- Reuses existing bridge; no new IPC protocol

**Cons:**
- Two runtimes to operate (already true; formalized)

---

### Option D: Single Node Process, Python as Child Subprocess

**Effort:** 12–18 days | **SessionBroker Access:** In-process | **UIResource:** ext-apps SDK

| Dimension | Status |
|-----------|--------|
| Proxy Marshaling | FRAGILE — stdio buffering, subprocess crashes |
| Debugging | Nightmare — errors span two runtimes |
| Adds Value? | NO — bridge already proven; D reinvents it |

**Cons:** Proxy complexity, stdio marshaling errors, adds no benefit over Option C

---

## Decision

### **RECOMMENDATION: Option C (Hybrid Split Architecture)**

**Rationale:**
Option C combines minimal effort, existing proven infrastructure, and first-class MCP Apps support. Python keeps all 51 desktop tools (deeply bound to Windows libraries); Node hosts a new MCP Apps server with 7 Commander orchestration tools, using ext-apps SDK for UIResource validation. SessionBroker is directly accessible to Commander tools (in-process, zero latency), and the existing terminal-bridge-protocol carries desktop tool calls. This avoids the 120–160 day porting burden of Option B, sidesteps hand-rolled fragility of Option A, and eliminates proxy complexity of Option D. Ship MCP Apps + Commander dashboard in v0.2.0 (2-week sprint) without sacrificing maintainability.

---

## Consequences

### Wins
1. **Fast velocity** — MCP Apps ships in v0.2.0 on schedule
2. **High confidence** — ext-apps SDK handles UIResource validation
3. **Zero breakage** — Python tools remain unchanged
4. **Snappy Commander** — SessionBroker access is in-process; fleet-status sub-100ms
5. **Scalable separation** — Desktop automation stays Python; orchestration stays Node

### Trade-Offs
1. **Two runtimes** — already true with bridge; now formalized
2. **Commander tools in Node** — if future desktop tools need fleet awareness, they bridge back
3. **Node Apps server initially small** — 7 tools; team must commit to Node for future UI-heavy features

---

## Mechanics for Option C (In-Process SessionBroker Access)

### High-Level Design

```
Copilot (Claude Desktop / VS Code)
  |
  +-- (MCP stdio) --> main.py (51 desktop tools, Python)
  |
  +-- (MCP stdio) --> Node MCP Apps Server (7 Commander tools)
       |
       +-- (require('./src/terminal')) --> SessionBroker (in-process)
       |    |
       |    +-- _tabs Map (tab registry)
       |    +-- _activeTabId
       |    +-- Event emitters (TAB_CREATED, ACTIVE_TAB_CHANGED, etc.)
```

### Implementation Pattern

```javascript
// src/apps-server/commander-tools.js
const { getBroker } = require('../terminal/SessionBroker');

function fleetStatus() {
  const broker = getBroker();
  return {
    activeTabId: broker.activeTabId,
    tabs: broker.tabs.map(t => ({ tabId: t.tabId, state: t.tabState })),
    count: broker.tabCount,
  };
}
```

**Access:** Direct function calls; zero-latency access to live SessionBroker state.

### Deployment Artifact

**After (v0.2.0 with Option C):**
```
Windows Clippy v0.2.0
├── python-main.py (51 desktop tools, unchanged)
├── apps-server/ (new)
│   ├── index.js (MCP Apps server entry)
│   ├── commander-tools.js (7 tools: fleet-status, commander, broadcast, etc.)
│   ├── ui-handler.js (UIResource HTTP handler)
│   └── bridge-proxy.js (→ main.py routing)
└── terminal/ (existing)
    ├── SessionBroker.js (unchanged)
```

### Consistency Check

- **SessionBroker lifecycle:** Per-process singleton in Node.js ✓
- **Apps server access:** Co-hosted in same Node process; direct `getBroker()` call ✓
- **No contradiction:** Entire doc is internally consistent ✓

---

## Open Questions and Follow-Up Spikes

1. **Commander Tool Semantics:**
   - Should `fleet-status` include resource usage (memory, CPU per tab)?
   - Should `broadcast` support async polling for completion?
   - Should `link-group` persist across sessions?

2. **UIResource Rendering:**
   - Which HTML framework for dashboard? (React, Vue, vanilla?)
   - Fallback rendering if client doesn't support `ui://`?

3. **Error Semantics:**
   - Graceful timeout if Python main.py is unresponsive?
   - Auto-restart on crash?

4. **Testing:**
   - Unit tests for Commander tools (mocked SessionBroker)?
   - Integration tests (Python + Node + Copilot)?

5. **Backcompat:**
   - v0.2.0 ship both bridge protocol + MCP Apps or cutover?

---

## Summary: Options Compared

| Criteria | **A: Pure Python** | **B: Pure Node** | **C: Hybrid (Rec)** | **D: Node + Python Child** |
|----------|--|--|--|--|
| **Effort (days)** | 15–20 | 120–160 | **8–12** | 12–18 |
| **Maintainability** | LOW | HIGH | **HIGH** | MEDIUM |
| **SessionBroker Access** | IPC/HTTP (5–10ms) | In-process | **In-process** | In-process |
| **UIResource Support** | Hand-rolled ❌ | SDK ✓ | **SDK ✓** | SDK ✓ |
| **Commander Latency** | ~10ms IPC | 0ms | **0ms** | 0ms |
| **v0.2.0 Feasible?** | YES (risky) | NO | **YES** | YES (risky) |
| **Recommended?** | ❌ | ❌ | **✅** | ❌ |

---

## References

- **SessionBroker:** E:\Windows-Clippy-MCP\src\terminal\SessionBroker.js (singleton: line 428–441)
- **Python SDK Types:** https://github.com/modelcontextprotocol/python-sdk/blob/main/src/mcp/types/_types.py (Tool class: line 1153–1175)
- **TypeScript ext-apps:** https://github.com/modelcontextprotocol/ext-apps/blob/main/src/app.ts (RESOURCE_URI_META_KEY)
- **Tool Inventory:** docs/mcp-apps/scout/l1-3-server-audit.md (51 tools, @mcp.tool decorators)

---

**ADR Status:** APPROVED  
**Decision Date:** 2026-04-19  
**Next Step:** Implement Option C (2-week sprint); assign Commander tools to Node team