# Windows Clippy MCP

Windows Clippy MCP is a Python-based Model Context Protocol (MCP) server that provides Windows desktop automation and Microsoft 365 integration tools. It enables AI agents to control Windows desktop applications, interact with Office 365 services, and automate common desktop tasks.

**ALWAYS reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.**

## Working Effectively

### Prerequisites & Platform Requirements
- **CRITICAL**: This application ONLY works on Windows 11 (Windows 10 may work but is unsupported)
- **DO NOT attempt to run on Linux or macOS** - it will fail with .NET runtime errors
- Python 3.13+ required (automatically installed by UV)
- UV package manager required: `pip install uv`
- English Windows locale recommended for consistent UI Automation

### Initial Setup & Dependencies
Run these commands in sequence to set up the development environment:

```bash
# Install UV package manager (if not already installed)
pip install uv

# Clone and navigate to repository
git clone https://github.com/dayour/Windows-Clippy-MCP.git
cd Windows-Clippy-MCP

# Install dependencies and Python 3.13
uv sync
```

**TIMING EXPECTATIONS:**
- `uv sync` (first time): **3-5 minutes** - Downloads Python 3.13.7 and 81 packages. **NEVER CANCEL** - Set timeout to 10+ minutes
- `uv sync` (subsequent): **<1 second** - Uses cached dependencies
- Dependency reinstall: **<1 second** - Fast when cached

### Build & Validation Process
**ALWAYS run these validation steps before making changes:**

```bash
# Validate Python syntax (fast: ~0.06 seconds)
uv run python -m py_compile main.py
uv run python -m py_compile src/desktop/views.py

# Validate JSON configuration
uv run python -c "import json; print('manifest.json:', json.load(open('manifest.json')))"

# Test basic MCP server creation (non-Windows parts only)
uv run python -c "from fastmcp import FastMCP; print('MCP server creation: OK')"
```

**CRITICAL LIMITATION:** 
- **DO NOT run `uv run main.py` on Linux/macOS** - it will fail with .NET runtime errors
- On Windows: Use `uv run main.py` to start the MCP server
- Use Ctrl+C to stop the server

### VS Code MCP Integration (Windows Only)
To configure this MCP server with VS Code agent mode:

1. **Create `.vscode/mcp.json` in your workspace:**
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

2. **Create/update `.vscode/settings.json`:**
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

3. **Restart VS Code completely** for MCP integration to take effect

## Testing & Validation

### Syntax and Import Validation
**ALWAYS run before committing changes:**

```bash
# Test all Python files compile
uv run python -m py_compile main.py
uv run python -m py_compile src/desktop/views.py

# Test core imports (safe on all platforms)
uv run python -c "
from fastmcp import FastMCP
from fastmcp.utilities.types import Image
import pyperclip, requests
from markdownify import markdownify
print('All core imports: OK')
"

# Validate JSON files
uv run python -c "import json; json.load(open('manifest.json'))"
```

### Windows-Specific Validation (Windows Only)
**On Windows systems, ALSO run:**

```bash
# Test full MCP server startup (Windows only)
timeout 10 uv run main.py
# Should start without errors and report 21 available tools

# Test Windows-specific imports
uv run python -c "
import uiautomation as ua
import pyautogui as pg
from live_inspect.watch_cursor import WatchCursor
print('Windows-specific imports: OK')
"
```

### Manual Validation Requirements
After making changes to tools or core functionality:

1. **On Windows:** Test at least one complete automation scenario:
   - Launch an application using Launch-Tool
   - Get desktop state using State-Tool
   - Perform a click/type operation
   - Verify the action completed successfully

2. **Tool Addition Validation:**
   - Confirm new tool appears in tool count
   - Test tool with various parameter combinations
   - Verify error handling for invalid inputs

## Common Development Tasks

### Adding New Tools
Follow the pattern in `main.py`:

