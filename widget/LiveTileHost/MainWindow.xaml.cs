using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace LiveTileHost;

public partial class MainWindow : Window
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly LiveTileLaunchOptions _options;
    private readonly DispatcherTimer _reloadTimer;
    private readonly DispatcherTimer _snapTimer;
    private FileSystemWatcher? _dataWatcher;
    private bool _isSnapScrollInProgress;
    private bool _windowPositioned;

    public MainWindow(LiveTileLaunchOptions options)
    {
        _options = options;
        InitializeComponent();

        _reloadTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(350)
        };
        _reloadTimer.Tick += OnReloadTimerTick;

        _snapTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(140)
        };
        _snapTimer.Tick += OnSnapTimerTick;

        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        LoadTileData(showErrors: true);
        StartWatcher();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _reloadTimer.Stop();
        _snapTimer.Stop();
        if (_dataWatcher is not null)
        {
            _dataWatcher.EnableRaisingEvents = false;
            _dataWatcher.Dispose();
            _dataWatcher = null;
        }
    }

    private void StartWatcher()
    {
        var directory = Path.GetDirectoryName(_options.DataPath);
        var fileName = Path.GetFileName(_options.DataPath);
        if (string.IsNullOrWhiteSpace(directory) || string.IsNullOrWhiteSpace(fileName) || !Directory.Exists(directory))
        {
            return;
        }

        _dataWatcher = new FileSystemWatcher(directory, fileName)
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.CreationTime | NotifyFilters.Size
        };
        _dataWatcher.Changed += OnWatchedFileChanged;
        _dataWatcher.Created += OnWatchedFileChanged;
        _dataWatcher.Renamed += OnWatchedFileChanged;
        _dataWatcher.EnableRaisingEvents = true;
    }

    private void OnWatchedFileChanged(object sender, FileSystemEventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            _reloadTimer.Stop();
            _reloadTimer.Start();
        });
    }

    private void OnReloadTimerTick(object? sender, EventArgs e)
    {
        _reloadTimer.Stop();
        LoadTileData(showErrors: false);
    }

    private void LoadTileData(bool showErrors)
    {
        try
        {
            var payload = ReadPayload(_options.DataPath);
            ApplyPayload(payload);
            StatusText.Text = $"Watching {Path.GetFileName(_options.DataPath)} for changes.";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Reload failed: {ex.Message}";
            if (showErrors)
            {
                MessageBox.Show(
                    ex.Message,
                    "Windows Clippy Live Tile",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
    }

    private static LiveTilePayload ReadPayload(string dataPath)
    {
        if (!File.Exists(dataPath))
        {
            throw new FileNotFoundException($"Live tile payload was not found: {dataPath}", dataPath);
        }

        var rawJson = File.ReadAllText(dataPath);
        var payload = JsonSerializer.Deserialize<LiveTilePayload>(rawJson, JsonOptions);
        if (payload is null)
        {
            throw new InvalidOperationException("Live tile payload could not be parsed.");
        }

        return payload;
    }

    private void ApplyPayload(LiveTilePayload payload)
    {
        var windowSettings = payload.Window ?? new LiveTileWindowPayload();
        var title = FirstNonEmpty(windowSettings.Title, _options.WindowTitle, "Windows Clippy Live Tile");

        Title = title;
        WindowTitleText.Text = title;
        TileTitleText.Text = FirstNonEmpty(payload.Title, "Windows Clippy native live tile");
        TileSummaryText.Text = FirstNonEmpty(payload.Summary, "Adaptive payload not available.");
        ReviewSummaryText.Text = FirstNonEmpty(payload.Review?.Summary, "No review summary has been captured yet.");

        if (windowSettings.Width is > 0)
        {
            Width = windowSettings.Width.Value;
        }
        if (windowSettings.Height is > 0)
        {
            Height = windowSettings.Height.Value;
        }

        if (_options.Left.HasValue)
        {
            Left = _options.Left.Value;
        }
        else if (windowSettings.Left is > 0)
        {
            Left = windowSettings.Left.Value;
        }

        if (_options.Top.HasValue)
        {
            Top = _options.Top.Value;
        }
        else if (windowSettings.Top is > 0)
        {
            Top = windowSettings.Top.Value;
        }

        Topmost = windowSettings.Topmost ?? _options.Topmost;
        UpdatePinButton();
        EnsureDefaultPosition();

        HeroImage.Source = LoadBitmap(payload.IconAssets?.Hero192);
        Default32Image.Source = LoadBitmap(payload.IconAssets?.Default32);
        Focused32Image.Source = LoadBitmap(payload.IconAssets?.Focused32);

        CapabilitiesItems.ItemsSource = payload.Capabilities ?? Array.Empty<string>();
        GenerationFactsItems.ItemsSource = BuildGenerationFacts(payload);
        ToolsItems.ItemsSource = payload.Tools ?? Array.Empty<ToolPayload>();
        ReviewNotesItems.ItemsSource = payload.Review?.Notes ?? Array.Empty<string>();
        ArtifactItems.ItemsSource = BuildArtifactFacts(payload);

        AdaptiveVersionText.Text = BuildAdaptiveVersionText(payload);
        DataPathText.Text = $"Data: {_options.DataPath}";
        TemplatePathText.Text = $"Template: {FirstNonEmpty(_options.TemplatePath, payload.Artifacts?.TemplatePath, "not provided")}";
        SchemaPathText.Text = $"Schema: {FirstNonEmpty(_options.SchemaPath, payload.Artifacts?.SchemaPath, "not provided")}";

        ApplyTheme(payload.IconAssets);
    }

    private void OnContentScrollViewerPreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (ContentScrollViewer.ScrollableHeight <= 0)
        {
            return;
        }

        e.Handled = true;
        _snapTimer.Stop();
        SnapToAdjacentViewport(e.Delta < 0 ? 1 : -1);
    }

    private void OnContentScrollViewerScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (_isSnapScrollInProgress || ContentScrollViewer.ScrollableHeight <= 0)
        {
            return;
        }

        if (e.VerticalChange == 0 && e.ViewportHeightChange == 0)
        {
            return;
        }

        _snapTimer.Stop();
        _snapTimer.Start();
    }

    private void OnSnapTimerTick(object? sender, EventArgs e)
    {
        _snapTimer.Stop();
        SnapToNearestViewport();
    }

    private void SnapToAdjacentViewport(int direction)
    {
        var pageHeight = GetViewportPageHeight();
        if (pageHeight <= 0)
        {
            return;
        }

        var pageProgress = ContentScrollViewer.VerticalOffset / pageHeight;
        var roundedPage = Math.Round(pageProgress, MidpointRounding.AwayFromZero);
        var isOnPageBoundary = Math.Abs(pageProgress - roundedPage) < 0.01;

        var targetPage = direction > 0
            ? (isOnPageBoundary ? (int)roundedPage + 1 : (int)Math.Ceiling(pageProgress))
            : (isOnPageBoundary ? (int)roundedPage - 1 : (int)Math.Floor(pageProgress));

        SnapToViewport(targetPage, pageHeight);
    }

    private void SnapToNearestViewport()
    {
        var pageHeight = GetViewportPageHeight();
        if (pageHeight <= 0)
        {
            return;
        }

        var targetPage = (int)Math.Round(
            ContentScrollViewer.VerticalOffset / pageHeight,
            MidpointRounding.AwayFromZero);

        SnapToViewport(targetPage, pageHeight);
    }

    private void SnapToViewport(int targetPage, double pageHeight)
    {
        var maxOffset = ContentScrollViewer.ScrollableHeight;
        if (maxOffset <= 0)
        {
            return;
        }

        var targetOffset = Math.Clamp(targetPage * pageHeight, 0, maxOffset);
        if (Math.Abs(ContentScrollViewer.VerticalOffset - targetOffset) < 0.5)
        {
            return;
        }

        _isSnapScrollInProgress = true;
        try
        {
            ContentScrollViewer.ScrollToVerticalOffset(targetOffset);
        }
        finally
        {
            _isSnapScrollInProgress = false;
        }
    }

    private double GetViewportPageHeight()
    {
        var viewportHeight = ContentScrollViewer.ViewportHeight;
        if (viewportHeight > 0)
        {
            return viewportHeight;
        }

        return ContentScrollViewer.ActualHeight;
    }

    private void EnsureDefaultPosition()
    {
        if (_windowPositioned)
        {
            return;
        }

        if (_options.Left.HasValue || _options.Top.HasValue)
        {
            _windowPositioned = true;
            return;
        }

        var workArea = SystemParameters.WorkArea;
        if (!double.IsNaN(Left) || !double.IsNaN(Top))
        {
            if (double.IsNaN(Left))
            {
                Left = Math.Max(workArea.Left + 16, workArea.Right - Width - 28);
            }

            if (double.IsNaN(Top))
            {
                Top = Math.Max(workArea.Top + 16, workArea.Bottom - Height - 28);
            }
        }
        else
        {
            Left = Math.Max(workArea.Left + 16, workArea.Right - Width - 28);
            Top = Math.Max(workArea.Top + 16, workArea.Bottom - Height - 28);
        }

        _windowPositioned = true;
    }

    private static IReadOnlyList<FactItem> BuildGenerationFacts(LiveTilePayload payload)
    {
        var generation = payload.Generation ?? new GenerationPayload();
        return
        [
            new FactItem("Agent", FirstNonEmpty(generation.Agent, "dayour-icon") ?? string.Empty),
            new FactItem("Model", FirstNonEmpty(generation.ReasoningModel, "not set") ?? string.Empty),
            new FactItem("Tool", FirstNonEmpty(generation.Tool, "not set") ?? string.Empty),
            new FactItem("Bridge", FirstNonEmpty(generation.Bridge, "not set") ?? string.Empty),
            new FactItem("State", FirstNonEmpty(payload.IconAssets?.SelectedState, "default") ?? string.Empty),
            new FactItem("Output", FirstNonEmpty(generation.OutputDirectory, "not set") ?? string.Empty),
            new FactItem("Prompt", FirstNonEmpty(generation.PromptSummary, "not set") ?? string.Empty),
            new FactItem("Constraints", FirstNonEmpty(generation.NegativeConstraints, "not set") ?? string.Empty)
        ];
    }

    private static IReadOnlyList<FactItem> BuildArtifactFacts(LiveTilePayload payload)
    {
        var artifacts = payload.Artifacts ?? new ArtifactsPayload();
        var facts = new List<FactItem>();

        AppendArtifactFact(facts, "Template", FirstNonEmpty(artifacts.TemplatePath));
        AppendArtifactFact(facts, "Schema", FirstNonEmpty(artifacts.SchemaPath, artifacts.DataSchemaPath));
        AppendArtifactFact(facts, "Data", FirstNonEmpty(artifacts.DataPath));
        AppendArtifactFact(facts, "Launch", FirstNonEmpty(artifacts.LaunchScriptPath));
        AppendArtifactFact(facts, "Command", FirstNonEmpty(artifacts.CmdPath));
        AppendArtifactFact(facts, "Manifest", FirstNonEmpty(artifacts.PackageManifestPath));
        AppendArtifactFact(facts, "Spec", FirstNonEmpty(artifacts.SpecPath));

        return facts;
    }

    private static void AppendArtifactFact(ICollection<FactItem> facts, string title, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value))
        {
            facts.Add(new FactItem(title, value));
        }
    }

    private static string BuildAdaptiveVersionText(LiveTilePayload payload)
    {
        var generatedAt = FirstNonEmpty(payload.GeneratedAt, "unknown");
        var adaptiveVersion = FirstNonEmpty(payload.AdaptiveCardVersion, "unknown");
        var templateVersion = FirstNonEmpty(payload.TemplateVersion, "unknown");
        return $"Adaptive card v{adaptiveVersion} | template {templateVersion} | generated {generatedAt}";
    }

    private void ApplyTheme(IconAssetsPayload? iconAssets)
    {
        var primary = ParseColorOrFallback(iconAssets?.PrimaryColor, "#1E335D");
        var accent = ParseColorOrFallback(iconAssets?.AccentColor, "#4F7AF2");

        ChromeBorder.BorderBrush = new SolidColorBrush(accent);
        ChromeBorder.Background = new SolidColorBrush(Darken(primary, 0.78));
        HeaderBorder.Background = new LinearGradientBrush(
            Lighten(primary, 0.12),
            Darken(primary, 0.12),
            new Point(0, 0),
            new Point(1, 1));
    }

    private static BitmapImage? LoadBitmap(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
        {
            return null;
        }

        try
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(fullPath, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    private static Color ParseColorOrFallback(string? rawColor, string fallbackHex)
    {
        if (!string.IsNullOrWhiteSpace(rawColor))
        {
            try
            {
                return (Color)ColorConverter.ConvertFromString(rawColor);
            }
            catch
            {
            }
        }

        return (Color)ColorConverter.ConvertFromString(fallbackHex);
    }

    private static Color Darken(Color color, double factor)
    {
        factor = Math.Clamp(factor, 0.0, 1.0);
        return Color.FromRgb(
            (byte)(color.R * factor),
            (byte)(color.G * factor),
            (byte)(color.B * factor));
    }

    private static Color Lighten(Color color, double amount)
    {
        amount = Math.Clamp(amount, 0.0, 1.0);
        return Color.FromRgb(
            (byte)(color.R + ((255 - color.R) * amount)),
            (byte)(color.G + ((255 - color.G) * amount)),
            (byte)(color.B + ((255 - color.B) * amount)));
    }

    private void UpdatePinButton()
    {
        PinButton.Content = Topmost ? "Pinned" : "Pin";
    }

    private static string? FirstNonEmpty(params string?[] values)
    {
        foreach (var value in values)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }

    private void OnHeaderMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            DragMove();
        }
    }

    private void OnRefreshClick(object sender, RoutedEventArgs e)
    {
        LoadTileData(showErrors: true);
    }

    private void OnPinClick(object sender, RoutedEventArgs e)
    {
        Topmost = !Topmost;
        UpdatePinButton();
        StatusText.Text = Topmost
            ? "Window pinned on top."
            : "Window unpinned.";
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }
}

