try:
    from live_inspect.watch_cursor import WatchCursor
    _has_watch_cursor = True
except ImportError:
    _has_watch_cursor = False
from contextlib import asynccontextmanager
from fastmcp.utilities.types import Image
from humancursor import SystemCursor
from platform import system, release
from markdownify import markdownify
from src.desktop import Desktop
from textwrap import dedent
from fastmcp import FastMCP
from typing import Literal, List, Optional
import uiautomation as ua
import pyautogui as pg
import pyperclip as pc
import subprocess
import requests
import asyncio
import ctypes
import psutil
import winreg
import shutil
import json
import os as os_module
import re

pg.FAILSAFE=False
pg.PAUSE=1.0

os_name=system()
version=release()

instructions=dedent(f'''
Windows Clippy MCP - Your friendly AI assistant for Windows desktop automation!

This MCP server provides tools to interact directly with the {os_name} {version} desktop,
thus enabling to operate the desktop on the user's behalf. Like the classic Office
assistant, Windows Clippy MCP is here to help with all your desktop automation needs.

Visual Identity: Look for the Windows Clippy MCP logo (WC25.png) in the assets folder.
''')

desktop=Desktop()
cursor=SystemCursor()
watch_cursor=WatchCursor() if _has_watch_cursor else None
ctypes.windll.user32.SetProcessDPIAware()

@asynccontextmanager
async def lifespan(app: FastMCP):
    """Runs initialization code before the server starts and cleanup code after it shuts down."""
    try:
        if watch_cursor:
            watch_cursor.start()
        await asyncio.sleep(1)
        yield
        if watch_cursor:
            watch_cursor.stop()
    except Exception:
        if watch_cursor:
            watch_cursor.stop()

mcp=FastMCP(name='windows-clippy-mcp',instructions=instructions,lifespan=lifespan)

@mcp.tool(name='Launch-Tool', description='Launch an application from the Windows Start Menu by name (e.g., "notepad", "calculator", "chrome")')
def launch_tool(name: str) -> str:
    _,status=desktop.launch_app(name)
    if status!=0:
        return f'Failed to launch {name.title()}.'
    else:
        return f'Launched {name.title()}.'

@mcp.tool(name='Powershell-Tool', description='Execute PowerShell commands and return the output with status code')
def powershell_tool(command: str) -> str:
    response,status=desktop.execute_command(command)
    return f'Status Code: {status}\nResponse: {response}'

@mcp.tool(name='State-Tool',description='Capture comprehensive desktop state including focused/opened applications, interactive UI elements (buttons, text fields, menus), informative content (text, labels, status), and scrollable areas. Optionally includes visual screenshot when use_vision=True. Essential for understanding current desktop context and available UI interactions.')
def state_tool(use_vision:bool=False)->str:
    desktop_state=desktop.get_state(use_vision=use_vision)
    interactive_elements=desktop_state.tree_state.interactive_elements_to_string()
    informative_elements=desktop_state.tree_state.informative_elements_to_string()
    scrollable_elements=desktop_state.tree_state.scrollable_elements_to_string()
    apps=desktop_state.apps_to_string()
    active_app=desktop_state.active_app_to_string()

    state_text = dedent(f'''
    Focused App:
    {active_app}

    Opened Apps:
    {apps}

    List of Interactive Elements:
    {interactive_elements or 'No interactive elements found.'}

    List of Informative Elements:
    {informative_elements or 'No informative elements found.'}

    List of Scrollable Elements:
    {scrollable_elements or 'No scrollable elements found.'}
    ''').strip()

    # Note: Image support would need to be handled differently in MCP
    # For now, just return the text state
    if use_vision:
        state_text += "\n\n[Screenshot capture requested but not supported in current MCP implementation]"

    return state_text

@mcp.tool(name='Clipboard-Tool',description='Copy text to clipboard or retrieve current clipboard content. Use "copy" mode with text parameter to copy, "paste" mode to retrieve.')
def clipboard_tool(mode: Literal['copy', 'paste'], text: str = None)->str:
    if mode == 'copy':
        if text:
            pc.copy(text)  # Copy text to system clipboard
            return f'Copied "{text}" to clipboard'
        else:
            raise ValueError("No text provided to copy")
    elif mode == 'paste':
        clipboard_content = pc.paste()  # Get text from system clipboard
        return f'Clipboard Content: "{clipboard_content}"'
    else:
        raise ValueError('Invalid mode. Use "copy" or "paste".')

@mcp.tool(name='Click-Tool',description='Click on UI elements at specific coordinates. Supports left/right/middle mouse buttons and single/double/triple clicks. Use coordinates from State-Tool output.')
def click_tool(x: int, y: int, button:Literal['left','right','middle']='left',clicks:int=1)->str:
    pg.click(x=x, y=y, button=button, clicks=clicks)
    control=desktop.get_element_under_cursor()
    num_clicks={1:'Single',2:'Double',3:'Triple'}
    return f'{num_clicks.get(clicks)} {button} Clicked on {control.Name} Element with ControlType {control.ControlTypeName} at ({x},{y}).'

@mcp.tool(name='Type-Tool',description='Type text into input fields, text areas, or focused elements. Set clear=True to replace existing text, False to append. Click on target element coordinates first.')
def type_tool(x: int, y: int, text:str,clear:bool=False) -> str:
    pg.click(x=x, y=y)
    control=desktop.get_element_under_cursor()
    if clear:  # Fixed: compare boolean directly instead of string
        pg.hotkey('ctrl','a')
        pg.press('backspace')
    pg.typewrite(text,interval=0.1)
    return f'Typed "{text}" on {control.Name} Element with ControlType {control.ControlTypeName} at ({x},{y}).'

@mcp.tool(name='Switch-Tool',description='Switch to a specific application window (e.g., "notepad", "calculator", "chrome", etc.) and bring to foreground.')
def switch_tool(name: str) -> str:
    _,status=desktop.switch_app(name)
    if status!=0:
        return f'Failed to switch to {name.title()} window.'
    else:
        return f'Switched to {name.title()} window.'

@mcp.tool(name='Scroll-Tool',description='Scroll at specific coordinates or current mouse position. Use wheel_times to control scroll amount (1 wheel = ~3-5 lines). Essential for navigating lists, web pages, and long content.')
def scroll_tool(x: int = None, y: int = None, direction:Literal['up','down','left','right']='down',wheel_times:int=3)->str:
    if x is not None and y is not None:
        pg.moveTo(x, y)

    match direction:
        case 'up':
            ua.WheelUp(wheel_times)
        case 'down':
            ua.WheelDown(wheel_times)
        case 'left':
            pg.keyDown('shift')
            pg.sleep(0.05)
            ua.WheelUp(wheel_times)
            pg.sleep(0.05)
            pg.keyUp('shift')
        case 'right':
            pg.keyDown('shift')
            pg.sleep(0.05)
            ua.WheelDown(wheel_times)
            pg.sleep(0.05)
            pg.keyUp('shift')
        case _:
            return f'Invalid direction "{direction}". Use: up, down, left, right.'

    return f'Scrolled {direction} by {wheel_times} wheel times.'

@mcp.tool(name='Drag-Tool', description='Drag and drop operation from source coordinates to destination coordinates. Useful for moving files, resizing windows, or drag-and-drop interactions.')
def drag_tool(from_x: int, from_y: int, to_x: int, to_y: int) -> str:
    # Move to start position, press mouse down, drag to end, release
    pg.moveTo(from_x, from_y)
    pg.mouseDown()
    pg.moveTo(to_x, to_y, duration=0.5)
    pg.mouseUp()
    return f'Dragged element from ({from_x},{from_y}) to ({to_x},{to_y}).'

@mcp.tool(name='Move-Tool', description='Move mouse cursor to specific coordinates without clicking. Useful for hovering over elements or positioning cursor before other actions.')
def move_tool(x: int, y: int) -> str:
    pg.moveTo(x, y)
    return f'Moved the mouse pointer to ({x},{y}).'

@mcp.tool(name='Shortcut-Tool',description='Execute keyboard shortcuts using key combinations. Pass keys as list (e.g., ["ctrl", "c"] for copy, ["alt", "tab"] for app switching, ["win", "r"] for Run dialog).')
def shortcut_tool(shortcut: List[str]):
    pg.hotkey(*shortcut)
    return f'Pressed {'+'.join(shortcut)}.'

