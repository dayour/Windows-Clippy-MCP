<!-- Windows Clippy MCP – README -->

<div align="center">

  <img src="assets/WC25.png" alt="Windows Clippy MCP Logo" width="200" height="200">

  <h1>Windows Clippy MCP</h1>

  <a href="https://github.com/dayour/windows-clippy-mcp/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  </a>
  <img src="https://img.shields.io/badge/python-3.13%2B-blue" alt="Python">
  <img src="https://img.shields.io/badge/platform-Windows%2011-blue" alt="Platform: Windows 11">
  <img src="https://img.shields.io/github/last-commit/dayour/windows-clippy-mcp" alt="Last Commit">
  <br>


</div>

---

Windows Clippy MCP is a Windows 11-first **Model Context Protocol (MCP)** server and native Clippy widget host. It combines desktop automation, Microsoft 365 integration, and bundled MCP Apps surfaces so Clippy can operate through the same tool and view contracts it exposes to external hosts.

It exposes **49 tools total: 42 Desktop Automation tools + 7 M365/Power Platform tools** that cover everyday desktop automation--launching apps, clicking, typing, scrolling, getting UI state, managing windows, controlling volume, taking screenshots, and more--while hiding the Windows Accessibility, input-synthesis, and widget-host plumbing behind a simple stdio interface.

**Current evidence bar:** the in-repo widget host is end-to-end proven for Fleet Status, Commander, and Agent Catalog. Generic UI-capable and headless host classes are covered by `npm run mcp-apps:host-conformance`. Product-specific configs remain documented guidance unless separately proven; see [`docs/mcp-apps/host-conformance.md`](docs/mcp-apps/host-conformance.md).

---

## Key Features

• **Native Windows integration** – Uses UI Automation, Win32 APIs, and pyautogui for reliable control.
• **Microsoft 365 integration** – Built-in tools for Graph API, Power Platform, and Copilot Studio.
• **Zero CV / Vision optional** – Works with *any* LLM; screenshot attachment is optional.
• **Fast** – Typical end-to-end latency 1.5 – 2.3 s per action.
• **MCP-compliant** – Validates against the official JSON schema and ships with MCP Apps host-conformance checks.
• **Extensible** – Add your own Python tools in `main.py`.
• **MIT-licensed** – Fork, embed, or commercialize freely.

---

## Supported OS

• Windows 11 (tested)
*Windows 10 may work but is not officially supported.*

---

## Available Tools (49 Total: 42 Desktop Automation + 7 M365/Power Platform)

### Desktop Automation Tools (42)

#### Core Interaction Tools

| Tool | Purpose |
|------|---------|
| Launch-Tool | Launch an application from the Start menu. |
| Powershell-Tool | Run a PowerShell command and capture output. |
| State-Tool | Dump active app, open apps, interactive / informative / scrollable elements, plus optional screenshot. |
| Clipboard-Tool | Copy text to clipboard or paste current clipboard contents. |
| Click-Tool | Click at `(x, y)` with configurable button/clicks. |
| Type-Tool | Type text into the UI with optional clear. |
| Switch-Tool | Bring a window (e.g., "notepad") to the foreground. |
| Scroll-Tool | Vertical / horizontal scrolling at coordinates. |
| Drag-Tool | Drag from `(x1, y1)` to `(x2, y2)`. |
| Move-Tool | Move mouse cursor. |
| Shortcut-Tool | Send keyboard shortcut list (e.g., `["win","r"]`). |
| Key-Tool | Press single key (Enter, Esc, F1-F12, arrows, etc.). |
| Wait-Tool | Sleep for N seconds. |

### Web & Browser Tools

| Tool | Purpose |
|------|---------|
| Browser-Tool | Launch Microsoft Edge and navigate to URL. |
| Scrape-Tool | Fetch a webpage and return Markdown. |

### Window Management Tools

| Tool | Purpose |
|------|---------|
| Window-Tool | Minimize, maximize, restore, close, or resize windows. |
| TaskView-Tool | Open Task View, create/close/switch virtual desktops. |
| Taskbar-Tool | Interact with taskbar, start menu, system tray. |

### Screenshot & Visual Tools

| Tool | Purpose |
|------|---------|
| Screenshot-Tool | Capture full screen, region, or active window. |
| Snip-Tool | Open Windows Snipping Tool for annotated captures. |
| Screen-Info-Tool | Get information about connected monitors. |
| Cursor-Position-Tool | Get current mouse cursor position. |

### System Control Tools

| Tool | Purpose |
|------|---------|
| Volume-Tool | Control system volume: mute, unmute, set level, up/down. |
| Lock-Tool | Lock workstation, sign out, sleep, hibernate, shutdown, restart. |
| ActionCenter-Tool | Open Quick Settings or Notifications panel. |
| Emoji-Tool | Open Windows Emoji picker (Win+.). |
| Clipboard-History-Tool | Open Windows Clipboard History (Win+V). |
| Run-Dialog-Tool | Open Run dialog and optionally execute commands. |

