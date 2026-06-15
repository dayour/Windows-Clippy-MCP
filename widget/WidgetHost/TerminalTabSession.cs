using Microsoft.Terminal.Wpf;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;

namespace WidgetHost;

internal sealed class TerminalTabSession : IDisposable
{
    private const short SmallTerminalFontSize = 10;
    private const short DefaultTerminalFontSize = 11;
    private const short LargeTerminalFontSize = 12;
    private const string DefaultCopilotCommand = "copilot";

    private readonly string _repoRoot;
    private readonly string _copilotConfigDir;
    private readonly TerminalControl _terminal;
    private readonly TaskCompletionSource<bool> _loaded =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private IWidgetTerminalConnection? _connection;
    private TerminalSessionCardSnapshot? _sessionCard;
    private short _appliedFontSize;
    private bool _disposed;

    public TerminalTabSession(
        string sessionId,
        string displayName,
        string repoRoot,
        string copilotConfigDir,
        TerminalControl terminal)
    {
        SessionId = sessionId;
        DisplayName = displayName;
        _repoRoot = repoRoot;
        _copilotConfigDir = copilotConfigDir;
        _terminal = terminal;

        _terminal.Loaded += OnTerminalLoaded;
        if (_terminal.IsLoaded)
        {
            _loaded.TrySetResult(true);
        }
    }

    public event EventHandler? Exited;

    public event EventHandler? MetadataChanged;

    public event EventHandler<CopilotEventArgs>? CopilotEventReceived;

    public Guid TabKey { get; } = Guid.NewGuid();

    public string SessionId { get; }

    public string DisplayName { get; }

    public string? GroupLabel { get; set; }

    public bool IsReady { get; private set; }

    public string CardKind => "Terminal";

    public string Mode { get; set; } = "Agent";

    public string? AgentId { get; set; }

    public string ModelId { get; set; } = ModelCatalog.DefaultModelId;

    public WidgetToolSettings ToolSettings { get; set; } = new();

    public bool IsWaitingForResponse => _sessionCard?.WaitingForResponse ?? false;

    public string LatestPromptPreview => _sessionCard?.LatestPrompt ?? string.Empty;

    public string LatestToolSummary => _sessionCard?.LatestToolSummary ?? string.Empty;

    public string LastErrorMessage => _sessionCard?.LastError ?? string.Empty;

    public string LatestTranscriptPreview
    {
        get
        {
            if (_sessionCard is null)
            {
                return string.Empty;
            }

            if (!string.IsNullOrWhiteSpace(_sessionCard.LatestAssistantText))
            {
                return _sessionCard.LatestAssistantText;
            }

            if (!string.IsNullOrWhiteSpace(_sessionCard.LatestThoughtText))
            {
                return _sessionCard.LatestThoughtText;
            }

            return _sessionCard.LatestPlainText;
        }
    }

    public async Task StartAsync()
    {
        ThrowIfDisposed();
        await _loaded.Task;

        ApplyTheme();

        _connection = CreateConnection();
        _connection.Exited += OnConnectionExited;
        _connection.SessionCardUpdated += OnSessionCardUpdated;
        _connection.CopilotEventReceived += OnConnectionCopilotEvent;
        _terminal.Connection = _connection;
        IsReady = true;
        if (_connection is ConPtyConnection)
        {
            await BootstrapCopilotAsync();
        }
    }

    public void SendInput(string text)
    {
        ThrowIfDisposed();
        if (!IsReady || _connection is null || string.IsNullOrEmpty(text))
        {
            return;
        }

        var payload = text.EndsWith('\r') || text.EndsWith('\n')
            ? text
            : text + "\r";
        _connection.WriteInput(payload);
    }

