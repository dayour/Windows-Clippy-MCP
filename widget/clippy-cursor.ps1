#requires -Version 7.0
<#
.SYNOPSIS
    Clippy Cursor - Native mouse pointer replacement with AI-powered context menu.
.DESCRIPTION
    Replaces the Windows system cursor with a Clippy icon and provides a Ctrl+Right-Click
    context menu with AI quick actions:
      - Explain This     (Ctrl+Shift+E)  - screenshot region + analyze
      - Summarize Screen (Ctrl+Shift+S)  - full-screen + summarize
      - Extract Text     (Ctrl+Shift+T)  - OCR-style text extraction
      - Read Aloud, Debug UI, Accessibility Check

    Streams responses into a floating adaptive-card-style WPF widget.

    Integration modes:
      - Widget-hosted:  dot-sourced by clippy-widget.ps1 — reuses the existing
                        ToolbarContextMenu style, Invoke-OnUiThread, Write-WidgetDebugLog,
                        session host bridge, and CopilotEvent streaming pipeline.
      - Standalone:     pwsh -File clippy-cursor.ps1 -Standalone
                        Self-contained; captures screenshots and shows a placeholder
                        until an AI provider is configured.
.NOTES
    Cursor replacement uses SetSystemCursor/SPI_SETCURSORS (Win32).
    Ctrl+Right-Click interception uses a low-level mouse hook (WH_MOUSE_LL).
    Keyboard shortcuts use a low-level keyboard hook (WH_KEYBOARD_LL).
    All hooks are cleaned up on Stop-ClippyCursorMode or process exit.
#>

param(
    [switch]$Standalone,
    [string]$AssetsDir
)

# ── Resolve asset directory ─────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($AssetsDir)) {
    $AssetsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
    if (-not (Test-Path $AssetsDir)) {
        $AssetsDir = Join-Path $PSScriptRoot '..\assets'
    }
}

# ── Assemblies (standalone only; widget already loaded these) ───────
if ($Standalone) {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
}

# ── Detect widget-hosted mode ───────────────────────────────────────
# When dot-sourced by clippy-widget.ps1, these functions already exist.
$script:IsWidgetHosted = (
    (Get-Command 'script:New-ToolbarContextMenu' -ErrorAction SilentlyContinue) -and
    (Get-Command 'script:New-ToolbarMenuItem' -ErrorAction SilentlyContinue)
)

# ── Win32 interop for cursor replacement ────────────────────────────
if (-not ([System.Management.Automation.PSTypeName]'ClippyCursor.CursorApi').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClippyCursor {
    public static class CursorApi {
        public const uint OCR_NORMAL = 32512;
        public const uint SPI_SETCURSORS = 0x0057;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetSystemCursor(IntPtr hcur, uint id);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr LoadCursorFromFile(string lpFileName);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr CopyIcon(IntPtr hIcon);

        [DllImport("user32.dll")]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam,
            IntPtr pvParam, uint fWinIni);

        public static void RestoreDefaultCursors() {
            SystemParametersInfo(SPI_SETCURSORS, 0, IntPtr.Zero, 0);
        }
    }
}
'@
}