### Settings & Configuration Tools

| Tool | Purpose |
|------|---------|
| Settings-Tool | Open specific Windows Settings pages (35+ pages supported). |
| Registry-Tool | Read Windows Registry values (read-only for safety). |
| Wifi-Tool | List networks, connect, disconnect, get WiFi status. |
| Bluetooth-Tool | Open Bluetooth settings or check device status. |

### File & Process Tools

| Tool | Purpose |
|------|---------|
| File-Tool | Create, delete, rename, copy, move, read, write files. |
| FileExplorer-Tool | Open File Explorer at specific path. |
| Process-Tool | List running processes or kill by name/PID. |
| SystemInfo-Tool | Get CPU, memory, disk, OS, network, battery info. |
| Search-Tool | Perform Windows Search for files, apps, settings. |

### Text Editing Tools

| Tool | Purpose |
|------|---------|
| Text-Select-Tool | Select text (all, word, line, from cursor). |
| Find-Replace-Tool | Open Find or Find and Replace dialog. |
| Undo-Redo-Tool | Perform undo/redo operations. |
| Zoom-Tool | Zoom in/out or reset zoom in active application. |

### Notification Tools

| Tool | Purpose |
|------|---------|
| Notification-Tool | Display Windows toast notifications. |

### Microsoft 365 & Power Platform Tools

| Tool | Purpose |
|------|---------|
| PAC-CLI-Tool | Execute Power Platform CLI commands for app management. |
| Connect-MGGraph-Tool | Authenticate with Microsoft Graph API. |
| Graph-API-Tool | Execute Microsoft Graph API calls for Office 365 data. |
| Copilot-Studio-Tool | Manage Copilot Studio agents: list, eval, trigger native evaluation runs via Agent Studio backend. |
| Agent-Studio-Tool | Query the unified Agent Studio store: eval runs, feedback, monitoring, activity timelines, MCP capabilities. |
| Power-Automate-Tool | Create and manage Power Automate workflows. |
| M365-Copilot-Tool | Interact with Microsoft 365 Copilot features. |

---

## Quick Start (VS Code Agent Mode)

**Choose your preferred installation method:**

### Option 1: One-Click NPM Installation (Recommended)

The fastest way to get started:

```shell
npm install -g @dayour/windows-clippy-mcp
```

That's it! The setup automatically:
- Bootstraps `uv` and a managed Python 3.13 runtime when needed
- Installs all dependencies
- Configures VS Code integration
- Sets up Windows service options
- Validates the installation

After installation:
1. **Restart VS Code completely**
2. Run `clippy-widget` to launch the floating widget.
3. Run `clippy-live-tile` to launch the dedicated native adaptive live tile for icon and widget review.
4. Run `clippy_widget_refresh` to relaunch running widget hosts after changes.
5. Run `clippy_widget_restart` to restart the widget service and relaunch widget hosts.
6. Run `clippy` to open a Copilot terminal session that automatically attaches a widget.
7. Start using Windows Clippy tools in agent mode.

**[Complete NPM Installation Guide →](NPM-INSTALL.md)**

---

### Option 2: Traditional Manual Installation

For developers or custom setups:

1. **Clone the repository:**
```shell
git clone https://github.com/dayour/windows-clippy-mcp.git
cd windows-clippy-mcp
```

2. **Install dependencies:**
```shell
cd Windows-Clippy-MCP
python -m uv sync
python -m uv tool install .
python -m uv run main.py
```

3. **Test the server (optional):**
```shell
uv run main.py
# Press Ctrl+C to stop
```

4. **Configure MCP in VS Code:**

Create or update `.vscode/mcp.json` in the root your workspace:
```json
{
  "servers": {
    "windows-clippy-mcp": {
      "type": "stdio",
      "command": "uv",
      "args": [
        "--directory",
        "${workspaceFolder}/windows-clippy-mcp",
        "run",
        "main.py"
      ]
    }
  },
  "inputs": []
}
```

5. **Configure VS Code settings:**

Create or update `.vscode/settings.json` in the root your workspace:
```json
{
  "mcp.servers": {
    "windows-clippy-mcp": {
      "command": "uv",
      "args": [
        "--directory",
        "${workspaceFolder}/windows-clippy-mcp",
        "run",
        "main.py"
      ],
      "env": {}
    }
  }
}
```

6. **Restart VS Code** and start using Windows Clippy MCP tools in agent mode!

### Global Installation (All Workspaces) - Manual Method

**For NPM users:** Use `npm install -g @clippymcp/windows-clippy-mcp` instead for easier global installation.

For global installation using the manual method that works across all VS Code workspaces:

1. **Install globally with UV:**
```shell
# Clone to a global location
git clone https://github.com/dayour/windows-clippy-mcp.git %USERPROFILE%\windows-clippy-mcp
cd %USERPROFILE%\windows-clippy-mcp
uv sync
```

