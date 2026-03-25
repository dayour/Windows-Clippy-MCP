using EasyWindowsTerminalControl;
using Microsoft.Terminal.Wpf;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace TerminalHost;

public partial class MainWindow : Window
{
    private static readonly Color TerminalBackground = (Color)ColorConverter.ConvertFromString("#1A1A2B");
    private static readonly Color TerminalForeground = (Color)ColorConverter.ConvertFromString("#FFE8E8E8");
    private static readonly Color TerminalSelection = (Color)ColorConverter.ConvertFromString("#FF333355");

    private readonly SessionLaunchOptions _options;
    private readonly CancellationTokenSource _controlLoopCancellation = new();
    private IntPtr _windowHandle;
    private int? _terminalProcessPid;
    private bool _readySent;
    private bool _exitSent;
    private bool _exitMonitorStarted;
    private bool _shutdownRequested;
    private bool _startupScriptInjected;

    public MainWindow(SessionLaunchOptions options)
    {
        _options = options;

        if (!string.IsNullOrWhiteSpace(_options.WorkingDirectory))
        {
            Directory.SetCurrentDirectory(_options.WorkingDirectory);
        }

        InitializeComponent();

        Title = _options.DisplayName;
        Terminal.StartupCommandLine = _options.BuildStartupCommandLine();
        Terminal.Theme = CreateTheme();
        Terminal.ConPTYTerm.TermReady += OnTerminalReady;

        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    public static SessionLaunchOptions ParseArguments(IEnumerable<string> rawArgs)
    {
        var options = new SessionLaunchOptions();
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
                case "--session-id":
                    options.SessionId = value ?? RequireValue(key, enumerator);
                    break;
                case "--model":
                    options.Model = value ?? RequireValue(key, enumerator);
                    break;
                case "--agent":
                    options.Agent = value ?? RequireValue(key, enumerator);
                    break;
                case "--mode":
                    options.Mode = value ?? RequireValue(key, enumerator);
                    break;
                case "--working-directory":
                    options.WorkingDirectory = NormalizeExistingPath(value ?? RequireValue(key, enumerator), key);
                    break;
                case "--config-dir":
                    options.ConfigDirectory = Path.GetFullPath(value ?? RequireValue(key, enumerator));
                    break;
                case "--display-name":
                    options.DisplayName = value ?? RequireValue(key, enumerator);
                    break;
                case "--command":
                    options.Command = value ?? RequireValue(key, enumerator);
                    break;
                case "--shell":
                    options.Shell = value ?? RequireValue(key, enumerator);
                    break;
                case "--env":
                    options.EnvironmentVariables.Add(ParseEnvironmentVariable(value ?? RequireValue(key, enumerator), key));
                    break;
                case "--allow-all-tools":
                    options.AllowAllTools = true;
                    break;
                case "--allow-all-paths":
                    options.AllowAllPaths = true;
                    break;
                case "--allow-all-urls":
                    options.AllowAllUrls = true;
                    break;
                case "--experimental":
                    options.Experimental = true;
                    break;
                case "--autopilot":
                    options.Autopilot = true;
                    break;
                case "--enable-all-github-mcp-tools":
                    options.EnableAllGitHubMcpTools = true;
                    break;
                case "--startup-script":
                    options.StartupScript = value ?? RequireValue(key, enumerator);
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

    private static EnvironmentVariableSpec ParseEnvironmentVariable(string rawValue, string argumentName)
    {
        var separatorIndex = rawValue.IndexOf('=');
        if (separatorIndex <= 0)
        {
            throw new ArgumentException($"{argumentName} must use KEY=VALUE format.");
        }

        var name = rawValue[..separatorIndex];
        if (name.Contains('='))
        {
            throw new ArgumentException($"{argumentName} contains an invalid environment variable name '{name}'.");
        }

        var value = rawValue[(separatorIndex + 1)..];
        return new EnvironmentVariableSpec(name, value);
    }

    private static string RequireValue(string argumentName, IEnumerator<string> enumerator)
    {
        if (!enumerator.MoveNext() || string.IsNullOrWhiteSpace(enumerator.Current))
        {
            throw new ArgumentException($"Missing value for {argumentName}");
        }

        return enumerator.Current;
    }

    private static string NormalizeExistingPath(string path, string argumentName)
    {
        var fullPath = Path.GetFullPath(path);
        if (!Directory.Exists(fullPath))
        {
            throw new DirectoryNotFoundException($"{argumentName} directory was not found: {fullPath}");
        }

        return fullPath;
    }

    private static TerminalTheme CreateTheme()
    {
        return new TerminalTheme
        {
            DefaultBackground = EasyTerminalControl.ColorToVal(TerminalBackground),
            DefaultForeground = EasyTerminalControl.ColorToVal(TerminalForeground),
            DefaultSelectionBackground = EasyTerminalControl.ColorToVal(TerminalSelection),
            CursorStyle = CursorStyle.BlinkingBar,
            ColorTable =
            [
                0x0C0C0C, 0xC50F1F, 0x13A10E, 0xC19C00,
                0x0037DA, 0x881798, 0x3A96DD, 0xCCCCCC,
                0x767676, 0xE74856, 0x16C60C, 0xF9F1A5,
                0x3B78FF, 0xB4009E, 0x61D6D6, 0xF2F2F2
            ]
        };
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _windowHandle = new WindowInteropHelper(this).Handle;
        TryEmitReady();
        if (_options.HwndMode)
        {
            Hide();
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (IsInputRedirected())
        {
            _ = RunControlLoopAsync(_controlLoopCancellation.Token);
        }
    }

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
                    if (!await TryHandleControlMessageAsync(document.RootElement))
                    {
                        return;
                    }
                }
                catch (JsonException ex)
                {
                    ReportProtocolError($"Invalid control message: {ex.Message}");
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

    private async Task<bool> TryHandleControlMessageAsync(JsonElement message)
    {
        var action = GetRequiredStringProperty(message, "action");
        switch (action)
        {
            case "write":
                await Dispatcher.InvokeAsync(() => WriteTerminalText(GetOptionalStringProperty(message, "text") ?? string.Empty));
                return true;
            case "input":
                var text = GetOptionalStringProperty(message, "text");
                if (string.IsNullOrWhiteSpace(text))
                {
                    ReportProtocolError("Input control message requires a non-empty 'text' value.");
                    return true;
                }

                await Dispatcher.InvokeAsync(() => SubmitTerminalInput(text));
                return true;
            case "resize":
                var cols = GetOptionalPositiveInt32Property(message, "cols", Terminal.Terminal.Columns);
                var rows = GetOptionalPositiveInt32Property(message, "rows", Terminal.Terminal.Rows);
                await Dispatcher.InvokeAsync(() => Terminal.ConPTYTerm.Resize(cols, rows));
                return true;
            case "close":
            case "shutdown":
                await Dispatcher.InvokeAsync(RequestShutdownAsync);
                return false;
            default:
                ReportProtocolError($"Unsupported control action '{action}'.");
                return true;
        }
    }

    private void WriteTerminalText(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        Terminal.ConPTYTerm.WriteToTerm(text);
    }

    private void SubmitTerminalInput(string text)
    {
        WriteTerminalText(text);
        if (text.Length == 0)
        {
            return;
        }

        var lastCharacter = text[^1];
        if (lastCharacter is not '\r' and not '\n')
        {
            Terminal.ConPTYTerm.WriteToTerm("\r");
        }
    }

    private static string GetRequiredStringProperty(JsonElement message, string propertyName)
    {
        var value = GetOptionalStringProperty(message, propertyName);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new JsonException($"Control message property '{propertyName}' must be a non-empty string.");
        }

        return value;
    }

    private static string? GetOptionalStringProperty(JsonElement message, string propertyName)
    {
        if (!message.TryGetProperty(propertyName, out var property))
        {
            return null;
        }

        return property.ValueKind switch
        {
            JsonValueKind.Null => null,
            JsonValueKind.String => property.GetString(),
            _ => throw new JsonException($"Control message property '{propertyName}' must be a string.")
        };
    }

    private static int GetOptionalPositiveInt32Property(JsonElement message, string propertyName, int fallbackValue)
    {
        if (!message.TryGetProperty(propertyName, out var property))
        {
            return fallbackValue;
        }

        if (property.ValueKind != JsonValueKind.Number || !property.TryGetInt32(out var value))
        {
            throw new JsonException($"Control message property '{propertyName}' must be an integer.");
        }

        if (value < 1)
        {
            throw new JsonException($"Control message property '{propertyName}' must be greater than zero.");
        }

        return value;
    }

    private static void ReportProtocolError(string message)
    {
        try
        {
            Console.Error.WriteLine($"Protocol error: {message}");
            Console.Error.Flush();
        }
        catch (IOException)
        {
            Debug.WriteLine(message);
        }
        catch (ObjectDisposedException)
        {
            Debug.WriteLine(message);
        }
    }

    private void OnTerminalReady(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            _terminalProcessPid ??= TryGetProcessId(Terminal.ConPTYTerm.Process);
            TryEmitReady();
            TryInjectStartupScript();

            if (_exitMonitorStarted)
            {
                return;
            }

            _exitMonitorStarted = true;
            _ = MonitorTerminalProcessExitAsync(Terminal.ConPTYTerm.Process);
        });
    }

