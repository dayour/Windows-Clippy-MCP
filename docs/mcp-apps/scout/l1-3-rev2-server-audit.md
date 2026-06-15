# Windows Clippy MCP – Server Audit Report
## L1-3-Rev2: Authoritative Tool Inventory from source (main.py)

**Report Date:** 2026-04-18 14:19:21**
**Authority:** main.py only (README.md explicitly ignored per revision)
**Audit Scope:** Complete grep and line-by-line mapping of all @mcp.tool() decorators

---

## 1. AUTHORITATIVE TOOL COUNT = 51

All decorators from main.py:

- Line 110: @mcp.tool(name='Launch-Tool', ...)
- Line 118: @mcp.tool(name='Powershell-Tool', ...)
- Line 123: @mcp.tool(name='State-Tool', ...)
- Line 156: @mcp.tool(name='Clipboard-Tool', ...)
- Line 170: @mcp.tool(name='Click-Tool', ...)
- Line 177: @mcp.tool(name='Type-Tool', ...)
- Line 187: @mcp.tool(name='Switch-Tool', ...)
- Line 195: @mcp.tool(name='Scroll-Tool', ...)
- Line 222: @mcp.tool(name='Drag-Tool', ...)
- Line 231: @mcp.tool(name='Move-Tool', ...)
- Line 236: @mcp.tool(name='Shortcut-Tool', ...)
- Line 241: @mcp.tool(name='Key-Tool', ...)
- Line 246: @mcp.tool(name='Wait-Tool', ...)
- Line 251: @mcp.tool(name='Scrape-Tool', ...)
- Line 258: @mcp.tool(name='Browser-Tool', ...)
- Line 291: @mcp.tool(name='PAC-CLI-Tool', ...)
- Line 310: @mcp.tool(name='Connect-MGGraph-Tool', ...)
- Line 338: @mcp.tool(name='Graph-API-Tool', ...)
- Line 373: @mcp.tool(name='Copilot-Studio-Tool', ...)
- Line 507: @mcp.tool(name='Agent-Studio-Tool', ...)
- Line 633: @mcp.tool(name='Power-Automate-Tool', ...)
- Line 669: @mcp.tool(name='M365-Copilot-Tool', ...)
- Line 702: @mcp.tool(name='Window-Tool', ...)
- Line 756: @mcp.tool(name='Screenshot-Tool', ...)
- Line 788: @mcp.tool(name='Volume-Tool', ...)
- Line 886: @mcp.tool(name='Notification-Tool', ...)
- Line 916: @mcp.tool(name='FileExplorer-Tool', ...)
- Line 933: @mcp.tool(name='Process-Tool', ...)
- Line 989: @mcp.tool(name='SystemInfo-Tool', ...)
- Line 1053: @mcp.tool(name='Search-Tool', ...)
- Line 1068: @mcp.tool(name='TaskView-Tool', ...)
- Line 1090: @mcp.tool(name='Settings-Tool', ...)
- Line 1137: @mcp.tool(name='Snip-Tool', ...)
- Line 1156: @mcp.tool(name='Registry-Tool', ...)
- Line 1226: @mcp.tool(name='Wifi-Tool', ...)
- Line 1253: @mcp.tool(name='Bluetooth-Tool', ...)
- Line 1274: @mcp.tool(name='ActionCenter-Tool', ...)
- Line 1287: @mcp.tool(name='Lock-Tool', ...)
- Line 1311: @mcp.tool(name='Taskbar-Tool', ...)
- Line 1336: @mcp.tool(name='Emoji-Tool', ...)
- Line 1344: @mcp.tool(name='Clipboard-History-Tool', ...)
- Line 1352: @mcp.tool(name='Run-Dialog-Tool', ...)
- Line 1368: @mcp.tool(name='File-Tool', ...)
- Line 1462: @mcp.tool(name='Cursor-Position-Tool', ...)
- Line 1470: @mcp.tool(name='Screen-Info-Tool', ...)
- Line 1493: @mcp.tool(name='Text-Select-Tool', ...)
- Line 1524: @mcp.tool(name='Find-Replace-Tool', ...)
- Line 1543: @mcp.tool(name='Undo-Redo-Tool', ...)
- Line 1556: @mcp.tool(name='Zoom-Tool', ...)
- Line 1591: @mcp.tool(name='Edge-Browser-Tool', ...)
- Line 1871: @mcp.tool(name='Copilot-CLI-Tool', ...)

