using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetHost;

internal sealed class CommanderTranscriptEntry
{
    public CommanderTranscriptEntry(string role, string content, DateTimeOffset timestamp)
    {
        Role = role;
        Content = content;
        Timestamp = timestamp;
    }

    public string Role { get; }

    public string Content { get; set; }

    public DateTimeOffset Timestamp { get; set; }
}

internal readonly record struct CommanderHistoryView(string Role, string Text, DateTimeOffset At);

internal sealed class CommanderSession : IDisposable
{
    private const int MaxHistoryEntries = 24;

    private readonly string _repoRoot;
    private readonly string _copilotConfigDir;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly List<CommanderTranscriptEntry> _history = [];
    private IWidgetTerminalConnection? _connection;
    private TerminalSessionCardSnapshot? _sessionCard;
    private CommanderTranscriptEntry? _pendingReasoning;
    private CommanderTranscriptEntry? _pendingAssistant;
    private string? _completedAssistantTextForCurrentTurn;
    private bool _disposed;

    public CommanderSession(string repoRoot, string copilotConfigDir)
    {
        _repoRoot = repoRoot;
        _copilotConfigDir = copilotConfigDir;
    }

    public event EventHandler? MetadataChanged;

    public event EventHandler? Exited;

    public event EventHandler<string>? AssistantTurnCompleted;

    public string SessionId { get; } = Guid.NewGuid().ToString();

    public string DisplayName { get; } = "Clippy Commander";

    public bool IsReady { get; private set; }

    public string Mode { get; set; } = "Agent";

    public string? AgentId { get; set; }

    public string ModelId { get; set; } = ModelCatalog.DefaultModelId;

    public WidgetToolSettings ToolSettings { get; set; } = new();

    public bool IsWaitingForResponse => _sessionCard?.WaitingForResponse ?? false;

    public string LatestPromptPreview => _sessionCard?.LatestPrompt ?? string.Empty;

    public string LatestToolSummary => _sessionCard?.LatestToolSummary ?? string.Empty;

    public string LastErrorMessage => _sessionCard?.LastError ?? string.Empty;

    public int HistoryCount
    {
        get
        {
            lock (_history)
            {
                return _history.Count;
            }
        }
    }

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

