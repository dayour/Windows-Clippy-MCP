import subprocess
import psutil
import uiautomation as ua
import pyautogui as pg
from dataclasses import dataclass
from typing import Optional, Tuple, List
from PIL import Image
import io
import base64


@dataclass
class TreeState:
    interactive_elements: List[ua.Control]
    informative_elements: List[ua.Control]
    scrollable_elements: List[ua.Control]
    
    def interactive_elements_to_string(self) -> str:
        if not self.interactive_elements:
            return ""
        elements = []
        for elem in self.interactive_elements:
            try:
                x, y = elem.BoundingRectangle[:2]
                elements.append(f"- {elem.Name or 'Unnamed'} ({elem.ControlTypeName}) at ({x}, {y})")
            except:
                continue
        return "\n".join(elements)
    
    def informative_elements_to_string(self) -> str:
        if not self.informative_elements:
            return ""
        elements = []
        for elem in self.informative_elements:
            try:
                text = elem.Name or elem.Value or "No text"
                elements.append(f"- {text}")
            except:
                continue
        return "\n".join(elements)
    
    def scrollable_elements_to_string(self) -> str:
        if not self.scrollable_elements:
            return ""
        elements = []
        for elem in self.scrollable_elements:
            try:
                x, y = elem.BoundingRectangle[:2]
                elements.append(f"- {elem.Name or 'Scrollable area'} at ({x}, {y})")
            except:
                continue
        return "\n".join(elements)


@dataclass 
class DesktopState:
    active_app: str
    apps: List[str]
    tree_state: TreeState
    screenshot: Optional[bytes] = None
    
    def active_app_to_string(self) -> str:
        return self.active_app
    
    def apps_to_string(self) -> str:
        return "\n".join(f"- {app}" for app in self.apps)


class Desktop:
    def __init__(self):
        self.ua = ua
        
    def launch_app(self, name: str) -> Tuple[str, int]:
        """Launch an application by name"""
        try:
            # Try different launch methods
            result = subprocess.run(['powershell', '-Command', f'Start-Process "{name}"'], 
                                  capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                return f"Launched {name}", 0
            else:
                # Try alternative method with explorer
                result = subprocess.run(['explorer', name], 
                                      capture_output=True, text=True, timeout=10)
                return f"Launched {name}", result.returncode
        except Exception as e:
            return f"Failed to launch {name}: {str(e)}", 1
    
    def execute_command(self, command: str) -> Tuple[str, int]:
        """Execute PowerShell command"""
        try:
            result = subprocess.run(['powershell', '-Command', command], 
                                  capture_output=True, text=True, timeout=30)
            return result.stdout or result.stderr, result.returncode
        except Exception as e:
            return str(e), 1
    
    def switch_app(self, name: str) -> Tuple[str, int]:
        """Switch to an application window"""
        try:
            # First try to find by window title
            windows = ua.FindWindows(lambda win, _: name.lower() in win.Name.lower() if win.Name else False)
            if windows:
                window = windows[0]
                window.SetForegroundWindow()
                return f"Switched to {name}", 0
            
            # Then try to find by process name
            for proc in psutil.process_iter(['pid', 'name']):
                try:
                    proc_name = proc.info['name'].lower()
                    if (name.lower() in proc_name or 
                        proc_name.startswith(name.lower()) or
                        proc_name.replace('.exe', '') == name.lower()):
                        windows = ua.FindWindows(processId=proc.info['pid'])
                        if windows:
                            for window in windows:
                                if window.IsTopLevel and window.Visible:
                                    window.SetForegroundWindow()
                                    return f"Switched to {name}", 0
                except (psutil.NoSuchProcess, psutil.AccessDenied, AttributeError):
                    continue
            
            return f"Could not find window for {name}", 1
        except Exception as e:
            return f"Failed to switch to {name}: {str(e)}", 1
    
    def get_state(self, use_vision: bool = False) -> DesktopState:
        """Get current desktop state"""
        try:
            # Get active window
            active_window = ua.GetForegroundWindow()
            active_app = active_window.Name if active_window else "Unknown"
            
            # Get all open applications
            apps = []
            for proc in psutil.process_iter(['pid', 'name']):
                try:
                    if proc.info['name'].endswith('.exe'):
                        app_name = proc.info['name'][:-4]  # Remove .exe
                        if app_name not in apps:
                            apps.append(app_name)
                except:
                    continue
            
            # Get UI elements
            interactive_elements = []
            informative_elements = []
            scrollable_elements = []
            
            try:
                if active_window:
                    # Find interactive elements (buttons, text fields, etc.)
                    buttons = active_window.GetChildren(lambda x: x.ControlType in [
                        ua.ControlType.ButtonControl, ua.ControlType.EditControl,
                        ua.ControlType.ComboBoxControl, ua.ControlType.CheckBoxControl
                    ])
                    interactive_elements.extend(buttons[:20])  # Limit to prevent overflow
                    
                    # Find informative elements (text, labels)
                    texts = active_window.GetChildren(lambda x: x.ControlType in [
                        ua.ControlType.TextControl, ua.ControlType.StaticTextControl
                    ])
                    informative_elements.extend(texts[:20])
                    
                    # Find scrollable elements
                    scrolls = active_window.GetChildren(lambda x: x.ControlType in [
                        ua.ControlType.ScrollBarControl, ua.ControlType.ListControl
                    ])
                    scrollable_elements.extend(scrolls[:10])
            except:
                pass
            
            tree_state = TreeState(
                interactive_elements=interactive_elements,
                informative_elements=informative_elements,
                scrollable_elements=scrollable_elements
            )
            
            screenshot_data = None
            if use_vision:
                try:
                    screenshot = pg.screenshot()
                    img_buffer = io.BytesIO()
                    screenshot.save(img_buffer, format='PNG')
                    screenshot_data = img_buffer.getvalue()
                except:
                    pass
            
            return DesktopState(
                active_app=active_app,
                apps=apps,
                tree_state=tree_state,
                screenshot=screenshot_data
            )
        except Exception as e:
            # Return minimal state on error
            return DesktopState(
                active_app="Error getting state",
                apps=[],
                tree_state=TreeState([], [], []),
                screenshot=None
            )
    
    def get_element_under_cursor(self) -> ua.Control:
        """Get UI element under current cursor position"""
        try:
            x, y = pg.position()
            element = ua.ControlFromPoint(x, y)
            return element if element else ua.Control()
        except:
            return ua.Control()