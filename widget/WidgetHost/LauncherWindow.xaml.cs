using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using WpfPoint = System.Windows.Point;

namespace WidgetHost;

public partial class LauncherWindow : Window
{
    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativePoint lpPoint);

    private readonly WidgetLaunchOptions _options;
    private readonly MainWindow _benchWindow;
    private readonly Dictionary<string, MenuItem> _modeMenuItems = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, MenuItem> _agentMenuItems = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, MenuItem> _modelMenuItems = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, MenuItem> _toolMenuItems = new(StringComparer.Ordinal);
    private readonly Dictionary<string, MenuItem> _extensionMenuItems = new(StringComparer.Ordinal);
    private WpfPoint _dragOrigin;
    private double _originLeft;
    private double _originTop;
    private bool _dragging;
    private bool _dragMoved;
    private MenuItem? _modeRootMenu;
    private MenuItem? _agentRootMenu;
    private MenuItem? _modelRootMenu;
    private MenuItem? _toolsRootMenu;
    private MenuItem? _extensionsRootMenu;
    private MenuItem? _aboutMenuItem;

    public LauncherWindow(WidgetLaunchOptions options, MainWindow benchWindow)
    {
        _options = options;
        _benchWindow = benchWindow;

        InitializeComponent();
        BuildContextMenu();
        Loaded += OnLoaded;
        LocationChanged += OnLocationChanged;
        Closing += OnClosing;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        RestoreOrPositionLauncher();
        LoadLauncherIcon();
        WidgetHostLogger.Log("LauncherWindow loaded.");

        if (_options.OpenChat)
        {
            await _benchWindow.ShowBenchAsync(GetBounds(), _options.SessionId);
        }
    }

    private void OnLocationChanged(object? sender, EventArgs e)
    {
        _benchWindow.RepositionNearLauncher(GetBounds());
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        WidgetHostLogger.Log("LauncherWindow closing. Shutting down bench window.");
        _benchWindow.CloseForShutdown();
    }

    private async void OnToggleBenchClick(object sender, RoutedEventArgs e)
    {
        WidgetHostLogger.Log("Launcher context menu toggle requested.");
        await _benchWindow.ToggleBenchAsync(GetBounds());
    }

    private async void OnNewTabClick(object sender, RoutedEventArgs e)
    {
        WidgetHostLogger.Log("Launcher context menu new-tab requested.");
        await _benchWindow.AddLauncherTabAsync(GetBounds());
    }

    private void OnResetPositionClick(object sender, RoutedEventArgs e)
    {
        PositionAtBottomRight();
        SaveLauncherPosition();
    }

    private void OnAboutClick(object sender, RoutedEventArgs e)
    {
        var executablePath = Process.GetCurrentProcess().MainModule?.FileName ?? string.Empty;
        var version = string.IsNullOrWhiteSpace(executablePath)
            ? "unknown"
            : FileVersionInfo.GetVersionInfo(executablePath).FileVersion ?? "unknown";

        var message =
            "Windows Clippy native widget" + Environment.NewLine +
            $"Version: {version}" + Environment.NewLine +
            $"Mode: {_benchWindow.GetActiveMode()}" + Environment.NewLine +
            $"Agent: {_benchWindow.GetActiveAgentDisplayName()}" + Environment.NewLine +
            $"Model: {_benchWindow.GetActiveModelDisplayName()}";

        MessageBox.Show(this, message, "About Clippy", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void OnExitClick(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void OnSurfaceMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        _dragOrigin = GetCursorScreenPosition();
        _originLeft = Left;
        _originTop = Top;
        _dragging = true;
        _dragMoved = false;
        if (!LauncherSurface.CaptureMouse())
        {
            WidgetHostLogger.Log("Launcher mouse capture failed.");
        }
        e.Handled = true;
    }

    private void OnSurfaceMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_dragging || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        var current = GetCursorScreenPosition();
        var deltaX = current.X - _dragOrigin.X;
        var deltaY = current.Y - _dragOrigin.Y;

        if (Math.Abs(deltaX) > 3 || Math.Abs(deltaY) > 3)
        {
            _dragMoved = true;
        }

        Left = _originLeft + deltaX;
        Top = _originTop + deltaY;
        _benchWindow.RepositionNearLauncher(GetBounds());
    }

    private async void OnSurfaceMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        LauncherSurface.ReleaseMouseCapture();
        _dragging = false;

        var wasDrag = _dragMoved;
        _dragMoved = false;

        if (wasDrag)
        {
            SaveLauncherPosition();
            WidgetHostLogger.Log($"Launcher moved to ({Left:F0}, {Top:F0}).");
        }
        else
        {
            WidgetHostLogger.Log("Launcher surface click toggling bench.");
            await _benchWindow.ToggleBenchAsync(GetBounds());
        }

        e.Handled = true;
    }

    private void OnSurfaceMouseRightButtonUp(object sender, MouseButtonEventArgs e)
    {
        WidgetHostLogger.Log("Launcher context menu opened.");
        LauncherContextMenu.PlacementTarget = LauncherSurface;
        LauncherContextMenu.IsOpen = true;
        e.Handled = true;
    }

    private Rect GetBounds()
    {
        return new Rect(
            Left,
            Top,
            ActualWidth > 0 ? ActualWidth : Width,
            ActualHeight > 0 ? ActualHeight : Height);
    }

    private static WpfPoint GetCursorScreenPosition()
    {
        return GetCursorPos(out var point)
            ? new WpfPoint(point.X, point.Y)
            : default;
    }

    private void PositionAtBottomRight()
    {
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right - Width - 20;
        Top = workArea.Bottom - Height - 20;
    }

    private void RestoreOrPositionLauncher()
    {
        var (savedLeft, savedTop) = _benchWindow.GetSavedLauncherPosition();
        if (savedLeft is null || savedTop is null)
        {
            PositionAtBottomRight();
            return;
        }

        var workArea = SystemParameters.WorkArea;
        Left = Math.Max(workArea.Left, Math.Min(savedLeft.Value, workArea.Right - Width));
        Top = Math.Max(workArea.Top, Math.Min(savedTop.Value, workArea.Bottom - Height));
    }

    private void SaveLauncherPosition()
    {
        _benchWindow.SaveLauncherPosition(Left, Top);
    }

    private void BuildContextMenu()
    {
        LauncherContextMenu.Items.Clear();
        LauncherContextMenu.Opened += OnContextMenuOpened;

        var toggleBenchItem = new MenuItem
        {
            Header = "Toggle Clippy Bench"
        };
        toggleBenchItem.Click += OnToggleBenchClick;
        LauncherContextMenu.Items.Add(toggleBenchItem);

        var newTabItem = new MenuItem
        {
            Header = "New Tab"
        };
        newTabItem.Click += OnNewTabClick;
        LauncherContextMenu.Items.Add(newTabItem);

        var resetPositionItem = new MenuItem
        {
            Header = "Reset Position"
        };
        resetPositionItem.Click += OnResetPositionClick;
        LauncherContextMenu.Items.Add(resetPositionItem);

        LauncherContextMenu.Items.Add(new Separator());

        _modeRootMenu = new MenuItem { Header = "Mode" };
        foreach (var mode in MainWindow.AvailableModes)
        {
            var item = new MenuItem
            {
                Header = mode,
                Tag = mode,
                IsCheckable = true,
                StaysOpenOnClick = true
            };
            item.Click += (_, _) => _benchWindow.ApplyModeFromLauncher((string)item.Tag);
            _modeMenuItems[mode] = item;
            _modeRootMenu.Items.Add(item);
        }
        LauncherContextMenu.Items.Add(_modeRootMenu);

        _agentRootMenu = new MenuItem { Header = "Agent" };
        foreach (var agent in _benchWindow.AvailableAgents)
        {
            var item = new MenuItem
            {
                Header = agent.DisplayName,
                Tag = agent.Id,
                ToolTip = AgentCatalog.BuildPortableTooltip(agent),
                IsCheckable = true,
                StaysOpenOnClick = true
            };
            item.Click += (_, _) => _benchWindow.ApplyAgentFromLauncher((string)item.Tag);
            _agentMenuItems[agent.Id] = item;
            _agentRootMenu.Items.Add(item);
        }
        _agentRootMenu.IsEnabled = _agentRootMenu.Items.Count > 0;
        LauncherContextMenu.Items.Add(_agentRootMenu);

        _modelRootMenu = new MenuItem { Header = "Model" };
        foreach (var model in ModelCatalog.Models)
        {
            var item = new MenuItem
            {
                Header = model.DisplayName,
                Tag = model.Id,
                InputGestureText = model.RateLabel,
                IsCheckable = true,
                StaysOpenOnClick = true
            };
            item.Click += (_, _) => _benchWindow.ApplyModelFromLauncher((string)item.Tag);
            _modelMenuItems[model.Id] = item;
            _modelRootMenu.Items.Add(item);
        }
        LauncherContextMenu.Items.Add(_modelRootMenu);

        _toolsRootMenu = new MenuItem { Header = "Tools" };
        AddToolToggle(nameof(WidgetToolSettings.AllowAllTools), "Allow all tools");
        AddToolToggle(nameof(WidgetToolSettings.AllowAllPaths), "Allow all paths");
        AddToolToggle(nameof(WidgetToolSettings.AllowAllUrls), "Allow all URLs");
        AddToolToggle(nameof(WidgetToolSettings.Experimental), "Experimental");
        AddToolToggle(nameof(WidgetToolSettings.Autopilot), "Autopilot");
        AddToolToggle(nameof(WidgetToolSettings.EnableAllGitHubMcpTools), "Enable all GitHub MCP tools");
        LauncherContextMenu.Items.Add(_toolsRootMenu);

        _extensionsRootMenu = new MenuItem { Header = "Extensions" };
        AddExtensionToggle(nameof(WidgetExtensionSettings.IncludeRegularSettings), "Include regular settings");
        AddExtensionToggle(nameof(WidgetExtensionSettings.IncludeInsidersSettings), "Include insiders settings");
        AddExtensionToggle(nameof(WidgetExtensionSettings.IncludeRegularExtensions), "Include regular extensions");
        AddExtensionToggle(nameof(WidgetExtensionSettings.IncludeInsidersExtensions), "Include insiders extensions");
        LauncherContextMenu.Items.Add(_extensionsRootMenu);

        LauncherContextMenu.Items.Add(new Separator());

        _aboutMenuItem = new MenuItem { Header = "About" };
        _aboutMenuItem.Click += OnAboutClick;
        LauncherContextMenu.Items.Add(_aboutMenuItem);

        var exitItem = new MenuItem { Header = "Exit" };
        exitItem.Click += OnExitClick;
        LauncherContextMenu.Items.Add(exitItem);
    }

    private void AddToolToggle(string settingName, string header)
    {
        if (_toolsRootMenu is null)
        {
            return;
        }

        var item = new MenuItem
        {
            Header = header,
            Tag = settingName,
            IsCheckable = true,
            StaysOpenOnClick = true
        };
        item.Click += (_, _) =>
        {
            _benchWindow.SetToolSetting(settingName, item.IsChecked);
            SyncToggleStates();
        };
        _toolMenuItems[settingName] = item;
        _toolsRootMenu.Items.Add(item);
    }

    private void AddExtensionToggle(string settingName, string header)
    {
        if (_extensionsRootMenu is null)
        {
            return;
        }

        var item = new MenuItem
        {
            Header = header,
            Tag = settingName,
            IsCheckable = true,
            StaysOpenOnClick = true
        };
        item.Click += (_, _) =>
        {
            _benchWindow.SetExtensionSetting(settingName, item.IsChecked);
            SyncToggleStates();
        };
        _extensionMenuItems[settingName] = item;
        _extensionsRootMenu.Items.Add(item);
    }

    private void OnContextMenuOpened(object sender, RoutedEventArgs e)
    {
        if (_modeRootMenu is not null)
        {
            _modeRootMenu.InputGestureText = _benchWindow.GetActiveMode();
        }

        if (_agentRootMenu is not null)
        {
            _agentRootMenu.InputGestureText = _benchWindow.GetActiveAgentDisplayName();
        }

        if (_modelRootMenu is not null)
        {
            _modelRootMenu.InputGestureText = _benchWindow.GetActiveModelDisplayName();
        }

        if (_toolsRootMenu is not null)
        {
            _toolsRootMenu.InputGestureText = $"{_benchWindow.ToolSettings.EnabledCount} enabled";
        }

        if (_extensionsRootMenu is not null)
        {
            _extensionsRootMenu.InputGestureText = $"{_benchWindow.ExtensionSettings.EnabledCount} enabled";
        }

        SyncToggleStates();
    }

    private void SyncToggleStates()
    {
        UpdateCheckedState(_modeMenuItems, _benchWindow.GetActiveMode());
        UpdateCheckedState(_agentMenuItems, _benchWindow.GetActiveAgentId());
        UpdateCheckedState(_modelMenuItems, _benchWindow.GetActiveModelId());

        SetChecked(_toolMenuItems, nameof(WidgetToolSettings.AllowAllTools), _benchWindow.ToolSettings.AllowAllTools);
        SetChecked(_toolMenuItems, nameof(WidgetToolSettings.AllowAllPaths), _benchWindow.ToolSettings.AllowAllPaths);
        SetChecked(_toolMenuItems, nameof(WidgetToolSettings.AllowAllUrls), _benchWindow.ToolSettings.AllowAllUrls);
        SetChecked(_toolMenuItems, nameof(WidgetToolSettings.Experimental), _benchWindow.ToolSettings.Experimental);
        SetChecked(_toolMenuItems, nameof(WidgetToolSettings.Autopilot), _benchWindow.ToolSettings.Autopilot);
        SetChecked(_toolMenuItems, nameof(WidgetToolSettings.EnableAllGitHubMcpTools), _benchWindow.ToolSettings.EnableAllGitHubMcpTools);

        SetChecked(_extensionMenuItems, nameof(WidgetExtensionSettings.IncludeRegularSettings), _benchWindow.ExtensionSettings.IncludeRegularSettings);
        SetChecked(_extensionMenuItems, nameof(WidgetExtensionSettings.IncludeInsidersSettings), _benchWindow.ExtensionSettings.IncludeInsidersSettings);
        SetChecked(_extensionMenuItems, nameof(WidgetExtensionSettings.IncludeRegularExtensions), _benchWindow.ExtensionSettings.IncludeRegularExtensions);
        SetChecked(_extensionMenuItems, nameof(WidgetExtensionSettings.IncludeInsidersExtensions), _benchWindow.ExtensionSettings.IncludeInsidersExtensions);
    }

    private static void UpdateCheckedState(Dictionary<string, MenuItem> items, string? activeKey)
    {
        foreach (var (key, item) in items)
        {
            item.IsChecked = string.Equals(key, activeKey, StringComparison.OrdinalIgnoreCase);
        }
    }

    private static void SetChecked(Dictionary<string, MenuItem> items, string key, bool value)
    {
        if (items.TryGetValue(key, out var item))
        {
            item.IsChecked = value;
        }
    }

    private void LoadLauncherIcon()
    {
        var iconPath = Path.Combine(ResolveRepoRoot(), "assets", "clippy25_96.png");
        if (!File.Exists(iconPath))
        {
            WidgetHostLogger.Log($"Launcher icon was not found at {iconPath}.");
            return;
        }

        try
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(iconPath, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            IconImage.Source = bitmap;
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Failed to load launcher icon: {ex}");
        }
    }

    private static string ResolveRepoRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            if (File.Exists(Path.Combine(current.FullName, "package.json")) &&
                Directory.Exists(Path.Combine(current.FullName, "widget")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException(
            $"Could not locate the Windows-Clippy-MCP repository root from {AppContext.BaseDirectory}.");
    }
}
