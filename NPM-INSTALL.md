# NPM Installation Guide

<div align="center">
  <img src="assets/WC25.png" alt="Windows Clippy MCP Logo" width="150" height="150">
</div>

Windows Clippy MCP now supports **one-click NPM installation** alongside the traditional manual setup. Choose the method that works best for you!

## 🚀 One-Click NPM Installation (Recommended)

The easiest way to get started with Windows Clippy MCP:

### Prerequisites
- Windows 10/11
- Node.js 16+ (install from [nodejs.org](https://nodejs.org))
- Python 3.13+ (will be auto-detected and guided if missing)

### Install & Setup
```bash
npm install -g @dayour/windows-clippy-mcp
```

That's it! The NPM package will automatically:
- ✅ Install Python dependencies via UV
- ✅ Create VS Code MCP configuration files
- ✅ Set up Windows service scripts
- ✅ Validate the installation

### Usage
After installation:

```bash
# Start the MCP server manually
npm start

# Install as Windows service (requires admin privileges)
npm run install-service

# Remove Windows service
npm run uninstall-service
```

### VS Code Integration
The setup automatically configures VS Code. Just:
1. **Restart VS Code completely**
2. Open agent mode
3. Start using Windows Clippy tools! 🎉

---

## 🛠️ Traditional Manual Installation

For developers who want full control or to contribute to the project:

### Prerequisites
- Windows 10/11
- Python 3.13+
- [UV package manager](https://github.com/astral-sh/uv): `pip install uv`

### Steps
1. **Clone the repository:**
   ```bash
   git clone https://github.com/dayour/Windows-Clippy-MCP.git
   cd Windows-Clippy-MCP
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
           "${workspaceFolder}/Windows-Clippy-MCP",
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
           "${workspaceFolder}/Windows-Clippy-MCP",
           "run",
           "main.py"
         ],
         "env": {}
       }
     }
   }
   ```

5. **Restart VS Code** and enjoy! 🚀

---

## 🔄 Comparison: NPM vs Manual

| Feature | NPM Installation | Manual Installation |
|---------|------------------|-------------------|
| **Setup Time** | ~2 minutes | ~5-10 minutes |
| **Automation** | Fully automated | Manual config needed |
| **Updates** | `npm update -g` | `git pull && uv sync` |
| **Service Setup** | One command | Manual service creation |
| **VS Code Config** | Automatic | Manual file creation |
| **Best For** | End users, quick setup | Developers, customization |

---

## 📋 Available Tools (21 Total)

Both installation methods provide access to all Windows Clippy MCP tools:

### Desktop Automation (15 tools)
- Launch-Tool, Click-Tool, Type-Tool, State-Tool
- Clipboard-Tool, Switch-Tool, Scroll-Tool, Drag-Tool
- Move-Tool, Shortcut-Tool, Key-Tool, Wait-Tool
- Powershell-Tool, Scrape-Tool, Browser-Tool

### Microsoft 365 & Power Platform (6 tools)
- PAC-CLI-Tool, Connect-MGGraph-Tool, Graph-API-Tool
- Copilot-Studio-Tool, Power-Automate-Tool, M365-Copilot-Tool

---

## 🐛 Troubleshooting

### NPM Installation Issues
```bash
# Check Node.js version
node --version  # Should be 16+

# Check if package installed correctly
npm list -g @clippymcp/windows-clippy-mcp

# Reinstall if needed
npm uninstall -g @clippymcp/windows-clippy-mcp
npm install -g @clippymcp/windows-clippy-mcp
```

### VS Code Not Connecting
1. **Restart VS Code completely** (close all windows)
2. Check MCP configuration in VS Code settings
3. Verify the MCP server starts: `npm start`
4. Check VS Code Developer Tools (Help → Toggle Developer Tools) for errors

### Windows Service Issues
```bash
# Check service status
sc query WindowsClippyMCP

# Restart service
sc stop WindowsClippyMCP
sc start WindowsClippyMCP

# Reinstall service (as admin)
npm run uninstall-service
npm run install-service
```

---

## 📚 Documentation

- **Full Documentation**: [README.md](README.md)
- **Contributing**: [CONTRIBUTING.md](CONTRIBUTING.md)
- **Add Tools**: [AddToolProcess.md](AddToolProcess.md)
- **GitHub**: [dayour/Windows-Clippy-MCP](https://github.com/dayour/Windows-Clippy-MCP)

---

## 🤝 Support

- **Issues**: [GitHub Issues](https://github.com/dayour/Windows-Clippy-MCP/issues)
- **Discussions**: [GitHub Discussions](https://github.com/dayour/Windows-Clippy-MCP/discussions)

---

**🎉 Welcome to Windows Clippy MCP! Your friendly AI assistant for Windows automation is ready to help.**