using Microsoft.Web.WebView2.Core;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;

namespace BrowserHost;

/// <summary>
/// Hosts a WebView2 browser surface using the same stdin/stdout JSON protocol
/// as TerminalHost. The widget parent launches this process with --hwnd-mode,
/// reads the {"type":"ready","hwnd":"0x..."} message, and reparents the HWND
/// as a WS_CHILD window inside the bench panel.
///
/// One BrowserHost process == one browser tab. The CoreWebView2Environment is
/// shared via a common user-data folder so all BrowserHost instances share
/// cookies, cache, and login sessions.
/// </summary>
public partial class MainWindow : Window
{
    private readonly BrowserLaunchOptions _options;
    private readonly CancellationTokenSource _controlLoopCancellation = new();
    private IntPtr _windowHandle;
    private bool _readySent;
    private bool _exitSent;
    private bool _shutdownRequested;

    public MainWindow(BrowserLaunchOptions options)
    {
        _options = options;
        InitializeComponent();
        Title = _options.DisplayName;

        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    // ── Argument parsing ──────────────────────────────────────────

    public static BrowserLaunchOptions ParseArguments(IEnumerable<string> rawArgs)
    {
        var options = new BrowserLaunchOptions();
        using var enumerator = rawArgs.GetEnumerator();

        while (enumerator.MoveNext())
        {
            var current = enumerator.Current ?? string.Empty;
            if (!current.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            string key;
            string? value = null;
            var separatorIndex = current.IndexOf('=');
            if (separatorIndex >= 0)
            {
                key = current[..separatorIndex];
                value = current[(separatorIndex + 1)..];
            }
            else
            {
                key = current;
            }

            switch (key)
            {
                case "--url":
                    options.InitialUrl = value ?? RequireValue(key, enumerator);
                    break;
                case "--display-name":
                    options.DisplayName = value ?? RequireValue(key, enumerator);
                    break;
                case "--user-data-dir":
                    options.UserDataDirectory = value ?? RequireValue(key, enumerator);
                    break;
                case "--hwnd-mode":
                    options.HwndMode = true;
                    break;
                default:
                    throw new ArgumentException($"Unsupported argument: {current}");
            }
        }

        return options;
    }

    private static string RequireValue(string key, IEnumerator<string> enumerator)
    {
        if (!enumerator.MoveNext() || string.IsNullOrWhiteSpace(enumerator.Current))
        {
            throw new ArgumentException($"{key} requires a value.");
        }
        return enumerator.Current;
    }

    // ── Lifecycle ─────────────────────────────────────────────────

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _windowHandle = new WindowInteropHelper(this).Handle;
        TryEmitReady();
        if (_options.HwndMode)
        {
            Hide();
        }
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await InitializeWebViewAsync();
        }
        catch (Exception ex)
        {
            ProtocolWriter.TryWrite(new { type = "error", message = $"WebView2 init failed: {ex.Message}" });
        }

        if (IsInputRedirected())
        {
            _ = RunControlLoopAsync(_controlLoopCancellation.Token);
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _controlLoopCancellation.Cancel();
        EmitExit(0);
    }

    // ── WebView2 initialization ───────────────────────────────────

    private async Task InitializeWebViewAsync()
    {
        // All BrowserHost instances share one user-data folder so they share
        // cookies/cache/login sessions -- this is the "one browser session
        // across tabs" requirement.
        var userDataDir = _options.UserDataDirectory
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Windows-Clippy-MCP",
                "BrowserHost-WebView2");

        var environment = await CoreWebView2Environment.CreateAsync(
            browserExecutableFolder: null,
            userDataFolder: userDataDir);

        await BrowserView.EnsureCoreWebView2Async(environment);

        // Dark-theme defaults
        BrowserView.CoreWebView2.Settings.IsStatusBarEnabled = false;

        // Navigate to initial URL or show a blank page
        var url = _options.InitialUrl ?? "about:blank";
        BrowserView.CoreWebView2.Navigate(url);

        ProtocolWriter.TryWrite(new { type = "browser.ready", url });
    }

    // ── stdin control loop (same pattern as TerminalHost) ─────────

