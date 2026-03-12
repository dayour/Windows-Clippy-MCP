### 1. Update `manifest.json`
Change the name and description fields.

```json
{
  "name": "Windows Clippy MCP",
  "description": "Your friendly AI assistant for Windows desktop automation and Microsoft 365 integration",
  "version": "0.1.69",
  "icon": "assets/WC25.png",
  "logo": "assets/WC25.png"
}
```

### 2. Update `README.md`
Change all instances of "Windows-MCP" to "Windows Clippy MCP". Here’s an updated excerpt:

```markdown
# Windows Clippy MCP

**Windows Clippy MCP** is your friendly AI assistant that brings the helpful spirit of the classic Microsoft Office assistant to modern desktop automation.

## Updates

- **VS Code Agent Mode Support** - Windows Clippy MCP now fully supports VS Code's native MCP integration
- **Schema Validation Fixed** - Resolved all MCP JSON schema validation errors for seamless tool integration
- **Microsoft 365 Integration** - Added tools for Power Platform, Graph API, and M365 Copilot
- **Rebranded** - Evolved from Windows Clippy MCP to Windows Clippy MCP with expanded capabilities

### Supported Operating Systems

- Windows 7
- Windows 8, 8.1
- Windows 10
- Windows 11

## Getting Started

### VS Code Agent Mode

VS Code now has native MCP support through agent mode. Follow these steps to set up Windows Clippy MCP:

1. **Clone the repository:**
```shell
git clone https://github.com/dayour/windows-clippy-mcp.git
cd windows-clippy-mcp
```

2. **Install dependencies:**
```shell
cd windows-clippy-mcp
uv sync
```

3. **Configure MCP in VS Code:**

Create or update `.vscode/mcp.json` in your workspace:
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

4. **Configure VS Code settings:**

Create or update `.vscode/settings.json`:
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

5. **Restart VS Code** and start using Windows Clippy MCP tools in agent mode!
```

### 3. Update `CHANGELOG.md`
Change all instances of "Windows-MCP" to "Windows Clippy MCP". Here’s an updated excerpt:

```markdown
## [v0.2.0] - 2025-07-22

### Major Improvements

#### **Fixed MCP Schema Validation Issues**
- **Fixed JSON Schema Array Type Validation**: Resolved "tool parameters array type must have items" errors
- **Updated Parameter Types**: Replaced `tuple[int,int]` parameters with separate `x: int, y: int` parameters for better MCP compatibility
- **Fixed List Type Annotations**: Changed `list[str]` to `List[str]` with proper import

#### **Windows Clippy MCP Integration**
- **Added MCP Configuration**: Created `.vscode/mcp.json` with proper server configuration
- **Updated VS Code Settings**: Fixed `.vscode/settings.json` to properly configure windows-clippy-mcp server
- **Full VS Code Agent Mode Support**: All tools now work seamlessly with VS Code's MCP integration
```

### 4. Update `CONTRIBUTING.md`
Change all instances of "Windows-MCP" to "Windows Clippy MCP". Here’s an updated excerpt:

```markdown
# Contributing to Windows Clippy MCP

Thank you for your interest in contributing to Windows Clippy MCP! This document provides guidelines and instructions for contributing to this project.
```

### 5. Update `mcp.json`
Change the server name from "windows-mcp" to "windows-clippy-mcp".

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

### 6. Update `settings.json`
Change the server name from "windows-mcp" to "windows-clippy-mcp".

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

### Summary of Changes
- **Renamed**: All instances of "Windows-MCP" to "Windows Clippy MCP".
- **Updated**: Configuration files and documentation to reflect the new name.
- **Ensured**: Consistency across all files.

After making these changes, ensure to test the application to confirm that everything is functioning correctly under the new name.