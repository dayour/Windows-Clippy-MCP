using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetHost.Voice;

/// <summary>
/// Hosts the proven Python full-duplex Voice Live realtime sample as a subprocess.
/// Python opens its own PyAudio mic + speaker; the widget only manages process
/// lifecycle and surfaces stdout/stderr to the widget log + status bar.
/// </summary>
internal sealed class LiveAiPythonHost : IDisposable
{
    private const string PythonExe = @"E:\voicelive-samples\python\voice-live-quickstarts\.venv\Scripts\python.exe";
    private const string Script = @"E:\voicelive-samples\python\voice-live-quickstarts\model-quickstart.py";
    private const string WorkDir = @"E:\voicelive-samples\python\voice-live-quickstarts";

    private readonly string _apiKey;
    private readonly string? _endpoint;
    private readonly string? _model;
    private readonly string? _voice;

    private Process? _process;
    private int _disposed;

    public event Action<string>? StatusChanged;
    public event Action<string>? ErrorRaised;
    public event Action? Stopped;

    public bool IsRunning => _process is { HasExited: false };

    public LiveAiPythonHost(string apiKey, string? endpoint = null, string? model = null, string? voice = null)
    {
        _apiKey = apiKey ?? throw new ArgumentNullException(nameof(apiKey));
        _endpoint = endpoint;
        _model = model;
        _voice = voice;
    }

    public Task StartAsync()
    {
        if (_disposed != 0) throw new ObjectDisposedException(nameof(LiveAiPythonHost));
        if (IsRunning) return Task.CompletedTask;

        if (!File.Exists(PythonExe))
        {
            ErrorRaised?.Invoke($"Python venv not found at {PythonExe}");
            return Task.CompletedTask;
        }
        if (!File.Exists(Script))
        {
            ErrorRaised?.Invoke($"Voice Live sample not found at {Script}");
            return Task.CompletedTask;
        }

        var psi = new ProcessStartInfo
        {
            FileName = PythonExe,
            WorkingDirectory = WorkDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        psi.ArgumentList.Add(Script);
        psi.ArgumentList.Add("--verbose");

        // Inject credentials via environment so they never appear on the command line.
        psi.Environment["AZURE_VOICELIVE_API_KEY"] = _apiKey;
        if (!string.IsNullOrWhiteSpace(_endpoint))
            psi.Environment["AZURE_VOICELIVE_ENDPOINT"] = NormalizeEndpoint(_endpoint!);
        if (!string.IsNullOrWhiteSpace(_model))
            psi.Environment["AZURE_VOICELIVE_MODEL"] = _model!;
        if (!string.IsNullOrWhiteSpace(_voice))
            psi.Environment["AZURE_VOICELIVE_VOICE"] = _voice!;
        psi.Environment["PYTHONUNBUFFERED"] = "1";
        psi.Environment["PYTHONIOENCODING"] = "utf-8";

        var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        proc.OutputDataReceived += (_, e) => OnLine(e.Data, isError: false);
        proc.ErrorDataReceived += (_, e) => OnLine(e.Data, isError: true);
        proc.Exited += (_, _) =>
        {
            try { WidgetHostLogger.Log($"LiveAI python subprocess exited code={proc.ExitCode}"); } catch { }
            Stopped?.Invoke();
        };

        try
        {
            if (!proc.Start())
            {
                ErrorRaised?.Invoke("Failed to start Python subprocess.");
                return Task.CompletedTask;
            }
        }
        catch (Exception ex)
        {
            ErrorRaised?.Invoke($"Python launch failed: {ex.Message}");
            return Task.CompletedTask;
        }

        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        _process = proc;
        WidgetHostLogger.Log($"LiveAI python subprocess started pid={proc.Id}");
        StatusChanged?.Invoke("Starting LiveAI realtime session...");
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        var proc = Interlocked.Exchange(ref _process, null);
        if (proc is null) return Task.CompletedTask;
        try
        {
            if (!proc.HasExited)
            {
                // Best-effort graceful: close stdin, then kill the tree.
                try { proc.StandardInput.Close(); } catch { }
                try { proc.Kill(entireProcessTree: true); } catch { }
                try { proc.WaitForExit(2500); } catch { }
            }
        }
        finally
        {
            try { proc.Dispose(); } catch { }
        }
        WidgetHostLogger.Log("LiveAI python subprocess stopped.");
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        try { StopAsync().GetAwaiter().GetResult(); } catch { }
    }

    private void OnLine(string? line, bool isError)
    {
        if (string.IsNullOrWhiteSpace(line)) return;
        try { WidgetHostLogger.Log($"LiveAI py {(isError ? "err" : "out")}: {line}"); } catch { }

        // Best-effort surface of friendly status to the widget.
        var lower = line.ToLowerInvariant();
        if (lower.Contains("connected to voicelive") || lower.Contains("session ready"))
            StatusChanged?.Invoke("LiveAI connected. Speak now.");
        else if (lower.Contains("listening"))
            StatusChanged?.Invoke("LiveAI: listening");
        else if (lower.Contains("user started speaking"))
            StatusChanged?.Invoke("LiveAI: hearing you");
        else if (lower.Contains("assistant started responding"))
            StatusChanged?.Invoke("LiveAI: assistant speaking");
        else if (isError && (lower.Contains("traceback") || lower.Contains("error")))
            ErrorRaised?.Invoke(line.Length > 240 ? line[..240] + "..." : line);
    }

    private static string NormalizeEndpoint(string endpoint)
    {
        // The Python sample expects an https:// endpoint; the SDK negotiates wss internally.
        var s = endpoint.Trim();
        if (s.StartsWith("wss://", StringComparison.OrdinalIgnoreCase))
            s = "https://" + s["wss://".Length..];
        else if (s.StartsWith("ws://", StringComparison.OrdinalIgnoreCase))
            s = "https://" + s["ws://".Length..];
        return s;
    }
}
