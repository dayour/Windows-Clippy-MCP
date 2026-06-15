using Microsoft.Terminal.Wpf;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetHost;

internal interface IWidgetTerminalConnection : ITerminalConnection, IDisposable
{
    event EventHandler<int?>? Exited;
    event EventHandler<TerminalSessionCardSnapshot>? SessionCardUpdated;
    event EventHandler<CopilotEventArgs>? CopilotEventReceived;

    void SubmitPrompt(string promptText);
}

internal sealed class CopilotEventArgs : EventArgs
{
    public CopilotEventArgs(string? tabId, string? sessionId, string eventType, System.Text.Json.JsonElement rawEvent)
    {
        TabId = tabId;
        SessionId = sessionId;
        EventType = eventType;
        RawEvent = rawEvent;
    }

    public string? TabId { get; }
    public string? SessionId { get; }
    public string EventType { get; }
    public System.Text.Json.JsonElement RawEvent { get; }
}

internal sealed class TerminalSessionCardSnapshot
{
    public string LatestPrompt { get; init; } = string.Empty;

    public string LatestAssistantText { get; init; } = string.Empty;

    public string LatestThoughtText { get; init; } = string.Empty;

    public string LatestPlainText { get; init; } = string.Empty;

    public string LastError { get; init; } = string.Empty;

    public string LatestToolSummary { get; init; } = string.Empty;

    public bool WaitingForResponse { get; init; }
}

internal enum BridgeRuntime
{
    Copilot,
    Terminal
}

internal sealed class BridgeTerminalConnection : IWidgetTerminalConnection
{
    private readonly object _gate = new();
    private readonly string _repoRoot;
    private readonly string _launchSummary;
    private readonly ProcessStartInfo _startInfo;
    private readonly BridgeRuntime _runtime;

    private Process? _hostProcess;
    private StreamWriter? _stdinWriter;
    private CancellationTokenSource? _pumpCancellation;
    private Task? _stdoutTask;
    private Task? _stderrTask;
    private Task? _exitTask;
    private bool _started;
    private bool _closed;
    private int _exitRaised;

    public BridgeTerminalConnection(
        string repoRoot,
        string sessionId,
        string displayName,
        string configDirectory,
        string? agentId,
        string? modelId,
        string? mode,
        WidgetToolSettings toolSettings)
        : this(
            repoRoot,
            sessionId,
            displayName,
            configDirectory,
            agentId,
            modelId,
            mode,
            toolSettings,
            BridgeRuntime.Terminal)
    {
    }

    public BridgeTerminalConnection(
        string repoRoot,
        string sessionId,
        string displayName,
        string configDirectory,
        string? agentId,
        string? modelId,
        string? mode,
        WidgetToolSettings toolSettings,
        BridgeRuntime runtime)
    {
        _repoRoot = repoRoot;
        _runtime = runtime;
        _startInfo = BuildStartInfo(
            repoRoot,
            sessionId,
            displayName,
            configDirectory,
            agentId,
            modelId,
            mode,
            toolSettings,
            runtime,
            out _launchSummary);
    }

    public event EventHandler<TerminalOutputEventArgs>? TerminalOutput;

    public event EventHandler<int?>? Exited;

    public event EventHandler<TerminalSessionCardSnapshot>? SessionCardUpdated;

    public event EventHandler<CopilotEventArgs>? CopilotEventReceived;

    public void Start()
    {
        lock (_gate)
        {
            ThrowIfClosed();
            if (_started)
            {
                return;
            }

            _started = true;
            try
            {
                _hostProcess = new Process
                {
                    StartInfo = _startInfo,
                    EnableRaisingEvents = false
                };

                if (!_hostProcess.Start())
                {
                    throw new InvalidOperationException("Bridge terminal host process did not start.");
                }

                _stdinWriter = _hostProcess.StandardInput;
                _stdinWriter.AutoFlush = true;

                _pumpCancellation = new CancellationTokenSource();
                _stdoutTask = Task.Run(() => PumpStdoutAsync(_pumpCancellation.Token));
                _stderrTask = Task.Run(() => PumpStderrAsync(_pumpCancellation.Token));
                _exitTask = Task.Run(() => WaitForHostExitAsync(_pumpCancellation.Token));

                WidgetHostLogger.Log(
                    $"Bridge terminal host started. PID={_hostProcess.Id}; Repo={_repoRoot}; Launch={_launchSummary}");
            }
            catch (Exception ex)
            {
                WidgetHostLogger.Log($"Bridge terminal host startup failed. Launch={_launchSummary}; Error={ex}");
                CleanupStartupFailure();
                throw;
            }
        }
    }