---

## 2. PER-TOOL DETAILED TABLE

| Tool Name | Decorator Line | Function Line | Category | Classification | Rationale |
|-----------|----------------|---------------|----------|-----------------|-----------|
| Launch-Tool | 110 | 111 | desktop-automation | MCP-APP-CANDIDATE | Launches Windows apps via shell; production-ready. |
| Powershell-Tool | 118 | 119 | desktop-automation | MCP-APP-CANDIDATE | Execute PowerShell; core desktop control. |
| State-Tool | 123 | 124 | desktop-automation | MCP-APP-CANDIDATE | Desktop state capture via UI Automation; foundational. |
| Clipboard-Tool | 156 | 157 | desktop-automation | MCP-APP-CANDIDATE | Clipboard read/write via pyperclip. |
| Click-Tool | 170 | 171 | desktop-automation | MCP-APP-CANDIDATE | Mouse click automation; essential for UI control. |
| Type-Tool | 177 | 178 | desktop-automation | MCP-APP-CANDIDATE | Type text into active element. |
| Switch-Tool | 187 | 188 | desktop-automation | MCP-APP-CANDIDATE | Switch between application windows. |
| Scroll-Tool | 195 | 196 | desktop-automation | MCP-APP-CANDIDATE | Scroll content at coordinates. |
| Drag-Tool | 222 | 223 | desktop-automation | MCP-APP-CANDIDATE | Drag-and-drop operation. |
| Move-Tool | 231 | 232 | desktop-automation | MCP-APP-CANDIDATE | Move mouse without clicking. |
| Shortcut-Tool | 236 | 237 | desktop-automation | MCP-APP-CANDIDATE | Execute keyboard shortcuts. |
| Key-Tool | 241 | 242 | desktop-automation | MCP-APP-CANDIDATE | Press individual keys. |
| Wait-Tool | 246 | 247 | desktop-automation | MCP-APP-CANDIDATE | Pause execution. |
| Scrape-Tool | 251 | 252 | browser | MCP-APP-CANDIDATE | Fetch and convert web pages to markdown. |
| Browser-Tool | 258 | 259 | browser | MCP-APP-CANDIDATE | Launch Edge and navigate to URLs. |
| PAC-CLI-Tool | 291 | 292 | m365 | MCP-APP-CANDIDATE | Execute Power Platform CLI commands. |
| Connect-MGGraph-Tool | 310 | 311 | m365 | MCP-APP-CANDIDATE | Authenticate with Microsoft Graph. |
| Graph-API-Tool | 338 | 339 | m365 | MCP-APP-CANDIDATE | Execute Microsoft Graph API calls. |
| Copilot-Studio-Tool | 373 | 374 | m365 | MCP-APP-CANDIDATE | Manage Copilot Studio agents via Agent Studio. |
| Agent-Studio-Tool | 507 | 508 | m365 | PLAIN-TOOL | Query Agent Studio unified store; lightweight. |
| Power-Automate-Tool | 633 | 634 | m365 | STUB | Returns placeholder "Creating Power Automate flow..."; not implemented. |
| M365-Copilot-Tool | 669 | 670 | m365 | STUB | Returns "This requires {app} with Copilot enabled..."; placeholder. |
| Window-Tool | 702 | 703 | desktop-automation | MCP-APP-CANDIDATE | Minimize/maximize/resize windows. |
| Screenshot-Tool | 756 | 757 | desktop-automation | MCP-APP-CANDIDATE | Capture full/region/window screenshots. |
| Volume-Tool | 788 | 789 | utility | MCP-APP-CANDIDATE | Control system volume (mute, set level, etc.). |
| Notification-Tool | 886 | 887 | desktop-automation | MCP-APP-CANDIDATE | Display Windows toast notifications. |
| FileExplorer-Tool | 916 | 917 | desktop-automation | MCP-APP-CANDIDATE | Open File Explorer at specified path. |
| Process-Tool | 933 | 934 | utility | MCP-APP-CANDIDATE | List or terminate processes. |
| SystemInfo-Tool | 989 | 990 | utility | MCP-APP-CANDIDATE | Get CPU, memory, disk, network info. |
| Search-Tool | 1053 | 1054 | desktop-automation | MCP-APP-CANDIDATE | Open Windows Search with query. |
| TaskView-Tool | 1068 | 1069 | desktop-automation | MCP-APP-CANDIDATE | Manage virtual desktops. |
| Settings-Tool | 1090 | 1091 | desktop-automation | MCP-APP-CANDIDATE | Open Windows Settings pages. |
| Snip-Tool | 1137 | 1138 | desktop-automation | MCP-APP-CANDIDATE | Open Snipping Tool for screen capture. |
| Registry-Tool | 1156 | 1157 | utility | MCP-APP-CANDIDATE | Read Windows Registry (read-only). |
| Wifi-Tool | 1226 | 1227 | utility | MCP-APP-CANDIDATE | Manage WiFi connections. |
| Bluetooth-Tool | 1253 | 1254 | utility | MCP-APP-CANDIDATE | Toggle/manage Bluetooth. |
| ActionCenter-Tool | 1274 | 1275 | desktop-automation | MCP-APP-CANDIDATE | Open Action Center or Quick Settings. |
| Lock-Tool | 1287 | 1288 | desktop-automation | MCP-APP-CANDIDATE | Lock workstation, sleep, shutdown. |
| Taskbar-Tool | 1311 | 1312 | desktop-automation | MCP-APP-CANDIDATE | Interact with taskbar. |
| Emoji-Tool | 1336 | 1337 | desktop-automation | MCP-APP-CANDIDATE | Open Emoji picker. |
| Clipboard-History-Tool | 1344 | 1345 | desktop-automation | MCP-APP-CANDIDATE | Open Clipboard History. |
| Run-Dialog-Tool | 1352 | 1353 | desktop-automation | MCP-APP-CANDIDATE | Open Run dialog. |
| File-Tool | 1368 | 1369 | utility | MCP-APP-CANDIDATE | Create/delete/copy/move files. |
| Cursor-Position-Tool | 1462 | 1463 | desktop-automation | PLAIN-TOOL | Get mouse cursor position. |
| Screen-Info-Tool | 1470 | 1471 | utility | MCP-APP-CANDIDATE | Get display/monitor info. |
| Text-Select-Tool | 1493 | 1494 | desktop-automation | PLAIN-TOOL | Select text in active element. |
| Find-Replace-Tool | 1524 | 1525 | desktop-automation | PLAIN-TOOL | Open Find/Replace dialogs. |
| Undo-Redo-Tool | 1543 | 1544 | desktop-automation | PLAIN-TOOL | Perform undo/redo. |
| Zoom-Tool | 1556 | 1557 | desktop-automation | PLAIN-TOOL | Zoom in/out/reset. |
| Edge-Browser-Tool | 1591 | 1592 | browser | MCP-APP-CANDIDATE | Full Edge control via Chrome DevTools Protocol (CDP). |
| Copilot-CLI-Tool | 1871 | 1872 | utility | MCP-APP-CANDIDATE | Run GitHub Copilot CLI with full flag support. |