# ── Low-level mouse hook (Ctrl+Right-Click interception) ────────────
if (-not ([System.Management.Automation.PSTypeName]'ClippyCursor.MouseHook').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClippyCursor {
    public class MouseHook : IDisposable {
        private const int WH_MOUSE_LL = 14;
        private const int WM_RBUTTONUP = 0x0205;

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private GCHandle _procHandle;  // prevent GC of the delegate

        public event EventHandler<MouseEventInfo> RightClick;

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct MSLLHOOKSTRUCT {
            public int X;
            public int Y;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        public class MouseEventInfo : EventArgs {
            public int X { get; set; }
            public int Y { get; set; }
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn,
            IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern short GetKeyState(int nVirtKey);

        private const int VK_CONTROL = 0x11;

        public MouseHook() {
            _proc = new LowLevelMouseProc(HookCallback);
            _procHandle = GCHandle.Alloc(_proc);  // prevent GC
        }

        public IntPtr Install() {
            _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc,
                GetModuleHandle("user32"), 0);
            return _hookId;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
            if (nCode >= 0 && (int)wParam == WM_RBUTTONUP) {
                bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
                if (ctrl) {
                    var hookStruct = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(
                        lParam, typeof(MSLLHOOKSTRUCT));
                    RightClick?.Invoke(this,
                        new MouseEventInfo { X = hookStruct.X, Y = hookStruct.Y });
                    return (IntPtr)1;  // Suppress default right-click
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }

        public void Dispose() {
            if (_hookId != IntPtr.Zero) {
                UnhookWindowsHookEx(_hookId);
                _hookId = IntPtr.Zero;
            }
            if (_procHandle.IsAllocated) _procHandle.Free();
        }
    }
}
'@
}

# ── Low-level keyboard hook (Ctrl+Shift hotkeys) ───────────────────
if (-not ([System.Management.Automation.PSTypeName]'ClippyCursor.KeyboardHook').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClippyCursor {
    public class KeyboardHook : IDisposable {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int VK_CONTROL = 0x11;
        private const int VK_SHIFT   = 0x10;

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelKeyboardProc _proc;
        private GCHandle _procHandle;

        public event EventHandler<int> HotkeyPressed;

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn,
            IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern short GetKeyState(int nVirtKey);

        public KeyboardHook() {
            _proc = new LowLevelKeyboardProc(HookCallback);
            _procHandle = GCHandle.Alloc(_proc);
        }

        public IntPtr Install() {
            _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc,
                GetModuleHandle("user32"), 0);
            return _hookId;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
            if (nCode >= 0 && wParam == (IntPtr)WM_KEYDOWN) {
                int vkCode = Marshal.ReadInt32(lParam);
                bool ctrl  = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
                bool shift = (GetKeyState(VK_SHIFT)   & 0x8000) != 0;

                if (ctrl && shift) {
                    HotkeyPressed?.Invoke(this, vkCode);
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }

        public void Dispose() {
            if (_hookId != IntPtr.Zero) {
                UnhookWindowsHookEx(_hookId);
                _hookId = IntPtr.Zero;
            }
            if (_procHandle.IsAllocated) _procHandle.Free();
        }
    }
}
'@
}

# ── Module state ────────────────────────────────────────────────────
$script:ClippyCursorActive       = $false
$script:ClippyCursorFile         = $null
$script:MouseHookInstance        = $null
$script:KeyboardHookInstance     = $null
$script:CursorContextMenu        = $null
$script:ResponseWidgetWindow     = $null
$script:CursorAnalysisActive     = $false
$script:CursorAnalysisWidget     = $null
$script:CursorAnalysisTabId      = $null
$script:CursorAnalysisId         = $null
$script:CursorCaptureDir         = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Windows-Clippy-MCP\captures'
$script:CursorConfigDir          = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Windows-Clippy-MCP'
$script:CursorMaxCaptureFiles    = 20
$script:CursorContextSchemaVersion = '1.0.0'

# VK codes for hotkeys
$script:VK_E = 0x45
$script:VK_S = 0x53
$script:VK_T = 0x54

# ── Action definitions ──────────────────────────────────────────────
$script:CursorActions = [ordered]@{
    explain = @{
        Label    = 'Explain This'
        Gesture  = 'Ctrl+Shift+E'
        Region   = $true
        Prompt   = 'Look at this screenshot. Explain what is shown on screen in clear, concise language. Describe the application, visible UI elements, and what the user appears to be doing. Be helpful like the classic Clippy assistant.'
    }
    summarize = @{
        Label    = 'Summarize Screen'
        Gesture  = 'Ctrl+Shift+S'
        Region   = $false
        Prompt   = 'Summarize the content visible on this screen. Focus on the key information, text content, and important visual elements. Be concise.'
    }
    extract = @{
        Label    = 'Extract Text'
        Gesture  = 'Ctrl+Shift+T'
        Region   = $true
        Prompt   = 'Extract all text visible in this screenshot. Return it as clean, structured text preserving the layout and hierarchy as much as possible.'
    }
    'read-aloud' = @{
        Label    = 'Read Aloud'
        Gesture  = $null
        Region   = $true
        Prompt   = 'Extract and read all visible text content from this screenshot, organized by visual hierarchy (headings, body text, labels, etc).'
    }
    debug = @{
        Label    = 'Debug UI'
        Gesture  = $null
        Region   = $true
        Prompt   = 'Analyze this screenshot as a developer debugging the UI. Identify any visual bugs, layout issues, overlapping elements, truncated text, or inconsistencies. Suggest fixes.'
    }
    accessibility = @{
        Label    = 'Accessibility Check'
        Gesture  = $null
        Region   = $true
        Prompt   = 'Analyze this screenshot for accessibility issues. Check contrast ratios, text sizes, interactive element visibility, and suggest improvements per WCAG 2.1 AA guidelines.'
    }
}

# ── Logging (delegates to widget debug log when hosted) ─────────────
function script:Write-CursorLog {
    param([string]$Message)

    if ($script:IsWidgetHosted) {
        try { script:Write-WidgetDebugLog "CURSOR: $Message" } catch {}
    } else {
        $logPath = Join-Path $script:CursorConfigDir 'cursor-debug.log'
        try {
            if (-not (Test-Path $script:CursorConfigDir)) {
                New-Item -ItemType Directory -Path $script:CursorConfigDir -Force | Out-Null
            }
            Add-Content -Path $logPath -Value "[$(Get-Date -Format 'o')] $Message"
        } catch {}
    }
}

# ── Cursor file generation (pure PowerShell, no System.Drawing) ─────
function script:New-ClippyCursorFile {
    # Prefer the 32px icon; fall back to 48px
    foreach ($name in @('clippy25_32.png', 'clippy25_48.png')) {
        $pngPath = Join-Path $AssetsDir $name
        if (Test-Path $pngPath) { break }
        $pngPath = $null
    }

    if (-not $pngPath) {
        script:Write-CursorLog "No Clippy PNG found in $AssetsDir"
        return $null
    }

    if (-not (Test-Path $script:CursorConfigDir)) {
        New-Item -ItemType Directory -Path $script:CursorConfigDir -Force | Out-Null
    }

    $curPath = Join-Path $script:CursorConfigDir 'clippy-cursor.cur'

    try {
        # Read the raw PNG bytes — we embed them directly in the .cur container.
        # The PNG is already 32x32 from the asset pipeline, so no rescaling needed.
        $pngData = [System.IO.File]::ReadAllBytes($pngPath)

        # ICO/CUR binary format: 6-byte header + 16-byte directory entry + image data
        $hotspotX = 4
        $hotspotY = 2
        $fs = [System.IO.File]::Create($curPath)
        $bw = [System.IO.BinaryWriter]::new($fs)

        # Header (6 bytes)
        $bw.Write([uint16]0)                # Reserved
        $bw.Write([uint16]2)                # Type = 2 (cursor)
        $bw.Write([uint16]1)                # Image count = 1

        # Directory entry (16 bytes)
        $bw.Write([byte]32)                 # Width
        $bw.Write([byte]32)                 # Height
        $bw.Write([byte]0)                  # Color palette size
        $bw.Write([byte]0)                  # Reserved
        $bw.Write([uint16]$hotspotX)        # Hotspot X
        $bw.Write([uint16]$hotspotY)        # Hotspot Y
        $bw.Write([uint32]$pngData.Length)  # Image data size
        $bw.Write([uint32]22)               # Offset to data (6 header + 16 directory)

        # Image data (raw PNG)
        $bw.Write($pngData)
        $bw.Flush()
        $bw.Close()
        $fs.Close()

        if (Test-Path $curPath) {
            script:Write-CursorLog "Created cursor file: $curPath ($($pngData.Length) bytes PNG from $pngPath)"
            return $curPath
        }
    } catch {
        script:Write-CursorLog "New-ClippyCursorFile failed: $($_.Exception.Message)"
        if ($bw) { try { $bw.Close() } catch {} }
        if ($fs) { try { $fs.Close() } catch {} }
    }

    return $null
}

# ── Cursor enable/disable ──────────────────────────────────────────
function script:Enable-ClippyCursor {
    if ($script:ClippyCursorActive) { return $true }

    $curFile = script:New-ClippyCursorFile
    if (-not $curFile) { return $false }

    $script:ClippyCursorFile = $curFile
    $hCursor = [ClippyCursor.CursorApi]::LoadCursorFromFile($curFile)
    if ($hCursor -eq [IntPtr]::Zero) {
        script:Write-CursorLog "LoadCursorFromFile returned NULL for $curFile"
        return $false
    }

    # SetSystemCursor takes ownership of the handle, so we must CopyIcon first
    $hCopy = [ClippyCursor.CursorApi]::CopyIcon($hCursor)
    if ($hCopy -eq [IntPtr]::Zero) {
        script:Write-CursorLog "CopyIcon failed"
        return $false
    }

    $ok = [ClippyCursor.CursorApi]::SetSystemCursor($hCopy, [ClippyCursor.CursorApi]::OCR_NORMAL)
    if (-not $ok) {
        script:Write-CursorLog "SetSystemCursor failed (may require elevation)"
        return $false
    }

    $script:ClippyCursorActive = $true
    script:Write-CursorLog "Clippy cursor activated ($curFile)"
    return $true
}

function script:Disable-ClippyCursor {
    if (-not $script:ClippyCursorActive) { return }

    [ClippyCursor.CursorApi]::RestoreDefaultCursors()
    $script:ClippyCursorActive = $false
    script:Write-CursorLog "Default cursor restored"
}

# ── Screen capture ──────────────────────────────────────────────────
function script:Ensure-CaptureDirectory {
    if (-not (Test-Path $script:CursorCaptureDir)) {
        New-Item -ItemType Directory -Path $script:CursorCaptureDir -Force | Out-Null
    }
}

function script:Prune-OldCaptures {
    # Keep only the N most recent capture files to prevent disk bloat.
    try {
        $files = Get-ChildItem -Path $script:CursorCaptureDir -Filter 'clippy-*.png' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending
        if ($files.Count -gt $script:CursorMaxCaptureFiles) {
            $files | Select-Object -Skip $script:CursorMaxCaptureFiles |
                ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

# ── Semantic screen context scanning ────────────────────────────────
function script:Ensure-ScreenContextInterop {
    if (([System.Management.Automation.PSTypeName]'ClippyCursor.ScreenContextApi').Type) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ClippyCursor {
    public static class ScreenContextApi {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        public static List<Dictionary<string, object>> GetWindows() {
            var results = new List<Dictionary<string, object>>();
            var foreground = GetForegroundWindow();
            var order = 0;
            EnumWindows((hWnd, lParam) => {
                order++;
                if (!IsWindowVisible(hWnd)) return true;

                var titleBuilder = new StringBuilder(512);
                GetWindowText(hWnd, titleBuilder, titleBuilder.Capacity);
                var title = titleBuilder.ToString();
                if (string.IsNullOrWhiteSpace(title)) return true;

                RECT rect;
                if (!GetWindowRect(hWnd, out rect)) return true;
                var width = rect.Right - rect.Left;
                var height = rect.Bottom - rect.Top;
                if (width <= 0 || height <= 0) return true;

                var classBuilder = new StringBuilder(256);
                GetClassName(hWnd, classBuilder, classBuilder.Capacity);
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);

                var row = new Dictionary<string, object>();
                row["zOrder"] = order;
                row["hwnd"] = hWnd.ToInt64();
                row["title"] = title;
                row["className"] = classBuilder.ToString();
                row["processId"] = (int)pid;
                row["isForeground"] = hWnd == foreground;
                row["bounds"] = new Dictionary<string, object> {
                    { "x", rect.Left },
                    { "y", rect.Top },
                    { "width", width },
                    { "height", height },
                    { "right", rect.Right },
                    { "bottom", rect.Bottom }
                };
                results.Add(row);
                return true;
            }, IntPtr.Zero);
            return results;
        }
    }
}
'@
}

function script:Get-UiAutomationPatternNames {
    param([System.Windows.Automation.AutomationElement]$Element)

    $patternMap = [ordered]@{
        Invoke = [System.Windows.Automation.InvokePattern]::Pattern
        Value = [System.Windows.Automation.ValuePattern]::Pattern
        Text = [System.Windows.Automation.TextPattern]::Pattern
        Selection = [System.Windows.Automation.SelectionPattern]::Pattern
        SelectionItem = [System.Windows.Automation.SelectionItemPattern]::Pattern
        Scroll = [System.Windows.Automation.ScrollPattern]::Pattern
        ExpandCollapse = [System.Windows.Automation.ExpandCollapsePattern]::Pattern
        Toggle = [System.Windows.Automation.TogglePattern]::Pattern
        RangeValue = [System.Windows.Automation.RangeValuePattern]::Pattern
        Grid = [System.Windows.Automation.GridPattern]::Pattern
        Table = [System.Windows.Automation.TablePattern]::Pattern
    }

    $patterns = @()
    foreach ($entry in $patternMap.GetEnumerator()) {
        try {
            if ($Element.GetCurrentPattern($entry.Value)) {
                $patterns += $entry.Key
            }
        } catch {}
    }
    return $patterns
}

function script:Get-UiAutomationSnapshot {
    param([int]$MaxElements = 500)

    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
    } catch {
        return @()
    }

    $items = [System.Collections.Generic.List[object]]::new()
    try {
        $all = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        $count = [Math]::Min($all.Count, $MaxElements)
        for ($i = 0; $i -lt $count; $i++) {
            $el = $all[$i]
            $rect = $el.Current.BoundingRectangle
            if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) { continue }

            $name = [string]$el.Current.Name
            $automationId = [string]$el.Current.AutomationId
            $controlType = [string]$el.Current.ControlType.ProgrammaticName
            if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($automationId)) { continue }

            $patterns = @(script:Get-UiAutomationPatternNames -Element $el)
            $interactable = $patterns.Count -gt 0 -or $el.Current.IsKeyboardFocusable
            $items.Add([ordered]@{
                index = $items.Count
                name = $name
                automationId = $automationId
                controlType = $controlType
                className = [string]$el.Current.ClassName
                processId = [int]$el.Current.ProcessId
                isEnabled = [bool]$el.Current.IsEnabled
                isKeyboardFocusable = [bool]$el.Current.IsKeyboardFocusable
                isInteractable = [bool]$interactable
                patterns = $patterns
                bounds = [ordered]@{
                    x = [int]$rect.X
                    y = [int]$rect.Y
                    width = [int]$rect.Width
                    height = [int]$rect.Height
                    right = [int]$rect.Right
                    bottom = [int]$rect.Bottom
                }
            })
        }
    } catch {
        script:Write-CursorLog "UI Automation snapshot failed: $($_.Exception.Message)"
    }

    return @($items)
}

function script:Get-ProcessNameSafe {
    param([int]$ProcessId)
    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName
    } catch {
        return $null
    }
}

function script:Get-ClippyActionContract {
    param([string]$ActionId)

    switch ($ActionId) {
        'explain' {
            return 'Explain the visible applications, layers, user task, and the most relevant interactable UI elements.'
        }
        'summarize' {
            return 'Summarize the foreground app, background layers, visible content, and likely user workflow.'
        }
        'extract' {
            return 'Extract visible text from screenshot and UI Automation names/values. Preserve hierarchy where possible.'
        }
        'debug' {
            return 'Identify UI defects: truncation, overlap, unreachable controls, disabled interactions, odd z-order, and layout risks.'
        }
        'accessibility' {
            return 'Assess accessibility using UI Automation data: names, focusability, enabled state, control types, and visible hierarchy.'
        }
        'read-aloud' {
            return 'Extract readable content and present it in a screen-reader friendly order.'
        }
        default {
            return 'Analyze the screen context and provide concise, useful guidance.'
        }
    }
}

function script:Convert-ScreenContextToMarkdown {
    param([object]$Context)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Clippy Screen Context")
    $lines.Add("")
    $lines.Add(('- **Action:** {0} / {1}' -f $Context.action.id, $Context.action.label))
    $lines.Add(('- **Captured:** {0}' -f $Context.capture.timestamp))
    $lines.Add(('- **Screenshot:** `{0}`' -f $Context.capture.imagePath))
    $lines.Add(('- **Screen:** {0}x{1}' -f $Context.screen.width, $Context.screen.height))
    $lines.Add("")

    $foreground = @($Context.windows | Where-Object { $_.isForeground } | Select-Object -First 1)
    if ($foreground.Count -gt 0) {
        $fg = $foreground[0]
        $lines.Add("## Foreground Layer")
        $lines.Add("")
        $lines.Add(('- **Title:** {0}' -f $fg.title))
        $lines.Add(('- **Process:** {0} ({1})' -f $fg.processName, $fg.processId))
        $lines.Add(('- **Bounds:** x={0}, y={1}, w={2}, h={3}' -f $fg.bounds.x, $fg.bounds.y, $fg.bounds.width, $fg.bounds.height))
        $lines.Add("")
    }

    $lines.Add("## Visible Window Layers")
    $lines.Add("")
    foreach ($window in @($Context.windows | Select-Object -First 20)) {
        $marker = if ($window.isForeground) { "foreground" } else { "visible" }
        $lines.Add(('- **#{0} {1}** `{2}` - {3} - x={4}, y={5}, w={6}, h={7}' -f $window.zOrder, $marker, $window.title, $window.processName, $window.bounds.x, $window.bounds.y, $window.bounds.width, $window.bounds.height))
    }
    $lines.Add("")

    $interactables = @($Context.uiAutomation.elements | Where-Object { $_.isInteractable } | Select-Object -First 80)
    $lines.Add("## Interactable UI Elements")
    $lines.Add("")
    if ($interactables.Count -eq 0) {
        $lines.Add("_No interactable UI Automation elements were discovered._")
    } else {
        foreach ($el in $interactables) {
            $label = if ($el.name) { $el.name } elseif ($el.automationId) { $el.automationId } else { "(unnamed)" }
            $patterns = if ($el.patterns -and $el.patterns.Count -gt 0) { [string]::Join(", ", @($el.patterns)) } else { "focusable=$($el.isKeyboardFocusable)" }
            $lines.Add(('- `{0}` - {1} - {2} - x={3}, y={4}, w={5}, h={6}' -f $label, $el.controlType, $patterns, $el.bounds.x, $el.bounds.y, $el.bounds.width, $el.bounds.height))
        }
    }
    $lines.Add("")

    $lines.Add("## Recommended Analysis Contract")
    $lines.Add("")
    $lines.Add($Context.action.contract)
    $lines.Add("")

    return ($lines -join "`n")
}

function script:New-ClippyScreenContext {
    param(
        [Parameter(Mandatory)][string]$CapturePath,
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$ScreenX,
        [Parameter(Mandatory)][int]$ScreenY,
        [Parameter(Mandatory)][string]$Prompt
    )

    script:Ensure-ScreenContextInterop
    $captureItem = Get-Item -LiteralPath $CapturePath
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $windows = @([ClippyCursor.ScreenContextApi]::GetWindows() | ForEach-Object {
        $processId = [int]$_['processId']
        [ordered]@{
            zOrder = [int]$_['zOrder']
            hwnd = [int64]$_['hwnd']
            title = [string]$_['title']
            className = [string]$_['className']
            processId = $processId
            processName = (script:Get-ProcessNameSafe -ProcessId $processId)
            isForeground = [bool]$_['isForeground']
            bounds = $_['bounds']
        }
    })

    $uiElements = @(script:Get-UiAutomationSnapshot)
    $context = [ordered]@{
        schema = 'https://darbotlabs.github.io/windows-clippy-mcp/screen-context/v1'
        schemaVersion = $script:CursorContextSchemaVersion
        capture = [ordered]@{
            imagePath = $captureItem.FullName
            imageBytes = [int64]$captureItem.Length
            timestamp = (Get-Date).ToString('o')
            cursor = [ordered]@{ x = $ScreenX; y = $ScreenY }
        }
        action = [ordered]@{
            id = $ActionId
            label = $Label
            prompt = $Prompt
            contract = (script:Get-ClippyActionContract -ActionId $ActionId)
        }
        screen = [ordered]@{
            width = [int]$bounds.Width
            height = [int]$bounds.Height
            left = [int]$bounds.Left
            top = [int]$bounds.Top
        }
        windows = $windows
        uiAutomation = [ordered]@{
            elementCount = $uiElements.Count
            interactableCount = @($uiElements | Where-Object { $_.isInteractable }).Count
            elements = $uiElements
        }
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($CapturePath)
    $jsonPath = Join-Path $script:CursorCaptureDir "$base.screen-context.json"
    $mdPath = Join-Path $script:CursorCaptureDir "$base.screen-context.md"
    $context | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    script:Convert-ScreenContextToMarkdown -Context ([pscustomobject]$context) | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $mdPath
        Context = $context
    }
}

function script:Capture-ScreenRegion {
    param(
        [int]$CenterX,
        [int]$CenterY,
        [int]$Width  = 800,
        [int]$Height = 600
    )

    script:Ensure-CaptureDirectory

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $left   = [Math]::Max(0, $CenterX - [int]($Width / 2))
    $top    = [Math]::Max(0, $CenterY - [int]($Height / 2))
    $w      = [Math]::Min($bounds.Width - $left, $Width)
    $h      = [Math]::Min($bounds.Height - $top, $Height)

    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = [System.Drawing.Bitmap]::new($w, $h)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($left, $top, 0, 0, [System.Drawing.Size]::new($w, $h))

        $path = Join-Path $script:CursorCaptureDir "clippy-region-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)

        script:Prune-OldCaptures
        return $path
    } catch {
        script:Write-CursorLog "Capture-ScreenRegion failed: $($_.Exception.Message)"
        return $null
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap)   { $bitmap.Dispose() }
    }
}

