using System;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace WidgetHost.Voice;

/// <summary>
/// Voice Live TTS-only session: takes assistant text and streams back audio
/// chunks (24 kHz pcm16) which the player enqueues for playback.
/// Separate from <see cref="VoiceLiveSession"/> so STT and TTS can run
/// concurrently without modality conflicts.
/// </summary>
internal sealed class VoiceLiveSpeaker : IAsyncDisposable
{
    private readonly VoiceLiveConfig _config;
    private readonly ClientWebSocket _socket = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly Channel<string> _outbound =
        Channel.CreateBounded<string>(new BoundedChannelOptions(16)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false
        });

    private Task? _recvLoop;
    private Task? _sendLoop;
    private int _disposed;
    private int _audioChunksReceived;
    private int _eventsLogged;

    public event Action<byte[]>? AudioChunk;
    public event Action? PlaybackBoundary;
    public event Action<string>? ErrorRaised;

    public VoiceLiveSpeaker(VoiceLiveConfig config)
    {
        _config = config;
        _socket.Options.SetRequestHeader("api-key", config.ApiKey);
    }

    public async Task ConnectAsync(CancellationToken ct)
    {
        var uri = new Uri(
            $"{_config.WssEndpoint.TrimEnd('/')}/voice-live/realtime?api-version=2025-10-01&model={Uri.EscapeDataString(_config.Model)}");

        using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(ct, _cts.Token);
        connectCts.CancelAfter(TimeSpan.FromSeconds(10));

        await _socket.ConnectAsync(uri, connectCts.Token).ConfigureAwait(false);
        Log($"VoiceLiveSpeaker connected. model={_config.Model}; voice={_config.TtsVoiceName}");
        await SendSessionUpdateAsync(_cts.Token).ConfigureAwait(false);
        Log("VoiceLiveSpeaker session updated.");

        _recvLoop = Task.Run(() => ReceiveLoopAsync(_cts.Token));
        _sendLoop = Task.Run(() => SendLoopAsync(_cts.Token));
    }

    public bool TrySpeak(string text)
    {
        if (_disposed != 0 || string.IsNullOrWhiteSpace(text)) return false;
        Log($"VoiceLiveSpeaker enqueue speech. chars={text.Length}");
        return _outbound.Writer.TryWrite(text);
    }

    private async Task SendSessionUpdateAsync(CancellationToken ct)
    {
        // Audio-only output, no mic input. Server will TTS our text items.
        var sessionUpdate = new JsonObject
        {
            ["type"] = "session.update",
            ["session"] = new JsonObject
            {
                ["modalities"] = new JsonArray("text", "audio"),
                ["instructions"] = "Speak the user-provided text exactly as written. Do not add commentary.",
                ["output_audio_format"] = "pcm16",
                ["voice"] = new JsonObject
                {
                    ["name"] = _config.TtsVoiceName,
                    ["type"] = "azure-standard"
                },
                ["turn_detection"] = null
            }
        };
        await SendJsonAsync(sessionUpdate, ct).ConfigureAwait(false);
    }

    private async Task SendLoopAsync(CancellationToken ct)
    {
        try
        {
            await foreach (var text in _outbound.Reader.ReadAllAsync(ct).ConfigureAwait(false))
            {
                if (_socket.State != WebSocketState.Open) break;

                var item = new JsonObject
                {
                    ["type"] = "conversation.item.create",
                    ["item"] = new JsonObject
                    {
                        ["type"] = "message",
                        ["role"] = "user",
                        ["content"] = new JsonArray(new JsonObject
                        {
                            ["type"] = "input_text",
                            ["text"] = text
                        })
                    }
                };
                await SendJsonAsync(item, ct).ConfigureAwait(false);
                Log($"VoiceLiveSpeaker sent conversation.item.create. chars={text.Length}");

                var response = new JsonObject { ["type"] = "response.create" };
                await SendJsonAsync(response, ct).ConfigureAwait(false);
                Log("VoiceLiveSpeaker sent response.create.");
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            ErrorRaised?.Invoke($"speaker send: {ex.Message}");
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var chunks = new System.IO.MemoryStream();

        try
        {
            while (!ct.IsCancellationRequested && _socket.State == WebSocketState.Open)
            {
                chunks.SetLength(0);
                WebSocketReceiveResult result;
                do
                {
                    result = await _socket.ReceiveAsync(buffer, ct).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        if (_disposed == 0)
                        {
                            ErrorRaised?.Invoke("Voice Live speaker socket closed.");
                        }
                        return;
                    }
                    chunks.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text) continue;

                var json = Encoding.UTF8.GetString(chunks.ToArray());
                HandleEvent(json);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            ErrorRaised?.Invoke($"speaker recv: {ex.Message}");
        }
    }

    private void HandleEvent(string json)
    {
        JsonNode? node;
        try { node = JsonNode.Parse(json); } catch { return; }

        var type = node?["type"]?.GetValue<string>();
        if (string.IsNullOrEmpty(type)) return;

        switch (type)
        {
            case "session.created":
            case "session.updated":
            case "conversation.item.created":
            case "response.created":
            case "response.output_item.added":
            case "response.content_part.added":
            case "response.audio_transcript.delta":
            case "response.audio_transcript.done":
            case "response.content_part.done":
            case "response.output_item.done":
                LogEventType(type);
                break;
            case "response.audio.delta":
                {
                    var b64 = node?["delta"]?.GetValue<string>();
                    if (!string.IsNullOrEmpty(b64))
                    {
                        try
                        {
                            var pcm = Convert.FromBase64String(b64);
                            if (Interlocked.Increment(ref _audioChunksReceived) == 1)
                            {
                                Log($"VoiceLiveSpeaker received first response.audio.delta. bytes={pcm.Length}");
                            }
                            AudioChunk?.Invoke(pcm);
                        }
                        catch { }
                    }
                    break;
                }
            case "response.audio.done":
            case "response.done":
                Log($"VoiceLiveSpeaker received {type}. audioChunks={Volatile.Read(ref _audioChunksReceived)}");
                Interlocked.Exchange(ref _audioChunksReceived, 0);
                PlaybackBoundary?.Invoke();
                break;
            case "error":
                {
                    var msg = node?["error"]?["message"]?.GetValue<string>() ?? "unknown error";
                    Log($"VoiceLiveSpeaker error event: {msg}");
                    ErrorRaised?.Invoke(msg);
                    break;
                }
            default:
                LogEventType(type);
                break;
        }
    }

    private async Task SendJsonAsync(JsonNode payload, CancellationToken ct)
    {
        var bytes = Encoding.UTF8.GetBytes(payload.ToJsonString());
        await _socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, ct).ConfigureAwait(false);
    }

    private static void Log(string message)
    {
        try { global::WidgetHost.WidgetHostLogger.Log(message); } catch { }
    }

    private void LogEventType(string type)
    {
        if (Interlocked.Increment(ref _eventsLogged) <= 20)
        {
            Log($"VoiceLiveSpeaker event: {type}");
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;

        try { _outbound.Writer.TryComplete(); } catch { }
        try { _cts.Cancel(); } catch { }

        if (_socket.State == WebSocketState.Open)
        {
            try
            {
                using var closeCts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "client closing", closeCts.Token)
                    .ConfigureAwait(false);
            }
            catch { }
        }

        try { if (_recvLoop is not null) await _recvLoop.ConfigureAwait(false); } catch { }
        try { if (_sendLoop is not null) await _sendLoop.ConfigureAwait(false); } catch { }

        _socket.Dispose();
        _cts.Dispose();
    }
}
