---
layout: default
title: Home
---

<div align="center">
  <img src="{{ site.baseurl }}/assets/clippy25_256.png" alt="Windows Clippy MCP Logo" width="200" height="200">
  <h1>Windows Clippy MCP</h1>
  <p>Your friendly AI assistant for Windows desktop automation</p>

  <a href="https://github.com/dayour/Darbot-Windows-MCP/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  </a>
  <img src="https://img.shields.io/badge/python-3.13%2B-blue" alt="Python">
  <img src="https://img.shields.io/badge/platform-Windows%2011-blue" alt="Platform: Windows 11">
  <img src="https://img.shields.io/github/last-commit/dayour/Darbot-Windows-MCP" alt="Last Commit">
</div>

---

Windows Clippy MCP is your friendly AI assistant that brings the helpful spirit of the classic Microsoft Office assistant to modern desktop automation. This lightweight, open-source **Model Context Protocol (MCP)** server enables any MCP-aware client (VS Code agent-mode, Claude Desktop, Gemini CLI, custom LLM agents, etc.) to control Windows and interact with Microsoft 365 services, just like a human would.

It exposes **40+ tools** that cover everyday desktop automation -- launching apps, clicking, typing, scrolling, getting UI state, managing windows, controlling volume, taking screenshots, and more -- while hiding all the Windows Accessibility and input-synthesis complexity behind a simple HTTP/stdio interface.

## Key Features

- **Native Windows integration** -- Uses UI Automation, Win32 APIs, and pyautogui for reliable control.
- **Microsoft 365 integration** -- Built-in tools for Graph API, Power Platform, and Copilot Studio.
- **Zero CV / Vision optional** -- Works with *any* LLM; screenshot attachment is optional.
- **Fast** -- Typical end-to-end latency 1.5 - 2.3 s per action.
- **MCP-compliant** -- Validates against the official JSON schema; ready for VS Code, Claude, Gemini CLI.
- **Extensible** -- Add your own Python tools in `main.py`.
- **MIT-licensed** -- Fork, embed, or commercialize freely.

---

## Quick Start

### One-Click NPM Installation (Recommended)

```shell
npm install -g @dayour/windows-clippy-mcp
```

The setup automatically installs all dependencies, configures VS Code integration, sets up Windows service options, and validates the installation.

### Manual Installation

```shell
git clone https://github.com/dayour/windows-clippy-mcp.git
cd windows-clippy-mcp
python -m uv sync
python -m uv tool install .
python -m uv run main.py
```

See the [full installation guide]({{ site.baseurl }}/installation) for detailed instructions.

---

## Available Tools

Windows Clippy MCP provides **40+ tools** across these categories:

| Category | Tools | Description |
|----------|-------|-------------|
| [Core Interaction]({{ site.baseurl }}/tools#core-interaction) | 13 tools | Launch apps, click, type, scroll, drag, shortcuts |
| [Web & Browser]({{ site.baseurl }}/tools#web--browser) | 2 tools | Edge browser control, web scraping |
| [Window Management]({{ site.baseurl }}/tools#window-management) | 3 tools | Minimize, maximize, virtual desktops, taskbar |
| [Screenshot & Visual]({{ site.baseurl }}/tools#screenshot--visual) | 4 tools | Screen capture, snipping, monitor info |
| [System Control]({{ site.baseurl }}/tools#system-control) | 6 tools | Volume, power, action center, emoji picker |
| [Settings & Config]({{ site.baseurl }}/tools#settings--configuration) | 4 tools | Windows Settings, registry, WiFi, Bluetooth |
| [File & Process]({{ site.baseurl }}/tools#file--process) | 5 tools | File ops, process management, system info |
| [Text Editing]({{ site.baseurl }}/tools#text-editing) | 4 tools | Selection, find/replace, undo/redo, zoom |
| [Notifications]({{ site.baseurl }}/tools#notifications) | 1 tool | Windows toast notifications |
| [Microsoft 365]({{ site.baseurl }}/tools#microsoft-365--power-platform) | 6 tools | Graph API, Power Platform, Copilot Studio |

[View all tools]({{ site.baseurl }}/tools)

---

## Prerequisites

- Python 3.13+
- [UV](https://github.com/astral-sh/uv) (`pip install uv`)
- English Windows locale (for consistent UI Automation tree)
- Windows 11 (tested; Windows 10 may work but is not officially supported)

For Microsoft 365 integration, see the [installation guide]({{ site.baseurl }}/installation#microsoft-365-setup).

---

## Contributing

Pull requests and issues welcome! See [CONTRIBUTING](https://github.com/dayour/Darbot-Windows-MCP/blob/main/CONTRIBUTING.md).

## License

MIT - (c) 2025 Windows Clippy MCP Contributors