function script:Capture-FullScreen {
    script:Ensure-CaptureDirectory

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(0, 0, 0, 0, $bounds.Size)

        $path = Join-Path $script:CursorCaptureDir "clippy-fullscreen-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)

        script:Prune-OldCaptures
        return $path
    } catch {
        script:Write-CursorLog "Capture-FullScreen failed: $($_.Exception.Message)"
        return $null
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap)   { $bitmap.Dispose() }
    }
}

# ── Floating response widget ───────────────────────────────────────
function script:Get-DpiScale {
    # Returns (scaleX, scaleY) for converting physical pixels to WPF units.
    # Falls back to 1.0 if no visual source is available.
    $scaleX = 1.0
    $scaleY = 1.0

    $visual = $null
    if ($script:IsWidgetHosted -and $script:Widget) {
        $visual = $script:Widget
    } elseif ([System.Windows.Application]::Current -and [System.Windows.Application]::Current.MainWindow) {
        $visual = [System.Windows.Application]::Current.MainWindow
    }

    if ($visual) {
        try {
            $source = [System.Windows.PresentationSource]::FromVisual($visual)
            if ($source -and $source.CompositionTarget) {
                $scaleX = $source.CompositionTarget.TransformFromDevice.M11
                $scaleY = $source.CompositionTarget.TransformFromDevice.M22
            }
        } catch {}
    }

    return @{ X = $scaleX; Y = $scaleY }
}