    public void WriteInput(string data)
    {
        if (string.IsNullOrEmpty(data))
        {
            return;
        }

        SendBridgeCommand(
            "session.write",
            new Dictionary<string, object?>
            {
                ["text"] = data
            });
    }

    public void SubmitPrompt(string promptText)
    {
        if (string.IsNullOrWhiteSpace(promptText))
        {
            return;
        }

        SendBridgeCommand(
            "session.input",
            new Dictionary<string, object?>
            {
                ["text"] = promptText
            });
    }

    public void Resize(uint rows, uint columns)
    {
        if (rows == 0 || columns == 0)
        {
            return;
        }

        SendBridgeCommand(
            "session.resize",
            new Dictionary<string, object?>
            {
                ["rows"] = (int)rows,
                ["cols"] = (int)columns
            });
    }

    public void Close()
    {
        Dispose();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_closed)
            {
                return;
            }

            _closed = true;
        }

        WidgetHostLogger.Log($"Closing bridge terminal host. PID={_hostProcess?.Id ?? 0}");

        TrySendShutdown();
        _pumpCancellation?.Cancel();

        TryDispose(_stdinWriter);

        if (_hostProcess is not null)
        {
            try
            {
                if (!_hostProcess.HasExited)
                {
                    if (!_hostProcess.WaitForExit(1500))
                    {
                        _hostProcess.Kill(entireProcessTree: true);
                        _hostProcess.WaitForExit(1500);
                    }
                }
            }
            catch (Exception ex)
            {
                WidgetHostLogger.Log($"Bridge terminal host shutdown encountered an error. PID={_hostProcess.Id}; Error={ex.Message}");
            }
        }

        TryDispose(_hostProcess);
        TryDispose(_pumpCancellation);
    }

    private static ProcessStartInfo BuildStartInfo(
        string repoRoot,
        string sessionId,
        string displayName,
        string configDirectory,
        string? agentId,
        string? modelId,
        string? mode,
        WidgetToolSettings toolSettings,
        BridgeRuntime runtime,
        out string launchSummary)
    {
        var scriptPath = Path.Combine(repoRoot, "scripts", "terminal-session-host.js");
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("Bridge terminal host script was not found.", scriptPath);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = FindExecutableOnPath("node.exe") ?? "node",
            WorkingDirectory = repoRoot,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            CreateNoWindow = true
        };

        startInfo.ArgumentList.Add(scriptPath);
        startInfo.ArgumentList.Add("--bridge-stdio");
        startInfo.ArgumentList.Add("--runtime");
        startInfo.ArgumentList.Add(runtime == BridgeRuntime.Terminal ? "terminal" : "copilot");
        if (runtime == BridgeRuntime.Terminal)
        {
            startInfo.ArgumentList.Add("--shell");
            startInfo.ArgumentList.Add("copilot");
        }
        startInfo.ArgumentList.Add("--session-id");
        startInfo.ArgumentList.Add(sessionId);
        startInfo.ArgumentList.Add("--display-name");
        startInfo.ArgumentList.Add(displayName);
        startInfo.ArgumentList.Add("--config-dir");
        startInfo.ArgumentList.Add(configDirectory);
        startInfo.ArgumentList.Add("--working-directory");
        startInfo.ArgumentList.Add(repoRoot);

        if (!string.IsNullOrWhiteSpace(agentId))
        {
            startInfo.ArgumentList.Add("--agent");
            startInfo.ArgumentList.Add(agentId);
        }

        if (!string.IsNullOrWhiteSpace(modelId))
        {
            startInfo.ArgumentList.Add("--model");
            startInfo.ArgumentList.Add(modelId);
        }

        if (!string.IsNullOrWhiteSpace(mode))
        {
            startInfo.ArgumentList.Add("--mode");
            startInfo.ArgumentList.Add(mode);
        }

        if (toolSettings.AllowAllTools)
        {
            startInfo.ArgumentList.Add("--allow-all-tools");
        }

        if (toolSettings.AllowAllPaths)
        {
            startInfo.ArgumentList.Add("--allow-all-paths");
        }

        if (toolSettings.AllowAllUrls)
        {
            startInfo.ArgumentList.Add("--allow-all-urls");
        }

        if (toolSettings.Experimental)
        {
            startInfo.ArgumentList.Add("--experimental");
        }

        if (toolSettings.Autopilot)
        {
            startInfo.ArgumentList.Add("--autopilot");
        }

        if (toolSettings.EnableAllGitHubMcpTools)
        {
            startInfo.ArgumentList.Add("--enable-all-github-mcp-tools");
        }

        launchSummary = $"{startInfo.FileName} {string.Join(" ", startInfo.ArgumentList)}";
        return startInfo;
    }

    private async Task PumpStdoutAsync(CancellationToken cancellationToken)
    {
        if (_hostProcess is null)
        {
            return;
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            string? line;
            try
            {
                line = await _hostProcess.StandardOutput.ReadLineAsync();
            }
            catch (ObjectDisposedException) when (_closed)
            {
                break;
            }
            catch (IOException) when (_closed)
            {
                break;
            }

            if (line is null)
            {
                break;
            }

            HandleBridgeOutput(line);
        }
    }

    private async Task PumpStderrAsync(CancellationToken cancellationToken)
    {
        if (_hostProcess is null)
        {
            return;
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            string? line;
            try
            {
                line = await _hostProcess.StandardError.ReadLineAsync();
            }
            catch (ObjectDisposedException) when (_closed)
            {
                break;
            }
            catch (IOException) when (_closed)
            {
                break;
            }

            if (line is null)
            {
                break;
            }

            WidgetHostLogger.Log($"Bridge terminal host stderr. PID={_hostProcess.Id}; {line}");
        }
    }

    private async Task WaitForHostExitAsync(CancellationToken cancellationToken)
    {
        if (_hostProcess is null)
        {
            return;
        }

        try
        {
            await _hostProcess.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        RaiseExited(_hostProcess.ExitCode, $"Bridge terminal host exited. PID={_hostProcess.Id}; ExitCode={_hostProcess.ExitCode}");
    }

    private void HandleBridgeOutput(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("type", out var typeElement))
            {
                WidgetHostLogger.Log($"Bridge terminal host emitted a message without a type. Line={line}");
                return;
            }

            var type = typeElement.GetString();
            var payload = root.TryGetProperty("payload", out var payloadElement)
                ? payloadElement
                : default;

            switch (type)
            {
                case "session.output":
                    if (TryGetString(payload, "text", out var text) && !string.IsNullOrEmpty(text))
                    {
                        TerminalOutput?.Invoke(this, new TerminalOutputEventArgs(text));
                    }
                    break;

                case "session.exit":
                    if (_runtime == BridgeRuntime.Copilot)
                    {
                        WidgetHostLogger.Log($"Bridge prompt child exited. ExitCode={TryGetInt(payload, "exitCode")?.ToString() ?? "(unknown)"}");
                    }
                    else
                    {
                        RaiseExited(TryGetInt(payload, "exitCode"), $"Bridge terminal session exited. ExitCode={TryGetInt(payload, "exitCode")?.ToString() ?? "(unknown)"}");
                    }
                    break;

                case "session.error":
                case "host.error":
                    var errorMessage = TryGetString(payload, "message", out var message)
                        ? message
                        : "(unknown)";
                    WidgetHostLogger.Log(
                        $"Bridge terminal host reported {type}. SessionError={errorMessage}");
                    break;

                case "session.ready":
                case "host.ready":
                    WidgetHostLogger.Log($"Bridge terminal host signaled {type}.");
                    break;

                case "terminal.card":
                    var snapshot = TryParseTerminalCardSnapshot(payload);
                    if (snapshot is not null)
                    {
                        SessionCardUpdated?.Invoke(this, snapshot);
                    }
                    break;

                case "copilot.event":
                    try
                    {
                        string? tabId = TryGetString(payload, "tabId", out var t) ? t : null;
                        string? sessionId = TryGetString(payload, "sessionId", out var s) ? s : null;
                        if (payload.ValueKind == JsonValueKind.Object &&
                            payload.TryGetProperty("event", out var eventElement) &&
                            eventElement.ValueKind == JsonValueKind.Object &&
                            eventElement.TryGetProperty("type", out var evtTypeElement))
                        {
                            var evtType = evtTypeElement.GetString();
                            if (!string.IsNullOrEmpty(evtType))
                            {
                                CopilotEventReceived?.Invoke(
                                    this,
                                    new CopilotEventArgs(tabId, sessionId, evtType, eventElement.Clone()));
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        WidgetHostLogger.Log($"Failed to forward copilot.event: {ex.Message}");
                    }
                    break;
            }
        }
        catch (JsonException)
        {
            WidgetHostLogger.Log($"Bridge terminal host emitted non-JSON output: {line}");
        }
    }

    private void SendBridgeCommand(string command, Dictionary<string, object?> payload)
    {
        string? failureMessage = null;
        int? exitCode = null;

        lock (_gate)
        {
            if (_closed || _stdinWriter is null)
            {
                return;
            }

            payload["command"] = command;
            var envelope = new Dictionary<string, object?>
            {
                ["type"] = "host.command",
                ["payload"] = payload
            };

            try
            {
                _stdinWriter.WriteLine(JsonSerializer.Serialize(envelope));
                _stdinWriter.Flush();
            }
            catch (IOException ex)
            {
                failureMessage = $"Bridge terminal host stdin write failed for command '{command}': {ex.Message}";
            }
            catch (ObjectDisposedException ex)
            {
                failureMessage = $"Bridge terminal host stdin was disposed while sending '{command}': {ex.Message}";
            }

            if (failureMessage is not null)
            {
                exitCode = TryGetHostExitCode();
                TryDispose(_stdinWriter);
                _stdinWriter = null;
            }
        }

        if (failureMessage is not null)
        {
            RaiseExited(exitCode, failureMessage);
        }
    }

    private int? TryGetHostExitCode()
    {
        if (_hostProcess is null)
        {
            return null;
        }

        try
        {
            return _hostProcess.HasExited ? _hostProcess.ExitCode : null;
        }
        catch
        {
            return null;
        }
    }

    private void TrySendShutdown()
    {
        try
        {
            SendBridgeCommand("host.shutdown", new Dictionary<string, object?>());
        }
        catch
        {
        }
    }

    private void RaiseExited(int? exitCode, string logMessage)
    {
        if (Interlocked.Exchange(ref _exitRaised, 1) != 0)
        {
            return;
        }

        WidgetHostLogger.Log(logMessage);
        Exited?.Invoke(this, exitCode);
    }

    private void CleanupStartupFailure()
    {
        TryDispose(_stdinWriter);
        TryDispose(_hostProcess);
        TryDispose(_pumpCancellation);
    }

    private void ThrowIfClosed()
    {
        ObjectDisposedException.ThrowIf(_closed, this);
    }

    private static bool TryGetString(JsonElement payload, string propertyName, out string? value)
    {
        value = null;
        if (payload.ValueKind != JsonValueKind.Object ||
            !payload.TryGetProperty(propertyName, out var property) ||
            property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString();
        return true;
    }

    private static string GetNestedString(JsonElement payload, params string[] path)
    {
        var current = payload;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return string.Empty;
            }
        }

        return current.ValueKind == JsonValueKind.String
            ? current.GetString() ?? string.Empty
            : string.Empty;
    }

    private static bool GetNestedBoolean(JsonElement payload, params string[] path)
    {
        var current = payload;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return false;
            }
        }

        if (current.ValueKind == JsonValueKind.True)
        {
            return true;
        }

        if (current.ValueKind == JsonValueKind.False)
        {
            return false;
        }

        return current.ValueKind == JsonValueKind.String &&
               bool.TryParse(current.GetString(), out var parsed) &&
               parsed;
    }

    private static string BuildLatestToolSummary(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object ||
            !payload.TryGetProperty("data", out var data) ||
            data.ValueKind != JsonValueKind.Object ||
            !data.TryGetProperty("recentTools", out var tools) ||
            tools.ValueKind != JsonValueKind.Array)
        {
            return string.Empty;
        }

        foreach (var tool in tools.EnumerateArray())
        {
            if (tool.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            var toolName = GetNestedString(tool, "name");
            if (string.IsNullOrWhiteSpace(toolName))
            {
                continue;
            }

            var status = GetNestedString(tool, "statusLabel");
            return string.IsNullOrWhiteSpace(status)
                ? toolName
                : $"{toolName} [{status}]";
        }

        return string.Empty;
    }

    private static TerminalSessionCardSnapshot? TryParseTerminalCardSnapshot(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object || !payload.TryGetProperty("data", out _))
        {
            return null;
        }

        return new TerminalSessionCardSnapshot
        {
            LatestPrompt = GetNestedString(payload, "data", "transcript", "latestUserPrompt"),
            LatestAssistantText = GetNestedString(payload, "data", "transcript", "latestAssistantText"),
            LatestThoughtText = GetNestedString(payload, "data", "transcript", "latestThoughtText"),
            LatestPlainText = GetNestedString(payload, "data", "transcript", "latestPlainText"),
            LastError = GetNestedString(payload, "data", "transcript", "lastError"),
            LatestToolSummary = BuildLatestToolSummary(payload),
            WaitingForResponse = GetNestedBoolean(payload, "data", "transcript", "waitingForResponse")
        };
    }

    private static int? TryGetInt(JsonElement payload, string propertyName)
    {
        if (payload.ValueKind == JsonValueKind.Object &&
            payload.TryGetProperty(propertyName, out var property) &&
            property.ValueKind == JsonValueKind.Number &&
            property.TryGetInt32(out var value))
        {
            return value;
        }

        return null;
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
            var candidate = Path.Combine(segment, fileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static void TryDispose(IDisposable? disposable)
    {
        disposable?.Dispose();
    }
}
