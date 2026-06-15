using System;
using System.Threading.Tasks;
using System.Windows;

namespace WidgetHost;

public partial class FleetStatusWindow : Window
{
    private readonly McpAppsBridge _bridge;
    private readonly string _resourceUri;
    private readonly string _commanderSessionId;
    private readonly Action<McpAppsHost?> _onHostChanged;
    private McpAppsHost? _host;
    private bool _disposed;

    internal FleetStatusWindow(
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

    public void SetStatusText(string text)
    {
        if (StatusText is null) return;
        StatusText.Text = text ?? string.Empty;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _host = new McpAppsHost(_resourceUri, _bridge, _commanderSessionId);
            HostSlot.Child = _host;
            _onHostChanged?.Invoke(_host);
            await _host.EnsureReadyAsync().ConfigureAwait(true);
            SetStatusText($"Mounted {_resourceUri}");
        }
        catch (Exception ex)
        {
            SetStatusText($"Mount failed: {ex.Message}");
            WidgetHostLogger.Log($"FleetStatusWindow mount failed: {ex.Message}");
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

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();
}