function script:New-ResponseWidget {
    param(
        [double]$ScreenX,
        [double]$ScreenY,
        [string]$Title = 'Clippy AI'
    )

    $dpi = script:Get-DpiScale
    $wpfX = $ScreenX * $dpi.X
    $wpfY = $ScreenY * $dpi.Y

    # Escape the title for safe XAML embedding
    $safeTitle = [System.Security.SecurityElement]::Escape($Title)

    [xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Clippy Response" Width="420" Height="340"
    WindowStyle="None" AllowsTransparency="True"
    Background="Transparent" Topmost="True"
    ShowInTaskbar="False" ResizeMode="CanResizeWithGrip"
    WindowStartupLocation="Manual"
    Left="$wpfX" Top="$wpfY">
  <Border Background="#F0101020"
          BorderBrush="#FF5B5FC7"
          BorderThickness="1.5"
          CornerRadius="14"
          Margin="8">
    <Border.Effect>
      <DropShadowEffect Color="#000" BlurRadius="24" ShadowDepth="4" Opacity="0.65"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="38"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Title bar -->
      <Border x:Name="ResponseTitleBar"
              Grid.Row="0"
              Background="#FF16162A"
              CornerRadius="14,14,0,0">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
            <TextBlock x:Name="ResponseTitle" Text="$safeTitle"
                       Foreground="#FFCCCCCC"
                       FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold"
                       VerticalAlignment="Center"/>
            <TextBlock x:Name="ResponseSubtitle" Text=""
                       Foreground="#FF6B6B8D"
                       FontFamily="Segoe UI" FontSize="11"
                       VerticalAlignment="Center" Margin="8,1,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,6,0">
            <Button x:Name="CopyResponseBtn"
                    Content="&#xF0E3;" FontFamily="Segoe MDL2 Assets" FontSize="11"
                    Width="30" Height="26"
                    Background="Transparent" Foreground="#FF707070"
                    BorderThickness="0" Cursor="Hand"
                    ToolTip="Copy response to clipboard"/>
            <Button x:Name="CloseResponseBtn"
                    Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="10"
                    Width="30" Height="26"
                    Background="Transparent" Foreground="#FF707070"
                    BorderThickness="0" Cursor="Hand"
                    ToolTip="Close"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Scrolling content area -->
      <ScrollViewer x:Name="ResponseScroller" Grid.Row="1"
                    VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled">
        <StackPanel x:Name="ResponseContent" Margin="14,10,14,10">
          <TextBlock x:Name="ResponseOutput"
                     Foreground="#FFE8E8E8"
                     FontFamily="Cascadia Code, Cascadia Mono, Consolas"
                     FontSize="12.5"
                     TextWrapping="Wrap"
                     LineHeight="20"/>
        </StackPanel>
      </ScrollViewer>

      <!-- Status bar -->
      <Border Grid.Row="2"
              Background="#FF12121C"
              CornerRadius="0,0,14,14"
              Padding="14,6">
        <Grid>
          <TextBlock x:Name="ResponseStatus"
                     Text="Analyzing..."
                     Foreground="#FF8F8FAF"
                     FontFamily="Segoe UI" FontSize="11"
                     VerticalAlignment="Center"/>
          <TextBlock x:Name="ResponseMeta"
                     Text=""
                     Foreground="#FF6B6B8D"
                     FontFamily="Segoe UI" FontSize="10"
                     HorizontalAlignment="Right"
                     VerticalAlignment="Center"/>
        </Grid>
      </Border>
    </Grid>
  </Border>
</Window>
"@

    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))

    # Wire title bar drag
    $titleBar = $window.FindName("ResponseTitleBar")
    $capturedWindow = $window
    $titleBar.Add_MouseLeftButtonDown({
        param($s, $e)
        $capturedWindow.DragMove()
    }.GetNewClosure())

    # Wire close
    $closeBtn = $window.FindName("CloseResponseBtn")
    $closeBtn.Add_Click({
        if ($script:CursorAnalysisWidget -eq $capturedWindow) {
            $script:CursorAnalysisActive = $false
            $script:CursorAnalysisWidget = $null
            $script:CursorAnalysisTabId = $null
            $script:CursorAnalysisId = $null
        }
        $capturedWindow.Hide()
    }.GetNewClosure())

    # Wire copy
    $copyBtn = $window.FindName("CopyResponseBtn")
    $capturedOutput = $window.FindName("ResponseOutput")
    $copyBtn.Add_Click({
        $text = $capturedOutput.Text
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [System.Windows.Clipboard]::SetText($text)
        }
    }.GetNewClosure())

    return $window
}

