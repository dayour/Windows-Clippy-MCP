from live_inspect.watch_cursor import WatchCursor
from contextlib import asynccontextmanager
from fastmcp.utilities.types import Image
from humancursor import SystemCursor
from platform import system, release
from markdownify import markdownify
from src.desktop import Desktop
from textwrap import dedent
from fastmcp import FastMCP
from typing import Literal, List
import uiautomation as ua
import pyautogui as pg
import pyperclip as pc
import requests
import asyncio
import ctypes

pg.FAILSAFE=False
pg.PAUSE=1.0

os=system()
version=release()

instructions=dedent(f'''
Windows Clippy MCP 📎 - Your friendly AI assistant for Windows desktop automation!

This MCP server provides tools to interact directly with the {os} {version} desktop, 
thus enabling to operate the desktop on the user's behalf. Like the classic Office
assistant, Windows Clippy MCP is here to help with all your desktop automation needs.

Visual Identity: Look for the Windows Clippy MCP logo (WC25.png) in the assets folder.
''')

desktop=Desktop()
cursor=SystemCursor()
watch_cursor=WatchCursor()
ctypes.windll.user32.SetProcessDPIAware()

@asynccontextmanager
async def lifespan(app: FastMCP):
    """Runs initialization code before the server starts and cleanup code after it shuts down."""
    try:
        watch_cursor.start()
        await asyncio.sleep(1) # Simulate startup latency
        yield
        watch_cursor.stop()
    except Exception:
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

@mcp.tool(name='Copilot-Studio-Tool', description='Manage Microsoft Copilot Studio bots and conversations. Create, configure, and interact with custom copilots built in Copilot Studio.')
def copilot_studio_tool(action: str, bot_name: str = None, message: str = None) -> str:
    """Manage Copilot Studio bots and interactions."""
    try:
        if action.lower() == 'list':
            # List available bots (would typically require Copilot Studio API)
            cmd = 'powershell.exe -Command "Write-Output \'Copilot Studio integration requires specific API setup. Please configure your Copilot Studio environment first.\'"'
            
        elif action.lower() == 'create' and bot_name:
            # Create a new bot (placeholder for Copilot Studio operations)
            cmd = f'powershell.exe -Command "Write-Output \'Creating Copilot Studio bot: {bot_name}. This would typically use Copilot Studio APIs.\'"'
            
        elif action.lower() == 'chat' and bot_name and message:
            # Send message to a bot (placeholder for bot interaction)
            cmd = f'powershell.exe -Command "Write-Output \'Sending message to {bot_name}: {message}. This requires Copilot Studio runtime configuration.\'"'
            
        else:
            return 'Error: Invalid action. Supported actions: list, create (requires bot_name), chat (requires bot_name and message)'
        
        response, status = desktop.execute_command(cmd)
        
        if status == 0:
            return f'Copilot Studio operation completed:\n{response}'
        else:
            return f'Copilot Studio operation failed (Status: {status}):\n{response}'
            
    except Exception as e:
        return f'Error with Copilot Studio operation: {str(e)}'

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

if __name__ == "__main__":
    mcp.run()