@mcp.tool(name='Key-Tool',description='Press individual keyboard keys. Supports special keys like "enter", "escape", "tab", "space", "backspace", "delete", arrow keys ("up", "down", "left", "right"), function keys ("f1"-"f12").')
def key_tool(key:str='')->str:
    pg.press(key)
    return f'Pressed the key {key}.'

@mcp.tool(name='Wait-Tool',description='Pause execution for specified duration in seconds. Useful for waiting for applications to load, animations to complete, or adding delays between actions.')
def wait_tool(duration:int)->str:
    pg.sleep(duration)
    return f'Waited for {duration} seconds.'

@mcp.tool(name='Scrape-Tool',description='Fetch and convert webpage content to markdown format. Provide full URL including protocol (http/https). Returns structured text content suitable for analysis.')
def scrape_tool(url:str)->str:
    response=requests.get(url,timeout=10)
    html=response.text
    content=markdownify(html=html)
    return f'Scraped the contents of the entire webpage:\n{content}'

@mcp.tool(name='Browser-Tool',description='Launch Microsoft Edge browser and navigate to a specified URL. If no URL is provided, opens Edge to the default home page.')
def browser_tool(url: str = None) -> str:
    try:
        # Launch Edge
        launch_result, status = desktop.launch_app("msedge")
        if status != 0:
            return f'Failed to launch Microsoft Edge.'

        # Wait for Edge to load
        pg.sleep(2)

        if url:
            # Navigate to the specified URL
            # Focus the address bar (Ctrl+L)
            pg.hotkey('ctrl', 'l')
            pg.sleep(0.5)

            # Type the URL
            pg.typewrite(url, interval=0.05)
            pg.sleep(0.5)

            # Press Enter to navigate
            pg.press('enter')

            return f'Launched Microsoft Edge and navigated to {url}'
        else:
            return 'Launched Microsoft Edge with default home page'

    except Exception as e:
        return f'Error launching Edge browser: {str(e)}'

# Microsoft 365 & Power Platform Tools

@mcp.tool(name='PAC-CLI-Tool', description='Execute Power Platform CLI (PAC) commands for managing Power Apps, Power Automate, and Dataverse environments. Common commands: pac auth list, pac solution list, pac app list, pac env list.')
def pac_cli_tool(command: str) -> str:
    """Execute PAC CLI commands for Power Platform management."""
    try:
        # Validate the command starts with 'pac'
        if not command.strip().lower().startswith('pac'):
            return 'Error: Command must start with "pac". Example: pac env list'

        # Execute the PAC CLI command via PowerShell
        response, status = desktop.execute_command(f'powershell.exe -Command "{command}"')

        if status == 0:
            return f'PAC CLI executed successfully:\n{response}'
        else:
            return f'PAC CLI command failed (Status: {status}):\n{response}'

    except Exception as e:
        return f'Error executing PAC CLI command: {str(e)}'

@mcp.tool(name='Connect-MGGraph-Tool', description='Authenticate with Microsoft Graph API using Connect-MgGraph PowerShell cmdlet. Supports interactive login and various authentication methods.')
def connect_mggraph_tool(scopes: str = None, tenant_id: str = None) -> str:
    """Connect to Microsoft Graph API for Office 365 operations."""
    try:
        # Build the Connect-MgGraph command
        cmd_parts = ['Connect-MgGraph']

        if scopes:
            # Add scopes parameter
            cmd_parts.append(f'-Scopes "{scopes}"')

        if tenant_id:
            # Add tenant ID parameter
            cmd_parts.append(f'-TenantId "{tenant_id}"')

        command = ' '.join(cmd_parts)
        powershell_cmd = f'powershell.exe -Command "Import-Module Microsoft.Graph; {command}; Get-MgContext | Select-Object Account, Scopes, Environment | Format-List"'

        response, status = desktop.execute_command(powershell_cmd)

        if status == 0:
            return f'Microsoft Graph connection established:\n{response}'
        else:
            return f'Failed to connect to Microsoft Graph (Status: {status}):\n{response}'

    except Exception as e:
        return f'Error connecting to Microsoft Graph: {str(e)}'

@mcp.tool(name='Graph-API-Tool', description='Execute Microsoft Graph API calls to interact with Office 365 data (users, groups, emails, files, etc.). Requires active Graph connection via Connect-MGGraph-Tool.')
def graph_api_tool(endpoint: str, method: str = "GET", body: str = None) -> str:
    """Execute Microsoft Graph API calls for Office 365 data operations."""
    try:
        # Validate endpoint
        if not endpoint.startswith('/'):
            endpoint = '/' + endpoint

        # Build the Graph API command
        if method.upper() == "GET":
            if endpoint.startswith('/me'):
                cmd = f'Get-MgUser -UserId (Get-MgContext).Account'
            elif endpoint.startswith('/users'):
                cmd = f'Get-MgUser -All'
            elif endpoint.startswith('/groups'):
                cmd = f'Get-MgGroup -All'
            else:
                cmd = f'Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0{endpoint}" -Method {method}'
        else:
            cmd = f'Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0{endpoint}" -Method {method}'
            if body:
                cmd += f' -Body \'{body}\''

        powershell_cmd = f'powershell.exe -Command "Import-Module Microsoft.Graph; {cmd} | ConvertTo-Json -Depth 3"'

        response, status = desktop.execute_command(powershell_cmd)

        if status == 0:
            return f'Graph API call successful:\n{response}'
        else:
            return f'Graph API call failed (Status: {status}):\n{response}'

    except Exception as e:
        return f'Error executing Graph API call: {str(e)}'