    private async Task MonitorTerminalProcessExitAsync(object? processHandle)
    {
        if (processHandle is null)
        {
            return;
        }

        var process = TryGetWrappedProcess(processHandle);
        if (process is not null)
        {
            await Task.Run(process.WaitForExit);
        }
        else if (processHandle is EasyWindowsTerminalControl.Internals.IProcess terminalProcess)
        {
            await Task.Run(terminalProcess.WaitForExit);
        }
        else
        {
            return;
        }

        var exitCode = TryGetExitCode(processHandle);
        EmitExit(exitCode);

        await Dispatcher.InvokeAsync(() =>
        {
            if (_shutdownRequested)
            {
                return;
            }

            _shutdownRequested = true;
            Close();
            Application.Current?.Shutdown(exitCode);
        });
    }

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
            pid = _terminalProcessPid ?? Process.GetCurrentProcess().Id
        });
    }

    private void TryInjectStartupScript()
    {
        if (_startupScriptInjected || string.IsNullOrWhiteSpace(_options.StartupScript))
        {
            return;
        }

        _startupScriptInjected = true;
        SubmitTerminalInput(_options.StartupScript);
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
        _controlLoopCancellation.Cancel();

        try
        {
            Terminal.ConPTYTerm.CloseStdinToApp();
        }
        catch
        {
        }

        try
        {
            Terminal.ConPTYTerm.StopExternalTermOnly();
        }
        catch
        {
        }

        await Task.Yield();
        Close();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _controlLoopCancellation.Cancel();
        Terminal.ConPTYTerm.TermReady -= OnTerminalReady;

        if (!_shutdownRequested)
        {
            try
            {
                Terminal.ConPTYTerm.CloseStdinToApp();
            }
            catch
            {
            }

            try
            {
                Terminal.ConPTYTerm.StopExternalTermOnly();
            }
            catch
            {
            }
        }
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

    private static int? TryGetProcessId(object? processHandle)
    {
        var pidProperty = processHandle?.GetType().GetProperty("Pid");
        if (pidProperty?.GetValue(processHandle) is int pid)
        {
            return pid;
        }

        return TryGetWrappedProcess(processHandle)?.Id;
    }

    private static Process? TryGetWrappedProcess(object? processHandle)
    {
        var processProperty = processHandle?.GetType().GetProperty("Process");
        return processProperty?.GetValue(processHandle) as Process;
    }

    private static int TryGetExitCode(object? processHandle)
    {
        var process = TryGetWrappedProcess(processHandle);
        if (process is not null)
        {
            try
            {
                return process.ExitCode;
            }
            catch
            {
                return -1;
            }
        }

        var exitCodeProperty = processHandle?.GetType().GetProperty("ExitCode");
        if (exitCodeProperty?.GetValue(processHandle) is int exitCode)
        {
            return exitCode;
        }

        return -1;
    }
}