# ── Response widget update helpers ──────────────────────────────────
function script:Update-ResponseWidget {
    param(
        [Windows.Window]$Widget,
        [hashtable]$Updates
    )

    if (-not $Widget -or $Widget.Dispatcher.HasShutdownStarted) { return }

    $Widget.Dispatcher.Invoke([Action]{
        $brushConv = [Windows.Media.BrushConverter]::new()

        if ($Updates.ContainsKey('Text')) {
            $output = $Widget.FindName("ResponseOutput")
            if ($output) { $output.Text += $Updates.Text }
        }
        if ($Updates.ContainsKey('SetText')) {
            $output = $Widget.FindName("ResponseOutput")
            if ($output) { $output.Text = $Updates.SetText }
        }
        if ($Updates.ContainsKey('Color')) {
            $output = $Widget.FindName("ResponseOutput")
            if ($output) {
                try { $output.Foreground = $brushConv.ConvertFromString($Updates.Color) } catch {}
            }
        }
        if ($Updates.ContainsKey('Status')) {
            $status = $Widget.FindName("ResponseStatus")
            if ($status) { $status.Text = $Updates.Status }
        }
        if ($Updates.ContainsKey('Meta')) {
            $meta = $Widget.FindName("ResponseMeta")
            if ($meta) { $meta.Text = $Updates.Meta }
        }
        if ($Updates.ContainsKey('Title')) {
            $title = $Widget.FindName("ResponseTitle")
            if ($title) { $title.Text = $Updates.Title }
        }
        if ($Updates.ContainsKey('Subtitle')) {
            $subtitle = $Widget.FindName("ResponseSubtitle")
            if ($subtitle) { $subtitle.Text = $Updates.Subtitle }
        }
        if ($Updates.ContainsKey('ScrollToEnd')) {
            $scroller = $Widget.FindName("ResponseScroller")
            if ($scroller) { $scroller.ScrollToEnd() }
        }
    })
}

