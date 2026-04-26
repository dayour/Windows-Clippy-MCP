using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls.Primitives;
using WidgetHost.Voice;

namespace WidgetHost;

public partial class MainWindow
{
    // STT-only mic dictation path. One utterance, drop into InputBox, auto-release.
    private VoiceLiveSession? _voiceSession;
    private VoiceLiveMicrophone? _voiceMic;
    private int _voiceSessionVersion;
    private bool _voiceStarting;

    // LiveAI: full-duplex Voice Live realtime, owned by a Python subprocess.
    private LiveAiPythonHost? _liveAiHost;
    private int _liveAiSessionVersion;
    private bool _liveAiStarting;

    // ----- Mic (STT-only dictation) -----

    private async void OnMicToggleChecked(object sender, RoutedEventArgs e)
    {
        if (_isSyncingUi) return;

        var settings = _settings.VoiceLive;
        var apiKey = settings.ApiKey;
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            RevertMicToggle("Set VOICELIVE_API_KEY environment variable to enable transcription.");
            return;
        }
        if (string.IsNullOrWhiteSpace(settings.WssEndpoint) || string.IsNullOrWhiteSpace(settings.Model))
        {
            RevertMicToggle("Voice Live endpoint or model is not configured.");
            return;
        }

        // Mutex: never run mic dictation while LiveAI realtime owns the device.
        if (LiveAICommanderToggle is ToggleButton lt && lt.IsChecked == true)
        {
            RevertMicToggle("LiveAI is active; turn LiveAI off first.");
            return;
        }

        if (_voiceStarting || _voiceSession is not null) return;

        _voiceStarting = true;
        var versionAtStart = Interlocked.Increment(ref _voiceSessionVersion);