public sealed class SessionLaunchOptions
{
    private const string DefaultCommand = "copilot";

    public string? SessionId { get; set; }

    public string? Model { get; set; }

    public string? Agent { get; set; }

    public string? Mode { get; set; }

    public string? WorkingDirectory { get; set; }

    public string? ConfigDirectory { get; set; }

    public bool AllowAllTools { get; set; }

    public bool AllowAllPaths { get; set; }

    public bool AllowAllUrls { get; set; }

    public bool Experimental { get; set; }

    public bool Autopilot { get; set; }

    public bool EnableAllGitHubMcpTools { get; set; }

    public string DisplayName { get; set; } = "Clippy Terminal Host";

    public bool HwndMode { get; set; }

    public string? Command { get; set; }

    public string? Shell { get; set; }

    public string? StartupScript { get; set; }

    public List<EnvironmentVariableSpec> EnvironmentVariables { get; } = [];

    public string BuildStartupCommandLine()
    {
        EnsureSupportedCommandSelection();
        EnsureEnvironmentVariableSupport();

        if (!string.IsNullOrWhiteSpace(Command))
        {
            return Command;
        }

        if (!string.IsNullOrWhiteSpace(Shell))
        {
            return BuildShellCommandLine();
        }

        return BuildCopilotStartupCommandLine();
    }