    public void SubmitCommanderPrompt(string text)
    {
        ThrowIfDisposed();
        if (!IsReady || _connection is null || string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        var prompt = BuildCommanderPrompt(text);
        _connection.SubmitPrompt(prompt);
        _sessionCard = new TerminalSessionCardSnapshot
        {
            LatestPrompt = TruncatePreview(prompt),
            WaitingForResponse = true
        };
        MetadataChanged?.Invoke(this, EventArgs.Empty);
    }

    public CommanderDispatchResult TryDispatchCommanderPrompt(string text, bool force = false)
    {
        if (_disposed)
        {
            return CommanderDispatchResult.Disposed;
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            return CommanderDispatchResult.Empty;
        }

        if (!IsReady || _connection is null)
        {
            return CommanderDispatchResult.NotReady;
        }

        if (!force && IsWaitingForResponse)
        {
            return CommanderDispatchResult.Busy;
        }

        var prompt = BuildCommanderPrompt(text);
        _connection.SubmitPrompt(prompt);
        _sessionCard = new TerminalSessionCardSnapshot
        {
            LatestPrompt = TruncatePreview(prompt),
            WaitingForResponse = true
        };
        MetadataChanged?.Invoke(this, EventArgs.Empty);
        return CommanderDispatchResult.Delivered;
    }

    public void ResizeEmbeddedSurface()
    {
        if (_disposed || !_terminal.IsLoaded || _terminal.ActualWidth <= 0 || _terminal.ActualHeight <= 0)
        {
            return;
        }

        ApplyTheme();

        var size = new Size(_terminal.ActualWidth, _terminal.ActualHeight);
        if (size.Width <= 0 || size.Height <= 0)
        {
            return;
        }

        _ = _terminal.TriggerResize(size);
    }

    public void FocusEmbeddedSurface()
    {
        if (_disposed || !_terminal.IsLoaded)
        {
            return;
        }

        _terminal.Focus();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        IsReady = false;
        _terminal.Loaded -= OnTerminalLoaded;

        if (_connection is not null)
        {
            _connection.Exited -= OnConnectionExited;
            _connection.SessionCardUpdated -= OnSessionCardUpdated;
            _connection.CopilotEventReceived -= OnConnectionCopilotEvent;
            _connection.Close();
            _connection = null;
        }
    }

    private void ApplyTheme()
    {
        var fontSize = ResolveTerminalFontSize();
        if (_appliedFontSize == fontSize)
        {
            return;
        }

        var background = Color.FromRgb(0x1A, 0x1A, 0x2B);
        var foreground = Color.FromRgb(0xE8, 0xE8, 0xE8);
        var selection = Color.FromRgb(0x5B, 0x5F, 0xC7);

        var theme = new TerminalTheme
        {
            DefaultBackground = ToColorRef(background),
            DefaultForeground = ToColorRef(foreground),
            DefaultSelectionBackground = ToColorRef(selection),
            CursorStyle = CursorStyle.BlinkingBar,
            ColorTable =
            [
                0x0C0C0C, 0x1F0FC5, 0x0EA113, 0x009CC1,
                0xDA3700, 0x981788, 0xDD963A, 0xCCCCCC,
                0x767676, 0x5648E7, 0x0CC616, 0xA5F1F9,
                0xFF783B, 0x9E00B4, 0xD6D661, 0xF2F2F2
            ]
        };

        _terminal.SetTheme(theme, "Cascadia Code", fontSize, background);
        _appliedFontSize = fontSize;
    }

    private short ResolveTerminalFontSize()
    {
        var width = _terminal.ActualWidth;
        var height = _terminal.ActualHeight;

        if (width <= 0 || height <= 0)
        {
            return DefaultTerminalFontSize;
        }

        if (width < 460 || height < 360)
        {
            return SmallTerminalFontSize;
        }

        if (width < 720 || height < 560)
        {
            return DefaultTerminalFontSize;
        }

        return LargeTerminalFontSize;
    }

    private string BuildStartupCommandLine()
    {
        var shellExecutable = ResolveInteractiveShellExecutable();
        var shellArguments = new List<string>
        {
            shellExecutable,
            "-NoLogo",
            "-NoProfile"
        };

        return string.Join(" ", shellArguments.Select(CommandLineEncoder.Quote));
    }

    private string BuildCommanderPrompt(string promptText)
    {
        var trimmedPrompt = promptText.Trim();
        if (string.IsNullOrWhiteSpace(trimmedPrompt))
        {
            return string.Empty;
        }

        var lines = new List<string>();
        var isSlashCommand = trimmedPrompt.StartsWith("/", StringComparison.Ordinal);
        if (!isSlashCommand && string.Equals(Mode, "Plan", StringComparison.OrdinalIgnoreCase))
        {
            lines.Add("[[PLAN]]");
        }

        lines.Add(trimmedPrompt);
        return string.Join(Environment.NewLine, lines);
    }

    private static string TruncatePreview(string text, int maxLength = 240)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Length <= maxLength)
        {
            return text;
        }

