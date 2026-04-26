// L3-3 / L3-5: MCP Apps bridge for the Windows Clippy widget.
//
// Owns a Node subprocess running `node src/mcp-apps/server.mjs` on stdio
// and speaks the MCP JSON-RPC 2.0 protocol to it as a client. The widget
// hosts a private in-process MCP Apps client so the WebView2 View renderer
// (McpAppsHost) never talks to the server directly.
//
// Principal policy (North Star):
//   Every tools/call originating from the widget MUST carry
//   _meta.clippy = { principal: "clippy", session: <commanderSessionId> }.
//   L3-6 will land server-side enforcement; until then this class always
//   emits the field so the enforcement layer can be turned on without
//   changing any call sites.
//
// Fleet state flow (L3-5):
//   CommanderHub event -> MainWindow.BuildFleetSnapshot ->
//     McpAppsBridge.PublishFleetStateAsync(snapshot) ->
//       serialize JSON -> write %LOCALAPPDATA%\WindowsClippy\fleet-state.json
//     McpAppsHost.PostResourceListChangedAsync() ->
//       View re-fetches via tools/call clippy.fleet-status through
//       McpAppsHost, which brokers the request to this bridge.
//
// The full push-notification wire (server emits
// notifications/resources/list_changed back to this client) is reserved
// for a later todo; see the L3 integration report section
// "L3-5 notification wire" for the delta.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetHost;

internal sealed class McpAppsBridge : IAsyncDisposable
{
    private const string ProtocolVersion = "2026-01-26";

    private readonly string _commanderSessionId;
    private readonly Func<FleetStateSnapshot> _fleetStateProvider;
    private readonly string _repoRoot;
    private readonly string _fleetStatePath;
    private readonly string _commanderIntentsPath;
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonDocument>> _pending = new();
    private readonly ConcurrentDictionary<string, byte> _processedIntentIds = new();
    private readonly SemaphoreSlim _stdinGate = new(1, 1);
    private Process? _node;
    private Task? _readerTask;
    private Task? _errReaderTask;
    private Task? _intentsWatcherTask;
    private long _intentsOffset;
    private CancellationTokenSource? _readerCts;
    private int _nextId;
    private bool _started;
    private bool _disposed;

    public McpAppsBridge(string commanderSessionId, Func<FleetStateSnapshot> fleetStateProvider, string repoRoot)
    {
        _commanderSessionId = commanderSessionId ?? throw new ArgumentNullException(nameof(commanderSessionId));
        _fleetStateProvider = fleetStateProvider ?? throw new ArgumentNullException(nameof(fleetStateProvider));
        _repoRoot = repoRoot ?? throw new ArgumentNullException(nameof(repoRoot));
        _fleetStatePath = BuildFleetStatePath();
        _commanderIntentsPath = BuildCommanderIntentsPath();
    }

    public event EventHandler<JsonElement>? NotificationReceived;

    /// <summary>
    /// L4-1 — fired when the Node server appends a new intent (via
    /// <c>clippy.commander.submit</c>). MainWindow consumes this to route
    /// the prompt through <c>CommanderSession.TrySubmitPrompt</c>.
    /// </summary>
    public event EventHandler<CommanderIntent>? CommanderIntentReceived;
    public event EventHandler<BroadcastIntent>? BroadcastIntentReceived;
    public event EventHandler<LinkGroupIntent>? LinkGroupIntentReceived;

    public string FleetStatePath => _fleetStatePath;

    public string CommanderIntentsPath => _commanderIntentsPath;