2. **Create global MCP configuration:**

Add to your global VS Code settings (`%APPDATA%\Code\User\settings.json`):
```json
{
  "mcp.servers": {
    "windows-clippy-mcp": {
      "command": "uv",
      "args": [
        "--directory",
        "%USERPROFILE%\\windows-clippy-mcp",
        "run",
        "main.py"
      ],
      "env": {}
    }
  }
}
```

3. **Alternative: Use UV global install:**
```shell
# From the cloned directory
uv tool install --editable .
# Then reference the global tool in MCP config
```

### Troubleshooting

#### MCP Server Not Working
1. **Restart the MCP server:**
   ```shell
   cd windows-clippy-mcp
   uv run main.py
   # Check for errors, then Ctrl+C to stop
   ```

2. **Restart VS Code completely:**
   - Close all VS Code windows
   - Reopen your workspace
   - Wait for MCP connection to establish

3. **Check MCP server status:**
   - Open VS Code Developer Tools (Help → Toggle Developer Tools)
   - Look for MCP connection errors in console

#### Tools Not Responding
- Ensure Windows UI Automation is enabled
- Run VS Code as Administrator if needed
- Check that no other automation tools are conflicting

#### Dependencies Issues
```shell
# Reinstall dependencies
cd windows-clippy-mcp
uv sync --reinstall
```

---

## Clippy Widget and MCP Apps

The package ships a native WPF/WebView2 widget host plus three bundled MCP Apps views that are backed by the same Clippy tool surface used by external hosts.

| View | Resource URI | Backing tool(s) | Status |
|------|--------------|-----------------|--------|
| Fleet Status | `ui://clippy/fleet-status.html` | `clippy.fleet-status` | Proven in the widget host and protocol-class conformance harness |
| Commander | `ui://clippy/commander.html` | `clippy.commander.state`, `clippy.commander.submit` | Proven in the widget host |
| Agent Catalog | `ui://clippy/agent-catalog.html` | `clippy.agent-catalog` | Proven in the widget host |

### Launch a specific bundled view

Use the packaged widget host to boot directly into a specific Clippy view:

```shell
clippy-widget --no-welcome --apps-view ui://clippy/fleet-status.html
clippy-widget --no-welcome --apps-view ui://clippy/commander.html
clippy-widget --no-welcome --apps-view ui://clippy/agent-catalog.html
```

### Rebuild and verify the MCP Apps surfaces

```shell
npm run build:views
npm run mcp-apps:host-conformance
```

The host-conformance command currently proves:

- a generic UI-capable MCP Apps host profile
- a generic headless MCP host profile
- the real in-repo widget host rendering Fleet Status, Commander, and Agent Catalog

For the full proof matrix and the distinction between protocol-class evidence and product-host evidence, see [`docs/mcp-apps/host-conformance.md`](docs/mcp-apps/host-conformance.md).

---

## Other Clients

• **VS Code Agent Mode** – See [`docs/mcp-apps/clients/vscode.md`](docs/mcp-apps/clients/vscode.md).
• **Claude Desktop** – See [`docs/mcp-apps/clients/claude.md`](docs/mcp-apps/clients/claude.md).
• **Goose** – See [`docs/mcp-apps/clients/goose.md`](docs/mcp-apps/clients/goose.md).
• Any HTTP or stdio MCP client can still use the server directly.

---

## Prerequisites

### Core Requirements
• Windows 10/11
• Node.js 16+ for the one-click `npm install` flow
• Python 3.13+ and [UV](https://github.com/astral-sh/uv) `pip install uv` for manual setup, or let `npm install` provision them automatically
• English Windows locale (for consistent UI Automation tree)

### Microsoft 365 & Power Platform Tools (Optional)
For full Microsoft 365 integration functionality, install these PowerShell modules:

```powershell
# Microsoft Graph PowerShell SDK
Install-Module Microsoft.Graph -Scope CurrentUser

# Power Platform CLI
# Download from: https://docs.microsoft.com/en-us/power-platform/developer/cli/introduction

# Microsoft Teams PowerShell
Install-Module MicrosoftTeams -Scope CurrentUser
```

Note: Microsoft 365 tools require appropriate licenses and permissions for your organization.

---

## Limitations

• ~~Fine-grained text selection is pending.~~ **Text-Select-Tool now available!**
• `Type-Tool` types whole blocks; not optimised for coding heavy files.
• Registry-Tool is read-only for safety.  
• Some system operations (shutdown, restart) require confirmation.  
• Microsoft 365 tools require proper licenses, PowerShell modules, and API permissions.
• Some M365 Copilot features may require enterprise licenses and admin configuration.

---

## Contributing

Pull requests and issues welcome! See [CONTRIBUTING](CONTRIBUTING.md).

---

## License

MIT – © 2025 Windows Clippy MCP Contributors