```python
@mcp.tool(name='NewTool-Name', description='Clear description of functionality')
def new_tool(param1: str, param2: int = 0) -> str:
    try:
        # Implementation using desktop object or pyautogui
        return f'Success: {result_description}'
    except Exception as e:
        return f'Error: {str(e)}'
```

**ALWAYS:**
- Update the tool count in README.md
- Test the tool on Windows before committing
- Use consistent naming: `<Function>-Tool`

### File Structure Understanding
```
Windows-Clippy-MCP/
├── main.py                    # Main MCP server with all 21 tools
├── src/desktop/views.py       # Desktop automation classes
├── pyproject.toml            # Dependencies and project config
├── manifest.json             # MCP server metadata
├── README.md                 # User documentation
├── CONTRIBUTING.md           # Contribution guidelines  
├── AddToolProcess.md         # Tool development guide
└── assets/                   # Demo videos and screenshots
```

### Key Dependencies & Import Structure
- `fastmcp`: MCP server framework
- `uiautomation`: Windows UI Automation (Windows only)
- `pyautogui`: Cross-platform GUI automation
- `pyperclip`: Clipboard operations
- `requests`: HTTP requests for web scraping
- `markdownify`: HTML to Markdown conversion
- `psutil`: System process management

## Troubleshooting

### Common Issues
1. **"Could not find libmono" error:**
   - This is expected on Linux/macOS
   - Application is Windows-only
   - Use syntax validation commands instead

2. **UV sync fails:**
   - Check internet connection
   - May need corporate proxy configuration
   - Try `uv sync --reinstall`

3. **MCP tools not appearing in VS Code:**
   - Restart VS Code completely
   - Check `.vscode/mcp.json` and `.vscode/settings.json` syntax
   - Verify file paths in configuration

4. **Import errors in main.py:**
   - Run `uv sync` to ensure all dependencies installed
   - Check Python version: should be 3.13+

### Development Workflow
1. **Before making changes:** Run syntax validation
2. **After making changes:** 
   - Run syntax validation again
   - Test on Windows if available
   - Update documentation as needed
3. **Before committing:** Verify all validation steps pass

## Available Tools (21 Total)

### Desktop Automation Tools (15)
- Launch-Tool: Launch applications from Start menu
- Powershell-Tool: Execute PowerShell commands
- State-Tool: Get desktop state and UI elements
- Clipboard-Tool: Copy/paste clipboard operations
- Click-Tool: Click at coordinates with various buttons
- Type-Tool: Type text into focused elements
- Switch-Tool: Switch between application windows
- Scroll-Tool: Scroll in specified directions
- Drag-Tool: Drag and drop operations
- Move-Tool: Move mouse cursor
- Shortcut-Tool: Execute keyboard shortcuts
- Key-Tool: Press individual keys
- Wait-Tool: Add delays between actions
- Scrape-Tool: Fetch and convert web content
- Browser-Tool: Launch Edge browser with optional URL

### Microsoft 365 & Power Platform Tools (6)
- PAC-CLI-Tool: Power Platform CLI operations
- Connect-MGGraph-Tool: Microsoft Graph authentication
- Graph-API-Tool: Execute Graph API calls
- Copilot-Studio-Tool: Manage Copilot Studio bots
- Power-Automate-Tool: Create and manage Power Automate flows
- M365-Copilot-Tool: Interact with Microsoft 365 Copilot

### Performance Expectations
- Tool execution latency: 1.5-2.3 seconds typical
- MCP server startup: <3 seconds on Windows
- Dependency sync: 3-5 minutes first time, <1 second cached
- Syntax validation: <0.1 seconds per file

**CRITICAL REMINDERS:**
- **NEVER run the full application on Linux/macOS** - use syntax validation only
- **ALWAYS set 10+ minute timeouts** for `uv sync` operations
- **Test actual functionality on Windows** after making tool changes
- **Validate syntax before committing** to catch errors early