public sealed class LiveTileLaunchOptions
{
    public string DataPath { get; init; } = string.Empty;
    public string? TemplatePath { get; init; }
    public string? SchemaPath { get; init; }
    public string WindowTitle { get; init; } = "Windows Clippy Live Tile";
    public bool Topmost { get; init; } = true;
    public double? Left { get; init; }
    public double? Top { get; init; }

    public static LiveTileLaunchOptions Parse(IEnumerable<string> rawArgs)
    {
        var options = new MutableOptions();
        using var enumerator = rawArgs.GetEnumerator();

        while (enumerator.MoveNext())
        {
            var current = enumerator.Current ?? string.Empty;
            if (!current.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            string key;
            string? value = null;
            var separatorIndex = current.IndexOf('=');
            if (separatorIndex >= 0)
            {
                key = current[..separatorIndex];
                value = current[(separatorIndex + 1)..];
            }
            else
            {
                key = current;
            }

            switch (key)
            {
                case "--data":
                    options.DataPath = RequireExistingFile(value ?? RequireValue(key, enumerator), key);
                    break;
                case "--template":
                    options.TemplatePath = RequireExistingFile(value ?? RequireValue(key, enumerator), key);
                    break;
                case "--schema":
                    options.SchemaPath = RequireExistingFile(value ?? RequireValue(key, enumerator), key);
                    break;
                case "--title":
                    options.WindowTitle = value ?? RequireValue(key, enumerator);
                    break;
                case "--left":
                    options.Left = ParseDouble(value ?? RequireValue(key, enumerator), key);
                    break;
                case "--top":
                    options.Top = ParseDouble(value ?? RequireValue(key, enumerator), key);
                    break;
                case "--no-topmost":
                    options.Topmost = false;
                    break;
                default:
                    throw new ArgumentException($"Unsupported argument: {current}");
            }
        }

        if (string.IsNullOrWhiteSpace(options.DataPath))
        {
            throw new ArgumentException("--data is required.");
        }

        return new LiveTileLaunchOptions
        {
            DataPath = options.DataPath!,
            TemplatePath = options.TemplatePath,
            SchemaPath = options.SchemaPath,
            WindowTitle = options.WindowTitle!,
            Topmost = options.Topmost,
            Left = options.Left,
            Top = options.Top
        };
    }

    private static string RequireValue(string argumentName, IEnumerator<string> enumerator)
    {
        if (!enumerator.MoveNext() || string.IsNullOrWhiteSpace(enumerator.Current))
        {
            throw new ArgumentException($"{argumentName} requires a value.");
        }

        return enumerator.Current;
    }

    private static string RequireExistingFile(string path, string argumentName)
    {
        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException($"{argumentName} file was not found: {fullPath}", fullPath);
        }

        return fullPath;
    }

