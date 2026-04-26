using System;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace WidgetHost.Voice;

/// <summary>
/// Microphone capture for Voice Live: opens the default input at its native
/// rate, resamples to 24 kHz mono PCM16, and forwards 20 ms frames via
/// <see cref="OnAudioChunk"/>. Caller pumps these into the session's
/// outbound audio channel.
/// </summary>
internal sealed class VoiceLiveMicrophone : IDisposable
{
    private const int TargetSampleRate = 24000;
    private const int FrameMs = 20;
    private const int TargetBytesPerFrame = TargetSampleRate * 2 /* bytes/sample */ * FrameMs / 1000; // 960 bytes

    private IWaveIn? _capture;
    private MediaFoundationResampler? _resampler;
    private BufferedWaveProvider? _captureBuffer;
    private byte[] _frameBuffer = new byte[TargetBytesPerFrame];
    private int _frameFill;
    private bool _disposed;

    public event Action<byte[]>? OnAudioChunk;
    public event Action<string>? OnError;

    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_capture is not null) return;

        var capture = CreateCaptureDevice(out var deviceName);
        var captureFormat = capture.WaveFormat;
        _captureBuffer = new BufferedWaveProvider(captureFormat)
        {
            BufferDuration = TimeSpan.FromSeconds(2),
            DiscardOnBufferOverflow = true,
            ReadFully = false
        };

        _resampler = new MediaFoundationResampler(_captureBuffer, new WaveFormat(TargetSampleRate, 16, 1))
        {
            ResamplerQuality = 40
        };

        capture.DataAvailable += OnDataAvailable;
        capture.RecordingStopped += OnRecordingStopped;

        try
        {
            capture.StartRecording();
            _capture = capture;
            Log($"VoiceLiveMicrophone started. device={deviceName}; format={FormatForLog(captureFormat)}");
        }
        catch (Exception ex)
        {
            capture.DataAvailable -= OnDataAvailable;
            capture.RecordingStopped -= OnRecordingStopped;
            try { capture.Dispose(); } catch { }
            try { _resampler?.Dispose(); } catch { }
            _resampler = null;
            _captureBuffer = null;
            Log($"VoiceLiveMicrophone failed to start. device={deviceName}; error={ex.Message}");
            throw new InvalidOperationException($"Microphone unavailable: {ex.Message}", ex);
        }
    }

    private static IWaveIn CreateCaptureDevice(out string deviceName)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            deviceName = device.FriendlyName;
            return new WasapiCapture(device);
        }
        catch (Exception wasapiEx)
        {
            if (WaveIn.DeviceCount <= 0)
            {
                throw new InvalidOperationException($"No microphone capture device is available: {wasapiEx.Message}", wasapiEx);
            }

            var caps = WaveIn.GetCapabilities(0);
            var channels = Math.Max(1, Math.Min(caps.Channels, 2));
            deviceName = string.IsNullOrWhiteSpace(caps.ProductName)
                ? "waveIn device 0"
                : caps.ProductName;
            return new WaveInEvent
            {
                DeviceNumber = 0,
                WaveFormat = new WaveFormat(48000, 16, channels),
                BufferMilliseconds = FrameMs
            };
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (_disposed || _captureBuffer is null || _resampler is null)
        {
            return;
        }

        try
        {
            _captureBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);

            // Pull resampled bytes; pack into fixed-size 20 ms frames for the API.
            var pull = new byte[TargetBytesPerFrame];
            int read;
            while ((read = _resampler.Read(pull, 0, pull.Length)) > 0)
            {
                AppendToFrame(pull, read);
            }
        }
        catch (Exception ex)
        {
            OnError?.Invoke($"Capture error: {ex.Message}");
        }
    }

    private void AppendToFrame(byte[] src, int count)
    {
        var srcOffset = 0;
        while (count > 0)
        {
            var space = TargetBytesPerFrame - _frameFill;
            var take = Math.Min(space, count);
            Buffer.BlockCopy(src, srcOffset, _frameBuffer, _frameFill, take);
            _frameFill += take;
            srcOffset += take;
            count -= take;

            if (_frameFill == TargetBytesPerFrame)
            {
                var copy = new byte[TargetBytesPerFrame];
                Buffer.BlockCopy(_frameBuffer, 0, copy, 0, TargetBytesPerFrame);
                OnAudioChunk?.Invoke(copy);
                _frameFill = 0;
            }
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (!_disposed && e.Exception is not null)
        {
            OnError?.Invoke($"Recording stopped: {e.Exception.Message}");
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        try { _capture?.StopRecording(); } catch { }
        try { _capture?.Dispose(); } catch { }
        try { _resampler?.Dispose(); } catch { }
        _capture = null;
        _resampler = null;
        _captureBuffer = null;
    }

    private static string FormatForLog(WaveFormat format)
    {
        return $"{format.Encoding} {format.SampleRate}Hz {format.BitsPerSample}bit {format.Channels}ch";
    }

    private static void Log(string message)
    {
        try { global::WidgetHost.WidgetHostLogger.Log(message); } catch { }
    }
}
