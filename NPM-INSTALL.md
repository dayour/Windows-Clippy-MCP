# NPM Installation Guide

<div align="center">
  <img src="assets/WC25.png" alt="Windows Clippy MCP Logo" width="150" height="150">
</div>

Windows Clippy MCP now supports **one-click NPM installation** alongside the traditional manual setup. Choose the method that works best for you!

## One-Click NPM Installation (Recommended)

The easiest way to get started with Windows Clippy MCP:

### Prerequisites
- Windows 10/11
- Node.js 25.7.0+ and npm 11.7.0+ (install from [nodejs.org](https://nodejs.org))
- PowerShell 7+ for Clippy Cursor and validation scripts
- .NET desktop runtime/SDK matching the packaged native hosts for native widget/live-tile launch; Clippy Cursor uses the PowerShell standalone path
- Internet access for the first install (the setup bootstraps `uv` and Python 3.13 automatically if needed)

### Install & Setup
```bash
npm install -g @dayour/windows-clippy-mcp
```

That's it! The NPM package will automatically:
- Bootstrap `uv` and a managed Python 3.13 runtime when they are missing
- Install Python dependencies via UV
- Create VS Code MCP configuration files
- Set up Windows service scripts
- Validate the installation

### Usage
After installation:

```bash
# Launch the floating Clippy widget
clippy-widget

# Launch Clippy Cursor Mode and right-click anywhere for Clippy Click context
clippy-cursor

# Refresh running widget hosts after changes
clippy_widget_refresh

# Restart the widget service and relaunch widget hosts
clippy_widget_restart

# Start a Copilot terminal session and attach a widget automatically
clippy

# Start the MCP server manually from a repo checkout
npm run start:mcp

# Launch Clippy Cursor from a repo checkout
npm run start:cursor

# Run Clippy Cursor in the foreground for diagnostics
npm run start:cursor:debug

# Install as Windows service (requires admin privileges)
npm run install-service

# Remove Windows service
npm run uninstall-service
```

### VS Code Integration
The setup automatically configures VS Code. Just:
1. **Restart VS Code completely**
2. Open agent mode
3. Start using Windows Clippy tools!

---

## Clippy Cursor after NPM install

The NPM package exposes `clippy-cursor` as a first-class command. It starts `widget\clippy-cursor.ps1` in standalone mode and keeps capture artifacts local under `%APPDATA%\Windows-Clippy-MCP\captures`.

Default behavior:

- **Right-click anywhere** opens the Clippy Click AI context menu.
- **Ctrl+Right-click safe mode** is available from the widget Cursor Mode menu.
- **Ctrl+Shift+E/S/T** trigger Explain This, Summarize Screen, and Extract Text.
- Each action emits screenshot PNG, screen-context JSON, screen-context Markdown, and Paperboy bundle artifacts.

If you launch the full widget with `clippy-widget`, right-click the widget and use **Cursor Mode → Activate Clippy Cursor**. That path installs the same mouse and keyboard hooks as the standalone launcher.

Troubleshooting:

```bash
# Foreground diagnostics
clippy-cursor --debug

# Validate the Darbit semanifest and Clippy Click packaging gates
npm run darbit:validate
```

If the cursor is active but you want Windows defaults back, use **Restore Default Cursor** from the Clippy Click context menu or the widget Cursor Mode menu.

---

## Traditional Manual Installation

For developers who want full control or to contribute to the project:

### Prerequisites
- Windows 10/11
- Python 3.13+
- [UV package manager](https://github.com/astral-sh/uv): `pip install uv`

### Steps
1. **Clone the repository:**
   ```bash
   git clone https://github.com/dayour/windows-clippy-mcp.git
   cd windows-clippy-mcp
   ```

2. **Install dependencies:**
   ```bash
   uv sync
   ```

3. **Test the server:**
   ```bash
   uv run main.py
   # Press Ctrl+C to stop
   ```

4. **Configure VS Code manually:**

   Create `.vscode/mcp.json` in your workspace:
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

   Create/update `.vscode/settings.json`:
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

5. **Restart VS Code** and enjoy!

---

## Comparison: NPM vs Manual

| Feature | NPM Installation | Manual Installation |
|---------|------------------|-------------------|
| **Setup Time** | ~2 minutes | ~5-10 minutes |
| **Automation** | Fully automated | Manual config needed |
| **Updates** | `npm update -g` | `git pull && uv sync` |
| **Service Setup** | One command | Manual service creation |
| **VS Code Config** | Automatic | Manual file creation |
| **Best For** | End users, quick setup | Developers, customization |

---

## Available Tools (49 Total)

Both installation methods provide access to all **49 tools** in Windows Clippy MCP:

### Desktop Automation (42 tools)
- Core Interaction (13): Launch-Tool, Powershell-Tool, State-Tool, Clipboard-Tool, Click-Tool, Type-Tool, Switch-Tool, Scroll-Tool, Drag-Tool, Move-Tool, Shortcut-Tool, Key-Tool, Wait-Tool
- Web & Browser (2): Browser-Tool, Scrape-Tool
- Window Management (3): Window-Tool, TaskView-Tool, Taskbar-Tool
- Screenshot & Visual (4): Screenshot-Tool, Snip-Tool, Screen-Info-Tool, Cursor-Position-Tool
- System Control (6): Volume-Tool, Lock-Tool, ActionCenter-Tool, Emoji-Tool, Clipboard-History-Tool, Run-Dialog-Tool
- Settings & Configuration (4): Settings-Tool, Registry-Tool, Wifi-Tool, Bluetooth-Tool
- File & Process (5): File-Tool, FileExplorer-Tool, Process-Tool, SystemInfo-Tool, Search-Tool
- Text Editing (4): Text-Select-Tool, Find-Replace-Tool, Undo-Redo-Tool, Zoom-Tool
- Notification (1): Notification-Tool

### M365 / Power Platform (7 tools)
- PAC-CLI-Tool, Connect-MGGraph-Tool, Graph-API-Tool
- Copilot-Studio-Tool, Agent-Studio-Tool, Power-Automate-Tool, M365-Copilot-Tool

---

## Troubleshooting

### NPM Installation Issues
```bash
# Check Node.js version
node --version  # Should be 25.7.0+
npm --version   # Should be 11.7.0+

# Check if package installed correctly
npm list -g @dayour/windows-clippy-mcp

# Reinstall if needed
npm uninstall -g @dayour/windows-clippy-mcp
npm install -g @dayour/windows-clippy-mcp
```

### VS Code Not Connecting
1. **Restart VS Code completely** (close all windows)
2. Check MCP configuration in VS Code settings
3. Verify the MCP server starts: `npm run start:mcp`
4. Check VS Code Developer Tools (Help → Toggle Developer Tools) for errors

### Windows Service Issues
```bash
# Check service status
sc query windowsclippymcp

# Restart service
sc stop windowsclippymcp
sc start windowsclippymcp

# Reinstall service (as admin)
npm run uninstall-service
npm run install-service
```

---

## Documentation

- **Full Documentation**: [README.md](README.md)
- **Contributing**: [CONTRIBUTING.md](CONTRIBUTING.md)
- **Add Tools**: [AddToolProcess.md](AddToolProcess.md)
- **GitHub**: [dayour/windows-clippy-mcp](https://github.com/dayour/windows-clippy-mcp)

---

## Support

- **Issues**: [GitHub Issues](https://github.com/dayour/windows-clippy-mcp/issues)
- **Discussions**: [GitHub Discussions](https://github.com/dayour/windows-clippy-mcp/discussions)

---

**Welcome to Windows Clippy MCP! Your friendly AI assistant for Windows automation is ready to help.**