@mcp.tool(name='Copilot-Studio-Tool', description='Manage Copilot Studio agents via the Agent Studio backend (localhost:3004). Actions: list (list agents), profiles (list environment profiles), switch-profile (switch active profile), eval-status (get eval details for an agent), generate-eval (generate and persist native eval test cases), trigger-eval (trigger a native Copilot Studio evaluation run), poll-eval (check eval run status). Requires Agent Studio server running on port 3004.')
def copilot_studio_tool(
    action: str,
    bot_id: str = None,
    profile_id: str = None,
    test_set_id: str = None,
    run_id: str = None,
    question_count: int = 5,
    eval_name: str = None,
    org_url: str = None,
) -> str:
    """Interact with Copilot Studio agents via the Agent Studio backend API."""
    import json as _json
    base = 'http://localhost:3004/api/copilot-studio'
    headers = {}
    if org_url:
        headers['x-agent-studio-org-url'] = org_url

    try:
        if action.lower() == 'list':
            resp = requests.get(f'{base}/agents', headers=headers, timeout=30)
            resp.raise_for_status()
            agents = resp.json()
            lines = [f'Found {len(agents)} agents:']
            for a in agents:
                pub = a.get('publishedOn') or 'not published'
                lines.append(f'  - {a.get("name")} | botId: {a.get("botId")} | published: {pub}')
            return '\n'.join(lines)

        elif action.lower() == 'profiles':
            resp = requests.get(f'{base}/profiles', timeout=15)
            resp.raise_for_status()
            data = resp.json()
            lines = [f'Active profile: {data.get("activeProfileId")}']
            for p in data.get('profiles', []):
                tag = ' [ACTIVE]' if p.get('active') else ''
                lines.append(f'  {p["id"]}: {p["name"]} ({p.get("orgUrl", "?")}){tag}')
            return '\n'.join(lines)

        elif action.lower() == 'switch-profile' and profile_id:
            resp = requests.post(f'{base}/profiles/switch',
                json={'profileId': profile_id}, timeout=15)
            resp.raise_for_status()
            data = resp.json()
            return f'Switched to profile: {data.get("activeProfileId")} ({data.get("profile", {}).get("name", "?")})'

        elif action.lower() == 'eval-status' and bot_id:
            resp = requests.get(f'{base}/evals/{bot_id}', headers=headers, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            native = data.get('native', {})
            dl = data.get('directLine', {})
            lines = [
                f'Agent: {bot_id}',
                f'Native eval configs: {native.get("configurationCount", 0)}',
                f'Test cases: {native.get("testCaseCount", 0)}',
                f'Eval runs: {native.get("evaluationRunCount", 0)}',
                f'Direct Line available: {dl.get("available", False)}',
                f'Published: {dl.get("published", False)} (on {dl.get("publishedOn", "?")})',
            ]
            for cfg in native.get('configurations', []):
                lines.append(f'  Config: {cfg.get("name")} (id: {cfg.get("id")})')
            for run in native.get('recentRuns', []):
                lines.append(f'  Run: {run.get("name")} state={run.get("state")} created={run.get("createdOn")}')
            return '\n'.join(lines)

        elif action.lower() == 'generate-eval' and bot_id:
            body = {
                'botId': bot_id,
                'count': question_count,
                'persist': True,
                'evaluationName': eval_name or f'Clippy Eval - {bot_id[:8]}',
                'evaluationDescription': 'Evaluation generated by Windows Clippy MCP',
            }
            resp = requests.post(f'{base}/generate-questions',
                json=body, headers=headers, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            persisted = data.get('persisted', {})
            questions = data.get('questions', [])
            lines = [f'Generated {len(questions)} questions for {bot_id}']
            if persisted.get('testSetId'):
                lines.append(f'Persisted to native eval! testSetId: {persisted["testSetId"]}')
                lines.append(f'Test set name: {persisted.get("name", "?")}')
            for q in questions:
                lines.append(f'  Q: {q.get("query", "?")}')
            return '\n'.join(lines)

        elif action.lower() == 'trigger-eval' and bot_id and test_set_id:
            resp = requests.post(f'{base}/evals/{bot_id}/native-run',
                json={'testSetId': test_set_id}, headers=headers, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            return (
                f'Native eval triggered!\n'
                f'  runId: {data.get("runId")}\n'
                f'  state: {data.get("executionState")}\n'
                f'  environment: {data.get("environment", "?")}\n'
                f'  botId: {data.get("botId")}'
            )

        elif action.lower() == 'poll-eval' and bot_id and run_id:
            resp = requests.get(f'{base}/evals/{bot_id}/native-run/{run_id}',
                headers=headers, timeout=15)
            resp.raise_for_status()
            data = resp.json()
            return (
                f'Run: {data.get("runId")}\n'
                f'  State: {data.get("executionState")}\n'
                f'  Processed: {data.get("processedItems")}/{data.get("totalItems")} items\n'
                f'  Last updated: {data.get("lastUpdatedAt", "?")}'
            )

        else:
            return (
                'Copilot Studio Tool - available actions:\n'
                '  list              - List all agents in active environment\n'
                '  profiles          - List environment profiles\n'
                '  switch-profile    - Switch active profile (requires profile_id)\n'
                '  eval-status       - Get eval details for agent (requires bot_id)\n'
                '  generate-eval     - Generate and persist eval test cases (requires bot_id)\n'
                '  trigger-eval      - Trigger native eval run (requires bot_id, test_set_id)\n'
                '  poll-eval         - Poll eval run status (requires bot_id, run_id)\n'
                '\n'
                'NOTE: Requires Agent Studio server running on localhost:3004'
            )

    except requests.exceptions.ConnectionError:
        return 'Error: Cannot connect to Agent Studio server at localhost:3004. Start it with: cd E:\\agent-studio && node server/server.js'
    except requests.exceptions.HTTPError as e:
        return f'Error: Agent Studio API returned {e.response.status_code}: {e.response.text[:500]}'
    except Exception as e:
        return f'Error with Copilot Studio operation: {str(e)}'

@mcp.tool(name='Agent-Studio-Tool', description='Query the Agent Studio unified store for eval runs, feedback, monitoring snapshots, and activity logs. Actions: overview (dashboard stats), timeline (agent activity timeline), query (flexible store query), capabilities (list MCP capability manifest), evals (list recent eval runs). Requires Agent Studio server on port 3004.')
def agent_studio_tool(
    action: str,
    agent_id: str = None,
    event_type: str = None,
    limit: int = 20,
) -> str:
    """Query Agent Studio unified store and capability manifest."""
    import json as _json
    api_base = 'http://localhost:3004/api'
    mcp_base = 'http://localhost:3447'

    try:
        if action.lower() == 'overview':
            resp = requests.get(f'{api_base}/store/overview', timeout=15)
            resp.raise_for_status()
            data = resp.json()
            lines = ['Agent Studio Store Overview:']
            for key, val in data.items():
                lines.append(f'  {key}: {val}')
            return '\n'.join(lines)

        elif action.lower() == 'timeline' and agent_id:
            resp = requests.get(f'{api_base}/store/timeline/{agent_id}', params={'limit': limit}, timeout=15)
            resp.raise_for_status()
            data = resp.json()
            lines = [f'Timeline for agent {agent_id} ({len(data)} events):']
            for event in data:
                lines.append(
                    f'  [{event.get("source", "?")}] {event.get("timestamp", "?")} - '
                    f'{_json.dumps(event.get("summary", ""), ensure_ascii=False)[:120]}'
                )
            return '\n'.join(lines)

        elif action.lower() == 'query':
            where = []
            sql_params = []
            if event_type:
                where.append('event_type = ?')
                sql_params.append(event_type)
            if agent_id:
                where.append('agent_id = ?')
                sql_params.append(agent_id)
            sql = (
                'SELECT id, agent_id, event_type, channel, detail, response_ms, created_at '
                'FROM activity_log'
            )
            if where:
                sql += ' WHERE ' + ' AND '.join(where)
            sql += ' ORDER BY created_at DESC LIMIT ?'
            sql_params.append(limit)
            resp = requests.post(
                f'{api_base}/store/query',
                json={'sql': sql, 'params': sql_params},
                timeout=15,
            )
            resp.raise_for_status()
            data = resp.json()
            return _json.dumps(data.get('rows', []), indent=2, ensure_ascii=False)[:3000]

        elif action.lower() == 'capabilities':
            try:
                resp = requests.get(f'{mcp_base}/capabilities', timeout=10)
            except requests.exceptions.ConnectionError:
                return 'Error: Cannot connect to Agent Studio MCP server at localhost:3447. Start it with: cd E:\\agent-studio && npm run start:mcp'
            resp.raise_for_status()
            data = resp.json()
            lines = [f'Agent Studio MCP Capabilities (v{data.get("version", "?")}):', '']
            for cat_name, cat_tools in data.get('capabilities', {}).items():
                lines.append(f'  {cat_name}:')
                for tool in cat_tools:
                    lines.append(f'    - {tool.get("name")}: {tool.get("description", "")[:80]}')
            return '\n'.join(lines)

        elif action.lower() == 'evals':
            where = []
            sql_params = []
            if agent_id:
                where.append('agent_id = ?')
                sql_params.append(agent_id)
            sql = (
                'SELECT id, agent_id, agent_name, profile_id, question_count, '
                'passed, failed, pass_rate, status, started_at, completed_at '
                'FROM eval_runs'
            )
            if where:
                sql += ' WHERE ' + ' AND '.join(where)
            sql += ' ORDER BY started_at DESC LIMIT ?'
            sql_params.append(limit)
            resp = requests.post(
                f'{api_base}/store/query',
                json={'sql': sql, 'params': sql_params},
                timeout=15,
            )
            resp.raise_for_status()
            rows = resp.json().get('rows', [])
            lines = [f'Recent eval runs ({len(rows)} entries):']
            for row in rows:
                lines.append(
                    f'  Agent: {row.get("agent_name") or row.get("agent_id", "?")} '
                    f'| profile: {row.get("profile_id", "?")} '
                    f'| passRate: {row.get("pass_rate", "?")}% '
                    f'| status: {row.get("status", "?")} '
                    f'| runId: {row.get("id", "?")}'
                )
            return '\n'.join(lines)

        else:
            return (
                'Agent Studio Tool - available actions:\n'
                '  overview       - Dashboard stats (eval runs, feedback, activity counts)\n'
                '  timeline       - Agent activity timeline (requires agent_id)\n'
                '  query          - Flexible store query (optional: agent_id, event_type, limit)\n'
                '  capabilities   - List MCP capability manifest\n'
                '  evals          - List recent eval runs and results\n'
                '\n'
                'NOTE: Requires Agent Studio backend on localhost:3004; capabilities also require MCP server on localhost:3447'
            )

    except requests.exceptions.ConnectionError:
        return 'Error: Cannot connect to Agent Studio server at localhost:3004. Start it with: cd E:\\agent-studio && node server/server.js'
    except requests.exceptions.HTTPError as e:
        return f'Error: Agent Studio API returned {e.response.status_code}: {e.response.text[:500]}'
    except Exception as e:
        return f'Error with Agent Studio operation: {str(e)}'

@mcp.tool(name='Power-Automate-Tool', description='Create and manage Power Automate workflows. List, create, trigger, and monitor cloud flows and desktop flows.')
def power_automate_tool(action: str, flow_name: str = None, parameters: str = None) -> str:
    """Manage Power Automate workflows and flows."""
    try:
        if action.lower() == 'list':
            # List flows using PAC CLI
            cmd = 'powershell.exe -Command "pac flow list"'

        elif action.lower() == 'create' and flow_name:
            # Create a new flow (placeholder - would need flow definition)
            cmd = f'powershell.exe -Command "Write-Output \'Creating Power Automate flow: {flow_name}. Flow creation requires detailed flow definition and proper environment setup.\'"'

        elif action.lower() == 'trigger' and flow_name:
            # Trigger a flow
            trigger_cmd = f'pac flow run --name "{flow_name}"'
            if parameters:
                trigger_cmd += f' --parameters \'{parameters}\''
            cmd = f'powershell.exe -Command "{trigger_cmd}"'

        elif action.lower() == 'status' and flow_name:
            # Check flow status
            cmd = f'powershell.exe -Command "pac flow show --name \\"{flow_name}\\""'

        else:
            return 'Error: Invalid action. Supported actions: list, create (requires flow_name), trigger (requires flow_name, optional parameters), status (requires flow_name)'

        response, status = desktop.execute_command(cmd)

        if status == 0:
            return f'Power Automate operation completed:\n{response}'
        else:
            return f'Power Automate operation failed (Status: {status}):\n{response}'

    except Exception as e:
        return f'Error with Power Automate operation: {str(e)}'

@mcp.tool(name='M365-Copilot-Tool', description='Interact with Microsoft 365 Copilot features across Office apps (Word, Excel, PowerPoint, Teams, Outlook). Execute Copilot prompts and commands.')
def m365_copilot_tool(app: str, prompt: str, context: str = None) -> str:
    """Interact with Microsoft 365 Copilot in various Office applications."""
    try:
        # Validate the target application
        supported_apps = ['word', 'excel', 'powerpoint', 'teams', 'outlook', 'onenote']
        if app.lower() not in supported_apps:
            return f'Error: Unsupported app. Supported apps: {", ".join(supported_apps)}'

        # This is a placeholder implementation as M365 Copilot integration
        # would require specific Office application APIs and Copilot licensing
        if app.lower() == 'word':
            cmd = f'powershell.exe -Command "Write-Output \'M365 Copilot Word interaction: {prompt}. This requires Word with Copilot enabled and proper API integration.\'"'
        elif app.lower() == 'excel':
            cmd = f'powershell.exe -Command "Write-Output \'M365 Copilot Excel interaction: {prompt}. This requires Excel with Copilot enabled and proper API integration.\'"'
        elif app.lower() == 'teams':
            cmd = f'powershell.exe -Command "Write-Output \'M365 Copilot Teams interaction: {prompt}. This requires Teams with Copilot enabled and proper API integration.\'"'
        else:
            cmd = f'powershell.exe -Command "Write-Output \'M365 Copilot {app} interaction: {prompt}. This requires {app} with Copilot enabled and proper API integration.\'"'

        response, status = desktop.execute_command(cmd)

        if status == 0:
            return f'M365 Copilot interaction completed:\n{response}'
        else:
            return f'M365 Copilot interaction failed (Status: {status}):\n{response}'

    except Exception as e:
        return f'Error with M365 Copilot interaction: {str(e)}'


# ==================== NEW WINDOWS TOOLS ====================

@mcp.tool(name='Window-Tool', description='Control window state: minimize, maximize, restore, close, or resize active/named window. Use action="minimize|maximize|restore|close|resize". For resize, provide width and height.')
def window_tool(action: Literal['minimize', 'maximize', 'restore', 'close', 'resize'], window_name: str = None, width: int = None, height: int = None) -> str:
    try:
        ps_script = '''
        Add-Type -TypeDefinition @'
        using System;
        using System.Runtime.InteropServices;
        public class WinAPI {
            [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
            [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
            [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
            [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
            [DllImport("user32.dll")] public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
            [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        }
'@
        '''
        
        if window_name:
            ps_script += f'''
            $proc = Get-Process | Where-Object {{ $_.MainWindowTitle -like "*{window_name}*" -and $_.MainWindowHandle -ne 0 }} | Select-Object -First 1
            if ($proc) {{ $hwnd = $proc.MainWindowHandle }} else {{ Write-Output "NOTFOUND"; exit }}
            '''
        else:
            ps_script += '$hwnd = [WinAPI]::GetForegroundWindow()\n'
        
        action_map = {
            'minimize': '[WinAPI]::ShowWindow($hwnd, 6) | Out-Null; Write-Output "Minimized"',
            'maximize': '[WinAPI]::ShowWindow($hwnd, 3) | Out-Null; Write-Output "Maximized"',
            'restore': '[WinAPI]::ShowWindow($hwnd, 9) | Out-Null; Write-Output "Restored"',
            'close': '[WinAPI]::SendMessage($hwnd, 0x0010, 0, 0) | Out-Null; Write-Output "Closed"',
        }
        
        if action == 'resize' and width and height:
            ps_script += f'''
            $rect = New-Object WinAPI+RECT
            [WinAPI]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
            [WinAPI]::MoveWindow($hwnd, $rect.Left, $rect.Top, {width}, {height}, $true) | Out-Null
            Write-Output "Resized to {width}x{height}"
            '''
        elif action in action_map:
            ps_script += action_map[action]
        else:
            return 'Invalid action or missing width/height for resize'
        
        result = subprocess.run(['powershell', '-Command', ps_script], capture_output=True, text=True, timeout=10)
        output = result.stdout.strip()
        
        if output == "NOTFOUND":
            return f'Window "{window_name}" not found'
        return f'Window action completed: {output}'
    except Exception as e:
        return f'Window operation failed: {str(e)}'

@mcp.tool(name='Screenshot-Tool', description='Capture screenshot of entire screen, specific region, or active window. Mode: "full", "region" (needs x,y,width,height), or "window". Returns base64 encoded PNG or saves to file.')
def screenshot_tool(mode: Literal['full', 'region', 'window'] = 'full', x: int = None, y: int = None, width: int = None, height: int = None, save_path: str = None) -> str:
    try:
        import base64
        from io import BytesIO
        
        if mode == 'full':
            screenshot = pg.screenshot()
        elif mode == 'region' and all([x is not None, y is not None, width, height]):
            screenshot = pg.screenshot(region=(x, y, width, height))
        elif mode == 'window':
            # Capture active window
            window = ua.GetForegroundWindow()
            if window:
                rect = window.BoundingRectangle
                screenshot = pg.screenshot(region=(rect.left, rect.top, rect.width(), rect.height()))
            else:
                screenshot = pg.screenshot()
        else:
            return 'Invalid mode or missing region parameters'
        
        if save_path:
            screenshot.save(save_path)
            return f'Screenshot saved to {save_path}'
        else:
            buffer = BytesIO()
            screenshot.save(buffer, format='PNG')
            b64_data = base64.b64encode(buffer.getvalue()).decode('utf-8')
            return f'Screenshot captured (base64 PNG, {len(b64_data)} chars). First 100 chars: {b64_data[:100]}...'
    except Exception as e:
        return f'Screenshot failed: {str(e)}'

@mcp.tool(name='Volume-Tool', description='Control system volume: mute, unmute, set volume level (0-100), increase/decrease by amount.')
def volume_tool(action: Literal['mute', 'unmute', 'set', 'up', 'down', 'get'], level: int = None) -> str:
    try:
        if action == 'mute':
            ps_cmd = '''
            $obj = New-Object -ComObject WScript.Shell
            $obj.SendKeys([char]173)
            '''
            # Alternative: use nircmd or direct API
            for _ in range(1):
                pg.press('volumemute')
            return 'Volume muted'
        
        elif action == 'unmute':
            pg.press('volumemute')  # Toggle
            return 'Volume unmuted (toggled)'
        
        elif action == 'set' and level is not None:
            # Set volume using PowerShell with audio API
            ps_cmd = f'''
            Add-Type -TypeDefinition @'
            using System.Runtime.InteropServices;
            [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
            interface IAudioEndpointVolume {{
                int _0(); int _1(); int _2(); int _3();
                int SetMasterVolumeLevelScalar(float fLevel, System.Guid pguidEventContext);
                int _5();
                int GetMasterVolumeLevelScalar(out float pfLevel);
            }}
            [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
            interface IMMDevice {{ int Activate(ref System.Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface); }}
            [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
            interface IMMDeviceEnumerator {{ int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice); }}
            [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject {{ }}
            public class Audio {{
                static IAudioEndpointVolume Vol() {{
                    var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
                    IMMDevice dev; enumerator.GetDefaultAudioEndpoint(0, 1, out dev);
                    var iid = typeof(IAudioEndpointVolume).GUID; object o; dev.Activate(ref iid, 1, IntPtr.Zero, out o);
                    return o as IAudioEndpointVolume;
                }}
                public static void SetVol(float v) {{ Vol().SetMasterVolumeLevelScalar(v, System.Guid.Empty); }}
                public static float GetVol() {{ float v; Vol().GetMasterVolumeLevelScalar(out v); return v; }}
            }}
'@
            [Audio]::SetVol({level/100})
            Write-Output "Volume set to {level}%"
            '''
            result = subprocess.run(['powershell', '-Command', ps_cmd], capture_output=True, text=True, timeout=10)
            return result.stdout.strip() or f'Volume set to {level}%'
        
        elif action == 'up':
            times = level if level else 2
            for _ in range(times):
                pg.press('volumeup')
            return f'Volume increased by {times * 2}%'
        
        elif action == 'down':
            times = level if level else 2
            for _ in range(times):
                pg.press('volumedown')
            return f'Volume decreased by {times * 2}%'
        
        elif action == 'get':
            ps_cmd = '''
            Add-Type -TypeDefinition @'
            using System.Runtime.InteropServices;
            [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
            interface IAudioEndpointVolume {
                int _0(); int _1(); int _2(); int _3();
                int SetMasterVolumeLevelScalar(float fLevel, System.Guid pguidEventContext);
                int _5();
                int GetMasterVolumeLevelScalar(out float pfLevel);
            }
            [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
            interface IMMDevice { int Activate(ref System.Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface); }
            [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
            interface IMMDeviceEnumerator { int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice); }
            [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
            public class Audio {
                public static float GetVol() {
                    var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
                    IMMDevice dev; enumerator.GetDefaultAudioEndpoint(0, 1, out dev);
                    var iid = typeof(IAudioEndpointVolume).GUID; object o; dev.Activate(ref iid, 1, IntPtr.Zero, out o);
                    float v; (o as IAudioEndpointVolume).GetMasterVolumeLevelScalar(out v); return v;
                }
            }
'@
            $vol = [Audio]::GetVol() * 100
            Write-Output "Current volume: $([math]::Round($vol))%"
            '''
            result = subprocess.run(['powershell', '-Command', ps_cmd], capture_output=True, text=True, timeout=10)
            return result.stdout.strip() or 'Could not get volume level'
        
        return 'Invalid action'
    except Exception as e:
        return f'Volume control failed: {str(e)}'

@mcp.tool(name='Notification-Tool', description='Display a Windows toast notification with title and message.')
def notification_tool(title: str, message: str, duration: Literal['short', 'long'] = 'short') -> str:
    try:
        # Escape special characters for PowerShell
        title_escaped = title.replace("'", "''").replace('"', '`"')
        message_escaped = message.replace("'", "''").replace('"', '`"')
        
        ps_script = f'''
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $template = @"
        <toast duration="{duration}">
            <visual>
                <binding template="ToastText02">
                    <text id="1">{title_escaped}</text>
                    <text id="2">{message_escaped}</text>
                </binding>
            </visual>
        </toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Darbot Windows MCP").Show($toast)
        '''
        result = subprocess.run(['powershell', '-Command', ps_script], capture_output=True, text=True, timeout=10)
        return f'Notification displayed: "{title}"'
    except Exception as e:
        return f'Notification failed: {str(e)}'

@mcp.tool(name='FileExplorer-Tool', description='Open Windows File Explorer at a specific path. If no path provided, opens default location.')
def file_explorer_tool(path: str = None) -> str:
    try:
        if path:
            # Normalize path
            path = os_module.path.normpath(path)
            if os_module.path.exists(path):
                subprocess.Popen(['explorer', path])
                return f'Opened File Explorer at: {path}'
            else:
                return f'Path does not exist: {path}'
        else:
            subprocess.Popen(['explorer'])
            return 'Opened File Explorer'
    except Exception as e:
        return f'Failed to open File Explorer: {str(e)}'

@mcp.tool(name='Process-Tool', description='List running processes or kill a process by name or PID. Action: "list" to show processes, "kill" to terminate.')
def process_tool(action: Literal['list', 'kill'], name: str = None, pid: int = None, filter_name: str = None) -> str:
    try:
        if action == 'list':
            processes = []
            for proc in psutil.process_iter(['pid', 'name', 'cpu_percent', 'memory_percent']):
                try:
                    info = proc.info
                    if filter_name and filter_name.lower() not in info['name'].lower():
                        continue
                    processes.append({
                        'pid': info['pid'],
                        'name': info['name'],
                        'cpu': round(info['cpu_percent'] or 0, 1),
                        'memory': round(info['memory_percent'] or 0, 1)
                    })
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
            
            # Sort by memory usage and limit
            processes.sort(key=lambda x: x['memory'], reverse=True)
            processes = processes[:30]
            
            result = "Running Processes (Top 30 by memory):\n"
            result += "-" * 60 + "\n"
            result += f"{'PID':<10} {'Name':<30} {'CPU%':<8} {'Mem%':<8}\n"
            result += "-" * 60 + "\n"
            for p in processes:
                result += f"{p['pid']:<10} {p['name'][:28]:<30} {p['cpu']:<8} {p['memory']:<8}\n"
            return result
        
        elif action == 'kill':
            if pid:
                proc = psutil.Process(pid)
                proc_name = proc.name()
                proc.terminate()
                return f'Terminated process: {proc_name} (PID: {pid})'
            elif name:
                killed = []
                for proc in psutil.process_iter(['pid', 'name']):
                    if name.lower() in proc.info['name'].lower():
                        try:
                            proc.terminate()
                            killed.append(f"{proc.info['name']} (PID: {proc.info['pid']})")
                        except:
                            pass
                if killed:
                    return f'Terminated processes: {", ".join(killed)}'
                return f'No process found matching: {name}'
            else:
                return 'Provide either name or pid to kill a process'
        
        return 'Invalid action'
    except Exception as e:
        return f'Process operation failed: {str(e)}'

@mcp.tool(name='SystemInfo-Tool', description='Get system information: CPU, memory, disk usage, OS details, network interfaces.')
def system_info_tool(info_type: Literal['all', 'cpu', 'memory', 'disk', 'os', 'network', 'battery'] = 'all') -> str:
    try:
        result = []
        
        if info_type in ['all', 'os']:
            import platform
            result.append("=== OS Information ===")
            result.append(f"System: {platform.system()} {platform.release()}")
            result.append(f"Version: {platform.version()}")
            result.append(f"Machine: {platform.machine()}")
            result.append(f"Processor: {platform.processor()}")
            result.append(f"Computer Name: {os_module.environ.get('COMPUTERNAME', 'Unknown')}")
            result.append(f"User: {os_module.environ.get('USERNAME', 'Unknown')}")
        
        if info_type in ['all', 'cpu']:
            result.append("\n=== CPU Information ===")
            result.append(f"Physical Cores: {psutil.cpu_count(logical=False)}")
            result.append(f"Logical Cores: {psutil.cpu_count(logical=True)}")
            result.append(f"CPU Usage: {psutil.cpu_percent(interval=1)}%")
            cpu_freq = psutil.cpu_freq()
            if cpu_freq:
                result.append(f"CPU Frequency: {cpu_freq.current:.0f} MHz")
        
        if info_type in ['all', 'memory']:
            mem = psutil.virtual_memory()
            result.append("\n=== Memory Information ===")
            result.append(f"Total: {mem.total / (1024**3):.2f} GB")
            result.append(f"Available: {mem.available / (1024**3):.2f} GB")
            result.append(f"Used: {mem.used / (1024**3):.2f} GB ({mem.percent}%)")
        
        if info_type in ['all', 'disk']:
            result.append("\n=== Disk Information ===")
            for partition in psutil.disk_partitions():
                try:
                    usage = psutil.disk_usage(partition.mountpoint)
                    result.append(f"Drive {partition.device}:")
                    result.append(f"  Total: {usage.total / (1024**3):.2f} GB")
                    result.append(f"  Used: {usage.used / (1024**3):.2f} GB ({usage.percent}%)")
                    result.append(f"  Free: {usage.free / (1024**3):.2f} GB")
                except:
                    pass
        
        if info_type in ['all', 'network']:
            result.append("\n=== Network Interfaces ===")
            for name, addrs in psutil.net_if_addrs().items():
                for addr in addrs:
                    if addr.family.name == 'AF_INET':
                        result.append(f"{name}: {addr.address}")
        
        if info_type in ['all', 'battery']:
            battery = psutil.sensors_battery()
            if battery:
                result.append("\n=== Battery Information ===")
                result.append(f"Charge: {battery.percent}%")
                result.append(f"Plugged In: {'Yes' if battery.power_plugged else 'No'}")
                if battery.secsleft != psutil.POWER_TIME_UNLIMITED and battery.secsleft != psutil.POWER_TIME_UNKNOWN:
                    mins = battery.secsleft // 60
                    result.append(f"Time Left: {mins} minutes")
        
        return "\n".join(result)
    except Exception as e:
        return f'System info failed: {str(e)}'

@mcp.tool(name='Search-Tool', description='Perform Windows Search for files, folders, or apps using the Windows search feature.')
def search_tool(query: str, search_type: Literal['files', 'apps', 'settings', 'web'] = 'files') -> str:
    try:
        # Open Windows Search
        pg.hotkey('win', 's')
        pg.sleep(0.5)
        
        # Type the search query
        pg.typewrite(query, interval=0.05)
        pg.sleep(1)
        
        return f'Windows Search opened with query: "{query}". Use State-Tool to see results and Click-Tool to select.'
    except Exception as e:
        return f'Search failed: {str(e)}'

@mcp.tool(name='TaskView-Tool', description='Open Task View for virtual desktop management or recent activities. Action: "open" to show task view, "new_desktop" to create virtual desktop, "switch_desktop" to switch between desktops.')
def task_view_tool(action: Literal['open', 'new_desktop', 'close_desktop', 'switch_left', 'switch_right'] = 'open') -> str:
    try:
        if action == 'open':
            pg.hotkey('win', 'tab')
            return 'Task View opened'
        elif action == 'new_desktop':
            pg.hotkey('win', 'ctrl', 'd')
            return 'New virtual desktop created'
        elif action == 'close_desktop':
            pg.hotkey('win', 'ctrl', 'f4')
            return 'Current virtual desktop closed'
        elif action == 'switch_left':
            pg.hotkey('win', 'ctrl', 'left')
            return 'Switched to desktop on the left'
        elif action == 'switch_right':
            pg.hotkey('win', 'ctrl', 'right')
            return 'Switched to desktop on the right'
        return 'Invalid action'
    except Exception as e:
        return f'Task View action failed: {str(e)}'

@mcp.tool(name='Settings-Tool', description='Open specific Windows Settings pages directly. Use page names like "display", "wifi", "bluetooth", "sound", "notifications", "privacy", "update", "apps", "personalization", "accounts", "time", "gaming", "accessibility".')
def settings_tool(page: str = 'main') -> str:
    try:
        # Map friendly names to ms-settings URIs
        settings_map = {
            'main': 'ms-settings:',
            'display': 'ms-settings:display',
            'wifi': 'ms-settings:network-wifi',
            'network': 'ms-settings:network-status',
            'bluetooth': 'ms-settings:bluetooth',
            'sound': 'ms-settings:sound',
            'notifications': 'ms-settings:notifications',
            'focus': 'ms-settings:quiethours',
            'power': 'ms-settings:powersleep',
            'battery': 'ms-settings:batterysaver',
            'storage': 'ms-settings:storagesense',
            'privacy': 'ms-settings:privacy',
            'update': 'ms-settings:windowsupdate',
            'apps': 'ms-settings:appsfeatures',
            'default_apps': 'ms-settings:defaultapps',
            'personalization': 'ms-settings:personalization',
            'background': 'ms-settings:personalization-background',
            'colors': 'ms-settings:colors',
            'themes': 'ms-settings:themes',
            'lockscreen': 'ms-settings:lockscreen',
            'accounts': 'ms-settings:yourinfo',
            'signin': 'ms-settings:signinoptions',
            'time': 'ms-settings:dateandtime',
            'language': 'ms-settings:regionlanguage',
            'gaming': 'ms-settings:gaming-gamebar',
            'accessibility': 'ms-settings:easeofaccess',
            'mouse': 'ms-settings:mousetouchpad',
            'keyboard': 'ms-settings:keyboard',
            'printers': 'ms-settings:printers',
            'phone': 'ms-settings:mobile-devices',
            'about': 'ms-settings:about',
            'vpn': 'ms-settings:network-vpn',
            'proxy': 'ms-settings:network-proxy',
            'startup': 'ms-settings:startupapps',
        }
        
        uri = settings_map.get(page.lower(), f'ms-settings:{page}')
        subprocess.Popen(['explorer', uri])
        return f'Opened Windows Settings: {page}'
    except Exception as e:
        return f'Failed to open settings: {str(e)}'

@mcp.tool(name='Snip-Tool', description='Open Windows Snipping Tool or Snip & Sketch for screen capture with annotation capabilities.')
def snip_tool(mode: Literal['snip', 'fullscreen', 'window', 'freeform', 'rectangle'] = 'snip') -> str:
    try:
        if mode == 'snip':
            pg.hotkey('win', 'shift', 's')
            return 'Snip & Sketch opened. Select area to capture.'
        elif mode == 'fullscreen':
            pg.press('printscreen')
            return 'Full screen captured to clipboard'
        elif mode == 'window':
            pg.hotkey('alt', 'printscreen')
            return 'Active window captured to clipboard'
        elif mode in ['freeform', 'rectangle']:
            pg.hotkey('win', 'shift', 's')
            return f'Snip & Sketch opened in {mode} mode. Select area to capture.'
        return 'Invalid snip mode'
    except Exception as e:
        return f'Snip operation failed: {str(e)}'

@mcp.tool(name='Registry-Tool', description='Read Windows Registry values (read-only for safety). Provide full key path and optional value name.')
def registry_tool(key_path: str, value_name: str = None) -> str:
    try:
        # Parse the key path
        root_keys = {
            'HKEY_CURRENT_USER': winreg.HKEY_CURRENT_USER,
            'HKCU': winreg.HKEY_CURRENT_USER,
            'HKEY_LOCAL_MACHINE': winreg.HKEY_LOCAL_MACHINE,
            'HKLM': winreg.HKEY_LOCAL_MACHINE,
            'HKEY_CLASSES_ROOT': winreg.HKEY_CLASSES_ROOT,
            'HKCR': winreg.HKEY_CLASSES_ROOT,
            'HKEY_USERS': winreg.HKEY_USERS,
            'HKU': winreg.HKEY_USERS,
        }
        
        parts = key_path.replace('/', '\\').split('\\', 1)
        if len(parts) < 2:
            return 'Invalid key path. Format: HKEY_*\\Path\\To\\Key'
        
        root_name = parts[0].upper()
        subkey = parts[1]
        
        if root_name not in root_keys:
            return f'Unknown root key: {root_name}'
        
        root = root_keys[root_name]
        
        with winreg.OpenKey(root, subkey, 0, winreg.KEY_READ) as key:
            if value_name:
                value, value_type = winreg.QueryValueEx(key, value_name)
                type_names = {
                    winreg.REG_SZ: 'REG_SZ',
                    winreg.REG_DWORD: 'REG_DWORD',
                    winreg.REG_QWORD: 'REG_QWORD',
                    winreg.REG_BINARY: 'REG_BINARY',
                    winreg.REG_MULTI_SZ: 'REG_MULTI_SZ',
                    winreg.REG_EXPAND_SZ: 'REG_EXPAND_SZ',
                }
                return f'Value: {value_name}\nType: {type_names.get(value_type, "Unknown")}\nData: {value}'
            else:
                # List all values in the key
                result = [f"Values in {key_path}:"]
                i = 0
                while True:
                    try:
                        name, value, vtype = winreg.EnumValue(key, i)
                        result.append(f"  {name}: {value}")
                        i += 1
                    except OSError:
                        break
                
                # List subkeys
                result.append("\nSubkeys:")
                i = 0
                while True:
                    try:
                        subkey_name = winreg.EnumKey(key, i)
                        result.append(f"  {subkey_name}")
                        i += 1
                    except OSError:
                        break
                
                return "\n".join(result)
    except FileNotFoundError:
        return f'Registry key not found: {key_path}'
    except PermissionError:
        return f'Access denied to registry key: {key_path}'
    except Exception as e:
        return f'Registry read failed: {str(e)}'

@mcp.tool(name='Wifi-Tool', description='Manage WiFi connections: list networks, connect, disconnect, or get current connection info.')
def wifi_tool(action: Literal['list', 'connect', 'disconnect', 'status'], network_name: str = None, password: str = None) -> str:
    try:
        if action == 'list':
            result = subprocess.run(['netsh', 'wlan', 'show', 'networks'], capture_output=True, text=True, timeout=15)
            return f'Available WiFi Networks:\n{result.stdout}'
        
        elif action == 'status':
            result = subprocess.run(['netsh', 'wlan', 'show', 'interfaces'], capture_output=True, text=True, timeout=10)
            return f'WiFi Status:\n{result.stdout}'
        
        elif action == 'connect' and network_name:
            # First check if profile exists
            result = subprocess.run(['netsh', 'wlan', 'connect', f'name={network_name}'], capture_output=True, text=True, timeout=15)
            if 'successfully' in result.stdout.lower():
                return f'Connected to {network_name}'
            else:
                return f'Failed to connect to {network_name}. Profile may not exist. Output: {result.stdout} {result.stderr}'
        
        elif action == 'disconnect':
            result = subprocess.run(['netsh', 'wlan', 'disconnect'], capture_output=True, text=True, timeout=10)
            return 'WiFi disconnected'
        
        return 'Invalid action or missing parameters'
    except Exception as e:
        return f'WiFi operation failed: {str(e)}'

@mcp.tool(name='Bluetooth-Tool', description='Open Bluetooth settings or toggle Bluetooth on/off.')
def bluetooth_tool(action: Literal['settings', 'toggle', 'status'] = 'settings') -> str:
    try:
        if action == 'settings':
            subprocess.Popen(['explorer', 'ms-settings:bluetooth'])
            return 'Bluetooth settings opened'
        elif action == 'toggle':
            # Use Action Center to toggle
            pg.hotkey('win', 'a')
            pg.sleep(0.5)
            return 'Action Center opened. Look for Bluetooth quick toggle.'
        elif action == 'status':
            ps_cmd = '''
            Get-PnpDevice -Class Bluetooth | Select-Object Status, FriendlyName | Format-Table -AutoSize
            '''
            result = subprocess.run(['powershell', '-Command', ps_cmd], capture_output=True, text=True, timeout=15)
            return f'Bluetooth Devices:\n{result.stdout}'
        return 'Invalid action'
    except Exception as e:
        return f'Bluetooth operation failed: {str(e)}'

@mcp.tool(name='ActionCenter-Tool', description='Open Windows Action Center (notifications) or Quick Settings panel.')
def action_center_tool(panel: Literal['notifications', 'quick_settings'] = 'quick_settings') -> str:
    try:
        if panel == 'quick_settings':
            pg.hotkey('win', 'a')
            return 'Quick Settings opened'
        elif panel == 'notifications':
            pg.hotkey('win', 'n')
            return 'Notifications panel opened'
        return 'Invalid panel'
    except Exception as e:
        return f'Action Center failed: {str(e)}'

@mcp.tool(name='Lock-Tool', description='Lock the workstation, sign out, or manage power state (sleep, hibernate, shutdown, restart).')
def lock_tool(action: Literal['lock', 'signout', 'sleep', 'hibernate', 'shutdown', 'restart'] = 'lock') -> str:
    try:
        if action == 'lock':
            ctypes.windll.user32.LockWorkStation()
            return 'Workstation locked'
        elif action == 'signout':
            subprocess.run(['shutdown', '/l'], timeout=10)
            return 'Signing out...'
        elif action == 'sleep':
            # Requires SetSuspendState
            subprocess.run(['powershell', '-Command', 'Add-Type -Assembly System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState("Suspend", $false, $false)'], timeout=10)
            return 'System going to sleep...'
        elif action == 'hibernate':
            subprocess.run(['shutdown', '/h'], timeout=10)
            return 'System hibernating...'
        elif action == 'shutdown':
            return 'Shutdown command requires confirmation. Use Powershell-Tool with "shutdown /s /t 60" to shutdown with 60 second delay (can be cancelled with "shutdown /a").'
        elif action == 'restart':
            return 'Restart command requires confirmation. Use Powershell-Tool with "shutdown /r /t 60" to restart with 60 second delay (can be cancelled with "shutdown /a").'
        return 'Invalid action'
    except Exception as e:
        return f'Lock/Power action failed: {str(e)}'

@mcp.tool(name='Taskbar-Tool', description='Interact with Windows Taskbar: show/hide, pin/unpin apps, or get taskbar info.')
def taskbar_tool(action: Literal['show', 'hide', 'info', 'start_menu', 'system_tray'] = 'info') -> str:
    try:
        if action == 'start_menu':
            pg.press('win')
            return 'Start menu opened'
        elif action == 'system_tray':
            pg.hotkey('win', 'b')
            return 'System tray focused. Use arrow keys to navigate.'
        elif action == 'info':
            ps_cmd = '''
            $taskbar = Get-Process -Name explorer | Select-Object -First 1
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen
            Write-Output "Primary Screen Resolution: $($screen.Bounds.Width) x $($screen.Bounds.Height)"
            Write-Output "Work Area: $($screen.WorkingArea.Width) x $($screen.WorkingArea.Height)"
            Write-Output "Taskbar Height: $($screen.Bounds.Height - $screen.WorkingArea.Height) pixels"
            '''
            result = subprocess.run(['powershell', '-Command', ps_cmd], capture_output=True, text=True, timeout=10)
            return result.stdout or 'Could not get taskbar info'
        elif action in ['show', 'hide']:
            return f'Taskbar auto-hide can be configured in Settings > Personalization > Taskbar'
        return 'Invalid action'
    except Exception as e:
        return f'Taskbar operation failed: {str(e)}'

@mcp.tool(name='Emoji-Tool', description='Open Windows Emoji picker for inserting emojis, GIFs, and symbols.')
def emoji_tool() -> str:
    try:
        pg.hotkey('win', '.')
        return 'Emoji picker opened. Use mouse or keyboard to select emoji.'
    except Exception as e:
        return f'Emoji picker failed: {str(e)}'

@mcp.tool(name='Clipboard-History-Tool', description='Open Windows Clipboard History to view and paste previous clipboard items.')
def clipboard_history_tool() -> str:
    try:
        pg.hotkey('win', 'v')
        return 'Clipboard History opened. Enable it in Settings if not already enabled.'
    except Exception as e:
        return f'Clipboard History failed: {str(e)}'

@mcp.tool(name='Run-Dialog-Tool', description='Open Windows Run dialog and optionally execute a command.')
def run_dialog_tool(command: str = None) -> str:
    try:
        pg.hotkey('win', 'r')
        pg.sleep(0.5)
        
        if command:
            pg.typewrite(command, interval=0.03)
            pg.sleep(0.3)
            pg.press('enter')
            return f'Executed Run command: {command}'
        
        return 'Run dialog opened. Type command to execute.'
    except Exception as e:
        return f'Run dialog failed: {str(e)}'

@mcp.tool(name='File-Tool', description='Perform file operations: create, delete, rename, copy, move, or get file info.')
def file_tool(action: Literal['create', 'delete', 'rename', 'copy', 'move', 'info', 'read', 'write'], 
              path: str, 
              destination: str = None, 
              content: str = None,
              new_name: str = None) -> str:
    try:
        path = os_module.path.normpath(path)
        
        if action == 'info':
            if os_module.path.exists(path):
                stat = os_module.stat(path)
                is_dir = os_module.path.isdir(path)
                import datetime
                modified = datetime.datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
                created = datetime.datetime.fromtimestamp(stat.st_ctime).strftime('%Y-%m-%d %H:%M:%S')
                
                result = f"Path: {path}\n"
                result += f"Type: {'Directory' if is_dir else 'File'}\n"
                result += f"Size: {stat.st_size:,} bytes\n"
                result += f"Modified: {modified}\n"
                result += f"Created: {created}\n"
                
                if is_dir:
                    items = os_module.listdir(path)
                    result += f"Contents: {len(items)} items\n"
                    for item in items[:20]:
                        item_path = os_module.path.join(path, item)
                        prefix = "[DIR]" if os_module.path.isdir(item_path) else "[FILE]"
                        result += f"  {prefix} {item}\n"
                    if len(items) > 20:
                        result += f"  ... and {len(items) - 20} more items"
                
                return result
            else:
                return f'Path does not exist: {path}'
        
        elif action == 'read':
            if os_module.path.isfile(path):
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read(10000)  # Limit to 10KB
                return f'File contents:\n{content}'
            return f'Cannot read: {path}'
        
        elif action == 'write' and content is not None:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(content)
            return f'Written to: {path}'
        
        elif action == 'create':
            if content is not None:
                with open(path, 'w', encoding='utf-8') as f:
                    f.write(content)
                return f'File created: {path}'
            else:
                # Create empty file or directory
                if path.endswith('/') or path.endswith('\\'):
                    os_module.makedirs(path, exist_ok=True)
                    return f'Directory created: {path}'
                else:
                    open(path, 'a').close()
                    return f'Empty file created: {path}'
        
        elif action == 'delete':
            if os_module.path.isfile(path):
                os_module.remove(path)
                return f'File deleted: {path}'
            elif os_module.path.isdir(path):
                shutil.rmtree(path)
                return f'Directory deleted: {path}'
            return f'Path not found: {path}'
        
        elif action == 'rename' and new_name:
            new_path = os_module.path.join(os_module.path.dirname(path), new_name)
            os_module.rename(path, new_path)
            return f'Renamed to: {new_path}'
        
        elif action == 'copy' and destination:
            destination = os_module.path.normpath(destination)
            if os_module.path.isfile(path):
                shutil.copy2(path, destination)
            else:
                shutil.copytree(path, destination)
            return f'Copied to: {destination}'
        
        elif action == 'move' and destination:
            destination = os_module.path.normpath(destination)
            shutil.move(path, destination)
            return f'Moved to: {destination}'
        
        return 'Invalid action or missing parameters'
    except Exception as e:
        return f'File operation failed: {str(e)}'

@mcp.tool(name='Cursor-Position-Tool', description='Get current mouse cursor position on screen.')
def cursor_position_tool() -> str:
    try:
        x, y = pg.position()
        return f'Cursor position: ({x}, {y})'
    except Exception as e:
        return f'Failed to get cursor position: {str(e)}'

@mcp.tool(name='Screen-Info-Tool', description='Get information about connected displays/monitors.')
def screen_info_tool() -> str:
    try:
        ps_cmd = '''
        Add-Type -AssemblyName System.Windows.Forms
        $screens = [System.Windows.Forms.Screen]::AllScreens
        $i = 0
        foreach ($screen in $screens) {
            Write-Output "=== Monitor $i ==="
            Write-Output "Device: $($screen.DeviceName)"
            Write-Output "Primary: $($screen.Primary)"
            Write-Output "Bounds: $($screen.Bounds.Width) x $($screen.Bounds.Height)"
            Write-Output "Working Area: $($screen.WorkingArea.Width) x $($screen.WorkingArea.Height)"
            Write-Output "Position: ($($screen.Bounds.X), $($screen.Bounds.Y))"
            Write-Output ""
            $i++
        }
        '''
        result = subprocess.run(['powershell', '-Command', ps_cmd], capture_output=True, text=True, timeout=10)
        return result.stdout or 'Could not get screen info'
    except Exception as e:
        return f'Screen info failed: {str(e)}'

@mcp.tool(name='Text-Select-Tool', description='Select text in the active element using keyboard shortcuts. Supports select all, word, line, or from cursor to start/end.')
def text_select_tool(mode: Literal['all', 'word', 'line', 'to_start', 'to_end', 'left', 'right'] = 'all', count: int = 1) -> str:
    try:
        if mode == 'all':
            pg.hotkey('ctrl', 'a')
            return 'Selected all text'
        elif mode == 'word':
            pg.hotkey('ctrl', 'shift', 'right')
            return f'Selected word to the right'
        elif mode == 'line':
            pg.press('home')
            pg.hotkey('shift', 'end')
            return 'Selected current line'
        elif mode == 'to_start':
            pg.hotkey('ctrl', 'shift', 'home')
            return 'Selected from cursor to start'
        elif mode == 'to_end':
            pg.hotkey('ctrl', 'shift', 'end')
            return 'Selected from cursor to end'
        elif mode == 'left':
            for _ in range(count):
                pg.hotkey('shift', 'left')
            return f'Selected {count} character(s) to the left'
        elif mode == 'right':
            for _ in range(count):
                pg.hotkey('shift', 'right')
            return f'Selected {count} character(s) to the right'
        return 'Invalid mode'
    except Exception as e:
        return f'Text selection failed: {str(e)}'

@mcp.tool(name='Find-Replace-Tool', description='Open Find (Ctrl+F) or Find and Replace (Ctrl+H) dialog in the active application.')
def find_replace_tool(action: Literal['find', 'replace'] = 'find', search_text: str = None) -> str:
    try:
        if action == 'find':
            pg.hotkey('ctrl', 'f')
            pg.sleep(0.3)
            if search_text:
                pg.typewrite(search_text, interval=0.03)
            return 'Find dialog opened' + (f' with "{search_text}"' if search_text else '')
        elif action == 'replace':
            pg.hotkey('ctrl', 'h')
            pg.sleep(0.3)
            if search_text:
                pg.typewrite(search_text, interval=0.03)
            return 'Find and Replace dialog opened' + (f' with "{search_text}"' if search_text else '')
        return 'Invalid action'
    except Exception as e:
        return f'Find/Replace failed: {str(e)}'

@mcp.tool(name='Undo-Redo-Tool', description='Perform undo or redo operations in the active application.')
def undo_redo_tool(action: Literal['undo', 'redo'], times: int = 1) -> str:
    try:
        for _ in range(times):
            if action == 'undo':
                pg.hotkey('ctrl', 'z')
            elif action == 'redo':
                pg.hotkey('ctrl', 'y')
            pg.sleep(0.1)
        return f'{action.capitalize()} performed {times} time(s)'
    except Exception as e:
        return f'{action.capitalize()} failed: {str(e)}'

@mcp.tool(name='Zoom-Tool', description='Zoom in/out or reset zoom in the active application using Ctrl+/- or Ctrl+0.')
def zoom_tool(action: Literal['in', 'out', 'reset'], times: int = 1) -> str:
    try:
        if action == 'in':
            for _ in range(times):
                pg.hotkey('ctrl', '=')  # Ctrl++ is typically Ctrl+=
                pg.sleep(0.1)
            return f'Zoomed in {times} time(s)'
        elif action == 'out':
            for _ in range(times):
                pg.hotkey('ctrl', '-')
                pg.sleep(0.1)
            return f'Zoomed out {times} time(s)'
        elif action == 'reset':
            pg.hotkey('ctrl', '0')
            return 'Zoom reset to 100%'
        return 'Invalid action'
    except Exception as e:
        return f'Zoom failed: {str(e)}'


if __name__ == "__main__":
    mcp.run()
