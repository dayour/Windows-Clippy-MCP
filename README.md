<!-- Windows Clippy MCP – README -->

<div align="center">

  <img src="assets/WC25.png" alt="Windows Clippy MCP Logo" width="200" height="200">
  
  <h1>📎 Windows Clippy MCP</h1>

  <a href="https://github.com/dayour/windows-clippy-mcp/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  </a>
  <img src="https://img.shields.io/badge/python-3.13%2B-blue" alt="Python">
  <img src="https://img.shields.io/badge/platform-Windows%2011-blue" alt="Platform: Windows 11">
  <img src="https://img.shields.io/github/last-commit/dayour/windows-clippy-mcp" alt="Last Commit">
  <br>


</div>

---

Windows Clippy MCP is your friendly AI assistant that brings the helpful spirit of the classic Microsoft Office assistant to modern desktop automation. This lightweight, open-source **Model Context Protocol (MCP)** server enables any MCP-aware client (VS Code agent-mode, Claude Desktop, Gemini CLI, custom LLM agents, etc.) to control Windows and interact with Microsoft 365 services, just like a human would.

It exposes powerful tools for everyday desktop automation—launching apps, clicking, typing, scrolling, getting UI state, and integrating with Microsoft 365 services—while hiding all the Windows Accessibility and input-synthesis complexity behind a simple HTTP/stdio interface.

**All tools have been validated and are working in VS Code agent mode!** ✅

---

## ✨ Key Features

• **Native Windows integration** – Uses UI Automation, Win32 APIs, and pyautogui for reliable control.  
• **Microsoft 365 integration** – Built-in tools for Graph API, Power Platform, and Copilot Studio.  
• **Zero CV / Vision optional** – Works with *any* LLM; screenshot attachment is optional.  
• **Fast** – Typical end-to-end latency 1.5 – 2.3 s per action.  
• **MCP-compliant** – Validates against the official JSON schema; ready for VS Code, Claude, Gemini CLI.  
• **Extensible** – Add your own Python tools in `main.py`.  
• **MIT-licensed** – Fork, embed, or commercialize freely.

---

## 🖥️ Supported OS

• Windows 11 (tested)  
*Windows 10 may work but is not officially supported.*

---

## 🛠️ Available Tools

### Desktop Automation Tools
| Tool | Purpose |
|------|---------|
| Launch-Tool | Launch an application from the Start menu. |
| Powershell-Tool | Run a PowerShell command and capture output. |
| State-Tool | Dump active app, open apps, interactive / informative / scrollable elements, plus optional screenshot. |
| Clipboard-Tool | Copy text to clipboard or paste current clipboard contents. |
| Click-Tool | Click at `(x, y)` with configurable button/clicks. |
| Type-Tool | Type text into the UI with optional clear. |
| Switch-Tool | Bring a window (e.g., “notepad”) to the foreground. |
| Scroll-Tool | Vertical / horizontal scrolling at coordinates. |
| Drag-Tool | Drag from `(x₁, y₁)` to `(x₂, y₂)`. |
| Move-Tool | Move mouse cursor. |
| Shortcut-Tool | Send keyboard shortcut list (e.g., `["win","r"]`). |
| Key-Tool | Press single key (Enter, Esc, F1–F12, arrows, etc.). |
| Wait-Tool | Sleep for N seconds. |
| Scrape-Tool | Fetch a webpage and return Markdown. |

### Microsoft 365 & Power Platform Tools
| Tool | Purpose |
|------|---------|
| PAC-CLI-Tool | Execute Power Platform CLI commands for app management. |
| Connect-MGGraph-Tool | Authenticate with Microsoft Graph API. |
| Graph-API-Tool | Execute Microsoft Graph API calls for Office 365 data. |
| Copilot-Studio-Tool | Manage and interact with Copilot Studio bots. |
| Power-Automate-Tool | Create and manage Power Automate workflows. |
| M365-Copilot-Tool | Interact with Microsoft 365 Copilot features. |

---

## ⚡ Quick Start (VS Code Agent Mode)

**Choose your preferred installation method:**

### 🚀 Option 1: One-Click NPM Installation (Recommended)

The fastest way to get started:

```shell
npm install -g @dayour/windows-clippy-mcp
```

That's it! The setup automatically:
- ✅ Installs all dependencies
- ✅ Configures VS Code integration  
- ✅ Sets up Windows service options
- ✅ Validates the installation

After installation:
1. **Restart VS Code completely**
2. Start using Windows Clippy tools in agent mode! 🚀

**📖 [Complete NPM Installation Guide →](NPM-INSTALL.md)**

---

### 🛠️ Option 2: Traditional Manual Installation

For developers or custom setups:

1. **Clone the repository:**
```shell
git clone https://github.com/dayour/windows-clippy-mcp.git
cd windows-clippy-mcp
```

2. **Install dependencies:**
```shell
uv sync
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
        "${workspaceFolder}/Windows-Clippy-MCP",
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
        "${workspaceFolder}/Windows-Clippy-MCP",
        "run",
        "main.py"
      ],
      "env": {}
    }
  }
}
```

6. **Restart VS Code** and start using Windows Clippy MCP tools in agent mode! 🚀

### Global Installation (All Workspaces) - Manual Method

⚠️ **For NPM users:** Use `npm install -g @clippymcp/windows-clippy-mcp` instead for easier global installation.

For global installation using the manual method that works across all VS Code workspaces:

1. **Install globally with UV:**
```shell
# Clone to a global location
git clone https://github.com/dayour/Windows-Clippy-MCP.git %USERPROFILE%\windows-clippy-mcp
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
   cd Windows-Clippy-MCP
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
cd Windows-Clippy-MCP
uv sync --reinstall
```

---

## 🗜️ Other Clients

• **Claude Desktop** – Build `.dxt` then load in *Settings → Extensions*.  
• **Gemini CLI** – Add `windows-clippy-mcp` entry in `%USERPROFILE%/.gemini/settings.json`.  
• Any HTTP or stdio MCP client.

---

## 📦 Prerequisites

### Core Requirements
• Python 3.13+  
• [UV](https://github.com/astral-sh/uv) `pip install uv`  
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

## 🚧 Limitations

• Fine-grained text selection is pending.  
• `Type-Tool` types whole blocks; not optimised for coding heavy files.  
• Microsoft 365 tools require proper licenses, PowerShell modules, and API permissions.  
• Some M365 Copilot features may require enterprise licenses and admin configuration.

---

## 🤝 Contributing

Pull requests and issues welcome! See [CONTRIBUTING](CONTRIBUTING.md).

---

## 🪪 License

MIT – © 2025 Windows Clippy MCP Contributors
