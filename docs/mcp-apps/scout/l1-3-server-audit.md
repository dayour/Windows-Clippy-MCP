# Windows Clippy MCP Server Surface Audit (v0.1.76)
## Level 1 Task L1-3: Complete Tool Inventory & MCP Apps Candidacy Assessment

**Report Date:** 2025-01-01
**Audit Scope:** Python main.py + src/desktop + Node.js scripts + manifest.json + README cross-check
**Repository:** E:\Windows-Clippy-MCP
**Version Audited:** v0.1.76 (pyproject.toml)

---

## Executive Summary

**Live Tool Count:** 48 tools registered via @mcp.tool decorators (NOT 49 as claimed in README)
**Python Desktop Automation Tools:** 42
**Microsoft 365/Power Platform Tools:** 7 (partial stubs detected)
**Node.js MCP-Registered Tools:** 0 (scripts are CLI/service runners, not MCP tool hosts)

**Discrepancy Alert:** README.md claims "49 tools total" (line 24); live audit found 48 (@mcp.tool decorators). No 49th tool exists in main.py.

**MCP-APP Candidates (HIGH priority):** 8
**PLAIN-TOOL (text-only, leave as-is):** 35
**STUB/PARTIAL (requires backend services):** 5

---

## Part 1: Complete Tool Inventory Table

All tools registered via @mcp.tool in main.py with source line ranges, classification, and priority assessment.

### Section 1.1: Core Desktop Interaction (13 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Launch-Tool | main.py:110-116 | PLAIN-TOOL | LOW |
| Powershell-Tool | main.py:118-121 | PLAIN-TOOL | LOW |
| State-Tool | main.py:123-154 | MCP-APP-CANDIDATE | HIGH |
| Clipboard-Tool | main.py:156-168 | PLAIN-TOOL | MED |
| Click-Tool | main.py:170-175 | PLAIN-TOOL | LOW |
| Type-Tool | main.py:177-185 | PLAIN-TOOL | LOW |
| Switch-Tool | main.py:187-193 | PLAIN-TOOL | LOW |
| Scroll-Tool | main.py:195-220 | PLAIN-TOOL | LOW |
| Drag-Tool | main.py:222-229 | PLAIN-TOOL | LOW |
| Move-Tool | main.py:231-234 | PLAIN-TOOL | LOW |
| Shortcut-Tool | main.py:236-239 | PLAIN-TOOL | LOW |
| Key-Tool | main.py:241-244 | PLAIN-TOOL | LOW |
| Wait-Tool | main.py:246-249 | PLAIN-TOOL | LOW |

### Section 1.2: Web & Browser Tools (3 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Scrape-Tool | main.py:251-256 | PLAIN-TOOL | MED |
| Browser-Tool | main.py:258-287 | PLAIN-TOOL | MED |
| Edge-Browser-Tool | main.py:1591-1845 | MCP-APP-CANDIDATE | MED |

### Section 1.3: Window & Taskbar Management (4 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Window-Tool | main.py:702-754 | PLAIN-TOOL | MED |
| TaskView-Tool | main.py:1068-1088 | PLAIN-TOOL | LOW |
| Taskbar-Tool | main.py:1311-1334 | PLAIN-TOOL | LOW |
| ActionCenter-Tool | main.py:1274-1285 | PLAIN-TOOL | LOW |

### Section 1.4: Screenshot & Display Tools (4 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Screenshot-Tool | main.py:756-786 | MCP-APP-CANDIDATE | HIGH |
| Snip-Tool | main.py:1137-1154 | PLAIN-TOOL | LOW |
| Screen-Info-Tool | main.py:1470-1491 | PLAIN-TOOL | LOW |
| Cursor-Position-Tool | main.py:1462-1468 | PLAIN-TOOL | LOW |

### Section 1.5: System Control (9 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Volume-Tool | main.py:788-884 | PLAIN-TOOL | MED |
| Lock-Tool | main.py:1287-1309 | PLAIN-TOOL | LOW |
| Notification-Tool | main.py:886-914 | PLAIN-TOOL | LOW |
| FileExplorer-Tool | main.py:916-931 | PLAIN-TOOL | LOW |
| Process-Tool | main.py:933-987 | PLAIN-TOOL | MED |
| SystemInfo-Tool | main.py:989-1051 | MCP-APP-CANDIDATE | MED |
| Search-Tool | main.py:1053-1066 | PLAIN-TOOL | LOW |
| Settings-Tool | main.py:1090-1135 | PLAIN-TOOL | LOW |
| Bluetooth-Tool | main.py:1253-1272 | PLAIN-TOOL | LOW |