---

## 3. CATEGORY ROLL-UP TABLE

| Category | Tool Count | Percentage | Tools |
|----------|-----------|-----------|-------|
| desktop-automation | 32 | 62.7% | Launch-Tool, Powershell-Tool, State-Tool, Clipboard-Tool, Click-Tool, Type-Tool, Switch-Tool, Scroll-Tool, Drag-Tool, Move-Tool, Shortcut-Tool, Key-Tool, Wait-Tool, Window-Tool, Screenshot-Tool, Notification-Tool, FileExplorer-Tool, Search-Tool, TaskView-Tool, Settings-Tool, Snip-Tool, ActionCenter-Tool, Lock-Tool, Taskbar-Tool, Emoji-Tool, Clipboard-History-Tool, Run-Dialog-Tool, Cursor-Position-Tool, Text-Select-Tool, Find-Replace-Tool, Undo-Redo-Tool, Zoom-Tool |
| utility | 9 | 17.6% | Volume-Tool, Process-Tool, SystemInfo-Tool, Registry-Tool, Wifi-Tool, Bluetooth-Tool, File-Tool, Screen-Info-Tool, Copilot-CLI-Tool |
| m365 | 7 | 13.7% | PAC-CLI-Tool, Connect-MGGraph-Tool, Graph-API-Tool, Copilot-Studio-Tool, Agent-Studio-Tool, Power-Automate-Tool, M365-Copilot-Tool |
| browser | 3 | 5.9% | Scrape-Tool, Browser-Tool, Edge-Browser-Tool |

