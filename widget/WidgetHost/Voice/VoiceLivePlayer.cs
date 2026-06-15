using System;
using NAudio.Wave;

namespace WidgetHost.Voice;

/// <summary>
/// Plays back 24 kHz mono PCM16 audio chunks streamed from Voice Live.
/// Buffered playback with a hard ceiling and prebuffer-on-start to avoid
/// underrun glitches on the first chunks. Drops oldest on overflow.
/// </summary>
internal sealed class VoiceLivePlayer : IDisposable
{
    private static readonly WaveFormat Format = new(24000, 16, 1);
    private const int PrebufferMs = 120;
    private const int MaxBufferSeconds = 8;

    private readonly object _gate = new();
    private WaveOutEvent? _output;
    private BufferedWaveProvider? _buffer;
    private bool _started;
    private bool _disposed;

    public void Start()
    {
        lock (_gate)
        {
            if (_disposed || _output is not null) return;

            _buffer = new BufferedWaveProvider(Format)
            {
                BufferDuration = TimeSpan.FromSeconds(MaxBufferSeconds),
                DiscardOnBufferOverflow = true,
                ReadFully = false
            };

            _output = new WaveOutEvent
            {
                DesiredLatency = 100,
                NumberOfBuffers = 3
            };
            _output.Init(_buffer);
            _started = false;
        }
    }

    public void Enqueue(byte[] pcm16Mono24k)
    {
        BufferedWaveProvider? buffer;
        WaveOutEvent? output;
        bool start = false;

        lock (_gate)
        {
            if (_disposed) return;
            buffer = _buffer;
            output = _output;
            if (buffer is null || output is null) return;

            buffer.AddSamples(pcm16Mono24k, 0, pcm16Mono24k.Length);

            if (!_started && buffer.BufferedDuration.TotalMilliseconds >= PrebufferMs)
            {
                _started = true;
                start = true;
            }
        }

        if (start)
        {
            try { output!.Play(); } catch { }
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            try { _buffer?.ClearBuffer(); } catch { }
            _started = false;
            try { _output?.Stop(); } catch { }
        }
    }

    public bool IsPlaying
    {
        get
        {
            lock (_gate)
            {
                if (_disposed || _buffer is null) return false;
                return _started && _buffer.BufferedDuration > TimeSpan.Zero;
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;

            try { _output?.Stop(); } catch { }
            try { _output?.Dispose(); } catch { }
            _output = null;
            _buffer = null;
        }
    }
}
