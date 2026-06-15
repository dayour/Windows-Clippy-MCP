using System;
using System.Windows;

namespace WidgetHost;

public partial class CommanderCardWindow : Window
{
    private const double LayerOffset = 22d;

    private readonly McpAppsBridge _bridge;
    private readonly string _resourceUri;
    private readonly string _commanderSessionId;
    private readonly Action<McpAppsHost?> _onHostChanged;
    private McpAppsHost? _host;
    private bool _disposed;

    internal CommanderCardWindow(
        McpAppsBridge bridge,
        string resourceUri,
        string commanderSessionId,
        Action<McpAppsHost?> onHostChanged)
    {
        InitializeComponent();
        _bridge = bridge;
        _resourceUri = resourceUri;
        _commanderSessionId = commanderSessionId;
        _onHostChanged = onHostChanged;
        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    internal McpAppsHost? Host => _host;

    internal void AlignBehind(Window foreground)
    {
        Width = foreground.ActualWidth > 0 ? foreground.ActualWidth : foreground.Width;
        Height = foreground.ActualHeight > 0 ? foreground.ActualHeight : foreground.Height;
        Left = foreground.Left + LayerOffset;
        Top = foreground.Top + LayerOffset;
        Topmost = foreground.Topmost;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _host = new McpAppsHost(_resourceUri, _bridge, _commanderSessionId);
            HostSlot.Child = _host;
            _onHostChanged?.Invoke(_host);
            await _host.EnsureReadyAsync().ConfigureAwait(true);
            StatusText.Text = " - live standalone card";
        }
        catch (Exception ex)
        {
            StatusText.Text = $" - mount failed: {ex.Message}";
            WidgetHostLogger.Log($"CommanderCardWindow mount failed: {ex.Message}");
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        if (_disposed) return;
        _disposed = true;
        _onHostChanged?.Invoke(null);
        try { _host?.Dispose(); } catch { }
        _host = null;
        HostSlot.Child = null;
    }
}