# ── AI analysis workflow ────────────────────────────────────────────
function script:Invoke-ClippyAnalysis {
    param(
        [int]$ScreenX,
        [int]$ScreenY,
        [string]$ActionId = 'explain'
    )

    $actionDef = $script:CursorActions[$ActionId]
    if (-not $actionDef) {
        script:Write-CursorLog "Unknown action: $ActionId"
        return
    }

    $label  = $actionDef.Label
    $prompt = $actionDef.Prompt

    # Capture
    $capturePath = if ($actionDef.Region) {
        script:Capture-ScreenRegion -CenterX $ScreenX -CenterY $ScreenY
    } else {
        script:Capture-FullScreen
    }

    if (-not $capturePath) {
        script:Write-CursorLog "Screen capture failed for $ActionId"
        return
    }

    script:Write-CursorLog "Captured $ActionId at ($ScreenX, $ScreenY) -> $capturePath"
    $screenContext = script:New-ClippyScreenContext -CapturePath $capturePath -ActionId $ActionId -Label $label -ScreenX $ScreenX -ScreenY $ScreenY -Prompt $prompt
    script:Write-CursorLog "Screen context for $ActionId -> $($screenContext.JsonPath); $($screenContext.MarkdownPath)"

    # Position the widget near cursor, avoiding screen overflow
    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $widgetX = $ScreenX + 30
    $widgetY = [Math]::Max(20, $ScreenY - 40)
    if ($widgetX + 440 -gt $screenBounds.Width)  { $widgetX = $ScreenX - 460 }
    if ($widgetY + 360 -gt $screenBounds.Height)  { $widgetY = $screenBounds.Height - 380 }
    if ($widgetX -lt 0) { $widgetX = 20 }

    # Close previous widget if open
    if ($script:ResponseWidgetWindow) {
        try { $script:ResponseWidgetWindow.Close() } catch {}
        $script:ResponseWidgetWindow = $null
    }

    $script:ResponseWidgetWindow = script:New-ResponseWidget -ScreenX $widgetX -ScreenY $widgetY -Title $label
    script:Update-ResponseWidget -Widget $script:ResponseWidgetWindow -Updates @{
        Subtitle = 'analyzing...'
        Status   = 'Capturing screen...'
    }
    $script:ResponseWidgetWindow.Show()

    # Widget-hosted mode: dispatch through the Copilot session pipeline
    if ($script:IsWidgetHosted) {
        $dispatched = script:Dispatch-WidgetAnalysis -CapturePath $capturePath `
            -Prompt $prompt -Label $label -ActionId $ActionId `
            -ScreenX $ScreenX -ScreenY $ScreenY `
            -ContextJsonPath $screenContext.JsonPath `
            -ContextMarkdownPath $screenContext.MarkdownPath
        if ($dispatched) { return }
        # Fall through to standalone if dispatch failed
    }

    # Standalone mode: show capture info and prompt user to connect
    script:Show-StandaloneResult -CapturePath $capturePath -ActionId $ActionId -Label $label -ContextJsonPath $screenContext.JsonPath -ContextMarkdownPath $screenContext.MarkdownPath
}

function script:Dispatch-WidgetAnalysis {
    param(
        [string]$CapturePath,
        [string]$Prompt,
        [string]$Label,
        [string]$ActionId,
        [int]$ScreenX,
        [int]$ScreenY,
        [string]$ContextJsonPath,
        [string]$ContextMarkdownPath
    )

    try {
        if (-not (Get-Command 'script:Invoke-ClippyCursorContextPrompt' -ErrorAction SilentlyContinue)) {
            script:Write-CursorLog "Widget cursor context prompt function is unavailable"
            return $false
        }

        $analysisId = ([guid]::NewGuid()).Guid
        $result = script:Invoke-ClippyCursorContextPrompt -CapturePath $CapturePath `
            -Prompt $Prompt -Label $Label -ActionId $ActionId `
            -ScreenX $ScreenX -ScreenY $ScreenY -AnalysisId $analysisId `
            -ContextJsonPath $ContextJsonPath -ContextMarkdownPath $ContextMarkdownPath

        if (-not $result) {
            return $false
        }

        $metaText = "session $([string]$result.SessionId)"
        if ($metaText.Length -gt 44) {
            $metaText = $metaText.Substring(0, 44)
        }

        script:Update-ResponseWidget -Widget $script:ResponseWidgetWindow -Updates @{
            Status   = 'Streaming from Cursor Context...'
            Subtitle = 'persistent session'
            Meta     = $metaText
        }

        # Mark analysis as active so the stream interceptor pipes deltas here
        $script:CursorAnalysisActive = $true
        $script:CursorAnalysisWidget = $script:ResponseWidgetWindow
        $script:CursorAnalysisTabId = [string]$result.TabId
        $script:CursorAnalysisId = [string]$result.AnalysisId

        script:Write-CursorLog "Dispatched $ActionId to Cursor Context session $($result.SessionId)"
        return $true
    } catch {
        script:Write-CursorLog "Dispatch-WidgetAnalysis failed: $($_.Exception.Message)"
        script:Update-ResponseWidget -Widget $script:ResponseWidgetWindow -Updates @{
            Status   = 'Dispatch failed'
            Subtitle = 'error'
            Meta     = $ActionId
        }
        return $false
    }
}

function script:Show-StandaloneResult {
    param(
        [string]$CapturePath,
        [string]$ActionId,
        [string]$Label,
        [string]$ContextJsonPath,
        [string]$ContextMarkdownPath
    )

    $fileSize = (Get-Item $CapturePath).Length
    $sizeKB = [Math]::Round($fileSize / 1024)

    $text = @(
        "$Label"
        ""
        "Screenshot captured and saved:"
        "  $CapturePath"
        "  Size: $sizeKB KB"
        ""
        "Semantic context files:"
        "  JSON: $ContextJsonPath"
        "  Markdown: $ContextMarkdownPath"
        ""
        "To get AI-powered analysis:"
        "  1. Open the Clippy Bench (click the widget icon)"
        "  2. Use the Commander prompt with the screenshot and context files attached"
        "  3. Or run: pwsh clippy-widget.ps1 to start a full session"
        ""
        "The screenshot and semantic screen context are ready for analysis through any AI provider."
    ) -join "`n"

    script:Update-ResponseWidget -Widget $script:ResponseWidgetWindow -Updates @{
        SetText  = $text
        Status   = 'Complete (standalone)'
        Subtitle = 'captured'
        Meta     = "$sizeKB KB"
    }
}

# ── Stream interceptor (called from Handle-CopilotEvent pipeline) ───
function script:Intercept-CursorAnalysisStream {
    <#
    .SYNOPSIS
        Pipes a text delta from the CopilotEvent stream into the floating response widget.
    .DESCRIPTION
        Called by the widget's Handle-CopilotEvent function when CursorAnalysisActive
        is true. Returns $true if the text was intercepted (dual-written to both the
        bench transcript and the response widget), $false if no cursor analysis is active.
    #>
    param(
        [string]$Text,
        [string]$Color = '#FFE8E8E8',
        [string]$TabId,
        [string]$AnalysisId
    )

    if (-not $script:CursorAnalysisActive -or -not $script:CursorAnalysisWidget) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CursorAnalysisTabId) -and [string]$TabId -ne [string]$script:CursorAnalysisTabId) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CursorAnalysisId) -and [string]$AnalysisId -ne [string]$script:CursorAnalysisId) {
        return $false
    }

    script:Update-ResponseWidget -Widget $script:CursorAnalysisWidget -Updates @{
        Text        = $Text
        Color       = $Color
        ScrollToEnd = $true
    }
    return $true
}

