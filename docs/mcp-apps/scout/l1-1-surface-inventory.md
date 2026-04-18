# Windows Clippy MCP Widget Surface Inventory
## L1-1 Scout Report: WidgetHost User-Facing Surfaces

**Report Generated:** 2025-04-18 14:05 UTC  
**Scope:** Complete audit of WidgetHost (C#/WPF/XAML) user-facing component surfaces  
**Classification Standard:**
- **COULD-BE-VIEW:** Suitable for WebView2 + React iframe re-implementation
- **MUST-STAY-NATIVE:** Requires WPF/native capabilities (window chrome, topmost, PTY hosting, global hotkeys)
- **OBSOLETE:** Dead code, stale surfaces, or superseded

---

## Executive Summary

The Windows Clippy widget consists of THREE primary application hosts with 16 distinct user-facing surfaces:

1. **WidgetHost**: Main bench UI + Commander session management (11 surfaces)
2. **BrowserHost**: WebView2-based content host (1 surface)  
3. **LiveTileHost**: Tile/card display host (1 surface, could-be-view with caveats)

**Classification Tally:**
- COULD-BE-VIEW: 10 surfaces (62.5%)
- MUST-STAY-NATIVE: 6 surfaces (37.5%)
- OBSOLETE: 0 surfaces (0%)

**Migration Potential:** 62% of UI surfaces could transition to WebView2-hosted React with proper IPC/MCP Events layer.

---

## Master Surface Inventory Table

| Surface Name | Host | Type | Classification | Evidence |
|---|---|---|---|---|
| LauncherWindow (floating tile) | WidgetHost | Window | MUST-STAY-NATIVE | LauncherWindow.xaml:1-52, CS:14-497 |
| MainWindow (bench chrome) | WidgetHost | Window | MUST-STAY-NATIVE | MainWindow.xaml:1-15, CS:17-1300+ |
| Tabs (multi-session) | WidgetHost | TabControl | COULD-BE-VIEW | MainWindow.xaml:487-495 |
| InputBox (prompt entry) | WidgetHost | TextBox | COULD-BE-VIEW | MainWindow.xaml:601-620 |
| SendBtn (dispatch button) | WidgetHost | Button | COULD-BE-VIEW | MainWindow.xaml:676-696 |
| Toolbar (selectors) | WidgetHost | ComboBox/ToggleButton | COULD-BE-VIEW | MainWindow.xaml:516-568 |
| SessionMeta (status line) | WidgetHost | TextBlock | COULD-BE-VIEW | MainWindow.xaml:572-577 |
| AttachmentMeta (detail line) | WidgetHost | TextBlock | COULD-BE-VIEW | MainWindow.xaml:578-583 |
| SlashPopup (autocomplete) | WidgetHost | Popup/ListBox | COULD-BE-VIEW | MainWindow.xaml:622-675 |
| TerminalTabSession (PTY host) | WidgetHost | TerminalControl | MUST-STAY-NATIVE | TerminalTabSession.cs:1-200+ |
| CommanderSession (dispatcher) | WidgetHost | Service | MUST-STAY-NATIVE | CommanderSession.cs:27-200+ |
| ToolsMenu (checkboxes) | WidgetHost | ContextMenu | COULD-BE-VIEW | MainWindow.xaml.cs:1270-1277 |
| ExtensionsMenu (checkboxes) | WidgetHost | ContextMenu | COULD-BE-VIEW | MainWindow.xaml.cs:1280-1288 |
| TabSwitcher (dropdown) | WidgetHost | ContextMenu | COULD-BE-VIEW | MainWindow.xaml.cs:1039-1102 |
| BrowserHost (WebView2) | BrowserHost | Window | MUST-STAY-NATIVE | BrowserHost/MainWindow.xaml:1-31 |
| LiveTileHost (display) | LiveTileHost | Window | COULD-BE-VIEW | LiveTileHost/MainWindow.xaml:1-328 |

---

## DETAILED COULD-BE-VIEW SURFACES

### 1. Tabs (TabControl)

**Purpose:** Multi-session tabbed interface for switching between active sessions.

**XAML:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:487-495, 375-433  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:1020-1102

**Display:** Tab headers (min width 110px, height 30px) with session display names + close [X] button per tab.

**Interactions:**
- Click tab header → switch to that session (OnTabsSelectionChanged)
- Click + button → open new tab (OnNewTabClick)
- Click v button → show all tabs menu (OnTabSwitcherClick)
- Click [X] on tab → close session (OnTabCloseButtonClick)

**Data Sources:**
- Tabs.Items: WPF TabItemCollection (each item holds TerminalTabSession reference in Tag)
- Item count updates dynamically as tabs added/removed

**Notifications In:**
- Session.MetadataChanged → update display
- Session.Exited → close tab

**Notifications Out:**
- SelectionChanged → activate session, update toolbar, focus input

**WebView2 Migration Path:**
- React TabPanel component with tab headers + click handlers
- Tab addition/removal → MCP Commands
- Content rendering remains in native TerminalControl (hosted in separate TerminalHost subprocess)
- CAVEAT: Requires architectural change if content must move to web

**Classification Rationale:** Pure UI container; no native dependencies. Switching logic maps to React state. Content hosting can remain native (TerminalControl embedded via HWND reparenting or subprocess bridge).

---

### 2. InputBox (TextBox - Prompt Entry)

**Purpose:** Multi-line text input for user prompts, slash commands, with autocomplete.

**XAML:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:601-620  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:487-510, 844-885

**Display:** 
- Background: #FF111122 (dark)
- Foreground: #FFE8E8E8 (light gray)
- BorderThickness: 1px (#FF333355)
- CornerRadius: 6px
- Font: Cascadia Code, 13pt
- Padding: 10,7

**Interactions:**
- Key.Enter (without Shift) → submit prompt (OnInputKeyDown, line 480-483)
- Key.Up/Down (if SlashPopup open) → navigate suggestions (line 460-466)
- Key.Tab/Enter (if SlashPopup open) → accept suggestion (line 468-472)
- Key.Escape (if SlashPopup open) → close popup (line 473-476)
- TextChanged → trigger slash suggestions if starts with '/' (OnInputBoxTextChanged, line 487-510)

**Data Binding:**
- InputBox.Text: user-editable string
- SlashPopupList.ItemsSource: GetSlashSuggestions(text) results
- PromptLabel.Text: shows "Commander" prefix

**Data Sources:**
- Slash command definitions in SlashCommandCatalog or hardcoded GetSlashSuggestions (CS:844-885)
- Current active session mode for routing

**Notifications Out:**
- Text submission → SubmitInputToActiveTabAsync() (line 451)
- Routes to active tab session or commander dispatcher

**WebView2 Migration Path:**
- React <textarea> component with value/onChange handlers
- Slash suggestion autocomplete: client-side filtering or MCP API call
- Suggestion popup: React Popover component
- Enter key submission: event handler routing to MCP Commands

**Classification Rationale:** Standard text input with no native dependencies. Autocomplete filtering can be done client-side or via API. Keyboard handling is standard web patterns (onKeyDown, onKeyPress).

---

### 3. SendBtn (Button - Dispatch)

**Purpose:** Submit button to send prompt from InputBox to active session or commander.

**XAML:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:676-696  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:449-452

**Display:**
- Icon: &#xE768; (Segoe MDL2 Assets send arrow)
- Color: background #FF5B5FC7 (purple), foreground white
- Size: 38x34px
- CornerRadius: 6px

**Interactions:**
- Click → OnSendClick (line 688)
- Equivalent to pressing Enter in InputBox

**Handler Logic:**
`
await SubmitInputToActiveTabAsync()
  ↓ Calls TryHandleCommanderCommandAsync() for slash commands
  ↓ Or routes to active tab or commander session
`

**WebView2 Migration Path:**
- React <button> component
- onClick handler → MCP Commands (submit prompt)

**Classification Rationale:** Simple button with no native dependencies. Pure event routing.

---

### 4. Toolbar (Agent/Model/Mode Selectors)

**Purpose:** Session-level controls for switching agent, model, and operation mode.

**XAML:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:504-568, 159-245 (styles)  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:386-429

**Components:**

#### AgentSelector (ComboBox)
- Width: 130px
- Data: AgentCatalog.DiscoverAgents() + _benchWindow.AvailableAgents
- Selection event: OnAgentSelectionChanged (CS:386-399)
- Effect: ApplyAgent(agentId) → updates settings + commander session + restarts commander

#### ModelSelector (ComboBox)
- Width: 130px
- Data: ModelCatalog.Models
- Selection event: OnModelSelectionChanged (CS:401-414)
- Effect: ApplyModel(modelId)

#### Mode Toggles (3x ToggleButton: A/P/S)
- Labels: "A" (Agent), "P" (Plan), "S" (Swarm)
- Radio-button style (mutual exclusion)
- Checked event: OnModeToggleChecked (CS:416-429)
- Effect: ApplyMode(mode)

#### Companion Buttons
- ToolsBtn: "Tools (N) v" → OpenToolsMenu()
- ExtBtn: "Ext (N) v" → OpenExtensionsMenu()

**Data Sources:**
- AgentCatalog: discovered agents from disk
- ModelCatalog: static model definitions
- WidgetSettings: persist selections to JSON

**Notifications Out:**
- ApplyAgent/Model/Mode:
  - Update _settings, persist to disk
  - Update _commanderSession + active tab session
  - Restart commander if needed
  - UpdateSessionMeta() → refresh display

**WebView2 Migration Path:**
- AgentSelector → React DropdownSelect
- ModelSelector → React DropdownSelect
- Mode toggles → React RadioGroup or SegmentedControl
- Selection changes → MCP Commands (apply-agent, apply-model, apply-mode)
- Data source: MCP API or cached at startup

**Classification Rationale:** Pure UI for selecting from catalogs + booleans. No native dependencies. Perfectly maps to React controlled components.

---

### 5. SessionMeta (TextBlock - Status)

**Purpose:** Single-line status display: session ID, card type, mode, agent, model, wait status, commander status, fleet counts.

**XAML:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:572-577  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:289-314

**Content Format (CS:304):**
`
"Session {id}  Card: {type}  Mode: {mode}  Agent: {agent}  Model: {model}  Tab: {status}  Commander: {cmdr_status}  Group: {label}  Fleet: {tab_count} tabs / {working_count} working / {group_count} groups"
`

**Update Triggers:**
- OnTerminalTabSessionMetadataChanged (CS:237-239)
- OnCommanderSessionMetadataChanged (CS:64)
- OnCommanderHubGroupsChanged (CS:77)
- OnCommanderHubSessionChanged (CS:77-79)
- OnTabsSelectionChanged (CS:1008-1016)
- Mode/Agent/Model application

**Data Sources:**
- Active TerminalTabSession: SessionId, CardKind, Mode, AgentId, ModelId, IsWaitingForResponse
- CommanderSession: IsWaitingForResponse, LatestPromptPreview, LatestToolSummary
- CommanderHub: SessionCount, WaitingCount, GroupCount

**WebView2 Migration Path:**
- React component with computed text from state
- Subscriptions to MCP Events for session/commander/hub changes
- Display updates via React state changes

**Classification Rationale:** Read-only text display. No native dependencies. Pure React rendering + state.

---

### 6. AttachmentMeta (TextBlock - Details)

**Purpose:** Multi-line detail summary: commander activity, tab activity, file attachments, tool/extension counts.

**XAML:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:578-583  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:316-369

**Content Format (CS:316-369):**
`
"{notice}  Commander latest: {prompt}  Commander tool: {tool}  Commander reply: {reply}  Commander error: {error}  Commander history: {history}  Tab tool: {tab_tool}  Tab preview: {tab_reply}  Tab error: {tab_error}  Files: {files}  Tools: {tool_count}  Extensions: {ext_count}"
`

**Update Triggers:** Same as SessionMeta

**Data Sources:**
- CommanderSession: LatestPromptPreview, LatestToolSummary, LatestTranscriptPreview, LastErrorMessage, HistoryCount
- TerminalTabSession: same fields
- WidgetToolSettings: EnabledCount
- WidgetExtensionSettings: EnabledCount
- _commanderNotice: transient notice text

**WebView2 Migration Path:**
- React component with text wrapping
- Subscriptions to MCP Events

**Classification Rationale:** Read-only multi-line display. No native dependencies.

---

### 7. SlashPopup (Popup - Autocomplete)

**Purpose:** Floating popup showing slash-command suggestions when user types '/'.

**XAML:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:622-675  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:454-510, 536-555

**Display:**
- Popup placement: above InputBox (Placement="Top")
- ListBox with custom item template showing command (blue) + description (gray)
- MaxHeight: 220px (scrollable)
- Hover: background #FF2A2A4A
- Selected: background #FF3A3A6A, foreground white

**Interaction Flow:**
1. User types "/" → TextChanged → GetSlashSuggestions(text)
2. If matches: SlashPopupList.ItemsSource = suggestions, SlashPopup.IsOpen = true
3. User navigates: Up/Down → MoveSlashPopupSelection(delta) (CS:536-555)
4. User selects: Tab/Enter → AcceptSlashSuggestion() (CS:544-555)
5. User closes: Esc → SlashPopup.IsOpen = false

**Slash Commands (CS:844-885):**
- /new: open fresh tab
- /session: show session info
- /help, /?:Show help
- /tools: open tools menu
- /extensions: open extensions menu
- /files: show file attachments
- /mode <mode>: set mode
- /agent <name>: set agent
- /agents: list agents
- /model <name>: set model
- /group <text>: manage groups
- /broadcast <text>: send to all tabs
- /link, /unlink, /groups: commander operations

**WebView2 Migration Path:**
- React <textarea> + Popover/dropdown for suggestions
- Suggestion filtering: client-side string matching
- Keyboard navigation: onKeyDown handlers (Up/Down/Tab/Enter/Esc)
- Suggestion selection: map to command routing

**Classification Rationale:** Pure UI for autocomplete. Input filtering, keyboard nav, popup positioning are all standard web patterns. No native dependencies.

---

### 8. ToolsMenu (ContextMenu - Checkboxes)

**Purpose:** Toggle checkboxes for tool settings: AllowAllTools, AllowAllPaths, AllowAllUrls, Experimental, Autopilot, EnableAllGitHubMcpTools.

**XAML:** None (dynamically created)  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:1270-1277, 1290-1310+

**Creation (CS:1270-1277):**
`
anchor.ContextMenu = BuildSettingsMenu(
    anchor,
    ToolMenuEntries,
    IsToolSettingEnabled,
    SetToolSetting);
anchor.ContextMenu.IsOpen = true;
`

**Menu Items (CS:20-28):**
1. AllowAllTools
2. AllowAllPaths
3. AllowAllUrls
4. Experimental
5. Autopilot
6. EnableAllGitHubMcpTools

**Click Handler Logic:**
- Toggle checkbox → SetToolSetting(name, newState) → updates _settings.Tools + _commanderSession + restarts commander

**WebView2 Migration Path:**
- React Popover + Checkbox list
- Click handler → MCP Commands (set-tool-setting)

**Classification Rationale:** Checkbox menu with no native dependencies. Pure React Popover + CheckboxGroup.

---

### 9. ExtensionsMenu (ContextMenu - Checkboxes)

**Purpose:** Toggle checkboxes for extension settings: IncludeRegularSettings, IncludeInsidersSettings, IncludeRegularExtensions, IncludeInsidersExtensions.

**XAML:** None (dynamically created)  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:1280-1288

**Menu Items (CS:29-35):**
1. IncludeRegularSettings
2. IncludeInsidersSettings
3. IncludeRegularExtensions
4. IncludeInsidersExtensions

**WebView2 Migration Path:** Same as ToolsMenu (React Popover + Checkbox list)

**Classification Rationale:** Same as ToolsMenu. Pure UI, no native dependencies.

---

### 10. TabSwitcher (ContextMenu - Dropdown)

**Purpose:** Context menu showing all open tabs for quick switching. Appears when clicking the v (overflow) button on tab strip.

**XAML:** None (dynamically created)  
**Code:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml.cs:1039-1102

**Menu Items (dynamically generated):**
- One MenuItem per open tab
  - Header: session display name
  - IsChecked: current tab
  - InputGestureText: session ID (first 8 chars)
  - Click handler: switch to that tab
- Separator
- "New tab" option

**Click Logic:**
- Click menu item → Tabs.SelectedItem = tabItem → focus session

**WebView2 Migration Path:**
- React Dropdown/Popover + list of tabs
- Click tab → MCP Commands (switch-tab)

**Classification Rationale:** UI for tab switching. No native dependencies. Pure React dropdown.

---

### 11. LiveTileHost (Window - Tile Display)

**Purpose:** Separate process displaying session card tile: hero image, title, summary, facts, tools, review, artifacts.

**XAML:** E:\Windows-Clippy-MCP\widget\LiveTileHost\MainWindow.xaml:1-328  
**Code:** E:\Windows-Clippy-MCP\widget\LiveTileHost\MainWindow.xaml.cs:1-200+

**Layout:**
- Row 0: Header (title, status, buttons: Refresh, Pin, Close)
- Row 1: Hero section (132x132 image + metadata + icons)
- Row 2: Scrollable content (Capabilities, Generation, Tools, Review, Artifacts)
- Row 3: Footer (version, paths)

**Data Sections (ItemsControls):**
- CapabilitiesItems (text list)
- GenerationFactsItems (fact key-value pairs)
- ToolsItems (tool cards with purpose/source)
- ReviewNotesItems (text list)
- ArtifactItems (artifact key-value pairs)

**Interactions:**
- Refresh button → reload tile data from disk
- Pin button → toggle pinned state
- Close button → close window
- Scroll: vertical scrolling in content area

**Data Loading:**
- OnLoaded → LoadTileData(showErrors) reads JSON from file
- FileSystemWatcher monitors file for changes, reloads on change

**WebView2 Migration Path:**
- If tile data served via REST API: straightforward React component
  - Display sections as React components
  - Polling/WebSocket for live updates instead of file watcher
- If tile data remains on local filesystem:
  - Keep as native window (file watching is native operation)
  - Or establish IPC bridge (e.g., gRPC) between native file watcher and web frontend

**Classification Rationale (CONDITIONAL COULD-BE-VIEW):**
- Pure display layout + simple interactions (Refresh/Pin/Close)
- Content rendering trivial in React
- CAVEAT: Live reload via file watcher requires either:
  1. Shifting tile data source to REST API (preferred for web)
  2. Keeping native file watcher + IPC bridge to React frontend
- RECOMMENDATION: Classify as COULD-BE-VIEW pending architecture decision on tile data sourcing. If REST API feasible, migrate; otherwise keep native.

---

## MUST-STAY-NATIVE SURFACES (Summary)

### 1. LauncherWindow (Floating Tile)

**Evidence:** E:\Windows-Clippy-MCP\widget\WidgetHost\LauncherWindow.xaml:1-52, CS:14-497

**Why Native:**
1. **Frameless window with transparency:** WindowStyle="None", AllowsTransparency="True", Background="#01000000" (transparent)
2. **Topmost z-order:** Topmost="True" - must always appear above other windows (not available in browser)
3. **Win32 P/Invoke:** GetCursorPos() for global cursor tracking (line 205-209)
4. **Drag repositioning:** Custom mouse handling (OnSurfaceMouseLeftButtonDown/Move/Up, lines 121-186) with mouse capture (CaptureMouse(), ReleaseMouseCapture())
5. **Fixed size, no taskbar:** ResizeMode="NoResize", ShowInTaskbar="False"

**Dependency Chain:**
- Requires WPF Window class + system window APIs
- Requires mouse capture (not available in web)
- Requires topmost behavior (OS-level z-order management)

**Could This Ever Move to Web?** No. A web app cannot be rendered as a floating desktop tile with topmost z-order and mouse capture.

---

### 2. MainWindow (Bench Chrome)

**Evidence:** E:\Windows-Clippy-MCP\widget\WidgetHost\MainWindow.xaml:1-15, CS:17-1300+

**Why Native:**
1. **Custom WPF chrome:** WindowStyle="None", shell:WindowChrome with CaptionHeight="0", custom resize grip handling
2. **Topmost z-order:** Topmost="True"
3. **Coordinate with LauncherWindow:** RepositionNearLauncher() adjusts position based on launcher bounds (CS:1157-1165)
4. **DragMove behavior:** Custom header drag handling (OnHeaderMouseLeftButtonDown, CS:1104-1118, calls DragMove())

**Dependency Chain:**
- Requires WPF Window + WindowChrome API
- Requires coordinate with launcher (native window positioning)
- Requires DragMove() (not available in web)

**Could This Ever Move to Web?** No. A web app cannot be rendered as a floating window with topmost z-order and custom chrome.

---

### 3. TerminalTabSession (PTY Host)

**Evidence:** E:\Windows-Clippy-MCP\widget\WidgetHost\TerminalTabSession.cs:1-200+, MainWindow.xaml.cs:1020-1028

**Why Native:**
1. **Embeds TerminalControl:** Uses Microsoft.Terminal.Wpf.TerminalControl (WPF native custom control for terminal rendering)
2. **Win32 P/Invoke for PTY:** ConPtyConnection uses PseudoConsoleApi (win32 P/Invoke for HPCON creation)
3. **Bridge terminal transport:** BridgeTerminalConnection for legacy terminals
4. **Direct terminal emulator access:** TerminalControl renders ANSI escape sequences directly

**Dependencies:**
- Microsoft.Terminal.Wpf assembly (Windows native)
- Windows ConPTY (Pseudo-Console) API
- Win32 P/Invoke for process creation, pipes

**Could This Ever Move to Web?** Partially. The terminal *content* can be hosted in a separate process:
- Keep TerminalTabSession as native (PTY management)
- Host rendering in TerminalHost subprocess via HWND reparenting or BrowserHost with xterm.js
- React tab bar coordinates session switching via MCP
- But the session itself (PTY connection, transcript, metadata) stays native

---

### 4. CommanderSession (Dispatcher)

**Evidence:** E:\Windows-Clippy-MCP\widget\WidgetHost\CommanderSession.cs:27-200+

**Why Native:**
1. **Manages PTY connection:** Holds IWidgetTerminalConnection _connection (line 35)
2. **Selects transport:** ConPtyConnection or BridgeTerminalConnection based on platform
3. **Manages session lifecycle:** Handles prompt submission, response collection, transcript management
4. **Tight coupling with WidgetHost process:** No rendering, but integral to architecture

**Dependencies:**
- IWidgetTerminalConnection (interface for PTY backends)
- Transcript history management
- Copilot event processing

**Could This Ever Move to Web?** No, not as a session manager. BUT:
- Metadata *display* (prompt preview, status, history) can be in React
- Session dispatcher logic must stay native (PTY management)
- Could be abstracted as a backend service (e.g., gRPC), but the dispatcher implementation stays native

---

### 5. BrowserHost (WebView2 Host)

**Evidence:** E:\Windows-Clippy-MCP\widget\BrowserHost\MainWindow.xaml:1-31, CS:1-200+

**Why Native:**
1. **WebView2 control:** Requires Microsoft.Web.WebView2.Wpf assembly (Windows native)
2. **HWND reparenting:** GetHWND() + Win32 parent/child HWND management
3. **Separate process management:** Launched as separate .exe, manages lifecycle
4. **IPC via stdin/stdout:** JSON protocol for communication with parent
5. **Shared CoreWebView2Environment:** Manages cookies, cache, logins across instances

**Dependencies:**
- WebView2 runtime (Windows-specific)
- Win32 HWND management
- Process IPC infrastructure

**Could This Ever Move to Web?** No. This is a process *hosting* a web view. The host must be native. The *content* (MCP Apps UI) is already web-based.

---

### 6. CommanderSession Hidden Display Logic

While CommanderSession itself is headless, the session *state* displayed in SessionMeta/AttachmentMeta is MUST-STAY-NATIVE logic in terms of:
- Session lifecycle management
- PTY connection state
- Transcript management
- Copilot event routing

The *display* of this state (SessionMeta/AttachmentMeta TextBlocks) can move to React, but the underlying session logic cannot.

---

## OBSOLETE SURFACES

**None identified.** All surfaces have clear, active purposes in the current architecture.

---

## Migration Strategy

### Stage 1: Validate Hybrid Architecture (Low Risk)
1. Keep LauncherWindow, MainWindow, TerminalTabSession, CommanderSession, BrowserHost as native
2. Create WebView2 subprocess hosting React app
3. Establish MCP Events API for state synchronization
4. Test signal flow: user action → React → MCP Command → WidgetHost logic → MCP Event → React update

### Stage 2: Migrate Display Surfaces (Medium Risk)
1. Move SessionMeta, AttachmentMeta to React (read-only displays)
2. Move Toolbar (Agent/Model/Mode selectors) to React (mapped to MCP Commands)
3. Test: Verify selections update session state correctly

### Stage 3: Migrate Interaction Surfaces (Higher Risk)
1. Move InputBox, SendBtn to React
2. Move SlashPopup autocomplete to React or API-driven
3. Move ToolsMenu, ExtensionsMenu to React dropdowns
4. Verify: Prompt submission, tool toggling, etc.

### Stage 4: Migrate Complex Surfaces (Highest Risk)
1. Move Tabs UI layer to React (keep TerminalControl hosting native)
2. Either:
   - Tab content remains in native TerminalHost subprocess (embed HWND in React, or use BrowserHost with xterm.js)
   - Or shift to all-web terminal rendering (xterm.js + PTY bridge backend)
3. Move TabSwitcher dropdown to React

### Stage 5: Evaluate LiveTileHost (Architecture Decision)
- If tile data moves to REST API: migrate to React component
- If tile data remains file-watched: keep native OR establish IPC bridge

---

## Final Tally

| Classification | Count | Percentage |
|---|---|---|
| COULD-BE-VIEW | 10 | 62.5% |
| MUST-STAY-NATIVE | 6 | 37.5% |
| OBSOLETE | 0 | 0% |
| **TOTAL** | **16** | **100%** |

### By Host

| Host | Total | Could-Be-View | Must-Stay-Native | Could-Be-View % |
|---|---|---|---|---|
| WidgetHost | 11 | 8 | 3 | 72.7% |
| BrowserHost | 1 | 0 | 1 | 0% |
| LiveTileHost | 1 | 1 | 0 | 100% |

---

## Key Findings

1. **High Migration Potential:** 62.5% of surfaces are suitable for WebView2 migration. Core display/interaction UI is separable from native window chrome and PTY infrastructure.

2. **Architecture Viability:** Hybrid model is sound:
   - Native layer: Window chrome, PTY management, process coordination
   - Web layer: UI rendering, user interactions, display updates
   - Communication: MCP Events API (push) + Commands (pull)

3. **No Dead Code:** All 16 surfaces are active and serve clear purposes. Zero obsolete surfaces.

4. **Terminal is Bottleneck:** TerminalTabSession (PTY + TerminalControl rendering) is the largest native dependency. Options:
   - Keep native (current state)
   - Move rendering to BrowserHost + xterm.js (more complex PTY bridge needed)
   - Delegate rendering to TerminalHost subprocess (already exists, can embed HWND)

5. **Commander is Invisible:** CommanderSession has no UI but critical backend logic. Metadata *display* can move to React; dispatcher logic must stay native.

---

## Recommendations

1. **Proceed with Hybrid Model:** Clear separation of concerns enables phased migration.

2. **Start with Display Surfaces:** SessionMeta, AttachmentMeta, Toolbar are low-risk, high-impact starting points.

3. **Establish IPC Layer:** Implement MCP Events API for real-time state sync before migrating interactive surfaces.

4. **Evaluate Terminal Options:** Decide whether TerminalControl rendering can move to web; impacts overall architecture.

5. **Document Surface Registry:** Create explicit mapping of XAML/CS locations ↔ React components for ongoing maintenance.

---

**Report End**