    public string BuildCopilotCommandLine() => BuildStartupCommandLine();

    private string BuildShellCommandLine()
    {
        return Shell?.Trim().ToLowerInvariant() switch
        {
            "copilot" => BuildCopilotStartupCommandLine(),
            "powershell" => BuildCommandLine(["powershell.exe"]),
            "cmd" => BuildCommandLine(["cmd.exe"]),
            _ => throw new ArgumentException($"Unsupported shell shortcut '{Shell}'. Supported values: copilot, powershell, cmd.")
        };
    }

    private void EnsureSupportedCommandSelection()
    {
        if (!string.IsNullOrWhiteSpace(Command) && !string.IsNullOrWhiteSpace(Shell))
        {
            throw new ArgumentException("Specify either --command or --shell, not both.");
        }
    }

    private void EnsureEnvironmentVariableSupport()
    {
        if (EnvironmentVariables.Count == 0)
        {
            return;
        }

        throw new NotSupportedException(
            "TerminalHost captured one or more --env values, but EasyWindowsTerminalControl only exposes StartupCommandLine/TermPTY command-string launch APIs. " +
            "There is no supported ProcessStartInfo or environment-block hook for the spawned ConPTY child process without replacing the package's process factory.");
    }

    private string BuildCopilotStartupCommandLine()
    {
        var arguments = new List<string> { DefaultCommand };

        if (!string.IsNullOrWhiteSpace(SessionId))
        {
            arguments.Add($"--resume={SessionId}");
        }

        if (!string.IsNullOrWhiteSpace(ConfigDirectory))
        {
            arguments.Add("--config-dir");
            arguments.Add(ConfigDirectory);
        }

        arguments.Add("--no-color");

        if (!string.IsNullOrWhiteSpace(Model))
        {
            arguments.Add("--model");
            arguments.Add(Model);
        }

        if (!string.IsNullOrWhiteSpace(Agent))
        {
            arguments.Add("--agent");
            arguments.Add(Agent);
        }

        if (!string.IsNullOrWhiteSpace(Mode))
        {
            arguments.Add("--mode");
            arguments.Add(Mode);
        }

        if (AllowAllTools)
        {
            arguments.Add("--allow-all-tools");
        }

        if (AllowAllPaths)
        {
            arguments.Add("--allow-all-paths");
        }

        if (AllowAllUrls)
        {
            arguments.Add("--allow-all-urls");
        }

        if (Experimental)
        {
            arguments.Add("--experimental");
        }

        if (Autopilot)
        {
            arguments.Add("--autopilot");
        }

        if (EnableAllGitHubMcpTools)
        {
            arguments.Add("--enable-all-github-mcp-tools");
        }

        if (!string.IsNullOrWhiteSpace(WorkingDirectory))
        {
            arguments.Add("--add-dir");
            arguments.Add(WorkingDirectory);
        }

        return BuildCommandLine(arguments);
    }

    private static string BuildCommandLine(IEnumerable<string> arguments) => string.Join(" ", arguments.Select(CommandLineEncoder.Quote));
}

public readonly record struct EnvironmentVariableSpec(string Name, string Value);

internal static class CommandLineEncoder
{
    public static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (!value.Any(static ch => char.IsWhiteSpace(ch) || ch is '"'))
        {
            return value;
        }

        var builder = new StringBuilder(value.Length + 2);
        builder.Append('"');

        var backslashCount = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashCount += 1;
                continue;
            }

            if (character == '"')
            {
                builder.Append('\\', backslashCount * 2 + 1);
                builder.Append(character);
                backslashCount = 0;
                continue;
            }

            if (backslashCount > 0)
            {
                builder.Append('\\', backslashCount);
                backslashCount = 0;
            }

            builder.Append(character);
        }

        if (backslashCount > 0)
        {
            builder.Append('\\', backslashCount * 2);
        }

        builder.Append('"');
        return builder.ToString();
    }
}

internal static class ProtocolWriter
{
    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
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