function script:Complete-CursorAnalysis {
    <#
    .SYNOPSIS
        Signals that the AI analysis stream has completed.
    #>
    param(
        [string]$TabId,
        [string]$AnalysisId
    )

    if (-not $script:CursorAnalysisActive) { return }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CursorAnalysisTabId) -and [string]$TabId -ne [string]$script:CursorAnalysisTabId) {
        return
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CursorAnalysisId) -and [string]$AnalysisId -ne [string]$script:CursorAnalysisId) {
        return
    }

    script:Update-ResponseWidget -Widget $script:CursorAnalysisWidget -Updates @{
        Status   = 'Complete'
        Subtitle = 'done'
    }
    $script:CursorAnalysisActive = $false
    $script:CursorAnalysisWidget = $null
    $script:CursorAnalysisTabId = $null
    $script:CursorAnalysisId = $null
    script:Write-CursorLog "Cursor analysis completed"
}

# ── Context menu construction ───────────────────────────────────────
function script:Build-ClippyCursorContextMenu {
    # Reuse widget styling when hosted; standalone gets a self-contained style.
    if ($script:IsWidgetHosted) {
        $menu = script:New-ToolbarContextMenu
    } else {
        $menu = script:New-StandaloneCursorMenu
    }

    # Section header
    $header = script:New-CursorMenuItemInternal -Header 'CLIPPY AI' -Menu $menu
    $header.IsEnabled = $false
    $header.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF5B5FC7')
    $header.FontWeight = 'SemiBold'
    $header.FontSize   = 10
    $menu.Items.Add($header) | Out-Null

    # AI quick actions (primary group)
    foreach ($actionId in @('explain', 'summarize', 'extract')) {
        $def = $script:CursorActions[$actionId]
        $item = script:New-CursorMenuItemInternal -Header $def.Label -Gesture $def.Gesture -Menu $menu
        $capturedId = $actionId
        $item.Add_Click({
            $pos = [System.Windows.Forms.Cursor]::Position
            script:Invoke-ClippyAnalysis -ScreenX $pos.X -ScreenY $pos.Y -ActionId $capturedId
        }.GetNewClosure())
        $menu.Items.Add($item) | Out-Null
    }

    # Read Aloud
    $readDef = $script:CursorActions['read-aloud']
    $readItem = script:New-CursorMenuItemInternal -Header $readDef.Label -Menu $menu
    $readItem.Add_Click({
        $pos = [System.Windows.Forms.Cursor]::Position
        script:Invoke-ClippyAnalysis -ScreenX $pos.X -ScreenY $pos.Y -ActionId 'read-aloud'
    })
    $menu.Items.Add($readItem) | Out-Null

    $menu.Items.Add([Windows.Controls.Separator]::new()) | Out-Null

    # Developer tools
    foreach ($actionId in @('debug', 'accessibility')) {
        $def = $script:CursorActions[$actionId]
        $item = script:New-CursorMenuItemInternal -Header $def.Label -Menu $menu
        $capturedId = $actionId
        $item.Add_Click({
            $pos = [System.Windows.Forms.Cursor]::Position
            script:Invoke-ClippyAnalysis -ScreenX $pos.X -ScreenY $pos.Y -ActionId $capturedId
        }.GetNewClosure())
        $menu.Items.Add($item) | Out-Null
    }

    $menu.Items.Add([Windows.Controls.Separator]::new()) | Out-Null

    # Cursor controls
    $miRestore = script:New-CursorMenuItemInternal -Header 'Restore Default Cursor' -Menu $menu
    $miRestore.Add_Click({ script:Disable-ClippyCursor })
    $menu.Items.Add($miRestore) | Out-Null

    $miReactivate = script:New-CursorMenuItemInternal -Header 'Reactivate Clippy Cursor' -Menu $menu
    $miReactivate.Add_Click({ script:Enable-ClippyCursor })
    $menu.Items.Add($miReactivate) | Out-Null

    if ($script:IsWidgetHosted) {
        $miOpenBench = script:New-CursorMenuItemInternal -Header 'Open Clippy Bench' -Menu $menu
        $miOpenBench.Add_Click({ script:Toggle-Chat })
        $menu.Items.Add($miOpenBench) | Out-Null
    }

    # Dynamic state on open
    $menu.Add_Opened({
        $miRestore.IsEnabled    = $script:ClippyCursorActive
        $miReactivate.IsEnabled = -not $script:ClippyCursorActive
    }.GetNewClosure())

    return $menu
}

function script:New-CursorMenuItemInternal {
    param(
        [string]$Header,
        [string]$Gesture,
        $Menu
    )

    if ($script:IsWidgetHosted) {
        return (script:New-ToolbarMenuItem -Header $Header -InputGestureText $Gesture)
    }

    $item = [Windows.Controls.MenuItem]::new()
    $item.Header = $Header
    if ($Gesture) { $item.InputGestureText = $Gesture }
    return $item
}

function script:New-StandaloneCursorMenu {
    # Minimal styled context menu for standalone mode
    $menu = [Windows.Controls.ContextMenu]::new()
    $menu.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF111122')
    $menu.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF5B5FC7')
    $menu.BorderThickness = [Windows.Thickness]::new(1)
    $menu.Padding = [Windows.Thickness]::new(4, 6, 4, 6)
    return $menu
}

# ── Lifecycle: Start / Stop ─────────────────────────────────────────
function script:Start-ClippyCursorMode {
    <#
    .SYNOPSIS
        Activates the Clippy cursor replacement and AI context menu system.
    .OUTPUTS
        [bool] True if at least the context menu was installed successfully.
    #>

    # 1. Replace the system cursor
    $cursorOk = script:Enable-ClippyCursor
    if (-not $cursorOk) {
        script:Write-CursorLog "Cursor replacement failed; continuing with context menu only."
    }

    # 2. Create a tiny hidden topmost window to anchor the context menu.
    #    WPF ContextMenu requires a visual owner to render above all other windows.
    [xml]$anchorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="ClippyCursorAnchor" Width="1" Height="1"
        WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Left="-10" Top="-10" />
'@
    $script:CursorAnchorWindow = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($anchorXaml))
    $script:CursorAnchorWindow.Show()

    # 3. Build the context menu and assign it to the anchor window
    $script:CursorContextMenu = script:Build-ClippyCursorContextMenu

    return $true
}