    private static double ParseDouble(string value, string argumentName)
    {
        if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsedValue))
        {
            throw new ArgumentException($"{argumentName} must be a number.");
        }

        return parsedValue;
    }

    private sealed class MutableOptions
    {
        public string? DataPath { get; set; }
        public string? TemplatePath { get; set; }
        public string? SchemaPath { get; set; }
        public string? WindowTitle { get; set; } = "Windows Clippy Live Tile";
        public bool Topmost { get; set; } = true;
        public double? Left { get; set; }
        public double? Top { get; set; }
    }
}

public sealed class LiveTilePayload
{
    public string? TemplateVersion { get; set; }
    public string? AdaptiveCardVersion { get; set; }
    public string? GeneratedAt { get; set; }
    public string? Title { get; set; }
    public string? Summary { get; set; }
    public LiveTileWindowPayload? Window { get; set; }
    public IconAssetsPayload? IconAssets { get; set; }
    public GenerationPayload? Generation { get; set; }
    public IReadOnlyList<string>? Capabilities { get; set; }
    public IReadOnlyList<ToolPayload>? Tools { get; set; }
    public ArtifactsPayload? Artifacts { get; set; }
    public ReviewPayload? Review { get; set; }
}

public sealed class LiveTileWindowPayload
{
    public string? Title { get; set; }
    public double? Width { get; set; }
    public double? Height { get; set; }
    public bool? Topmost { get; set; }
    public double? Left { get; set; }
    public double? Top { get; set; }
}