    private async Task RunControlLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var line = await Console.In.ReadLineAsync(cancellationToken);
                if (line is null)
                {
                    await Dispatcher.InvokeAsync(RequestShutdownAsync);
                    return;
                }

                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                try
                {
                    using var document = JsonDocument.Parse(line);
                    await HandleControlMessageAsync(document.RootElement);
                }
                catch (JsonException ex)
                {
                    ProtocolWriter.TryWrite(new { type = "error", message = $"Invalid control message: {ex.Message}" });
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (IOException)
        {
            await Dispatcher.InvokeAsync(RequestShutdownAsync);
        }
    }

    private async Task HandleControlMessageAsync(JsonElement root)
    {
        if (!root.TryGetProperty("type", out var typeProp))
        {
            return;
        }

        var messageType = typeProp.GetString();

        switch (messageType)
        {
            case "navigate":
                if (root.TryGetProperty("url", out var urlProp))
                {
                    var url = urlProp.GetString();
                    if (!string.IsNullOrWhiteSpace(url))
                    {
                        await Dispatcher.InvokeAsync(() =>
                        {
                            BrowserView.CoreWebView2?.Navigate(url);
                        });
                    }
                }
                break;

            case "navigate.back":
                await Dispatcher.InvokeAsync(() => { if (BrowserView.CoreWebView2?.CanGoBack == true) BrowserView.CoreWebView2.GoBack(); });
                break;

            case "navigate.forward":
                await Dispatcher.InvokeAsync(() => { if (BrowserView.CoreWebView2?.CanGoForward == true) BrowserView.CoreWebView2.GoForward(); });
                break;

            case "navigate.reload":
                await Dispatcher.InvokeAsync(() => BrowserView.CoreWebView2?.Reload());
                break;

            case "execute.script":
                if (root.TryGetProperty("script", out var scriptProp))
                {
                    var script = scriptProp.GetString();
                    if (!string.IsNullOrWhiteSpace(script))
                    {
                        await Dispatcher.InvokeAsync(async () =>
                        {
                            try
                            {
                                var result = await BrowserView.CoreWebView2.ExecuteScriptAsync(script);
                                ProtocolWriter.TryWrite(new { type = "script.result", result });
                            }
                            catch (Exception ex)
                            {
                                ProtocolWriter.TryWrite(new { type = "script.error", message = ex.Message });
                            }
                        });
                    }
                }
                break;

            case "shutdown":
                await Dispatcher.InvokeAsync(RequestShutdownAsync);
                break;

            default:
                ProtocolWriter.TryWrite(new { type = "error", message = $"Unknown control message type: {messageType}" });
                break;
        }
    }

    // ── Protocol helpers ──────────────────────────────────────────

    private void TryEmitReady()
    {
        if (_readySent || _windowHandle == IntPtr.Zero)
        {
            return;
        }

        _readySent = true;
        ProtocolWriter.TryWrite(new
        {
            type = "ready",
            hwnd = $"0x{_windowHandle.ToInt64():X}",
            pid = Process.GetCurrentProcess().Id,
            surface = "browser"
        });
    }

    private void EmitExit(int exitCode)
    {
        if (_exitSent)
        {
            return;
        }

        _exitSent = true;
        ProtocolWriter.TryWrite(new { type = "exit", code = exitCode });
    }

    private async void RequestShutdownAsync()
    {
        if (_shutdownRequested)
        {
            return;
        }

        _shutdownRequested = true;
        EmitExit(0);

        // Give the parent a moment to read the exit message
        await Task.Delay(100);
        Close();
        Application.Current?.Shutdown(0);
    }

    private static bool IsInputRedirected()
    {
        try
        {
            return Console.IsInputRedirected;
        }
        catch
        {
            return false;
        }
    }
}

// ── Launch options ────────────────────────────────────────────────

public class BrowserLaunchOptions
{
    public string? InitialUrl { get; set; }
    public string DisplayName { get; set; } = "Clippy Browser Host";
    public string? UserDataDirectory { get; set; }
    public bool HwndMode { get; set; }
}

// ── Protocol writer (identical pattern to TerminalHost) ───────────

internal static class ProtocolWriter
{
    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    public static void TryWrite(object payload)
    {
        try
        {
            var json = JsonSerializer.Serialize(payload, SerializerOptions);
            lock (Gate)
            {
                Console.Out.WriteLine(json);
                Console.Out.Flush();
            }
        }
        catch
        {
        }
    }
}
