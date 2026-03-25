#requires -Version 5.1
<#
.SYNOPSIS
    Windows Clippy - Floating desktop widget with an adaptive Clippy bench UI.
.DESCRIPTION
    A WPF-based floating desktop widget displaying the Clippy icon with a
    pop-out dark-themed bench panel for kernel and prompt runtimes. Drag the
    icon to reposition, click to toggle the bench window, right-click for
    context menu.
#>

param(
    [switch]$NoWelcome,
    [string]$SessionId,
    [switch]$OpenChat
)

trap {
    $crashLogDir = Join-Path $env:APPDATA 'Windows-Clippy-MCP'
    if (-not (Test-Path -LiteralPath $crashLogDir)) {
        New-Item -ItemType Directory -Path $crashLogDir -Force | Out-Null
    }
    $msg = "[$(Get-Date -Format o)] UNHANDLED EXCEPTION: $($_.Exception.Message)`n$($_.Exception.StackTrace)`nAt: $($_.InvocationInfo.PositionMessage)"
    $msg | Out-File (Join-Path $crashLogDir 'widget-crash.log') -Append
    continue
}

# ── Single-instance guard ─────────────────────────────────────────
$_mutexCreatedNew = $false
$_widgetMutex = New-Object System.Threading.Mutex($true, 'Global\Windows-Clippy-MCP-Widget', [ref]$_mutexCreatedNew)
if (-not $_mutexCreatedNew) {
    $diagLog = Join-Path $env:APPDATA 'Windows-Clippy-MCP\widget-startup-diag.log'
    "[$(Get-Date -Format o)] DIAG: Another widget instance is already running. Exiting pid=$PID" | Out-File $diagLog -Append
    return
}

# ── Assemblies ────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsFormsIntegration
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClippyWidget {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", SetLastError = true)]
        public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
        public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int nWidth, int nHeight, bool bRepaint);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsHungAppWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr hWnd);

        public const uint SMTO_ABORTIFHUNG = 0x0002;
        public const uint WM_NULL = 0x0000;

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    }
}
'@
$script:User32 = [ClippyWidget.NativeMethods]
$script:GWL_STYLE = -16
$script:WS_CHILD = 0x40000000
$script:WS_POPUP = 0x80000000
$script:SW_SHOW = 5

# ── Safe cross-process window helpers ─────────────────────────────
# TerminalHost.exe can hang, which causes synchronous Win32 calls
# (MoveWindow, ShowWindow, SetParent, SetWindowLongPtr) to block
# the WPF UI thread indefinitely, triggering AppHangXProcB1.
# These helpers detect a hung target window and skip the call.

function script:Test-TerminalHwndResponsive {
    param([IntPtr]$Hwnd)

    if ($Hwnd -eq [IntPtr]::Zero) {
        return $false
    }

    if (-not $script:User32::IsWindow($Hwnd)) {
        return $false
    }

    if ($script:User32::IsHungAppWindow($Hwnd)) {
        return $false
    }

    # Double-check with a short SendMessageTimeout (200ms) to make
    # sure the target message pump is processing messages.
    $result = [IntPtr]::Zero
    $sent = $script:User32::SendMessageTimeout(
        $Hwnd,
        [ClippyWidget.NativeMethods]::WM_NULL,
        [IntPtr]::Zero,
        [IntPtr]::Zero,
        [ClippyWidget.NativeMethods]::SMTO_ABORTIFHUNG,
        200,
        [ref]$result)

    return $sent
}

function script:Invoke-SafeMoveWindow {
    param([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$Width, [int]$Height, [bool]$Repaint = $true)

    if (-not (script:Test-TerminalHwndResponsive -Hwnd $Hwnd)) {
        script:Write-WidgetDebugLog "MoveWindow skipped: terminal HWND 0x$('{0:X}' -f $Hwnd.ToInt64()) is not responsive"
        return $false
    }

    return $script:User32::MoveWindow($Hwnd, $X, $Y, $Width, $Height, $Repaint)
}

function script:Invoke-SafeShowWindow {
    param([IntPtr]$Hwnd, [int]$CmdShow)

    if (-not (script:Test-TerminalHwndResponsive -Hwnd $Hwnd)) {
        script:Write-WidgetDebugLog "ShowWindow skipped: terminal HWND 0x$('{0:X}' -f $Hwnd.ToInt64()) is not responsive"
        return $false
    }

    return $script:User32::ShowWindow($Hwnd, $CmdShow)
}

function script:Invoke-SafeSetParent {
    param([IntPtr]$ChildHwnd, [IntPtr]$ParentHwnd)

    if (-not (script:Test-TerminalHwndResponsive -Hwnd $ChildHwnd)) {
        script:Write-WidgetDebugLog "SetParent skipped: terminal HWND 0x$('{0:X}' -f $ChildHwnd.ToInt64()) is not responsive"
        return [IntPtr]::Zero
    }

    return $script:User32::SetParent($ChildHwnd, $ParentHwnd)
}

function script:Invoke-SafeSetWindowLongPtr {
    param([IntPtr]$Hwnd, [int]$Index, [IntPtr]$NewLong)

    if (-not (script:Test-TerminalHwndResponsive -Hwnd $Hwnd)) {
        script:Write-WidgetDebugLog "SetWindowLongPtr skipped: terminal HWND 0x$('{0:X}' -f $Hwnd.ToInt64()) is not responsive"
        return [IntPtr]::Zero
    }

    return $script:User32::SetWindowLongPtr($Hwnd, $Index, $NewLong)
}

# ── Resolve paths ─────────────────────────────────────────────────
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RepoRoot = Split-Path $ScriptDir
$AssetsDir = Join-Path $script:RepoRoot "assets"
$script:TerminalHostExe = Join-Path $script:RepoRoot 'widget\TerminalHost\bin\Debug\net8.0-windows\TerminalHost.exe'
$script:TerminalAdaptiveCardTemplatePath = Join-Path $script:RepoRoot 'widget\adaptive-cards\terminal-session.template.json'
$script:TerminalAdaptiveCardSchemaPath = Join-Path $script:RepoRoot 'widget\adaptive-cards\terminal-session.data.schema.json'
$script:AgentcardAdaptiveCardTemplatePath = Join-Path $script:RepoRoot 'widget\adaptive-cards\agentcard-icon.template.json'
$script:AgentcardAdaptiveCardSchemaPath = Join-Path $script:RepoRoot 'widget\adaptive-cards\agentcard-icon.data.schema.json'
$script:AgentcardAdaptiveCardDataPath = Join-Path $script:RepoRoot 'widget\adaptive-cards\agentcard-icon.data.json'
$script:AgentcardPackageManifestPath = Join-Path $script:RepoRoot 'widget\adaptive-cards\agentcard-icon.package-manifest.json'
$script:AgentcardSpecPath = Join-Path $script:RepoRoot 'widget\adaptive-cards\agentcard-icon.spec.json'
$script:AgentcardHeroAssetPath = Join-Path $AssetsDir 'agentcard_192.png'
$script:AgentcardDefaultAssetPath = Join-Path $AssetsDir 'agentcard_32.png'
$script:AgentcardFocusedAssetPath = Join-Path $AssetsDir 'agentcard_focused_32.png'
$script:ClippyRuntimeCopilot = 'copilot'
$script:ClippyRuntimeKernel = 'clippy-kernel'
$script:ClippySurfaceTerminal = 'terminal'
$script:ClippySurfaceBrowser = 'browser'
$script:ClippySurfaceNote = 'note'
$script:ClippyHostTransportEmbeddedTerminal = 'embedded-terminal'
$script:ClippyHostTransportNodeBridge = 'node-bridge'
$script:ClippyHostTransportNone = 'none'
$script:ClippyKernelRoot = 'E:\clippy-kernel'
$script:ClippyKernelSweExe = Join-Path $script:ClippyKernelRoot '.venv\Scripts\clippy-swe.exe'
$script:ClippyKernelPythonExe = Join-Path $script:ClippyKernelRoot '.venv\Scripts\python.exe'

# ── Shared state ──────────────────────────────────────────────────
$script:ChatOpen = $false
$script:ChatWasClosed = $false
$script:IsApplicationClosing = $false
$script:History  = [System.Collections.Generic.List[string]]::new()
$script:HistIdx  = -1
$script:CopilotConfigDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.copilot'
$script:WidgetConfigDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Windows-Clippy-MCP'
$script:WidgetConfigPath = Join-Path $script:WidgetConfigDir 'widget-settings.json'
$script:CopilotSessionPath = Join-Path $script:WidgetConfigDir 'copilot-session.json'
$script:WidgetDebugLogPath = Join-Path $script:WidgetConfigDir 'widget-debug.log'
$script:AttachedFiles = [System.Collections.Generic.List[string]]::new()
$script:AvailableModes = @('Agent', 'Plan', 'Swarm')
$script:AvailableModelCatalog = @(
    [pscustomobject]@{ Id = 'gpt-5.4'; DisplayName = 'GPT-5.4'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gpt-5.3-codex'; DisplayName = 'GPT-5.3-Codex'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gpt-5.2-codex'; DisplayName = 'GPT-5.2-Codex'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gpt-5.2'; DisplayName = 'GPT-5.2'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gpt-5.1-codex-max'; DisplayName = 'GPT-5.1-Codex-Max'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gpt-5.1-codex'; DisplayName = 'GPT-5.1-Codex'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gpt-5.1'; DisplayName = 'GPT-5.1'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gpt-5.1-codex-mini'; DisplayName = 'GPT-5.1-Codex-Mini (Preview)'; RateLabel = '0.33x' }
    [pscustomobject]@{ Id = 'gpt-5-mini'; DisplayName = 'GPT-5 mini'; RateLabel = '0x' }
    [pscustomobject]@{ Id = 'gpt-4.1'; DisplayName = 'GPT-4.1'; RateLabel = '0x' }
    [pscustomobject]@{ Id = 'claude-sonnet-4.6'; DisplayName = 'Claude Sonnet 4.6'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'claude-sonnet-4.5'; DisplayName = 'Claude Sonnet 4.5'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'claude-haiku-4.5'; DisplayName = 'Claude Haiku 4.5'; RateLabel = '0.33x' }
    [pscustomobject]@{ Id = 'claude-opus-4.6'; DisplayName = 'Claude Opus 4.6 (default)'; RateLabel = '3x' }
    [pscustomobject]@{ Id = 'claude-opus-4.6-1m'; DisplayName = 'Claude Opus 4.6 (1M context)(Internal only)'; RateLabel = '6x' }
    [pscustomobject]@{ Id = 'claude-opus-4.5'; DisplayName = 'Claude Opus 4.5'; RateLabel = '3x' }
    [pscustomobject]@{ Id = 'claude-sonnet-4'; DisplayName = 'Claude Sonnet 4'; RateLabel = '1x' }
    [pscustomobject]@{ Id = 'gemini-3-pro-preview'; DisplayName = 'Gemini 3 Pro (Preview)'; RateLabel = '1x' }
)
$script:AvailableModels = @($script:AvailableModelCatalog | ForEach-Object { $_.Id })
$script:ModelCatalogById = @{}
foreach ($definition in $script:AvailableModelCatalog) {
    $script:ModelCatalogById[$definition.Id] = $definition
}
$script:AvailableAgents = @()
$script:ModeMenuItems = @{}
$script:AgentMenuItems = @{}
$script:ModelMenuItems = @{}
$script:ModeCycleButton = $null
$script:ToolDropdownItems = @{}
$script:ExtensionDropdownItems = @{}
$script:WidgetSettings = $null
$script:VsCodeSnapshot = $null
$script:ToolSourceSnapshot = [ordered]@{}
$script:CopilotSessionId = $null
$script:IsSyncingUi = $false
$script:SnippingTileOpen = $false
$script:IsCopilotCommandRunning = $false
$script:ActiveAssistantStream = $null
$script:ActiveCopilotProcess = $null
$script:ClippyTabs = [ordered]@{}
$script:ClippyTabOrder = [System.Collections.Generic.List[string]]::new()
$script:ActiveClippyTabId = $null
$script:ClippyTabStrip = $null
$script:ClippyAddTabButton = $null
$script:cOutputHost = $null
$script:BusyTabId = $null
$script:TabStripRefreshScheduled = $false
$script:SessionSaveTimer = $null

# ── XAML: Floating Widget Icon ────────────────────────────────────
[xml]$WX = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Clippy" Width="96" Height="108"
    WindowStyle="None" AllowsTransparency="True"
    Background="Transparent" Topmost="True"
    ShowInTaskbar="False" ResizeMode="NoResize"
    WindowStartupLocation="Manual">
  <Grid Background="Transparent">
    <Border x:Name="Ring"
            Background="Transparent"
            Cursor="Hand" ToolTip="Click to toggle the Clippy bench"/>
    <Image x:Name="Icon" Margin="2"
           Stretch="Uniform"
           HorizontalAlignment="Center"
           VerticalAlignment="Center"
           RenderOptions.BitmapScalingMode="Fant"
           RenderTransformOrigin="0.5,0.5"
           SnapsToDevicePixels="True">
      <Image.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="4" Opacity="0.55"/>
      </Image.Effect>
      <Image.RenderTransform>
        <ScaleTransform ScaleX="1.0" ScaleY="1.0"/>
      </Image.RenderTransform>
    </Image>
  </Grid>
</Window>
'@

# ── XAML: Terminal Chat Panel ─────────────────────────────────────
[xml]$CX = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Clippy Bench" Width="540" Height="620"
    WindowStyle="None" AllowsTransparency="True"
    Background="Transparent" Topmost="True"
    ShowInTaskbar="False" ResizeMode="CanResizeWithGrip"
    WindowStartupLocation="Manual">
  <Window.Resources>
    <Style x:Key="ToolbarButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center"
                                VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="#FF1A1A35"/>
                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="#FF24244A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ToolbarToggleButtonStyle" TargetType="ToggleButton">
      <Setter Property="Height" Value="28"/>
      <Setter Property="MinWidth" Value="28"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#FFB7B7D6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="ToggleBorder"
                    Margin="1"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center"
                                VerticalAlignment="Center"
                                Margin="8,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ToggleBorder" Property="Background" Value="#FF1A1A35"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="White"/>
                <Setter TargetName="ToggleBorder" Property="Background" Value="#FF5B5FC7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ToolbarComboBoxItemStyle" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" CornerRadius="6" Margin="4,2">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#FF1A1A35"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#FF2D2D57"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ToolbarComboBoxStyle" TargetType="ComboBox">
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="10,0,24,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="MaxDropDownHeight" Value="280"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource ToolbarComboBoxItemStyle}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="ComboBorder"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      CornerRadius="8"/>
              <ToggleButton x:Name="DropDownToggle"
                            Background="Transparent"
                            BorderThickness="0"
                            Focusable="False"
                            ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <ContentPresenter/>
                  </ControlTemplate>
                </ToggleButton.Template>
                <Grid>
                  <Border Width="22"
                          HorizontalAlignment="Right"
                          Background="#FF181832"
                          BorderBrush="{TemplateBinding BorderBrush}"
                          BorderThickness="1,0,0,0"
                          CornerRadius="0,8,8,0">
                    <TextBlock Text="v"
                               Foreground="#FFB7B7D6"
                               FontFamily="Segoe UI"
                               FontSize="11"
                               HorizontalAlignment="Center"
                               VerticalAlignment="Center"/>
                  </Border>
                </Grid>
              </ToggleButton>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                IsHitTestVisible="False"
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                Content="{TemplateBinding SelectionBoxItem}"/>
              <Popup Name="PART_Popup"
                      Placement="Bottom"
                      AllowsTransparency="True"
                      Focusable="False"
                      PlacementTarget="{Binding RelativeSource={RelativeSource TemplatedParent}}"
                      IsOpen="{TemplateBinding IsDropDownOpen}"
                      PopupAnimation="Fade">
                <Border Margin="0,4,0,0"
                        Width="{TemplateBinding Tag}"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        Background="#FF111122"
                        BorderBrush="#FF333355"
                        BorderThickness="1"
                        CornerRadius="8">
                  <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}"
                                CanContentScroll="True"
                                HorizontalScrollBarVisibility="{TemplateBinding ScrollViewer.HorizontalScrollBarVisibility}"
                                VerticalScrollBarVisibility="{TemplateBinding ScrollViewer.VerticalScrollBarVisibility}">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
              <Trigger Property="IsDropDownOpen" Value="True">
                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border CornerRadius="12" Background="#FF0C0C0C"
          BorderBrush="#FF5B5FC7" BorderThickness="1.5">
    <Border.Effect>
      <DropShadowEffect Color="#000" BlurRadius="24" ShadowDepth="4" Opacity="0.65"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="42"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Title bar -->
      <Border x:Name="TitleBar" Grid.Row="0"
              Background="#FF16162A" CornerRadius="12,12,0,0">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
            <Image x:Name="TitleIcon" Width="18" Height="18" Margin="0,0,8,0"
                   RenderOptions.BitmapScalingMode="Fant"/>
            <TextBlock Text="Windows Clippy" Foreground="#FFCCCCCC"
                       FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold"
                       VerticalAlignment="Center"/>
            <TextBlock Text="  kernel bench" Foreground="#FF6B6B8D"
                        FontFamily="Segoe UI" FontSize="11"
                        VerticalAlignment="Center" Margin="2,1,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,6,0">
            <Button x:Name="ClearBtn" Content="&#xE894;"
                    FontFamily="Segoe MDL2 Assets" FontSize="11"
                    Width="34" Height="30" Margin="0,0,2,0"
                    Background="Transparent" Foreground="#FF707070"
                    BorderThickness="0" Cursor="Hand"
                    ToolTip="Clear" VerticalAlignment="Center"/>
            <Button x:Name="HideBtn" Content="&#xE921;"
                    FontFamily="Segoe MDL2 Assets" FontSize="10"
                    Width="34" Height="30" Margin="0,0,2,0"
                    Background="Transparent" Foreground="#FF707070"
                    BorderThickness="0" Cursor="Hand"
                    ToolTip="Hide" VerticalAlignment="Center"/>
            <Button x:Name="TilePanelToggleBtn" Content="&#xE71D;"
                    FontFamily="Segoe MDL2 Assets" FontSize="10"
                    Width="34" Height="30" Margin="0,0,2,0"
                    Background="Transparent" Foreground="#FF707070"
                    BorderThickness="0" Cursor="Hand"
                    ToolTip="Toggle tile dashboard" VerticalAlignment="Center"/>
            <Button x:Name="SnippingBtn" Content="&#xE7C3;"
                    FontFamily="Segoe MDL2 Assets" FontSize="10"
                    Width="34" Height="30" Margin="0,0,2,0"
                    Background="Transparent" Foreground="#FF707070"
                    BorderThickness="0" Cursor="Hand"
                    ToolTip="Snipping Tool and Click to Do" VerticalAlignment="Center"/>
            <Button x:Name="CloseBtn" Content="&#xE8BB;"
                    FontFamily="Segoe MDL2 Assets" FontSize="10"
                    Width="34" Height="30"
                    Background="Transparent" Foreground="#FF707070"
                    BorderThickness="0" Cursor="Hand"
                    ToolTip="Close" VerticalAlignment="Center"/>
          </StackPanel>
          <Popup x:Name="SnippingTilePopup"
                 AllowsTransparency="True"
                 Placement="Top"
                 PopupAnimation="Fade"
                 StaysOpen="False">
            <Border x:Name="SnippingTileCard"
                    Width="356"
                    Padding="12"
                    Background="#FF111122"
                    BorderBrush="#FF5B5FC7"
                    BorderThickness="1"
                    CornerRadius="10">
              <Border.Effect>
                <DropShadowEffect Color="#000000" BlurRadius="20" ShadowDepth="4" Opacity="0.55"/>
              </Border.Effect>
              <StackPanel>
                <DockPanel Margin="0,0,0,10">
                  <TextBlock Text="Snipping + Click to Do"
                             Foreground="#FFE8E8E8"
                             FontFamily="Segoe UI"
                             FontSize="12"
                             FontWeight="SemiBold"
                             DockPanel.Dock="Left"/>
                  <TextBlock x:Name="SnippingTileStatus"
                             Foreground="#FF8F8FAF"
                             FontFamily="Segoe UI"
                             FontSize="10.5"
                             DockPanel.Dock="Right"/>
                </DockPanel>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Button x:Name="SnipOverlayBtn"
                          Grid.Column="0"
                          Content="Snip"
                          Margin="0,0,6,0"
                          Style="{StaticResource ToolbarButtonStyle}"
                          ToolTip="Open the native Snipping Tool capture overlay"/>
                  <Button x:Name="SnipSketchBtn"
                          Grid.Column="1"
                          Content="Sketch"
                          Margin="0,0,6,0"
                          Style="{StaticResource ToolbarButtonStyle}"
                          ToolTip="Open Snipping Tool in its sketch editor"/>
                  <Button x:Name="SnipToolBtn"
                          Grid.Column="2"
                          Content="Tool"
                          Margin="0,0,6,0"
                          Style="{StaticResource ToolbarButtonStyle}"
                          ToolTip="Open the Snipping Tool app"/>
                  <Button x:Name="SnipClickToDoBtn"
                          Grid.Column="3"
                          Content="Click"
                          Margin="0,0,6,0"
                          Style="{StaticResource ToolbarButtonStyle}"
                          ToolTip="Open native Click to Do when supported by Windows"/>
                  <Button x:Name="SnipSettingsBtn"
                          Grid.Column="4"
                          Content="Prefs"
                          Style="{StaticResource ToolbarButtonStyle}"
                          ToolTip="Open Click to Do settings"/>
                </Grid>
                <TextBlock x:Name="SnippingTileNote"
                           Foreground="#FF6B6B8D"
                           FontFamily="Segoe UI"
                           FontSize="10.5"
                           TextWrapping="Wrap"
                           Text="Snip opens the native overlay with Windows capture modes. Click to Do uses the native Windows provider when the device supports it."/>
              </StackPanel>
            </Border>
          </Popup>
        </Grid>
      </Border>

      <!-- Output area -->
      <Border Grid.Row="1" Background="#FF0C0C0C">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0"
                  Background="#FF10101A"
                  BorderBrush="#FF23233A"
                  BorderThickness="0,0,0,1"
                  Padding="12,8,12,6">
            <DockPanel LastChildFill="True">
              <Button x:Name="TabAddBtn"
                      DockPanel.Dock="Right"
                      Content="+"
                      Width="30"
                      Height="26"
                      Margin="8,0,0,0"
                      Style="{StaticResource ToolbarButtonStyle}"
                      ToolTip="Open a fresh Clippy bench tab"/>
              <ScrollViewer HorizontalScrollBarVisibility="Auto"
                            VerticalScrollBarVisibility="Disabled"
                            CanContentScroll="False">
                <StackPanel x:Name="TabStripPanel" Orientation="Horizontal"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
          <Border x:Name="TilePanelHost" Grid.Row="1"
                  Background="#FF0D1117"
                  BorderBrush="#FF1F2937"
                  BorderThickness="0,0,0,1"
                  Padding="8,6"
                  Visibility="Collapsed">
            <Grid x:Name="TilePanelGrid">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
            </Grid>
          </Border>
          <Grid x:Name="OutputHost" Grid.Row="2">
            <RichTextBox x:Name="Output"
                         Background="#FF0A0E14" Foreground="#FFCCCCCC"
                         FontFamily="Cascadia Code, Cascadia Mono, Consolas"
                         FontSize="13" IsReadOnly="True"
                         BorderThickness="0" Padding="14,8"
                         VerticalScrollBarVisibility="Auto"
                         HorizontalScrollBarVisibility="Disabled"
                         IsDocumentEnabled="True">
              <FlowDocument/>
            </RichTextBox>
          </Grid>
        </Grid>
      </Border>

      <!-- Input bar -->
      <Border Grid.Row="2" Background="#FF16162A"
              Padding="14,10" CornerRadius="0,0,12,12">
        <StackPanel>
          <Grid Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="148"/>
              <ColumnDefinition Width="184"/>
              <ColumnDefinition Width="70"/>
              <ColumnDefinition Width="70"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="AttachBtn"
                    Grid.Column="0"
                    Content="&#xE710;" FontFamily="Segoe MDL2 Assets"
                    FontSize="13" Width="32"
                    Margin="0,0,6,0"
                    Style="{StaticResource ToolbarButtonStyle}"
                    Cursor="Hand" ToolTip="Open a fresh Clippy bench tab"/>
            <ComboBox x:Name="AgentSelector"
                      Grid.Column="1"
                      Tag="260"
                      Margin="0,0,6,0"
                      Style="{StaticResource ToolbarComboBoxStyle}"
                      ToolTip="Choose the prompt-mode agent"/>
            <ComboBox x:Name="ModelSelector"
                      Grid.Column="2"
                      Tag="320"
                      Margin="0,0,6,0"
                      Style="{StaticResource ToolbarComboBoxStyle}"
                      ToolTip="Choose the prompt-mode model"/>
            <Button x:Name="ToolsBtn"
                    Grid.Column="3"
                    Content="Tools v"
                    Margin="0,0,6,0"
                    Style="{StaticResource ToolbarButtonStyle}"
                    ToolTip="Open quick prompt-mode tool settings"/>
            <Button x:Name="ExtensionsBtn"
                    Grid.Column="4"
                    Content="Ext v"
                    Margin="0,0,6,0"
                    Style="{StaticResource ToolbarButtonStyle}"
                    ToolTip="Open quick VS Code extension settings"/>
            <Button x:Name="ModeCycleBtn"
                    Grid.Column="5"
                    Width="78"
                    HorizontalAlignment="Left"
                    Content="Agent"
                    Style="{StaticResource ToolbarButtonStyle}"
                    ToolTip="Current prompt mode: Agent&#x0a;Click to switch to Plan."/>
          </Grid>
          <TextBlock x:Name="SessionMeta"
                     Foreground="#FF8F8FAF"
                     FontFamily="Segoe UI"
                     FontSize="11"
                     Margin="2,0,0,4"
                     TextWrapping="Wrap"/>
          <TextBlock x:Name="AttachmentMeta"
                     Foreground="#FF6B6B8D"
                     FontFamily="Segoe UI"
                     FontSize="11"
                     Margin="2,0,0,8"
                     TextWrapping="Wrap"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="PromptLabel" Grid.Column="0" Text="Command"
                       Foreground="#FF5B5FC7"
                       FontFamily="Segoe UI Semibold"
                       FontSize="12.5" FontWeight="Bold"
                       VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBox x:Name="Input" Grid.Column="1"
                       Background="#FF111122" Foreground="#FFE8E8E8"
                       CaretBrush="#FF5B5FC7"
                       FontFamily="Cascadia Code, Cascadia Mono, Consolas"
                     FontSize="13" BorderBrush="#FF333355" BorderThickness="1"
                     Padding="10,7" VerticalContentAlignment="Center">
              <TextBox.Resources>
                <Style TargetType="Border">
                  <Setter Property="CornerRadius" Value="6"/>
                </Style>
              </TextBox.Resources>
            </TextBox>
            <Button x:Name="RunBtn" Grid.Column="2"
                    Content="&#xE768;" FontFamily="Segoe MDL2 Assets"
                    FontSize="15" Width="38" Height="34"
                    Background="#FF5B5FC7" Foreground="White"
                    BorderThickness="0" Cursor="Hand" Margin="10,0,0,0"
                    ToolTip="Send to the active prompt tab">
              <Button.Resources>
                <Style TargetType="Border">
                  <Setter Property="CornerRadius" Value="6"/>
                </Style>
              </Button.Resources>
            </Button>
          </Grid>
        </StackPanel>
      </Border>
    </Grid>
  </Border>
</Window>
'@

# ── Build windows from XAML ───────────────────────────────────────
$script:Widget = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($WX))

function script:New-ChatWindowInstance {
    return [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($CX))
}

function script:Set-ChatWindowReferences {
    param([Parameter(Mandatory)][Windows.Window]$Window)

    $script:Chat = $Window
    $script:ChatWasClosed = $false
    $script:cTitle  = $script:Chat.FindName("TitleBar")
    $script:cTIcon  = $script:Chat.FindName("TitleIcon")
    $script:cOutputHost = $script:Chat.FindName("OutputHost")
    $script:cOutput = $script:Chat.FindName("Output")
    $script:cTabStrip = $script:Chat.FindName("TabStripPanel")
    $script:cTabAdd = $script:Chat.FindName("TabAddBtn")
    $script:cAttach = $script:Chat.FindName("AttachBtn")
    $script:cAgent  = $script:Chat.FindName("AgentSelector")
    $script:cModel  = $script:Chat.FindName("ModelSelector")
    $script:cTools  = $script:Chat.FindName("ToolsBtn")
    $script:cExt    = $script:Chat.FindName("ExtensionsBtn")
    $script:cModeCycle = $script:Chat.FindName("ModeCycleBtn")
    $script:cMeta   = $script:Chat.FindName("SessionMeta")
    $script:cFiles  = $script:Chat.FindName("AttachmentMeta")
    $script:cInput  = $script:Chat.FindName("Input")
    $script:cRun    = $script:Chat.FindName("RunBtn")
    $script:cClear  = $script:Chat.FindName("ClearBtn")
    $script:cHide   = $script:Chat.FindName("HideBtn")
    $script:cSnip   = $script:Chat.FindName("SnippingBtn")
    $script:cClose  = $script:Chat.FindName("CloseBtn")
    $script:cTilePanel = $script:Chat.FindName("TilePanelHost")
    $script:cTilePanelGrid = $script:Chat.FindName("TilePanelGrid")
    $script:cTilePanelToggle = $script:Chat.FindName("TilePanelToggleBtn")
    $script:cSnippingTilePopup = $script:Chat.FindName("SnippingTilePopup")
    $script:cSnippingTileCard = $script:Chat.FindName("SnippingTileCard")
    $script:cSnippingTileStatus = $script:Chat.FindName("SnippingTileStatus")
    $script:cSnippingTileNote = $script:Chat.FindName("SnippingTileNote")
    $script:cSnipOverlay = $script:Chat.FindName("SnipOverlayBtn")
    $script:cSnipSketch = $script:Chat.FindName("SnipSketchBtn")
    $script:cSnipTool = $script:Chat.FindName("SnipToolBtn")
    $script:cSnipClickToDo = $script:Chat.FindName("SnipClickToDoBtn")
    $script:cSnipSettings = $script:Chat.FindName("SnipSettingsBtn")

    $script:ModeCycleButton = $script:cModeCycle
    $script:ClippyTabStrip = $script:cTabStrip
    $script:ClippyAddTabButton = $script:cTabAdd
}

function script:Apply-ChatWindowBranding {
    if ($script:WidgetIconLarge -and $script:cTIcon) {
        $script:cTIcon.Source = $script:WidgetIconLarge
    }

    if ($script:WidgetIconSmall) {
        $script:Chat.Icon = $script:WidgetIconSmall
    } elseif ($script:WidgetIconLarge) {
        $script:Chat.Icon = $script:WidgetIconLarge
    }
}

function script:Initialize-ChatWindow {
    script:Set-ChatWindowReferences -Window (script:New-ChatWindowInstance)
    script:Apply-ChatWindowBranding
}

# Named elements
$wRing   = $script:Widget.FindName("Ring")
$wIcon   = $script:Widget.FindName("Icon")
script:Initialize-ChatWindow


# ── Load icon ─────────────────────────────────────────────────────
function script:Load-Icon ([string]$Path) {
    $bmp = [Windows.Media.Imaging.BitmapImage]::new()
    $bmp.BeginInit()
    $bmp.UriSource   = [Uri]::new($Path)
    $bmp.CacheOption = 'OnLoad'
    $bmp.EndInit()
    $bmp.Freeze()
    return $bmp
}

$iconLarge = Join-Path $AssetsDir "clippy25_128.png"
$iconSmall = Join-Path $AssetsDir "clippy25_32.png"
$script:WidgetIconLarge = $null
$script:WidgetIconSmall = $null
if (Test-Path $iconLarge) {
    $script:WidgetIconLarge = script:Load-Icon $iconLarge
    $wIcon.Source = $script:WidgetIconLarge
}
if (Test-Path $iconSmall) {
    $script:WidgetIconSmall = script:Load-Icon $iconSmall
    $script:Widget.Icon = $script:WidgetIconSmall
} elseif ($script:WidgetIconLarge) {
    $script:Widget.Icon = $script:WidgetIconLarge
}
script:Apply-ChatWindowBranding

# ── Position widget at bottom-right of primary monitor ────────────
$wa = [System.Windows.SystemParameters]::WorkArea
$script:Widget.Left = $wa.Right - $script:Widget.Width - 20
$script:Widget.Top  = $wa.Bottom - $script:Widget.Height - 20

# Chat owner is assigned lazily after the widget is visible.

# ── Helper: colored terminal output ──────────────────────────────
function script:Invoke-OnUiThread {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,
        [switch]$Async
    )

    if (-not $script:Chat -or -not $script:Chat.Dispatcher -or $script:Chat.Dispatcher.HasShutdownStarted) {
        return
    }

    if ($script:Chat.Dispatcher.CheckAccess()) {
        try {
            & $Action
        } catch {
            script:Write-WidgetDebugLog "UI action failed [direct] $($_.Exception.Message)"
        }
        return
    }

    if ($Async) {
        [void]$script:Chat.Dispatcher.BeginInvoke([Action] {
            try {
                & $Action
            } catch {
                script:Write-WidgetDebugLog "UI action failed [async] $($_.Exception.Message)"
            }
        }, [Windows.Threading.DispatcherPriority]::Background)
        return
    }

    try {
        $script:Chat.Dispatcher.Invoke([Action] {
            try {
                & $Action
            } catch {
                script:Write-WidgetDebugLog "UI action failed [invoke] $($_.Exception.Message)"
            }
        }, [Windows.Threading.DispatcherPriority]::Background)
    } catch {
        script:Write-WidgetDebugLog "UI dispatch failed [invoke] $($_.Exception.Message)"
    }
}

function script:New-TranscriptDocument {
    $document = [Windows.Documents.FlowDocument]::new()
    $document.PagePadding = [Windows.Thickness]::new(0)
    return $document
}

function script:Get-ClippyTab {
    param([string]$TabId)

    if ([string]::IsNullOrWhiteSpace($TabId)) {
        return $null
    }

    if ($script:ClippyTabs.Contains($TabId)) {
        return $script:ClippyTabs[$TabId]
    }

    return $null
}

function script:Get-ActiveClippyTab {
    return script:Get-ClippyTab -TabId $script:ActiveClippyTabId
}

function script:Get-BusyClippyTabs {
    $busyTabs = [System.Collections.Generic.List[object]]::new()
    foreach ($tabId in @($script:ClippyTabOrder)) {
        $tab = script:Get-ClippyTab -TabId $tabId
        if ($tab -and $tab.StreamState -and $tab.StreamState.WaitingForResponse) {
            [void]$busyTabs.Add($tab)
        }
    }

    return @($busyTabs)
}

function script:Sync-CopilotBusyState {
    $busyTabs = @(script:Get-BusyClippyTabs)
    $activeTab = script:Get-ActiveClippyTab
    $activeBusyTab = $null

    if ($activeTab -and $activeTab.StreamState -and $activeTab.StreamState.WaitingForResponse) {
        $activeBusyTab = $activeTab
    } elseif ($busyTabs.Count -gt 0) {
        $activeBusyTab = $busyTabs[0]
    }

    $script:IsCopilotCommandRunning = ($busyTabs.Count -gt 0)
    $script:BusyTabId = if ($activeBusyTab) { [string]$activeBusyTab.TabId } else { $null }
    $script:ActiveCopilotProcess = if ($activeBusyTab) { $activeBusyTab.HostProcess } else { $null }

    script:Invoke-OnUiThread -Async -Action {
        $uiActiveTab = script:Get-ActiveClippyTab
        $activeTabBusy = [bool]($uiActiveTab -and $uiActiveTab.StreamState -and $uiActiveTab.StreamState.WaitingForResponse)
        # Kernel tabs have an active TerminalHost that accepts 'write' actions via
        # Invoke-Cmd, so the widget prompt should remain enabled for them.  Only the
        # busy-state guard (waiting-for-response) is preserved here.
        if ($script:cRun) {
            $script:cRun.IsEnabled = -not $activeTabBusy
        }
        if ($script:cInput) {
            $script:cInput.IsEnabled = -not $activeTabBusy
        }
    }

    script:Refresh-ClippyTabStrip
    script:Update-WidgetStatus
}

function script:Set-CopilotBusyState {
    param([bool]$Busy)

    script:Sync-CopilotBusyState
}

function script:Get-ActiveSessionId {
    $tab = script:Get-ActiveClippyTab
    if ($tab -and $tab.SessionId) {
        return [string]$tab.SessionId
    }

    return $script:CopilotSessionId
}

function script:New-ClippyTerminalSurfaceState {
    return [hashtable]::Synchronized(@{
        Process = $null
        Hwnd = [IntPtr]::Zero
        Panel = $null
        FormsHost = $null
        StdinWriter = $null
        Ready = $false
        SummaryBlock = $null
        AdaptiveCardSnapshot = $null
        AdaptiveCardJson = $null
        AdaptiveCardDataJson = $null
    })
}

function script:New-ClippyBrowserSurfaceState {
    return [hashtable]::Synchronized(@{
        Address = $null
        Metadata = $null
    })
}

function script:New-ClippyNoteSurfaceState {
    return [hashtable]::Synchronized(@{
        Content = $null
        Metadata = $null
    })
}

function script:Normalize-ClippySurfaceKind {
    param(
        [string]$SurfaceKind,
        [string]$Runtime
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($SurfaceKind)) {
        $null
    } else {
        ([string]$SurfaceKind).ToLowerInvariant()
    }

    switch ($candidate) {
        $script:ClippySurfaceTerminal { return $script:ClippySurfaceTerminal }
        $script:ClippySurfaceBrowser { return $script:ClippySurfaceBrowser }
        $script:ClippySurfaceNote { return $script:ClippySurfaceNote }
        default { return $script:ClippySurfaceTerminal }
    }
}

function script:Normalize-ClippyHostTransportKind {
    param([string]$HostTransportKind)

    $candidate = if ([string]::IsNullOrWhiteSpace($HostTransportKind)) {
        $null
    } else {
        ([string]$HostTransportKind).ToLowerInvariant()
    }

    switch ($candidate) {
        $script:ClippyHostTransportEmbeddedTerminal { return $script:ClippyHostTransportEmbeddedTerminal }
        $script:ClippyHostTransportNodeBridge { return $script:ClippyHostTransportNodeBridge }
        default { return $script:ClippyHostTransportNone }
    }
}

function script:Sync-ClippyTabLegacySurfaceFields {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    $terminalSurface = $Tab.TerminalSurface
    if (-not $terminalSurface) {
        return
    }

    $surfaceKind = script:Normalize-ClippySurfaceKind -SurfaceKind ([string]$Tab.SurfaceKind) -Runtime ([string]$Tab.Runtime)
    $hostTransportKind = script:Normalize-ClippyHostTransportKind -HostTransportKind ([string]$Tab.HostTransportKind)
    $Tab.SurfaceKind = $surfaceKind
    $Tab.HostTransportKind = $hostTransportKind
    $Tab.UseEmbeddedTerminal = ($surfaceKind -eq $script:ClippySurfaceTerminal) -and ($hostTransportKind -eq $script:ClippyHostTransportEmbeddedTerminal)
    $Tab.TerminalProcess = $terminalSurface.Process
    $Tab.TerminalHwnd = $terminalSurface.Hwnd
    $Tab.TerminalPanel = $terminalSurface.Panel
    $Tab.TerminalFormsHost = $terminalSurface.FormsHost
    $Tab.TerminalStdinWriter = $terminalSurface.StdinWriter
    $Tab.TerminalReady = [bool]$terminalSurface.Ready
    $Tab.TerminalSummaryBlock = $terminalSurface.SummaryBlock
    $Tab.AdaptiveCardSnapshot = $terminalSurface.AdaptiveCardSnapshot
    $Tab.AdaptiveCardJson = $terminalSurface.AdaptiveCardJson
    $Tab.AdaptiveCardDataJson = $terminalSurface.AdaptiveCardDataJson
}

function script:Ensure-ClippyTabSurfaceState {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return $null
    }

    $Tab.SurfaceKind = script:Normalize-ClippySurfaceKind -SurfaceKind ([string]$Tab.SurfaceKind) -Runtime ([string]$Tab.Runtime)
    $Tab.HostTransportKind = script:Normalize-ClippyHostTransportKind -HostTransportKind ([string]$Tab.HostTransportKind)

    if (-not $Tab.TerminalSurface) {
        $Tab.TerminalSurface = script:New-ClippyTerminalSurfaceState
    }
    if (-not $Tab.BrowserSurface) {
        $Tab.BrowserSurface = script:New-ClippyBrowserSurfaceState
    }
    if (-not $Tab.NoteSurface) {
        $Tab.NoteSurface = script:New-ClippyNoteSurfaceState
    }

    $terminalSurface = $Tab.TerminalSurface
    if (-not $terminalSurface.Process -and $Tab.TerminalProcess) {
        $terminalSurface.Process = $Tab.TerminalProcess
    }
    if (($terminalSurface.Hwnd -eq [IntPtr]::Zero) -and ($Tab.TerminalHwnd -ne [IntPtr]::Zero)) {
        $terminalSurface.Hwnd = $Tab.TerminalHwnd
    }
    if (-not $terminalSurface.Panel -and $Tab.TerminalPanel) {
        $terminalSurface.Panel = $Tab.TerminalPanel
    }
    if (-not $terminalSurface.FormsHost -and $Tab.TerminalFormsHost) {
        $terminalSurface.FormsHost = $Tab.TerminalFormsHost
    }
    if (-not $terminalSurface.StdinWriter -and $Tab.TerminalStdinWriter) {
        $terminalSurface.StdinWriter = $Tab.TerminalStdinWriter
    }
    if (-not $terminalSurface.Ready -and $Tab.TerminalReady) {
        $terminalSurface.Ready = [bool]$Tab.TerminalReady
    }
    if (-not $terminalSurface.SummaryBlock -and $Tab.TerminalSummaryBlock) {
        $terminalSurface.SummaryBlock = $Tab.TerminalSummaryBlock
    }
    if (-not $terminalSurface.AdaptiveCardSnapshot -and $Tab.AdaptiveCardSnapshot) {
        $terminalSurface.AdaptiveCardSnapshot = $Tab.AdaptiveCardSnapshot
    }
    if ([string]::IsNullOrWhiteSpace([string]$terminalSurface.AdaptiveCardJson) -and -not [string]::IsNullOrWhiteSpace([string]$Tab.AdaptiveCardJson)) {
        $terminalSurface.AdaptiveCardJson = [string]$Tab.AdaptiveCardJson
    }
    if ([string]::IsNullOrWhiteSpace([string]$terminalSurface.AdaptiveCardDataJson) -and -not [string]::IsNullOrWhiteSpace([string]$Tab.AdaptiveCardDataJson)) {
        $terminalSurface.AdaptiveCardDataJson = [string]$Tab.AdaptiveCardDataJson
    }

    script:Sync-ClippyTabLegacySurfaceFields -Tab $Tab
    return $Tab
}

function script:Get-TabSurfaceKind {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    if ($Tab) {
        [void](script:Ensure-ClippyTabSurfaceState -Tab $Tab)
        return [string]$Tab.SurfaceKind
    }

    return $script:ClippySurfaceTerminal
}

function script:Get-TabHostTransportKind {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    if ($Tab) {
        [void](script:Ensure-ClippyTabSurfaceState -Tab $Tab)
        return [string]$Tab.HostTransportKind
    }

    return $script:ClippyHostTransportNone
}

function script:Set-TabHostTransportKind {
    param(
        [hashtable]$Tab,
        [string]$HostTransportKind
    )

    if (-not $Tab) {
        return $script:ClippyHostTransportNone
    }

    [void](script:Ensure-ClippyTabSurfaceState -Tab $Tab)
    $Tab.HostTransportKind = script:Normalize-ClippyHostTransportKind -HostTransportKind $HostTransportKind
    script:Sync-ClippyTabLegacySurfaceFields -Tab $Tab
    return [string]$Tab.HostTransportKind
}

function script:Get-TabTerminalSurfaceState {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    if (-not $Tab) {
        return $null
    }

    [void](script:Ensure-ClippyTabSurfaceState -Tab $Tab)
    return $Tab.TerminalSurface
}

function script:Test-ClippyTerminalSurfaceTab {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    return ((script:Get-TabSurfaceKind -Tab $Tab) -eq $script:ClippySurfaceTerminal)
}

function script:Test-ClippyEmbeddedTerminalTab {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    return ((script:Get-TabHostTransportKind -Tab $Tab) -eq $script:ClippyHostTransportEmbeddedTerminal)
}

function script:Get-TabRuntime {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    if ($Tab -and -not [string]::IsNullOrWhiteSpace([string]$Tab.Runtime)) {
        return ([string]$Tab.Runtime).ToLowerInvariant()
    }

    return $script:ClippyRuntimeKernel
}

function script:Test-ClippyKernelTab {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    return ((script:Get-TabRuntime -Tab $Tab) -eq $script:ClippyRuntimeKernel)
}

function script:Get-TabRuntimeDisplayName {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    switch (script:Get-TabRuntime -Tab $Tab) {
        $script:ClippyRuntimeKernel { return 'Clippy Kernel' }
        $script:ClippyRuntimeCopilot { return 'Clippy Terminal' }
        default { return 'Terminal' }
    }
}

function script:Get-ActiveTabMode {
    $tab = script:Get-ActiveClippyTab
    if ($tab -and $tab.Mode) {
        return [string]$tab.Mode
    }

    if ($script:WidgetSettings) {
        return [string]$script:WidgetSettings.Mode
    }

    return 'Agent'
}

function script:Get-ActiveTabModelId {
    $tab = script:Get-ActiveClippyTab
    if ($tab -and $tab.Model) {
        return [string]$tab.Model
    }

    if ($script:WidgetSettings) {
        return [string]$script:WidgetSettings.Model
    }

    return $null
}

function script:Get-ActiveTabAgentToken {
    $tab = script:Get-ActiveClippyTab
    if ($tab) {
        return [string]$tab.Agent
    }

    if ($script:WidgetSettings) {
        return [string]$script:WidgetSettings.Agent
    }

    return $null
}

function script:Get-ResolvedAgentIdForTab {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    $mode = if ($Tab -and $Tab.Mode) { [string]$Tab.Mode } else { script:Get-ActiveTabMode }
    if ($mode -eq 'Swarm' -and ($script:AvailableAgents.Id -contains 'dayswarm')) {
        return 'dayswarm'
    }

    $token = if ($Tab) { [string]$Tab.Agent } else { script:Get-ActiveTabAgentToken }
    $resolved = script:Resolve-AgentToken -Token $token
    if ($resolved) {
        return $resolved
    }

    return script:Get-DefaultAgentId
}

function script:Get-TabShortSessionId {
    param([hashtable]$Tab)

    if (-not $Tab -or [string]::IsNullOrWhiteSpace([string]$Tab.SessionId)) {
        return 'pending'
    }

    $str = [string]$Tab.SessionId
    if ($str.Length -le 8) { return $str }
    return $str.Substring(0, 8)
}

function script:Get-DefaultTabDisplayName {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return 'Clippy'
    }

    if (script:Test-ClippyKernelTab -Tab $Tab) {
        return 'Kernel {0}' -f (script:Get-TabShortSessionId -Tab $Tab)
    }

    $modeLabel = if ([string]::IsNullOrWhiteSpace([string]$Tab.Mode)) { 'Agent' } else { [string]$Tab.Mode }
    return '{0} {1}' -f $modeLabel, (script:Get-TabShortSessionId -Tab $Tab)
}

function script:Get-TabAgentDisplayName {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    if (script:Test-ClippyKernelTab -Tab $Tab) {
        return 'n/a'
    }

    $agentId = script:Get-ResolvedAgentIdForTab -Tab $Tab
    if ([string]::IsNullOrWhiteSpace($agentId)) {
        return 'Terminal'
    }

    $definition = script:Get-AgentDefinition -AgentId $agentId
    if ($definition) {
        return [string]$definition.DisplayName
    }

    return [string]$agentId
}

function script:Get-TabModelDisplayName {
    param([hashtable]$Tab = $(script:Get-ActiveClippyTab))

    $modelId = if ($Tab -and -not [string]::IsNullOrWhiteSpace([string]$Tab.Model)) {
        [string]$Tab.Model
    } else {
        script:Get-ActiveTabModelId
    }

    if ([string]::IsNullOrWhiteSpace($modelId)) {
        return 'default'
    }

    $definition = script:Get-ModelDefinition -ModelId $modelId
    if ($definition) {
        return [string]$definition.DisplayName
    }

    return [string]$modelId
}

function script:Get-TabTerminalTitle {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return 'Terminal'
    }

    if (script:Test-ClippyKernelTab -Tab $Tab) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Tab.DisplayName)) {
            return [string]$Tab.DisplayName
        }

        return 'Clippy Kernel'
    }

    $agentDisplay = script:Get-TabAgentDisplayName -Tab $Tab
    if (-not [string]::IsNullOrWhiteSpace($agentDisplay) -and $agentDisplay -ne 'none') {
        return $agentDisplay
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Tab.DisplayName)) {
        return [string]$Tab.DisplayName
    }

    return 'Terminal'
}

function script:Get-TabModeBadgeInfo {
    param([hashtable]$Tab)

    $mode = if ($Tab -and -not [string]::IsNullOrWhiteSpace([string]$Tab.Mode)) {
        [string]$Tab.Mode
    } else {
        'Agent'
    }

    switch ($mode.ToLowerInvariant()) {
        'plan' {
            return [pscustomobject]@{
                Label = 'plan'
                Background = '#FF3A2D14'
                Foreground = '#FFFBBF24'
            }
        }
        'swarm' {
            return [pscustomobject]@{
                Label = 'swarm'
                Background = '#FF143A2D'
                Foreground = '#FF34D399'
            }
        }
        default {
            return [pscustomobject]@{
                Label = 'agent'
                Background = '#FF172554'
                Foreground = '#FF93C5FD'
            }
        }
    }
}

function script:Get-TabHostStateInfo {
    param([hashtable]$Tab)

    $state = if ($Tab -and -not [string]::IsNullOrWhiteSpace([string]$Tab.HostState)) {
        ([string]$Tab.HostState).ToLowerInvariant()
    } else {
        'pending'
    }

    switch ($state) {
        'running' {
            return [pscustomobject]@{
                State = $state
                Label = 'Running'
                DotColor = '#FF34D399'
                TextColor = '#FF34D399'
                AccentColor = '#FF34D399'
            }
        }
        'connecting' {
            return [pscustomobject]@{
                State = $state
                Label = 'Connecting...'
                DotColor = '#FFFBBF24'
                TextColor = '#FFFBBF24'
                AccentColor = '#FFFBBF24'
            }
        }
        'error' {
            return [pscustomobject]@{
                State = $state
                Label = 'Error'
                DotColor = '#FFF44747'
                TextColor = '#FFF44747'
                AccentColor = '#FFF44747'
            }
        }
        'stopped' {
            return [pscustomobject]@{
                State = $state
                Label = 'Stopped'
                DotColor = '#FF6B7280'
                TextColor = '#FF9CA3AF'
                AccentColor = '#FF6B7280'
            }
        }
        default {
            return [pscustomobject]@{
                State = $state
                Label = 'Pending'
                DotColor = '#FF5B5FC7'
                TextColor = '#FFB7B7D6'
                AccentColor = '#FF5B5FC7'
            }
        }
    }
}

function script:Format-TerminalPreviewText {
    param(
        [string]$Text,
        [int]$MaxLength = 120
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $normalized = ($Text -replace '\s+', ' ').Trim()
    if ($normalized.Length -le $MaxLength) {
        return $normalized
    }

    return ($normalized.Substring(0, $MaxLength - 3).TrimEnd() + '...')
}

function script:Update-ActiveSessionContext {
    $activeTab = script:Get-ActiveClippyTab
    if ($activeTab) {
        $script:CopilotSessionId = [string]$activeTab.SessionId
        return
    }

    $script:CopilotSessionId = $null
}

function script:Show-ClippyTabDocument {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    [void](script:Ensure-ClippyTabSurfaceState -Tab $Tab)
    $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $Tab

    foreach ($tabId in @($script:ClippyTabOrder)) {
        $candidateTab = script:Get-ClippyTab -TabId $tabId
        if ($candidateTab) {
            $candidateTerminalSurface = script:Get-TabTerminalSurfaceState -Tab $candidateTab
            if ($candidateTerminalSurface -and $candidateTerminalSurface.FormsHost) {
                $candidateTerminalSurface.FormsHost.Visibility = 'Collapsed'
            }
        }
    }

    if ((script:Test-ClippyTerminalSurfaceTab -Tab $Tab) -and (script:Test-ClippyEmbeddedTerminalTab -Tab $Tab) -and $terminalSurface -and -not $terminalSurface.FormsHost) {
        script:Ensure-ClippyTabTerminalPanel -Tab $Tab
        $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $Tab
    }

    if ((script:Test-ClippyTerminalSurfaceTab -Tab $Tab) -and (script:Test-ClippyEmbeddedTerminalTab -Tab $Tab) -and $terminalSurface -and $terminalSurface.FormsHost) {
        if ($cOutput) {
            $cOutput.Visibility = 'Collapsed'
        }
        $terminalSurface.FormsHost.Visibility = 'Visible'
        # Only attempt synchronous attach after the WPF window is presenting. Before
        # $app.Run(), $script:Chat.IsLoaded is false and SetParent/SetWindowLongPtr
        # would block waiting for the TerminalHost's message pump. Let the queued
        # attach timer handle the first attach after the window becomes visible.
        if ($script:Chat -and $script:Chat.IsLoaded) {
            [void](script:Attach-ClippyTerminalWindow -Tab $Tab)
        }
        script:Queue-ClippyTerminalWindowAttach -Tab $Tab
        return
    }

    if (-not $cOutput) {
        return
    }

    $cOutput.Visibility = 'Visible'

    if (-not $Tab.Document) {
        $Tab.Document = script:New-TranscriptDocument
    }

    if ($cOutput.Document -ne $Tab.Document) {
        $cOutput.Document = $Tab.Document
    }

    $cOutput.ScrollToEnd()
}

function script:New-TabCopilotStreamState {
    param([string]$TabId)

    return [hashtable]::Synchronized(@{
        TabId = $TabId
        ToolCalls = [hashtable]::Synchronized(@{})
        StreamedAssistantText = ''
        FinalAssistantText = ''
        HadAssistantOutput = $false
        HadToolOutput = $false
        StreamedThoughtText = ''
        FinalThoughtText = ''
        HadThoughtOutput = $false
        ExitCode = $null
        Completed = $false
        WaitingForResponse = $false
    })
}

function script:Reset-TabCopilotStreamState {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return $null
    }

    $Tab.ActiveAssistantStream = $null
    $Tab.ActiveThoughtStream = $null
    $Tab.StreamState = script:New-TabCopilotStreamState -TabId ([string]$Tab.TabId)
    return $Tab.StreamState
}

function script:New-ClippyTabState {
    param(
        [string]$SessionId,
        [string]$Mode,
        [string]$Model,
        [string]$Agent,
        [string]$Runtime,
        [string]$SurfaceKind
    )

    $resolvedSessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) {
        ([guid]::NewGuid()).Guid
    } else {
        $SessionId
    }

    $resolvedMode = if ([string]::IsNullOrWhiteSpace($Mode)) { 'Agent' } else { $Mode }
    $resolvedModel = if ([string]::IsNullOrWhiteSpace($Model)) { $script:WidgetSettings.Model } else { $Model }
    $resolvedAgent = if ($null -eq $Agent) { $script:WidgetSettings.Agent } else { $Agent }
    $resolvedRuntime = if ([string]::IsNullOrWhiteSpace($Runtime)) { $script:ClippyRuntimeKernel } else { ([string]$Runtime).ToLowerInvariant() }
    $resolvedSurfaceKind = script:Normalize-ClippySurfaceKind -SurfaceKind $SurfaceKind -Runtime $resolvedRuntime
    $tab = [hashtable]::Synchronized(@{
        TabId = ([guid]::NewGuid()).Guid
        SessionId = $resolvedSessionId
        Mode = $resolvedMode
        Model = $resolvedModel
        Agent = $resolvedAgent
        Runtime = $resolvedRuntime
        SurfaceKind = $resolvedSurfaceKind
        HostTransportKind = $script:ClippyHostTransportNone
        TerminalSurface = $(script:New-ClippyTerminalSurfaceState)
        BrowserSurface = $(script:New-ClippyBrowserSurfaceState)
        NoteSurface = $(script:New-ClippyNoteSurfaceState)
        DisplayName = $null
        Document = $(script:New-TranscriptDocument)
        ActiveAssistantStream = $null
        ActiveThoughtStream = $null
        StreamState = $null
        HostProcess = $null
        HostPump = $null
        HostStdoutTask = $null
        HostStderrTask = $null
        HostUsesEventedRead = $false
        HostState = 'pending'
        HostPid = $null
        HostMetadata = $null
        AdaptiveCardSnapshot = $null
        AdaptiveCardJson = $null
        AdaptiveCardDataJson = $null
        TerminalSummaryBlock = $null
        MetadataReceived = $false
        ClosingRequested = $false
        UseEmbeddedTerminal = $false
        TerminalProcess = $null
        TerminalHwnd = [IntPtr]::Zero
        TerminalPanel = $null
        TerminalFormsHost = $null
        TerminalStdinWriter = $null
        TerminalReady = $false
        CreatedAt = (Get-Date).ToString('o')
    })
    [void](script:Ensure-ClippyTabSurfaceState -Tab $tab)
    $tab.DisplayName = script:Get-DefaultTabDisplayName -Tab $tab
    [void](script:Reset-TabCopilotStreamState -Tab $tab)
    return $tab
}

function script:Get-SessionHostScriptPath {
    return Join-Path $script:RepoRoot 'scripts\terminal-session-host.js'
}

function script:ConvertTo-ProcessArgumentString {
    param([string[]]$Arguments)

    $parts = foreach ($argument in $Arguments) {
        if ($null -eq $argument) { continue }

        $value = [string]$argument
        if ($value -match '[\s"]') {
            $escaped = $value -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            '"{0}"' -f $escaped
        } else {
            $value
        }
    }

    return ($parts -join ' ')
}

function script:Test-ClippyTerminalHostAvailable {
    return (-not [string]::IsNullOrWhiteSpace($script:TerminalHostExe)) -and (Test-Path $script:TerminalHostExe -PathType Leaf)
}

function script:Get-ClippyKernelLaunchSpec {
    param([hashtable]$Tab)

    if ([string]::IsNullOrWhiteSpace($script:ClippyKernelRoot)) {
        throw 'Clippy kernel root is not configured.'
    }

    if (-not (Test-Path $script:ClippyKernelRoot -PathType Container)) {
        throw "Clippy kernel root was not found: $($script:ClippyKernelRoot)"
    }

    $commandArguments = $null
    if (Test-Path $script:ClippyKernelSweExe -PathType Leaf) {
        $commandArguments = @($script:ClippyKernelSweExe, 'interactive')
    } elseif (Test-Path $script:ClippyKernelPythonExe -PathType Leaf) {
        $commandArguments = @($script:ClippyKernelPythonExe, '-m', 'autogen.cli.clippy_swe_cli', 'interactive')
    } else {
        throw ("Clippy kernel startup failed for tab '{0}'. Neither '{1}' nor '{2}' was found." -f (script:Get-TabTerminalTitle -Tab $Tab), $script:ClippyKernelSweExe, $script:ClippyKernelPythonExe)
    }

    return [pscustomobject]@{
        WorkingDirectory = $script:ClippyKernelRoot
        CommandLine = (script:ConvertTo-ProcessArgumentString -Arguments $commandArguments)
    }
}

function script:ConvertTo-PowerShellSingleQuotedLiteral {
    param([string]$Value)

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function script:ConvertTo-PowerShellArrayLiteral {
    param([string[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return '@()'
    }

    $items = foreach ($item in $Values) {
        script:ConvertTo-PowerShellSingleQuotedLiteral -Value $item
    }

    return '@(' + ($items -join ', ') + ')'
}

function script:New-CopilotTerminalStartupScript {
    param([hashtable]$Tab)

    $copilotArgs = [System.Collections.Generic.List[string]]::new()
    $copilotArgs.Add("--resume=$([string]$Tab.SessionId)")
    $copilotArgs.Add('--config-dir')
    $copilotArgs.Add($script:CopilotConfigDir)

    if (-not [string]::IsNullOrWhiteSpace([string]$Tab.Model)) {
        $copilotArgs.Add('--model')
        $copilotArgs.Add([string]$Tab.Model)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Tab.Mode)) {
        $copilotArgs.Add('--mode')
        $copilotArgs.Add(([string]$Tab.Mode).ToLowerInvariant())
    }

    $resolvedAgent = script:Get-ResolvedAgentIdForTab -Tab $Tab
    if (-not [string]::IsNullOrWhiteSpace($resolvedAgent)) {
        $copilotArgs.Add('--agent')
        $copilotArgs.Add($resolvedAgent)
    }

    if ($script:WidgetSettings.Tools.AllowAllTools) {
        $copilotArgs.Add('--allow-all-tools')
    }
    if ($script:WidgetSettings.Tools.AllowAllPaths) {
        $copilotArgs.Add('--allow-all-paths')
    }
    if ($script:WidgetSettings.Tools.AllowAllUrls) {
        $copilotArgs.Add('--allow-all-urls')
    }
    if ($script:WidgetSettings.Tools.Experimental) {
        $copilotArgs.Add('--experimental')
    }
    if ($script:WidgetSettings.Tools.Autopilot) {
        $copilotArgs.Add('--autopilot')
    }
    if ($script:WidgetSettings.Tools.EnableAllGitHubMcpTools) {
        $copilotArgs.Add('--enable-all-github-mcp-tools')
    }

    $copilotArgsLiteral = script:ConvertTo-PowerShellArrayLiteral -Values @($copilotArgs)
    $workingDirectoryLiteral = script:ConvertTo-PowerShellSingleQuotedLiteral -Value $script:RepoRoot
    $displayNameLiteral = script:ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$Tab.DisplayName)
    $sessionIdLiteral = script:ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$Tab.SessionId)

    return @(
        ('$Host.UI.RawUI.WindowTitle = {0}' -f $displayNameLiteral),
        ('$Global:ClippySessionId = {0}' -f $sessionIdLiteral),
        ('$Global:ClippyWorkingDirectory = {0}' -f $workingDirectoryLiteral),
        ('function global:Start-ClippyCopilot { param([string[]]$ExtraArgs) $clippyArgs = {0}; & copilot @clippyArgs @ExtraArgs }' -f $copilotArgsLiteral),
        'Set-Alias -Name clippyresume -Value Start-ClippyCopilot -Scope Global',
        ('Set-Location -LiteralPath {0}' -f $workingDirectoryLiteral),
        'Write-Host ''Clippy terminal ready. Use regular PowerShell commands or run "clippyresume" to attach Copilot.'''
    ) -join '; '
}

function script:ConvertTo-NativeIntPtr {
    param($Value)

    if ($Value -is [IntPtr]) {
        return $Value
    }

    if ($null -eq $Value) {
        return [IntPtr]::Zero
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [IntPtr]::Zero
    }

    if ($text.StartsWith('0x', [System.StringComparison]::OrdinalIgnoreCase)) {
        $parsed = [int64]::Parse($text.Substring(2), [System.Globalization.NumberStyles]::HexNumber)
        return [IntPtr]::new($parsed)
    }

    return [IntPtr]::new([int64]$text)
}

function script:Reset-ClippyTabTerminalSurfaceState {
    param(
        [hashtable]$Tab,
        [switch]$RemovePanel
    )

    if (-not $Tab) {
        return
    }

    $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $Tab
    if (-not $terminalSurface) {
        return
    }

    if ($RemovePanel -and $terminalSurface.FormsHost -and $script:cOutputHost) {
        $formsHost = $terminalSurface.FormsHost
        script:Invoke-OnUiThread -Action {
            try {
                [void]$script:cOutputHost.Children.Remove($formsHost)
            } catch {
            }
        }
        $terminalSurface.FormsHost = $null
        $terminalSurface.Panel = $null
    }

    $terminalSurface.Process = $null
    $terminalSurface.StdinWriter = $null
    $terminalSurface.Hwnd = [IntPtr]::Zero
    $terminalSurface.Ready = $false
    [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
    script:Sync-ClippyTabLegacySurfaceFields -Tab $Tab
}

function script:Ensure-ClippyTabTerminalPanel {
    param([hashtable]$Tab)

    if (-not $Tab -or -not $script:cOutputHost) {
        return
    }

    $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $Tab

    script:Invoke-OnUiThread -Action {
        if ($terminalSurface.FormsHost -and $terminalSurface.Panel) {
            return
        }

        $formsHost = [System.Windows.Forms.Integration.WindowsFormsHost]::new()
        $formsHost.Visibility = 'Collapsed'

        $panel = [System.Windows.Forms.Panel]::new()
        $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
        $panel.Tag = [string]$Tab.TabId
        $panel.Add_Resize({
            param($sender, $eventArgs)

            $resizeTab = script:Get-ClippyTab -TabId ([string]$sender.Tag)
            if ($resizeTab) {
                script:Resize-ClippyTerminalSurface -Tab $resizeTab
            }
        })

        $formsHost.Child = $panel
        [void]$script:cOutputHost.Children.Add($formsHost)

        $terminalSurface.FormsHost = $formsHost
        $terminalSurface.Panel = $panel
        script:Sync-ClippyTabLegacySurfaceFields -Tab $Tab
    }
}

function script:Read-ClippyTerminalHostReadyMessage {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutMs = 5000
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $task = $Process.StandardOutput.ReadLineAsync()
    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($task.Wait(250)) {
            $line = $task.Result
            if ($null -eq $line) {
                break
            }

            if ([string]::IsNullOrWhiteSpace([string]$line)) {
                $task = $Process.StandardOutput.ReadLineAsync()
                continue
            }

            script:Write-WidgetDebugLog "TERM-STDOUT [pending] $line"

            try {
                $message = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $task = $Process.StandardOutput.ReadLineAsync()
                continue
            }

            if ($message.PSObject.Properties.Name -contains 'type') {
                return $message
            }

            $task = $Process.StandardOutput.ReadLineAsync()
            continue
        }

        if ($Process.HasExited) {
            break
        }
    }

    return $null
}

function script:Resize-ClippyTerminalSurface {
    param([hashtable]$Tab)

    if (-not $Tab -or -not $Tab.TerminalPanel) {
        return
    }

    $terminalHwnd = script:ConvertTo-NativeIntPtr -Value $Tab.TerminalHwnd
    if ($terminalHwnd -eq [IntPtr]::Zero) {
        return
    }

    $width = [Math]::Max([int]$Tab.TerminalPanel.ClientSize.Width, 0)
    $height = [Math]::Max([int]$Tab.TerminalPanel.ClientSize.Height, 0)
    if ($width -le 0 -or $height -le 0) {
        return
    }

    [void]$script:User32::MoveWindow($terminalHwnd, 0, 0, $width, $height, $true)

    if ($Tab.TerminalStdinWriter) {
        $cols = [Math]::Max(20, [int][Math]::Floor($width / 9))
        $rows = [Math]::Max(5, [int][Math]::Floor($height / 20))

        try {
            $payload = @{
                type = 'host.command'
                payload = @{
                    command = 'session.resize'
                    cols = $cols
                    rows = $rows
                }
                action = 'resize'
                cols = $cols
                rows = $rows
            } | ConvertTo-Json -Compress -Depth 8
            $Tab.TerminalStdinWriter.WriteLine($payload)
            $Tab.TerminalStdinWriter.Flush()
        } catch {
            script:Write-WidgetDebugLog "Terminal resize failed [$([string]$Tab.TabId)] $($_.Exception.Message)"
        }
    }
}

function script:Attach-ClippyTerminalWindow {
    param([hashtable]$Tab)

    if (-not $Tab -or -not $Tab.TerminalPanel) {
        if ($Tab) {
            script:Write-WidgetDebugLog "Attach skipped [$($Tab.TabId)] terminal panel not ready."
        }
        return $false
    }

    $terminalHwnd = script:ConvertTo-NativeIntPtr -Value $Tab.TerminalHwnd
    if ($terminalHwnd -eq [IntPtr]::Zero) {
        script:Write-WidgetDebugLog "Attach: terminalHwnd is zero [$($Tab.TabId)]"
        return $false
    }

    script:Write-WidgetDebugLog "Attach: checking IsHandleCreated [$($Tab.TabId)]"
    # Do not access .Handle if the WinForms Panel hasn't been created yet. Accessing
    # .Handle before the WPF host window has presented will block or create an orphan
    # HWND. Callers must use Queue-ClippyTerminalWindowAttach for deferred attach.
    if (-not $Tab.TerminalPanel.IsHandleCreated) {
        script:Write-WidgetDebugLog "Attach deferred [$($Tab.TabId)] panel handle not yet created."
        return $false
    }

    script:Write-WidgetDebugLog "Attach: getting panel Handle [$($Tab.TabId)]"
    $parentHwnd = $Tab.TerminalPanel.Handle
    if ($parentHwnd -eq [IntPtr]::Zero) {
        script:Write-WidgetDebugLog "Attach deferred [$($Tab.TabId)] terminal panel handle is zero."
        return $false
    }

    script:Write-WidgetDebugLog "Attach: calling GetWindowLongPtr on 0x$('{0:X}' -f $terminalHwnd.ToInt64()) [$($Tab.TabId)]"
    $stylePtr = $script:User32::GetWindowLongPtr($terminalHwnd, $script:GWL_STYLE)
    if ($stylePtr -eq [IntPtr]::Zero) {
        script:Write-WidgetDebugLog "Attach skipped [$($Tab.TabId)] GetWindowLongPtr returned zero"
        return $false
    }
    script:Write-WidgetDebugLog "Attach: style=0x$('{0:X}' -f $stylePtr.ToInt64()) [$($Tab.TabId)]"
    $style = $stylePtr.ToInt64()
    $style = ($style -bor [int64]$script:WS_CHILD) -band (-bnot [int64]$script:WS_POPUP)
    # Run Win32 reparenting on a background thread to avoid cross-process
    # SendMessage deadlock (SetWindowLongPtr sends WM_STYLECHANGING to the
    # terminal, which may SendMessage back to our UI thread).
    $tabId = $Tab.TabId
    $attachTab = $Tab
    $newStyle = [IntPtr]::new($style)
    $tHwnd = $terminalHwnd
    $pHwnd = $parentHwnd
    $u32 = $script:User32
    $gwlStyle = $script:GWL_STYLE
    $swShow = $script:SW_SHOW
    [System.Threading.ThreadPool]::QueueUserWorkItem([System.Threading.WaitCallback]{
        param($stateObj)
        try {
            script:Write-WidgetDebugLog "Attach[bg]: calling SetWindowLongPtr [$tabId]"
            [void]$u32::SetWindowLongPtr($tHwnd, $gwlStyle, $newStyle)
            script:Write-WidgetDebugLog "Attach[bg]: calling SetParent [$tabId]"
            [void]$u32::SetParent($tHwnd, $pHwnd)
            script:Write-WidgetDebugLog "Attach[bg]: calling ShowWindow [$tabId]"
            [void]$u32::ShowWindow($tHwnd, $swShow)
            script:Write-WidgetDebugLog "Attach[bg]: reparenting done, dispatching resize [$tabId]"
            # Resize must happen on the UI thread (accesses WPF controls)
            $script:Chat.Dispatcher.Invoke([Action]{
                script:Resize-ClippyTerminalSurface -Tab $attachTab
                script:Write-WidgetDebugLog "Attached embedded terminal [$tabId] terminal=0x$('{0:X}' -f $tHwnd.ToInt64()) parent=0x$('{0:X}' -f $pHwnd.ToInt64())"
            })
        } catch {
            script:Write-WidgetDebugLog "Attach[bg] ERROR: $($_.Exception.Message) [$tabId]"
        }
    }, $null) | Out-Null
    return $true
}

function script:Queue-ClippyTerminalWindowAttach {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    $tabId = [string]$Tab.TabId
    script:Invoke-OnUiThread -Action {
        if (-not (script:Test-ChatWindowAvailable)) {
            $reason = if (-not $script:Chat) { 'Chat is null' }
                      elseif ($script:ChatWasClosed) { 'ChatWasClosed is true' }
                      elseif (-not $script:Chat.Dispatcher) { 'Dispatcher is null' }
                      elseif ($script:Chat.Dispatcher.HasShutdownStarted) { 'Dispatcher shutting down' }
                      else { 'unknown' }
            script:Write-WidgetDebugLog "Queue-ClippyTerminalWindowAttach skipped: ChatWindow not available ($reason) [$tabId]"
            return
        }

        if ($Tab.TerminalAttachTimer) {
            try {
                $Tab.TerminalAttachTimer.Stop()
            } catch {
            }
            $Tab.TerminalAttachTimer = $null
        }

        $timer = [Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Normal, $script:Chat.Dispatcher)
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        # Store closure state at script scope keyed by tabId - EventHandler
        # scriptblocks cannot capture parent-scope locals in PowerShell and
        # DispatcherTimer has no Tag property (unlike WinForms Timer).
        if (-not $script:TerminalAttachState) { $script:TerminalAttachState = @{} }
        # Remove stale entry for this tab (from previous timer that was just stopped)
        $script:TerminalAttachState.Remove($tabId)
        $script:TerminalAttachState[$tabId] = @{ TabId = $tabId; Attempts = 0 }

        $handler = [System.EventHandler]{
            param($sender, $eventArgs)

            try {
                # Find our state - iterate since we cannot capture $tabId directly
                $st = $null
                foreach ($k in @($script:TerminalAttachState.Keys)) {
                    $candidate = $script:TerminalAttachState[$k]
                    if ($candidate -and $candidate.Timer -eq $sender) {
                        $st = $candidate
                        break
                    }
                }
                if (-not $st) {
                    script:Write-WidgetDebugLog "attach tick: no state found for timer, stopping"
                    $sender.Stop()
                    return
                }
                $tid = $st.TabId
                $st.Attempts++
                if ($st.Attempts -eq 1 -or ($st.Attempts % 10) -eq 0) {
                    script:Write-WidgetDebugLog "attach tick attempt=$($st.Attempts) [$tid]"
                }
                $attachTab = script:Get-ClippyTab -TabId $tid
                script:Write-WidgetDebugLog "attach tick: Get-ClippyTab returned $(if ($attachTab) { 'tab' } else { 'null' }) [$tid]"
                if (-not $attachTab -or -not $attachTab.UseEmbeddedTerminal -or -not (script:Test-ChatWindowAvailable)) {
                    $reason = if (-not $attachTab) { 'tab not found' }
                              elseif (-not $attachTab.UseEmbeddedTerminal) { 'UseEmbeddedTerminal=false' }
                              else { 'ChatWindow not available' }
                    script:Write-WidgetDebugLog "attach tick aborted: $reason [$tid]"
                    $sender.Stop()
                    $script:TerminalAttachState.Remove($tid)
                    return
                }

                script:Write-WidgetDebugLog "attach tick: calling Attach-ClippyTerminalWindow [$tid]"
                $attachResult = script:Attach-ClippyTerminalWindow -Tab $attachTab
                script:Write-WidgetDebugLog "attach tick: Attach returned $attachResult [$tid]"
                if ($attachResult) {
                    $sender.Stop()
                    $attachTab.TerminalAttachTimer = $null
                    $script:TerminalAttachState.Remove($tid)
                    return
                }

                if ($st.Attempts -ge 30) {
                    script:Write-WidgetDebugLog "Embedded terminal attach timed out after $($st.Attempts) attempts [$tid]"
                    $sender.Stop()
                    $attachTab.TerminalAttachTimer = $null
                    $script:TerminalAttachState.Remove($tid)
                }
            } catch {
                script:Write-WidgetDebugLog "attach tick ERROR: $($_.Exception.Message)"
                $sender.Stop()
            }
        }

        $timer.Add_Tick($handler)
        $script:TerminalAttachState[$tabId].Timer = $timer
        $Tab.TerminalAttachTimer = $timer
        $timer.Start()
        script:Write-WidgetDebugLog "Terminal attach timer started (priority=Normal, interval=100ms) [$tabId]"
    } -Async
}

function script:Queue-ClippyActiveTabDocumentRefresh {
    if (-not (script:Test-ChatWindowAvailable)) {
        return
    }

    script:Invoke-OnUiThread -Action {
        if (-not (script:Test-ChatWindowAvailable)) {
            return
        }

        if ($script:ActiveTabRenderTimer) {
            try {
                $script:ActiveTabRenderTimer.Stop()
            } catch {
            }
            $script:ActiveTabRenderTimer = $null
        }

        $timer = [Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::ApplicationIdle, $script:Chat.Dispatcher)
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $attempts = 0

        $handler = [System.EventHandler]{
            param($sender, $eventArgs)

            $attempts++
            if (-not (script:Test-ChatWindowAvailable) -or -not $script:Chat.IsVisible) {
                $sender.Stop()
                $script:ActiveTabRenderTimer = $null
                return
            }

            try {
                $script:Chat.UpdateLayout()
            } catch {
            }

            $refreshTab = script:Get-ActiveClippyTab
            if ($refreshTab) {
                script:Show-ClippyTabDocument -Tab $refreshTab
                if ($refreshTab.UseEmbeddedTerminal) {
                    script:Ensure-ClippyTabTerminalPanel -Tab $refreshTab
                    [void](script:Attach-ClippyTerminalWindow -Tab $refreshTab)
                    script:Queue-ClippyTerminalWindowAttach -Tab $refreshTab
                }
            }

            if ($attempts -ge 30) {
                $sender.Stop()
                $script:ActiveTabRenderTimer = $null
            }
        }

        $timer.Add_Tick($handler)
        $script:ActiveTabRenderTimer = $timer
        $timer.Start()
    } -Async
}

function script:Handle-SessionHostMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [Parameter(Mandatory)]
        $Metadata
    )

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab) {
        return
    }

    $tab.MetadataReceived = $true
    $tab.HostMetadata = $Metadata
    $tab.HostState = if ($Metadata.hostState) { [string]$Metadata.hostState } else { 'running' }
    $tab.HostPid = $Metadata.pid
    if ($Metadata.displayName) {
        $tab.DisplayName = [string]$Metadata.displayName
    }
    if ($Metadata.sessionId) {
        $tab.SessionId = [string]$Metadata.sessionId
    }
    script:Update-ActiveSessionContext
    script:Update-TerminalSessionSummary -Tab $tab
    script:Save-CopilotSessionState
    script:Refresh-ClippyTabStrip
    script:Update-WidgetStatus
}

function script:Handle-SessionHostTerminalCard {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [Parameter(Mandatory)]
        $Payload
    )

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab -or -not $Payload) {
        return
    }

    $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $tab
    $terminalSurface.AdaptiveCardSnapshot = $Payload
    if ($Payload.PSObject.Properties.Name -contains 'card') {
        $terminalSurface.AdaptiveCardJson = ($Payload.card | ConvertTo-Json -Depth 40)
    }
    if ($Payload.PSObject.Properties.Name -contains 'data') {
        $terminalSurface.AdaptiveCardDataJson = ($Payload.data | ConvertTo-Json -Depth 40)
    }
    script:Sync-ClippyTabLegacySurfaceFields -Tab $tab
    script:Update-TerminalSessionSummary -Tab $tab
}

function script:Append-SessionHostOutput {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [Parameter(Mandatory)]
        $Payload
    )

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab -or -not $Payload) {
        return
    }

    $text = if ($Payload.PSObject.Properties.Name -contains 'text') { [string]$Payload.text } else { '' }
    if ([string]::IsNullOrEmpty($text)) {
        return
    }

    $stream = if ($Payload.PSObject.Properties.Name -contains 'stream') { [string]$Payload.stream } else { 'stdout' }
    $color = if ($stream -eq 'stderr') { '#F44747' } else { '#4EC9B0' }

    if ($tab.StreamState) {
        $tab.StreamState.HadAssistantOutput = $true
        $tab.StreamState.StreamedAssistantText += $text
    }

    script:Append-TermStream -Text $text -Color $color -TabId $TabId
}

function script:Handle-SessionHostState {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [Parameter(Mandatory)]
        $Payload
    )

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab) {
        return
    }

    if ($Payload.currentHostState) {
        $tab.HostState = [string]$Payload.currentHostState
    } elseif ($Payload.hostState) {
        $tab.HostState = [string]$Payload.hostState
    }
    if ($Payload.PSObject.Properties.Name -contains 'pid') {
        $tab.HostPid = $Payload.pid
    }
    if ($Payload.displayName) {
        $tab.DisplayName = [string]$Payload.displayName
    }
    script:Update-TerminalSessionSummary -Tab $tab
    script:Refresh-ClippyTabStrip
    script:Update-WidgetStatus
}

function script:Handle-SessionHostErrorLine {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [Parameter(Mandatory)]
        [string]$Line,
        [switch]$PreserveHostState
    )

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($Line)) {
        script:Write-WidgetDebugLog "STDERR [$TabId] $Line"
        if (-not $PreserveHostState) {
            $tab.HostState = 'error'
            script:Update-TerminalSessionSummary -Tab $tab
            script:Refresh-ClippyTabStrip
            script:Update-WidgetStatus
        }
        script:Write-Term "ERROR: $Line" "#F44747" -TabId $TabId
    }
}

function script:Handle-SessionHostProtocolMessage {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [Parameter(Mandatory)]
        $Message
    )

    $messageType = if ($Message.type) { [string]$Message.type } else { '' }
    $payload = if ($Message.PSObject.Properties.Name -contains 'payload') { $Message.payload } else { $null }

    switch ($messageType) {
        'host.ready' {
            if ($payload) {
                script:Handle-SessionHostState -TabId $TabId -Payload $payload
            }
            return
        }
        'host.metadata' {
            script:Handle-SessionHostMetadata -TabId $TabId -Metadata $payload
            return
        }
        'host.state' {
            script:Handle-SessionHostState -TabId $TabId -Payload $payload
            return
        }
        'host.error' {
            $message = if ($payload.message) { [string]$payload.message } else { 'Unknown host error.' }
            script:Handle-SessionHostErrorLine -TabId $TabId -Line $message
            return
        }
        'copilot.event' {
            $tab = script:Get-ClippyTab -TabId $TabId
            if ($tab -and $payload -and $payload.event) {
                if (-not $tab.StreamState) {
                    [void](script:Reset-TabCopilotStreamState -Tab $tab)
                }
                script:Handle-CopilotEvent -Event $payload.event -State $tab.StreamState
            }
            return
        }
        'terminal.card' {
            script:Handle-SessionHostTerminalCard -TabId $TabId -Payload $payload
            return
        }
        'transcript.text' {
            # Plain-text (non-JSON) line forwarded from the CLI when structured
            # JSONL events are not available.  Render it exactly like a streaming
            # assistant message delta so the user sees output in real time.
            $tab = script:Get-ClippyTab -TabId $TabId
            if ($tab -and $payload -and -not [string]::IsNullOrEmpty([string]$payload.text)) {
                if (-not $tab.StreamState) {
                    [void](script:Reset-TabCopilotStreamState -Tab $tab)
                }
                $tab.StreamState.HadAssistantOutput = $true
                $tab.StreamState.StreamedAssistantText += [string]$payload.text
                script:Append-TermStream -Text ([string]$payload.text + "`n") -Color "#4EC9B0" -TabId $TabId
            }
            return
        }
        'session.output' {
            script:Append-SessionHostOutput -TabId $TabId -Payload $payload
            return
        }
        'session.ready' {
            script:Handle-SessionHostState -TabId $TabId -Payload @{ currentHostState = 'running' }
            return
        }
        'session.exit' {
            $keepAlive = $false
            if ($payload -and ($payload.PSObject.Properties.Name -contains 'keepAlive')) {
                $keepAlive = [bool]$payload.keepAlive
            }

            if ($keepAlive) {
                $hostPid = $null
                if ($payload -and ($payload.PSObject.Properties.Name -contains 'pid')) {
                    $hostPid = $payload.pid
                }
                script:Handle-SessionHostState -TabId $TabId -Payload @{
                    currentHostState = if ($payload.currentHostState) { [string]$payload.currentHostState } else { 'running' }
                    pid = $hostPid
                }
            } else {
                script:Handle-SessionHostState -TabId $TabId -Payload @{ currentHostState = 'stopped'; pid = $null }
            }

            $tab = script:Get-ClippyTab -TabId $TabId
            if ($tab -and $tab.StreamState -and $tab.StreamState.WaitingForResponse) {
                if ($payload -and ($payload.PSObject.Properties.Name -contains 'exitCode')) {
                    $tab.StreamState.ExitCode = $payload.exitCode
                }
                script:Complete-CopilotPromptStream -State $tab.StreamState
            }
            return
        }
        'session.error' {
            $message = if ($payload.message) { [string]$payload.message } else { 'Session host reported an error.' }
            $keepAlive = $false
            if ($payload -and ($payload.PSObject.Properties.Name -contains 'keepAlive')) {
                $keepAlive = [bool]$payload.keepAlive
            }

            if ($keepAlive) {
                $statePayload = @{
                    currentHostState = if ($payload.currentHostState) { [string]$payload.currentHostState } else { 'running' }
                }
                if ($payload -and ($payload.PSObject.Properties.Name -contains 'pid')) {
                    $statePayload.pid = $payload.pid
                }
                script:Handle-SessionHostState -TabId $TabId -Payload $statePayload
            }

            script:Handle-SessionHostErrorLine -TabId $TabId -Line $message -PreserveHostState:$keepAlive
            $tab = script:Get-ClippyTab -TabId $TabId
            if ($tab -and $tab.StreamState -and $tab.StreamState.WaitingForResponse) {
                script:Complete-CopilotPromptStream -State $tab.StreamState
            }
            return
        }
    }
}

function script:Handle-SessionHostLine {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [Parameter(Mandatory)]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    script:Write-WidgetDebugLog "STDOUT [$TabId] $Line"

    $tab = script:Get-ClippyTab -TabId $TabId

    try {
        $message = $Line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($Line)) {
            script:Write-Term $Line "#8F8FAF" -TabId $TabId
        }
        return
    }

    if ($tab -and (script:Test-ClippyEmbeddedTerminalTab -Tab $tab) -and ($message.PSObject.Properties.Name -contains 'type')) {
        switch ([string]$message.type) {
            'ready' {
                $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $tab
                $terminalSurface.Hwnd = script:ConvertTo-NativeIntPtr -Value $message.hwnd
                $terminalSurface.Ready = $true
                script:Sync-ClippyTabLegacySurfaceFields -Tab $tab
                $tab.HostPid = $message.pid
                $tab.HostState = 'running'
                script:Refresh-ClippyTabStrip
                script:Update-WidgetStatus
                return
            }
            'exit' {
                if (($message.PSObject.Properties.Name -contains 'error') -and -not [string]::IsNullOrWhiteSpace([string]$message.error)) {
                    $tab.HostState = 'error'
                    script:Refresh-ClippyTabStrip
                    script:Update-WidgetStatus
                    script:Write-Term "ERROR: $([string]$message.error)" "#F44747" -TabId $TabId
                } else {
                    script:Handle-SessionHostState -TabId $TabId -Payload @{ currentHostState = 'stopped'; pid = $null }
                }
                return
            }
        }
    }

    if ($message.PSObject.Properties.Name -contains 'type') {
        script:Handle-SessionHostProtocolMessage -TabId $TabId -Message $message
        return
    }

    script:Handle-SessionHostMetadata -TabId $TabId -Metadata $message
}

function script:Send-ClippyTabHostMessage {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Tab,
        [Parameter(Mandatory)]
        $Payload
    )

    if ($Tab.TerminalProcess) {
        if ($Tab.TerminalStdinWriter -and -not $Tab.TerminalProcess.HasExited) {
            $message = $Payload | ConvertTo-Json -Compress -Depth 8
            $Tab.TerminalStdinWriter.WriteLine($message)
            $Tab.TerminalStdinWriter.Flush()
            return
        }

        if ($Tab.UseEmbeddedTerminal) {
            throw 'The active Clippy terminal is not running.'
        }
    }

    if (-not $Tab.HostProcess -or $Tab.HostProcess.HasExited) {
        throw 'The active Clippy host is not running. Widget prompts only flow through the session host bridge.'
    }

    $message = $Payload | ConvertTo-Json -Compress -Depth 8
    $Tab.HostProcess.StandardInput.WriteLine($message)
    $Tab.HostProcess.StandardInput.Flush()
}

function script:New-TerminalBridgeCommandPayload {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [hashtable]$Payload = @{},
        [string]$LegacyAction = $null
    )

    $envelope = @{
        type = 'host.command'
        payload = @{ command = $Command }
    }

    if ($Payload) {
        foreach ($entry in $Payload.GetEnumerator()) {
            $envelope.payload[$entry.Key] = $entry.Value
            $envelope[$entry.Key] = $entry.Value
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LegacyAction)) {
        $envelope.action = $LegacyAction
    }

    return $envelope
}

function script:Restart-ClippyTabHostBridge {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Tab,
        [Parameter(Mandatory)]
        [hashtable]$ConfigOverrides
    )

    if (-not $Tab) {
        return
    }

    if ($Tab.UseEmbeddedTerminal -or ($Tab.TerminalProcess -and -not $Tab.TerminalProcess.HasExited)) {
        script:Restart-ClippyTerminalHost -Tab $Tab
        return
    }

    if ($Tab.HostProcess -and -not $Tab.HostProcess.HasExited) {
        script:Send-ClippyTabHostMessage -Tab $Tab -Payload @{
            type = 'host.command'
            payload = @{
                command = 'session.restart'
                displayName = [string]$Tab.DisplayName
                configOverrides = $ConfigOverrides
            }
            action = 'restart'
            displayName = [string]$Tab.DisplayName
            configOverrides = $ConfigOverrides
        }
        return
    }

    script:Restart-ClippyTabHost -Tab $Tab
}

function script:Start-ClippyTerminalHost {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return $false
    }

    $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $Tab
    if ($terminalSurface.Process -and -not $terminalSurface.Process.HasExited) {
        [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportEmbeddedTerminal)
        return $true
    }

    script:Invoke-OnUiThread -Action {
        [void](script:Ensure-ChatWindow)
    }
    script:Ensure-ClippyTabTerminalPanel -Tab $Tab
    script:Reset-ClippyTabTerminalSurfaceState -Tab $Tab

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('--hwnd-mode')
    $arguments.Add("--session-id=$([string]$Tab.SessionId)")
    $arguments.Add('--display-name')
    $arguments.Add([string]$Tab.DisplayName)
    $terminalWorkingDirectory = $script:RepoRoot

    if (script:Test-ClippyKernelTab -Tab $Tab) {
        $kernelLaunchSpec = script:Get-ClippyKernelLaunchSpec -Tab $Tab
        $terminalWorkingDirectory = [string]$kernelLaunchSpec.WorkingDirectory
        $arguments.Add('--working-directory')
        $arguments.Add($terminalWorkingDirectory)
        $arguments.Add('--command')
        $arguments.Add([string]$kernelLaunchSpec.CommandLine)
    } else {
        $arguments.Add('--working-directory')
        $arguments.Add($script:RepoRoot)
        $arguments.Add('--shell')
        $arguments.Add('powershell')
        $arguments.Add('--startup-script')
        $arguments.Add((script:New-CopilotTerminalStartupScript -Tab $Tab))

        if ($script:WidgetSettings.Tools.AllowAllTools) {
            $arguments.Add('--allow-all-tools')
        }
        if ($script:WidgetSettings.Tools.AllowAllPaths) {
            $arguments.Add('--allow-all-paths')
        }
        if ($script:WidgetSettings.Tools.AllowAllUrls) {
            $arguments.Add('--allow-all-urls')
        }
        if ($script:WidgetSettings.Tools.Experimental) {
            $arguments.Add('--experimental')
        }
        if ($script:WidgetSettings.Tools.Autopilot) {
            $arguments.Add('--autopilot')
        }
        if ($script:WidgetSettings.Tools.EnableAllGitHubMcpTools) {
            $arguments.Add('--enable-all-github-mcp-tools')
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:TerminalHostExe
    $startInfo.Arguments = script:ConvertTo-ProcessArgumentString -Arguments @($arguments)
    $startInfo.WorkingDirectory = $terminalWorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.EnableRaisingEvents = $true

    $Tab.ClosingRequested = $false
    [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportEmbeddedTerminal)
    $Tab.HostState = 'starting'
    $Tab.HostPid = $null
    $Tab.HostMetadata = $null
    $Tab.MetadataReceived = $false
    $terminalSurface.Process = $process
    script:Sync-ClippyTabLegacySurfaceFields -Tab $Tab
    $Tab.HostProcess = $process
    script:Refresh-ClippyTabStrip
    script:Update-WidgetStatus
    script:Save-CopilotSessionState

    try {
        $started = $process.Start()
        if (-not $started) {
            throw 'Terminal host could not be started.'
        }

        $readyMessage = script:Read-ClippyTerminalHostReadyMessage -Process $process
        if (-not $readyMessage) {
            throw 'Terminal host did not report ready state.'
        }
        if ([string]$readyMessage.type -ne 'ready') {
            $detail = if ($readyMessage.PSObject.Properties.Name -contains 'error') { [string]$readyMessage.error } else { 'Terminal host exited before becoming ready.' }
            throw $detail
        }

        $terminalHwnd = script:ConvertTo-NativeIntPtr -Value $readyMessage.hwnd
        if ($terminalHwnd -eq [IntPtr]::Zero) {
            throw 'Terminal host returned an invalid HWND.'
        }

        $terminalSurface.Hwnd = $terminalHwnd
        $terminalSurface.StdinWriter = $process.StandardInput
        $terminalSurface.Ready = $true
        script:Sync-ClippyTabLegacySurfaceFields -Tab $Tab
        $Tab.HostPid = if ($readyMessage.pid) { $readyMessage.pid } else { $process.Id }
        $Tab.HostMetadata = $readyMessage
        $Tab.MetadataReceived = $true
        $Tab.HostState = 'running'
        script:Ensure-ClippyTabTerminalPanel -Tab $Tab
        script:Queue-ClippyTerminalWindowAttach -Tab $Tab

        script:Write-WidgetDebugLog "Started embedded terminal [$($Tab.TabId)] pid=$($process.Id) session=$([string]$Tab.SessionId) hwnd=$([string]$readyMessage.hwnd)"
        script:Start-ClippyTabHostPump -Tab $Tab

        if ([string]$script:ActiveClippyTabId -eq [string]$Tab.TabId) {
            script:Invoke-OnUiThread -Action {
                script:Show-ClippyTabDocument -Tab $Tab
            }
        }

        script:Save-CopilotSessionState
        script:Refresh-ClippyTabStrip
        script:Update-WidgetStatus
        return $true
    } catch {
        try {
            if ($process -and -not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(1000)
            }
        } catch {
        }

        try {
            if ($process) {
                $process.Dispose()
            }
        } catch {
        }

        script:Reset-ClippyTabTerminalSurfaceState -Tab $Tab
        $Tab.HostProcess = $null
        $Tab.HostPid = $null
        $Tab.HostState = 'error'
        [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
        throw
    }
}

function script:Stop-ClippyTerminalHost {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    script:Stop-ClippyTabHostPump -Tab $Tab

    $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $Tab
    $process = if ($terminalSurface.Process) { $terminalSurface.Process } else { $Tab.HostProcess }
    if (-not $process) {
        script:Reset-ClippyTabTerminalSurfaceState -Tab $Tab -RemovePanel
        $Tab.HostProcess = $null
        $Tab.HostState = 'closed'
        [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
        return
    }

    $Tab.ClosingRequested = $true

    try {
        if (-not $process.HasExited) {
            if ($terminalSurface.StdinWriter) {
                $payload = @{
                    type = 'host.command'
                    payload = @{ command = 'host.shutdown' }
                    action = 'close'
                } | ConvertTo-Json -Compress -Depth 8
                $terminalSurface.StdinWriter.WriteLine($payload)
                $terminalSurface.StdinWriter.Flush()
                $terminalSurface.StdinWriter.Close()
            }
            if (-not $process.WaitForExit(3000)) {
                $process.Kill()
                [void]$process.WaitForExit(1000)
            }
        }
    } catch {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(1000)
            }
        } catch {
        }
    } finally {
        try {
            $process.Dispose()
        } catch {
        }
        script:Reset-ClippyTabTerminalSurfaceState -Tab $Tab -RemovePanel
        $Tab.HostProcess = $null
        $Tab.HostPump = $null
        $Tab.HostPid = $null
        $Tab.HostState = 'closed'
        [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
    }
}

function script:Restart-ClippyTerminalHost {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    script:Stop-ClippyTerminalHost -Tab $Tab
    $Tab.ClosingRequested = $false
    script:Start-ClippyTerminalHost -Tab $Tab
}

function script:Handle-ClippyTabHostStartupFailure {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Tab,
        [string]$Message
    )

    $detail = if ([string]::IsNullOrWhiteSpace($Message)) {
        'Session host could not be started.'
    } else {
        [string]$Message
    }

    script:Write-WidgetDebugLog "Host startup failed [$($Tab.TabId)] $detail"
    script:Stop-ClippyTabHostPump -Tab $Tab

    if (script:Test-ClippyEmbeddedTerminalTab -Tab $Tab) {
        script:Reset-ClippyTabTerminalSurfaceState -Tab $Tab -RemovePanel
    }

    $Tab.ClosingRequested = $false
    $Tab.HostProcess = $null
    $Tab.HostPid = $null
    $Tab.HostPump = $null
    $Tab.HostMetadata = $null
    $Tab.MetadataReceived = $false
    $Tab.HostState = 'error'
    [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)

    script:Update-TerminalSessionSummary -Tab $Tab
    script:Refresh-ClippyTabStrip
    script:Update-WidgetStatus
    script:Save-CopilotSessionState

    script:Write-Term ("ERROR: Unable to start the {0} session host for tab '{1}'." -f (script:Get-TabRuntimeDisplayName -Tab $Tab), (script:Get-TabTerminalTitle -Tab $Tab)) '#F44747' -Bold -TabId $Tab.TabId
    script:Write-Term "DETAIL: $detail" '#F44747' -TabId $Tab.TabId
    script:Write-Term '' -TabId $Tab.TabId
}

function script:Start-ClippyTabHostSafely {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return $false
    }

    try {
        script:Start-ClippyTabHost -Tab $Tab
        return $true
    } catch {
        script:Handle-ClippyTabHostStartupFailure -Tab $Tab -Message $_.Exception.Message
        return $false
    }
}

function script:Start-ClippyTabHost {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    [void](script:Ensure-ClippyTabSurfaceState -Tab $Tab)

    if ($Tab.HostProcess -and -not $Tab.HostProcess.HasExited) {
        return
    }

    if (-not (script:Test-ClippyTerminalSurfaceTab -Tab $Tab)) {
        throw ("Surface '{0}' is not implemented yet for bench tabs." -f (script:Get-TabSurfaceKind -Tab $Tab))
    }

    if (script:Test-ClippyKernelTab -Tab $Tab) {
        if (-not (script:Test-ClippyTerminalHostAvailable)) {
            throw "Embedded terminal host was not found at $($script:TerminalHostExe)."
        }

        [void](script:Start-ClippyTerminalHost -Tab $Tab)
        return
    }

    $hostScript = script:Get-SessionHostScriptPath
    $nodeCommand = Get-Command 'node' -ErrorAction SilentlyContinue
    $nodeBridgeError = $null
    $embeddedTerminalError = $null

    if (script:Test-ClippyTerminalHostAvailable) {
        try {
            if (script:Start-ClippyTerminalHost -Tab $Tab) {
                return
            }
        } catch {
            $embeddedTerminalError = $_.Exception.Message
            script:Write-WidgetDebugLog "Embedded terminal launch failed [$($Tab.TabId)] $embeddedTerminalError; falling back to node bridge."
            script:Reset-ClippyTabTerminalSurfaceState -Tab $Tab -RemovePanel
            $Tab.HostProcess = $null
            [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
        }
    } else {
        $embeddedTerminalError = "Embedded terminal host was not found at $($script:TerminalHostExe)."
    }

    if (-not $nodeCommand) {
        $nodeBridgeError = "The 'node' command was not found in PATH."
        script:Write-WidgetDebugLog "Node bridge unavailable [$($Tab.TabId)] $nodeBridgeError"
    } elseif (-not (Test-Path $hostScript -PathType Leaf)) {
        $nodeBridgeError = "Session host script was not found at $hostScript."
        script:Write-WidgetDebugLog "Node bridge unavailable [$($Tab.TabId)] $nodeBridgeError"
    } else {
        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.Add($hostScript)
        $arguments.Add('--json')
        $arguments.Add('--bridge-stdio')
        $arguments.Add('--runtime')
        $arguments.Add('terminal')
        $arguments.Add("--session-id=$([string]$Tab.SessionId)")
        $arguments.Add('--working-directory')
        $arguments.Add($script:RepoRoot)
        $arguments.Add('--display-name')
        $arguments.Add([string]$Tab.DisplayName)
        $arguments.Add('--shell')
        $arguments.Add('powershell')
        $arguments.Add('--command')
        $arguments.Add((script:New-CopilotTerminalStartupScript -Tab $Tab))

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $nodeCommand.Source
        $startInfo.Arguments = script:ConvertTo-ProcessArgumentString -Arguments @($arguments)
        $startInfo.WorkingDirectory = $script:RepoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $startInfo.EnvironmentVariables['CLIPPY_WIDGET_TAB_ID'] = [string]$Tab.TabId

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $process.EnableRaisingEvents = $true

        $Tab.ClosingRequested = $false
        [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNodeBridge)
        $Tab.HostState = 'starting'
        $Tab.HostPid = $null
        $Tab.HostMetadata = $null
        $Tab.MetadataReceived = $false
        $Tab.HostProcess = $process
        script:Refresh-ClippyTabStrip
        script:Update-WidgetStatus
        script:Save-CopilotSessionState

        try {
            $started = $process.Start()
        } catch {
            $Tab.HostProcess = $null
            $Tab.HostState = 'error'
            [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
            $nodeBridgeError = "Session host could not be started. $($_.Exception.Message)"
            script:Write-WidgetDebugLog "Node bridge launch failed [$($Tab.TabId)] $nodeBridgeError; falling back to embedded terminal."
        }

        if ($started) {
            script:Write-WidgetDebugLog "Started Node bridge host [$($Tab.TabId)] pid=$($process.Id) session=$([string]$Tab.SessionId) script=$hostScript"
            script:Start-EventedClippyTabHostRead -Tab $Tab
            script:Start-ClippyTabHostPump -Tab $Tab
            return
        }

        if (-not $nodeBridgeError) {
            $Tab.HostProcess = $null
            $Tab.HostState = 'error'
            [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
            $nodeBridgeError = 'Session host could not be started.'
            script:Write-WidgetDebugLog "Node bridge launch failed [$($Tab.TabId)] $nodeBridgeError; falling back to embedded terminal."
        }
    }

    if ($nodeBridgeError -and $embeddedTerminalError) {
        throw "Node bridge failed: $nodeBridgeError Embedded terminal failed: $embeddedTerminalError"
    }

    if ($nodeBridgeError) {
        throw $nodeBridgeError
    }

    if ($embeddedTerminalError) {
        throw $embeddedTerminalError
    }

    throw 'Session host could not be started.'
}
function script:Stop-ClippyTabHost {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    if (script:Test-ClippyEmbeddedTerminalTab -Tab $Tab) {
        script:Stop-ClippyTerminalHost -Tab $Tab
        return
    }

    script:Stop-ClippyTabHostPump -Tab $Tab

    $process = $Tab.HostProcess
    if (-not $process) {
        $Tab.HostState = 'closed'
        [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
        return
    }

    $Tab.ClosingRequested = $true

    try {
        if (-not $process.HasExited) {
            $payload = @{
                type = 'host.command'
                payload = @{ command = 'host.shutdown' }
                action = 'shutdown'
            } | ConvertTo-Json -Compress -Depth 8
            $process.StandardInput.WriteLine($payload)
            $process.StandardInput.Flush()
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(3000)) {
                $process.Kill()
                [void]$process.WaitForExit(1000)
            }
        }
    } catch {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(1000)
            }
        } catch {
        }
    } finally {
        try {
            $process.Dispose()
        } catch {
        }
        if ($Tab.StreamState -and $Tab.StreamState.WaitingForResponse) {
            $Tab.StreamState.WaitingForResponse = $false
            $Tab.StreamState.Completed = $true
        }
        $Tab.ActiveAssistantStream = $null
        $Tab.ActiveThoughtStream = $null
        $Tab.HostProcess = $null
        $Tab.HostPump = $null
        $Tab.HostPid = $null
        $Tab.HostState = 'closed'
        [void](script:Set-TabHostTransportKind -Tab $Tab -HostTransportKind $script:ClippyHostTransportNone)
        script:Set-CopilotBusyState $false
    }
}

function script:Restart-ClippyTabHost {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    script:Stop-ClippyTabHost -Tab $Tab
    $Tab.ClosingRequested = $false
    [void](script:Start-ClippyTabHostSafely -Tab $Tab)
}

function script:Start-EventedClippyTabHostRead {
    param([hashtable]$Tab)

    if (-not $Tab -or -not $Tab.HostProcess) {
        return
    }

    # OutputDataReceived/ErrorDataReceived callbacks execute on CLR worker
    # threads, which can crash Windows PowerShell 5.1 when they invoke
    # scriptblocks. Use the existing polled reader on the dispatcher thread.
    $Tab.HostUsesEventedRead = $false
}

function script:Stop-ClippyTabHostPump {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    $pump = $Tab.HostPump
    if ($pump) {
        try {
            $pump.Stop()
        } catch {
        }
        $Tab.HostPump = $null
    }

    if ($Tab.HostUsesEventedRead) {
        $process = $Tab.HostProcess
        if ($process) {
            try {
                $process.CancelOutputRead()
            } catch {
            }
            try {
                $process.CancelErrorRead()
            } catch {
            }
        }
        $Tab.HostUsesEventedRead = $false
    }

    $Tab.HostStdoutTask = $null
    $Tab.HostStderrTask = $null
}

function script:Get-HostReadTaskPropertyName {
    param([string]$StreamName)

    switch ($StreamName) {
        'StandardOutput' { return 'HostStdoutTask' }
        'StandardError' { return 'HostStderrTask' }
        default { throw "Unsupported host stream '$StreamName'." }
    }
}

function script:Test-HostReadTasksPending {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return $false
    }

    if ($Tab.HostUsesEventedRead) {
        return $false
    }

    foreach ($propertyName in @('HostStdoutTask', 'HostStderrTask')) {
        $task = $Tab[$propertyName]
        if ($task -and -not $task.IsCompleted) {
            return $true
        }
    }

    return $false
}

function script:Drain-HostReadTask {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return $false
    }

    if ($Tab.HostUsesEventedRead) {
        return $false
    }

    $process = $Tab.HostProcess
    if (-not $process) {
        return $false
    }

    $tabId = [string]$Tab.TabId
    $processedLineCount = 0
    $maxLinesPerTick = 100

    foreach ($streamName in @('StandardOutput', 'StandardError')) {
        $isError = ($streamName -eq 'StandardError')
        $taskProperty = script:Get-HostReadTaskPropertyName -StreamName $streamName

        while ($processedLineCount -lt $maxLinesPerTick) {
            $task = $Tab[$taskProperty]
            if (-not $task) {
                try {
                    $task = $process.$streamName.ReadLineAsync()
                    $Tab[$taskProperty] = $task
                } catch {
                    script:Write-WidgetDebugLog "ReadLineAsync failed [$tabId][$streamName] $($_.Exception.Message)"
                    $Tab[$taskProperty] = $null
                    break
                }
            }

            if (-not $task.IsCompleted) {
                break
            }

            $Tab[$taskProperty] = $null

            try {
                $line = $task.GetAwaiter().GetResult()
            } catch {
                script:Write-WidgetDebugLog "Read task completion failed [$tabId][$streamName] $($_.Exception.Message)"
                break
            }

            if ($null -eq $line) {
                break
            }

            $processedLineCount += 1
            if ($isError) {
                script:Handle-SessionHostErrorLine -TabId $tabId -Line ([string]$line)
            } else {
                script:Handle-SessionHostLine -TabId $tabId -Line ([string]$line)
            }
        }
    }

    return ($processedLineCount -gt 0)
}

function script:Handle-ClippyTabHostExit {
    param([hashtable]$Tab)

    if (-not $Tab) {
        return
    }

    $process = $Tab.HostProcess
    script:Drain-HostReadTask -Tab $Tab

    script:Stop-ClippyTabHostPump -Tab $Tab
    $exitCode = $null
    if ($process -and -not $process.Disposed) {
        try { $exitCode = $process.ExitCode } catch { }
    }
    script:Write-WidgetDebugLog "Host exit [$($Tab.TabId)] closing=$([bool]$Tab.ClosingRequested) exitCode=$exitCode pid=$($Tab.HostPid)"

    $closingRequested = [bool]$Tab.ClosingRequested
    $Tab.HostState = if ($closingRequested) { 'closed' } else { 'stopped' }
    $Tab.HostPid = $null
    if ($Tab.StreamState -and $Tab.StreamState.WaitingForResponse) {
        script:Complete-CopilotPromptStream -State $Tab.StreamState
    }

    if ($process) {
        try {
            $process.Dispose()
        } catch {
        }
    }

    if ($Tab.UseEmbeddedTerminal) {
        script:Reset-ClippyTabTerminalSurfaceState -Tab $Tab
    }

    $Tab.HostProcess = $null
    $Tab.HostPump = $null
    script:Update-TerminalSessionSummary -Tab $Tab
    script:Save-CopilotSessionState
    script:Refresh-ClippyTabStrip
    script:Update-WidgetStatus
}

function script:Poll-ClippyTabHost {
    param([string]$TabId)

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab) {
        return $false
    }

    $process = $tab.HostProcess
    if (-not $process) {
        script:Stop-ClippyTabHostPump -Tab $tab
        return $false
    }

    $hadData = script:Drain-HostReadTask -Tab $tab

    try {
        if ($process.HasExited) {
            if ($tab.HostUsesEventedRead) {
                try {
                    [void]$process.WaitForExit(250)
                } catch {
                }
            }
            if (-not (script:Test-HostReadTasksPending -Tab $tab)) {
                script:Handle-ClippyTabHostExit -Tab $tab
            }
            return $true
        }
    } catch {
        script:Handle-ClippyTabHostExit -Tab $tab
        return $true
    }

    return $hadData
}

function script:Start-ClippyTabHostPump {
    param([hashtable]$Tab)

    if (-not $Tab -or -not $Tab.HostProcess) {
        return
    }

    $existingPump = $Tab.HostPump
    if ($existingPump) {
        try {
            $existingPump.Stop()
        } catch {
        }
        $Tab.HostPump = $null
    }

    if (-not $Tab.HostUsesEventedRead) {
        $Tab.HostStdoutTask = $null
        $Tab.HostStderrTask = $null
    }

    $tabId = [string]$Tab.TabId
    $timer = [Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background, $script:Chat.Dispatcher)
    $baseIntervalMs = if ($Tab.HostUsesEventedRead) { 250 } else { 75 }
    $timer.Interval = [TimeSpan]::FromMilliseconds($baseIntervalMs)
    # Store the tab ID on the timer itself. PowerShell 5.1 event handler
    # scriptblocks do NOT close over local variables -- $tabId would be empty
    # by the time the timer fires. Reading $sender.Tag is the only reliable
    # way to recover identity inside a .NET event handler in PS 5.1.
    $timer.Tag = $tabId
    $Tab.HostPumpIdleCount = 0
    $Tab.HostPumpBaseInterval = $baseIntervalMs
    $timer.Add_Tick({
        param($sender, $eventArgs)
        try {
            $id = [string]$sender.Tag
            $pumpTab = script:Get-ClippyTab -TabId $id
            $hadData = script:Poll-ClippyTabHost -TabId $id
            # Adaptive backoff: slow down when idle, snap back on activity.
            if ($pumpTab) {
                if ($hadData) {
                    $pumpTab.HostPumpIdleCount = 0
                    $sender.Interval = [TimeSpan]::FromMilliseconds($pumpTab.HostPumpBaseInterval)
                } else {
                    $pumpTab.HostPumpIdleCount++
                    if ($pumpTab.HostPumpIdleCount -gt 10) {
                        $newInterval = [Math]::Min($pumpTab.HostPumpBaseInterval + ($pumpTab.HostPumpIdleCount * 5), 250)
                        $sender.Interval = [TimeSpan]::FromMilliseconds($newInterval)
                    }
                }
            }
        } catch {
            script:Write-WidgetDebugLog "Timer tick error [$($sender.Tag)]: $($_.Exception.Message)"
        }
    })
    $Tab.HostPump = $timer
    $timer.Start()
    script:Write-WidgetDebugLog "Started host pump [$tabId] intervalMs=$baseIntervalMs adaptive=true"
}

function script:New-TabBrush {
    param([string]$Color)

    return ([Windows.Media.BrushConverter]::new()).ConvertFromString($Color)
}

function script:New-TerminalSummaryTextBlock {
    param(
        [string]$Text,
        [string]$Color = '#FFE8E8E8',
        [double]$FontSize = 12,
        [string]$FontFamily = 'Cascadia Code, Cascadia Mono, Consolas',
        [switch]$Bold
    )

    $textBlock = [Windows.Controls.TextBlock]::new()
    $textBlock.Text = [string]$Text
    $textBlock.Foreground = script:New-TabBrush -Color $Color
    $textBlock.FontSize = $FontSize
    $textBlock.FontFamily = [Windows.Media.FontFamily]::new($FontFamily)
    $textBlock.TextWrapping = 'Wrap'
    if ($Bold) {
        $textBlock.FontWeight = [Windows.FontWeights]::SemiBold
    }

    return $textBlock
}

function script:New-TileTextBlock {
    param(
        [string]$Text,
        [string]$Color = '#FFCCCCCC',
        [double]$FontSize = 12,
        [switch]$Bold
    )
    $tb = [Windows.Controls.TextBlock]::new()
    $tb.Text = $Text
    $tb.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $tb.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI')
    $tb.FontSize = $FontSize
    $tb.TextWrapping = 'Wrap'
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    $tb.Margin = [Windows.Thickness]::new(0, 1, 0, 1)
    return $tb
}

function script:New-TileBorder {
    param([Windows.UIElement]$Child, [int]$Column = 0)
    $border = [Windows.Controls.Border]::new()
    $border.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF0D1117')
    $border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF1F2937')
    $border.BorderThickness = [Windows.Thickness]::new(1)
    $border.CornerRadius = [Windows.CornerRadius]::new(8)
    $border.Padding = [Windows.Thickness]::new(10, 8, 10, 8)
    $border.Margin = [Windows.Thickness]::new(4)
    if ($Child) { $border.Child = $Child }
    [Windows.Controls.Grid]::SetColumn($border, $Column)
    return $border
}

function script:New-SessionStatusTile {
    $activeTab = script:Get-ActiveClippyTab
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Vertical'

    [void]$panel.Children.Add((script:New-TileTextBlock -Text 'Session' -Color '#FF93C5FD' -FontSize 13 -Bold))

    $agentDisplay = script:Get-TabAgentDisplayName -Tab $activeTab
    [void]$panel.Children.Add((script:New-TileTextBlock -Text "Agent: $agentDisplay" -FontSize 11))

    $modelDisplay = script:Get-TabModelDisplayName -Tab $activeTab
    [void]$panel.Children.Add((script:New-TileTextBlock -Text "Model: $modelDisplay" -FontSize 11))

    $modeLabel = if ($activeTab -and -not [string]::IsNullOrWhiteSpace([string]$activeTab.Mode)) {
        [string]$activeTab.Mode
    } else { 'Agent' }
    [void]$panel.Children.Add((script:New-TileTextBlock -Text "Mode: $modeLabel" -FontSize 11))

    $shortId = script:Get-ShortSessionId
    [void]$panel.Children.Add((script:New-TileTextBlock -Text "Session: #$shortId" -Color '#FF6B7280' -FontSize 10))

    $hostState = script:Get-TabHostStateInfo -Tab $activeTab
    $dotPanel = [Windows.Controls.StackPanel]::new()
    $dotPanel.Orientation = 'Horizontal'
    $dotPanel.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
    $dot = [Windows.Shapes.Ellipse]::new()
    $dot.Width = 7
    $dot.Height = 7
    $dot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($hostState.DotColor)
    $dot.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
    $dot.VerticalAlignment = 'Center'
    [void]$dotPanel.Children.Add($dot)
    [void]$dotPanel.Children.Add((script:New-TileTextBlock -Text $hostState.Label -Color $hostState.TextColor -FontSize 11))
    [void]$panel.Children.Add($dotPanel)

    return (script:New-TileBorder -Child $panel -Column 0)
}

function script:New-McpInventoryTile {
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Vertical'

    [void]$panel.Children.Add((script:New-TileTextBlock -Text 'MCP Servers' -Color '#FF93C5FD' -FontSize 13 -Bold))

    if ($script:ToolSourceSnapshot -and $script:ToolSourceSnapshot.Count -gt 0) {
        foreach ($key in $script:ToolSourceSnapshot.Keys) {
            $source = $script:ToolSourceSnapshot[$key]
            if (-not $source -or $source.Servers.Count -eq 0) { continue }

            [void]$panel.Children.Add((script:New-TileTextBlock -Text ('{0}: {1}' -f $source.SummaryName, $source.Servers.Count) -FontSize 11))

            $maxServers = [Math]::Min($source.Servers.Count, 4)
            for ($i = 0; $i -lt $maxServers; $i++) {
                $serverName = [string]$source.Servers[$i].Name
                [void]$panel.Children.Add((script:New-TileTextBlock -Text "  $serverName" -Color '#FF6B7280' -FontSize 10))
            }
        }
    } else {
        [void]$panel.Children.Add((script:New-TileTextBlock -Text 'No MCP sources detected' -Color '#FF6B7280' -FontSize 11))
    }

    return (script:New-TileBorder -Child $panel -Column 1)
}

function script:New-RecentActivityTile {
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Vertical'

    [void]$panel.Children.Add((script:New-TileTextBlock -Text 'Recent Activity' -Color '#FF93C5FD' -FontSize 13 -Bold))

    $recentTools = @()
    $activeTab = script:Get-ActiveClippyTab
    if ($activeTab) {
        $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $activeTab
        if ($terminalSurface -and $terminalSurface.AdaptiveCardSnapshot -and
            ($terminalSurface.AdaptiveCardSnapshot.PSObject.Properties.Name -contains 'data')) {
            $snapshotData = $terminalSurface.AdaptiveCardSnapshot.data
            if ($snapshotData -and ($snapshotData.PSObject.Properties.Name -contains 'recentTools')) {
                $recentTools = @($snapshotData.recentTools)
            }
        }
    }

    if ($recentTools.Count -gt 0) {
        $maxTools = [Math]::Min($recentTools.Count, 3)
        for ($i = 0; $i -lt $maxTools; $i++) {
            $tool = $recentTools[$i]
            $toolName = [string](script:Get-ObjectPropertyValue -InputObject $tool -PropertyName 'name')
            $toolStatus = [string](script:Get-ObjectPropertyValue -InputObject $tool -PropertyName 'statusLabel')
            if ([string]::IsNullOrWhiteSpace($toolStatus)) { $toolStatus = 'done' }

            $statusColor = switch -Wildcard ($toolStatus.ToLowerInvariant()) {
                'success*' { '#FF34D399' }
                'done*'    { '#FF34D399' }
                'running*' { '#FFFBBF24' }
                'error*'   { '#FFF44747' }
                'fail*'    { '#FFF44747' }
                default    { '#FFCCCCCC' }
            }

            $toolPanel = [Windows.Controls.StackPanel]::new()
            $toolPanel.Orientation = 'Horizontal'
            $toolPanel.Margin = [Windows.Thickness]::new(0, 1, 0, 1)
            [void]$toolPanel.Children.Add((script:New-TileTextBlock -Text $toolName -FontSize 11))
            [void]$toolPanel.Children.Add((script:New-TileTextBlock -Text " ($toolStatus)" -Color $statusColor -FontSize 11))
            [void]$panel.Children.Add($toolPanel)
        }
    } else {
        [void]$panel.Children.Add((script:New-TileTextBlock -Text 'No recent activity' -Color '#FF6B7280' -FontSize 11))
    }

    return (script:New-TileBorder -Child $panel -Column 2)
}

function script:Refresh-BenchTiles {
    if (-not $script:cTilePanelGrid -or -not $script:cTilePanel -or $script:cTilePanel.Visibility -ne 'Visible') { return }
    script:Invoke-OnUiThread -Async -Action {
        if (-not $script:cTilePanelGrid) { return }
        $script:cTilePanelGrid.Children.Clear()
        $script:cTilePanelGrid.Children.Add((script:New-SessionStatusTile)) | Out-Null
        $script:cTilePanelGrid.Children.Add((script:New-McpInventoryTile)) | Out-Null
        $script:cTilePanelGrid.Children.Add((script:New-RecentActivityTile)) | Out-Null
    }
}

function script:Update-TerminalSessionSummary {
    param([hashtable]$Tab)

    if (-not $Tab -or (script:Test-ClippyEmbeddedTerminalTab -Tab $Tab)) {
        return
    }

    $targetTabId = [string]$Tab.TabId
    script:Invoke-OnUiThread -Async -Action {
        $tab = script:Get-ClippyTab -TabId $targetTabId
        if (-not $tab -or (script:Test-ClippyEmbeddedTerminalTab -Tab $tab)) {
            return
        }

        $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $tab

        if (-not $tab.Document) {
            $tab.Document = script:New-TranscriptDocument
        }

        if ($terminalSurface.SummaryBlock) {
            try {
                $tab.Document.Blocks.Remove($terminalSurface.SummaryBlock)
            } catch {
            }
            $terminalSurface.SummaryBlock = $null
            script:Sync-ClippyTabLegacySurfaceFields -Tab $tab
        }

        $stateInfo = script:Get-TabHostStateInfo -Tab $tab
        $modeBadge = script:Get-TabModeBadgeInfo -Tab $tab
        $snapshotData = if ($terminalSurface.AdaptiveCardSnapshot -and ($terminalSurface.AdaptiveCardSnapshot.PSObject.Properties.Name -contains 'data')) {
            $terminalSurface.AdaptiveCardSnapshot.data
        } else {
            $null
        }
        $sessionData = script:Get-ObjectPropertyValue -InputObject $snapshotData -PropertyName 'session'
        $statusData = script:Get-ObjectPropertyValue -InputObject $snapshotData -PropertyName 'status'
        $transcriptData = script:Get-ObjectPropertyValue -InputObject $snapshotData -PropertyName 'transcript'
        $recentTools = if ($snapshotData -and ($snapshotData.PSObject.Properties.Name -contains 'recentTools')) { @($snapshotData.recentTools) } else { @() }

        $shortSessionId = script:Get-TabShortSessionId -Tab $tab
        if ($sessionData) {
            $candidateShortSessionId = script:Get-ObjectPropertyValue -InputObject $sessionData -PropertyName 'shortSessionId'
            if (-not [string]::IsNullOrWhiteSpace([string]$candidateShortSessionId)) {
                $shortSessionId = [string]$candidateShortSessionId
            }
        }

        $workingDirectory = if ($sessionData) {
            [string](script:Get-ObjectPropertyValue -InputObject $sessionData -PropertyName 'workingDirectory')
        } else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
            $workingDirectory = $script:RepoRoot
        }

        $agentDisplay = script:Get-TabAgentDisplayName -Tab $tab
        if ($statusData) {
            $agentId = [string](script:Get-ObjectPropertyValue -InputObject $statusData -PropertyName 'agent')
            $agentDefinition = script:Get-AgentDefinition -AgentId $agentId
            if ($agentDefinition) {
                $agentDisplay = [string]$agentDefinition.DisplayName
            } elseif (-not [string]::IsNullOrWhiteSpace($agentId)) {
                $agentDisplay = $agentId
            }
        }

        $modelDisplay = script:Get-TabModelDisplayName -Tab $tab
        if ($statusData) {
            $modelId = [string](script:Get-ObjectPropertyValue -InputObject $statusData -PropertyName 'model')
            $modelDefinition = script:Get-ModelDefinition -ModelId $modelId
            if ($modelDefinition) {
                $modelDisplay = [string]$modelDefinition.DisplayName
            } elseif (-not [string]::IsNullOrWhiteSpace($modelId)) {
                $modelDisplay = $modelId
            }
        }

        $modeLabel = if ($statusData) {
            [string](script:Get-ObjectPropertyValue -InputObject $statusData -PropertyName 'mode')
        } else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($modeLabel)) {
            $modeLabel = if ([string]::IsNullOrWhiteSpace([string]$tab.Mode)) { 'Agent' } else { [string]$tab.Mode }
        }

        $toolSummary = if ($statusData) {
            [string](script:Get-ObjectPropertyValue -InputObject $statusData -PropertyName 'toolFlagSummary')
        } else {
            ''
        }

        $latestPrompt = ''
        $latestOutput = ''
        $lastError = ''
        $waitingForResponse = $false
        if ($transcriptData) {
            $latestPrompt = script:Format-TerminalPreviewText -Text ([string](script:Get-ObjectPropertyValue -InputObject $transcriptData -PropertyName 'latestUserPrompt')) -MaxLength 120
            $latestOutput = script:Format-TerminalPreviewText -Text ([string](script:Get-ObjectPropertyValue -InputObject $transcriptData -PropertyName 'latestAssistantText')) -MaxLength 160
            if ([string]::IsNullOrWhiteSpace($latestOutput)) {
                $latestOutput = script:Format-TerminalPreviewText -Text ([string](script:Get-ObjectPropertyValue -InputObject $transcriptData -PropertyName 'latestPlainText')) -MaxLength 160
            }
            $lastError = script:Format-TerminalPreviewText -Text ([string](script:Get-ObjectPropertyValue -InputObject $transcriptData -PropertyName 'lastError')) -MaxLength 120
            $waitingForResponse = [bool](script:Get-ObjectPropertyValue -InputObject $transcriptData -PropertyName 'waitingForResponse')
        } elseif ($tab.StreamState) {
            $waitingForResponse = [bool]$tab.StreamState.WaitingForResponse
        }

        $recentToolSummary = ''
        if ($recentTools.Count -gt 0) {
            $latestTool = $recentTools[0]
            $toolName = [string](script:Get-ObjectPropertyValue -InputObject $latestTool -PropertyName 'name')
            $toolStatusLabel = [string](script:Get-ObjectPropertyValue -InputObject $latestTool -PropertyName 'statusLabel')
            if (-not [string]::IsNullOrWhiteSpace($toolName)) {
                $recentToolSummary = "Latest tool: $toolName"
                if (-not [string]::IsNullOrWhiteSpace($toolStatusLabel)) {
                    $recentToolSummary += " ($toolStatusLabel)"
                }
            }
        }

        $summaryBorder = [Windows.Controls.Border]::new()
        $summaryBorder.Background = script:New-TabBrush -Color '#FF0D1117'
        $summaryBorder.BorderBrush = script:New-TabBrush -Color '#FF1F2937'
        $summaryBorder.BorderThickness = [Windows.Thickness]::new(1)
        $summaryBorder.CornerRadius = [Windows.CornerRadius]::new(10)
        $summaryBorder.Padding = [Windows.Thickness]::new(12, 10, 12, 10)

        $layout = [Windows.Controls.StackPanel]::new()
        $layout.Orientation = 'Vertical'

        $headerGrid = [Windows.Controls.Grid]::new()
        $headerGrid.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
        [void]$headerGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
        $statusColumn = [Windows.Controls.ColumnDefinition]::new()
        $statusColumn.Width = [Windows.GridLength]::Auto
        [void]$headerGrid.ColumnDefinitions.Add($statusColumn)

        $titleRow = [Windows.Controls.StackPanel]::new()
        $titleRow.Orientation = 'Horizontal'
        $titleRow.VerticalAlignment = 'Center'

        $dot = [Windows.Shapes.Ellipse]::new()
        $dot.Width = 8
        $dot.Height = 8
        $dot.Fill = script:New-TabBrush -Color $stateInfo.DotColor
        $dot.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
        [void]$titleRow.Children.Add($dot)

        $title = script:New-TerminalSummaryTextBlock -Text (script:Get-TabTerminalTitle -Tab $tab) -Color '#FFF8FAFC' -FontSize 13 -FontFamily 'Segoe UI' -Bold
        $title.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
        [void]$titleRow.Children.Add($title)

        $badgeBorder = [Windows.Controls.Border]::new()
        $badgeBorder.Background = script:New-TabBrush -Color $modeBadge.Background
        $badgeBorder.CornerRadius = [Windows.CornerRadius]::new(4)
        $badgeBorder.Padding = [Windows.Thickness]::new(5, 1, 5, 1)
        $badgeBorder.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
        $badgeText = script:New-TerminalSummaryTextBlock -Text $modeBadge.Label -Color $modeBadge.Foreground -FontSize 10 -FontFamily 'Segoe UI'
        $badgeBorder.Child = $badgeText
        [void]$titleRow.Children.Add($badgeBorder)

        $sessionText = script:New-TerminalSummaryTextBlock -Text ('#{0}' -f $shortSessionId) -Color '#FF6B7280' -FontSize 11 -FontFamily 'Segoe UI'
        [void]$titleRow.Children.Add($sessionText)

        [void]$headerGrid.Children.Add($titleRow)

        $statusText = script:New-TerminalSummaryTextBlock -Text $stateInfo.Label -Color $stateInfo.TextColor -FontSize 11 -FontFamily 'Segoe UI' -Bold
        [Windows.Controls.Grid]::SetColumn($statusText, 1)
        [void]$headerGrid.Children.Add($statusText)

        [void]$layout.Children.Add($headerGrid)

        [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text ('{0}  -  {1}' -f $agentDisplay, $modelDisplay) -Color '#FFE5E7EB' -FontSize 12))
        [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text $workingDirectory -Color '#FF9CA3AF' -FontSize 11))

        $details = 'Mode: {0}  -  Tools: {1}' -f $modeLabel, $(if ([string]::IsNullOrWhiteSpace($toolSummary)) { 'default' } else { $toolSummary })
        [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text $details -Color '#FF6B7280' -FontSize 10.5 -FontFamily 'Segoe UI'))

        if (-not [string]::IsNullOrWhiteSpace($lastError)) {
            [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text ("Error: {0}" -f $lastError) -Color '#FFFCA5A5' -FontSize 11))
        } elseif ($waitingForResponse) {
            [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text 'Waiting for response from the active Clippy host...' -Color '#FFFBBF24' -FontSize 11))
        } elseif (-not [string]::IsNullOrWhiteSpace($recentToolSummary)) {
            [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text $recentToolSummary -Color '#FF93C5FD' -FontSize 11))
        }

        if (-not [string]::IsNullOrWhiteSpace($latestPrompt)) {
            [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text ("Last prompt: {0}" -f $latestPrompt) -Color '#FFB7B7D6' -FontSize 10.5))
        } elseif (-not [string]::IsNullOrWhiteSpace($latestOutput)) {
            [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text ("Preview: {0}" -f $latestOutput) -Color '#FFB7B7D6' -FontSize 10.5))
        } else {
            $readyText = if (script:Test-ClippyKernelTab -Tab $tab) {
                'Ready for input. Use the widget prompt or type directly into the embedded terminal.'
            } else {
                'Ready for input. Prompt tabs stream Clippy output here; prefix ! for local PowerShell.'
            }
            [void]$layout.Children.Add((script:New-TerminalSummaryTextBlock -Text $readyText -Color '#FFB7B7D6' -FontSize 10.5))
        }

        $summaryBorder.Child = $layout

        $uiContainer = [Windows.Documents.BlockUIContainer]::new($summaryBorder)
        $uiContainer.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
        if ($tab.Document.Blocks.FirstBlock) {
            $tab.Document.Blocks.InsertBefore($tab.Document.Blocks.FirstBlock, $uiContainer)
        } else {
            $tab.Document.Blocks.Add($uiContainer)
        }

        $terminalSurface.SummaryBlock = $uiContainer
        script:Sync-ClippyTabLegacySurfaceFields -Tab $tab

        script:Refresh-BenchTiles
    }
}

function script:New-ClippyTabChip {
    param([hashtable]$Tab)

    $isActive = ([string]$Tab.TabId -eq [string]$script:ActiveClippyTabId)
    $stateInfo = script:Get-TabHostStateInfo -Tab $Tab
    $modeBadge = script:Get-TabModeBadgeInfo -Tab $Tab
    $background = if ($isActive) { '#FF0A0E14' } else { '#FF0D1117' }
    $foreground = if ($isActive) { '#FFF8F8FF' } else { '#FFE5E7EB' }
    $borderBrush = if ($isActive) { '#FF253340' } else { '#FF1F2937' }

    $border = [Windows.Controls.Border]::new()
    $border.Background = script:New-TabBrush -Color $background
    $border.BorderBrush = script:New-TabBrush -Color $borderBrush
    $border.BorderThickness = [Windows.Thickness]::new(0, 0, 1, 0)
    $border.Margin = [Windows.Thickness]::new(0)
    $border.Padding = [Windows.Thickness]::new(0)

    $grid = [Windows.Controls.Grid]::new()
    [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $closeColumn = [Windows.Controls.ColumnDefinition]::new()
    $closeColumn.Width = [Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($closeColumn)

    $button = [Windows.Controls.Button]::new()
    $button.Tag = [string]$Tab.TabId
    $contentRow = [Windows.Controls.StackPanel]::new()
    $contentRow.Orientation = 'Horizontal'
    $contentRow.VerticalAlignment = 'Center'

    $statusDot = [Windows.Shapes.Ellipse]::new()
    $statusDot.Width = 8
    $statusDot.Height = 8
    $statusDot.Fill = script:New-TabBrush -Color $stateInfo.DotColor
    $statusDot.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    [void]$contentRow.Children.Add($statusDot)

    $modeBadgeBorder = [Windows.Controls.Border]::new()
    $modeBadgeBorder.Background = script:New-TabBrush -Color $modeBadge.Background
    $modeBadgeBorder.CornerRadius = [Windows.CornerRadius]::new(4)
    $modeBadgeBorder.Padding = [Windows.Thickness]::new(5, 1, 5, 1)
    $modeBadgeBorder.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    $modeBadgeText = script:New-TerminalSummaryTextBlock -Text $modeBadge.Label -Color $modeBadge.Foreground -FontSize 10 -FontFamily 'Segoe UI'
    $modeBadgeBorder.Child = $modeBadgeText
    [void]$contentRow.Children.Add($modeBadgeBorder)

    $labelText = script:New-TerminalSummaryTextBlock -Text (script:Get-TabTerminalTitle -Tab $Tab) -Color $foreground -FontSize 12 -FontFamily 'Segoe UI' -Bold
    $labelText.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    [void]$contentRow.Children.Add($labelText)

    $sessionText = script:New-TerminalSummaryTextBlock -Text ('#{0}' -f (script:Get-TabShortSessionId -Tab $Tab)) -Color '#FF6B7280' -FontSize 10.5 -FontFamily 'Segoe UI'
    [void]$contentRow.Children.Add($sessionText)

    $button.Content = $contentRow
    $button.Background = [Windows.Media.Brushes]::Transparent
    $button.BorderBrush = [Windows.Media.Brushes]::Transparent
    $button.BorderThickness = [Windows.Thickness]::new(0)
    $button.Foreground = script:New-TabBrush -Color $foreground
    $button.Padding = [Windows.Thickness]::new(12, 8, 8, 8)
    $button.Cursor = 'Hand'
    $button.ToolTip = "Bench tab $(script:Get-TabShortSessionId -Tab $Tab)  Runtime: $(script:Get-TabRuntimeDisplayName -Tab $Tab)  Host: $($stateInfo.Label)  Agent: $(script:Get-TabAgentDisplayName -Tab $Tab)"
    $button.Add_Click({
        param($sender, $eventArgs)
        script:Set-ActiveClippyTab -TabId ([string]$sender.Tag)
    })
    [void]$grid.Children.Add($button)

    $closeButton = [Windows.Controls.Button]::new()
    $closeButton.Tag = [string]$Tab.TabId
    $closeButton.Content = 'x'
    $closeButton.Background = [Windows.Media.Brushes]::Transparent
    $closeButton.BorderBrush = [Windows.Media.Brushes]::Transparent
    $closeButton.BorderThickness = [Windows.Thickness]::new(0)
    $closeButton.Foreground = script:New-TabBrush -Color '#FF6B7280'
    $closeButton.Padding = [Windows.Thickness]::new(6, 8, 10, 8)
    $closeButton.Cursor = 'Hand'
    $closeButton.ToolTip = 'Close this bench tab'
    [Windows.Controls.Grid]::SetColumn($closeButton, 1)
    $closeButton.Add_Click({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        script:Close-ClippyTab -TabId ([string]$sender.Tag)
    })
    [void]$grid.Children.Add($closeButton)

    $border.Child = $grid
    return $border
}

function script:Refresh-ClippyTabStrip {
    if (-not $script:ClippyTabStrip) {
        return
    }

    # Coalesce rapid successive calls into a single UI rebuild.
    if ($script:TabStripRefreshScheduled) {
        return
    }
    $script:TabStripRefreshScheduled = $true

    script:Invoke-OnUiThread -Action {
        $script:TabStripRefreshScheduled = $false
        $script:ClippyTabStrip.Children.Clear()
        foreach ($tabId in @($script:ClippyTabOrder)) {
            $tab = script:Get-ClippyTab -TabId $tabId
            if (-not $tab) { continue }
            [void]$script:ClippyTabStrip.Children.Add((script:New-ClippyTabChip -Tab $tab))
        }
    } -Async
}

function script:Set-ActiveClippyTab {
    param(
        [Parameter(Mandatory)]
        [string]$TabId,
        [switch]$SkipSave
    )

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab) {
        return
    }

    $script:ActiveClippyTabId = $TabId
    script:Update-ActiveSessionContext
    script:Invoke-OnUiThread -Action {
        script:Show-ClippyTabDocument -Tab $tab
    }
    script:Refresh-ClippyTabStrip
    script:Sync-CopilotBusyState
    if (-not $SkipSave) {
        script:Save-CopilotSessionState
    }
    script:Sync-WidgetUi
}

function script:New-ClippyTab {
    param(
        [string]$SessionId,
        [string]$Runtime,
        [string]$SurfaceKind,
        [switch]$Activate,
        [switch]$LaunchHost
    )

    $resolvedSurfaceKind = script:Normalize-ClippySurfaceKind -SurfaceKind $SurfaceKind -Runtime $Runtime
    $tab = script:New-ClippyTabState -SessionId $SessionId -Mode $script:WidgetSettings.Mode -Model $script:WidgetSettings.Model -Agent $script:WidgetSettings.Agent -Runtime $Runtime -SurfaceKind $resolvedSurfaceKind
    $script:ClippyTabs[$tab.TabId] = $tab
    $script:ClippyTabOrder.Add([string]$tab.TabId)

    if ($LaunchHost) {
        [void](script:Start-ClippyTabHostSafely -Tab $tab)
    }

    if ($Activate -or [string]::IsNullOrWhiteSpace($script:ActiveClippyTabId)) {
        script:Set-ActiveClippyTab -TabId ([string]$tab.TabId) -SkipSave
    }

    script:Refresh-ClippyTabStrip
    script:Save-CopilotSessionState
    return $tab
}

function script:Close-ClippyTab {
    param([string]$TabId)

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab) {
        return
    }

    if ($tab.StreamState -and $tab.StreamState.WaitingForResponse) {
        script:Write-Term 'Wait for this Clippy tab to finish before closing it.' '#CCA700' -TabId $TabId
        script:Write-Term '' -TabId $TabId
        return
    }

    if ($script:ClippyTabOrder.Count -le 1) {
        $replacement = script:New-ClippyTab -Runtime (script:Get-TabRuntime -Tab $tab) -SurfaceKind (script:Get-TabSurfaceKind -Tab $tab) -Activate -LaunchHost
        if (-not (script:Test-ClippyKernelTab -Tab $replacement) -and [string]$replacement.HostState -ne 'error') {
            script:Render-TranscriptWelcome
        }
        if ($replacement.TabId -eq $TabId) {
            return
        }
    }

    $currentIndex = [array]::IndexOf(@($script:ClippyTabOrder), $TabId)
    if ($currentIndex -lt 0) {
        $currentIndex = 0
    }

    $script:ClippyTabOrder.Remove($TabId)
    [void]$script:ClippyTabs.Remove($TabId)
    script:Stop-ClippyTabHost -Tab $tab

    if ($script:ActiveClippyTabId -eq $TabId) {
        $nextIndex = [Math]::Min($currentIndex, $script:ClippyTabOrder.Count - 1)
        if ($nextIndex -ge 0 -and $script:ClippyTabOrder.Count -gt 0) {
            script:Set-ActiveClippyTab -TabId ([string]$script:ClippyTabOrder[$nextIndex]) -SkipSave
        } else {
            $script:ActiveClippyTabId = $null
            script:Update-ActiveSessionContext
        }
    }

    script:Refresh-ClippyTabStrip
    script:Save-CopilotSessionState
    script:Update-WidgetStatus
}

function script:Initialize-ClippyTabs {
    param([string]$RequestedSessionId)

    if ($script:ClippyTabOrder.Count -gt 0) {
        return
    }

    $restoredState = script:Load-CopilotSessionState
    $restoredTabs = [System.Collections.Generic.List[hashtable]]::new()

    if ($restoredState) {
        foreach ($savedTab in @($restoredState.Tabs)) {
            $tab = script:New-ClippyTabState -SessionId $savedTab.SessionId -Mode $savedTab.Mode -Model $savedTab.Model -Agent $savedTab.Agent -Runtime $savedTab.Runtime -SurfaceKind $(if ($savedTab.PSObject.Properties.Name -contains 'SurfaceKind') { [string]$savedTab.SurfaceKind } else { $null })
            if (-not [string]::IsNullOrWhiteSpace($savedTab.DisplayName)) {
                $tab.DisplayName = [string]$savedTab.DisplayName
            }
            if (-not [string]::IsNullOrWhiteSpace($savedTab.CreatedAt)) {
                $tab.CreatedAt = [string]$savedTab.CreatedAt
            }
            $script:ClippyTabs[$tab.TabId] = $tab
            $script:ClippyTabOrder.Add([string]$tab.TabId)
            [void](script:Start-ClippyTabHostSafely -Tab $tab)
            if (-not (script:Test-ClippyKernelTab -Tab $tab) -and [string]$tab.HostState -ne 'error') {
                script:Render-TranscriptWelcome -TabId $tab.TabId
            }
            $restoredTabs.Add($tab)
        }
    }

    if ($restoredTabs.Count -eq 0) {
        $initialTab = script:New-ClippyTab -SessionId (script:Resolve-RequestedSessionId -RequestedSessionId $RequestedSessionId) -Runtime $script:ClippyRuntimeKernel -SurfaceKind $script:ClippySurfaceTerminal -Activate -LaunchHost
        script:Show-ClippyTabDocument -Tab $initialTab
        return
    }

    $activeTab = $null
    if (-not [string]::IsNullOrWhiteSpace($RequestedSessionId)) {
        $activeTab = $restoredTabs | Where-Object { [string]$_.SessionId -eq [string]$RequestedSessionId } | Select-Object -First 1
        if (-not $activeTab) {
            $requestedTab = script:New-ClippyTab -SessionId $RequestedSessionId -Runtime $script:ClippyRuntimeKernel -SurfaceKind $script:ClippySurfaceTerminal -Activate -LaunchHost
            if (-not (script:Test-ClippyKernelTab -Tab $requestedTab) -and [string]$requestedTab.HostState -ne 'error') {
                script:Render-TranscriptWelcome -TabId $requestedTab.TabId
            }
            $activeTab = $requestedTab
        }
    }
    if (-not $activeTab -and $restoredState.ActiveTabId) {
        $activeTab = $restoredTabs | Where-Object { [string]$_.TabId -eq [string]$restoredState.ActiveTabId } | Select-Object -First 1
    }
    if (-not $activeTab) {
        $activeTab = $restoredTabs[0]
    }

    script:Set-ActiveClippyTab -TabId ([string]$activeTab.TabId) -SkipSave
}

function script:New-TerminalParagraphState {
    param(
        [string]$Color = "#CCCCCC",
        [switch]$Bold
    )

    $para = [Windows.Documents.Paragraph]::new()
    $para.Margin = [Windows.Thickness]::new(0, 1, 0, 1)
    $run = [Windows.Documents.Run]::new('')
    $run.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $run.FontWeight = [Windows.FontWeights]::SemiBold }
    $para.Inlines.Add($run)

    return [pscustomobject]@{
        Paragraph = $para
        Run = $run
        Color = $Color
        Bold = [bool]$Bold
    }
}

function script:Write-Term {
    param(
        [string]$Text,
        [string]$Color = "#CCCCCC",
        [switch]$Bold,
        [string]$TabId = $script:ActiveClippyTabId
    )

    $targetTabId = $TabId
    script:Invoke-OnUiThread -Action {
        $tab = script:Get-ClippyTab -TabId $targetTabId
        if (-not $tab) { return }
        if (-not $tab.Document) {
            $tab.Document = script:New-TranscriptDocument
        }
        if ([string]$script:ActiveClippyTabId -eq [string]$targetTabId) {
            script:Show-ClippyTabDocument -Tab $tab
        }
        $tab.ActiveAssistantStream = $null
        $tab.ActiveThoughtStream = $null
        $state = script:New-TerminalParagraphState -Color $Color -Bold:$Bold
        $state.Run.Text = $Text
        $tab.Document.Blocks.Add($state.Paragraph)
        if ([string]$script:ActiveClippyTabId -eq [string]$targetTabId) {
            $cOutput.ScrollToEnd()
        }
    } -Async
}

function script:Append-TranscriptParagraphStream {
    param(
        [string]$Text,
        [string]$Color = "#4EC9B0",
        [switch]$Bold,
        [string]$StreamProperty = 'ActiveAssistantStream',
        [string]$TabId = $script:ActiveClippyTabId
    )

    if ($null -eq $Text) { return }

    script:Write-WidgetDebugLog "AppendStream prop=$StreamProperty tabId=$TabId textLen=$($Text.Length) activeTab=$($script:ActiveClippyTabId)"

    $targetTabId = $TabId
    script:Invoke-OnUiThread -Action {
        $tab = script:Get-ClippyTab -TabId $targetTabId
        if (-not $tab) { return }
        if (-not $tab.Document) {
            $tab.Document = script:New-TranscriptDocument
        }
        if ([string]$script:ActiveClippyTabId -eq [string]$targetTabId) {
            script:Show-ClippyTabDocument -Tab $tab
        }
        if (-not $tab[$StreamProperty]) {
            $tab[$StreamProperty] = script:New-TerminalParagraphState -Color $Color -Bold:$Bold
            $tab.Document.Blocks.Add($tab[$StreamProperty].Paragraph)
        }

        foreach ($character in $Text.ToCharArray()) {
            switch ($character) {
                "`r" { continue }
                "`n" {
                    $tab[$StreamProperty] = script:New-TerminalParagraphState -Color $Color -Bold:$Bold
                    $tab.Document.Blocks.Add($tab[$StreamProperty].Paragraph)
                    continue
                }
                default {
                    $tab[$StreamProperty].Run.Text += [string]$character
                }
            }
        }

        if ([string]$script:ActiveClippyTabId -eq [string]$targetTabId) {
            $cOutput.ScrollToEnd()
        }
    } -Async
}

function script:Append-TermStream {
    param(
        [string]$Text,
        [string]$Color = "#4EC9B0",
        [switch]$Bold,
        [string]$TabId = $script:ActiveClippyTabId
    )

    script:Append-TranscriptParagraphStream -Text $Text -Color $Color -Bold:$Bold -StreamProperty 'ActiveAssistantStream' -TabId $TabId
}

function script:Append-ThoughtStream {
    param(
        [string]$Text,
        [string]$Color = "#8F8FAF",
        [switch]$Bold,
        [string]$TabId = $script:ActiveClippyTabId
    )

    script:Append-TranscriptParagraphStream -Text $Text -Color $Color -Bold:$Bold -StreamProperty 'ActiveThoughtStream' -TabId $TabId
}

function script:Flush-TerminalUi {
    script:Invoke-OnUiThread -Action {
        $cOutput.UpdateLayout()
    }
}

function script:Clear-Transcript {
    param([string]$TabId = $script:ActiveClippyTabId)

    $tab = script:Get-ClippyTab -TabId $TabId
    if (-not $tab) { return }
    if ($tab.UseEmbeddedTerminal) { return }

    $tab.ActiveAssistantStream = $null
    $tab.ActiveThoughtStream = $null
    if ($tab.StreamState) {
        $tab.StreamState.StreamedAssistantText = ''
        $tab.StreamState.StreamedThoughtText = ''
    }
    if ($tab.Document) {
        $tab.Document.Blocks.Clear()
    }
    $terminalSurface = script:Get-TabTerminalSurfaceState -Tab $tab
    if ($terminalSurface) {
        $terminalSurface.SummaryBlock = $null
        script:Sync-ClippyTabLegacySurfaceFields -Tab $tab
    }
    if ($script:ActiveClippyTabId -eq $TabId -and $cOutput) {
        script:Show-ClippyTabDocument -Tab $tab
    }
}

function script:Render-TranscriptWelcome {
    param([string]$TabId = $script:ActiveClippyTabId)

    $tab = script:Get-ClippyTab -TabId $TabId
    if ($tab -and $tab.UseEmbeddedTerminal) { return }

    script:Clear-Transcript -TabId $TabId
    if ($tab) {
        script:Update-TerminalSessionSummary -Tab $tab
    }
    if (-not $cOutput) { return }
    if ($NoWelcome) { return }

    script:Write-Term "  Windows Clippy Bench" "#5B5FC7" -Bold -TabId $TabId
    script:Write-Term "  --------------------------------" "#333355" -TabId $TabId
    script:Write-Term "  Tabs stay live like terminal sessions while the active host streams into this pane." "#6B6B8D" -TabId $TabId
    script:Write-Term "  Kernel tabs run directly in the embedded terminal. Prompt tabs route widget input through the prompt bridge." "#6B6B8D" -TabId $TabId
    script:Write-Term "  Use !<command> for local PowerShell from the widget prompt when a prompt tab is active." "#6B6B8D" -TabId $TabId
    script:Write-Term "  The bench card above tracks host state, runtime, agent, model, and the latest prompt/tool activity." "#6B6B8D" -TabId $TabId
    script:Write-Term "  Current bench tab: $(script:Get-ShortSessionId)" "#6B6B8D" -TabId $TabId
    script:Write-Term "  Type 'help' for chat commands." "#6B6B8D" -TabId $TabId
    script:Write-Term "" -TabId $TabId
}

function script:Get-CopilotCommand {
    foreach ($commandName in @('clippy', 'copilot')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            return $command
        }
    }

    return $null
}

function script:Test-UriProtocolAvailable {
    param([string]$ProtocolName)

    if ([string]::IsNullOrWhiteSpace($ProtocolName)) {
        return $false
    }

    return Test-Path ("Registry::HKEY_CLASSES_ROOT\{0}" -f $ProtocolName.TrimEnd(':'))
}

function script:Get-SnippingToolCommand {
    return Get-Command 'SnippingTool.exe' -ErrorAction SilentlyContinue
}

function script:Update-SnippingButtonVisual {
    if (-not $cSnip) { return }

    if ($script:SnippingTileOpen) {
        $cSnip.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FF5B5FC7")
        return
    }

    $cSnip.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FF707070")
}

function script:Update-SnippingTileState {
    $hasOverlay = script:Test-UriProtocolAvailable 'ms-screenclip'
    $hasSketch = script:Test-UriProtocolAvailable 'ms-screensketch'
    $hasClickToDo = script:Test-UriProtocolAvailable 'ms-clicktodo'
    $hasTool = $null -ne (script:Get-SnippingToolCommand)

    $cSnipOverlay.IsEnabled = $hasOverlay
    $cSnipSketch.IsEnabled = $hasSketch
    $cSnipTool.IsEnabled = $hasTool
    $cSnipClickToDo.IsEnabled = $hasClickToDo
    $cSnipSettings.IsEnabled = $hasClickToDo

    if ($hasClickToDo) {
        $cSnippingTileStatus.Text = 'Native ready'
        $cSnippingTileNote.Text = 'Snip opens the native overlay with Windows capture modes. Click to Do launches the built-in Windows provider on supported hardware.'
        return
    }

    $cSnippingTileStatus.Text = 'Snip ready'
    $cSnippingTileNote.Text = 'Snip actions use the native Windows overlay and Snipping Tool app. Click to Do is only enabled on supported Windows builds and hardware.'
}

function script:Update-SnippingTilePlacement {
    if (-not $cSnippingTilePopup -or -not $cTitle) { return }

    $cardWidth = if ($cSnippingTileCard.ActualWidth -gt 0) {
        $cSnippingTileCard.ActualWidth
    } elseif ($cSnippingTileCard.Width -gt 0) {
        $cSnippingTileCard.Width
    } else {
        356
    }

    $titleWidth = if ($cTitle.ActualWidth -gt 0) { $cTitle.ActualWidth } else { $script:Chat.Width }
    $offset = [Math]::Max(12, $titleWidth - $cardWidth - 12)

    $cSnippingTilePopup.PlacementTarget = $cTitle
    $cSnippingTilePopup.Placement = 'Top'
    $cSnippingTilePopup.HorizontalOffset = $offset
    $cSnippingTilePopup.VerticalOffset = -14
}

function script:Set-SnippingTileOpen {
    param([bool]$IsOpen)

    if (-not $cSnippingTilePopup) { return }

    if ($IsOpen) {
        script:Update-SnippingTileState
        script:Update-SnippingTilePlacement
    }

    $cSnippingTilePopup.IsOpen = $IsOpen
    $script:SnippingTileOpen = $IsOpen
    script:Update-SnippingButtonVisual
}

function script:Toggle-SnippingTile {
    script:Set-SnippingTileOpen (-not $script:SnippingTileOpen)
}

function script:Invoke-SnippingTileAction {
    param(
        [ValidateSet('Snip', 'Sketch', 'Tool', 'ClickToDo', 'Settings')]
        [string]$Action
    )

    try {
        $detail = $null
        switch ($Action) {
            'Snip' {
                if (-not (script:Test-UriProtocolAvailable 'ms-screenclip')) {
                    throw 'The native screen clip overlay is not registered on this device.'
                }
                Start-Process 'ms-screenclip:' | Out-Null
                $message = 'Opened the native Snipping Tool overlay.'
                $detail = 'Use the Windows capture toolbar to choose rectangle, freeform, window, or fullscreen snips.'
            }
            'Sketch' {
                if (-not (script:Test-UriProtocolAvailable 'ms-screensketch')) {
                    throw 'The Snipping Tool sketch editor is not registered on this device.'
                }
                Start-Process 'ms-screensketch:' | Out-Null
                $message = 'Opened Snipping Tool in sketch mode.'
            }
            'Tool' {
                $toolCommand = script:Get-SnippingToolCommand
                if (-not $toolCommand) {
                    throw 'SnippingTool.exe is not available in PATH.'
                }
                Start-Process $toolCommand.Source | Out-Null
                $message = 'Opened the Snipping Tool app.'
            }
            'ClickToDo' {
                if (-not (script:Test-UriProtocolAvailable 'ms-clicktodo')) {
                    throw 'Click to Do is not available on this device.'
                }
                Start-Process 'ms-clicktodo:' | Out-Null
                $message = 'Opened Click to Do.'
                $detail = 'Windows also exposes Click to Do through Windows+Q and supported Snipping Tool builds.'
            }
            'Settings' {
                Start-Process 'ms-settings:privacy-clicktodo' | Out-Null
                $message = 'Opened Click to Do settings.'
            }
        }

        script:Write-Term $message "#4EC9B0"
        if ($detail) {
            script:Write-Term $detail "#6B6B8D"
        }
        script:Write-Term ""
    } catch {
        script:Write-Term "Snipping action failed: $($_.Exception.Message)" "#F48771"
        script:Write-Term ""
    } finally {
        script:Set-SnippingTileOpen $false
    }
}

function script:Get-DefaultWidgetSettings {
    return @{
        Mode = 'Agent'
        Model = 'gpt-5.4'
        Agent = script:Get-DefaultAgentId
        Tools = @{
            AllowAllTools = $true
            AllowAllPaths = $true
            AllowAllUrls = $true
            Experimental = $false
            Autopilot = $false
            EnableAllGitHubMcpTools = $true
        }
        Extensions = @{
            IncludeRegularSettings = $true
            IncludeInsidersSettings = $true
            IncludeRegularExtensions = $true
            IncludeInsidersExtensions = $true
        }
    }
}

function script:Load-WidgetSettings {
    $settings = script:Get-DefaultWidgetSettings
    if (-not (Test-Path $script:WidgetConfigPath)) {
        return $settings
    }

    try {
        $saved = Get-Content -Path $script:WidgetConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $settings
    }

    if ($saved.PSObject.Properties.Name -contains 'Mode' -and $saved.Mode -in $script:AvailableModes) {
        $settings.Mode = [string]$saved.Mode
    }
    if ($saved.PSObject.Properties.Name -contains 'Model' -and $saved.Model -in $script:AvailableModels) {
        $settings.Model = [string]$saved.Model
    }
    if ($saved.PSObject.Properties.Name -contains 'Agent') {
        $resolvedAgent = script:Resolve-AgentToken -Token ([string]$saved.Agent)
        if ($resolvedAgent) {
            $settings.Agent = $resolvedAgent
        }
    }

    if ($saved.PSObject.Properties.Name -contains 'Tools' -and $saved.Tools) {
        foreach ($name in @($settings.Tools.Keys)) {
            if ($saved.Tools.PSObject.Properties.Name -contains $name) {
                $settings.Tools[$name] = [bool]$saved.Tools.$name
            }
        }
    }

    if ($saved.PSObject.Properties.Name -contains 'Extensions' -and $saved.Extensions) {
        foreach ($name in @($settings.Extensions.Keys)) {
            if ($saved.Extensions.PSObject.Properties.Name -contains $name) {
                $settings.Extensions[$name] = [bool]$saved.Extensions.$name
            }
        }
    }

    return $settings
}

function script:Ensure-WidgetConfigDirectory {
    if (-not (Test-Path $script:WidgetConfigDir)) {
        New-Item -ItemType Directory -Path $script:WidgetConfigDir -Force | Out-Null
    }
}

function script:Write-WidgetDebugLog {
    param([string]$Message)

    try {
        script:Ensure-WidgetConfigDirectory
        $timestamp = [DateTime]::UtcNow.ToString('o')
        Add-Content -Path $script:WidgetDebugLogPath -Value "[$timestamp] $Message"
    } catch {
    }
}

function script:Save-WidgetSettings {
    if (-not $script:WidgetSettings) { return }

    script:Ensure-WidgetConfigDirectory

    $payload = @{
        Mode = $script:WidgetSettings.Mode
        Model = $script:WidgetSettings.Model
        Agent = $script:WidgetSettings.Agent
        Tools = $script:WidgetSettings.Tools
        Extensions = $script:WidgetSettings.Extensions
    }

    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $script:WidgetConfigPath -Encoding UTF8
}

function script:Get-EnabledSettingCount {
    param($SettingsTable)

    if (-not $SettingsTable) {
        return 0
    }

    $enabledCount = 0
    foreach ($key in $SettingsTable.Keys) {
        if ($SettingsTable[$key]) {
            $enabledCount += 1
        }
    }

    return $enabledCount
}

function script:Get-WidgetPackageVersion {
    $packagePath = Join-Path $script:RepoRoot 'package.json'
    if (-not (Test-Path $packagePath -PathType Leaf)) {
        return $null
    }

    try {
        $packageMetadata = Get-Content -Path $packagePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        script:Write-WidgetDebugLog "Unable to read package.json for widget version: $($_.Exception.Message)"
        return $null
    }

    if ($packageMetadata -and $packageMetadata.PSObject.Properties.Name -contains 'version' -and -not [string]::IsNullOrWhiteSpace([string]$packageMetadata.version)) {
        return [string]$packageMetadata.version
    }

    return $null
}

function script:Set-DialogOwner {
    param($Window)

    if (-not $Window) {
        return
    }

    $Window.WindowStartupLocation = 'CenterScreen'
    if ($script:Chat -and $script:Chat.IsLoaded) {
        $Window.Owner = $script:Chat
        $Window.WindowStartupLocation = 'CenterOwner'
    }
}

function script:Resolve-RequestedSessionId {
    param([string]$RequestedSessionId)

    if (-not [string]::IsNullOrWhiteSpace($RequestedSessionId)) {
        try {
            [guid]::Parse($RequestedSessionId) | Out-Null
            return $RequestedSessionId
        } catch {
        }
    }

    return [guid]::NewGuid().Guid
}

function script:Load-CopilotSessionState {
    if (-not (Test-Path $script:CopilotSessionPath -PathType Leaf)) {
        return $null
    }

    try {
        $saved = Get-Content -Path $script:CopilotSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }

    if (-not $saved -or -not $saved.Tabs) {
        return $null
    }

    $tabs = [System.Collections.Generic.List[object]]::new()
    foreach ($savedTab in @($saved.Tabs)) {
        if (-not $savedTab) {
            continue
        }

        $sessionId = [string]$savedTab.SessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            continue
        }

        $tabs.Add([pscustomobject]@{
            SessionId = $sessionId
            DisplayName = if ($savedTab.PSObject.Properties.Name -contains 'DisplayName') { [string]$savedTab.DisplayName } else { $null }
            Mode = if ($savedTab.PSObject.Properties.Name -contains 'Mode') { [string]$savedTab.Mode } else { $null }
            Model = if ($savedTab.PSObject.Properties.Name -contains 'Model') { [string]$savedTab.Model } else { $null }
            Agent = if ($savedTab.PSObject.Properties.Name -contains 'Agent') { [string]$savedTab.Agent } else { $null }
            Runtime = if ($savedTab.PSObject.Properties.Name -contains 'Runtime') { [string]$savedTab.Runtime } else { $script:ClippyRuntimeKernel }
            SurfaceKind = if ($savedTab.PSObject.Properties.Name -contains 'SurfaceKind') { [string]$savedTab.SurfaceKind } else { $script:ClippySurfaceTerminal }
            CreatedAt = if ($savedTab.PSObject.Properties.Name -contains 'CreatedAt') { [string]$savedTab.CreatedAt } else { $null }
        })
    }

    if ($tabs.Count -eq 0) {
        return $null
    }

    return [pscustomobject]@{
        ActiveTabId = if ($saved.PSObject.Properties.Name -contains 'ActiveTabId') { [string]$saved.ActiveTabId } else { $null }
        SessionId = if ($saved.PSObject.Properties.Name -contains 'SessionId') { [string]$saved.SessionId } else { $null }
        Tabs = @($tabs)
    }
}

function script:Save-CopilotSessionState {
    # Debounce: coalesce rapid saves into a single disk write after 400ms.
    if ($script:SessionSaveTimer) {
        try { $script:SessionSaveTimer.Stop() } catch {}
        $script:SessionSaveTimer = $null
    }

    if (-not $script:Chat -or -not $script:Chat.Dispatcher) {
        script:Save-CopilotSessionStateImmediate
        return
    }

    $timer = [Windows.Threading.DispatcherTimer]::new(
        [Windows.Threading.DispatcherPriority]::Background,
        $script:Chat.Dispatcher)
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({
        param($sender, $eventArgs)
        $sender.Stop()
        $script:SessionSaveTimer = $null
        script:Save-CopilotSessionStateImmediate
    })
    $script:SessionSaveTimer = $timer
    $timer.Start()
}

function script:Save-CopilotSessionStateImmediate {
    script:Ensure-WidgetConfigDirectory
    script:Update-ActiveSessionContext

    $activeSessionId = script:Get-ActiveSessionId
    $tabs = foreach ($tabId in @($script:ClippyTabOrder)) {
        $tab = script:Get-ClippyTab -TabId $tabId
        if (-not $tab) { continue }
        @{
            TabId = $tab.TabId
            SessionId = $tab.SessionId
            DisplayName = $tab.DisplayName
            Mode = $tab.Mode
            Model = $tab.Model
            Agent = $tab.Agent
            Runtime = $tab.Runtime
            HostState = $tab.HostState
            HostPid = $tab.HostPid
            CreatedAt = $tab.CreatedAt
        }
    }

    if (-not $activeSessionId) {
        $fallbackTab = @($tabs | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.SessionId) } | Select-Object -First 1)
        if ($fallbackTab) {
            $activeSessionId = [string]$fallbackTab.SessionId
            if (-not $script:ActiveClippyTabId) {
                $script:ActiveClippyTabId = [string]$fallbackTab.TabId
            }
            if (-not $script:CopilotSessionId) {
                $script:CopilotSessionId = $activeSessionId
            }
        }
    }

    if (-not $activeSessionId) { return }

    try {
        @{
            SessionId = $activeSessionId
            ActiveTabId = $script:ActiveClippyTabId
            Tabs = @($tabs)
            Source = 'widget'
            UpdatedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $script:CopilotSessionPath -Encoding UTF8
    } catch {
        script:Write-WidgetDebugLog "Failed to save copilot session state: $($_.Exception.Message)"
    }
}

function script:Get-ShortSessionId {
    $activeSessionId = script:Get-ActiveSessionId
    if (-not $activeSessionId) { return 'pending' }
    if ($activeSessionId.Length -le 8) { return $activeSessionId }
    return $activeSessionId.Substring(0, 8)
}

function script:New-ClippySession {
    $tab = script:New-ClippyKernelSession
    script:Update-WidgetStatus
    return $tab
}

function script:New-ClippyKernelSession {
    $tab = script:New-ClippyTab -SessionId (script:Resolve-RequestedSessionId) -Runtime $script:ClippyRuntimeKernel -SurfaceKind $script:ClippySurfaceTerminal -Activate -LaunchHost
    script:Update-WidgetStatus
    return $tab
}

function script:Get-UniqueDirectories {
    param([string[]]$Paths)

    $dirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $candidate = $path
        if (Test-Path $candidate -PathType Leaf) {
            $candidate = Split-Path -Path $candidate -Parent
        }
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate -PathType Container)) {
            [void]$dirs.Add((Resolve-Path $candidate).Path)
        }
    }
    return @($dirs)
}

function script:Get-VsCodeSettingsObject {
    param([string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }
}

function script:Get-WidgetJsonObject {
    param([string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function script:Get-WidgetFileText {
    param([string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return ''
    }

    try {
        return [System.IO.File]::ReadAllText($Path)
    } catch {
        return ''
    }
}

function script:Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName
    )

    if (-not $InputObject -or [string]::IsNullOrWhiteSpace($PropertyName)) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($property) {
        return $property.Value
    }

    return $null
}

function script:Get-McpServerEntries {
    param(
        [object]$ConfigObject,
        [string]$PropertyName
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $serversNode = script:Get-ObjectPropertyValue -InputObject $ConfigObject -PropertyName $PropertyName
    if (-not $serversNode) {
        return @()
    }

    foreach ($property in @($serversNode.PSObject.Properties | Sort-Object -Property Name)) {
        $server = $property.Value
        $url = script:Get-ObjectPropertyValue -InputObject $server -PropertyName 'url'
        $command = script:Get-ObjectPropertyValue -InputObject $server -PropertyName 'command'
        $transport = script:Get-ObjectPropertyValue -InputObject $server -PropertyName 'type'
        if ([string]::IsNullOrWhiteSpace($transport)) {
            $transport = if ($url) { 'http' } else { 'stdio' }
        }

        $detail = if ($url) {
            [string]$url
        } elseif ($command) {
            [string]$command
        } else {
            $null
        }

        $entries.Add([pscustomobject]@{
            Name = [string]$property.Name
            Transport = [string]$transport
            Detail = $detail
        })
    }

    return $entries.ToArray()
}

function script:Get-McpEntriesFromProperties {
    param(
        [object]$ConfigObject,
        [string[]]$PropertyNames
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($propertyName in $PropertyNames) {
        foreach ($entry in @(script:Get-McpServerEntries -ConfigObject $ConfigObject -PropertyName $propertyName)) {
            if ($seen.Add($entry.Name)) {
                $entries.Add($entry)
            }
        }
    }

    return $entries.ToArray()
}

function script:Test-SensitiveConfigKey {
    param([string]$KeyName)

    if ([string]::IsNullOrWhiteSpace($KeyName)) {
        return $false
    }

    return $KeyName -match '(?i)(secret|token|password|api[-_]?key|apikey|client[-_]?secret|private[-_]?key|access[-_]?key|sas|pat|bearer)'
}

function script:Get-SanitizedConfigValue {
    param(
        [object]$Value,
        [string]$PropertyName
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($PropertyName -and (script:Test-SensitiveConfigKey -KeyName $PropertyName)) {
        return '[REDACTED]'
    }

    if ($Value -is [string] -or
        $Value -is [char] -or
        $Value -is [bool] -or
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [double] -or
        $Value -is [decimal]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $sanitized = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $sanitized[[string]$key] = script:Get-SanitizedConfigValue -Value $Value[$key] -PropertyName ([string]$key)
        }
        return [pscustomobject]$sanitized
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((script:Get-SanitizedConfigValue -Value $item -PropertyName $null))
        }
        return @($items)
    }

    if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
        $sanitized = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            $sanitized[$property.Name] = script:Get-SanitizedConfigValue -Value $property.Value -PropertyName $property.Name
        }
        return [pscustomobject]$sanitized
    }

    return [string]$Value
}

function script:Get-McpConfigPreviewObject {
    param(
        [object]$ConfigObject,
        [string[]]$PreviewPropertyNames
    )

    $preview = [ordered]@{}
    foreach ($propertyName in $PreviewPropertyNames) {
        $value = script:Get-ObjectPropertyValue -InputObject $ConfigObject -PropertyName $propertyName
        if ($null -ne $value) {
            $preview[$propertyName] = script:Get-SanitizedConfigValue -Value $value -PropertyName $propertyName
        }
    }

    if ($preview.Count -eq 0) {
        return $null
    }

    return [pscustomobject]$preview
}

function script:Get-McpConfigSnapshot {
    param(
        [string]$Path,
        [string]$Label,
        [string[]]$ServerPropertyNames,
        [string[]]$PreviewPropertyNames
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $null
    }

    $configObject = script:Get-VsCodeSettingsObject -Path $Path
    $previewObject = $null
    $serverEntries = @()

    if ($configObject) {
        $serverEntries = @(script:Get-McpEntriesFromProperties -ConfigObject $configObject -PropertyNames $ServerPropertyNames)
        $previewObject = script:Get-McpConfigPreviewObject -ConfigObject $configObject -PreviewPropertyNames $PreviewPropertyNames
        if (-not $previewObject) {
            $previewObject = [pscustomobject]@{
                note = 'No MCP configuration keys were found in this file.'
            }
        }
    } else {
        $previewObject = [pscustomobject]@{
            error = 'The file could not be parsed as JSON.'
        }
    }

    return [pscustomobject]@{
        Label = $Label
        Path = $Path
        ServerEntries = @($serverEntries)
        PreviewObject = $previewObject
        PreviewJson = ($previewObject | ConvertTo-Json -Depth 40)
    }
}

function script:Get-MergedMcpEntriesFromSnapshots {
    param([object[]]$Snapshots)

    $entries = [System.Collections.Generic.List[object]]::new()
    $index = @{}
    foreach ($snapshot in @($Snapshots)) {
        foreach ($entry in @($snapshot.ServerEntries)) {
            $key = '{0}|{1}|{2}' -f $entry.Name, $entry.Transport, $entry.Detail
            if ($index.ContainsKey($key)) {
                $existing = $index[$key]
                if ($snapshot.Label -notin $existing.DefinedIn) {
                    $existing.DefinedIn = @($existing.DefinedIn + $snapshot.Label)
                }
                continue
            }

            $mergedEntry = [pscustomobject]@{
                Name = $entry.Name
                Transport = $entry.Transport
                Detail = $entry.Detail
                DefinedIn = @($snapshot.Label)
            }
            $index[$key] = $mergedEntry
            $entries.Add($mergedEntry)
        }
    }

    return $entries.ToArray()
}

function script:Get-VsCodeProfileSnapshot {
    param(
        [string]$Name,
        [string]$SettingsPath,
        [string]$ExtensionsDir,
        [string]$UserDir
    )

    $settings = script:Get-VsCodeSettingsObject -Path $SettingsPath
    $extensions = @()
    $configSnapshots = [System.Collections.Generic.List[object]]::new()
    if (Test-Path $ExtensionsDir -PathType Container) {
        $extensions = @(
            Get-ChildItem -Path $ExtensionsDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name |
            Select-Object -ExpandProperty Name
        )
    }

    $settingsSnapshot = script:Get-McpConfigSnapshot `
        -Path $SettingsPath `
        -Label 'Settings' `
        -ServerPropertyNames @('mcp.servers') `
        -PreviewPropertyNames @('mcp.servers')
    if ($settingsSnapshot) {
        $configSnapshots.Add($settingsSnapshot)
    }

    $userMcpPath = Join-Path $UserDir 'mcp.json'
    $userMcpSnapshot = script:Get-McpConfigSnapshot `
        -Path $userMcpPath `
        -Label 'User mcp.json' `
        -ServerPropertyNames @('servers', 'mcpServers', 'mcp.servers') `
        -PreviewPropertyNames @('servers', 'mcpServers', 'mcp.servers', 'inputs', 'enabled')
    if ($userMcpSnapshot) {
        $configSnapshots.Add($userMcpSnapshot)
    }

    $profilesRoot = Join-Path $UserDir 'profiles'
    if (Test-Path $profilesRoot -PathType Container) {
        $profileMcpPaths = @(
            Get-ChildItem -Path $profilesRoot -Filter 'mcp.json' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName |
            Select-Object -ExpandProperty FullName
        )
        foreach ($profileMcpPath in $profileMcpPaths) {
            $profileId = Split-Path (Split-Path $profileMcpPath -Parent) -Leaf
            $profileSnapshot = script:Get-McpConfigSnapshot `
                -Path $profileMcpPath `
                -Label ("Profile {0} mcp.json" -f $profileId) `
                -ServerPropertyNames @('servers', 'mcpServers', 'mcp.servers') `
                -PreviewPropertyNames @('servers', 'mcpServers', 'mcp.servers', 'inputs', 'enabled')
            if ($profileSnapshot) {
                $configSnapshots.Add($profileSnapshot)
            }
        }
    }

    return @{
        Name = $Name
        SettingsPath = $SettingsPath
        SettingsKeys = if ($settings) { @($settings.PSObject.Properties.Name | Sort-Object) } else { @() }
        ExtensionsDir = $ExtensionsDir
        Extensions = $extensions
        UserDir = $UserDir
        McpConfigSnapshots = @($configSnapshots)
        McpServers = @(script:Get-MergedMcpEntriesFromSnapshots -Snapshots @($configSnapshots))
    }
}

function script:Refresh-VsCodeContext {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $script:VsCodeSnapshot = @{
        Regular = script:Get-VsCodeProfileSnapshot `
            -Name 'VS Code' `
            -SettingsPath (Join-Path $appData 'Code\User\settings.json') `
            -ExtensionsDir (Join-Path $userProfile '.vscode\extensions') `
            -UserDir (Join-Path $appData 'Code\User')
        Insiders = script:Get-VsCodeProfileSnapshot `
            -Name 'VS Code Insiders' `
            -SettingsPath (Join-Path $appData 'Code - Insiders\User\settings.json') `
            -ExtensionsDir (Join-Path $userProfile '.vscode-insiders\extensions') `
            -UserDir (Join-Path $appData 'Code - Insiders\User')
    }
}

function script:Refresh-AgentCatalog {
    $agentsDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.copilot\agents'
    $script:AvailableAgents = @()

    if (-not (Test-Path $agentsDir -PathType Container)) {
        return
    }

    $script:AvailableAgents = @(
        Get-ChildItem -Path $agentsDir -File -Filter '*.md' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -notin @('README', 'readme', 'index') } |
        Sort-Object -Property Name |
        ForEach-Object {
            [pscustomobject]@{
                Id = $_.BaseName
                DisplayName = $_.BaseName
                Path = $_.FullName
            }
        }
    )
}

function script:Get-DefaultAgentId {
    if ($script:AvailableAgents.Count -eq 0) {
        return $null
    }

    foreach ($candidate in @('dayour-swe', 'dayour', 'dayswarm')) {
        if ($candidate -and ($script:AvailableAgents.Id -contains $candidate)) {
            return $candidate
        }
    }

    return [string]$script:AvailableAgents[0].Id
}

function script:Get-AgentDefinition {
    param([string]$AgentId)

    if ([string]::IsNullOrWhiteSpace($AgentId)) {
        return $null
    }

    foreach ($definition in $script:AvailableAgents) {
        if ($definition.Id -eq $AgentId) {
            return $definition
        }
    }

    return $null
}

function script:Resolve-AgentToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $normalized = $Token.Trim()
    foreach ($definition in $script:AvailableAgents) {
        if ($definition.Id.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase) -or
            $definition.DisplayName.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $definition.Id
        }
    }

    return $null
}

function script:Get-ModelDefinition {
    param([string]$ModelId)

    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        return $null
    }

    return $script:ModelCatalogById[$ModelId]
}

function script:Resolve-ModelToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $normalized = $Token.Trim()
    foreach ($definition in $script:AvailableModelCatalog) {
        if ($definition.Id.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase) -or
            $definition.DisplayName.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $definition.Id
        }
    }

    return $null
}

function script:Get-SelectedModelDisplayName {
    $modelId = script:Get-ActiveTabModelId
    $definition = script:Get-ModelDefinition -ModelId $modelId
    if ($definition) {
        return $definition.DisplayName
    }

    return $modelId
}

function script:Get-ActiveAgentId {
    if (-not $script:WidgetSettings) {
        return $null
    }

    $activeTab = script:Get-ActiveClippyTab
    if (script:Test-ClippyKernelTab -Tab $activeTab) {
        return $null
    }

    return script:Get-ResolvedAgentIdForTab -Tab $activeTab
}

function script:Get-ActiveAgentDisplayName {
    $agentId = script:Get-ActiveAgentId
    if ([string]::IsNullOrWhiteSpace($agentId)) {
        return 'none'
    }

    $definition = script:Get-AgentDefinition -AgentId $agentId
    if ($definition) {
        return $definition.DisplayName
    }

    return $agentId
}

function script:Get-ToolSourceSnapshot {
    param(
        [string]$Name,
        [string]$SummaryName,
        [object[]]$ConfigSnapshots,
        [string[]]$CandidatePaths
    )

    $snapshots = @($ConfigSnapshots | Where-Object { $_ })
    $paths = @($snapshots | ForEach-Object { $_.Path })
    $servers = @(script:Get-MergedMcpEntriesFromSnapshots -Snapshots $snapshots)
    $schemaFiles = @(
        foreach ($snapshot in $snapshots) {
            [pscustomobject]@{
                label = $snapshot.Label
                path = $snapshot.Path
                config = $snapshot.PreviewObject
            }
        }
    )

    $schemaPayload = if ($schemaFiles.Count -gt 0) {
        [pscustomobject]@{
            source = $Name
            files = $schemaFiles
        }
    } else {
        [pscustomobject]@{
            source = $Name
            message = 'No MCP configuration files were found.'
            files = @()
        }
    }

    $tilePayload = [pscustomobject]@{
        source = $Name
        summaryName = $SummaryName
        serverCount = $servers.Count
        paths = if ($paths.Count -gt 0) { $paths } else { @($CandidatePaths) }
        servers = @(
            foreach ($server in $servers) {
                [pscustomobject]@{
                    name = $server.Name
                    transport = $server.Transport
                    detail = $server.Detail
                    definedIn = $server.DefinedIn
                }
            }
        )
        schema = $schemaPayload
    }

    return [pscustomobject]@{
        Name = $Name
        SummaryName = $SummaryName
        Paths = $paths
        CandidatePaths = @($CandidatePaths)
        Servers = $servers
        ConfigSnapshots = $snapshots
        SchemaJson = ($schemaPayload | ConvertTo-Json -Depth 40)
        TileJson = ($tilePayload | ConvertTo-Json -Depth 40)
    }
}

function script:Refresh-ToolSourceContext {
    $copilotMcpPath = Join-Path $script:CopilotConfigDir 'mcp-config.json'
    $copilotSnapshots = @()
    $copilotSnapshot = script:Get-McpConfigSnapshot `
        -Path $copilotMcpPath `
        -Label 'mcp-config.json' `
        -ServerPropertyNames @('mcpServers') `
        -PreviewPropertyNames @('mcpServers', 'inputs')
    if ($copilotSnapshot) {
        $copilotSnapshots += $copilotSnapshot
    }

    $claudeDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude'
    $claudeConfigPath = Join-Path $claudeDir 'config.json'
    $claudeSettingsPath = Join-Path $claudeDir 'settings.json'
    $claudeSnapshots = [System.Collections.Generic.List[object]]::new()
    foreach ($configPath in @($claudeConfigPath, $claudeSettingsPath)) {
        $snapshot = script:Get-McpConfigSnapshot `
            -Path $configPath `
            -Label (Split-Path $configPath -Leaf) `
            -ServerPropertyNames @('mcpServers', 'mcp.servers', 'servers') `
            -PreviewPropertyNames @('mcpServers', 'mcp.servers', 'servers', 'inputs', 'enabled')
        if ($snapshot) {
            $claudeSnapshots.Add($snapshot)
        }
    }

    $script:ToolSourceSnapshot = [ordered]@{
        Copilot = script:Get-ToolSourceSnapshot `
            -Name '.copilot' `
            -SummaryName '.copilot' `
            -ConfigSnapshots $copilotSnapshots `
            -CandidatePaths @($copilotMcpPath)
        Regular = script:Get-ToolSourceSnapshot `
            -Name 'VS Code' `
            -SummaryName 'VS Code' `
            -ConfigSnapshots $script:VsCodeSnapshot.Regular.McpConfigSnapshots `
            -CandidatePaths @(
                $script:VsCodeSnapshot.Regular.SettingsPath,
                (Join-Path $script:VsCodeSnapshot.Regular.UserDir 'mcp.json')
            )
        Insiders = script:Get-ToolSourceSnapshot `
            -Name 'VS Code Insiders' `
            -SummaryName 'Insiders' `
            -ConfigSnapshots $script:VsCodeSnapshot.Insiders.McpConfigSnapshots `
            -CandidatePaths @(
                $script:VsCodeSnapshot.Insiders.SettingsPath,
                (Join-Path $script:VsCodeSnapshot.Insiders.UserDir 'mcp.json')
            )
        Claude = script:Get-ToolSourceSnapshot `
            -Name 'Claude Code' `
            -SummaryName 'Claude' `
            -ConfigSnapshots $claudeSnapshots.ToArray() `
            -CandidatePaths @($claudeConfigPath, $claudeSettingsPath)
    }
}

function script:Get-ExtensionSourceSummary {
    if (-not $script:WidgetSettings) { return 'Editor context: pending' }

    $enabled = [System.Collections.Generic.List[string]]::new()
    if ($script:WidgetSettings.Extensions.IncludeRegularSettings -or $script:WidgetSettings.Extensions.IncludeRegularExtensions) {
        $enabled.Add('VS Code')
    }
    if ($script:WidgetSettings.Extensions.IncludeInsidersSettings -or $script:WidgetSettings.Extensions.IncludeInsidersExtensions) {
        $enabled.Add('VS Code Insiders')
    }

    if ($enabled.Count -eq 0) {
        return 'Editor context: off'
    }

    return 'Editor context: ' + ($enabled -join ', ')
}

function script:Get-McpSourceSummary {
    if ($script:ToolSourceSnapshot.Count -eq 0) {
        return 'MCP: pending'
    }

    $parts = foreach ($source in $script:ToolSourceSnapshot.Values) {
        '{0} {1}' -f $source.SummaryName, $source.Servers.Count
    }

    return 'MCP: ' + ($parts -join ', ')
}

function script:Copy-WidgetTextToClipboard {
    param(
        [string]$Text,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        script:Write-Term "No $Label is available to copy." "#CCA700"
        script:Write-Term ""
        return
    }

    try {
        [Windows.Clipboard]::SetText($Text)
        script:Write-Term "Copied $Label to the clipboard." "#4EC9B0"
    } catch {
        script:Write-Term "ERROR: Could not copy $Label. $($_.Exception.Message)" "#F44747"
    }
    script:Write-Term ""
}

function script:Copy-WidgetFileToClipboard {
    param(
        [string]$Path,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path -PathType Leaf)) {
        script:Write-Term "No $Label file is available to copy." "#CCA700"
        script:Write-Term ""
        return
    }

    try {
        $content = [System.IO.File]::ReadAllText($Path)
    } catch {
        script:Write-Term "ERROR: Could not read $Label. $($_.Exception.Message)" "#F44747"
        script:Write-Term ""
        return
    }

    script:Copy-WidgetTextToClipboard -Text $content -Label $Label
}

function script:Copy-ActiveClippyAdaptiveCard {
    $tab = script:Get-ActiveClippyTab
    if (-not $tab) {
        script:Write-Term "No active Clippy tab is available to copy." "#CCA700"
        script:Write-Term ""
        return
    }

    script:Copy-WidgetTextToClipboard -Text ([string]$tab.AdaptiveCardJson) -Label 'active adaptive card'
}

function script:Copy-ActiveClippyAdaptiveCardData {
    $tab = script:Get-ActiveClippyTab
    if (-not $tab) {
        script:Write-Term "No active Clippy tab is available to copy." "#CCA700"
        script:Write-Term ""
        return
    }

    script:Copy-WidgetTextToClipboard -Text ([string]$tab.AdaptiveCardDataJson) -Label 'active adaptive card data'
}

function script:New-ToolbarComboItem {
    param(
        [Parameter(Mandatory)]
        [string]$Tag,
        [Parameter(Mandatory)]
        [string]$PrimaryText,
        [string]$SecondaryText,
        [string]$ToolTip
    )

    $item = [Windows.Controls.ComboBoxItem]::new()
    $item.Tag = $Tag

    $grid = [Windows.Controls.Grid]::new()
    $primaryColumn = [Windows.Controls.ColumnDefinition]::new()
    $detailColumn = [Windows.Controls.ColumnDefinition]::new()
    $detailColumn.Width = [Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($primaryColumn)
    [void]$grid.ColumnDefinitions.Add($detailColumn)

    $nameText = [Windows.Controls.TextBlock]::new()
    $nameText.Text = $PrimaryText
    $nameText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FFE8E8E8")
    $nameText.TextTrimming = 'CharacterEllipsis'
    $nameText.VerticalAlignment = 'Center'
    $grid.Children.Add($nameText) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($SecondaryText)) {
        $detailText = [Windows.Controls.TextBlock]::new()
        $detailText.Text = $SecondaryText
        $detailText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FF8F8FAF")
        $detailText.Margin = [Windows.Thickness]::new(10, 0, 0, 0)
        $detailText.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($detailText, 1)
        $grid.Children.Add($detailText) | Out-Null
    }

    $item.Content = $grid
    if ($ToolTip) {
        $item.ToolTip = $ToolTip
    }

    return $item
}

function script:Set-ComboSelectionByTag {
    param(
        [Parameter(Mandatory)]
        $ComboBox,
        [string]$Tag
    )

    foreach ($item in @($ComboBox.Items)) {
        if ([string]$item.Tag -eq $Tag) {
            $ComboBox.SelectedItem = $item
            return
        }
    }

    $ComboBox.SelectedItem = $null
}

function script:Get-AttachmentSummaryText {
    $tabCount = $script:ClippyTabOrder.Count
    return "Bench tabs: $tabCount live. Use + to open another bench tab"
}

function script:Update-WidgetStatus {
    if (-not $script:Chat -or -not $script:Chat.Dispatcher -or $script:Chat.Dispatcher.HasShutdownStarted) {
        return
    }

    if (-not $script:Chat.Dispatcher.CheckAccess()) {
        script:Invoke-OnUiThread -Async -Action {
            script:Update-WidgetStatus
        }
        return
    }

    if (-not $script:WidgetSettings) { return }

    $activeTab = script:Get-ActiveClippyTab
    $activeMode = script:Get-ActiveTabMode
    $hostStateInfo = script:Get-TabHostStateInfo -Tab $activeTab
    $modeDetail = if (script:Test-ClippyKernelTab -Tab $activeTab) {
        'Kernel tab active. Use the widget prompt or type directly into the embedded terminal for this bench tab.'
    } elseif ($activeMode -eq 'Plan') {
        'Plan mode is selected. Prefix new requests with [[PLAN]] in the terminal input box.'
    } else {
        'The active prompt-backed bench tab stays live while Clippy streams into this pane.'
    }

    $tabLabel = if ($activeTab) { script:Get-TabTerminalTitle -Tab $activeTab } else { 'No active tab' }
    $cMeta.Text = "Bench: $tabLabel  Runtime: $(script:Get-TabRuntimeDisplayName -Tab $activeTab)  Tab: $(script:Get-ShortSessionId)  Host: $($hostStateInfo.Label)  Agent: $(script:Get-ActiveAgentDisplayName)  Mode: $activeMode  Model: $(script:Get-SelectedModelDisplayName)  $modeDetail"
    $cFiles.Text = "$(script:Get-AttachmentSummaryText)  $(script:Get-ExtensionSourceSummary)  $(script:Get-McpSourceSummary)"

    script:Refresh-BenchTiles
}

function script:Set-WidgetMode {
    param([string]$Mode)

    if ($Mode -notin $script:AvailableModes) { return }
    $script:WidgetSettings.Mode = $Mode
    $activeTab = script:Get-ActiveClippyTab
    if ($activeTab -and -not (script:Test-ClippyKernelTab -Tab $activeTab)) {
        $activeTab.Mode = $Mode
        $activeTab.DisplayName = script:Get-DefaultTabDisplayName -Tab $activeTab
        script:Restart-ClippyTabHostBridge -Tab $activeTab -ConfigOverrides @{
            mode = ([string]$Mode).ToLowerInvariant()
        }
    }
    script:Save-WidgetSettings
    script:Refresh-ClippyTabStrip
    script:Sync-WidgetUi
}

function script:Get-NextWidgetMode {
    param([string]$Mode)

    $modeList = @($script:AvailableModes)
    if ($modeList.Count -eq 0) {
        return $null
    }

    $index = [array]::IndexOf($modeList, $Mode)
    if ($index -lt 0) {
        return $modeList[0]
    }

    return $modeList[(($index + 1) % $modeList.Count)]
}

function script:Get-ModeTilePalette {
    param([string]$Mode)

    switch ($Mode) {
        'Plan' {
            return [pscustomobject]@{
                Background = '#FF2D2348'
                BorderBrush = '#FF9A7BF2'
                Foreground = '#FFF5EEFF'
            }
        }
        'Swarm' {
            return [pscustomobject]@{
                Background = '#FF143042'
                BorderBrush = '#FF4EC9B0'
                Foreground = '#FFE8FFF8'
            }
        }
        default {
            return [pscustomobject]@{
                Background = '#FF1D2440'
                BorderBrush = '#FF5B5FC7'
                Foreground = '#FFF2F3FF'
            }
        }
    }
}

function script:Update-ModeCycleTile {
    if (-not $script:ModeCycleButton -or -not $script:WidgetSettings) { return }

    $currentMode = script:Get-ActiveTabMode
    if ($currentMode -notin $script:AvailableModes) {
        $currentMode = $script:AvailableModes[0]
    }
    $nextMode = script:Get-NextWidgetMode -Mode $currentMode
    $palette = script:Get-ModeTilePalette -Mode $currentMode
    $brushConverter = [Windows.Media.BrushConverter]::new()

    $script:ModeCycleButton.Content = $currentMode
    $script:ModeCycleButton.Background = $brushConverter.ConvertFromString($palette.Background)
    $script:ModeCycleButton.BorderBrush = $brushConverter.ConvertFromString($palette.BorderBrush)
    $script:ModeCycleButton.Foreground = $brushConverter.ConvertFromString($palette.Foreground)
    $script:ModeCycleButton.ToolTip = "Current mode: $currentMode`nClick to switch to $nextMode."
}

function script:Cycle-WidgetMode {
    if (-not $script:WidgetSettings) { return }

    $nextMode = script:Get-NextWidgetMode -Mode (script:Get-ActiveTabMode)
    if ($nextMode) {
        script:Set-WidgetMode $nextMode
    }
}

function script:Set-WidgetModel {
    param([string]$Model)

    $resolvedModel = script:Resolve-ModelToken -Token $Model
    if (-not $resolvedModel) { return }
    $script:WidgetSettings.Model = $resolvedModel
    $activeTab = script:Get-ActiveClippyTab
    if ($activeTab -and -not (script:Test-ClippyKernelTab -Tab $activeTab)) {
        $activeTab.Model = $resolvedModel
        script:Restart-ClippyTabHostBridge -Tab $activeTab -ConfigOverrides @{
            model = $resolvedModel
        }
    }
    script:Save-WidgetSettings
    script:Refresh-ClippyTabStrip
    script:Sync-WidgetUi
}

function script:Set-WidgetAgent {
    param([string]$Agent)

    $resolvedAgent = script:Resolve-AgentToken -Token $Agent
    if (-not $resolvedAgent) { return }
    $script:WidgetSettings.Agent = $resolvedAgent
    $activeTab = script:Get-ActiveClippyTab
    if ($activeTab -and -not (script:Test-ClippyKernelTab -Tab $activeTab)) {
        $activeTab.Agent = $resolvedAgent
        script:Restart-ClippyTabHostBridge -Tab $activeTab -ConfigOverrides @{
            agent = $resolvedAgent
        }
    }
    script:Save-WidgetSettings
    script:Refresh-ClippyTabStrip
    script:Sync-WidgetUi
}

function script:Sync-WidgetUi {
    if (-not $script:WidgetSettings) { return }

    $script:IsSyncingUi = $true
    try {
        if ($cAgent) {
            script:Set-ComboSelectionByTag -ComboBox $cAgent -Tag (script:Get-ActiveTabAgentToken)
        }
        if ($cModel) {
            script:Set-ComboSelectionByTag -ComboBox $cModel -Tag (script:Get-ActiveTabModelId)
        }

        $activeMode = script:Get-ActiveTabMode
        $activeAgent = script:Get-ActiveTabAgentToken
        $activeModel = script:Get-ActiveTabModelId
        foreach ($mode in $script:ModeMenuItems.Keys) {
            $script:ModeMenuItems[$mode].IsChecked = ($mode -eq $activeMode)
        }
        foreach ($agent in $script:AgentMenuItems.Keys) {
            $script:AgentMenuItems[$agent].IsChecked = ($agent -eq $activeAgent)
        }
        foreach ($model in $script:ModelMenuItems.Keys) {
            $script:ModelMenuItems[$model].IsChecked = ($model -eq $activeModel)
        }

        script:Update-WidgetStatus
        script:Update-ToolbarControls
    } finally {
        $script:IsSyncingUi = $false
    }
}

function script:Add-AttachmentFiles {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path -PathType Leaf)) {
            continue
        }

        $resolved = (Resolve-Path $path).Path
        if (-not $script:AttachedFiles.Contains($resolved)) {
            $script:AttachedFiles.Add($resolved)
        }
    }

    script:Update-WidgetStatus
}

function script:Pick-AttachmentFiles {
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Multiselect = $true
    $dialog.Title = 'Pick files for prompt-tab context'
    $dialog.CheckFileExists = $true

    if ($dialog.ShowDialog()) {
        script:Add-AttachmentFiles -Paths $dialog.FileNames
        script:Write-Term "Attached $($dialog.FileNames.Count) file(s) for the current bench tab." "#4EC9B0"
        script:Write-Term ""
    }
}

function script:Clear-Attachments {
    $script:AttachedFiles.Clear()
    script:Update-WidgetStatus
    script:Write-Term "Cleared attached files." "#6B6B8D"
    script:Write-Term ""
}

function script:Get-VsCodePromptContextLines {
    if (-not $script:WidgetSettings) { return @() }

    # Guard: only do expensive file-system scans when at least one include flag
    # is actually enabled.  Calling Refresh-VsCodeContext unconditionally runs
    # recursive Get-ChildItem on the UI thread and blocks the Dispatcher for
    # tens of seconds on machines with many VS Code profiles/extensions.
    $ext = $script:WidgetSettings.Extensions
    $anyFlagEnabled = $ext.IncludeRegularSettings -or
                      $ext.IncludeRegularExtensions -or
                      $ext.IncludeInsidersSettings  -or
                      $ext.IncludeInsidersExtensions
    if (-not $anyFlagEnabled) { return @() }

    script:Refresh-VsCodeContext
    $lines = [System.Collections.Generic.List[string]]::new()

    $regular = $script:VsCodeSnapshot.Regular
    if ($script:WidgetSettings.Extensions.IncludeRegularSettings -and $regular.SettingsKeys.Count -gt 0) {
        $preview = @($regular.SettingsKeys | Select-Object -First 15)
        $suffix = if ($regular.SettingsKeys.Count -gt $preview.Count) { " (+$($regular.SettingsKeys.Count - $preview.Count) more keys)" } else { '' }
        $lines.Add("VS Code settings keys: $($preview -join ', ')$suffix")
    }
    if ($script:WidgetSettings.Extensions.IncludeRegularExtensions -and $regular.Extensions.Count -gt 0) {
        $preview = @($regular.Extensions | Select-Object -First 15)
        $suffix = if ($regular.Extensions.Count -gt $preview.Count) { " (+$($regular.Extensions.Count - $preview.Count) more extensions)" } else { '' }
        $lines.Add("VS Code extensions: $($preview -join ', ')$suffix")
    }

    $insiders = $script:VsCodeSnapshot.Insiders
    if ($script:WidgetSettings.Extensions.IncludeInsidersSettings -and $insiders.SettingsKeys.Count -gt 0) {
        $preview = @($insiders.SettingsKeys | Select-Object -First 15)
        $suffix = if ($insiders.SettingsKeys.Count -gt $preview.Count) { " (+$($insiders.SettingsKeys.Count - $preview.Count) more keys)" } else { '' }
        $lines.Add("VS Code Insiders settings keys: $($preview -join ', ')$suffix")
    }
    if ($script:WidgetSettings.Extensions.IncludeInsidersExtensions -and $insiders.Extensions.Count -gt 0) {
        $preview = @($insiders.Extensions | Select-Object -First 15)
        $suffix = if ($insiders.Extensions.Count -gt $preview.Count) { " (+$($insiders.Extensions.Count - $preview.Count) more extensions)" } else { '' }
        $lines.Add("VS Code Insiders extensions: $($preview -join ', ')$suffix")
    }

    return @($lines)
}

function script:Build-CopilotPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if ((script:Get-ActiveTabMode) -eq 'Plan') {
        $lines.Add('[[PLAN]]')
    }

    if ($script:AttachedFiles.Count -gt 0) {
        $lines.Add('Attached files for this turn:')
        foreach ($file in $script:AttachedFiles) {
            $lines.Add("@$file")
        }
        $lines.Add('')
    }

    $editorContext = @(script:Get-VsCodePromptContextLines)
    if ($editorContext.Count -gt 0) {
        $lines.Add('Editor context:')
        foreach ($line in $editorContext) {
            $lines.Add("- $line")
        }
        $lines.Add('')
    }

    $lines.Add($Prompt)
    return ($lines -join "`n")
}

function script:Get-ToolResultText {
    param($Result)

    if (-not $Result) { return $null }

    if ($Result.PSObject.Properties.Name -contains 'content' -and -not [string]::IsNullOrWhiteSpace([string]$Result.content)) {
        return [string]$Result.content
    }

    if ($Result.PSObject.Properties.Name -contains 'detailedContent' -and -not [string]::IsNullOrWhiteSpace([string]$Result.detailedContent)) {
        return [string]$Result.detailedContent
    }

    return (($Result | ConvertTo-Json -Compress -Depth 6) -replace '\\u001b\[[0-9;]*m', '')
}

# ── VS Code-style inline terminal block helpers ───────────────────

function script:Get-ToolExecutionSummary {
    param($EventData)

    $toolName = [string]$EventData.toolName
    $input = $EventData.input

    if ($input) {
        foreach ($paramName in @('command', 'query', 'url', 'path', 'text', 'message', 'content', 'script', 'code')) {
            if ($input.PSObject.Properties.Name -contains $paramName) {
                $val = [string]$input.$paramName
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $val = $val.Trim() -replace '[\r\n]+', ' '
                    if ($val.Length -gt 80) { $val = $val.Substring(0, 77) + '...' }
                    return $val
                }
            }
        }
        $json = ($input | ConvertTo-Json -Compress -Depth 2)
        if ($json.Length -gt 80) { $json = $json.Substring(0, 77) + '...' }
        return $json
    }

    return $toolName
}

function script:New-InlineTerminalBlock {
    # Creates a VS Code-style collapsible terminal block as a WPF element.
    # Must be called on the UI / Dispatcher thread.
    param(
        [string]$HeaderLabel
    )

    $brushConv = [Windows.Media.BrushConverter]::new()

    # ── Outer border ─────────────────────────────────────────────
    $outerBorder = [Windows.Controls.Border]::new()
    $outerBorder.Margin = [Windows.Thickness]::new(2, 4, 2, 4)
    $outerBorder.CornerRadius = [Windows.CornerRadius]::new(6)
    $outerBorder.Background = $brushConv.ConvertFromString("#FF0D0D14")
    $outerBorder.BorderBrush = $brushConv.ConvertFromString("#FF23233A")
    $outerBorder.BorderThickness = [Windows.Thickness]::new(1)

    $mainGrid = [Windows.Controls.Grid]::new()
    $mainGrid.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $mainGrid.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $outerBorder.Child = $mainGrid

    # ── Header ───────────────────────────────────────────────────
    $headerBorder = [Windows.Controls.Border]::new()
    $headerBorder.Background = $brushConv.ConvertFromString("#FF12121C")
    $headerBorder.CornerRadius = [Windows.CornerRadius]::new(6, 6, 0, 0)
    $headerBorder.Padding = [Windows.Thickness]::new(10, 5, 8, 5)
    [Windows.Controls.Grid]::SetRow($headerBorder, 0)
    $mainGrid.Children.Add($headerBorder)

    $headerDock = [Windows.Controls.DockPanel]::new()
    $headerDock.LastChildFill = $true
    $headerBorder.Child = $headerDock

    # Copy button (right-docked first so DockPanel fills remaining to label)
    $copyBtn = [Windows.Controls.Button]::new()
    $copyBtn.Content = [char]0xF0E3   # Segoe MDL2 "Copy"
    $copyBtn.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
    $copyBtn.FontSize = 11
    $copyBtn.Width = 24
    $copyBtn.Height = 22
    $copyBtn.Background = [Windows.Media.Brushes]::Transparent
    $copyBtn.Foreground = $brushConv.ConvertFromString("#FF5B5F7F")
    $copyBtn.BorderThickness = [Windows.Thickness]::new(0)
    $copyBtn.VerticalAlignment = 'Center'
    $copyBtn.Cursor = [Windows.Input.Cursors]::Hand
    $copyBtn.ToolTip = 'Copy output to clipboard'
    [Windows.Controls.DockPanel]::SetDock($copyBtn, 'Right')
    $headerDock.Children.Add($copyBtn)

    # Chevron toggle (left-docked)
    $toggleBtn = [Windows.Controls.Button]::new()
    $toggleBtn.Content = [char]0xE972  # ChevronDownSmall
    $toggleBtn.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
    $toggleBtn.FontSize = 9
    $toggleBtn.Width = 20
    $toggleBtn.Height = 20
    $toggleBtn.Background = [Windows.Media.Brushes]::Transparent
    $toggleBtn.Foreground = $brushConv.ConvertFromString("#FF8F8FAF")
    $toggleBtn.BorderThickness = [Windows.Thickness]::new(0)
    $toggleBtn.VerticalAlignment = 'Center'
    $toggleBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
    $toggleBtn.Cursor = [Windows.Input.Cursors]::Hand
    [Windows.Controls.DockPanel]::SetDock($toggleBtn, 'Left')
    $headerDock.Children.Add($toggleBtn)

    # "Ran `command`" label row
    $labelPanel = [Windows.Controls.StackPanel]::new()
    $labelPanel.Orientation = 'Horizontal'
    $labelPanel.VerticalAlignment = 'Center'

    $ranLabel = [Windows.Controls.TextBlock]::new()
    $ranLabel.Text = 'Ran '
    $ranLabel.Foreground = $brushConv.ConvertFromString("#FF6B6B8D")
    $ranLabel.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI')
    $ranLabel.FontSize = 11.5
    $ranLabel.VerticalAlignment = 'Center'
    $labelPanel.Children.Add($ranLabel)

    $displayCmd = if ($HeaderLabel.Length -gt 60) { $HeaderLabel.Substring(0, 57) + '...' } else { $HeaderLabel }
    $cmdLabel = [Windows.Controls.TextBlock]::new()
    $cmdLabel.Text = $displayCmd
    $cmdLabel.Foreground = $brushConv.ConvertFromString("#FFCCCCCC")
    $cmdLabel.FontFamily = [Windows.Media.FontFamily]::new('Cascadia Code, Cascadia Mono, Consolas')
    $cmdLabel.FontSize = 11
    $cmdLabel.VerticalAlignment = 'Center'
    $cmdLabel.TextTrimming = 'CharacterEllipsis'
    $labelPanel.Children.Add($cmdLabel)

    $headerDock.Children.Add($labelPanel)

    # ── Content / output area ────────────────────────────────────
    $contentBorder = [Windows.Controls.Border]::new()
    $contentBorder.BorderBrush = $brushConv.ConvertFromString("#FF1A1A2E")
    $contentBorder.BorderThickness = [Windows.Thickness]::new(0, 1, 0, 0)
    $contentBorder.Padding = [Windows.Thickness]::new(12, 6, 12, 8)
    $contentBorder.Visibility = 'Visible'
    [Windows.Controls.Grid]::SetRow($contentBorder, 1)
    $mainGrid.Children.Add($contentBorder)

    $scrollViewer = [Windows.Controls.ScrollViewer]::new()
    $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
    $scrollViewer.VerticalScrollBarVisibility = 'Auto'
    $scrollViewer.MaxHeight = 220
    $contentBorder.Child = $scrollViewer

    $outputPanel = [Windows.Controls.StackPanel]::new()
    $outputPanel.Orientation = 'Vertical'
    $scrollViewer.Content = $outputPanel

    # ── Wire collapse toggle ─────────────────────────────────────
    $capturedContent = $contentBorder
    $capturedToggle = $toggleBtn
    $toggleBtn.Add_Click({
        if ($capturedContent.Visibility -eq 'Visible') {
            $capturedContent.Visibility = 'Collapsed'
            $capturedToggle.Content = [char]0xE974   # ChevronRightSmall
        } else {
            $capturedContent.Visibility = 'Visible'
            $capturedToggle.Content = [char]0xE972   # ChevronDownSmall
        }
    })

    # ── Wire copy button ─────────────────────────────────────────
    $capturedPanel = $outputPanel
    $copyBtn.Add_Click({
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($child in $capturedPanel.Children) {
            if ($child -is [Windows.Controls.TextBlock]) {
                $lines.Add([string]$child.Text)
            }
        }
        $text = $lines -join "`n"
        if (-not [string]::IsNullOrEmpty($text)) {
            try { [Windows.Clipboard]::SetText($text) } catch {}
        }
    })

    return [pscustomobject]@{
        Container     = $outerBorder
        OutputPanel   = $outputPanel
        ToggleBtn     = $toggleBtn
        ContentBorder = $contentBorder
        HeaderLabel   = $HeaderLabel
        Succeeded     = $null
    }
}

function script:Add-InlineTerminalBlockLine {
    param(
        [Parameter(Mandatory)]
        $Block,
        [string]$Text = '',
        [string]$Color = "#8F8FAF",
        [switch]$IsError
    )

    if (-not $Block -or -not $Block.OutputPanel) { return }

    $lineColor = if ($IsError) { "#F48771" } else { $Color }
    $tb = [Windows.Controls.TextBlock]::new()
    $tb.Text = $Text
    $tb.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($lineColor)
    $tb.FontFamily = [Windows.Media.FontFamily]::new('Cascadia Code, Cascadia Mono, Consolas')
    $tb.FontSize = 11.5
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = [Windows.Thickness]::new(0, 0, 0, 1)
    $Block.OutputPanel.Children.Add($tb) | Out-Null
}

function script:Finalize-InlineTerminalBlock {
    param(
        [Parameter(Mandatory)]
        $Block,
        [switch]$Success
    )

    if (-not $Block) { return }

    $Block.Succeeded = [bool]$Success
    $accentColor = if ($Success) { "#FF3A5C40" } else { "#FF6B2020" }
    $Block.Container.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($accentColor)

    # Auto-collapse when output fits on a screen without scrolling (≤ 8 lines)
    # or when it is a success with ≤ 4 lines (keeps transcript clean like VS Code)
    $lineCount = $Block.OutputPanel.Children.Count
    $autoCollapse = ($Success -and $lineCount -le 4) -or ($lineCount -eq 0)
    if ($autoCollapse) {
        $Block.ContentBorder.Visibility = 'Collapsed'
        $Block.ToggleBtn.Content = [char]0xE974
    }
}

function script:Handle-CopilotEvent {
    param(
        [Parameter(Mandatory)]
        $Event,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    script:Write-WidgetDebugLog "CopilotEvent type=$([string]$Event.type) tabId=$([string]$State.TabId) waiting=$([string]$State.WaitingForResponse)"

    switch ([string]$Event.type) {
        'assistant.reasoning_delta' {
            $delta = [string]$Event.data.deltaContent
            if (-not [string]::IsNullOrEmpty($delta)) {
                $State.HadThoughtOutput = $true
                $State.StreamedThoughtText = [string]$State.StreamedThoughtText + $delta
                script:Write-WidgetDebugLog "ThoughtDelta len=$($delta.Length) tabId=$([string]$State.TabId)"
                script:Append-ThoughtStream -Text $delta -Color "#8F8FAF" -TabId $State.TabId
            }
            return
        }
        'assistant.reasoning' {
            $content = [string]$Event.data.content
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                $State.FinalThoughtText = $content
                if (-not $State.HadThoughtOutput) {
                    $State.HadThoughtOutput = $true
                    $State.StreamedThoughtText = $content
                    script:Append-ThoughtStream -Text $content -Color "#8F8FAF" -TabId $State.TabId
                } elseif ($content.StartsWith([string]$State.StreamedThoughtText)) {
                    $streamedLen = ([string]$State.StreamedThoughtText).Length
                    if ($streamedLen -le $content.Length) {
                        $suffix = $content.Substring($streamedLen)
                    } else {
                        $suffix = ''
                    }
                    if ($suffix) {
                        $State.StreamedThoughtText = $content
                        script:Append-ThoughtStream -Text $suffix -Color "#8F8FAF" -TabId $State.TabId
                    }
                } else {
                    $State.StreamedThoughtText = $content
                    script:Append-ThoughtStream -Text $content -Color "#8F8FAF" -TabId $State.TabId
                }
            }
            return
        }
        'assistant.message_delta' {
            $delta = [string]$Event.data.deltaContent
            if (-not [string]::IsNullOrEmpty($delta)) {
                $State.HadAssistantOutput = $true
                $State.StreamedAssistantText = [string]$State.StreamedAssistantText + $delta
                script:Append-TermStream -Text $delta -Color "#4EC9B0" -TabId $State.TabId
            }
            return
        }
        'assistant.message' {
            $content = [string]$Event.data.content
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                $State.FinalAssistantText = $content
                if (-not $State.HadAssistantOutput) {
                    $State.HadAssistantOutput = $true
                    $State.StreamedAssistantText = $content
                    script:Append-TermStream -Text $content -Color "#4EC9B0" -TabId $State.TabId
                } elseif ($content.StartsWith([string]$State.StreamedAssistantText)) {
                    $streamedLen = ([string]$State.StreamedAssistantText).Length
                    if ($streamedLen -le $content.Length) {
                        $suffix = $content.Substring($streamedLen)
                    } else {
                        $suffix = ''
                    }
                    if ($suffix) {
                        $State.StreamedAssistantText = $content
                        script:Append-TermStream -Text $suffix -Color "#4EC9B0" -TabId $State.TabId
                    }
                }
            }
            return
        }
        'tool.execution_start' {
            $toolCallId = [string]$Event.data.toolCallId
            $toolName   = [string]$Event.data.toolName
            $summary    = script:Get-ToolExecutionSummary -EventData $Event.data

            # Shared reference so the completion handler can mutate the same block
            $termBlockRef = [hashtable]::Synchronized(@{ Block = $null })

            $State.ToolCalls[$toolCallId] = [pscustomobject]@{
                Name            = $toolName
                Summary         = $summary
                TerminalBlockRef = $termBlockRef
            }

            if ($toolName -ne 'report_intent') {
                $State.HadToolOutput = $true
                $capturedRef     = $termBlockRef
                $capturedSummary = $summary
                $capturedName    = $toolName
                $capturedTabId   = $State.TabId

                script:Invoke-OnUiThread -Async -Action {
                    $tab = script:Get-ClippyTab -TabId $capturedTabId
                    if (-not $tab -or -not $tab.Document) { return }

                    # Break any open streaming paragraph so the block sits cleanly
                    $tab.ActiveAssistantStream = $null
                    $tab.ActiveThoughtStream   = $null

                    $headerText = if (-not [string]::IsNullOrWhiteSpace($capturedSummary)) { $capturedSummary } else { $capturedName }
                    $newBlock = script:New-InlineTerminalBlock -HeaderLabel $headerText

                    # "Running…" placeholder line while the tool executes
                    script:Add-InlineTerminalBlockLine -Block $newBlock -Text 'Running...' -Color "#5B5F7F"

                    $uiContainer = [Windows.Documents.BlockUIContainer]::new($newBlock.Container)
                    $uiContainer.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
                    $tab.Document.Blocks.Add($uiContainer)

                    if ([string]$script:ActiveClippyTabId -eq [string]$capturedTabId -and $cOutput) {
                        $cOutput.ScrollToEnd()
                    }

                    $capturedRef.Block = $newBlock
                }
            }
            return
        }
        'tool.execution_complete' {
            $toolCallId = [string]$Event.data.toolCallId
            $callInfo   = $State.ToolCalls[$toolCallId]
            $toolName   = if ($callInfo) { [string]$callInfo.Name } else { 'tool' }
            $success    = [bool]$Event.data.success

            if ($toolName -eq 'report_intent') { return }

            $State.HadToolOutput = $true
            $resultText = script:Get-ToolResultText -Result $Event.data.result

            if ($callInfo -and $callInfo.TerminalBlockRef) {
                $capturedRef     = $callInfo.TerminalBlockRef
                $capturedText    = $resultText
                $capturedSuccess = $success
                $capturedName    = $toolName
                $capturedTabId   = $State.TabId

                script:Invoke-OnUiThread -Async -Action {
                    # Race guard: if the start-handler's Async dispatch hasn't fired yet, wait
                    # one more frame by re-queuing at a slightly lower priority.
                    $block = $capturedRef.Block
                    if (-not $block) {
                        $replayRef  = $capturedRef
                        $replayText = $capturedText
                        $replayOk   = $capturedSuccess
                        $replayName = $capturedName
                        $script:Chat.Dispatcher.BeginInvoke(
                            [Action]{
                                $b2 = $replayRef.Block
                                if (-not $b2) { return }
                                $b2.OutputPanel.Children.Clear()
                                if (-not [string]::IsNullOrWhiteSpace($replayText)) {
                                    $mc2 = 0
                                    foreach ($ln in ($replayText -split "`r?`n")) {
                                        if ($mc2 -ge 60) { script:Add-InlineTerminalBlockLine -Block $b2 -Text '... (truncated)' -Color "#5B5F7F"; break }
                                        script:Add-InlineTerminalBlockLine -Block $b2 -Text $ln -IsError:(-not $replayOk) -Color $(if($replayOk){"#8F8FAF"}else{"#F48771"})
                                        $mc2++
                                    }
                                } elseif (-not $replayOk) {
                                    script:Add-InlineTerminalBlockLine -Block $b2 -Text "[$replayName] failed." -IsError -Color "#F44747"
                                }
                                script:Finalize-InlineTerminalBlock -Block $b2 -Success:$replayOk
                            },
                            [Windows.Threading.DispatcherPriority]::ApplicationIdle
                        ) | Out-Null
                        return
                    }

                    # Replace the "Running..." placeholder with real output
                    $block.OutputPanel.Children.Clear()

                    if (-not [string]::IsNullOrWhiteSpace($capturedText)) {
                        $maxLines  = 60
                        $lineCount = 0
                        foreach ($line in ($capturedText -split "`r?`n")) {
                            if ($lineCount -ge $maxLines) {
                                script:Add-InlineTerminalBlockLine -Block $block -Text '... (truncated)' -Color "#5B5F7F"
                                break
                            }
                            $lineColor = if ($capturedSuccess) { "#8F8FAF" } else { "#F48771" }
                            script:Add-InlineTerminalBlockLine -Block $block -Text $line -IsError:(-not $capturedSuccess) -Color $lineColor
                            $lineCount++
                        }
                    } elseif (-not $capturedSuccess) {
                        script:Add-InlineTerminalBlockLine -Block $block -Text "[$capturedName] failed." -IsError -Color "#F44747"
                    }

                    script:Finalize-InlineTerminalBlock -Block $block -Success:$capturedSuccess
                }
            } else {
                # Fallback: flat text (no block reference – edge case)
                if (-not $success) {
                    script:Write-Term "[$toolName] failed." "#F44747" -TabId $State.TabId
                }
                if ($resultText) {
                    $color = if ($success) { "#8F8FAF" } else { "#F48771" }
                    foreach ($line in ($resultText -split "`r?`n")) {
                        script:Write-Term "  $line" $color -TabId $State.TabId
                    }
                }
            }
            return
        }
        'result' {
            if ($Event.PSObject.Properties.Name -contains 'exitCode') {
                $State.ExitCode = [int]$Event.exitCode
            }
            script:Complete-CopilotPromptStream -State $State
            return
        }
        'assistant.turn_end' {
            script:Complete-CopilotPromptStream -State $State
            return
        }
    }
}

function script:Handle-CopilotOutputLine {
    param(
        [Parameter(Mandatory)]
        [string]$Line,
        [Parameter(Mandatory)]
        [hashtable]$State,
        [switch]$IsError
    )

    $cleanLine = script:Normalize-CopilotOutputLine -Line $Line
    if ([string]::IsNullOrWhiteSpace($cleanLine)) { return }

    $jsonStart = $cleanLine.IndexOf('{')
    if ($jsonStart -ge 0) {
        $jsonLine = $cleanLine.Substring($jsonStart)
        try {
            $event = $jsonLine | ConvertFrom-Json -ErrorAction Stop
            script:Handle-CopilotEvent -Event $event -State $State
            return
        } catch {
        }
    }

    if (script:Should-SkipCopilotNoise -Line $cleanLine) {
        return
    }

    $State.HadToolOutput = $true
    $color = if ($IsError -or $cleanLine -match 'ERROR|Exception|FAIL') { "#F44747" } else { "#8F8FAF" }
    script:Write-Term $cleanLine $color -TabId $State.TabId
}

function script:Complete-CopilotPromptStream {
    param([hashtable]$State)

    if ($State.Completed) { return }
    $State.Completed = $true

    $targetTabId = [string]$State.TabId
    $tab = script:Get-ClippyTab -TabId $targetTabId
    $finalText = [string]$State.FinalAssistantText
    if (-not $State.HadAssistantOutput -and -not [string]::IsNullOrWhiteSpace($finalText)) {
        script:Append-TermStream -Text $finalText -Color "#4EC9B0" -TabId $targetTabId
        $State.HadAssistantOutput = $true
    }

    if ((-not $State.HadAssistantOutput) -and (-not $State.HadToolOutput)) {
        if ($null -ne $State.ExitCode -and [int]$State.ExitCode -ne 0) {
            script:Write-Term "ERROR: Copilot exited with code $($State.ExitCode) without returning a response." "#F44747" -TabId $targetTabId
        } else {
            script:Write-Term "No response returned from copilot." "#CCA700" -TabId $targetTabId
        }
    }

    script:Write-Term "" -TabId $targetTabId
    if ($tab) {
        $tab.ActiveAssistantStream = $null
        $tab.ActiveThoughtStream = $null
        $tab.StreamState.WaitingForResponse = $false
    }
    script:Set-CopilotBusyState $false
}

function script:Invoke-CopilotCliCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $copilot = script:Get-CopilotCommand
    if (-not $copilot) {
        throw "The 'copilot' command was not found in PATH."
    }

    $rawLines = @(
        & $copilot.Source @Arguments 2>&1 |
        ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $_.ToString()
            } else {
                [string]$_
            }
        }
    )

    return (($rawLines | ForEach-Object { $_.Replace([string][char]27, '') }) -join "`n").Trim()
}

function script:New-ToolbarMenuResources {
    [xml]$resourcesXaml = @'
<ResourceDictionary
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="MenuSurfaceBrush" Color="#FF111122"/>
  <SolidColorBrush x:Key="MenuBorderBrush" Color="#FF333355"/>
  <SolidColorBrush x:Key="MenuHoverBrush" Color="#FF1A1A35"/>
  <SolidColorBrush x:Key="MenuAccentBrush" Color="#FF5B5FC7"/>
  <SolidColorBrush x:Key="MenuAccentSoftBrush" Color="#FF1D2440"/>
  <SolidColorBrush x:Key="MenuTextBrush" Color="#FFE8E8E8"/>
  <SolidColorBrush x:Key="MenuMutedTextBrush" Color="#FF8F8FAF"/>
  <SolidColorBrush x:Key="MenuDisabledTextBrush" Color="#FF6B6B8D"/>

  <Style TargetType="{x:Type ContextMenu}">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="SnapsToDevicePixels" Value="True"/>
    <Setter Property="HasDropShadow" Value="False"/>
    <Setter Property="Foreground" Value="{StaticResource MenuTextBrush}"/>
    <Setter Property="Background" Value="{StaticResource MenuSurfaceBrush}"/>
    <Setter Property="BorderBrush" Value="{StaticResource MenuBorderBrush}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="6"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="{x:Type ContextMenu}">
          <Border
              Background="{TemplateBinding Background}"
              BorderBrush="{TemplateBinding BorderBrush}"
              BorderThickness="{TemplateBinding BorderThickness}"
              CornerRadius="12"
              Padding="{TemplateBinding Padding}">
            <Border.Effect>
              <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="4" Opacity="0.55"/>
            </Border.Effect>
            <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="520">
              <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
            </ScrollViewer>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="{x:Type Separator}">
    <Setter Property="Margin" Value="6,4"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="{x:Type Separator}">
          <Border Height="1" Background="#FF2A2A46"/>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="{x:Type MenuItem}">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="SnapsToDevicePixels" Value="True"/>
    <Setter Property="Foreground" Value="{StaticResource MenuTextBrush}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="FontFamily" Value="Segoe UI"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="MinHeight" Value="30"/>
    <Setter Property="MinWidth" Value="228"/>
    <Setter Property="Padding" Value="10,7"/>
    <Setter Property="Margin" Value="0,1"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="{x:Type MenuItem}">
          <Grid SnapsToDevicePixels="True" ClipToBounds="False">
            <Border
                x:Name="ItemBorder"
                Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}"
                CornerRadius="8"
                Padding="{TemplateBinding Padding}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="14"/>
                </Grid.ColumnDefinitions>

                <Border
                    x:Name="SelectionDot"
                    Grid.Column="0"
                    Width="8"
                    Height="8"
                    CornerRadius="4"
                    Background="Transparent"
                    BorderBrush="Transparent"
                    BorderThickness="1"
                    Opacity="0"
                    VerticalAlignment="Center"
                    HorizontalAlignment="Center"/>

                <ContentPresenter
                    Grid.Column="1"
                    ContentSource="Header"
                    RecognizesAccessKey="True"
                    VerticalAlignment="Center"/>

                <TextBlock
                    x:Name="GestureText"
                    Grid.Column="2"
                    Margin="14,0,0,0"
                    Foreground="{StaticResource MenuMutedTextBrush}"
                    Text="{TemplateBinding InputGestureText}"
                    VerticalAlignment="Center"/>

                <TextBlock
                    x:Name="ArrowText"
                    Grid.Column="3"
                    Margin="12,0,0,0"
                    Foreground="{StaticResource MenuMutedTextBrush}"
                    Text=">"
                    VerticalAlignment="Center"
                    Visibility="Collapsed"/>
              </Grid>
            </Border>

            <Popup
                x:Name="SubMenuPopup"
                Placement="Right"
                HorizontalOffset="8"
                VerticalOffset="-10"
                AllowsTransparency="True"
                Focusable="False"
                IsOpen="{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}"
                PopupAnimation="Fade">
              <Border
                  Background="{StaticResource MenuSurfaceBrush}"
                  BorderBrush="{StaticResource MenuBorderBrush}"
                  BorderThickness="1"
                  CornerRadius="12"
                  Padding="6">
                <Border.Effect>
                  <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="4" Opacity="0.55"/>
                </Border.Effect>
                <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="420">
                  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                </ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="InputGestureText" Value="">
              <Setter TargetName="GestureText" Property="Visibility" Value="Collapsed"/>
            </Trigger>
            <Trigger Property="HasItems" Value="True">
              <Setter TargetName="ArrowText" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsCheckable" Value="True">
              <Setter TargetName="SelectionDot" Property="Opacity" Value="0.45"/>
              <Setter TargetName="SelectionDot" Property="BorderBrush" Value="{StaticResource MenuBorderBrush}"/>
            </Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="SelectionDot" Property="Opacity" Value="1"/>
              <Setter TargetName="SelectionDot" Property="Background" Value="{StaticResource MenuAccentBrush}"/>
              <Setter TargetName="SelectionDot" Property="BorderBrush" Value="{StaticResource MenuAccentBrush}"/>
              <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource MenuAccentSoftBrush}"/>
              <Setter TargetName="ItemBorder" Property="BorderBrush" Value="{StaticResource MenuAccentBrush}"/>
            </Trigger>
            <Trigger Property="IsHighlighted" Value="True">
              <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource MenuHoverBrush}"/>
              <Setter TargetName="ItemBorder" Property="BorderBrush" Value="{StaticResource MenuAccentBrush}"/>
            </Trigger>
            <Trigger Property="IsSubmenuOpen" Value="True">
              <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource MenuHoverBrush}"/>
              <Setter TargetName="ItemBorder" Property="BorderBrush" Value="{StaticResource MenuAccentBrush}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Foreground" Value="{StaticResource MenuDisabledTextBrush}"/>
              <Setter TargetName="ItemBorder" Property="Opacity" Value="0.7"/>
              <Setter TargetName="GestureText" Property="Foreground" Value="{StaticResource MenuDisabledTextBrush}"/>
              <Setter TargetName="ArrowText" Property="Foreground" Value="{StaticResource MenuDisabledTextBrush}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@

    return [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($resourcesXaml))
}

function script:New-ToolbarContextMenu {
    $menu = [Windows.Controls.ContextMenu]::new()
    $menu.Resources = script:New-ToolbarMenuResources
    return $menu
}

function script:New-ToolbarMenuItem {
    param(
        [string]$Header,
        [string]$Tag,
        [string]$InputGestureText,
        [switch]$Checkable,
        [switch]$StayOpen
    )

    $item = [Windows.Controls.MenuItem]::new()
    $item.Header = $Header
    if ($Tag) { $item.Tag = $Tag }
    if (-not [string]::IsNullOrWhiteSpace($InputGestureText)) {
        $item.InputGestureText = $InputGestureText
    }
    if ($Checkable) {
        $item.IsCheckable = $true
        $item.StaysOpenOnClick = [bool]$StayOpen
    }
    return $item
}

function script:Open-ToolbarContextMenu {
    param($Button)

    if (-not $Button -or -not $Button.ContextMenu) { return }
    $Button.ContextMenu.PlacementTarget = $Button
    $Button.ContextMenu.Placement = 'Bottom'
    $Button.ContextMenu.IsOpen = $true
}

function script:Initialize-ToolbarDropdowns {
    $script:ToolDropdownItems = @{}
    $script:ExtensionDropdownItems = @{}

    $toolMenu = script:New-ToolbarContextMenu
    $toolSettings = script:New-ToolbarMenuItem -Header 'Tool settings...'
    $toolSettings.Add_Click({ script:Show-ToolsSettingsDialog })
    $toolMenu.Items.Add($toolSettings) | Out-Null
    $toolMenu.Items.Add([Windows.Controls.Separator]::new()) | Out-Null

    $toolEntries = [ordered]@{
        AllowAllTools = 'Allow all tools'
        AllowAllPaths = 'Allow all paths'
        AllowAllUrls = 'Allow all urls'
        Experimental = 'Experimental'
        Autopilot = 'Autopilot'
        EnableAllGitHubMcpTools = 'All GitHub MCP tools'
    }
    foreach ($entry in $toolEntries.GetEnumerator()) {
        $item = script:New-ToolbarMenuItem -Header $entry.Value -Tag $entry.Key -Checkable -StayOpen
        $item.Add_Click({
            $script:WidgetSettings.Tools[[string]$this.Tag] = [bool]$this.IsChecked
            script:Save-WidgetSettings
            script:Sync-WidgetUi
        })
        $script:ToolDropdownItems[$entry.Key] = $item
        $toolMenu.Items.Add($item) | Out-Null
    }
    $toolMenu.Items.Add([Windows.Controls.Separator]::new()) | Out-Null
    $mcpInventory = script:New-ToolbarMenuItem -Header 'MCP server inventory'
    $mcpInventory.IsEnabled = $false
    $toolMenu.Items.Add($mcpInventory) | Out-Null
    foreach ($source in $script:ToolSourceSnapshot.Values) {
        $sourceItem = script:New-ToolbarMenuItem -Header ('{0} ({1})' -f $source.Name, $source.Servers.Count)
        if ($source.Servers.Count -eq 0) {
            $empty = script:New-ToolbarMenuItem -Header 'No MCP servers found'
            $empty.IsEnabled = $false
            $sourceItem.Items.Add($empty) | Out-Null
        } else {
            foreach ($server in $source.Servers) {
                $definedIn = if ($server.DefinedIn.Count -gt 0) { ' [' + ($server.DefinedIn -join ', ') + ']' } else { '' }
                $header = if ([string]::IsNullOrWhiteSpace($server.Detail)) {
                    '{0} [{1}]{2}' -f $server.Name, $server.Transport, $definedIn
                } else {
                    '{0} [{1}] - {2}{3}' -f $server.Name, $server.Transport, $server.Detail, $definedIn
                }
                $serverItem = script:New-ToolbarMenuItem -Header $header
                $serverItem.IsEnabled = $false
                $sourceItem.Items.Add($serverItem) | Out-Null
            }
        }
        $toolMenu.Items.Add($sourceItem) | Out-Null
    }
    $cTools.ContextMenu = $toolMenu

    $extMenu = script:New-ToolbarContextMenu
    $extSettings = script:New-ToolbarMenuItem -Header 'Extension settings...'
    $extSettings.Add_Click({ script:Show-ExtensionSettingsDialog })
    $extMenu.Items.Add($extSettings) | Out-Null
    $extMenu.Items.Add([Windows.Controls.Separator]::new()) | Out-Null

    $extensionEntries = [ordered]@{
        IncludeRegularSettings = 'VS Code settings'
        IncludeRegularExtensions = 'VS Code extensions'
        IncludeInsidersSettings = 'Insiders settings'
        IncludeInsidersExtensions = 'Insiders extensions'
    }
    foreach ($entry in $extensionEntries.GetEnumerator()) {
        $item = script:New-ToolbarMenuItem -Header $entry.Value -Tag $entry.Key -Checkable -StayOpen
        $item.Add_Click({
            $script:WidgetSettings.Extensions[[string]$this.Tag] = [bool]$this.IsChecked
            script:Save-WidgetSettings
            script:Sync-WidgetUi
        })
        $script:ExtensionDropdownItems[$entry.Key] = $item
        $extMenu.Items.Add($item) | Out-Null
    }
    $cExt.ContextMenu = $extMenu
}

function script:Update-ToolbarControls {
    if (-not $script:WidgetSettings) { return }

    script:Update-ModeCycleTile

    foreach ($name in $script:ToolDropdownItems.Keys) {
        $script:ToolDropdownItems[$name].IsChecked = [bool]$script:WidgetSettings.Tools[$name]
    }

    foreach ($name in $script:ExtensionDropdownItems.Keys) {
        $script:ExtensionDropdownItems[$name].IsChecked = [bool]$script:WidgetSettings.Extensions[$name]
    }

    $enabledTools = @(
        foreach ($name in $script:WidgetSettings.Tools.Keys) {
            if ($script:WidgetSettings.Tools[$name]) { $name }
        }
    )
    $enabledExtensions = @(
        foreach ($name in $script:WidgetSettings.Extensions.Keys) {
            if ($script:WidgetSettings.Extensions[$name]) { $name }
        }
    )

    $toolSummary = if ($enabledTools.Count -gt 0) { $enabledTools -join ', ' } else { 'none' }
    $extensionSummary = if ($enabledExtensions.Count -gt 0) { $enabledExtensions -join ', ' } else { 'none' }

    $cTools.ToolTip = "Quick tool options. Enabled: $toolSummary`n$(script:Get-McpSourceSummary)"
    $cExt.ToolTip = "Quick extension options. Enabled: $extensionSummary"
    if ($cAgent) {
        $cAgent.ToolTip = "Selected agent: $(script:Get-ActiveAgentDisplayName)"
    }
    $cModel.ToolTip = "Current model: $(script:Get-SelectedModelDisplayName)"
}

function script:Show-ToolsSettingsDialog {
    script:Refresh-VsCodeContext
    script:Refresh-ToolSourceContext

    [xml]$TX = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Tools Settings"
    Width="960"
    Height="620"
    WindowStartupLocation="CenterOwner"
    Background="Transparent"
    AllowsTransparency="True"
    WindowStyle="None"
    ResizeMode="NoResize">
  <Window.Resources>
    <Style x:Key="PopupButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="PopupButtonBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF1A1A35"/>
                <Setter TargetName="PopupButtonBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF24244A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PopupCheckBoxStyle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>
    <Style x:Key="SourceListStyle" TargetType="ListBox">
      <Setter Property="Background" Value="#FF0E0E1E"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="SourceJsonTextStyle" TargetType="TextBox">
      <Setter Property="Background" Value="#FF0E0E1E"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Cascadia Code, Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="10"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
      <Setter Property="AcceptsReturn" Value="True"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
    </Style>
  </Window.Resources>
  <Border Background="#FF0C0C0C" BorderBrush="#FF333355" BorderThickness="1.5" CornerRadius="14">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border x:Name="HeaderBar" Grid.Row="0" Background="#FF151528" CornerRadius="14,14,0,0" Padding="18,14">
        <DockPanel LastChildFill="True">
          <Button x:Name="CloseBtn" DockPanel.Dock="Right" Content="X" Width="34" Style="{StaticResource PopupButtonStyle}" Margin="12,0,0,0"/>
          <StackPanel>
            <TextBlock Text="Prompt runtime tools and MCP inventory" FontSize="17" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
            <TextBlock Text="Flags on the left affect prompt-backed tabs in the Clippy bench. MCP servers on the right are read-only inventory from .copilot, VS Code, VS Code Insiders, and Claude Code." Foreground="#FF8F8FAF" Margin="0,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>
      <Grid Grid.Row="1" Margin="18,16,18,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="290"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#FF111122" BorderBrush="#FF333355" BorderThickness="1" CornerRadius="12" Padding="16">
          <StackPanel>
            <TextBlock Text="Prompt runtime CLI flags" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
            <TextBlock Text="These map directly to the legacy prompt runtime CLI flags used by prompt-backed tabs." Foreground="#FF8F8FAF" Margin="0,6,0,16" TextWrapping="Wrap"/>
            <CheckBox x:Name="AllowAllTools" Style="{StaticResource PopupCheckBoxStyle}" Content="Allow all tools for prompt mode"/>
            <CheckBox x:Name="AllowAllPaths" Style="{StaticResource PopupCheckBoxStyle}" Content="Allow all file paths"/>
            <CheckBox x:Name="AllowAllUrls" Style="{StaticResource PopupCheckBoxStyle}" Content="Allow all URLs"/>
            <CheckBox x:Name="Experimental" Style="{StaticResource PopupCheckBoxStyle}" Content="Enable experimental features"/>
            <CheckBox x:Name="Autopilot" Style="{StaticResource PopupCheckBoxStyle}" Content="Enable autopilot continuation"/>
            <CheckBox x:Name="EnableAllGitHubMcpTools" Style="{StaticResource PopupCheckBoxStyle}" Content="Enable all GitHub MCP tools"/>
          </StackPanel>
        </Border>
        <Grid Grid.Column="2">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Detected MCP servers" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8" Margin="0,0,0,10"/>
          <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#FF111122" BorderBrush="#FF333355" BorderThickness="1" CornerRadius="12" Padding="14">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel Grid.Row="0">
                  <TextBlock Text=".copilot" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                  <TextBlock x:Name="CopilotCountText" DockPanel.Dock="Right" Foreground="#FF8F8FAF"/>
                </DockPanel>
                <TextBlock x:Name="CopilotPathText" Grid.Row="1" Margin="0,8,0,10" Foreground="#FF8F8FAF" TextWrapping="Wrap"/>
                <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="CopilotViewToggleBtn" Content="View: List" Width="84" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="CopilotCopyTileBtn" Content="Copy tile" Width="82" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="CopilotCopySchemaBtn" Content="Copy schema" Width="96" Style="{StaticResource PopupButtonStyle}"/>
                </StackPanel>
                <Grid Grid.Row="3">
                  <ListBox x:Name="CopilotServerList" Style="{StaticResource SourceListStyle}"/>
                  <TextBox x:Name="CopilotJsonText" Style="{StaticResource SourceJsonTextStyle}" Visibility="Collapsed"/>
                </Grid>
              </Grid>
            </Border>
            <Border Grid.Column="2" Background="#FF111122" BorderBrush="#FF333355" BorderThickness="1" CornerRadius="12" Padding="14">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel Grid.Row="0">
                  <TextBlock Text="VS Code" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                  <TextBlock x:Name="RegularCountText" DockPanel.Dock="Right" Foreground="#FF8F8FAF"/>
                </DockPanel>
                <TextBlock x:Name="RegularPathText" Grid.Row="1" Margin="0,8,0,10" Foreground="#FF8F8FAF" TextWrapping="Wrap"/>
                <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="RegularViewToggleBtn" Content="View: List" Width="84" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="RegularCopyTileBtn" Content="Copy tile" Width="82" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="RegularCopySchemaBtn" Content="Copy schema" Width="96" Style="{StaticResource PopupButtonStyle}"/>
                </StackPanel>
                <Grid Grid.Row="3">
                  <ListBox x:Name="RegularServerList" Style="{StaticResource SourceListStyle}"/>
                  <TextBox x:Name="RegularJsonText" Style="{StaticResource SourceJsonTextStyle}" Visibility="Collapsed"/>
                </Grid>
              </Grid>
            </Border>
          </Grid>
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#FF111122" BorderBrush="#FF333355" BorderThickness="1" CornerRadius="12" Padding="14">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel Grid.Row="0">
                  <TextBlock Text="VS Code Insiders" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                  <TextBlock x:Name="InsidersCountText" DockPanel.Dock="Right" Foreground="#FF8F8FAF"/>
                </DockPanel>
                <TextBlock x:Name="InsidersPathText" Grid.Row="1" Margin="0,8,0,10" Foreground="#FF8F8FAF" TextWrapping="Wrap"/>
                <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="InsidersViewToggleBtn" Content="View: List" Width="84" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="InsidersCopyTileBtn" Content="Copy tile" Width="82" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="InsidersCopySchemaBtn" Content="Copy schema" Width="96" Style="{StaticResource PopupButtonStyle}"/>
                </StackPanel>
                <Grid Grid.Row="3">
                  <ListBox x:Name="InsidersServerList" Style="{StaticResource SourceListStyle}"/>
                  <TextBox x:Name="InsidersJsonText" Style="{StaticResource SourceJsonTextStyle}" Visibility="Collapsed"/>
                </Grid>
              </Grid>
            </Border>
            <Border Grid.Column="2" Background="#FF111122" BorderBrush="#FF333355" BorderThickness="1" CornerRadius="12" Padding="14">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel Grid.Row="0">
                  <TextBlock Text="Claude Code" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                  <TextBlock x:Name="ClaudeCountText" DockPanel.Dock="Right" Foreground="#FF8F8FAF"/>
                </DockPanel>
                <TextBlock x:Name="ClaudePathText" Grid.Row="1" Margin="0,8,0,10" Foreground="#FF8F8FAF" TextWrapping="Wrap"/>
                <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="ClaudeViewToggleBtn" Content="View: List" Width="84" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="ClaudeCopyTileBtn" Content="Copy tile" Width="82" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
                  <Button x:Name="ClaudeCopySchemaBtn" Content="Copy schema" Width="96" Style="{StaticResource PopupButtonStyle}"/>
                </StackPanel>
                <Grid Grid.Row="3">
                  <ListBox x:Name="ClaudeServerList" Style="{StaticResource SourceListStyle}"/>
                  <TextBox x:Name="ClaudeJsonText" Style="{StaticResource SourceJsonTextStyle}" Visibility="Collapsed"/>
                </Grid>
              </Grid>
            </Border>
          </Grid>
        </Grid>
      </Grid>
      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="18,6,18,18">
        <Button x:Name="RefreshBtn" Content="Refresh inventory" Width="128" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
        <Button x:Name="CancelBtn" Content="Cancel" Width="88" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
        <Button x:Name="SaveBtn" Content="Save" Width="88" Style="{StaticResource PopupButtonStyle}" Background="#FF5B5FC7" BorderBrush="#FF5B5FC7"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($TX))
    script:Set-DialogOwner -Window $win

    $checkNames = @(
        'AllowAllTools',
        'AllowAllPaths',
        'AllowAllUrls',
        'Experimental',
        'Autopilot',
        'EnableAllGitHubMcpTools'
    )

    $checks = @{}
    foreach ($name in $checkNames) {
        $box = $win.FindName($name)
        $box.IsChecked = [bool]$script:WidgetSettings.Tools[$name]
        $checks[$name] = $box
    }

    $header = $win.FindName('HeaderBar')
    $close = $win.FindName('CloseBtn')
    $refresh = $win.FindName('RefreshBtn')
    $save = $win.FindName('SaveBtn')
    $cancel = $win.FindName('CancelBtn')

    $sourceBindings = @(
        @{ Key = 'Copilot'; Path = 'CopilotPathText'; Count = 'CopilotCountText'; List = 'CopilotServerList'; Json = 'CopilotJsonText'; Toggle = 'CopilotViewToggleBtn'; CopyTile = 'CopilotCopyTileBtn'; CopySchema = 'CopilotCopySchemaBtn' }
        @{ Key = 'Regular'; Path = 'RegularPathText'; Count = 'RegularCountText'; List = 'RegularServerList'; Json = 'RegularJsonText'; Toggle = 'RegularViewToggleBtn'; CopyTile = 'RegularCopyTileBtn'; CopySchema = 'RegularCopySchemaBtn' }
        @{ Key = 'Insiders'; Path = 'InsidersPathText'; Count = 'InsidersCountText'; List = 'InsidersServerList'; Json = 'InsidersJsonText'; Toggle = 'InsidersViewToggleBtn'; CopyTile = 'InsidersCopyTileBtn'; CopySchema = 'InsidersCopySchemaBtn' }
        @{ Key = 'Claude'; Path = 'ClaudePathText'; Count = 'ClaudeCountText'; List = 'ClaudeServerList'; Json = 'ClaudeJsonText'; Toggle = 'ClaudeViewToggleBtn'; CopyTile = 'ClaudeCopyTileBtn'; CopySchema = 'ClaudeCopySchemaBtn' }
    )

    $setCardViewMode = {
        param($binding, [string]$mode)

        $listBox = $win.FindName($binding.List)
        $jsonBox = $win.FindName($binding.Json)
        $toggleButton = $win.FindName($binding.Toggle)
        $isJson = $mode -eq 'JSON'

        $toggleButton.Tag = if ($isJson) { 'JSON' } else { 'List' }
        $toggleButton.Content = if ($isJson) { 'View: JSON' } else { 'View: List' }
        $listBox.Visibility = if ($isJson) { 'Collapsed' } else { 'Visible' }
        $jsonBox.Visibility = if ($isJson) { 'Visible' } else { 'Collapsed' }
    }

    $populateSources = {
        script:Refresh-VsCodeContext
        script:Refresh-ToolSourceContext
        script:Initialize-ToolbarDropdowns
        script:Update-ToolbarControls
        script:Update-WidgetStatus

        foreach ($binding in $sourceBindings) {
            $source = $script:ToolSourceSnapshot[$binding.Key]
            $pathBlock = $win.FindName($binding.Path)
            $countBlock = $win.FindName($binding.Count)
            $listBox = $win.FindName($binding.List)
            $jsonBox = $win.FindName($binding.Json)
            $toggleButton = $win.FindName($binding.Toggle)

            $countBlock.Text = if ($source.Servers.Count -eq 1) { '1 server' } else { "$($source.Servers.Count) servers" }
            if ($source.Paths.Count -gt 0) {
                $pathBlock.Text = 'Sources: ' + ($source.Paths -join '; ')
            } else {
                $pathBlock.Text = 'Checked: ' + ($source.CandidatePaths -join '; ')
            }

            $listBox.Items.Clear()
            if ($source.Servers.Count -eq 0) {
                [void]$listBox.Items.Add('No MCP servers found')
            } else {
                foreach ($server in $source.Servers) {
                    $definedIn = if ($server.DefinedIn.Count -gt 0) { ' | ' + ($server.DefinedIn -join ', ') } else { '' }
                    if ([string]::IsNullOrWhiteSpace($server.Detail)) {
                        [void]$listBox.Items.Add(('{0} [{1}]{2}' -f $server.Name, $server.Transport, $definedIn))
                    } else {
                        [void]$listBox.Items.Add(('{0} [{1}] - {2}{3}' -f $server.Name, $server.Transport, $server.Detail, $definedIn))
                    }
                }
            }

            $jsonBox.Text = $source.SchemaJson
            $currentMode = [string]$toggleButton.Tag
            if ([string]::IsNullOrWhiteSpace($currentMode)) {
                $currentMode = 'List'
            }
            & $setCardViewMode $binding $currentMode
        }
    }

    $header.Add_MouseLeftButtonDown({ $win.DragMove() })
    $close.Add_Click({ $win.DialogResult = $false; $win.Close() })
    $refresh.Add_Click({ & $populateSources })

    foreach ($binding in $sourceBindings) {
        $bindingData = $binding
        $toggleButton = $win.FindName($binding.Toggle)
        $copyTileButton = $win.FindName($binding.CopyTile)
        $copySchemaButton = $win.FindName($binding.CopySchema)

        $toggleButton.Add_Click({
            $nextMode = if ([string]$this.Tag -eq 'JSON') { 'List' } else { 'JSON' }
            & $setCardViewMode $bindingData $nextMode
        }.GetNewClosure())

        $copyTileButton.Add_Click({
            $source = $script:ToolSourceSnapshot[$bindingData.Key]
            script:Copy-WidgetTextToClipboard -Text $source.TileJson -Label "$($source.Name) tile"
        }.GetNewClosure())

        $copySchemaButton.Add_Click({
            $source = $script:ToolSourceSnapshot[$bindingData.Key]
            script:Copy-WidgetTextToClipboard -Text $source.SchemaJson -Label "$($source.Name) schema"
        }.GetNewClosure())
    }

    $cancel.Add_Click({ $win.DialogResult = $false; $win.Close() })
    $save.Add_Click({
        foreach ($name in $checkNames) {
            $script:WidgetSettings.Tools[$name] = [bool]$checks[$name].IsChecked
        }
        script:Save-WidgetSettings
        script:Sync-WidgetUi
        $win.DialogResult = $true
        $win.Close()
    })

    & $populateSources
    [void]$win.ShowDialog()
}

function script:Show-ExtensionSettingsDialog {
    script:Refresh-VsCodeContext

    [xml]$EX = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Extension Settings"
    Width="860"
    Height="620"
    WindowStartupLocation="CenterOwner"
    Background="Transparent"
    AllowsTransparency="True"
    WindowStyle="None"
    ResizeMode="NoResize">
  <Window.Resources>
    <Style x:Key="PopupButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="PopupButtonBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF1A1A35"/>
                <Setter TargetName="PopupButtonBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF24244A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PopupCheckBoxStyle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>
    <Style x:Key="SectionCardStyle" TargetType="Border">
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16"/>
    </Style>
    <Style x:Key="DetailTextStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF8F8FAF"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="SourceListItemStyle" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Margin" Value="4,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="ListItemBorder" Background="Transparent" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ListItemBorder" Property="Background" Value="#FF1A1A35"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ListItemBorder" Property="Background" Value="#FF1D2440"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SourceListStyle" TargetType="ListBox">
      <Setter Property="Background" Value="#FF0E0E1E"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="4"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource SourceListItemStyle}"/>
    </Style>
    <Style x:Key="PopupTabItemStyle" TargetType="TabItem">
      <Setter Property="Foreground" Value="#FFB7B7D6"/>
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="10,10,0,0"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#FF1A1A35"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Foreground" Value="#FFFFFFFF"/>
                <Setter TargetName="TabBorder" Property="Background" Value="#FF1D2440"/>
                <Setter TargetName="TabBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#FF0C0C0C" BorderBrush="#FF333355" BorderThickness="1.5" CornerRadius="14">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border x:Name="HeaderBar" Grid.Row="0" Background="#FF151528" CornerRadius="14,14,0,0" Padding="18,14">
        <DockPanel LastChildFill="True">
          <Button x:Name="CloseBtn" DockPanel.Dock="Right" Content="X" Width="34" Style="{StaticResource PopupButtonStyle}" Margin="12,0,0,0"/>
          <StackPanel>
            <TextBlock Text="VS Code extension settings" FontSize="17" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
            <TextBlock Text="Choose which regular and Insiders profile details Clippy carries into chat context, then inspect the detected extension inventory below." Foreground="#FF8F8FAF" Margin="0,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>
      <TabControl Grid.Row="1" Background="Transparent" BorderThickness="0" Margin="18,16,18,10">
        <TabItem Header="VS Code" Style="{StaticResource PopupTabItemStyle}">
          <Grid Margin="0,12,0,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Style="{StaticResource SectionCardStyle}">
              <StackPanel>
                <TextBlock Text="Included in chat context" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                <TextBlock Text="Control how much of the regular VS Code profile becomes prompt context for the current widget session." Foreground="#FF8F8FAF" Margin="0,6,0,16" TextWrapping="Wrap"/>
                <CheckBox x:Name="IncludeRegularSettings" Style="{StaticResource PopupCheckBoxStyle}" Content="Include VS Code user settings keys in chat context"/>
                <CheckBox x:Name="IncludeRegularExtensions" Style="{StaticResource PopupCheckBoxStyle}" Content="Include installed VS Code extensions in chat context"/>
              </StackPanel>
            </Border>
            <Border Grid.Row="1" Style="{StaticResource SectionCardStyle}" Margin="0,10,0,10">
              <StackPanel>
                <TextBlock Text="Detected profile paths" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                <TextBlock Text="Clippy reads from the live profile paths shown here when context capture is enabled." Foreground="#FF8F8FAF" Margin="0,6,0,14" TextWrapping="Wrap"/>
                <TextBlock x:Name="RegularSettingsPath" Style="{StaticResource DetailTextStyle}"/>
                <TextBlock x:Name="RegularExtensionsPath" Style="{StaticResource DetailTextStyle}" Margin="0,2,0,0"/>
              </StackPanel>
            </Border>
            <Border Grid.Row="2" Style="{StaticResource SectionCardStyle}">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel Grid.Row="0" Margin="0,0,0,12">
                  <TextBlock Text="Installed extensions" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                  <TextBlock x:Name="RegularExtensionCountText" DockPanel.Dock="Right" Foreground="#FF8F8FAF"/>
                </DockPanel>
                <ListBox x:Name="RegularExtensionsList" Grid.Row="1" Style="{StaticResource SourceListStyle}"/>
              </Grid>
            </Border>
          </Grid>
        </TabItem>
        <TabItem Header="VS Code Insiders" Style="{StaticResource PopupTabItemStyle}">
          <Grid Margin="0,12,0,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Style="{StaticResource SectionCardStyle}">
              <StackPanel>
                <TextBlock Text="Included in chat context" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                <TextBlock Text="Control how much of the VS Code Insiders profile is available to the widget when gathering editor context." Foreground="#FF8F8FAF" Margin="0,6,0,16" TextWrapping="Wrap"/>
                <CheckBox x:Name="IncludeInsidersSettings" Style="{StaticResource PopupCheckBoxStyle}" Content="Include VS Code Insiders user settings keys in chat context"/>
                <CheckBox x:Name="IncludeInsidersExtensions" Style="{StaticResource PopupCheckBoxStyle}" Content="Include installed VS Code Insiders extensions in chat context"/>
              </StackPanel>
            </Border>
            <Border Grid.Row="1" Style="{StaticResource SectionCardStyle}" Margin="0,10,0,10">
              <StackPanel>
                <TextBlock Text="Detected profile paths" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                <TextBlock Text="Clippy reads the live Insiders profile from the paths shown here whenever these toggles are enabled." Foreground="#FF8F8FAF" Margin="0,6,0,14" TextWrapping="Wrap"/>
                <TextBlock x:Name="InsidersSettingsPath" Style="{StaticResource DetailTextStyle}"/>
                <TextBlock x:Name="InsidersExtensionsPath" Style="{StaticResource DetailTextStyle}" Margin="0,2,0,0"/>
              </StackPanel>
            </Border>
            <Border Grid.Row="2" Style="{StaticResource SectionCardStyle}">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel Grid.Row="0" Margin="0,0,0,12">
                  <TextBlock Text="Installed extensions" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                  <TextBlock x:Name="InsidersExtensionCountText" DockPanel.Dock="Right" Foreground="#FF8F8FAF"/>
                </DockPanel>
                <ListBox x:Name="InsidersExtensionsList" Grid.Row="1" Style="{StaticResource SourceListStyle}"/>
              </Grid>
            </Border>
          </Grid>
        </TabItem>
      </TabControl>
      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="18,6,18,18">
        <Button x:Name="RefreshBtn" Content="Refresh" Width="96" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
        <Button x:Name="CancelBtn" Content="Cancel" Width="88" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
        <Button x:Name="SaveBtn" Content="Save" Width="88" Style="{StaticResource PopupButtonStyle}" Background="#FF5B5FC7" BorderBrush="#FF5B5FC7"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($EX))
    script:Set-DialogOwner -Window $win

    $header = $win.FindName('HeaderBar')
    $close = $win.FindName('CloseBtn')
    $regularSettings = $win.FindName('IncludeRegularSettings')
    $regularExtensions = $win.FindName('IncludeRegularExtensions')
    $insidersSettings = $win.FindName('IncludeInsidersSettings')
    $insidersExtensions = $win.FindName('IncludeInsidersExtensions')
    $regularSettingsPath = $win.FindName('RegularSettingsPath')
    $regularExtensionsPath = $win.FindName('RegularExtensionsPath')
    $insidersSettingsPath = $win.FindName('InsidersSettingsPath')
    $insidersExtensionsPath = $win.FindName('InsidersExtensionsPath')
    $regularCount = $win.FindName('RegularExtensionCountText')
    $insidersCount = $win.FindName('InsidersExtensionCountText')
    $regularList = $win.FindName('RegularExtensionsList')
    $insidersList = $win.FindName('InsidersExtensionsList')
    $refresh = $win.FindName('RefreshBtn')
    $cancel = $win.FindName('CancelBtn')
    $save = $win.FindName('SaveBtn')

    $regularSettings.IsChecked = [bool]$script:WidgetSettings.Extensions.IncludeRegularSettings
    $regularExtensions.IsChecked = [bool]$script:WidgetSettings.Extensions.IncludeRegularExtensions
    $insidersSettings.IsChecked = [bool]$script:WidgetSettings.Extensions.IncludeInsidersSettings
    $insidersExtensions.IsChecked = [bool]$script:WidgetSettings.Extensions.IncludeInsidersExtensions

    $populate = {
        script:Refresh-VsCodeContext

        $regular = $script:VsCodeSnapshot.Regular
        $regularSettingsPath.Text = "Settings: $($regular.SettingsPath)"
        $regularExtensionsPath.Text = "Extensions: $($regular.ExtensionsDir)"
        $regularCount.Text = if ($regular.Extensions.Count -eq 1) { '1 extension' } else { "$($regular.Extensions.Count) extensions" }
        $regularList.Items.Clear()
        foreach ($item in $regular.Extensions) {
            [void]$regularList.Items.Add($item)
        }
        if ($regular.Extensions.Count -eq 0) {
            [void]$regularList.Items.Add('No extensions found')
        }

        $insiders = $script:VsCodeSnapshot.Insiders
        $insidersSettingsPath.Text = "Settings: $($insiders.SettingsPath)"
        $insidersExtensionsPath.Text = "Extensions: $($insiders.ExtensionsDir)"
        $insidersCount.Text = if ($insiders.Extensions.Count -eq 1) { '1 extension' } else { "$($insiders.Extensions.Count) extensions" }
        $insidersList.Items.Clear()
        foreach ($item in $insiders.Extensions) {
            [void]$insidersList.Items.Add($item)
        }
        if ($insiders.Extensions.Count -eq 0) {
            [void]$insidersList.Items.Add('No extensions found')
        }
    }

    & $populate

    $header.Add_MouseLeftButtonDown({ $win.DragMove() })
    $close.Add_Click({ $win.DialogResult = $false; $win.Close() })
    $refresh.Add_Click({ & $populate })
    $cancel.Add_Click({ $win.DialogResult = $false; $win.Close() })
    $save.Add_Click({
        $script:WidgetSettings.Extensions.IncludeRegularSettings = [bool]$regularSettings.IsChecked
        $script:WidgetSettings.Extensions.IncludeRegularExtensions = [bool]$regularExtensions.IsChecked
        $script:WidgetSettings.Extensions.IncludeInsidersSettings = [bool]$insidersSettings.IsChecked
        $script:WidgetSettings.Extensions.IncludeInsidersExtensions = [bool]$insidersExtensions.IsChecked
        script:Save-WidgetSettings
        script:Sync-WidgetUi
        $win.DialogResult = $true
        $win.Close()
    })

    [void]$win.ShowDialog()
}

function script:Show-AboutDialog {
    script:Refresh-VsCodeContext
    script:Refresh-ToolSourceContext

    $widgetVersion = script:Get-WidgetPackageVersion
    if ([string]::IsNullOrWhiteSpace($widgetVersion)) {
        $widgetVersion = 'local build'
    } else {
        $widgetVersion = "v$widgetVersion"
    }

    $currentMode = script:Get-ActiveTabMode
    if ([string]::IsNullOrWhiteSpace($currentMode)) {
        $currentMode = if ($script:WidgetSettings) { [string]$script:WidgetSettings.Mode } else { 'Agent' }
    }
    $currentAgent = script:Get-ActiveAgentDisplayName
    $currentModel = script:Get-SelectedModelDisplayName
    $openTabs = @($script:ClippyTabOrder).Count
    $pickedFiles = @($script:AttachedFiles).Count
    $toolCount = if ($script:WidgetSettings) { script:Get-EnabledSettingCount -SettingsTable $script:WidgetSettings.Tools } else { 0 }
    $extensionCount = if ($script:WidgetSettings) { script:Get-EnabledSettingCount -SettingsTable $script:WidgetSettings.Extensions } else { 0 }
    $regularExtensionCount = if ($script:VsCodeSnapshot -and $script:VsCodeSnapshot.Regular) { @($script:VsCodeSnapshot.Regular.Extensions).Count } else { 0 }
    $insidersExtensionCount = if ($script:VsCodeSnapshot -and $script:VsCodeSnapshot.Insiders) { @($script:VsCodeSnapshot.Insiders.Extensions).Count } else { 0 }
    $totalMcpServers = 0
    foreach ($source in $script:ToolSourceSnapshot.Values) {
        $totalMcpServers += $source.Servers.Count
    }

    [xml]$AX = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="About Clippy"
    Width="940"
    Height="620"
    WindowStartupLocation="CenterOwner"
    Background="Transparent"
    AllowsTransparency="True"
    WindowStyle="None"
    ResizeMode="NoResize">
  <Window.Resources>
    <Style x:Key="PopupButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="PopupButtonBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF1A1A35"/>
                <Setter TargetName="PopupButtonBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF24244A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SectionCardStyle" TargetType="Border">
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16"/>
    </Style>
    <Style x:Key="TileLabelStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFB7B7D6"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>
    <Style x:Key="TileValueStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFFFFFFF"/>
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="DetailStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF8F8FAF"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
  </Window.Resources>
  <Border Background="#FF0C0C0C" BorderBrush="#FF333355" BorderThickness="1.5" CornerRadius="14">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border x:Name="HeaderBar" Grid.Row="0" Background="#FF151528" CornerRadius="14,14,0,0" Padding="18,14">
        <DockPanel LastChildFill="True">
          <Button x:Name="CloseBtn" DockPanel.Dock="Right" Content="X" Width="34" Style="{StaticResource PopupButtonStyle}" Margin="12,0,0,0"/>
          <StackPanel>
            <TextBlock Text="Windows Clippy MCP Widget" FontSize="18" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
            <TextBlock Text="A richer status card for the floating Copilot desktop assistant, using the same elevated shell language as the rest of the widget." Foreground="#FF8F8FAF" Margin="0,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid Grid.Row="1" Margin="18,16,18,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="320"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0">
          <Border Style="{StaticResource SectionCardStyle}" Margin="0,0,0,10">
            <StackPanel>
              <Image x:Name="HeroImage" Height="180" Stretch="Uniform" Margin="0,0,0,12"/>
              <TextBlock Text="About this widget" FontSize="17" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
              <TextBlock x:Name="VersionText" Foreground="#FFB7B7D6" Margin="0,6,0,10"/>
              <TextBlock Text="Clippy keeps a floating desktop session nearby so you can switch modes, launch prompts, inspect tools, and layer local Windows actions into the same workspace." Style="{StaticResource DetailStyle}"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource SectionCardStyle}">
            <StackPanel>
              <TextBlock Text="Quick actions" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
              <TextBlock Text="Jump directly into the surfaces that shape the current widget session." Foreground="#FF8F8FAF" Margin="0,6,0,12" TextWrapping="Wrap"/>
              <WrapPanel>
                <Button x:Name="RepoBtn" Content="Open repo" Width="96" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
                <Button x:Name="ConfigBtn" Content="Config folder" Width="108" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
                <Button x:Name="ToolsBtn" Content="Tools settings" Width="110" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
                <Button x:Name="ExtensionsBtn" Content="Extensions" Width="96" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
              </WrapPanel>
            </StackPanel>
          </Border>
        </StackPanel>

        <Grid Grid.Column="2">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <UniformGrid Grid.Row="0" Columns="2" Rows="2" Margin="0,0,0,10">
            <Border x:Name="ModeTile" Background="#FF1D2440" BorderBrush="#FF5B5FC7" BorderThickness="1" CornerRadius="12" Padding="14" Margin="0,0,10,10">
              <StackPanel>
                <TextBlock Text="Current mode" Style="{StaticResource TileLabelStyle}"/>
                <TextBlock x:Name="ModeTileValue" Style="{StaticResource TileValueStyle}" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <Border Background="#FF143042" BorderBrush="#FF4EC9B0" BorderThickness="1" CornerRadius="12" Padding="14" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Text="Selected agent" Style="{StaticResource TileLabelStyle}"/>
                <TextBlock x:Name="AgentTileValue" Style="{StaticResource TileValueStyle}" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <Border Background="#FF2D2348" BorderBrush="#FF9A7BF2" BorderThickness="1" CornerRadius="12" Padding="14" Margin="0,0,10,0">
              <StackPanel>
                <TextBlock Text="Model" Style="{StaticResource TileLabelStyle}"/>
                <TextBlock x:Name="ModelTileValue" Style="{StaticResource TileValueStyle}" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <Border Background="#FF182133" BorderBrush="#FF5B5FC7" BorderThickness="1" CornerRadius="12" Padding="14">
              <StackPanel>
                <TextBlock Text="Open tabs and files" Style="{StaticResource TileLabelStyle}"/>
                <TextBlock x:Name="SessionTileValue" Style="{StaticResource TileValueStyle}" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource SectionCardStyle}">
              <StackPanel>
                <TextBlock Text="Context snapshot" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                <TextBlock Text="These values reflect the current widget state and the supporting sources already wired into the session." Foreground="#FF8F8FAF" Margin="0,6,0,12" TextWrapping="Wrap"/>
                <TextBlock x:Name="ToolsSummaryText" Style="{StaticResource DetailStyle}" Margin="0,0,0,8"/>
                <TextBlock x:Name="ExtensionsSummaryText" Style="{StaticResource DetailStyle}" Margin="0,0,0,8"/>
                <TextBlock x:Name="McpSummaryText" Style="{StaticResource DetailStyle}" Margin="0,0,0,8"/>
                <TextBlock x:Name="ExtensionInventoryText" Style="{StaticResource DetailStyle}" Margin="0,0,0,8"/>
                <TextBlock x:Name="ConfigPathText" Style="{StaticResource DetailStyle}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource SectionCardStyle}">
              <StackPanel>
                <TextBlock Text="What Clippy can do" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
                <TextBlock Text="Use the widget as a compact control deck for the larger Clippy session window." Foreground="#FF8F8FAF" Margin="0,6,0,12" TextWrapping="Wrap"/>
                <TextBlock Text="- Launch and keep a Copilot-backed session close to the desktop." Style="{StaticResource DetailStyle}" Margin="0,0,0,8"/>
                <TextBlock Text="- Switch prompt mode, agent, and model without leaving the widget." Style="{StaticResource DetailStyle}" Margin="0,0,0,8"/>
                <TextBlock Text="- Mix local PowerShell commands through !command with Copilot prompts in the same session." Style="{StaticResource DetailStyle}" Margin="0,0,0,8"/>
                <TextBlock Text="- Pull in picked files, VS Code context, and MCP inventory when you need more grounding." Style="{StaticResource DetailStyle}" Margin="0,0,0,12"/>
                <Border Background="#FF16162A" BorderBrush="#FF333355" BorderThickness="1" CornerRadius="10" Padding="12">
                  <StackPanel>
                    <TextBlock Text="Quick tip" Foreground="#FFE8E8E8" FontWeight="SemiBold"/>
                    <TextBlock Text="Use /tools, /extensions, and /files from the chat panel for the same surfaces exposed in the right-click menu." Foreground="#FF8F8FAF" Margin="0,6,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
          </Grid>
        </Grid>
      </Grid>

      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="18,6,18,18">
        <Button x:Name="FooterRepoBtn" Content="Open repo" Width="96" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
        <Button x:Name="FooterToolsBtn" Content="Tools settings" Width="110" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,0"/>
        <Button x:Name="FooterCloseBtn" Content="Close" Width="88" Style="{StaticResource PopupButtonStyle}" Background="#FF5B5FC7" BorderBrush="#FF5B5FC7"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($AX))
    script:Set-DialogOwner -Window $win

    $header = $win.FindName('HeaderBar')
    $close = $win.FindName('CloseBtn')
    $footerClose = $win.FindName('FooterCloseBtn')
    $repoBtn = $win.FindName('RepoBtn')
    $configBtn = $win.FindName('ConfigBtn')
    $toolsBtn = $win.FindName('ToolsBtn')
    $extensionsBtn = $win.FindName('ExtensionsBtn')
    $footerRepoBtn = $win.FindName('FooterRepoBtn')
    $footerToolsBtn = $win.FindName('FooterToolsBtn')
    $heroImage = $win.FindName('HeroImage')
    $versionText = $win.FindName('VersionText')
    $modeTile = $win.FindName('ModeTile')
    $modeTileValue = $win.FindName('ModeTileValue')
    $agentTileValue = $win.FindName('AgentTileValue')
    $modelTileValue = $win.FindName('ModelTileValue')
    $sessionTileValue = $win.FindName('SessionTileValue')
    $toolsSummaryText = $win.FindName('ToolsSummaryText')
    $extensionsSummaryText = $win.FindName('ExtensionsSummaryText')
    $mcpSummaryText = $win.FindName('McpSummaryText')
    $extensionInventoryText = $win.FindName('ExtensionInventoryText')
    $configPathText = $win.FindName('ConfigPathText')

    $versionText.Text = $widgetVersion
    $modeTileValue.Text = $currentMode
    $agentTileValue.Text = $currentAgent
    $modelTileValue.Text = $currentModel
    $sessionTileValue.Text = '{0} tab{1} / {2} file{3}' -f $openTabs, $(if ($openTabs -eq 1) { '' } else { 's' }), $pickedFiles, $(if ($pickedFiles -eq 1) { '' } else { 's' })
    $toolsSummaryText.Text = 'Tools settings enabled: {0} of {1}' -f $toolCount, $(if ($script:WidgetSettings) { $script:WidgetSettings.Tools.Count } else { 0 })
    $extensionsSummaryText.Text = 'Extension settings enabled: {0} of {1}' -f $extensionCount, $(if ($script:WidgetSettings) { $script:WidgetSettings.Extensions.Count } else { 0 })
    $mcpSummaryText.Text = '{0} (total MCP servers detected: {1})' -f (script:Get-McpSourceSummary), $totalMcpServers
    $extensionInventoryText.Text = 'Extension inventory: VS Code {0}, VS Code Insiders {1}' -f $regularExtensionCount, $insidersExtensionCount
    $configPathText.Text = 'Widget config: {0}' -f $script:WidgetConfigPath

    $modePalette = script:Get-ModeTilePalette -Mode $currentMode
    $brushConverter = [Windows.Media.BrushConverter]::new()
    $modeTile.Background = $brushConverter.ConvertFromString($modePalette.Background)
    $modeTile.BorderBrush = $brushConverter.ConvertFromString($modePalette.BorderBrush)
    $modeTileValue.Foreground = $brushConverter.ConvertFromString($modePalette.Foreground)

    $heroImagePath = Join-Path $AssetsDir 'WC25.png'
    if (-not (Test-Path $heroImagePath -PathType Leaf)) {
        $heroImagePath = Join-Path $AssetsDir 'clippy25_256.png'
    }
    if (Test-Path $heroImagePath -PathType Leaf) {
        try {
            $heroImage.Source = script:Load-Icon $heroImagePath
        } catch {
            script:Write-WidgetDebugLog "Unable to load About dialog hero image: $($_.Exception.Message)"
        }
    }

    $header.Add_MouseLeftButtonDown({ $win.DragMove() })
    $close.Add_Click({ $win.DialogResult = $false; $win.Close() })
    $footerClose.Add_Click({ $win.DialogResult = $false; $win.Close() })

    $openRepoAction = {
        Start-Process 'https://github.com/dayour/windows-clippy-mcp' | Out-Null
    }
    $openConfigAction = {
        script:Ensure-WidgetConfigDirectory
        Start-Process explorer.exe -ArgumentList @($script:WidgetConfigDir) | Out-Null
    }
    $openToolsAction = {
        $win.Close()
        script:Show-ToolsSettingsDialog
    }
    $openExtensionsAction = {
        $win.Close()
        script:Show-ExtensionSettingsDialog
    }

    $repoBtn.Add_Click($openRepoAction)
    $footerRepoBtn.Add_Click($openRepoAction)
    $configBtn.Add_Click($openConfigAction)
    $toolsBtn.Add_Click($openToolsAction)
    $footerToolsBtn.Add_Click($openToolsAction)
    $extensionsBtn.Add_Click($openExtensionsAction)

    [void]$win.ShowDialog()
}

function script:Show-AgentcardTileWindow {
    $payload = script:Get-WidgetJsonObject -Path $script:AgentcardAdaptiveCardDataPath
    if (-not $payload) {
        $payload = [pscustomobject]@{
            title = 'Agentcard icon tile'
            summary = 'No local agentcard tile data is available yet.'
            iconAssets = [pscustomobject]@{
                hero192 = $script:AgentcardHeroAssetPath
                default32 = $script:AgentcardDefaultAssetPath
                focused32 = $script:AgentcardFocusedAssetPath
                primaryColor = '#2146C7'
                accentColor = '#77E8FF'
                selectedState = 'missing'
            }
            generation = [pscustomobject]@{
                agent = 'dayour-icon'
                reasoningModel = 'claude-sonnet-4.6'
                tool = 'image_flux_2_pro'
                bridge = 'http://localhost:4300/api/generate'
                outputDirectory = 'M:\images'
                promptSummary = 'Create the widget adaptive-card files to populate the live tile payload.'
                negativeConstraints = 'No local data file was found.'
            }
            tools = @()
            artifacts = [pscustomobject]@{
                templatePath = $script:AgentcardAdaptiveCardTemplatePath
                dataSchemaPath = $script:AgentcardAdaptiveCardSchemaPath
                dataPath = $script:AgentcardAdaptiveCardDataPath
                packageManifestPath = $script:AgentcardPackageManifestPath
                specPath = $script:AgentcardSpecPath
            }
            review = [pscustomobject]@{
                status = 'missing'
                summary = 'The agentcard tile payload has not been created yet.'
                notes = @('Create the adaptive-card data file before opening this window.')
            }
        }
    }

    $iconAssets = script:Get-ObjectPropertyValue -InputObject $payload -PropertyName 'iconAssets'
    $generation = script:Get-ObjectPropertyValue -InputObject $payload -PropertyName 'generation'
    $artifacts = script:Get-ObjectPropertyValue -InputObject $payload -PropertyName 'artifacts'
    $review = script:Get-ObjectPropertyValue -InputObject $payload -PropertyName 'review'
    $tools = @((script:Get-ObjectPropertyValue -InputObject $payload -PropertyName 'tools'))

    $title = [string](script:Get-ObjectPropertyValue -InputObject $payload -PropertyName 'title')
    $summary = [string](script:Get-ObjectPropertyValue -InputObject $payload -PropertyName 'summary')
    $heroPath = [string](script:Get-ObjectPropertyValue -InputObject $iconAssets -PropertyName 'hero192')
    $defaultPath = [string](script:Get-ObjectPropertyValue -InputObject $iconAssets -PropertyName 'default32')
    $focusedPath = [string](script:Get-ObjectPropertyValue -InputObject $iconAssets -PropertyName 'focused32')
    $primaryColor = [string](script:Get-ObjectPropertyValue -InputObject $iconAssets -PropertyName 'primaryColor')
    $accentColor = [string](script:Get-ObjectPropertyValue -InputObject $iconAssets -PropertyName 'accentColor')
    $selectedState = [string](script:Get-ObjectPropertyValue -InputObject $iconAssets -PropertyName 'selectedState')
    $reviewStatus = [string](script:Get-ObjectPropertyValue -InputObject $review -PropertyName 'status')
    $reviewSummary = [string](script:Get-ObjectPropertyValue -InputObject $review -PropertyName 'summary')
    $promptSummary = [string](script:Get-ObjectPropertyValue -InputObject $generation -PropertyName 'promptSummary')
    $negativeConstraints = [string](script:Get-ObjectPropertyValue -InputObject $generation -PropertyName 'negativeConstraints')
    $toolName = [string](script:Get-ObjectPropertyValue -InputObject $generation -PropertyName 'tool')

    if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Agentcard icon tile' }
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Adaptive live tile metadata is unavailable.' }
    if ([string]::IsNullOrWhiteSpace($primaryColor)) { $primaryColor = '#2146C7' }
    if ([string]::IsNullOrWhiteSpace($accentColor)) { $accentColor = '#77E8FF' }
    if ([string]::IsNullOrWhiteSpace($selectedState)) { $selectedState = 'default' }
    if ([string]::IsNullOrWhiteSpace($reviewStatus)) { $reviewStatus = 'unknown' }
    if ([string]::IsNullOrWhiteSpace($reviewSummary)) { $reviewSummary = 'No review summary is available.' }
    if ([string]::IsNullOrWhiteSpace($toolName)) { $toolName = 'image_flux_2_pro' }

    $dataJson = script:Get-WidgetFileText -Path $script:AgentcardAdaptiveCardDataPath
    $templateJson = script:Get-WidgetFileText -Path $script:AgentcardAdaptiveCardTemplatePath
    $schemaJson = script:Get-WidgetFileText -Path $script:AgentcardAdaptiveCardSchemaPath
    $manifestJson = script:Get-WidgetFileText -Path $script:AgentcardPackageManifestPath

    if ([string]::IsNullOrWhiteSpace($dataJson)) { $dataJson = '{ }' }
    if ([string]::IsNullOrWhiteSpace($templateJson)) { $templateJson = '{ }' }
    if ([string]::IsNullOrWhiteSpace($schemaJson)) { $schemaJson = '{ }' }
    if ([string]::IsNullOrWhiteSpace($manifestJson)) { $manifestJson = '{ }' }

    [xml]$AX = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Agentcard tile"
    Width="1080"
    Height="760"
    WindowStartupLocation="CenterOwner"
    Background="Transparent"
    AllowsTransparency="True"
    WindowStyle="None"
    ResizeMode="NoResize">
  <Window.Resources>
    <Style x:Key="PopupButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="PopupButtonBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF1A1A35"/>
                <Setter TargetName="PopupButtonBorder" Property="BorderBrush" Value="#FF5B5FC7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="PopupButtonBorder" Property="Background" Value="#FF24244A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SectionCardStyle" TargetType="Border">
      <Setter Property="Background" Value="#FF111122"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16"/>
    </Style>
    <Style x:Key="DetailStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF8F8FAF"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="CodeBoxStyle" TargetType="TextBox">
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="AcceptsReturn" Value="True"/>
      <Setter Property="AcceptsTab" Value="True"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="Background" Value="#FF0C0C0C"/>
      <Setter Property="Foreground" Value="#FFE8E8E8"/>
      <Setter Property="BorderBrush" Value="#FF333355"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="10"/>
    </Style>
  </Window.Resources>
  <Border Background="#FF0C0C0C" BorderBrush="#FF333355" BorderThickness="1.5" CornerRadius="14">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border x:Name="HeaderBar" Grid.Row="0" Background="#FF151528" CornerRadius="14,14,0,0" Padding="18,14">
        <DockPanel LastChildFill="True">
          <Button x:Name="CloseBtn" DockPanel.Dock="Right" Content="X" Width="34" Style="{StaticResource PopupButtonStyle}" Margin="12,0,0,0"/>
          <StackPanel>
            <TextBlock Text="Agentcard adaptive tile" FontSize="18" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
            <TextBlock Text="Live Windows Clippy view for the packaged icon assets, adaptive-card schema, and generation tool stack." Foreground="#FF8F8FAF" Margin="0,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid Grid.Row="1" Margin="18,16,18,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="320"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0">
          <Border x:Name="PreviewTile" Style="{StaticResource SectionCardStyle}" Margin="0,0,0,10">
            <StackPanel>
              <TextBlock Text="Tile preview" FontSize="15" FontWeight="SemiBold" Foreground="#FFFFFFFF"/>
              <Image x:Name="HeroImage" Height="170" Stretch="Uniform" Margin="0,12,0,12"/>
              <TextBlock x:Name="TileTitleText" FontSize="17" FontWeight="SemiBold" Foreground="#FFFFFFFF" TextWrapping="Wrap"/>
              <TextBlock x:Name="TileSummaryText" Foreground="#FFE8E8E8" Margin="0,8,0,0" TextWrapping="Wrap"/>
              <WrapPanel Margin="0,12,0,0">
                <Border x:Name="StatusBadge" Background="#FF111122" BorderBrush="#FF85A2FF" BorderThickness="1" CornerRadius="10" Padding="10,4" Margin="0,0,8,8">
                  <TextBlock x:Name="StatusBadgeText" Foreground="#FFFFFFFF" FontSize="11" FontWeight="SemiBold"/>
                </Border>
                <Border x:Name="ToolBadge" Background="#FF77E8FF" BorderBrush="#FF77E8FF" BorderThickness="1" CornerRadius="10" Padding="10,4" Margin="0,0,0,8">
                  <TextBlock x:Name="ToolBadgeText" Foreground="#FF0C0C0C" FontSize="11" FontWeight="SemiBold"/>
                </Border>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource SectionCardStyle}" Margin="0,0,0,10">
            <StackPanel>
              <TextBlock Text="Packaged variants" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
              <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" HorizontalAlignment="Center">
                  <Image x:Name="DefaultIconImage" Width="64" Height="64" Stretch="Uniform" Margin="0,0,0,8"/>
                  <TextBlock Text="Default 32" Foreground="#FFB7B7D6" HorizontalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="2" HorizontalAlignment="Center">
                  <Image x:Name="FocusedIconImage" Width="64" Height="64" Stretch="Uniform" Margin="0,0,0,8"/>
                  <TextBlock Text="Focused 32" Foreground="#FFB7B7D6" HorizontalAlignment="Center"/>
                </StackPanel>
              </Grid>
              <TextBlock x:Name="AssetPathText" Style="{StaticResource DetailStyle}" Margin="0,12,0,0"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource SectionCardStyle}">
            <StackPanel>
              <TextBlock Text="Generation summary" FontSize="15" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
              <TextBlock x:Name="PromptSummaryText" Style="{StaticResource DetailStyle}" Margin="0,10,0,8"/>
              <TextBlock x:Name="ConstraintText" Style="{StaticResource DetailStyle}" Margin="0,0,0,10"/>
              <TextBlock Text="Tools" FontSize="13" FontWeight="SemiBold" Foreground="#FFE8E8E8"/>
              <ListBox x:Name="ToolsList" Height="170" Margin="0,10,0,0" Background="#FF0C0C0C" BorderBrush="#FF333355" Foreground="#FFE8E8E8"/>
            </StackPanel>
          </Border>
        </StackPanel>

        <TabControl Grid.Column="2" Background="#FF111122" BorderBrush="#FF333355">
          <TabItem Header="Data">
            <TextBox x:Name="DataBox" Style="{StaticResource CodeBoxStyle}"/>
          </TabItem>
          <TabItem Header="Template">
            <TextBox x:Name="TemplateBox" Style="{StaticResource CodeBoxStyle}"/>
          </TabItem>
          <TabItem Header="Schema">
            <TextBox x:Name="SchemaBox" Style="{StaticResource CodeBoxStyle}"/>
          </TabItem>
          <TabItem Header="Manifest">
            <TextBox x:Name="ManifestBox" Style="{StaticResource CodeBoxStyle}"/>
          </TabItem>
        </TabControl>
      </Grid>

      <WrapPanel Grid.Row="2" HorizontalAlignment="Right" Margin="18,6,18,18">
        <Button x:Name="CopyDataBtn" Content="Copy data" Width="96" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
        <Button x:Name="CopyTemplateBtn" Content="Copy template" Width="108" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
        <Button x:Name="CopySchemaBtn" Content="Copy schema" Width="100" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
        <Button x:Name="CopyManifestBtn" Content="Copy manifest" Width="108" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
        <Button x:Name="OpenAssetsBtn" Content="Open assets" Width="100" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
        <Button x:Name="OpenCardsBtn" Content="Adaptive cards" Width="112" Style="{StaticResource PopupButtonStyle}" Margin="0,0,8,8"/>
        <Button x:Name="FooterCloseBtn" Content="Close" Width="88" Style="{StaticResource PopupButtonStyle}" Background="#FF5B5FC7" BorderBrush="#FF5B5FC7" Margin="0,0,0,8"/>
      </WrapPanel>
    </Grid>
  </Border>
</Window>
'@

    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($AX))
    script:Set-DialogOwner -Window $win

    $brushConverter = [Windows.Media.BrushConverter]::new()
    $header = $win.FindName('HeaderBar')
    $close = $win.FindName('CloseBtn')
    $footerClose = $win.FindName('FooterCloseBtn')
    $previewTile = $win.FindName('PreviewTile')
    $heroImage = $win.FindName('HeroImage')
    $tileTitleText = $win.FindName('TileTitleText')
    $tileSummaryText = $win.FindName('TileSummaryText')
    $statusBadge = $win.FindName('StatusBadge')
    $statusBadgeText = $win.FindName('StatusBadgeText')
    $toolBadge = $win.FindName('ToolBadge')
    $toolBadgeText = $win.FindName('ToolBadgeText')
    $defaultIconImage = $win.FindName('DefaultIconImage')
    $focusedIconImage = $win.FindName('FocusedIconImage')
    $assetPathText = $win.FindName('AssetPathText')
    $promptSummaryText = $win.FindName('PromptSummaryText')
    $constraintText = $win.FindName('ConstraintText')
    $toolsList = $win.FindName('ToolsList')
    $dataBox = $win.FindName('DataBox')
    $templateBox = $win.FindName('TemplateBox')
    $schemaBox = $win.FindName('SchemaBox')
    $manifestBox = $win.FindName('ManifestBox')
    $copyDataBtn = $win.FindName('CopyDataBtn')
    $copyTemplateBtn = $win.FindName('CopyTemplateBtn')
    $copySchemaBtn = $win.FindName('CopySchemaBtn')
    $copyManifestBtn = $win.FindName('CopyManifestBtn')
    $openAssetsBtn = $win.FindName('OpenAssetsBtn')
    $openCardsBtn = $win.FindName('OpenCardsBtn')

    $tileTitleText.Text = $title
    $tileSummaryText.Text = $summary
    $statusBadgeText.Text = $reviewStatus
    $toolBadgeText.Text = $toolName
    $promptSummaryText.Text = 'Prompt: ' + $promptSummary
    $constraintText.Text = 'Constraints: ' + $negativeConstraints
    $assetPathText.Text = 'Hero: {0}`r`nDefault: {1}`r`nFocused: {2}`r`nSpec: {3}' -f $heroPath, $defaultPath, $focusedPath, ([string](script:Get-ObjectPropertyValue -InputObject $artifacts -PropertyName 'specPath'))
    $dataBox.Text = $dataJson
    $templateBox.Text = $templateJson
    $schemaBox.Text = $schemaJson
    $manifestBox.Text = $manifestJson

    try {
        $previewTile.Background = $brushConverter.ConvertFromString($primaryColor)
        $previewTile.BorderBrush = $brushConverter.ConvertFromString($accentColor)
        $statusBadge.BorderBrush = $brushConverter.ConvertFromString($accentColor)
        $toolBadge.Background = $brushConverter.ConvertFromString($accentColor)
        $toolBadge.BorderBrush = $brushConverter.ConvertFromString($accentColor)
    } catch {
        script:Write-WidgetDebugLog "Unable to apply agentcard palette: $($_.Exception.Message)"
    }

    foreach ($imageBinding in @(
        @{ Path = $heroPath; Control = $heroImage; Label = 'hero' },
        @{ Path = $defaultPath; Control = $defaultIconImage; Label = 'default' },
        @{ Path = $focusedPath; Control = $focusedIconImage; Label = 'focused' }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$imageBinding.Path) -or -not (Test-Path $imageBinding.Path -PathType Leaf)) {
            continue
        }

        try {
            $imageBinding.Control.Source = script:Load-Icon $imageBinding.Path
        } catch {
            script:Write-WidgetDebugLog "Unable to load agentcard $($imageBinding.Label) icon: $($_.Exception.Message)"
        }
    }

    $toolsList.Items.Clear()
    if ($tools.Count -eq 0) {
        [void]$toolsList.Items.Add('No generation tools were listed in the tile data.')
    } else {
        foreach ($tool in $tools) {
            $name = [string](script:Get-ObjectPropertyValue -InputObject $tool -PropertyName 'name')
            $kind = [string](script:Get-ObjectPropertyValue -InputObject $tool -PropertyName 'kind')
            $purpose = [string](script:Get-ObjectPropertyValue -InputObject $tool -PropertyName 'purpose')
            $source = [string](script:Get-ObjectPropertyValue -InputObject $tool -PropertyName 'source')
            $line = '{0} [{1}] - {2}' -f $name, $kind, $purpose
            if (-not [string]::IsNullOrWhiteSpace($source)) {
                $line += " | $source"
            }
            [void]$toolsList.Items.Add($line)
        }
    }

    $header.Add_MouseLeftButtonDown({ $win.DragMove() })
    $close.Add_Click({ $win.DialogResult = $false; $win.Close() })
    $footerClose.Add_Click({ $win.DialogResult = $false; $win.Close() })

    $copyDataBtn.Add_Click({
        script:Copy-WidgetFileToClipboard -Path $script:AgentcardAdaptiveCardDataPath -Label 'agentcard tile data'
    })
    $copyTemplateBtn.Add_Click({
        script:Copy-WidgetFileToClipboard -Path $script:AgentcardAdaptiveCardTemplatePath -Label 'agentcard tile template'
    })
    $copySchemaBtn.Add_Click({
        script:Copy-WidgetFileToClipboard -Path $script:AgentcardAdaptiveCardSchemaPath -Label 'agentcard tile schema'
    })
    $copyManifestBtn.Add_Click({
        script:Copy-WidgetFileToClipboard -Path $script:AgentcardPackageManifestPath -Label 'agentcard package manifest'
    })
    $openAssetsBtn.Add_Click({
        Start-Process explorer.exe -ArgumentList @($AssetsDir) | Out-Null
    })
    $openCardsBtn.Add_Click({
        Start-Process explorer.exe -ArgumentList @((Split-Path -Path $script:AgentcardAdaptiveCardDataPath -Parent)) | Out-Null
    })

    [void]$win.ShowDialog()
}

function script:Show-CopilotUsage {
    script:Write-Term "  Clippy bench commands" "#4EC9B0" -Bold
    script:Write-Term "  Ask anything directly   plain text goes to the active prompt tab" "#6B6B8D"
    script:Write-Term "  !<command>              run a local PowerShell command" "#6B6B8D"
    script:Write-Term "  /new                    open a fresh Clippy kernel bench tab" "#6B6B8D"
    script:Write-Term "  /mode <agent|plan|swarm>  set prompt mode for prompt-backed tabs" "#6B6B8D"
    script:Write-Term "  /agent <name>           select the prompt-mode agent used by the widget" "#6B6B8D"
    script:Write-Term "  /agents                 list agents discovered in .copilot\agents" "#6B6B8D"
    script:Write-Term "  /model <name>           switch prompt-mode models from the toolbar or command line" "#6B6B8D"
    script:Write-Term "  /tools  /extensions     open settings dialogs" "#6B6B8D"
    script:Write-Term "  /files   /files clear   inspect or clear picked files" "#6B6B8D"
    script:Write-Term "  clippy                  open a prompt-backed terminal session with an attached widget" "#6B6B8D"
    script:Write-Term "  copilot --help          show legacy prompt runtime CLI help" "#6B6B8D"
    script:Write-Term ""
}

function script:Set-WidgetVisualState {
    param([bool]$Hovered = $false)

    $isActive = $Hovered -or $script:ChatOpen
    $scale = if ($isActive) { 1.06 } else { 1.0 }
    $opacity = if ($isActive) { 1.0 } else { 0.94 }
    $blur = if ($isActive) { 26 } else { 18 }
    $shadowOpacity = if ($isActive) { 0.82 } else { 0.55 }

    if ($wIcon.RenderTransform -is [Windows.Media.ScaleTransform]) {
        $wIcon.RenderTransform.ScaleX = $scale
        $wIcon.RenderTransform.ScaleY = $scale
    }

    if ($wIcon.Effect -is [Windows.Media.Effects.DropShadowEffect]) {
        $wIcon.Effect.BlurRadius = $blur
        $wIcon.Effect.Opacity = $shadowOpacity
    }

    $wIcon.Opacity = $opacity
}

function script:Test-ChatWindowAvailable {
    return (
        $script:Chat -and
        -not $script:ChatWasClosed -and
        $script:Chat.Dispatcher -and
        -not $script:Chat.Dispatcher.HasShutdownStarted -and
        -not $script:Chat.Dispatcher.HasShutdownFinished
    )
}

function script:Ensure-ChatWindow {
    if (script:Test-ChatWindowAvailable) {
        return $true
    }

    try {
        script:Initialize-ChatWindow
    } catch {
        Write-Warning "Clippy: failed to create chat window: $_"
        return $false
    }

    if (-not $script:Chat) {
        Write-Warning "Clippy: chat window is null after initialization"
        return $false
    }

    script:Initialize-ChatWindowHandlers

    $activeTab = script:Get-ActiveClippyTab
    if ($activeTab) {
        script:Show-ClippyTabDocument -Tab $activeTab
    }

    script:Sync-WidgetUi
    script:Refresh-ClippyTabStrip
    script:Set-WidgetVisualState
    return $true
}

# ── Helper: position chat adjacent to widget ──────────────────────
function script:Place-Chat {
    if (-not (script:Ensure-ChatWindow)) {
        return
    }

    $workArea = [System.Windows.SystemParameters]::WorkArea
    $wL = $script:Widget.Left
    $wT = $script:Widget.Top
    $cW = if ($script:Chat.ActualWidth -gt 0) { $script:Chat.ActualWidth } elseif ($script:Chat.Width -gt 0) { $script:Chat.Width } else { 540 }
    $cH = if ($script:Chat.ActualHeight -gt 0) { $script:Chat.ActualHeight } elseif ($script:Chat.Height -gt 0) { $script:Chat.Height } else { 620 }
    $widgetWidth = if ($script:Widget.ActualWidth -gt 0) { $script:Widget.ActualWidth } else { $script:Widget.Width }
    $widgetHeight = if ($script:Widget.ActualHeight -gt 0) { $script:Widget.ActualHeight } else { $script:Widget.Height }
    $gap = 14
    $margin = 8

    # prefer left of widget; flip right if clipped
    $left = $wL - $cW - $gap
    if ($left -lt $workArea.Left) {
        $left = $wL + $widgetWidth + $gap
    }
    $left = [Math]::Max($workArea.Left + $margin, [Math]::Min($left, $workArea.Right - $cW - $margin))

    # bottom-align with widget; clamp to work area
    $top = $wT + $widgetHeight - $cH
    $top = [Math]::Max($workArea.Top + $margin, [Math]::Min($top, $workArea.Bottom - $cH - $margin))

    $script:Chat.Left = $left
    $script:Chat.Top  = $top
}

# ── Helper: show / hide chat with fade ────────────────────────────
function script:Toggle-Chat {
    $chatVisible = (script:Test-ChatWindowAvailable) -and $script:Chat.IsVisible
    if ($script:ChatOpen -and $chatVisible) {
        script:Set-SnippingTileOpen $false
        $script:Chat.Hide()
        $script:ChatOpen = $false
        script:Set-WidgetVisualState
        return
    }

    if (-not (script:Ensure-ChatWindow)) {
        return
    }

    if ($script:Widget -and $script:Widget.IsVisible -and $script:Chat.Owner -ne $script:Widget) {
        try {
            $script:Chat.Owner = $script:Widget
        } catch {
        }
    }

    script:Place-Chat
    $script:Chat.Opacity = 0
    if (-not $script:Chat.IsVisible) {
        $script:Chat.Show()
    }
    script:Update-SnippingTilePlacement

    $activeTab = script:Get-ActiveClippyTab
    if ($activeTab) {
        try {
            if ($activeTab.UseEmbeddedTerminal) {
                script:Ensure-ClippyTabTerminalPanel -Tab $activeTab
                [void](script:Attach-ClippyTerminalWindow -Tab $activeTab)
                script:Queue-ClippyTerminalWindowAttach -Tab $activeTab
            }
            script:Show-ClippyTabDocument -Tab $activeTab
        } catch {
            script:Write-WidgetDebugLog "Toggle-Chat tab setup error: $($_.Exception.Message)"
        }
    }

    $anim = [Windows.Media.Animation.DoubleAnimation]::new()
    $anim.From = 0; $anim.To = 1
    $anim.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
    $anim.EasingFunction = [Windows.Media.Animation.QuadraticEase]::new()
    $script:Chat.BeginAnimation([Windows.UIElement]::OpacityProperty, $anim)
    $script:ChatOpen = $true
    script:Queue-ClippyActiveTabDocumentRefresh
    $script:Chat.Activate()
    if ($script:cInput) {
        [void]$script:cInput.Focus()
        $script:cInput.CaretIndex = $script:cInput.Text.Length
    }
    script:Set-WidgetVisualState
}

# ── Initialize session state and selectors ─────────────────────────
script:Refresh-AgentCatalog
script:Refresh-VsCodeContext
script:Refresh-ToolSourceContext
$script:WidgetSettings = script:Load-WidgetSettings
"[$(Get-Date -Format o)] DIAG: Calling Initialize-ClippyTabs pid=$PID" | Out-File "$env:APPDATA\Windows-Clippy-MCP\widget-startup-diag.log" -Append
$_initSw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    script:Initialize-ClippyTabs -RequestedSessionId $SessionId
    "[$(Get-Date -Format o)] DIAG: Initialize-ClippyTabs done pid=$PID elapsedMs=$($_initSw.ElapsedMilliseconds)" | Out-File "$env:APPDATA\Windows-Clippy-MCP\widget-startup-diag.log" -Append
} catch {
    "[$(Get-Date -Format o)] DIAG: Initialize-ClippyTabs FAILED pid=$PID elapsedMs=$($_initSw.ElapsedMilliseconds) error=$($_.Exception.ToString())" | Out-File "$env:APPDATA\Windows-Clippy-MCP\widget-startup-diag.log" -Append
}

$cAgent.Items.Clear()
if ($script:AvailableAgents.Count -eq 0) {
    $placeholderAgent = script:New-ToolbarComboItem -Tag '' -PrimaryText 'No agents found' -ToolTip 'No .copilot agents were found on this machine.'
    $placeholderAgent.IsEnabled = $false
    [void]$cAgent.Items.Add($placeholderAgent)
    $cAgent.IsEnabled = $false
} else {
    $cAgent.IsEnabled = $true
    foreach ($agent in $script:AvailableAgents) {
        [void]$cAgent.Items.Add((script:New-ToolbarComboItem -Tag $agent.Id -PrimaryText $agent.DisplayName -ToolTip $agent.Path))
    }
}

$cModel.Items.Clear()
foreach ($model in $script:AvailableModelCatalog) {
    [void]$cModel.Items.Add((script:New-ToolbarComboItem -Tag $model.Id -PrimaryText $model.DisplayName -SecondaryText $model.RateLabel -ToolTip ('{0} - {1}' -f $model.DisplayName, $model.Id)))
}

script:Initialize-ToolbarDropdowns
script:Sync-WidgetUi
script:Refresh-ClippyTabStrip
script:Update-SnippingTileState
script:Update-SnippingButtonVisual

# ── Helper: execute a command ─────────────────────────────────────
function script:Invoke-Cmd ([string]$Cmd) {
    $t = $Cmd.Trim()
    if ([string]::IsNullOrEmpty($t)) { return }

    $script:History.Add($t)
    $script:HistIdx = $script:History.Count

    $activeTab = script:Get-ActiveClippyTab
    $hasTerminalHost = $activeTab -and $activeTab.TerminalProcess -and -not $activeTab.TerminalProcess.HasExited -and $activeTab.TerminalStdinWriter
    if ($hasTerminalHost) {
        try {
            script:Send-ClippyTabHostMessage -Tab $activeTab -Payload (
                script:New-TerminalBridgeCommandPayload -Command 'session.write' -LegacyAction 'write' -Payload @{
                    text = "$t`r"
                }
            )
        } catch {
            script:Write-Term "ERROR: $($_.Exception.Message)" "#F44747" -TabId $activeTab.TabId
            script:Write-Term "" -TabId $activeTab.TabId
        }
        return
    }

    script:Write-Term "Clippy> $t" "#5B5FC7" -Bold

    switch -Regex ($t) {
        '^(cls|clear)$' { script:Clear-Transcript; return }
        '^exit$'        { script:Toggle-Chat; return }
        '^(help|/\?|/help)$' { script:Show-CopilotUsage; return }
        '^/new$' {
            script:New-ClippySession
            script:Write-Term "Opened a fresh Clippy kernel bench tab." "#4EC9B0"
            script:Write-Term ""
            return
        }
        '^/session$' {
            script:Write-Term "Bench tab $(script:Get-ShortSessionId) is active." "#4EC9B0"
            script:Write-Term ""
            return
        }
        '^/tools$' {
            script:Show-ToolsSettingsDialog
            script:Write-Term "Updated tool settings for the current widget session." "#4EC9B0"
            script:Write-Term ""
            return
        }
        '^/extensions$' {
            script:Show-ExtensionSettingsDialog
            script:Write-Term "Updated extension settings for the current widget session." "#4EC9B0"
            script:Write-Term ""
            return
        }
        '^/files$' {
            if ($script:AttachedFiles.Count -eq 0) {
                script:Write-Term "No files are attached to this session." "#6B6B8D"
            } else {
                script:Write-Term "Attached files:" "#4EC9B0" -Bold
                foreach ($file in $script:AttachedFiles) {
                    script:Write-Term "  $file" "#CCCCCC"
                }
            }
            script:Write-Term ""
            return
        }
        '^/files\s+clear$' {
            script:Clear-Attachments
            return
        }
        '^/mode\s+(agent|plan|swarm)$' {
            $mode = switch ($Matches[1].ToLowerInvariant()) {
                'agent' { 'Agent' }
                'plan'  { 'Plan' }
                'swarm' { 'Swarm' }
            }
            script:Set-WidgetMode $mode
            script:Write-Term "Mode set to $mode." "#4EC9B0"
            script:Write-Term ""
            return
        }
        '^/agents$' {
            if ($script:AvailableAgents.Count -eq 0) {
                script:Write-Term "No agents were found in $([IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.copilot', 'agents'))." "#CCA700"
            } else {
                script:Write-Term "Available agents:" "#4EC9B0" -Bold
                foreach ($agent in $script:AvailableAgents) {
                    script:Write-Term "  $($agent.DisplayName)" "#CCCCCC"
                }
            }
            script:Write-Term ""
            return
        }
        '^/agent\s+(.+)$' {
            $agent = $Matches[1].Trim()
            $resolvedAgent = script:Resolve-AgentToken -Token $agent
            if (-not $resolvedAgent) {
                script:Write-Term "ERROR: Unknown agent '$agent'." "#F44747"
                script:Write-Term "Available agents: $((@($script:AvailableAgents | ForEach-Object { $_.DisplayName })) -join ', ')" "#CCA700"
                script:Write-Term ""
                return
            }
            script:Set-WidgetAgent $resolvedAgent
            script:Write-Term "Agent set to $resolvedAgent. Active agent: $(script:Get-ActiveAgentDisplayName)." "#4EC9B0"
            script:Write-Term ""
            return
        }
        '^/model\s+(.+)$' {
            $model = $Matches[1].Trim()
            $resolvedModel = script:Resolve-ModelToken -Token $model
            if (-not $resolvedModel) {
                script:Write-Term "ERROR: Unknown model '$model'." "#F44747"
                script:Write-Term "Available models: $((@($script:AvailableModelCatalog | ForEach-Object { $_.DisplayName })) -join ', ')" "#CCA700"
                script:Write-Term ""
                return
            }
            script:Set-WidgetModel $resolvedModel
            script:Write-Term "Model set to $(script:Get-SelectedModelDisplayName)." "#4EC9B0"
            script:Write-Term ""
            return
        }
        '^hey(?:\s+clippy)?$' { script:Show-CopilotUsage; return }
        '^clippy(?:\.exe)?$'  { script:Show-CopilotUsage; return }
        '^copilot(?:\.exe)?$' { script:Show-CopilotUsage; return }
        '^(?:clippy|copilot)(?:\.exe)?\s+(--help|-h|help)$' {
            try {
                $response = script:Invoke-CopilotCliCommand -Arguments @('--help')
                foreach ($line in ($response -split "`r?`n")) {
                    script:Write-Term $line "#CCCCCC"
                }
            } catch {
                script:Write-Term "ERROR: $($_.Exception.Message)" "#F44747"
            }
            script:Write-Term ""
            return
        }
        '^(?:clippy|copilot)(?:\.exe)?\s+(--version|-v|version)$' {
            try {
                $response = script:Invoke-CopilotCliCommand -Arguments @('--version')
                foreach ($line in ($response -split "`r?`n")) {
                    script:Write-Term $line "#CCCCCC"
                }
            } catch {
                script:Write-Term "ERROR: $($_.Exception.Message)" "#F44747"
            }
            script:Write-Term ""
            return
        }
    }

    if ($t -match '^!(.*)$') {
        script:Run-ShellCommand -Command $Matches[1]
        return
    }

    $prompt = $t
    if ($t -match '^(?:hey\s+clippy|clippy(?:\.exe)?|copilot(?:\.exe)?)\s+(.+)$') {
        $prompt = $Matches[1].Trim()
    }

    $activeTab = script:Get-ActiveClippyTab
    if (-not $activeTab) {
        script:Write-Term "ERROR: No active Clippy tab is available." "#F44747"
        script:Write-Term ""
        return
    }

    if ($activeTab.StreamState -and $activeTab.StreamState.WaitingForResponse) {
        script:Write-Term "This Clippy tab is still processing the previous request." "#CCA700" -TabId $activeTab.TabId
        script:Write-Term "" -TabId $activeTab.TabId
        return
    }
    
    # Session-backed only: do not fall back to widget-side copilot -p execution.
    $promptText = script:Build-CopilotPrompt -Prompt $prompt
    [void](script:Reset-TabCopilotStreamState -Tab $activeTab)
    $activeTab.StreamState.WaitingForResponse = $true
    script:Set-CopilotBusyState $true
    script:Write-Term "Clippy is thinking in $([string]$activeTab.Mode) mode with $(script:Get-ActiveAgentDisplayName)..." "#6B6B8D" -TabId $activeTab.TabId
    script:Flush-TerminalUi
    try {
        script:Send-ClippyTabHostMessage -Tab $activeTab -Payload (
            script:New-TerminalBridgeCommandPayload -Command 'session.input' -LegacyAction 'input' -Payload @{
                text = $promptText
            }
        )
    } catch {
        $activeTab.StreamState.WaitingForResponse = $false
        script:Set-CopilotBusyState $false
        script:Write-Term "ERROR: $($_.Exception.Message)" "#F44747"
        script:Write-Term ""
    }
}

# ══════════════════════════════════════════════════════════════════
#  EVENT WIRING
# ══════════════════════════════════════════════════════════════════

# ── Widget: click vs drag ─────────────────────────────────────────
$script:Widget.Add_MouseLeftButtonDown({
    $script:_wSnap = @{ L = $script:Widget.Left; T = $script:Widget.Top }
    try {
        $script:Widget.DragMove()
    } catch {
        # DragMove can throw if the mouse button was released during the call
    }
    $dx = [Math]::Abs($script:Widget.Left - $script:_wSnap.L)
    $dy = [Math]::Abs($script:Widget.Top  - $script:_wSnap.T)
    try {
        if (($dx + $dy) -lt 4) {
            script:Toggle-Chat
        } elseif ($script:ChatOpen) {
            script:Place-Chat
        }
    } catch {
        script:Write-WidgetDebugLog "Click handler error: $($_.Exception.Message)"
    }
})

# ── Widget: hover glow ───────────────────────────────────────────
$wRing.Add_MouseEnter({
    script:Set-WidgetVisualState -Hovered $true
})
$wRing.Add_MouseLeave({
    script:Set-WidgetVisualState
})

# ── Widget: right-click context menu ──────────────────────────────
$ctx = script:New-ToolbarContextMenu

$miOpen = script:New-ToolbarMenuItem -Header 'Open Clippy Bench'
$miOpen.Add_Click({ script:Toggle-Chat })
$ctx.Items.Add($miOpen) | Out-Null

$miSession = script:New-ToolbarMenuItem -Header 'New Clippy Bench Tab'
$miSession.Add_Click({
    script:New-ClippySession
    script:Write-Term "Opened a fresh Clippy kernel bench tab." "#4EC9B0"
    script:Write-Term ""
})
$ctx.Items.Add($miSession) | Out-Null

$miAttach = script:New-ToolbarMenuItem -Header 'Pick Files'
$miAttach.Add_Click({ script:Pick-AttachmentFiles })
$ctx.Items.Add($miAttach) | Out-Null

$miClearFiles = script:New-ToolbarMenuItem -Header 'Clear Picked Files'
$miClearFiles.Add_Click({ script:Clear-Attachments })
$ctx.Items.Add($miClearFiles) | Out-Null

$ctx.Items.Add([Windows.Controls.Separator]::new()) | Out-Null

$miMode = script:New-ToolbarMenuItem -Header 'Mode'
foreach ($mode in $script:AvailableModes) {
    $item = script:New-ToolbarMenuItem -Header $mode -Tag $mode -Checkable -StayOpen
    $item.Add_Click({ script:Set-WidgetMode ([string]$this.Tag) })
    $script:ModeMenuItems[$mode] = $item
    $miMode.Items.Add($item) | Out-Null
}
$ctx.Items.Add($miMode) | Out-Null

$miAgent = script:New-ToolbarMenuItem -Header 'Agent'
foreach ($agent in $script:AvailableAgents) {
    $item = script:New-ToolbarMenuItem -Header $agent.DisplayName -Tag $agent.Id -Checkable -StayOpen
    $item.Add_Click({ script:Set-WidgetAgent ([string]$this.Tag) })
    $script:AgentMenuItems[$agent.Id] = $item
    $miAgent.Items.Add($item) | Out-Null
}
$ctx.Items.Add($miAgent) | Out-Null

$miModel = script:New-ToolbarMenuItem -Header 'Model'
foreach ($model in $script:AvailableModelCatalog) {
    $item = script:New-ToolbarMenuItem -Header $model.DisplayName -InputGestureText $model.RateLabel -Tag $model.Id -Checkable -StayOpen
    $item.Add_Click({ script:Set-WidgetModel ([string]$this.Tag) })
    $script:ModelMenuItems[$model.Id] = $item
    $miModel.Items.Add($item) | Out-Null
}
$ctx.Items.Add($miModel) | Out-Null

$ctx.Items.Add([Windows.Controls.Separator]::new()) | Out-Null

$miTools = script:New-ToolbarMenuItem -Header 'Tools Settings'
$miTools.Add_Click({ script:Show-ToolsSettingsDialog })
$ctx.Items.Add($miTools) | Out-Null

$miExtensions = script:New-ToolbarMenuItem -Header 'Extension Settings'
$miExtensions.Add_Click({ script:Show-ExtensionSettingsDialog })
$ctx.Items.Add($miExtensions) | Out-Null

$miAdaptiveCards = script:New-ToolbarMenuItem -Header 'Adaptive Cards'
$miCopyActiveCard = script:New-ToolbarMenuItem -Header 'Copy active card'
$miCopyActiveCard.Add_Click({ script:Copy-ActiveClippyAdaptiveCard })
$miAdaptiveCards.Items.Add($miCopyActiveCard) | Out-Null

$miCopyActiveCardData = script:New-ToolbarMenuItem -Header 'Copy active card data'
$miCopyActiveCardData.Add_Click({ script:Copy-ActiveClippyAdaptiveCardData })
$miAdaptiveCards.Items.Add($miCopyActiveCardData) | Out-Null

$miCopyCardTemplate = script:New-ToolbarMenuItem -Header 'Copy card template'
$miCopyCardTemplate.Add_Click({
    script:Copy-WidgetFileToClipboard `
        -Path $script:TerminalAdaptiveCardTemplatePath `
        -Label 'adaptive card template'
})
$miAdaptiveCards.Items.Add($miCopyCardTemplate) | Out-Null

$miCopyCardSchema = script:New-ToolbarMenuItem -Header 'Copy data schema'
$miCopyCardSchema.Add_Click({
    script:Copy-WidgetFileToClipboard `
        -Path $script:TerminalAdaptiveCardSchemaPath `
        -Label 'adaptive card data schema'
})
$miAdaptiveCards.Items.Add($miCopyCardSchema) | Out-Null

$miShowAgentcardTile = script:New-ToolbarMenuItem -Header 'Open agentcard tile'
$miShowAgentcardTile.Add_Click({ script:Show-AgentcardTileWindow })
$miAdaptiveCards.Items.Add($miShowAgentcardTile) | Out-Null

$miCopyAgentcardData = script:New-ToolbarMenuItem -Header 'Copy agentcard data'
$miCopyAgentcardData.Add_Click({
    script:Copy-WidgetFileToClipboard `
        -Path $script:AgentcardAdaptiveCardDataPath `
        -Label 'agentcard tile data'
})
$miAdaptiveCards.Items.Add($miCopyAgentcardData) | Out-Null

$miCopyAgentcardTemplate = script:New-ToolbarMenuItem -Header 'Copy agentcard template'
$miCopyAgentcardTemplate.Add_Click({
    script:Copy-WidgetFileToClipboard `
        -Path $script:AgentcardAdaptiveCardTemplatePath `
        -Label 'agentcard tile template'
})
$miAdaptiveCards.Items.Add($miCopyAgentcardTemplate) | Out-Null

$miCopyAgentcardSchema = script:New-ToolbarMenuItem -Header 'Copy agentcard schema'
$miCopyAgentcardSchema.Add_Click({
    script:Copy-WidgetFileToClipboard `
        -Path $script:AgentcardAdaptiveCardSchemaPath `
        -Label 'agentcard tile schema'
})
$miAdaptiveCards.Items.Add($miCopyAgentcardSchema) | Out-Null

$miCopyAgentcardManifest = script:New-ToolbarMenuItem -Header 'Copy agentcard manifest'
$miCopyAgentcardManifest.Add_Click({
    script:Copy-WidgetFileToClipboard `
        -Path $script:AgentcardPackageManifestPath `
        -Label 'agentcard package manifest'
})
$miAdaptiveCards.Items.Add($miCopyAgentcardManifest) | Out-Null

$ctx.Items.Add($miAdaptiveCards) | Out-Null

$ctx.Items.Add([Windows.Controls.Separator]::new()) | Out-Null

$miAbout = script:New-ToolbarMenuItem -Header 'About'
$miAbout.Add_Click({ script:Show-AboutDialog })
$ctx.Items.Add($miAbout) | Out-Null

$miExit = script:New-ToolbarMenuItem -Header 'Exit'
$miExit.Add_Click({
    $script:IsApplicationClosing = $true
    $script:Widget.Close()
})
$ctx.Items.Add($miExit) | Out-Null

$ctx.Add_Opened({
    $toolEnabledCount = if ($script:WidgetSettings) { script:Get-EnabledSettingCount -SettingsTable $script:WidgetSettings.Tools } else { 0 }
    $extensionEnabledCount = if ($script:WidgetSettings) { script:Get-EnabledSettingCount -SettingsTable $script:WidgetSettings.Extensions } else { 0 }
    $currentMode = script:Get-ActiveTabMode
    if ([string]::IsNullOrWhiteSpace($currentMode)) {
        $currentMode = if ($script:WidgetSettings) { [string]$script:WidgetSettings.Mode } else { 'Agent' }
    }
    $currentAgent = script:Get-ActiveAgentDisplayName
    $currentModel = if ($script:WidgetSettings) { [string]$script:WidgetSettings.Model } else { '' }
    $widgetVersion = script:Get-WidgetPackageVersion
    $activeTab = script:Get-ActiveClippyTab
    $hasAdaptiveCard = $activeTab -and -not [string]::IsNullOrWhiteSpace([string]$activeTab.AdaptiveCardJson)
    $hasAdaptiveCardData = $activeTab -and -not [string]::IsNullOrWhiteSpace([string]$activeTab.AdaptiveCardDataJson)
    $hasAgentcardData = Test-Path $script:AgentcardAdaptiveCardDataPath -PathType Leaf
    $hasAgentcardTemplate = Test-Path $script:AgentcardAdaptiveCardTemplatePath -PathType Leaf
    $hasAgentcardSchema = Test-Path $script:AgentcardAdaptiveCardSchemaPath -PathType Leaf
    $hasAgentcardManifest = Test-Path $script:AgentcardPackageManifestPath -PathType Leaf

    $miMode.InputGestureText = $currentMode
    $miAgent.InputGestureText = $currentAgent
    $miModel.InputGestureText = $currentModel
    $miTools.InputGestureText = '{0} enabled' -f $toolEnabledCount
    $miExtensions.InputGestureText = '{0} enabled' -f $extensionEnabledCount
    $miClearFiles.InputGestureText = if ($script:AttachedFiles.Count -eq 1) { '1 picked' } else { "$($script:AttachedFiles.Count) picked" }
    $miClearFiles.IsEnabled = $script:AttachedFiles.Count -gt 0
    $miAdaptiveCards.InputGestureText = if ($hasAdaptiveCard -and $hasAgentcardData) { 'live + agentcard' } elseif ($hasAdaptiveCard) { 'live' } elseif ($hasAgentcardData) { 'agentcard' } else { 'template' }
    $miCopyActiveCard.IsEnabled = [bool]$hasAdaptiveCard
    $miCopyActiveCardData.IsEnabled = [bool]$hasAdaptiveCardData
    $miCopyCardTemplate.IsEnabled = Test-Path $script:TerminalAdaptiveCardTemplatePath -PathType Leaf
    $miCopyCardSchema.IsEnabled = Test-Path $script:TerminalAdaptiveCardSchemaPath -PathType Leaf
    $miShowAgentcardTile.IsEnabled = [bool]$hasAgentcardData
    $miCopyAgentcardData.IsEnabled = [bool]$hasAgentcardData
    $miCopyAgentcardTemplate.IsEnabled = [bool]$hasAgentcardTemplate
    $miCopyAgentcardSchema.IsEnabled = [bool]$hasAgentcardSchema
    $miCopyAgentcardManifest.IsEnabled = [bool]$hasAgentcardManifest
    $miAbout.InputGestureText = if ([string]::IsNullOrWhiteSpace($widgetVersion)) { '' } else { "v$widgetVersion" }
})

$script:Widget.ContextMenu = $ctx

function script:Initialize-ChatWindowHandlers {
    if (-not $script:Chat) {
        return
    }

    $script:Chat.Add_Closing({
        param($s, $e)
        if ($script:IsApplicationClosing) {
            return
        }
        $e.Cancel = $true
        script:Set-SnippingTileOpen $false
        if ($script:Chat -and $script:Chat.IsVisible) {
            $script:Chat.Hide()
        }
        $script:ChatOpen = $false
        script:Set-WidgetVisualState
    })

    $script:Chat.Add_Closed({
        $script:ChatWasClosed = $true
        $script:ChatOpen = $false
        script:Set-SnippingTileOpen $false
    })

    $script:Chat.Add_SizeChanged({
        if ($script:SnippingTileOpen) {
            script:Update-SnippingTilePlacement
        }

        script:Resize-ClippyTerminalSurface -Tab (script:Get-ActiveClippyTab)
    })
    $script:cTitle.Add_SizeChanged({
        if ($script:SnippingTileOpen) {
            script:Update-SnippingTilePlacement
        }
    })

    # ── Chat: title bar drag ─────────────────────────────────────
    $script:cTitle.Add_MouseLeftButtonDown({ $script:Chat.DragMove() })

    # ── Chat: buttons ─────────────────────────────────────────────
    $script:cClose.Add_Click({ script:Toggle-Chat })
    $script:cHide.Add_Click({ script:Toggle-Chat })
    $script:cClear.ToolTip = 'Clear the transcript'
    $script:cAttach.ToolTip = 'Open a fresh Clippy kernel bench tab'
    $script:cClear.Add_Click({ script:Clear-Transcript })
    $script:cAttach.Add_Click({
        script:New-ClippySession
        script:Write-Term "Opened a fresh Clippy kernel bench tab." "#4EC9B0"
        script:Write-Term ""
    })
    $script:cTabAdd.Add_Click({
        script:New-ClippySession
        script:Write-Term "Opened a fresh Clippy kernel bench tab." "#4EC9B0"
        script:Write-Term ""
    })
    $script:cTools.Add_Click({ script:Open-ToolbarContextMenu $script:cTools })
    $script:cExt.Add_Click({ script:Open-ToolbarContextMenu $script:cExt })
    if ($script:cTilePanelToggle) {
        $script:cTilePanelToggle.Add_Click({
            if ($script:cTilePanel.Visibility -eq 'Visible') {
                $script:cTilePanel.Visibility = 'Collapsed'
            } else {
                $script:cTilePanel.Visibility = 'Visible'
                script:Refresh-BenchTiles
            }
        })
    }
    if ($script:cSnip) {
        $script:cSnip.Add_Click({ script:Toggle-SnippingTile })
    }

    if ($script:cSnippingTilePopup) {
        $script:cSnippingTilePopup.Add_Opened({
            $script:SnippingTileOpen = $true
            script:Update-SnippingTilePlacement
            script:Update-SnippingButtonVisual
        })
        $script:cSnippingTilePopup.Add_Closed({
            $script:SnippingTileOpen = $false
            script:Update-SnippingButtonVisual
        })
    }

    if ($script:cSnipOverlay) { $script:cSnipOverlay.Add_Click({ script:Invoke-SnippingTileAction 'Snip' }) }
    if ($script:cSnipSketch) { $script:cSnipSketch.Add_Click({ script:Invoke-SnippingTileAction 'Sketch' }) }
    if ($script:cSnipTool) { $script:cSnipTool.Add_Click({ script:Invoke-SnippingTileAction 'Tool' }) }
    if ($script:cSnipClickToDo) { $script:cSnipClickToDo.Add_Click({ script:Invoke-SnippingTileAction 'ClickToDo' }) }
    if ($script:cSnipSettings) { $script:cSnipSettings.Add_Click({ script:Invoke-SnippingTileAction 'Settings' }) }

    if ($script:cModeCycle) { $script:cModeCycle.Add_Click({ script:Cycle-WidgetMode }) }

    $script:cAgent.Add_SelectionChanged({
        if ($script:IsSyncingUi) { return }
        if ($script:cAgent.SelectedItem -and $script:cAgent.SelectedItem.Tag) {
            script:Set-WidgetAgent ([string]$script:cAgent.SelectedItem.Tag)
        }
    })

    $script:cModel.Add_SelectionChanged({
        if ($script:IsSyncingUi) { return }
        if ($script:cModel.SelectedItem -and $script:cModel.SelectedItem.Tag) {
            script:Set-WidgetModel ([string]$script:cModel.SelectedItem.Tag)
        }
    })

    # close button hover → red
    $script:cClose.Add_MouseEnter({
        $script:cClose.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FFF44747")
    })
    $script:cClose.Add_MouseLeave({
        $script:cClose.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FF707070")
    })
    $script:cSnip.Add_MouseEnter({
        if (-not $script:SnippingTileOpen) {
            $script:cSnip.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FFB7B7D6")
        }
    })
    $script:cSnip.Add_MouseLeave({
        script:Update-SnippingButtonVisual
    })

    # ── Chat: send command ────────────────────────────────────────
    $script:cRun.Add_Click({
        $cmd = $script:cInput.Text; $script:cInput.Clear()
        script:Invoke-Cmd $cmd
    })

    # ── Chat: keyboard input ─────────────────────────────────────
    $script:cInput.Add_PreviewKeyDown({
        param($s, $e)
        switch ($e.Key) {
            'Return' {
                $cmd = $script:cInput.Text; $script:cInput.Clear()
                script:Invoke-Cmd $cmd
                $e.Handled = $true
            }
            'Up' {
                if ($script:History.Count -gt 0 -and $script:HistIdx -gt 0) {
                    $script:HistIdx--
                    $script:cInput.Text = $script:History[$script:HistIdx]
                    $script:cInput.CaretIndex = $script:cInput.Text.Length
                }
                $e.Handled = $true
            }
            'Down' {
                if ($script:HistIdx -lt ($script:History.Count - 1)) {
                    $script:HistIdx++
                    $script:cInput.Text = $script:History[$script:HistIdx]
                    $script:cInput.CaretIndex = $script:cInput.Text.Length
                } else {
                    $script:HistIdx = $script:History.Count
                    $script:cInput.Clear()
                }
                $e.Handled = $true
            }
            'Escape' {
                if ($script:cInput -and $script:cInput.Text.Length -gt 0) {
                    $script:cInput.Clear()
                } else {
                    script:Toggle-Chat
                }
                $e.Handled = $true
            }
        }
    })
}

script:Initialize-ChatWindowHandlers

# ── Welcome message ───────────────────────────────────────────────
$activeTab = script:Get-ClippyTab -TabId $script:ActiveClippyTabId
if (-not $activeTab -or [string]$activeTab.HostState -ne 'error') {
    script:Render-TranscriptWelcome
}

script:Sync-WidgetUi
script:Refresh-ClippyTabStrip
script:Set-WidgetVisualState

if ($OpenChat) {
    $script:Widget.Add_ContentRendered({
        if (-not $script:ChatOpen) {
            script:Toggle-Chat
        }
    })
}

# ── Cleanup on close ──────────────────────────────────────────────
$script:Widget.Add_Closing({
    $script:IsApplicationClosing = $true
    script:Set-SnippingTileOpen $false
    if ($script:ActiveCopilotProcess -and -not $script:ActiveCopilotProcess.HasExited) {
        try {
            $script:ActiveCopilotProcess.Kill()
        } catch {
        }
    }
    foreach ($tabId in @($script:ClippyTabOrder)) {
        $tab = script:Get-ClippyTab -TabId $tabId
        if ($tab) {
            script:Stop-ClippyTabHost -Tab $tab
        }
    }
    if (script:Test-ChatWindowAvailable) {
        try {
            $script:Chat.Close()
        } catch {
        }
    }
    try { $_widgetMutex.ReleaseMutex() } catch { }
    try { $_widgetMutex.Dispose() } catch { }
})

# ── Run application ───────────────────────────────────────────────
"[$(Get-Date -Format o)] DIAG: Creating Application" | Out-File "$env:APPDATA\Windows-Clippy-MCP\widget-startup-diag.log" -Append
$app = [Windows.Application]::new()
$app.Add_DispatcherUnhandledException({
    param($s, $e)
    script:Write-WidgetDebugLog "UNHANDLED WPF EXCEPTION: $($e.Exception.Message) | $($e.Exception.StackTrace)"
    $e.Handled = $true
})
$app.ShutdownMode = 'OnMainWindowClose'
$app.MainWindow   = $script:Widget
$app.Run($script:Widget) | Out-Null