public sealed class IconAssetsPayload
{
    public string? Hero192 { get; set; }
    public string? Default32 { get; set; }
    public string? Focused32 { get; set; }
    public string? PrimaryColor { get; set; }
    public string? AccentColor { get; set; }
    public string? SelectedState { get; set; }
}

public sealed class GenerationPayload
{
    public string? Agent { get; set; }
    public string? ReasoningModel { get; set; }
    public string? Tool { get; set; }
    public string? Bridge { get; set; }
    public string? OutputDirectory { get; set; }
    public string? PromptSummary { get; set; }
    public string? NegativeConstraints { get; set; }
}

public sealed class ToolPayload
{
    public string? Name { get; set; }
    public string? Kind { get; set; }
    public string? Purpose { get; set; }
    public string? Source { get; set; }

    public string DisplayName => string.IsNullOrWhiteSpace(Kind)
        ? Name ?? string.Empty
        : $"{Name} [{Kind}]";
}

public sealed class ArtifactsPayload
{
    public string? TemplatePath { get; set; }
    public string? DataSchemaPath { get; set; }
    public string? SchemaPath { get; set; }
    public string? DataPath { get; set; }
    public string? LaunchScriptPath { get; set; }
    public string? CmdPath { get; set; }
    public string? PackageManifestPath { get; set; }
    public string? SpecPath { get; set; }
}

public sealed class ReviewPayload
{
    public string? Status { get; set; }
    public string? Summary { get; set; }
    public IReadOnlyList<string>? Notes { get; set; }
}

public sealed record FactItem(string Title, string Value);