    /// <summary>
    /// L4-9 — shared publisher so in-process UI (toolbar slash commands, hotkeys) and
    /// external MCP Apps tools converge on the same intent log. Every dispatch flows
    /// through the same watcher -> event pipeline, guaranteeing a unified audit trail.
    ///
    /// Normalizes every intent to the protocol schema documented in
    /// docs/mcp-apps/protocol.md: id, kind, principal="clippy", session, enqueuedAt.
    /// Callers supplying ts/sessionId are harmonized into session/enqueuedAt.
    /// </summary>
    public async Task PublishIntentAsync(object intent, CancellationToken ct = default)
    {
        if (intent is null) throw new ArgumentNullException(nameof(intent));
        if (string.IsNullOrEmpty(_commanderIntentsPath))
        {
            throw new InvalidOperationException("Commander intents path is not configured.");
        }
        var json = JsonSerializer.Serialize(intent);
        var normalized = NormalizeIntentJson(json);
        var dir = Path.GetDirectoryName(_commanderIntentsPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        await File.AppendAllTextAsync(_commanderIntentsPath, normalized + "\n", Encoding.UTF8, ct).ConfigureAwait(false);
    }

    private string NormalizeIntentJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var dict = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (var prop in root.EnumerateObject())
            {
                dict[prop.Name] = prop.Value.Clone();
            }

            using var ms = new MemoryStream();
            using (var writer = new Utf8JsonWriter(ms))
            {
                writer.WriteStartObject();

                // Required schema keys (docs/mcp-apps/protocol.md)
                WriteStringOrDefault(writer, "id", dict, () => Guid.NewGuid().ToString("n"));
                WriteStringOrDefault(writer, "kind", dict, () => "unknown");
                WriteStringOrDefault(writer, "principal", dict, () => "clippy");

                // session is the Commander session that authored the intent.
                // It is NOT the target tab id for linkgroup.link/unlink.
                string sessionValue;
                if (dict.TryGetValue("session", out var sessEl) && sessEl.ValueKind == JsonValueKind.String)
                {
                    sessionValue = sessEl.GetString() ?? string.Empty;
                }
                else
                {
                    sessionValue = _commanderSessionId;
                }
                writer.WriteString("session", sessionValue);

                // enqueuedAt: accept `enqueuedAt` or legacy `ts`
                string enqueuedValue;
                if (dict.TryGetValue("enqueuedAt", out var eqEl) && eqEl.ValueKind == JsonValueKind.String)
                {
                    enqueuedValue = eqEl.GetString() ?? DateTime.UtcNow.ToString("O");
                }
                else if (dict.TryGetValue("ts", out var tsEl) && tsEl.ValueKind == JsonValueKind.String)
                {
                    enqueuedValue = tsEl.GetString() ?? DateTime.UtcNow.ToString("O");
                }
                else
                {
                    enqueuedValue = DateTime.UtcNow.ToString("O");
                }
                writer.WriteString("enqueuedAt", enqueuedValue);

                // Pass through any additional kind-specific properties.
                // NOTE: `sessionId` is preserved (not stripped) because linkgroup.*
                // dispatchers read it as the target tab session id. Root-level
                // `session` remains the Commander author session for every intent.
                var reserved = new HashSet<string>(StringComparer.Ordinal)
                {
                    "id", "kind", "principal", "session", "enqueuedAt", "ts"
                };
                foreach (var kv in dict)
                {
                    if (reserved.Contains(kv.Key)) continue;
                    writer.WritePropertyName(kv.Key);
                    kv.Value.WriteTo(writer);
                }

                writer.WriteEndObject();
            }
            return Encoding.UTF8.GetString(ms.ToArray());
        }
        catch
        {
            // Fallback: pass through raw JSON if anything fails.
            return json;
        }
    }

    private static void WriteStringOrDefault(Utf8JsonWriter writer, string name, Dictionary<string, JsonElement> dict, Func<string> defaultFactory)
    {
        if (dict.TryGetValue(name, out var el) && el.ValueKind == JsonValueKind.String)
        {
            writer.WriteString(name, el.GetString() ?? defaultFactory());
        }
        else
        {
            writer.WriteString(name, defaultFactory());
        }
    }

    public bool IsReady => _started && _node is { HasExited: false };

    public async Task StartAsync(CancellationToken ct)
    {
        ThrowIfDisposed();
        if (_started) return;

        var serverPath = Path.Combine(_repoRoot, "src", "mcp-apps", "server.mjs");
        if (!File.Exists(serverPath))
        {
            WidgetHostLogger.Log($"McpAppsBridge: server.mjs not found at {serverPath}; bridge disabled.");
            return;
        }

        // Write an initial fleet-state snapshot before spawning so the
        // server's first read lands on real data instead of DEFAULT_SNAPSHOT.
        try { WriteFleetStateFile(_fleetStateProvider()); }
        catch (Exception ex) { WidgetHostLogger.Log($"McpAppsBridge: initial fleet-state write failed: {ex.Message}"); }

        var psi = new ProcessStartInfo
        {
            FileName = "node",
            WorkingDirectory = _repoRoot,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        psi.ArgumentList.Add(serverPath);
        psi.Environment["CLIPPY_FLEET_STATE_PATH"] = _fleetStatePath;
        psi.Environment["CLIPPY_COMMANDER_SESSION"] = _commanderSessionId;
        psi.Environment["CLIPPY_COMMANDER_INTENTS_PATH"] = _commanderIntentsPath;

        try
        {
            EnsureCommanderIntentsFile();
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: intents log prepare failed: {ex.Message}");
        }

        try
        {
            _node = Process.Start(psi) ?? throw new InvalidOperationException("Process.Start returned null.");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: failed to spawn node server: {ex.Message}");
            return;
        }

        _readerCts = new CancellationTokenSource();
        _readerTask = Task.Run(() => ReadLoopAsync(_node.StandardOutput, _readerCts.Token));
        _errReaderTask = Task.Run(() => ReadStderrAsync(_node.StandardError, _readerCts.Token));
        _intentsWatcherTask = Task.Run(() => WatchCommanderIntentsAsync(_readerCts.Token));

        try
        {
            await HandshakeAsync(ct).ConfigureAwait(false);
            _started = true;
            WidgetHostLogger.Log($"McpAppsBridge: handshake complete pid={_node.Id} session={_commanderSessionId}");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: handshake failed: {ex.Message}");
        }
    }

    private async Task HandshakeAsync(CancellationToken ct)
    {
        var initParams = new
        {
            protocolVersion = ProtocolVersion,
            capabilities = new
            {
                extensions = new
                {
                    @__placeholder = (object?)null,
                },
                io_modelcontextprotocol_ui = (object?)null,
            },
            clientInfo = new { name = "windows-clippy-widget", version = "0.2.0-alpha.1" },
        };
        // Build the params JSON manually so we can use the exact extension
        // key "io.modelcontextprotocol/ui" (dot + slash) that the SDK
        // expects. Anonymous objects cannot express that member name.
        var rawParams = JsonDocument.Parse(
            "{\"protocolVersion\":\"" + ProtocolVersion + "\",\"capabilities\":{" +
            "\"extensions\":{\"io.modelcontextprotocol/ui\":{\"mimeTypes\":[\"text/html;profile=mcp-app\"]}}" +
            "},\"clientInfo\":{\"name\":\"windows-clippy-widget\",\"version\":\"0.2.0-alpha.1\"}}");

        _ = initParams; // suppress unused warning; structured form kept for future tweaks.

        var response = await SendRequestAsync("initialize", rawParams.RootElement, ct).ConfigureAwait(false);
        using (response) { /* ignore; we just need the 200-equivalent. */ }

        await SendNotificationAsync("notifications/initialized", null, ct).ConfigureAwait(false);
    }

    public async Task<JsonDocument> CallToolAsync(string toolName, JsonElement arguments, CancellationToken ct)
    {
        ThrowIfDisposed();
        EnsureStarted();

        // Build params including _meta.clippy so L3-6 enforcement can
        // flip on without a call-site change. Serialize manually because
        // System.Text.Json cannot project dictionary keys that contain
        // anonymous-type reserved characters cleanly.
        using var doc = JsonDocument.Parse(
            BuildToolCallParams(toolName, arguments));
        return await SendRequestAsync("tools/call", doc.RootElement.Clone(), ct).ConfigureAwait(false);
    }

    public async Task<JsonDocument> ReadResourceAsync(string uri, CancellationToken ct)
    {
        ThrowIfDisposed();
        EnsureStarted();
        using var doc = JsonDocument.Parse("{\"uri\":" + JsonSerializer.Serialize(uri) + "}");
        return await SendRequestAsync("resources/read", doc.RootElement.Clone(), ct).ConfigureAwait(false);
    }

    public async Task<JsonDocument> ListResourcesAsync(CancellationToken ct)
    {
        ThrowIfDisposed();
        EnsureStarted();
        using var doc = JsonDocument.Parse("{}");
        return await SendRequestAsync("resources/list", doc.RootElement.Clone(), ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Persist the latest widget fleet snapshot so the Node server's next
    /// FleetState._readFromPath sees the fresh data. This is the L3-5
    /// "publish" path; a true push-notification wire lives behind the
    /// list_changed signal the Host fires into the View.
    /// </summary>
    public Task PublishFleetStateAsync(FleetStateSnapshot snapshot)
    {
        ThrowIfDisposed();
        try { WriteFleetStateFile(snapshot); }
        catch (Exception ex) { WidgetHostLogger.Log($"McpAppsBridge: fleet-state publish failed: {ex.Message}"); }
        return Task.CompletedTask;
    }

    /// <summary>
    /// L3-5 placeholder: the server does not expose a tool that forces
    /// emission of <c>notifications/resources/list_changed</c>, so this
    /// method just re-writes the snapshot and relies on the View doing a
    /// timed refetch. The Host-side signal fires independently.
    /// </summary>
    public Task NotifyResourceListChangedAsync()
    {
        return PublishFleetStateAsync(_fleetStateProvider());
    }

    private string BuildToolCallParams(string toolName, JsonElement arguments)
    {
        var sb = new StringBuilder(256);
        sb.Append("{\"name\":").Append(JsonSerializer.Serialize(toolName));
        sb.Append(",\"arguments\":");
        if (arguments.ValueKind == JsonValueKind.Undefined)
        {
            sb.Append("{}");
        }
        else
        {
            sb.Append(arguments.GetRawText());
        }
        sb.Append(",\"_meta\":{\"clippy\":{\"principal\":\"clippy\",\"session\":")
          .Append(JsonSerializer.Serialize(_commanderSessionId))
          .Append("}}}");
        return sb.ToString();
    }

    private async Task<JsonDocument> SendRequestAsync(string method, JsonElement paramsElement, CancellationToken ct)
    {
        var id = Interlocked.Increment(ref _nextId);
        var tcs = new TaskCompletionSource<JsonDocument>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;

        var envelope = "{\"jsonrpc\":\"2.0\",\"id\":" + id +
            ",\"method\":" + JsonSerializer.Serialize(method) +
            ",\"params\":" + (paramsElement.ValueKind == JsonValueKind.Undefined ? "{}" : paramsElement.GetRawText()) +
            "}";

        try
        {
            await WriteLineAsync(envelope, ct).ConfigureAwait(false);
        }
        catch
        {
            _pending.TryRemove(id, out _);
            throw;
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        linked.CancelAfter(TimeSpan.FromSeconds(30));
        await using (linked.Token.Register(() =>
        {
            if (_pending.TryRemove(id, out var waiter))
            {
                waiter.TrySetCanceled();
            }
        }))
        {
            return await tcs.Task.ConfigureAwait(false);
        }
    }

    private async Task SendNotificationAsync(string method, JsonElement? paramsElement, CancellationToken ct)
    {
        var paramsJson = paramsElement is null || paramsElement.Value.ValueKind == JsonValueKind.Undefined
            ? "{}"
            : paramsElement.Value.GetRawText();
        var envelope = "{\"jsonrpc\":\"2.0\",\"method\":" + JsonSerializer.Serialize(method) +
            ",\"params\":" + paramsJson + "}";
        await WriteLineAsync(envelope, ct).ConfigureAwait(false);
    }

    private async Task WriteLineAsync(string line, CancellationToken ct)
    {
        if (_node is null) throw new InvalidOperationException("McpAppsBridge not started.");
        await _stdinGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await _node.StandardInput.WriteLineAsync(line.AsMemory(), ct).ConfigureAwait(false);
            await _node.StandardInput.FlushAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _stdinGate.Release();
        }
    }

    private async Task ReadLoopAsync(StreamReader reader, CancellationToken ct)
    {
        try
        {
            string? line;
            while (!ct.IsCancellationRequested && (line = await reader.ReadLineAsync(ct).ConfigureAwait(false)) is not null)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); }
                catch (Exception ex)
                {
                    WidgetHostLogger.Log($"McpAppsBridge: unparseable stdout line: {ex.Message}");
                    continue;
                }
                HandleMessage(doc);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: read loop ended: {ex.Message}");
        }
    }

    private async Task ReadStderrAsync(StreamReader reader, CancellationToken ct)
    {
        try
        {
            string? line;
            while (!ct.IsCancellationRequested && (line = await reader.ReadLineAsync(ct).ConfigureAwait(false)) is not null)
            {
                WidgetHostLogger.Log($"McpAppsBridge[stderr]: {line}");
            }
        }
        catch (OperationCanceledException) { }
        catch { /* swallow; stderr is diagnostic-only */ }
    }

    private void HandleMessage(JsonDocument doc)
    {
        try
        {
            var root = doc.RootElement;
            if (root.TryGetProperty("id", out var idElement) && idElement.ValueKind == JsonValueKind.Number)
            {
                var id = idElement.GetInt32();
                if (_pending.TryRemove(id, out var waiter))
                {
                    // If an error is present, surface as faulted. Otherwise
                    // deliver the full envelope (result + metadata).
                    if (root.TryGetProperty("error", out var err))
                    {
                        waiter.TrySetException(new McpAppsRpcException(err.GetRawText()));
                        doc.Dispose();
                        return;
                    }
                    waiter.TrySetResult(doc);
                    return;
                }
                doc.Dispose();
                return;
            }

            // Notification path (no id). Fire event for MainWindow/Host.
            if (root.TryGetProperty("method", out var methodElement))
            {
                var clone = root.Clone();
                try { NotificationReceived?.Invoke(this, clone); }
                catch (Exception ex)
                {
                    WidgetHostLogger.Log($"McpAppsBridge: NotificationReceived handler threw: {ex.Message}");
                }
                WidgetHostLogger.Log($"McpAppsBridge[notification]: {methodElement.GetString()}");
            }
            doc.Dispose();
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: HandleMessage failed: {ex.Message}");
            doc.Dispose();
        }
    }

    private void WriteFleetStateFile(FleetStateSnapshot snapshot)
    {
        var dir = Path.GetDirectoryName(_fleetStatePath);
        if (!string.IsNullOrWhiteSpace(dir))
        {
            Directory.CreateDirectory(dir);
        }
        var json = FleetStateSerializer.Serialize(snapshot);
        WriteTextAllowingReaders(_fleetStatePath, json);
    }

    private static void WriteTextAllowingReaders(string path, string contents)
    {
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        using var writer = new StreamWriter(stream, new UTF8Encoding(false));
        writer.Write(contents);
    }

    private static string BuildFleetStatePath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "WindowsClippy", "fleet-state.json");
    }

    private static string BuildCommanderIntentsPath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "WindowsClippy", "commander-intents.jsonl");
    }

    private void EnsureCommanderIntentsFile()
    {
        var dir = Path.GetDirectoryName(_commanderIntentsPath);
        if (!string.IsNullOrWhiteSpace(dir))
        {
            Directory.CreateDirectory(dir);
        }
        if (!File.Exists(_commanderIntentsPath))
        {
            using var _ = File.Create(_commanderIntentsPath);
        }
        // Start tailing from end-of-file so pre-existing (already-processed)
        // intents don't replay on widget restart.
        try
        {
            _intentsOffset = new FileInfo(_commanderIntentsPath).Length;
        }
        catch
        {
            _intentsOffset = 0;
        }
    }

    private async Task WatchCommanderIntentsAsync(CancellationToken ct)
    {
        // Poll every 300ms. FileSystemWatcher is skipped because our own
        // writer (node) truncates + appends from a different process; the
        // polling reader is simpler and avoids FSW missed-event edge cases.
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await ReadNewIntentsAsync(ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                WidgetHostLogger.Log($"McpAppsBridge: intents watcher tick failed: {ex.Message}");
            }

            try { await Task.Delay(300, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task ReadNewIntentsAsync(CancellationToken ct)
    {
        if (!File.Exists(_commanderIntentsPath)) return;
        long length;
        try { length = new FileInfo(_commanderIntentsPath).Length; }
        catch { return; }
        if (length <= _intentsOffset) return;

        using var stream = new FileStream(
            _commanderIntentsPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);
        stream.Seek(_intentsOffset, SeekOrigin.Begin);
        using var reader = new StreamReader(stream, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);
        string? line;
        while ((line = await reader.ReadLineAsync(ct).ConfigureAwait(false)) is not null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                DispatchIntentLine(line);
            }
            catch (Exception ex)
            {
                WidgetHostLogger.Log($"McpAppsBridge: intent parse failed: {ex.Message}");
            }
        }
        _intentsOffset = stream.Position;
    }

    private void DispatchIntentLine(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object) return;

        if (!IsTrustedIntent(root))
        {
            WidgetHostLogger.Log("McpAppsBridge: rejected untrusted commander intent.");
            return;
        }

        var id = root.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.String
            ? idEl.GetString() ?? string.Empty
            : string.Empty;
        if (!string.IsNullOrEmpty(id) && !_processedIntentIds.TryAdd(id, 0)) return;

        var kind = root.TryGetProperty("kind", out var kindEl) && kindEl.ValueKind == JsonValueKind.String
            ? kindEl.GetString() ?? string.Empty
            : string.Empty;

        if (string.Equals(kind, "commander.submit", StringComparison.Ordinal))
        {
            DispatchCommanderSubmit(root, id);
            return;
        }
        if (string.Equals(kind, "broadcast.send", StringComparison.Ordinal))
        {
            DispatchBroadcast(root, id);
            return;
        }
        if (kind.StartsWith("linkgroup.", StringComparison.Ordinal))
        {
            DispatchLinkGroup(root, id, kind);
            return;
        }
    }

    private void DispatchCommanderSubmit(JsonElement root, string id)
    {
        var prompt = root.TryGetProperty("prompt", out var pEl) && pEl.ValueKind == JsonValueKind.String
            ? pEl.GetString() ?? string.Empty
            : string.Empty;
        if (string.IsNullOrWhiteSpace(prompt)) return;

        var mode = root.TryGetProperty("mode", out var mEl) && mEl.ValueKind == JsonValueKind.String
            ? mEl.GetString()
            : null;
        var session = root.TryGetProperty("session", out var sEl) && sEl.ValueKind == JsonValueKind.String
            ? sEl.GetString()
            : null;

        var evt = new CommanderIntent(id, prompt, mode, session);
        try
        {
            CommanderIntentReceived?.Invoke(this, evt);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: CommanderIntentReceived handler threw: {ex.Message}");
        }
    }

    private void DispatchBroadcast(JsonElement root, string id)
    {
        var prompt = root.TryGetProperty("prompt", out var pEl) && pEl.ValueKind == JsonValueKind.String
            ? pEl.GetString() ?? string.Empty
            : string.Empty;
        if (string.IsNullOrWhiteSpace(prompt)) return;

        string mode = "all";
        string? label = null;
        string[]? ids = null;
        string[]? tabKeys = null;
        string[]? sessionIds = null;
        if (root.TryGetProperty("targets", out var tEl) && tEl.ValueKind == JsonValueKind.Object)
        {
            if (tEl.TryGetProperty("mode", out var tmEl) && tmEl.ValueKind == JsonValueKind.String)
            {
                mode = tmEl.GetString() ?? "all";
            }
            if (tEl.TryGetProperty("label", out var tlEl) && tlEl.ValueKind == JsonValueKind.String)
            {
                label = tlEl.GetString();
            }
            if (tEl.TryGetProperty("ids", out var tiEl) && tiEl.ValueKind == JsonValueKind.Array)
            {
                ids = ReadStringArray(tiEl);
            }
            if (tEl.TryGetProperty("tabKeys", out var tkEl) && tkEl.ValueKind == JsonValueKind.Array)
            {
                tabKeys = ReadStringArray(tkEl);
            }
            if (tEl.TryGetProperty("sessionIds", out var siEl) && siEl.ValueKind == JsonValueKind.Array)
            {
                sessionIds = ReadStringArray(siEl);
            }
        }

        var evt = new BroadcastIntent(id, prompt, mode, label, ids, tabKeys, sessionIds);
        try
        {
            BroadcastIntentReceived?.Invoke(this, evt);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: BroadcastIntentReceived handler threw: {ex.Message}");
        }
    }

    private void DispatchLinkGroup(JsonElement root, string id, string kind)
    {
        var op = kind.Substring("linkgroup.".Length);
        var sessionId = root.TryGetProperty("sessionId", out var sEl) && sEl.ValueKind == JsonValueKind.String
            ? sEl.GetString()
            : null;
        var tabKey = root.TryGetProperty("tabKey", out var tkEl) && tkEl.ValueKind == JsonValueKind.String
            ? tkEl.GetString()
            : null;
        var label = root.TryGetProperty("label", out var lEl) && lEl.ValueKind == JsonValueKind.String
            ? lEl.GetString()
            : null;
        var prompt = root.TryGetProperty("prompt", out var pEl) && pEl.ValueKind == JsonValueKind.String
            ? pEl.GetString()
            : null;

        var evt = new LinkGroupIntent(id, op, tabKey, sessionId, label, prompt);
        try
        {
            LinkGroupIntentReceived?.Invoke(this, evt);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: LinkGroupIntentReceived handler threw: {ex.Message}");
        }
    }

    private bool IsTrustedIntent(JsonElement root)
    {
        var principal = root.TryGetProperty("principal", out var pEl) && pEl.ValueKind == JsonValueKind.String
            ? pEl.GetString()
            : null;
        if (!string.Equals(principal, "clippy", StringComparison.Ordinal))
        {
            return false;
        }

        var session = root.TryGetProperty("session", out var sEl) && sEl.ValueKind == JsonValueKind.String
            ? sEl.GetString()
            : null;
        return string.IsNullOrWhiteSpace(session) ||
            string.Equals(session, _commanderSessionId, StringComparison.OrdinalIgnoreCase);
    }

    private static string[] ReadStringArray(JsonElement array)
    {
        var list = new List<string>(array.GetArrayLength());
        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                var value = item.GetString();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    list.Add(value);
                }
            }
        }
        return list.ToArray();
    }

    private void EnsureStarted()
    {
        if (!IsReady)
        {
            throw new InvalidOperationException("McpAppsBridge is not started or the Node server has exited.");
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(McpAppsBridge));
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;

        try { _readerCts?.Cancel(); } catch { }
        try
        {
            if (_node is { HasExited: false })
            {
                try { _node.StandardInput.Close(); } catch { }
                if (!_node.WaitForExit(1500))
                {
                    try { _node.Kill(entireProcessTree: true); } catch { }
                }
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsBridge: dispose shutdown warning: {ex.Message}");
        }

        if (_readerTask is not null)
        {
            try { await _readerTask.ConfigureAwait(false); } catch { }
        }
        if (_errReaderTask is not null)
        {
            try { await _errReaderTask.ConfigureAwait(false); } catch { }
        }

        foreach (var kvp in _pending)
        {
            kvp.Value.TrySetCanceled();
        }
        _pending.Clear();

        _node?.Dispose();
        _readerCts?.Dispose();
        _stdinGate.Dispose();
        if (_intentsWatcherTask is not null)
        {
            try { await _intentsWatcherTask.ConfigureAwait(false); } catch { }
        }
    }
}

internal sealed record CommanderIntent(string Id, string Prompt, string? Mode, string? Session);

internal sealed record BroadcastIntent(
    string Id,
    string Prompt,
    string Mode,
    string? Label,
    string[]? Ids,
    string[]? TabKeys,
    string[]? SessionIds);

internal sealed record LinkGroupIntent(
    string Id,
    string Op,
    string? TabKey,
    string? SessionId,
    string? Label,
    string? Prompt);

internal sealed class McpAppsRpcException : Exception
{
    public McpAppsRpcException(string rawError) : base($"MCP RPC error: {rawError}")
    {
        RawError = rawError;
    }

    public string RawError { get; }
}