**Sum validation:** 32 + 9 + 7 + 3 = **51 ✓**

---

## 4. CROSS-CHECK AGAINST manifest.json

**manifest.json path:** E:\Windows-Clippy-MCP\manifest.json

**Current contents:**
- Name: "Windows Clippy MCP"
- Version: "0.1.76"
- No embedded tool list

**Finding:** manifest.json contains package metadata only; authoritative tool list exists only in main.py. ✓

---

## 5. STUB TOOLS (Not Implemented / Placeholder)

| Tool Name | Line | Behavior | Status |
|-----------|------|----------|--------|
| Power-Automate-Tool | 633 | Returns placeholder text "Creating Power Automate flow..." | Stub |
| M365-Copilot-Tool | 669 | Returns "This requires {app} with Copilot enabled..." | Stub |

**Total stubs: 2**

---

## 6. PROPOSED v0.2.0 COMMANDER TOOLS (Future)

Seven new tools proposed for evaluation (not designed):

1. **clippy.commander** – Unified command dispatcher for tool orchestration
2. **clippy.broadcast** – Broadcast state/events across connected agents
3. **clippy.link-group** – Link multiple tool instances into logical groups
4. **clippy.fleet-status** – Query status of agent fleet / connected clients
5. **clippy.agent-catalog** – Discover and catalog remote agent capabilities
6. **clippy.session-inspector** – Inspect MCP session metadata and auth context
7. **clippy.terminal-tab** – Tab-aware terminal multiplexer integration

---

## 7. README DRIFT ANALYSIS

### **README.md Line 24 Claim:**
> "It exposes **49 tools total: 42 Desktop Automation tools + 7 M365/Power Platform tools**"

### **Source Truth (main.py):**

| Category | Count |
|----------|-------|
| desktop-automation | 32 |
| utility | 9 |
| m365 | 7 |
| browser | 3 |
| **TOTAL** | **51** |

### **Drift Summary:**
- **README claim:** 49 tools (42 DA + 7 M365)
- **Actual count:** 51 tools (32 DA + 9 Utility + 7 M365 + 3 Browser)
- **Gap:** 2 tools (4% drift)
- **Root cause:** Utility and browser tools not tallied in README

### **Recommended Fix for README.md Line 24:**

**Replace:**
`
It exposes **49 tools total: 42 Desktop Automation tools + 7 M365/Power Platform tools**
`

**With:**
`
It exposes **51 tools total: 32 Desktop Automation + 9 Utility + 7 M365/Power Platform + 3 Browser Integration tools**
`

---

## AUDIT CHECKLIST

- [x] grep -n "^@mcp\.tool(" executed against main.py only
- [x] All 51 decorators traced to exact line number + function line
- [x] Per-tool classification assigned (MCP-APP-CANDIDATE / PLAIN-TOOL / STUB)
- [x] Category roll-up totals verified (sum = 51 ✓)
- [x] manifest.json cross-checked (no tool enumeration)
- [x] Stubs identified and documented (2 found)
- [x] README drift quantified and corrected
- [x] No reuse of rev1 numbers
- [x] All numbers sourced directly from main.py

---

## REVISION HISTORY

| Rev | Date | Status | Notes |
|-----|------|--------|-------|
| rev1 | — | ✗ Rejected | Arithmetic errors (49 vs 48 vs 51 mismatch) |
| rev2 | 2026-04-18 | ✓ Authoritative | Count = 51, all decorators verified line-by-line |

---

**Prepared by:** L1 Audit Agent  
**Authority:** main.py grep + manual verification  
**Status:** Ready for L1 Boss sign-off  