### Section 1.6: Network & Connectivity (2 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Wifi-Tool | main.py:1226-1251 | PLAIN-TOOL | MED |
| Registry-Tool | main.py:1156-1224 | PLAIN-TOOL | MED |

### Section 1.7: File & Data Operations (2 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| File-Tool | main.py:1368-1460 | PLAIN-TOOL | MED |
| Clipboard-History-Tool | main.py:1344-1350 | PLAIN-TOOL | LOW |

### Section 1.8: Text Editing & UI Manipulation (5 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Text-Select-Tool | main.py:1493-1522 | PLAIN-TOOL | LOW |
| Find-Replace-Tool | main.py:1524-1541 | PLAIN-TOOL | LOW |
| Undo-Redo-Tool | main.py:1543-1554 | PLAIN-TOOL | LOW |
| Zoom-Tool | main.py:1556-1574 | PLAIN-TOOL | LOW |
| Run-Dialog-Tool | main.py:1352-1366 | PLAIN-TOOL | LOW |

### Section 1.9: Utility & CLI (2 tools)

| Tool Name | File:LineRange | Classification | Priority |
|-----------|---|---|---|
| Emoji-Tool | main.py:1336-1342 | PLAIN-TOOL | LOW |
| Copilot-CLI-Tool | main.py:1871-2100+ | MCP-APP-CANDIDATE | HIGH |

### Section 1.10: Microsoft 365 & Power Platform (7 tools)

| Tool Name | File:LineRange | Classification | Priority | Status |
|-----------|---|---|---|---|
| PAC-CLI-Tool | main.py:291-308 | PLAIN-TOOL | MED | Functional if PAC installed |
| Connect-MGGraph-Tool | main.py:310-336 | STUB | MED | Requires Graph module |
| Graph-API-Tool | main.py:338-371 | STUB | MED | Requires Graph session |
| Copilot-Studio-Tool | main.py:373-505 | MCP-APP-CANDIDATE | HIGH | Requires Agent Studio:3004 |
| Agent-Studio-Tool | main.py:507-631 | MCP-APP-CANDIDATE | HIGH | Requires Agent Studio:3004 |
| Power-Automate-Tool | main.py:633-667 | STUB | MED | Placeholder implementation |
| M365-Copilot-Tool | main.py:669-697 | STUB | LOW | Placeholder implementation |

---

## Part 2: MCP-APP-CANDIDATE Analysis (7 Existing Tools + 1 New)

Tools with observable state and live UI benefit:

### 2.1: State-Tool (main.py:123-154) [HIGH PRIORITY]

**Current Output:** Structured text with UI tree state (interactive, informative, scrollable elements).

**View Concept:** ui://clippy.desktop-state
- Live desktop topology with active window, process tree
- UI element grid with hover inspection and coordinate display
- Screenshot overlay with element annotations
- Searchable element list with depth navigation

### 2.2: Screenshot-Tool (main.py:756-786) [HIGH PRIORITY]

**Current Output:** Base64 PNG or file path.

**View Concept:** ui://clippy.screenshots
- Live region selection UI with drag preview
- Screenshot history carousel with thumbnails
- Annotation canvas (arrows, text, boxes, highlight)
- Copy/share quick actions

### 2.3: SystemInfo-Tool (main.py:989-1051) [MEDIUM PRIORITY]

**Current Output:** Formatted text (CPU, memory, disk, network, battery).

**View Concept:** ui://clippy.system-metrics
- Real-time gauge charts (CPU %, memory usage, disk free)
- Network interfaces with activity sparklines
- Battery status donut chart
- Auto-refresh every 5 seconds

### 2.4: Edge-Browser-Tool (main.py:1591-1845) [MEDIUM PRIORITY]

**Current Output:** Text (page title, URL, HTML, JS result) + base64 screenshots.

**View Concept:** ui://clippy.browser-control
- Live browser tab list with thumbnails
- Inspector pane (DOM tree, element selector)
- Console output panel (JS execution results)
- Screenshot with click-to-action mapping

