using System;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace WidgetHost.Voice;

/// <summary>
/// Minimal Voice Live API client wrapping the realtime WebSocket.
/// V1: speech-to-text only — emits the user's final transcript so the
/// MainWindow can fill the Commander InputBox. The model is configured
/// with text-only modalities so it will not generate its own audio reply.
/// </summary>
internal sealed class VoiceLiveSession : IAsyncDisposable
{
    private readonly VoiceLiveConfig _config;
    private readonly ClientWebSocket _socket = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly Channel<byte[]> _outboundAudio =
        Channel.CreateBounded<byte[]>(new BoundedChannelOptions(64)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false
        });

    private Task? _recvLoop;
    private Task? _sendLoop;
    private int _disposed;

    public event Action<string>? UserTranscriptFinal;
    public event Action<string>? StatusChanged;
    public event Action<string>? ErrorRaised;
    public event Action<string>? DiagLog;

    private long _audioChunksSent;
    private long _audioBytesSent;

    public VoiceLiveSession(VoiceLiveConfig config)
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

        StatusChanged?.Invoke("Connecting...");
        await _socket.ConnectAsync(uri, connectCts.Token).ConfigureAwait(false);

        await SendSessionUpdateAsync(_cts.Token).ConfigureAwait(false);

        _recvLoop = Task.Run(() => ReceiveLoopAsync(_cts.Token));
        _sendLoop = Task.Run(() => SendLoopAsync(_cts.Token));

        StatusChanged?.Invoke("Listening");
    }

    public bool TryEnqueueAudio(byte[] pcm16Mono24k)
    {
        if (_disposed != 0)
        {
            return false;
        }
        return _outboundAudio.Writer.TryWrite(pcm16Mono24k);
    }

    private async Task SendSessionUpdateAsync(CancellationToken ct)
    {
        // Text-only modalities: we want the model to transcribe user audio
        // but NOT generate its own audio/text reply. The Commander handles
        // the actual response.
        // Text-only modalities require a minimal session config: Voice Live
        // explicitly rejects server-side echo cancellation in this mode
        // ("Server side echo cancellation is not supported when modalities
        // is text-only"), and `input_audio_sampling_rate` is not a recognized
        // field on this API surface. Keep only properties the service accepts
        // for transcription-only sessions.
        var sessionUpdate = new JsonObject
        {
            ["type"] = "session.update",
            ["session"] = new JsonObject
            {
                ["modalities"] = new JsonArray("text"),
                ["instructions"] = "Transcribe the user's speech. Do not respond.",
                ["input_audio_format"] = "pcm16",
                ["input_audio_noise_reduction"] = new JsonObject
                {
                    ["type"] = "azure_deep_noise_suppression"
                },
                ["input_audio_transcription"] = new JsonObject
                {
                    ["model"] = "whisper-1"
                },
                ["turn_detection"] = new JsonObject
                {
                    ["type"] = "azure_semantic_vad",
                    ["threshold"] = 0.3,
                    ["prefix_padding_ms"] = 300,
                    ["speech_duration_ms"] = 80,
                    ["silence_duration_ms"] = 1200,
                    ["remove_filler_words"] = false,
                    ["interrupt_response"] = false,
                    ["create_response"] = false,
                    ["end_of_utterance_detection"] = new JsonObject
                    {
                        ["model"] = "semantic_detection_v1",
                        ["threshold_level"] = "default",
                        ["timeout_ms"] = 1500
                    }
                }
            }
        };

        await SendJsonAsync(sessionUpdate, ct).ConfigureAwait(false);
    }

    private async Task SendLoopAsync(CancellationToken ct)
    {
        try
        {
            await foreach (var chunk in _outboundAudio.Reader.ReadAllAsync(ct).ConfigureAwait(false))
            {
                if (_socket.State != WebSocketState.Open)
                {
                    break;
                }

                var msg = new JsonObject
                {
                    ["type"] = "input_audio_buffer.append",
                    ["audio"] = Convert.ToBase64String(chunk)
                };
                await SendJsonAsync(msg, ct).ConfigureAwait(false);

                var n = Interlocked.Increment(ref _audioChunksSent);
                Interlocked.Add(ref _audioBytesSent, chunk.Length);
                if (n == 1 || n % 50 == 0)
                {
                    DiagLog?.Invoke($"audio uplink: chunks={n} bytes={Interlocked.Read(ref _audioBytesSent)}");
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            ErrorRaised?.Invoke($"send loop: {ex.Message}");
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
                        StatusChanged?.Invoke("Closed");
                        if (_disposed == 0)
                        {
                            ErrorRaised?.Invoke("Voice Live socket closed.");
                        }
                        return;
                    }
                    chunks.Write(buffer, 0, result.Count);
                }
                while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text)
                {
                    continue;
                }

                var json = Encoding.UTF8.GetString(chunks.ToArray());
                HandleEvent(json);
            }
        }
        catch (OperationCanceledException) { }
        catch (WebSocketException wsex)
        {
            // Surface as much WebSocket diagnostic info as possible. An
            // abrupt close (no handshake) usually means the server gave up
            // after rejecting our session.update — read prior `error`
            // events in the log to find the root cause.
            var status = _socket.CloseStatus?.ToString() ?? "(no close status)";
            var desc = string.IsNullOrEmpty(_socket.CloseStatusDescription)
                ? "(no description)" : _socket.CloseStatusDescription;
            ErrorRaised?.Invoke(
                $"recv loop ({wsex.WebSocketErrorCode}, native=0x{wsex.NativeErrorCode:X}, " +
                $"close={status}, desc={desc}): {wsex.Message}");
        }
        catch (Exception ex)
        {
            ErrorRaised?.Invoke($"recv loop: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private void HandleEvent(string json)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json);
        }
        catch
        {
            return;
        }

        var type = node?["type"]?.GetValue<string>();
        if (string.IsNullOrEmpty(type))
        {
            return;
        }

        DiagLog?.Invoke($"recv event: {type}");

        switch (type)
        {
            case "conversation.item.input_audio_transcription.completed":
                {
                    var transcript = node?["transcript"]?.GetValue<string>();
                    DiagLog?.Invoke($"transcription.completed transcript=\"{(transcript ?? "(null)")}\"");
                    if (!string.IsNullOrWhiteSpace(transcript))
                    {
                        UserTranscriptFinal?.Invoke(transcript.Trim());
                    }
                    break;
                }
            case "conversation.item.input_audio_transcription.delta":
                {
                    var delta = node?["delta"]?.GetValue<string>();
                    if (!string.IsNullOrEmpty(delta))
                    {
                        DiagLog?.Invoke($"transcription.delta \"{delta}\"");
                    }
                    break;
                }
            case "conversation.item.input_audio_transcription.failed":
                {
                    var msg = node?["error"]?["message"]?.GetValue<string>() ?? "transcription failed";
                    DiagLog?.Invoke($"transcription.failed: {msg}");
                    ErrorRaised?.Invoke($"transcription failed: {msg}");
                    break;
                }
            case "input_audio_buffer.speech_started":
                DiagLog?.Invoke("VAD: speech_started");
                StatusChanged?.Invoke("Speaking...");
                break;
            case "input_audio_buffer.speech_stopped":
                DiagLog?.Invoke("VAD: speech_stopped");
                StatusChanged?.Invoke("Listening");
                break;
            case "input_audio_buffer.committed":
                DiagLog?.Invoke("VAD: buffer committed");
                break;
            case "session.created":
            case "session.updated":
            case "rate_limits.updated":
                break;
            case "error":
                {
                    var msg = node?["error"]?["message"]?.GetValue<string>() ?? "unknown error";
                    var code = node?["error"]?["code"]?.GetValue<string>() ?? "";
                    DiagLog?.Invoke($"server error: code={code} msg={msg}");
                    ErrorRaised?.Invoke(msg);
                    break;
                }
        }
    }

    private async Task SendJsonAsync(JsonNode payload, CancellationToken ct)
    {
        var bytes = Encoding.UTF8.GetBytes(payload.ToJsonString());
        await _socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, ct).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        try { _outboundAudio.Writer.TryComplete(); } catch { }
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

internal sealed record VoiceLiveConfig(
    string WssEndpoint,
    string Model,
    string ApiKey,
    string TtsVoiceName = "en-US-AvaMultilingualNeural");