    public async Task EnsureStartedAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_connection is not null && IsReady)
            {
                return;
            }

            if (_connection is not null && !IsReady)
            {
                DisposeConnection();
            }

            var connection = CreateConnection();
            connection.Exited += OnConnectionExited;
            connection.SessionCardUpdated += OnSessionCardUpdated;
            connection.CopilotEventReceived += OnConnectionCopilotEvent;
            connection.Start();
            _connection = connection;
            IsReady = true;
        }
        finally
        {
            _lifecycleGate.Release();
        }

        MetadataChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task RestartAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            DisposeConnection();

            var connection = CreateConnection();
            connection.Exited += OnConnectionExited;
            connection.SessionCardUpdated += OnSessionCardUpdated;
            connection.CopilotEventReceived += OnConnectionCopilotEvent;
            connection.Start();
            _connection = connection;
            IsReady = true;
        }
        finally
        {
            _lifecycleGate.Release();
        }

        MetadataChanged?.Invoke(this, EventArgs.Empty);
    }

    public CommanderDispatchResult TrySubmitPrompt(string text)
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

        if (IsWaitingForResponse)
        {
            return CommanderDispatchResult.Busy;
        }

        var prompt = BuildCommanderPrompt(text);
        _completedAssistantTextForCurrentTurn = null;
        _connection.SubmitPrompt(prompt);
        _sessionCard = new TerminalSessionCardSnapshot
        {
            LatestPrompt = TruncatePreview(prompt),
            WaitingForResponse = true
        };
        MetadataChanged?.Invoke(this, EventArgs.Empty);
        return CommanderDispatchResult.Delivered;
    }

    public string BuildHistorySummary(int maxEntries = 6)
    {
        CommanderTranscriptEntry[] snapshot;
        lock (_history)
        {
            snapshot = _history
                .TakeLast(Math.Max(1, maxEntries))
                .ToArray();
        }

        if (snapshot.Length == 0)
        {
            return "No Commander history yet.";
        }

        return string.Join(
            "  ",
            snapshot.Select(entry => $"{entry.Role}: {entry.Content}"));
    }

    /// <summary>
    /// L4-1 — structured transcript snapshot for publication through
    /// FleetStateSnapshot.Commander. Role/text/timestamp only so the
    /// JSON surface stays minimal and portable across MCP Apps hosts.
    /// </summary>
    public IReadOnlyList<CommanderHistoryView> BuildHistoryEntries(int maxEntries = 24)
    {
        CommanderTranscriptEntry[] snapshot;
        lock (_history)
        {
            snapshot = _history
                .TakeLast(Math.Max(0, maxEntries))
                .ToArray();
        }

        return snapshot
            .Select(e => new CommanderHistoryView(e.Role ?? string.Empty, e.Content ?? string.Empty, e.Timestamp))
            .ToArray();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        DisposeConnection();
        _lifecycleGate.Dispose();
    }

    private IWidgetTerminalConnection CreateConnection()
    {
        return new BridgeTerminalConnection(
            _repoRoot,
            SessionId,
            DisplayName,
            _copilotConfigDir,
            AgentId,
            ModelId,
            Mode,
            ToolSettings,
            BridgeRuntime.Copilot);
    }

    private void DisposeConnection()
    {
        IsReady = false;
        ClearEphemeralState();

        if (_connection is null)
        {
            return;
        }

        _connection.Exited -= OnConnectionExited;
        _connection.SessionCardUpdated -= OnSessionCardUpdated;
        _connection.CopilotEventReceived -= OnConnectionCopilotEvent;
        _connection.Close();
        _connection = null;
    }

    private void OnConnectionExited(object? sender, int? e)
    {
        IsReady = false;
        ClearEphemeralState();
        MetadataChanged?.Invoke(this, EventArgs.Empty);
        Exited?.Invoke(this, EventArgs.Empty);
    }

    private void ClearEphemeralState()
    {
        _sessionCard = null;
        _pendingAssistant = null;
        _pendingReasoning = null;
    }

    private void OnSessionCardUpdated(object? sender, TerminalSessionCardSnapshot snapshot)
    {
        if (_disposed)
        {
            return;
        }

        var previous = _sessionCard;
        _sessionCard = snapshot;
        if (previous?.WaitingForResponse == true && !snapshot.WaitingForResponse)
        {
            var completionText = SelectAssistantCompletionText(snapshot);
            if (string.IsNullOrWhiteSpace(completionText))
            {
                WidgetHostLogger.Log(
                    $"Commander terminal-card turn ended without assistant text. errorChars={snapshot.LastError.Length}; toolChars={snapshot.LatestToolSummary.Length}");
            }
            else
            {
                PublishAssistantTurnCompleted(completionText, "terminal-card");
            }
        }
        MetadataChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnConnectionCopilotEvent(object? sender, CopilotEventArgs e)
    {
        if (_disposed)
        {
            return;
        }

        ApplyTranscriptEvent(e);
        MetadataChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ApplyTranscriptEvent(CopilotEventArgs e)
    {
        switch (e.EventType)
        {
            case "user.message":
            {
                var content = TryGetEventDataString(e.RawEvent, "content");
                if (!string.IsNullOrWhiteSpace(content))
                {
                    AddHistoryEntry("User", content, TryGetEventTimestamp(e.RawEvent));
                    _pendingAssistant = null;
                    _pendingReasoning = null;
                    _completedAssistantTextForCurrentTurn = null;
                }

                break;
            }

            case "assistant.reasoning_delta":
            {
                var delta = TryGetEventDataString(e.RawEvent, "deltaContent");
                AppendStreamingEntry(ref _pendingReasoning, "Reasoning", delta, TryGetEventTimestamp(e.RawEvent));
                break;
            }

            case "assistant.reasoning":
            {
                var content = TryGetEventDataString(e.RawEvent, "content");
                SetStreamingEntry(ref _pendingReasoning, "Reasoning", content, TryGetEventTimestamp(e.RawEvent));
                break;
            }

            case "assistant.message_delta":
            {
                var delta = TryGetEventDataString(e.RawEvent, "deltaContent");
                AppendStreamingEntry(ref _pendingAssistant, "Assistant", delta, TryGetEventTimestamp(e.RawEvent));
                break;
            }

            case "assistant.message":
            {
                var content = TryGetEventDataString(e.RawEvent, "content");
                SetStreamingEntry(ref _pendingAssistant, "Assistant", content, TryGetEventTimestamp(e.RawEvent));
                break;
            }

            case "assistant.turn_end":
            case "result":
                {
                    var finalText = _pendingAssistant?.Content;
                    _pendingAssistant = null;
                    _pendingReasoning = null;
                    if (!string.IsNullOrWhiteSpace(finalText))
                    {
                        PublishAssistantTurnCompleted(finalText!, "copilot-event");
                    }
                    else
                    {
                        WidgetHostLogger.Log($"Commander copilot event '{e.EventType}' ended without pending assistant text.");
                    }
                    break;
                }
        }
    }

    private void AddHistoryEntry(string role, string content, DateTimeOffset timestamp)
    {
        var normalized = NormalizeHistoryText(content);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return;
        }

        lock (_history)
        {
            _history.Add(new CommanderTranscriptEntry(role, normalized, timestamp));
            while (_history.Count > MaxHistoryEntries)
            {
                _history.RemoveAt(0);
            }
        }
    }

    private void AppendStreamingEntry(
        ref CommanderTranscriptEntry? entry,
        string role,
        string content,
        DateTimeOffset timestamp)
    {
        var normalized = NormalizeHistoryText(content);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return;
        }

        lock (_history)
        {
            if (entry is null || !_history.Contains(entry))
            {
                entry = new CommanderTranscriptEntry(role, normalized, timestamp);
                _history.Add(entry);
            }
            else
            {
                entry.Content = NormalizeHistoryText($"{entry.Content}\n{normalized}");
                entry.Timestamp = timestamp;
            }

            while (_history.Count > MaxHistoryEntries)
            {
                if (ReferenceEquals(_history[0], entry))
                {
                    break;
                }

                _history.RemoveAt(0);
            }
        }
    }

    private void SetStreamingEntry(
        ref CommanderTranscriptEntry? entry,
        string role,
        string content,
        DateTimeOffset timestamp)
    {
        var normalized = NormalizeHistoryText(content);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return;
        }

        lock (_history)
        {
            if (entry is null || !_history.Contains(entry))
            {
                entry = new CommanderTranscriptEntry(role, normalized, timestamp);
                _history.Add(entry);
            }
            else
            {
                entry.Content = normalized;
                entry.Timestamp = timestamp;
            }

            while (_history.Count > MaxHistoryEntries)
            {
                if (ReferenceEquals(_history[0], entry))
                {
                    break;
                }

                _history.RemoveAt(0);
            }
        }
    }

    private void PublishAssistantTurnCompleted(string text, string source)
    {
        var normalized = NormalizeHistoryText(text);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return;
        }

        if (string.Equals(_completedAssistantTextForCurrentTurn, normalized, StringComparison.Ordinal))
        {
            return;
        }

        _completedAssistantTextForCurrentTurn = normalized;
        WidgetHostLogger.Log($"Commander assistant turn completed via {source}; chars={normalized.Length}");
        AssistantTurnCompleted?.Invoke(this, normalized);
    }

    private static string SelectAssistantCompletionText(TerminalSessionCardSnapshot snapshot)
    {
        if (!string.IsNullOrWhiteSpace(snapshot.LatestAssistantText))
        {
            return snapshot.LatestAssistantText;
        }

        if (!string.IsNullOrWhiteSpace(snapshot.LatestPlainText))
        {
            return snapshot.LatestPlainText;
        }

        return string.Empty;
    }

    private string BuildCommanderPrompt(string promptText)
    {
        var trimmedPrompt = promptText.Trim();
        return string.Equals(Mode, "Plan", StringComparison.OrdinalIgnoreCase)
            ? $"[[PLAN]] {trimmedPrompt}"
            : trimmedPrompt;
    }

    private static string TruncatePreview(string text, int maxLength = 240)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Length <= maxLength)
        {
            return text;
        }

        return text[..Math.Max(0, maxLength - 3)] + "...";
    }

    private static string NormalizeHistoryText(string value)
    {
        return string.Join(
            '\n',
            value
                .Replace("\r", string.Empty, StringComparison.Ordinal)
                .Split('\n')
                .Select(static line => line.TrimEnd()))
            .Trim();
    }

    private static string TryGetEventDataString(JsonElement rawEvent, string propertyName)
    {
        if (rawEvent.ValueKind == JsonValueKind.Object &&
            rawEvent.TryGetProperty("data", out var dataElement) &&
            dataElement.ValueKind == JsonValueKind.Object &&
            dataElement.TryGetProperty(propertyName, out var propertyElement) &&
            propertyElement.ValueKind == JsonValueKind.String)
        {
            return propertyElement.GetString() ?? string.Empty;
        }

        return string.Empty;
    }

    private static DateTimeOffset TryGetEventTimestamp(JsonElement rawEvent)
    {
        if (rawEvent.ValueKind == JsonValueKind.Object &&
            rawEvent.TryGetProperty("timestamp", out var timestampElement) &&
            timestampElement.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(
                timestampElement.GetString(),
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal,
                out var timestamp))
        {
            return timestamp;
        }

        return DateTimeOffset.UtcNow;
    }
}