        try
        {
            var cfg = new VoiceLiveConfig(settings.WssEndpoint, settings.Model, apiKey!, settings.TtsVoiceName);
            var session = new VoiceLiveSession(cfg);
            session.UserTranscriptFinal += t => OnVoiceTranscriptFinal(versionAtStart, t);
            session.StatusChanged += s => OnVoiceStatusChanged(versionAtStart, s);
            session.ErrorRaised += err => OnVoiceErrorRaised(versionAtStart, err);
            session.DiagLog += msg => WidgetHostLogger.Log($"VoiceLiveSession(mic): {msg}");

            await session.ConnectAsync(CancellationToken.None);

            if (versionAtStart != Volatile.Read(ref _voiceSessionVersion))
            {
                await session.DisposeAsync();
                return;
            }

            var mic = new VoiceLiveMicrophone();
            mic.OnAudioChunk += chunk =>
            {
                if (versionAtStart != Volatile.Read(ref _voiceSessionVersion)) return;
                session.TryEnqueueAudio(chunk);
            };
            mic.OnError += err => OnVoiceErrorRaised(versionAtStart, err);
            mic.Start();

            _voiceSession = session;
            _voiceMic = mic;

            UpdateStatus("Mic on. Speak one phrase; it will land in the input box.");
            WidgetHostLogger.Log("Mic dictation session started.");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Mic dictation start failed: {ex.Message}");
            RevertMicToggle($"Transcription failed to start: {ex.Message}");
            await StopVoiceAsync();
        }
        finally
        {
            _voiceStarting = false;
        }
    }

    private async void OnMicToggleUnchecked(object sender, RoutedEventArgs e)
    {
        if (_isSyncingUi) return;
        await StopVoiceAsync();
        UpdateStatus("Mic off.");
        WidgetHostLogger.Log("Mic dictation session stopped.");
    }

    private async Task StopVoiceAsync()
    {
        Interlocked.Increment(ref _voiceSessionVersion);

        var mic = _voiceMic; _voiceMic = null;
        var session = _voiceSession; _voiceSession = null;

        try { mic?.Dispose(); } catch { }
        if (session is not null) { try { await session.DisposeAsync(); } catch { } }
    }

    private void OnVoiceTranscriptFinal(int version, string transcript)
    {
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (version != Volatile.Read(ref _voiceSessionVersion)) return;
            if (string.IsNullOrWhiteSpace(transcript)) return;

            AppendVoiceTextToInputBox(transcript);
            var preview = transcript.Length > 60 ? transcript[..60] + "..." : transcript;
            UpdateStatus($"Heard: {preview} (review and Send)");

            // Dictation-only: one utterance per click. Auto-release the toggle so the next
            // click starts a fresh capture and the user keeps explicit control.
            var was = _isSyncingUi; _isSyncingUi = true;
            try
            {
                if (MicToggle is ToggleButton tb) tb.IsChecked = false;
            }
            finally { _isSyncingUi = was; }
            _ = StopVoiceAsync();
        });
    }

    private void OnVoiceStatusChanged(int version, string status)
    {
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (version != Volatile.Read(ref _voiceSessionVersion)) return;
            UpdateStatus($"Mic: {status}");
        });
    }

    private void OnVoiceErrorRaised(int version, string err)
    {
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, async () =>
        {
            if (version != Volatile.Read(ref _voiceSessionVersion)) return;
            WidgetHostLogger.Log($"Mic dictation error: {err}");
            await StopVoiceAsync();
            RevertMicToggle($"Transcription stopped: {err}");
        });
    }

    private void RevertMicToggle(string message)
    {
        var wasSyncing = _isSyncingUi;
        _isSyncingUi = true;
        try
        {
            if (MicToggle is ToggleButton tb) tb.IsChecked = false;
        }
        finally { _isSyncingUi = wasSyncing; }
        SetCommanderNotice(message);
        UpdateStatus(message);
    }

    // ----- LiveAI (full-duplex realtime via Python subprocess) -----

    private async void OnLiveAiToggleChecked(object sender, RoutedEventArgs e)
    {
        if (_isSyncingUi) return;

        var settings = _settings.VoiceLive;
        var apiKey = settings.ApiKey;
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            RevertLiveAiToggle("Set VOICELIVE_API_KEY environment variable to enable LiveAI.");
            return;
        }

        // Mutex: kill mic dictation if it is running.
        if (MicToggle is ToggleButton mt && mt.IsChecked == true)
        {
            await StopVoiceAsync();
            var was = _isSyncingUi; _isSyncingUi = true;
            try { mt.IsChecked = false; } finally { _isSyncingUi = was; }
        }

        if (_liveAiStarting || _liveAiHost is not null) return;

        _liveAiStarting = true;
        var versionAtStart = Interlocked.Increment(ref _liveAiSessionVersion);

        try
        {
            var host = new LiveAiPythonHost(
                apiKey!,
                settings.WssEndpoint,
                settings.Model,
                settings.TtsVoiceName);
            host.StatusChanged += s => OnLiveAiStatusChanged(versionAtStart, s);
            host.ErrorRaised += err => OnLiveAiErrorRaised(versionAtStart, err);
            host.Stopped += () => OnLiveAiStopped(versionAtStart);

            await host.StartAsync();

            if (versionAtStart != Volatile.Read(ref _liveAiSessionVersion))
            {
                host.Dispose();
                return;
            }

            _liveAiHost = host;
            UpdateStatus("LiveAI starting. Headphones recommended.");
            WidgetHostLogger.Log("LiveAI Python subprocess host started.");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"LiveAI start failed: {ex.Message}");
            RevertLiveAiToggle($"LiveAI failed to start: {ex.Message}");
            await StopLiveAiAsync();
        }
        finally
        {
            _liveAiStarting = false;
        }
    }

    private async void OnLiveAiToggleUnchecked(object sender, RoutedEventArgs e)
    {
        if (_isSyncingUi) return;
        await StopLiveAiAsync();
        UpdateStatus("LiveAI off.");
        WidgetHostLogger.Log("LiveAI Python subprocess host stopped.");
    }

    private async Task StopLiveAiAsync()
    {
        Interlocked.Increment(ref _liveAiSessionVersion);
        var host = _liveAiHost; _liveAiHost = null;
        if (host is not null)
        {
            try { await host.StopAsync(); } catch { }
            try { host.Dispose(); } catch { }
        }
    }

    private void OnLiveAiStatusChanged(int version, string status)
    {
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (version != Volatile.Read(ref _liveAiSessionVersion)) return;
            UpdateStatus(status);
        });
    }

    private void OnLiveAiErrorRaised(int version, string err)
    {
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, async () =>
        {
            if (version != Volatile.Read(ref _liveAiSessionVersion)) return;
            WidgetHostLogger.Log($"LiveAI error: {err}");
            await StopLiveAiAsync();
            RevertLiveAiToggle($"LiveAI stopped: {err}");
        });
    }

    private void OnLiveAiStopped(int version)
    {
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (version != Volatile.Read(ref _liveAiSessionVersion)) return;
            // Subprocess exited on its own. Clean up and release the toggle.
            _liveAiHost = null;
            var was = _isSyncingUi; _isSyncingUi = true;
            try
            {
                if (LiveAICommanderToggle is ToggleButton tb) tb.IsChecked = false;
            }
            finally { _isSyncingUi = was; }
            UpdateStatus("LiveAI session ended.");
        });
    }

    private void RevertLiveAiToggle(string message)
    {
        var wasSyncing = _isSyncingUi;
        _isSyncingUi = true;
        try
        {
            if (LiveAICommanderToggle is ToggleButton tb) tb.IsChecked = false;
        }
        finally { _isSyncingUi = wasSyncing; }
        SetCommanderNotice(message);
        UpdateStatus(message);
    }

    private void AppendVoiceTextToInputBox(string text)
    {
        var existing = InputBox.Text ?? string.Empty;
        var sep = string.IsNullOrWhiteSpace(existing) || existing.EndsWith(' ') ? string.Empty : " ";
        InputBox.Text = existing + sep + text;
        InputBox.CaretIndex = InputBox.Text.Length;
    }
}
