<!-- Darbot Windows MCP – README -->

<div align="center">

  <h1>🪟 Darbot Windows MCP</h1>

  <a href="https://github.com/dayour/Darbot-Windows-MCP/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  </a>
  <img src="https://img.shields.io/badge/python-3.13%2B-blue" alt="Python">
  <img src="https://img.shields.io/badge/platform-Windows%2011-blue" alt="Platform: Windows 11">
  <img src="https://img.shields.io/github/last-commit/dayour/Darbot-Windows-MCP" alt="Last Commit">
  <br>


</div>

---

Darbot Windows MCP is a lightweight, open-source **Model Context Protocol (MCP)** server that lets any MCP-aware client (VS Code agent-mode, Claude Desktop, Gemini CLI, custom LLM agents, etc.) control Windows just like a human.


It exposes 14 tools that cover everyday desktop automation—launching apps, clicking, typing, scrolling, getting UI state, and more—while hiding all the Windows Accessibility and input-synthesis complexity behind a simple HTTP/stdio interface.

---

## ✨ Key Features

• **Native Windows integration** – Uses UI Automation, Win32 APIs, and pyautogui for reliable control.  
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

---

## ⚡ Quick Start (VS Code Agent Mode)


1. **Clone the repository:**
```shell
git clone https://github.com/dayour/Darbot-Windows-MCP.git
cd Darbot-Windows-MCP
```

2. **Install dependencies:**
```shell
cd Darbot-Windows-MCP
uv sync
```

3. **Configure MCP in VS Code:**

Create or update `.vscode/mcp.json` in the root your workspace:
```json
{
  "servers": {
    "darbot-windows-mcp": {
      "type": "stdio",
      "command": "uv",
      "args": [
        "--directory",
        "${workspaceFolder}/Darbot-Windows-MCP",
        "run",
        "main.py"
      ]
    }
  },
  "inputs": []
}
```

4. **Configure VS Code settings:**

Create or update `.vscode/settings.json` in the root your workspace:
```json
{
  "mcp.servers": {
    "darbot-windows-mcp": {
      "command": "uv",
      "args": [
        "--directory",
        "${workspaceFolder}/Darbot-Windows-MCP",
        "run",
        "main.py"
      ],
      "env": {}
    }
  }
}
```

5. **Restart VS Code** and start using Darbot Windows MCP tools in agent mode! 🚀
```


```markdown

`
---

## 🗜️ Other Clients

• **Claude Desktop** – Build `.dxt` then load in *Settings → Extensions*.  
• **Gemini CLI** – Add `darbot-windows-mcp` entry in `%USERPROFILE%/.gemini/settings.json`.  
• Any HTTP or stdio MCP client.

---

## 📦 Prerequisites

• Python 3.13+  
• [UV](https://github.com/astral-sh/uv) `pip install uv`  
• English Windows locale (for consistent UI Automation tree)

---

## 🚧 Limitations

• Fine-grained text selection is pending.  
• `Type-Tool` types whole blocks; not optimised for coding heavy files.

---

## 🤝 Contributing

Pull requests and issues welcome! See [CONTRIBUTING](CONTRIBUTING.md).

---

## 🪪 License

MIT – © 2025 Darbot at Darbot Labs / contributors