        return text[..Math.Max(0, maxLength - 3)] + "...";
    }

    private IWidgetTerminalConnection CreateConnection()
    {
        if (string.Equals(Environment.GetEnvironmentVariable("CLIPPY_WIDGET_USE_NATIVE_CONPTY"), "1", StringComparison.Ordinal))
        {
            var commandLine = BuildStartupCommandLine();
            WidgetHostLogger.Log(
                $"Starting native terminal session {SessionId} ({DisplayName}) with native ConPTY fallback. Command={commandLine}");
            return new ConPtyConnection(commandLine, _repoRoot);
        }

        WidgetHostLogger.Log(
            $"Starting native terminal session {SessionId} ({DisplayName}) with bridge terminal transport.");
        return new BridgeTerminalConnection(
            _repoRoot,
            SessionId,
            DisplayName,
            _copilotConfigDir,
            AgentId,
            ModelId,
            Mode,
            ToolSettings);
    }

    private async Task BootstrapCopilotAsync()
    {
        await Task.Delay(250);
        if (_disposed || _connection is null)
        {
            return;
        }

        var bootstrapCommand = BuildCopilotBootstrapInput();
        WidgetHostLogger.Log($"Sending native terminal bootstrap input for session {SessionId}.");
        _connection.WriteInput(bootstrapCommand + "\r");
    }

    private string BuildCopilotBootstrapInput()
    {
        var builder = new StringBuilder();
        builder.Append("Set-Location -LiteralPath ");
        builder.Append(PowerShellEncoder.Quote(_repoRoot));
        builder.Append("; & ");
        builder.Append(PowerShellEncoder.Quote(DefaultCopilotCommand));

        foreach (var argument in BuildCopilotArguments())
        {
            builder.Append(' ');
            builder.Append(PowerShellEncoder.Quote(argument));
        }

        return builder.ToString();
    }

    private List<string> BuildCopilotArguments()
    {
        var arguments = new List<string>
        {
            $"--resume={SessionId}",
            "--config-dir",
            _copilotConfigDir,
            "--no-color",
            "--add-dir",
            _repoRoot
        };

        if (!string.IsNullOrWhiteSpace(ModelId))
        {
            arguments.Add("--model");
            arguments.Add(ModelId);
        }

        if (!string.IsNullOrWhiteSpace(AgentId))
        {
            arguments.Add("--agent");
            arguments.Add(AgentId);
        }

        if (ToolSettings.AllowAllTools)
        {
            arguments.Add("--allow-all-tools");
        }

        if (ToolSettings.AllowAllPaths)
        {
            arguments.Add("--allow-all-paths");
        }

        if (ToolSettings.AllowAllUrls)
        {
            arguments.Add("--allow-all-urls");
        }

        if (ToolSettings.Experimental)
        {
            arguments.Add("--experimental");
        }

        if (ToolSettings.Autopilot)
        {
            arguments.Add("--autopilot");
        }

        if (ToolSettings.EnableAllGitHubMcpTools)
        {
            arguments.Add("--enable-all-github-mcp-tools");
        }

        return arguments;
    }

    private static string ResolveInteractiveShellExecutable()
    {
        return FindExecutableOnPath("pwsh.exe")
            ?? FindExecutableOnPath("powershell.exe")
            ?? "pwsh.exe";
    }

    private static string? FindExecutableOnPath(string fileName)
    {
        var pathValue = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(pathValue))
        {
            return null;
        }

        foreach (var segment in pathValue.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var candidate = System.IO.Path.Combine(segment, fileName);
            if (System.IO.File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private void OnTerminalLoaded(object sender, RoutedEventArgs e)
    {
        _loaded.TrySetResult(true);
    }

    private void OnConnectionExited(object? sender, int? exitCode)
    {
        IsReady = false;
        _sessionCard = _sessionCard is null
            ? new TerminalSessionCardSnapshot { WaitingForResponse = false }
            : new TerminalSessionCardSnapshot
            {
                LatestPrompt = _sessionCard.LatestPrompt,
                LatestAssistantText = _sessionCard.LatestAssistantText,
                LatestThoughtText = _sessionCard.LatestThoughtText,
                LatestPlainText = _sessionCard.LatestPlainText,
                LastError = _sessionCard.LastError,
                LatestToolSummary = _sessionCard.LatestToolSummary,
                WaitingForResponse = false
            };
        MetadataChanged?.Invoke(this, EventArgs.Empty);
        WidgetHostLogger.Log($"Native terminal exited. Session={SessionId}; ExitCode={exitCode?.ToString() ?? "(unknown)"}");
        Exited?.Invoke(this, EventArgs.Empty);
    }

    private void OnSessionCardUpdated(object? sender, TerminalSessionCardSnapshot snapshot)
    {
        if (_disposed)
        {
            return;
        }

        if (_terminal.Dispatcher.CheckAccess())
        {
            ApplySessionCard(snapshot);
            return;
        }

        _terminal.Dispatcher.BeginInvoke(() => ApplySessionCard(snapshot));
    }

    private void ApplySessionCard(TerminalSessionCardSnapshot snapshot)
    {
        if (_disposed)
        {
            return;
        }

        _sessionCard = snapshot;
        MetadataChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnConnectionCopilotEvent(object? sender, CopilotEventArgs e)
    {
        if (_disposed)
        {
            return;
        }

        CopilotEventReceived?.Invoke(this, e);
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private static uint ToColorRef(Color color)
    {
        return (uint)(color.R | (color.G << 8) | (color.B << 16));
    }
}

internal static class CommandLineEncoder
{
    public static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (!value.Any(static ch => char.IsWhiteSpace(ch) || ch == '"'))
        {
            return value;
        }

        var builder = new StringBuilder(value.Length + 2);
        builder.Append('"');

        var backslashCount = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashCount += 1;
                continue;
            }

            if (character == '"')
            {
                builder.Append('\\', backslashCount * 2 + 1);
                builder.Append(character);
                backslashCount = 0;
                continue;
            }

            if (backslashCount > 0)
            {
                builder.Append('\\', backslashCount);
                backslashCount = 0;
            }

            builder.Append(character);
        }

        if (backslashCount > 0)
        {
            builder.Append('\\', backslashCount * 2);
        }

        builder.Append('"');
        return builder.ToString();
    }
}

internal static class PowerShellEncoder
{
    public static string Quote(string value)
    {
        return $"'{value.Replace("'", "''")}'";
    }
}
