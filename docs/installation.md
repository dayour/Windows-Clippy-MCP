---
layout: default
title: Installation Guide
---

# Installation Guide

## One-Click NPM Installation (Recommended)

The fastest way to get started:

```shell
npm install -g @dayour/windows-clippy-mcp
```

The setup automatically:
- Bootstraps `uv` and Python 3.13 if they are not already available
- Installs all dependencies
- Configures VS Code integration
- Sets up Windows service options
- Validates the installation

After installation:
1. **Restart VS Code completely**
2. Run `clippy-widget` to launch the floating widget.
3. Run `clippy_widget_refresh` to relaunch running widget hosts after updates.
4. Run `clippy_widget_restart` to restart the widget service and relaunch widget hosts.
5. Run `clippy` to open a Copilot terminal session that automatically attaches a widget.
6. Start using Windows Clippy tools in agent mode.

---

## Manual Installation

For developers or custom setups:

### 1. Clone the repository

```shell
git clone https://github.com/dayour/windows-clippy-mcp.git
cd windows-clippy-mcp
```

### 2. Install dependencies

```shell
python -m uv sync
python -m uv tool install .
python -m uv run main.py
```

### 3. Test the server (optional)

```shell
uv run main.py
# Press Ctrl+C to stop
```

### 4. Configure MCP in VS Code

Create or update `.vscode/mcp.json` in the root of your workspace:

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

### 5. Configure VS Code settings

Create or update `.vscode/settings.json` in the root of your workspace:

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

### 6. Restart VS Code

Restart VS Code and start using Windows Clippy MCP tools in agent mode!

---

## Global Installation (All Workspaces)

### Via NPM (Easiest)

```shell
npm install -g @dayour/windows-clippy-mcp
```

### Via UV (Manual)

```shell
git clone https://github.com/dayour/windows-clippy-mcp.git %USERPROFILE%\windows-clippy-mcp
cd %USERPROFILE%\windows-clippy-mcp
uv sync
```

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

---

## Other Clients

- **Claude Desktop** -- Build `.dxt` then load in *Settings > Extensions*.
- **Gemini CLI** -- Add `windows-clippy-mcp` entry in `%USERPROFILE%/.gemini/settings.json`.
- Any HTTP or stdio MCP client.

---

## Microsoft 365 Setup

For full Microsoft 365 integration, install these PowerShell modules:

```powershell
# Microsoft Graph PowerShell SDK
Install-Module Microsoft.Graph -Scope CurrentUser

# Microsoft Teams PowerShell
Install-Module MicrosoftTeams -Scope CurrentUser
```

For Power Platform CLI, download from the [official docs](https://docs.microsoft.com/en-us/power-platform/developer/cli/introduction).

Note: Microsoft 365 tools require appropriate licenses and permissions for your organization.

---

## Troubleshooting

### MCP Server Not Working

1. **Restart the MCP server:**
   ```shell
   cd windows-clippy-mcp
   uv run main.py
   # Check for errors, then Ctrl+C to stop
   ```

2. **Restart VS Code completely** -- close all windows, reopen your workspace, and wait for the MCP connection to establish.

3. **Check MCP server status** -- open VS Code Developer Tools (Help > Toggle Developer Tools) and look for MCP connection errors in the console.

### Tools Not Responding

- Ensure Windows UI Automation is enabled
- Run VS Code as Administrator if needed
- Check that no other automation tools are conflicting

### Dependency Issues

```shell
cd windows-clippy-mcp
uv sync --reinstall
```

## Prerequisites

- Windows 11 (tested; Windows 10 may work but is not officially supported)
- Node.js 16+ for the one-click `npm install` flow
- Python 3.13+ and [UV](https://github.com/astral-sh/uv) (`pip install uv`) for manual setup, or let the npm setup bootstrap them automatically
- English Windows locale (for consistent UI Automation tree)