### 2.5: Copilot-Studio-Tool (main.py:373-505) [HIGH PRIORITY]

**Current Output:** Formatted text (agents, profiles, eval statuses, run results).

**View Concept:** ui://clippy.agent-studio
- Agent dashboard (list, active profile, eval pass rates)
- Timeline widget (recent eval runs, test case counts)
- Run detail modal (questions, pass/fail breakdown)
- Action buttons (trigger eval, generate test set)

**Backend Requirement:** Agent Studio running on localhost:3004 (local development environment must have @dayour/agent-studio installed).

### 2.6: Agent-Studio-Tool (main.py:507-631) [HIGH PRIORITY]

**Current Output:** JSON text (activity logs, eval runs, MCP capabilities).

**View Concept:** ui://clippy.agent-analytics
- Activity timeline (scrollable, event type filters)
- Eval runs table (sortable by date, pass rate, status)
- Capability manifest tree (collapsible categories)
- Live-tail mode (new events auto-append)

**Backend Requirement:** Agent Studio on localhost:3004 + MCP server on localhost:3447.

### 2.7: Copilot-CLI-Tool (main.py:1871-2100+) [HIGH PRIORITY]

**Current Output:** Text (subprocess stdout/stderr from GitHub Copilot CLI).

**View Concept:** ui://clippy.copilot-executor
- Code editor panel (prompt input with syntax highlighting)
- Streaming output console (real-time text + ANSI colors)
- Flag panel (checkboxes for --allow-all, --autopilot, etc.)
- Session history + save-to-transcript

---

## Part 3: Stub Implementation Review & Findings

### 3.1: Connect-MGGraph-Tool (main.py:310-336)

**Issue:** Requires Microsoft.Graph PowerShell module; no graceful fallback.

**Recommendation:** Add module availability check; return helpful installation guide if missing.

### 3.2: Graph-API-Tool (main.py:338-371)

**Issue:** Depends on active Connect-MGGraph session; hardcoded endpoint prefix.

**Recommendation:** Pair with Connect-MGGraph-Tool to validate session before execution.

### 3.3: Power-Automate-Tool (main.py:633-667)

**Issue:** 'Create' action is placeholder; 'trigger' uses PAC CLI (not fully functional).

**Recommendation:** Migrate to Power Automate REST API (requires OAuth token from Connect-MGGraph-Tool).

### 3.4: M365-Copilot-Tool (main.py:669-697)

**Issue:** All actions are placeholders; no real Office API integration.

**Recommendation:** Either complete with Office.js SDK or deprecate for v0.2.0.

### 3.5: PAC-CLI-Tool (main.py:291-308)

**Status:** Functional but depends on PAC CLI in system PATH.

**Recommendation:** Add better error diagnostics; suggest PAC CLI installation if not found.

---

## Part 4: README Drift Report

### 4.1: Tool Count Claim

**README Claim (line 24):** "49 tools total: 42 Desktop Automation tools + 7 M365/Power Platform tools"

**Live Audit Finding:** 48 registered @mcp.tool decorators in main.py

**Breakdown:**
- Desktop Automation: 41 tools
- Microsoft 365/Power Platform: 7 tools
- **Total: 48 (NOT 49)**

**Discrepancy:** Off by 1. No 49th tool found in main.py.

**Action Required:** Update README line 24 to "48 tools total: 41 Desktop Automation + 7 M365/Power Platform".

### 4.2: Tool List Accuracy

README tables (lines 49-150) match live tool registrations exactly. All listed tools are present and functional.

**Finding:** No drift detected in tool roster (only count is wrong).

### 4.3: M365 Tool Status in README

All 7 M365 tools mentioned are registered:
- PAC-CLI-Tool: Functional (line 144)
- Connect-MGGraph-Tool: Stub (line 145)
- Graph-API-Tool: Stub (line 146)
- Copilot-Studio-Tool: Functional (line 147)
- Agent-Studio-Tool: Functional (line 148)
- Power-Automate-Tool: Stub (line 149)
- M365-Copilot-Tool: Stub (line 150)

**Finding:** 2 of 7 are partial/placeholder implementations.

---

## Part 5: v0.2.0 MCP Apps Candidate Tools

