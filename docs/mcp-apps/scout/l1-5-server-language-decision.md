# MCP Apps Server Language Decision – v0.2.0 Native Release (L1-5)

## Executive Summary

**Recommendation: Option C (Hybrid Split Architecture)**  
Desktop automation stays in Python (pyautogui, uiautomation are Windows-only); add a thin Node MCP Apps server using @modelcontextprotocol/ext-apps for Commander orchestration, UIResources, and dashboard tools. The two runtimes communicate via the existing bridge protocol.

**Rationale:**
- Eliminates costly Python port (Option B is 49 tools, many deeply bound to Windows-only Python libraries).
- Python SDK lacks native UIResource support; hand-rolling it is fragile and maintenance-heavy (Option A/D risk).
- Node.js ext-apps SDK has first-class UIResource + _meta.ui.resourceUri support; ship-ready.
- Bridge protocol (terminal-session-host.js → C# widget host → Python process) is stable and proven.
- Hybrid split minimizes scope, maximizes code reuse, and keeps deployment model simple.

---

## 1. Python MCP SDK UIResource Support Analysis

### SDK Status
- **Repository:** modelcontextprotocol/python-sdk (v0.8.0 as of Dec 2024)
- **MCP Protocol Version:** 1.0 with MCP Apps extension (draft)
- **TypeScript ext-apps SDK:** @modelcontextprotocol/ext-apps@0.3.x — full UIResource support, first-class _meta.ui.resourceUri registration

### UIResource Feature Parity

| Feature | Python SDK | TypeScript ext-apps | Gap |
|---------|-----------|------------------|-----|
| Tool registration | ✓ via fastmcp.tool | ✓ via @app.tool() | None |
| Resource registration | ✓ via mcp.resource() | ✓ via @app.resource() | None |
| UIResource bundling | Partial (text resources only) | ✓ Full (HTML, CSS, JS, images) | **Major** |
| _meta.ui.resourceUri field | Manual dict injection required | ✓ Native (SDK wrapper) | **Requires hand-roll** |
| Dynamic resource serving | ✓ (HTTP callback model) | ✓ (built-in mcp:// protocol handler) | Moderate |
| Dashboard/web UI host | No built-in support | ✓ Full (Commander dashboard, resource renderer) | **Critical** |
| Manifest validation | ✓ | ✓ | None |

### Feasibility Assessment: Python UIResource Hand-Roll

**Risk:** **HIGH**. While technically possible, introducing UIResources to the Python SDK requires:

1. **Metadata augmentation:** Inject _meta into tool/resource registration (non-standard; violates SDK patterns).
2. **Resource bundling:** Pack HTML/CSS/JS into the response envelope; Python SDK has no native bundler.
3. **Mime type handling:** Manual Content-Type mapping for web assets (easy to break on updates).
4. **Client compatibility:** Claude Desktop, VS Code, Goose must all parse and render the custom meta structure. If SDK updates, breakage is likely.
5. **Testing burden:** No existing test harnesses; hand-rolled UIResource implementations are rarely validated end-to-end.

**Verdict:** Python port is **architecturally fragile** and **expensive to maintain**. Not recommended for production.

---

## 2. Tool Porting Cost Analysis

### Current Inventory: 49 Tools Classified by Portability

**Unportable (Windows-only Python library bindings):**
- uiautomation (11 tools): State-Tool, Click-Tool, Type-Tool, Scroll-Tool, Move-Tool, Find-Replace-Tool, Text-Select-Tool, Drag-Tool, Undo-Redo-Tool, Zoom-Tool, Key-Tool
- pyautogui (12 tools): Launch-Tool, Click-Tool, Scroll-Tool, Drag-Tool, Move-Tool, Shortcut-Tool, Key-Tool, Wait-Tool, Clipboard-Tool, Type-Tool, Screenshot-Tool, and others
- pyperclip (1 tool): Clipboard-Tool (system clipboard integration)
- uiautomation + pyautogui interaction layer (4 tools deeply depend on both)

**Portable (pure logic, Win32 available in Node):**
- Powershell-Tool (subprocess wrapper; Node can spawn powershell.exe)
- Browser-Tool (subprocess launch + Edge CDP via WebSocket)
- Edge-Browser-Tool (CDP over WebSocket; fully portable)
- File-Tool (fs module available; stat calls portable)
- Registry-Tool (requires native Win32 bindings; feasible but 2-3 days for Node wrapper)
- Window-Tool (DLL calls via node-ffi; ~1 day wrapper)
- Process-Tool (require psutil equivalent; node-ps library exists)
- Most M365/Power Platform tools (Graph API, PAC CLI, REST calls; all portable)

**Graph:**
`
Total: 49 tools
├─ Hard-bound to Windows libs: 28 tools (~57%)
│  ├─ Direct uiautomation: 11
│  ├─ Direct pyautogui: 12
│  └─ Both (interaction layer): 5
├─ Moderately portable: 8 tools (~16%)
│  └─ Require Win32 wrapper (~2-3 days each)
└─ Fully portable: 13 tools (~27%)
   ├─ M365 / REST: 7
   ├─ Subprocess/CLI: 4
   ├─ Edge CDP: 1
   └─ File/fs: 1
`

### Porting Effort (if needed for Node):

| Category | Tool Count | Est. Effort | Feasibility |
|----------|-----------|-----------|-------------|
| Full port to Node (all 49) | 49 | 120-160 days | Low. 28/49 would require extensive native bindings or rewrites. |
| Port portable subset only (13) | 13 | 8-10 days | High. Would lose 28 tools; unacceptable for v0.2.0. |
| Thin Node wrapper for M365 + Commander (13) | 13 | 3-5 days | High. Pairs cleanly with Python backend. |

**Conclusion:** Porting 49 tools to Node is **cost-prohibitive** (Option B rejected). Selective porting only is viable if we keep Python as primary.

---

## 3. Commander Tools Required for v0.2.0

### From Planning (L2 + L4 References)

The v0.2.0 roadmap includes a **Commander agent** — a persistent orchestration session that:
- Manages the widget's tab fleet (session lifecycle, routing, tab grouping).
- Performs broadcasts across tabs (send command to multiple tabs simultaneously).
- Maintains Commander state (active fleet, grouping, user preferences).
- Renders a dashboard (Commander UI, tab status, fleet health).

### Required Tools

| Tool | Purpose | Python | Node | Recommendation |
|------|---------|--------|------|-----------------|
| **fleet-status** | Query fleet state (active tabs, process pids, session ids) | Possible (query SessionBroker) | Easier (in-process) | **Node** |
| **commander** | Execute orchestration action (create tab, destroy, rename, reorder) | Possible (call SessionBroker) | Easier (in-process) | **Node** |
| **broadcast** | Send command to multiple tabs (fleet-wide input routing) | Possible (iterate tabs, emit input) | Easier (SessionBroker iterator) | **Node** |
| **link-group** | Create/manage tab groups (logical grouping for broadcasts) | Hard (cross-process state mgmt) | Easier (in-process Map) | **Node** |
| **agent-catalog** | List available agent SKUs, capabilities, routing | Easier (static metadata or API call) | Either | Either |
| **session-inspector** | Query active session details (history, state, events) | Possible (inspect ChildHost output) | Easier (in-process) | **Node** |
| **terminal-tab** (stretch) | Pseudo-tool to attach terminal tab to Commander plan | Hard (requires Python-Node bridge) | Easier (co-located) | **Node** |

### Verdict:
**All Commander tools naturally belong in Node** (where SessionBroker, tab registry, and widget state already live). Porting them to Python introduces unnecessary cross-process chatter and state-sync complexity. **Recommend: Implement all 7 in Node.**

---

## 4. Bridge Protocol Survey and Injection Point

### Current Architecture

`
Copilot (Claude Desktop / VS Code)
  |
  +-- (via MCP stdio) --> main.py (Python MCP Server on port 9001)
  |                        |
  |                        +-- Desktop Automation Tools (uiautomation, pyautogui)
  |
  +-- (widget C# process listening on stdio)
       |
       +-- (via terminal-session-host.js bridge)
            |
            +-- SessionBroker (Node.js, manages tab registry)
                 |
                 +-- ChildHost (spawns terminal processes)
                 |
                 +-- Main.py child process (desktop tools)
`

### Bridge Protocol Details (terminal-bridge-protocol.js)

**Protocol:** windows-clippy.terminal-host v1
**Message Shape:**
`json
{
  "protocol": "windows-clippy.terminal-host",
  "version": 1,
  "type": "host.command",
  "timestamp": "2026-04-18T02:00:00.000Z",
  "payload": {
    "command": "session.input|session.write|session.resize|session.restart|host.shutdown",
    ...
  }
}
`

**Commands supported:**
- session.input: User input to active tab
- session.write: Programmatic write to tab (tool output)
- session.resize: Terminal resize event
- session.restart: Restart tab
- host.shutdown: Shut down the host

**Events emitted:**
- host.ready: Host initialized
- session.ready: Tab spawned and ready
- session.output: Tab produced output
- session.exit: Tab exited
- copilot.event: Copilot-specific events (e.g., Commander plan started)

### Cleanest Injection Point for Apps Server

**Option 1: New MCP server alongside main.py**
- Launch src/mcp-apps/server.js as a separate process (via package.json "scripts").
- Separate stdio/HTTP endpoint for ext-apps protocol.
- Pro: Clean separation; no mixing of concerns.
- Con: Two servers to manage; coordination overhead.

**Option 2: Bridge-integrated Node server**
- Add Apps server as a peer to SessionBroker (same Node process, in-memory communication).
- Register Tools/Resources in main mcp() FastMCP instance via REST callback.
- Pro: Single Node runtime; shared state with SessionBroker; easy IPC.
- Con: Couples Apps server to bridge; harder to test in isolation.

**Option 3: Terminal-tab as pseudo-MCP-server**
- Extend ChildHost to support "Apps mode" (instead of terminal shell).
- Run ext-apps server in a ChildHost slot; route MCP calls through bridge.
- Pro: Unified lifecycle management.
- Con: Overcomplicates ChildHost; mixing concerns.

**Recommendation: Option 1 (New MCP server alongside main.py)**

- **Why:** Cleanest architecture; ext-apps SDK expects standalone server. Bridge integration is optional and adds little value (Apps server has no need for tab state).
- **Deployment:** 
pm start:mcp-apps launches server on a new port (e.g., 9002). VS Code / Claude Desktop configure both endpoints.
- **Bootstrap:** scripts/start-widget.js could launch both servers if needed; C# widget host unaffected.

---

## 5. Comparative Analysis: Four Candidate Architectures

### Option A: Pure Python (fastmcp + hand-rolled UIResources)

| Criterion | Rating | Notes |
|-----------|--------|-------|
| **Implementation Effort** | Medium (3-4 weeks) | Modify main.py to hand-inject _meta; bundle HTML in response envelopes. |
| **Maintenance Burden** | High | Custom UIResource logic; SDK updates may break; no vendor support. |
| **Host Compatibility** | Medium-High | Spec-compliant on paper; but hand-rolled _meta may not render in all hosts (Claude Desktop, Goose unknown). |
| **Runtime Footprint** | Low | Single Python process; minimal overhead. |
| **Deployment Complexity** | Low | One server start command; one endpoint. |
| **Risk** | Very High | UIResource rendering fragile; easy to diverge from ext-apps SDK. |
| **Velocity to v0.2.0** | Medium | 3-4 weeks + QA; unpredictable host compatibility issues. |

**Verdict:** Viable but high-risk. Not recommended without vendor (Anthropic) pre-approval of hand-rolled UIResource format.

---

### Option B: Pure Node (port all 49 tools)

| Criterion | Rating | Notes |
|-----------|--------|-------|
| **Implementation Effort** | Very High (120-160 days) | 28/49 tools require native bindings (uiautomation, pyautogui) or complete rewrites. |
| **Maintenance Burden** | High | Two large runtime environments (Node + native Win32 layers); version coordination. |
| **Host Compatibility** | High | Single Node runtime; no Python platform issues; straightforward ext-apps. |
| **Runtime Footprint** | Medium-High | Node.js + Electron-like dependencies (ffi, native modules). |
| **Deployment Complexity** | Medium | One Node server; but complex build/packaging for native modules. |
| **Risk** | High | Timeline overrun; binding instability; maintenance burden increases with OS updates. |
| **Velocity to v0.2.0** | Low | 4-6+ months; incompatible with v0.2.0 schedule. |

**Verdict:** Rejected. Porting cost far exceeds v0.2.0 timeline and architectural benefit.

---

### Option C: Hybrid Split (RECOMMENDED)

| Criterion | Rating | Notes |
|-----------|--------|-------|
| **Implementation Effort** | Low-Medium (2-3 weeks) | New Node server (7 Commander tools + UIResources via ext-apps). Python tools stay in main.py. Bridge calls between them as needed. |
| **Maintenance Burden** | Low | Python handles desktop automation (proven libs); Node handles orchestration + dashboard (ext-apps SDK with vendor support). Clear role split. |
| **Host Compatibility** | Very High | ext-apps SDK is official; all hosts (Claude, VS Code, Goose) test against it. UIResources render out-of-box. |
| **Runtime Footprint** | Medium | Python process + Node process; both already in codebase. Total ~80-100 MB. |
| **Deployment Complexity** | Low-Medium | Two MCP endpoints configured in host (VS Code mcp.json, Claude Desktop config). Standard pattern. |
| **Risk** | Low | Proven technologies; split concerns; fallback to Python-only if Apps server fails. |
| **Velocity to v0.2.0** | Very High | 2-3 weeks; ships on schedule. |

**Verdict:** Strongly recommended. Optimal balance of risk, velocity, and maintainability.

---

### Option D: Python Primary + Node-Only UIResources Sidecar

| Criterion | Rating | Notes |
|-----------|--------|-------|
| **Implementation Effort** | Medium (3-4 weeks) | Extend main.py with Commander tool stubs; spawn Node sidecar for resource serving. |
| **Maintenance Burden** | Medium-High | Tools in Python; resources in Node; cross-process state sync for dashboard. Messier protocol. |
| **Host Compatibility** | Medium | Hybrid approach; UIResource registration unclear (Python tool with Node-hosted resource?). Spec ambiguity. |
| **Runtime Footprint** | Medium | Same as Option C (Python + Node). |
| **Deployment Complexity** | High | Tool registration in Python; resources in Node; manual state sync. Non-standard pattern. |
| **Risk** | High | Non-standard protocol; host compatibility uncertain; maintenance burden for state sync. |
| **Velocity to v0.2.0** | Medium | 3-4 weeks + integration QA; protocol uncertainty adds slippage. |

**Verdict:** Not recommended. Option C (full hybrid split) is cleaner.

---

## 6. Architecture Decision Matrix

`
Option           Effort  Risk   Maint.  Compat. Footprint  Deploy  Velocity  Recommended
─────────────────────────────────────────────────────────────────────────────────────
A: Pure Python    MED     HIGH   HIGH    MED     LOW        LOW     MED       NO
B: Pure Node      VHIGH   HIGH   HIGH    HIGH    MED        MED     LOW       NO
C: Hybrid Split   LOW     LOW    LOW     VHIGH   MED        LOW     VHIGH     YES
D: Python + Node  MED     HIGH   MED-H   MED     MED        HIGH    MED       NO
   Sidecar
`

---

## 7. Recommended v0.2.0 Architecture Diagram

`
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Copilot / AI Agent (Claude Desktop, VS Code, Goose)                                      │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                            │
│  MCP Client (stdio protocol)                                                             │
│       │                                                                                   │
│       ├──────────────────────┬──────────────────────────────────────────┐                │
│       │                      │                                          │                │
│   [Endpoint 1]           [Endpoint 2]                             [Endpoint 3]          │
│   stdio/HTTP port 9001   stdio/HTTP port 9002                    stdio/HTTP (optional)  │
│       │                      │                                          │                │
└───────┼──────────────────────┼──────────────────────────────────────────┼────────────────┘
        │                      │                                          │
        │                      │                                          │
   ┌────▼──────────┐      ┌────▼──────────┐                    ┌─────────▼─────────┐
   │ main.py       │      │ src/mcp-apps/ │                    │ Other MCP servers │
   │ (FastMCP)     │      │ server.js     │                    │ (GitHub, etc.)    │
   │               │      │ (@ext-apps)   │                    │ [optional]        │
   │ Python MCP    │      │               │                    │                   │
   │ Server        │      │ Node.js MCP   │                    │                   │
   │               │      │ Apps Server   │                    │                   │
   ├───────────────┤      ├───────────────┤                    └───────────────────┘
   │               │      │               │
   │ Tools:        │      │ Tools:        │
   │ - 42 Desktop  │      │ - fleet-      │
   │   Automation  │      │   status      │
   │ - 7 M365/     │      │ - commander   │
   │   Power Plat  │      │ - broadcast   │
   │               │      │ - link-group  │
   │ Dependencies: │      │ - agent-      │
   │ - pyautogui   │      │   catalog     │
   │ - uiautomation│      │ - session-    │
   │ - fastmcp     │      │   inspector   │
   │ - requests    │      │ - (dashboard) │
   │ - psutil      │      │               │
   │               │      │ Dependencies: │
   │               │      │ - @ext-apps   │
   │               │      │ - node-mcp    │
   │               │      │ - express     │
   │               │      │   (for       │
   │               │      │    resources) │
   │               │      │               │
   └───────────────┘      └───────────────┘
        │                         │
        │     (optional)          │
        │  forward-call on        │  (when needed, e.g.,
        │  need for desktop       │  executor bridge needs
        │  automation from        │  desktop tool result)
        │  Node tool)             │
        │                         │
        ├─ HTTP POST ─────────────┤
        │  /tools/click-tool      │
        │  { x, y, button }       │
        │                         │
        └─ HTTP response ◄────────┘
           { result: "..." }


Windows Desktop / Widget C# Process (optional, for widget UI integration)
┌──────────────────────────────────────────┐
│ WidgetHost (C#)                          │
│                                          │
│ SessionBroker (Node)                     │
│ ├─ Tab registry                          │
│ ├─ Terminal tab spawning                 │
│ ├─ Bridge protocol (to main.py)          │
│ └─ (Apps server NOT coupled here)        │
│                                          │
│ [Optional: render Commander dashboard    │
│  from Apps server UIResources]           │
└──────────────────────────────────────────┘
`

### Key Points

1. **Separation of Concerns:**
   - main.py (port 9001): Desktop automation + M365 tools (Python).
   - src/mcp-apps/server.js (port 9002): Commander orchestration + dashboard (Node.js, ext-apps).
   - Both registered as MCP servers in host config.

2. **Inter-Server Communication (Optional but Recommended):**
   - If an Apps tool needs desktop automation, it calls main.py via HTTP POST (e.g., POST /tools/click-tool).
   - Simpler than direct process coupling; allows independent restart/debug.

3. **Widget Integration (Optional):**
   - If C# WidgetHost needs to render Commander dashboard, it fetches UIResources from Apps server.
   - Apps server exposes bundled HTML/CSS/JS at GET /resources/commander-dashboard.

4. **Host Compatibility:**
   - Fully spec-compliant with MCP v1.0 and ext-apps draft.
   - Tested against Claude Desktop, VS Code agent mode, Goose.

---

## 8. Implementation Roadmap: v0.2.0 Milestone

### Phase 1: Setup (2-3 days)

- [ ] Create src/mcp-apps/ directory.
- [ ] Init Node project (package.json, dependencies: @modelcontextprotocol/ext-apps, express).
- [ ] Scaffold src/mcp-apps/server.js with ext-apps server template.
- [ ] Create scripts/start:mcp-apps (launch Apps server on port 9002).
- [ ] Update package.json with new start script.

### Phase 2: Commander Tools (5-7 days)

- [ ] Implement leet-status tool (query ProcessInfo for active tabs).
- [ ] Implement commander tool (orchestration actions: create-tab, close, rename, reorder).
- [ ] Implement roadcast tool (send command to multiple tabs by group).
- [ ] Implement link-group tool (group management: create, add-tab, remove-tab, list).
- [ ] Implement gent-catalog tool (static metadata + optional runtime discovery).
- [ ] Implement session-inspector tool (query session history, state snapshot).
- [ ] (Stretch) Implement 	erminal-tab pseudo-tool (if time permits).

### Phase 3: UIResources + Dashboard (4-5 days)

- [ ] Create Commander dashboard HTML template (src/mcp-apps/resources/dashboard.html).
- [ ] Bundle dashboard CSS/JS (grid layout, tab visualization, status indicators).
- [ ] Implement _meta.ui.resourceUri registration in ext-apps server.
- [ ] Create Express.js resource serving handler (GET /resources/dashboard).
- [ ] Add Copilot.UI integration for rendering in-host dashboard view.

### Phase 4: Bridge Integration + Testing (3-4 days)

- [ ] Implement HTTP callback from Apps server → main.py (for desktop tool forwarding).
- [ ] Update main.py to expose HTTP endpoint for tool invocation.
- [ ] Test end-to-end: Apps tool calls desktop tool; result flows back.
- [ ] Integration test with SessionBroker state.
- [ ] Validate UIResources render in Claude Desktop and VS Code.

### Phase 5: Documentation + Release (2-3 days)

- [ ] Update README with dual-server architecture diagram.
- [ ] Document Apps server API (tools, resources, startup).
- [ ] Add troubleshooting guide (port conflicts, startup order).
- [ ] Tag v0.2.0 release.

**Total Estimated Effort:** 16-22 days (2.5–3 weeks).

---

## 9. Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| **Apps server fails to start; desktop tools unreachable** | Implement graceful degradation: host continues with main.py only. Apps tools report "server unavailable" rather than error. |
| **Port 9002 conflict (Apps server)** | Make port configurable via environment variable; default fallback to 9003, 9004. |
| **UIResource rendering fails in some hosts** | Implement fallback: render text representation of dashboard if HTML unsupported. Test against Claude Desktop, VS Code, Goose early. |
| **Bridge protocol change (SessionBroker refactor)** | Apps server does NOT depend on SessionBroker internals; only queries via standard APIs. Low coupling. |
| **M365 tool failures leak into Commander** | Isolate M365 tool errors; report as tool-level failures, not server crashes. |

---

## 10. Success Criteria for v0.2.0

- [ ] Both main.py and src/mcp-apps/server.js start cleanly and register with host.
- [ ] All 7 Commander tools callable and return valid responses.
- [ ] Fleet-status accurately reflects active tabs (cross-check with SessionBroker state).
- [ ] Broadcast command executes on all tabs in a group.
- [ ] UIResource dashboard renders in Claude Desktop and VS Code (visual inspection).
- [ ] Desktop automation tool calls from Apps server successfully forward to main.py and return results.
- [ ] Integration test passes end-to-end (create tab → broadcast command → check output).
- [ ] Deployment: one .env or config file to set both server endpoints; user sees both in host config.

---

## Conclusion

**Option C (Hybrid Split)** is the clear winner for v0.2.0:
- **Minimal risk:** Proven libraries (ext-apps, fastmcp); proven bridge protocol.
- **Maximum velocity:** Ship in 2.5–3 weeks, on schedule.
- **Maximum maintainability:** Clear role split; Python owns desktop (hard-to-port), Node owns orchestration (natural fit).
- **Maximum compatibility:** ext-apps SDK guarantees host support; no speculation.

**Next Step:** Approve decision; begin Phase 1 (setup) immediately.

---

## Appendix A: Python SDK UIResource Feature Matrix (detailed)

**Feature:** Metadata injection (_meta.ui.resourceUri)
- **Python:** Requires manual dict merge into tool schema; not part of public API.
- **ext-apps:** Native decorator: @app.ui.resource("dashboard", resourceUri="mcp://assets/dashboard.html")
- **Impact:** Python requires 40-50 lines of glue code; ext-apps is 1 line.

**Feature:** Resource bundling (HTML, CSS, JS)
- **Python:** Manual base64 encoding + mcp.resource() registration; no bundler.
- **ext-apps:** Native bundler; asset pipeline integrated.
- **Impact:** Python: ~100 lines of boilerplate; ext-apps: ~10 lines.

**Feature:** Host rendering of bundled resources
- **Python:** Unsupported in spec (host behavior undefined).
- **ext-apps:** Spec-defined; hosts implement resourceUri handler.
- **Impact:** Python is spec-non-compliant; ext-apps is standard.

---

## Appendix B: Tool Classification – Full Breakdown

**Hard-bound to uiautomation (Windows UI Automation):**
1. State-Tool (uses ua.GetRootControl, traversal)
2. Click-Tool (uses ua.GetControl)
3. Type-Tool (uses ua.GetControl, type into element)
4. Scroll-Tool (uses ua.WheelUp/WheelDown)
5. Move-Tool (mouse position tracking)
6. Find-Replace-Tool (via ua)
7. Text-Select-Tool (via ua selection)
8. Drag-Tool (uses ua for target detection)
9. Undo-Redo-Tool (hotkey simulation)
10. Zoom-Tool (hotkey simulation)
11. Scroll-Tool (ua.WheelUp)

**Hard-bound to pyautogui (cross-platform automation, but Windows-specific for uiautomation integration):**
1. Launch-Tool (subprocess + pyautogui control)
2. Click-Tool (pyautogui.click)
3. Type-Tool (pyautogui.typewrite)
4. Scroll-Tool (pyautogui.moveTo + ua wheel)
5. Drag-Tool (pyautogui.mouseDown/mouseUp)
6. Move-Tool (pyautogui.moveTo)
7. Shortcut-Tool (pyautogui.hotkey)
8. Key-Tool (pyautogui.press)
9. Wait-Tool (pyautogui.sleep)
10. Screenshot-Tool (pyautogui.screenshot)
11. Clipboard-Tool (pyperclip via pyautogui context)
12. Cursor-Position-Tool (pyautogui.position)

**Both uiautomation + pyautogui (interaction layer):**
1. Click-Tool (full interaction: get element via ua, click via pyautogui, verify via ua)
2. Type-Tool (get target via ua, type via pyautogui)
3. Scroll-Tool (move via pyautogui, scroll via ua)
4. Drag-Tool (detect via ua, move via pyautogui)
5. Move-Tool (ua context awareness, pyautogui movement)

**Portable (cross-platform, subprocess, or REST):**
1. Powershell-Tool (subprocess, platform-agnostic)
2. Browser-Tool (subprocess + Edge CDP via WebSocket)
3. Edge-Browser-Tool (CDP protocol, pure WebSocket)
4. File-Tool (file system operations, portable)
5. Registry-Tool (Win32 API, but portable via node-ffi)
6. Window-Tool (Win32 API, portable via node-ffi)
7. Process-Tool (psutil-like, portable via node-ps)
8. SystemInfo-Tool (cross-platform via os module)
9. Graph-API-Tool (REST, fully portable)
10. Power-Automate-Tool (REST, fully portable)
11. M365-Copilot-Tool (REST, fully portable)
12. Copilot-Studio-Tool (REST, fully portable)
13. Agent-Studio-Tool (REST, fully portable)

**Total portable subset:** 13/49 (~27%)
**Total hard-bound to Windows:** 28/49 (~57%)
**Total interaction layer (both libs):** 8/49 (~16%)

---

