# Windows Clippy MCP Widget Surface Inventory - REVISION 2

## L1-1 Scout Report: WidgetHost User-Facing Surfaces

**Report Generated:** 2025-04-18 14:45 UTC (REVISED)  
**Scope:** Complete audit of WidgetHost (C#/WPF/XAML) + BrowserHost + LiveTileHost user-facing component surfaces  
**Revision Note:** Rev1 contained arithmetic drift in host breakdown. Rev2 corrects discrepancy from claimed "16" breakdown to authoritative table-based recount.

**Classification Standard:**
- **COULD-BE-VIEW:** Suitable for WebView2 + React iframe re-implementation
- **MUST-STAY-NATIVE:** Requires WPF/native capabilities (window chrome, topmost, PTY hosting, global hotkeys)
- **OBSOLETE:** Dead code, stale surfaces, or superseded

---

## CORRECTED Executive Summary

The Windows Clippy widget consists of **THREE** primary application hosts with **16 distinct user-facing surfaces**:

1. **WidgetHost**: Main bench UI + Commander session management (**14 surfaces**, not 11)
2. **BrowserHost**: WebView2-based content host (**1 surface**)  
3. **LiveTileHost**: Tile/card display host (**1 surface**)

**Classification Tally (Corrected):**
- COULD-BE-VIEW: 11 surfaces (68.75%) — *was 10*
- MUST-STAY-NATIVE: 5 surfaces (31.25%) — *was 6*
- OBSOLETE: 0 surfaces (0%)

**Arithmetic Correction:** 
- Rev1 claimed WidgetHost = 11 surfaces, but Master Inventory Table documents 14.
- Rev2 authoritative count: 14 + 1 + 1 = **16 total** ✓
- Roll-up by classification: 11 COULD-BE-VIEW + 5 MUST-STAY-NATIVE = 16 ✓

**Migration Potential:** 68.75% of UI surfaces could transition to WebView2-hosted React with proper IPC/MCP Events layer.

---

## Master Surface Inventory Table (AUTHORITATIVE)

| # | Surface Name | Host | Type | Classification | XAML/Code Citation |
|---|---|---|---|---|---|
| 1 | LauncherWindow (floating tile) | WidgetHost | Window | MUST-STAY-NATIVE | LauncherWindow.xaml:1-16, CS:1-497 |
| 2 | MainWindow (bench chrome) | WidgetHost | Window | MUST-STAY-NATIVE | MainWindow.xaml:1-18, CS:1-1300+ |
| 3 | Tabs (multi-session) | WidgetHost | TabControl | COULD-BE-VIEW | MainWindow.xaml:487-495, 375-433, CS:1020-1102 |
| 4 | InputBox (prompt entry) | WidgetHost | TextBox | COULD-BE-VIEW | MainWindow.xaml:601-620, CS:487-510, 844-885 |
| 5 | SendBtn (dispatch button) | WidgetHost | Button | COULD-BE-VIEW | MainWindow.xaml:676-696, CS:515-535 |
| 6 | Toolbar (agent/model/mode selectors) | WidgetHost | ComboBox/ToggleButton | COULD-BE-VIEW | MainWindow.xaml:516-568, CS:550-650 |
| 7 | SessionMeta (status line) | WidgetHost | TextBlock | COULD-BE-VIEW | MainWindow.xaml:572-577, CS:1160-1175 |
| 8 | AttachmentMeta (detail line) | WidgetHost | TextBlock | COULD-BE-VIEW | MainWindow.xaml:578-583, CS:1176-1185 |
| 9 | SlashPopup (autocomplete) | WidgetHost | Popup/ListBox | COULD-BE-VIEW | MainWindow.xaml:622-675, CS:536-600 |
| 10 | TerminalTabSession (PTY host) | WidgetHost | TerminalControl | MUST-STAY-NATIVE | TerminalTabSession.cs:1-200+, MainWindow.xaml.cs:1020-1028 |
| 11 | CommanderSession (dispatcher logic) | WidgetHost | Service | MUST-STAY-NATIVE | CommanderSession.cs:27-200+ |
| 12 | ToolsMenu (checkboxes) | WidgetHost | ContextMenu | COULD-BE-VIEW | MainWindow.xaml.cs:1270-1277, 1290-1310 |
| 13 | ExtensionsMenu (checkboxes) | WidgetHost | ContextMenu | COULD-BE-VIEW | MainWindow.xaml.cs:1280-1288 |
| 14 | TabSwitcher (dropdown) | WidgetHost | ContextMenu | COULD-BE-VIEW | MainWindow.xaml.cs:1039-1102 |
| 15 | BrowserHost (WebView2 window) | BrowserHost | Window | MUST-STAY-NATIVE | BrowserHost/MainWindow.xaml:1-31 |
| 16 | LiveTileHost (display window) | LiveTileHost | Window | COULD-BE-VIEW | LiveTileHost/MainWindow.xaml:1-328 |

**Summary by Host:**

| Host | Total | COULD-BE-VIEW | MUST-STAY-NATIVE | % Migratable |
|---|---|---|---|---|
| WidgetHost | 14 | 10 | 4 | 71.4% |
| BrowserHost | 1 | 0 | 1 | 0% |
| LiveTileHost | 1 | 1 | 0 | 100% |
| **TOTAL** | **16** | **11** | **5** | **68.75%** |

*Correction Note: Rev1 claimed WidgetHost = 11 total with 8 COULD-BE-VIEW + 3 MUST-STAY-NATIVE. Actual table shows 14 total with 10 COULD-BE-VIEW + 4 MUST-STAY-NATIVE.*

---

## Corrected Summary by Classification

| Classification | Count | Percentage |
|---|---|---|
| COULD-BE-VIEW | 11 | 68.75% |
| MUST-STAY-NATIVE | 5 | 31.25% |
| OBSOLETE | 0 | 0% |
| **TOTAL** | **16** | **100%** |

---

## Key Findings

1. **Authoritative Surface Count: 16** — All entries verified against Master Inventory Table with real XAML:Code citations.

2. **WidgetHost Discrepancy Resolved:** Rev1's "By Host" roll-up claimed 11 surfaces, but Master Table documents 14:
   - **COULD-BE-VIEW (10):** Tabs, InputBox, SendBtn, Toolbar, SessionMeta, AttachmentMeta, SlashPopup, ToolsMenu, ExtensionsMenu, TabSwitcher
   - **MUST-STAY-NATIVE (4):** LauncherWindow, MainWindow, TerminalTabSession, CommanderSession

3. **Classification Cascade:** 
   - COULD-BE-VIEW: 11 (not 10) — +1 from WidgetHost recount
   - MUST-STAY-NATIVE: 5 (not 6) — -1 from WidgetHost recount

4. **Migration Potential Increased:** 68.75% of UI surfaces (vs. 62.5% claimed in rev1) are migratable to WebView2/React.

5. **No Dead Code:** All 16 surfaces have active purposes. OBSOLETE = 0.

---

## Detailed Classification Rationale

### MUST-STAY-NATIVE (5 surfaces)

**LauncherWindow** (WidgetHost.LauncherWindow.xaml:1-16, CS:1-497)
- Frameless, transparent, topmost floating window with global mouse tracking
- Requires Win32 P/Invoke (GetCursorPos) + mouse capture
- **Verdict:** Native-only. Web cannot achieve floating desktop tile with z-order and mouse capture.

**MainWindow** (WidgetHost.MainWindow.xaml:1-18, CS:1-1300+)
- Custom WPF chrome, topmost z-order, DragMove() behavior
- Coordinates with LauncherWindow positioning
- **Verdict:** Native-only. Web cannot render as floating window with topmost z-order.

**TerminalTabSession** (WidgetHost.TerminalTabSession.cs:1-200+)
- Embeds Microsoft.Terminal.Wpf.TerminalControl
- Uses Win32 ConPTY API (PseudoConsoleApi) for PTY management
- **Verdict:** PTY management stays native. Terminal *rendering* can partially migrate to xterm.js in BrowserHost via subprocess bridge.

**CommanderSession** (WidgetHost.CommanderSession.cs:27-200+)
- Service layer coordinating tool execution, MCP dispatch, process lifecycle
- Direct integration with TerminalTabSession PTY management
- **Verdict:** Native-only service. (Display state in SessionMeta/AttachmentMeta can migrate.)

**BrowserHost** (BrowserHost.MainWindow.xaml:1-31)
- WPF Window hosting WebView2 control
- Window lifecycle management requires native code
- **Verdict:** Host window stays native. Content inside WebView2 can be web-based.

### COULD-BE-VIEW (11 surfaces)

**Tabs, InputBox, SendBtn, Toolbar** — Pure UI containers/inputs with standard web patterns.
- **Rationale:** No native dependencies. React components sufficient. State changes map to MCP Commands.

**SessionMeta, AttachmentMeta** — Read-only displays of session state.
- **Rationale:** IPC data binding via MCP Events. React components receive updates.

**SlashPopup** — Popup menu with keyboard navigation.
- **Rationale:** Standard web popover pattern. onKeyDown handlers for Up/Down/Tab/Enter/Esc.

**ToolsMenu, ExtensionsMenu, TabSwitcher** — Context menus with checkboxes/items.
- **Rationale:** Dynamically generated React menus. No native dependencies.

**LiveTileHost** (LiveTileHost.MainWindow.xaml:1-328)
- Tile rendering from file or REST API
- **Verdict:** COULD-BE-VIEW pending architecture decision. If tile data moves to REST API, migrate to React. If file-watched, keep native or establish IPC bridge.

---

## Verdict

**Authoritative Count (N):** 16 surfaces  
**Corrected Breakdown:** WidgetHost 14 + BrowserHost 1 + LiveTileHost 1 = 16 ✓  
**Classification Fix:** COULD-BE-VIEW 11 (68.75%) + MUST-STAY-NATIVE 5 (31.25%) = 16 ✓  

Rev1's arithmetic drift stemmed from a typo in the "By Host" roll-up table (line 630: WidgetHost claimed 11 surfaces when Master Inventory Table clearly documents 14). The authoritative count of 16 is correct; the host and classification breakdowns now reconcile with real XAML/code citations. Migration potential increases to 68.75% with three additional COULD-BE-VIEW surfaces (ToolsMenu, ExtensionsMenu, TabSwitcher) properly classified.