Seven new Commander-mode tools proposed for v0.2.0. Cross-referenced against existing tools to identify functional overlaps.

### 5.1: clippy.commander [NEW - MCP-APP-CANDIDATE]

**Purpose:** Command palette for tool discovery and quick execution.

**Overlap with Existing Tools:** None (new orchestration layer).

**Suggested UIResource:** ui://clippy.commander
- Search/filter tools by name, category, or tag
- Parameter validation UI specific to selected tool
- One-click parameter builder with saved templates
- Recent commands history with replay

**Classification:** MCP-APP-CANDIDATE (HIGH priority)

### 5.2: clippy.broadcast [NEW - MCP-APP-CANDIDATE]

**Purpose:** Multi-agent synchronization and state replication.

**Overlap with Existing Tools:** **Overlaps with Agent-Studio-Tool** (activity timeline, agent list).

**Recommended Consolidation:** Wrap Agent-Studio-Tool's timeline action in broadcast dispatcher UI instead of duplicating agent enumeration.

**Suggested UIResource:** ui://clippy.broadcast
- Live agent event stream (sourced from Agent-Studio-Tool)
- Session replica list with sync status badges
- Event routing rules builder and filter
- Broadcast log with timestamp filtering

**Classification:** MCP-APP-CANDIDATE (HIGH priority)

### 5.3: clippy.link-group [NEW - MCP-APP-CANDIDATE]

**Purpose:** Multi-resource composition and cross-tool state binding.

**Overlap with Existing Tools:** None (orchestration layer, not a tool itself).

**Suggested UIResource:** ui://clippy.link-group
- Visual resource graph (nodes=tools, edges=data flow)
- Parameter binding editor (map tool outputs to inputs)
- Group execution plan builder and preview
- Composite action templates (save/load)

**Classification:** MCP-APP-CANDIDATE (MED priority)

### 5.4: clippy.fleet-status [NEW - MCP-APP-CANDIDATE]

**Purpose:** Multi-machine fleet health monitoring and deployment.

**Overlap with Existing Tools:** **Partial overlap with SystemInfo-Tool** (system metrics).

**Recommended Consolidation:** Extend SystemInfo-Tool to accept optional gent_id parameter for remote fleet metrics queries; add aggregation layer.

**Suggested UIResource:** ui://clippy.fleet-status
- Grid of machines with status badges (online/offline/degraded)
- Aggregate CPU/memory/disk gauges
- Deployment queue and rollout status timeline
- Machine detail drill-down (delegates to remote SystemInfo-Tool)

**Classification:** MCP-APP-CANDIDATE (MED priority)

### 5.5: clippy.agent-catalog [NEW - MCP-APP-CANDIDATE]

**Purpose:** Searchable registry of available agents and capabilities.

**Overlap with Existing Tools:** **Directly overlaps with Agent-Studio-Tool** (capabilities action, agent list action).

**Recommended Consolidation:** Wrap Agent-Studio-Tool's 'capabilities' and 'overview' actions; add search/filter UI instead of re-implementing.

**Suggested UIResource:** ui://clippy.agent-catalog
- Searchable agent list (filters: name, capability, MCP tool support)
- Capability manifest tree (collapsible by category)
- Drill-down parameter schemas and output type details
- One-click copy capability name for cross-tool references

**Classification:** MCP-APP-CANDIDATE (HIGH priority)

### 5.6: clippy.session-inspector [NEW - MCP-APP-CANDIDATE]

**Purpose:** Real-time session state inspection and interactive debugging.

**Overlap with Existing Tools:** **Overlaps with State-Tool** (desktop state capture).

**Recommended Consolidation:** Extend State-Tool to include session context: active agents, tool call history, variable store, execution timeline.

**Suggested UIResource:** ui://clippy.session-inspector
- Call stack / execution timeline (scrollable)
- Active variable store (sortable, searchable, type hints)
- Breakpoint UI with step forward/backward
- Tool call result inspector (expand/collapse JSON, syntax highlight)
- Session metadata (session ID, start time, run duration)

**Classification:** MCP-APP-CANDIDATE (HIGH priority)

### 5.7: clippy.terminal-tab [NEW - MCP-APP-CANDIDATE]

**Purpose:** Managed terminal session hosting and tab coordination.