function script:Install-ClippyCursorHooks {
    <#
    .SYNOPSIS
        Installs low-level mouse and keyboard hooks.
        MUST be called from the WPF dispatcher thread (inside Dispatcher.Run message pump).
    #>

    # Mouse hook: Ctrl+Right-Click -> context menu
    try {
        $script:MouseHookInstance = [ClippyCursor.MouseHook]::new()
        $capturedMenu = $script:CursorContextMenu
        $capturedAnchor = $script:CursorAnchorWindow
        $script:MouseHookInstance.Add_RightClick({
            param($sender, $e)
            $capturedAnchor.Dispatcher.Invoke([Action]{
                $dpi = script:Get-DpiScale
                $capturedAnchor.Left = $e.X * $dpi.X
                $capturedAnchor.Top  = $e.Y * $dpi.Y
                $capturedMenu.PlacementTarget = $capturedAnchor
                $capturedMenu.Placement = 'Bottom'
                $capturedMenu.IsOpen = $false
                $capturedMenu.IsOpen = $true
            })
        }.GetNewClosure())
        $hookOk = $script:MouseHookInstance.Install()
        if ($hookOk -ne [IntPtr]::Zero) {
            script:Write-CursorLog "Mouse hook installed (handle: 0x$($hookOk.ToString('X')))"
        } else {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            script:Write-CursorLog "Mouse hook FAILED (Win32 error: $err)"
        }
    } catch {
        script:Write-CursorLog "Mouse hook install failed: $($_.Exception.Message)"
    }

    # Keyboard hook: Ctrl+Shift+E/S/T
    try {
        $script:KeyboardHookInstance = [ClippyCursor.KeyboardHook]::new()
        $script:KeyboardHookInstance.Add_HotkeyPressed({
            param($sender, $vkCode)
            $pos = [System.Windows.Forms.Cursor]::Position
            $actionId = switch ($vkCode) {
                $script:VK_E { 'explain' }
                $script:VK_S { 'summarize' }
                $script:VK_T { 'extract' }
                default       { $null }
            }
            if ($actionId) {
                [System.Windows.Application]::Current.Dispatcher.BeginInvoke([Action]{
                    script:Invoke-ClippyAnalysis -ScreenX $pos.X -ScreenY $pos.Y -ActionId $actionId
                })
            }
        }.GetNewClosure())
        $kbHook = $script:KeyboardHookInstance.Install()
        if ($kbHook -ne [IntPtr]::Zero) {
            script:Write-CursorLog "Keyboard hook installed (handle: 0x$($kbHook.ToString('X')))"
        } else {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            script:Write-CursorLog "Keyboard hook FAILED (Win32 error: $err)"
        }
    } catch {
        script:Write-CursorLog "Keyboard hook install failed: $($_.Exception.Message)"
    }
}

function script:Stop-ClippyCursorMode {
    <#
    .SYNOPSIS
        Restores the default system cursor and removes all hooks.
    #>

    script:Disable-ClippyCursor

    if ($script:MouseHookInstance) {
        $script:MouseHookInstance.Dispose()
        $script:MouseHookInstance = $null
    }

    if ($script:KeyboardHookInstance) {
        $script:KeyboardHookInstance.Dispose()
        $script:KeyboardHookInstance = $null
    }

    if ($script:ResponseWidgetWindow) {
        try { $script:ResponseWidgetWindow.Close() } catch {}
        $script:ResponseWidgetWindow = $null
    }

    if ($script:CursorAnchorWindow) {
        try { $script:CursorAnchorWindow.Close() } catch {}
        $script:CursorAnchorWindow = $null
    }

    $script:CursorAnalysisActive = $false
    $script:CursorAnalysisWidget = $null
    $script:CursorAnalysisTabId = $null
    $script:CursorAnalysisId = $null
    $script:CursorContextMenu = $null

    script:Write-CursorLog "Clippy cursor mode stopped"
}

# ── Adaptive card template ──────────────────────────────────────────
function script:Get-CursorAnalysisAdaptiveCardTemplate {
    return @'
{
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "type": "AdaptiveCard",
  "version": "1.5",
  "fallbackText": "Clippy AI analysis result",
  "body": [
    {
      "type": "ColumnSet",
      "columns": [
        {
          "type": "Column",
          "width": "auto",
          "items": [
            {
              "type": "Image",
              "url": "${icon}",
              "size": "Small",
              "style": "Person"
            }
          ]
        },
        {
          "type": "Column",
          "width": "stretch",
          "items": [
            {
              "type": "TextBlock",
              "text": "${title}",
              "weight": "Bolder",
              "size": "Medium",
              "wrap": true
            },
            {
              "type": "TextBlock",
              "text": "${subtitle}",
              "spacing": "None",
              "isSubtle": true,
              "wrap": true,
              "size": "Small"
            }
          ]
        }
      ]
    },
    {
      "type": "Container",
      "style": "emphasis",
      "items": [
        {
          "type": "TextBlock",
          "text": "${analysis}",
          "wrap": true,
          "size": "Default"
        }
      ]
    },
    {
      "type": "FactSet",
      "separator": true,
      "facts": [
        { "title": "Action",   "value": "${action}" },
        { "title": "Position", "value": "(${cursorX}, ${cursorY})" },
        { "title": "Captured", "value": "${timestamp}" }
      ]
    }
  ],
  "actions": [
    { "type": "Action.Submit", "title": "Copy",          "data": { "action": "copy" } },
    { "type": "Action.Submit", "title": "Ask Follow-up", "data": { "action": "followup" } },
    { "type": "Action.Submit", "title": "Open in Bench", "data": { "action": "open_bench" } }
  ]
}
'@
}

# ── Standalone entry point ──────────────────────────────────────────
if ($Standalone) {
    Write-Host "Clippy Cursor Mode" -ForegroundColor Cyan
    Write-Host "  Ctrl+Right-Click : Clippy AI context menu" -ForegroundColor DarkCyan
    Write-Host "  Ctrl+Shift+E     : Explain This" -ForegroundColor DarkCyan
    Write-Host "  Ctrl+Shift+S     : Summarize Screen" -ForegroundColor DarkCyan
    Write-Host "  Ctrl+Shift+T     : Extract Text" -ForegroundColor DarkCyan
    Write-Host ""

    if (-not [System.Windows.Application]::Current) {
        $app = [System.Windows.Application]::new()
        $app.ShutdownMode = 'OnExplicitShutdown'
    }

    $started = script:Start-ClippyCursorMode
    if ($started) {
        Write-Host "Active. Press Ctrl+C to exit." -ForegroundColor Green

        $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            script:Stop-ClippyCursorMode
        }

        # Install hooks AFTER the dispatcher starts pumping messages.
        # Low-level hooks deliver callbacks to the thread's message loop,
        # so the thread must be pumping when SetWindowsHookEx is called.
        [System.Windows.Application]::Current.Dispatcher.BeginInvoke([Action]{
            script:Install-ClippyCursorHooks
        })

        try {
            [System.Windows.Threading.Dispatcher]::Run()
        } finally {
            script:Stop-ClippyCursorMode
            Write-Host "Clippy cursor deactivated." -ForegroundColor Yellow
        }
    }
}