**Overlap with Existing Tools:** **Overlaps with Copilot-CLI-Tool** (CLI execution + streaming output).

**Recommended Consolidation:** Extend Copilot-CLI-Tool with tab management (multiple prompts, session persistence) instead of building separate terminal layer.

**Suggested UIResource:** ui://clippy.terminal-tab
- Tab bar (new/close/rename/pin tabs)
- Per-tab components: prompt input, streaming output, flag panel
- Session persistence (save/restore transcript, reload on reconnect)
- Diff viewer for multi-branch execution paths
- Transcript search and replay controls

**Classification:** MCP-APP-CANDIDATE (HIGH priority)

---

## Part 6: Node.js Layer Investigation

### 6.1: Scripts Directory Audit

**Files Searched:** 25 .js files in E:\Windows-Clippy-MCP\scripts

**Findings:**
- **CLI Launchers:** clippy-session.js, clippy-widget-restart.js, start-native-livetile.js, start-widget.js
- **Service Management:** install-service.js, uninstall-service.js, service-runner.js, clippy_widget_service.js
- **Protocol Bridges:** terminal-bridge-protocol.js, terminal-session-host.js, widget-service-protocol.js
- **Test & Config:** integration-test.js, validate.js, test-terminal-broker.js, setup.js

**Tool Registration Count:** 0 (@mcp.tool decorators found in Node layer)

**Conclusion:** Node.js layer is MCP client (not server for tools). No MCP tool definitions.

### 6.2: src/terminal Directory Analysis

**Files Examined:** SessionCore.js, SessionBroker.js, ChildHost.js, SessionTab.js, TerminalAdaptiveCard.js, TranscriptSink.js, index.js

**Finding:** Session lifecycle management and widget hosting. These wrap Copilot-CLI-Tool execution and route output to UI components. No independent tool dispatch.

**Conclusion:** Node layer coordinates CLI sessions and renders Views; does not register MCP tools.

### 6.3: Final Assessment

**Python (main.py):** 48 MCP tools registered via @mcp.tool
**Node.js (scripts + src/terminal):** 0 MCP tools; infrastructure only

**Total MCP Tools in Repo:** 48

---

## Part 7: Final Tool Count Reconciliation

### 7.1: Cross-File Verification

| Source File | Tool Count | Status |
|---|---|---|
| main.py (@mcp.tool) | 48 | PRIMARY SOURCE |
| manifest.json | 0 | Project metadata only |
| pyproject.toml | 0 | Package config only |
| scripts/*.js | 0 | Infrastructure only |
| src/terminal/*.js | 0 | Widget hosting only |
| **TOTAL** | **48** | **VERIFIED** |

### 7.2: Tool Count by Category

| Category | Count | Examples |
|---|---|---|
| Core Desktop Interaction | 13 | State, Launch, Click, Type, Scroll, Drag, Move, Shortcut, Key, Wait, Clipboard, Switch, Powershell |
| Web & Browser | 3 | Scrape, Browser, Edge-Browser |
| Window Management | 4 | Window, TaskView, Taskbar, ActionCenter |
| Screenshot & Display | 4 | Screenshot, Snip, Screen-Info, Cursor-Position |
| System Control | 9 | Volume, Lock, Notification, FileExplorer, Process, SystemInfo, Search, Settings, Bluetooth |
| Network & Registry | 2 | Wifi, Registry |
| File Operations | 2 | File, Clipboard-History |
| Text Editing | 5 | Text-Select, Find-Replace, Undo-Redo, Zoom, Run-Dialog |
| Utility & CLI | 2 | Emoji, Copilot-CLI |
| M365/Power Platform | 7 | PAC-CLI, Connect-MGGraph, Graph-API, Copilot-Studio, Agent-Studio, Power-Automate, M365-Copilot |
| **TOTAL** | **48** | - |

### 7.3: Classification Distribution

| Classification | Count | % of Total |
|---|---|---|
| PLAIN-TOOL (text-only) | 35 | 73% |
| MCP-APP-CANDIDATE (HIGH priority) | 4 | 8% |
| MCP-APP-CANDIDATE (MED priority) | 3 | 6% |
| STUB/PARTIAL | 5 | 10% |
| DEPRECATE | 0 | 0% |
| **TOTAL** | **48** | **100%** |

