using Microsoft.Terminal.Wpf;
using Microsoft.Win32.SafeHandles;
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetHost;

internal sealed class ConPtyConnection : IWidgetTerminalConnection
{
    private readonly object _gate = new();
    private readonly string _commandLine;
    private readonly string _workingDirectory;
    private readonly IReadOnlyDictionary<string, string> _environmentOverrides;
    private readonly uint _initialRows;
    private readonly uint _initialColumns;

    private PseudoConsolePipe? _inputPipe;
    private PseudoConsolePipe? _outputPipe;
    private StreamWriter? _stdinWriter;
    private StreamReader? _stdoutReader;
    private CancellationTokenSource? _outputCancellation;
    private NativeProcess? _process;
    private Task? _outputTask;
    private Task? _exitTask;
    private IntPtr _pseudoConsole;
    private bool _started;
    private bool _closed;
    private int _exitRaised;
    private int _loggedOutputChunks;
    private int _loggedInputWrites;

    public ConPtyConnection(
        string commandLine,
        string workingDirectory,
        uint initialRows = 30,
        uint initialColumns = 120,
        IReadOnlyDictionary<string, string>? environmentOverrides = null)
    {
        _commandLine = commandLine;
        _workingDirectory = workingDirectory;
        _initialRows = initialRows;
        _initialColumns = initialColumns;
        _environmentOverrides = environmentOverrides ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    public event EventHandler<TerminalOutputEventArgs>? TerminalOutput;

    public event EventHandler<int?>? Exited;

    public event EventHandler<TerminalSessionCardSnapshot>? SessionCardUpdated;

#pragma warning disable CS0067 // ConPtyConnection does not emit copilot events; provided to satisfy interface.
    public event EventHandler<CopilotEventArgs>? CopilotEventReceived;
#pragma warning restore CS0067

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
                _inputPipe = new PseudoConsolePipe();
                _outputPipe = new PseudoConsolePipe();

                var size = new PseudoConsoleApi.COORD
                {
                    X = checked((short)_initialColumns),
                    Y = checked((short)_initialRows)
                };

                var createResult = PseudoConsoleApi.CreatePseudoConsole(
                    size,
                    _inputPipe.ReadSide,
                    _outputPipe.WriteSide,
                    0,
                    out _pseudoConsole);

                if (createResult != 0)
                {
                    throw new ExternalException($"CreatePseudoConsole failed with HRESULT 0x{createResult:X8}.", createResult);
                }

                _inputPipe.ReadSide.Dispose();
                _outputPipe.WriteSide.Dispose();

                _process = NativeProcess.Start(_commandLine, _workingDirectory, _environmentOverrides, _pseudoConsole);

                _stdinWriter = new StreamWriter(
                    new FileStream(_inputPipe.WriteSide, FileAccess.Write, 4096, false),
                    new UTF8Encoding(false))
                {
                    AutoFlush = true,
                    NewLine = "\r"
                };

                _stdoutReader = new StreamReader(
                    new FileStream(_outputPipe.ReadSide, FileAccess.Read, 4096, false),
                    new UTF8Encoding(false, false));

                _outputCancellation = new CancellationTokenSource();
                _outputTask = Task.Run(() => PumpOutputAsync(_outputCancellation.Token));
                _exitTask = Task.Run(() => WaitForExitAsync());

                WidgetHostLogger.Log(
                    $"ConPTY started. PID={_process.ProcessId}; Rows={_initialRows}; Cols={_initialColumns}; Cwd={_workingDirectory}; Command={_commandLine}");
            }
            catch (Exception ex)
            {
                WidgetHostLogger.Log($"ConPTY startup failed. Command={_commandLine}; Error={ex}");
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

        lock (_gate)
        {
            if (_closed || _stdinWriter is null)
            {
                return;
            }

            try
            {
                if (_loggedInputWrites < 12)
                {
                    var writeIndex = Interlocked.Increment(ref _loggedInputWrites);
                    if (writeIndex <= 12)
                    {
                        var sample = VisualizeControlText(data, 120);
                        WidgetHostLogger.Log(
                            $"ConPTY input write {writeIndex}. PID={_process?.ProcessId ?? 0}; Chars={data.Length}; Sample={sample}");
                    }
                }
                _stdinWriter.Write(data);
                _stdinWriter.Flush();
            }
            catch (IOException) when (_closed)
            {
            }
            catch (ObjectDisposedException) when (_closed)
            {
            }
        }
    }

    public void SubmitPrompt(string promptText)
    {
        if (string.IsNullOrWhiteSpace(promptText))
        {
            return;
        }

        var payload = promptText.EndsWith('\r') || promptText.EndsWith('\n')
            ? promptText
            : promptText + "\r";

        WriteInput(payload);
    }

    public void Resize(uint rows, uint columns)
    {
        if (rows == 0 || columns == 0)
        {
            return;
        }

        lock (_gate)
        {
            if (_closed || _pseudoConsole == IntPtr.Zero)
            {
                return;
            }

            var result = PseudoConsoleApi.ResizePseudoConsole(
                _pseudoConsole,
                new PseudoConsoleApi.COORD
                {
                    X = checked((short)columns),
                    Y = checked((short)rows)
                });

            if (result != 0)
            {
                WidgetHostLogger.Log($"ResizePseudoConsole failed for PID={_process?.ProcessId} with HRESULT 0x{result:X8}.");
            }
        }
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

        WidgetHostLogger.Log($"Closing ConPTY connection. PID={_process?.ProcessId ?? 0}");

        _outputCancellation?.Cancel();

        TryDispose(_stdinWriter);
        TryDispose(_stdoutReader);

        if (_process is not null &&
            !_process.WaitForExit(750, out _))
        {
            _process.TryTerminate(1);
            _ = _process.WaitForExit(1000, out _);
        }

        if (_pseudoConsole != IntPtr.Zero)
        {
            PseudoConsoleApi.ClosePseudoConsole(_pseudoConsole);
            _pseudoConsole = IntPtr.Zero;
        }

        TryDispose(_inputPipe);
        TryDispose(_outputPipe);
        TryDispose(_process);
        TryDispose(_outputCancellation);
    }

    private async Task PumpOutputAsync(CancellationToken cancellationToken)
    {
        if (_stdoutReader is null)
        {
            return;
        }

        var buffer = new char[4096];
        while (!cancellationToken.IsCancellationRequested)
        {
            int read;
            try
            {
                read = await _stdoutReader.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (IOException) when (_closed)
            {
                break;
            }
            catch (ObjectDisposedException) when (_closed)
            {
                break;
            }

            if (read == 0)
            {
                break;
            }

            if (_loggedOutputChunks < 12)
            {
                var chunkIndex = Interlocked.Increment(ref _loggedOutputChunks);
                if (chunkIndex <= 12)
                {
                    var sample = VisualizeControlText(new string(buffer, 0, read), 120);
                    WidgetHostLogger.Log(
                        $"ConPTY output chunk {chunkIndex}. PID={_process?.ProcessId ?? 0}; Chars={read}; Sample={sample}");
                }
            }

            TerminalOutput?.Invoke(this, new TerminalOutputEventArgs(new string(buffer, 0, read)));
        }
    }

    private void WaitForExitAsync()
    {
        var exitCode = _process?.WaitForExit();
        if (Interlocked.Exchange(ref _exitRaised, 1) == 0)
        {
            WidgetHostLogger.Log($"ConPTY process exited. PID={_process?.ProcessId ?? 0}; ExitCode={exitCode?.ToString() ?? "(unknown)"}");
            Exited?.Invoke(this, exitCode);
        }
    }

    private void CleanupStartupFailure()
    {
        if (_pseudoConsole != IntPtr.Zero)
        {
            PseudoConsoleApi.ClosePseudoConsole(_pseudoConsole);
            _pseudoConsole = IntPtr.Zero;
        }

        TryDispose(_stdinWriter);
        TryDispose(_stdoutReader);
        TryDispose(_inputPipe);
        TryDispose(_outputPipe);
        TryDispose(_process);
        TryDispose(_outputCancellation);
    }

    private void ThrowIfClosed()
    {
        ObjectDisposedException.ThrowIf(_closed, this);
    }

    private static void TryDispose(IDisposable? disposable)
    {
        disposable?.Dispose();
    }

    private static string VisualizeControlText(string text, int maxLength)
    {
        var builder = new StringBuilder();
        foreach (var ch in text.Take(maxLength))
        {
            builder.Append(ch switch
            {
                '\u001b' => "\\e",
                '\r' => "\\r",
                '\n' => "\\n",
                '\t' => "\\t",
                _ when char.IsControl(ch) => $"\\x{(int)ch:X2}",
                _ => ch.ToString()
            });
        }

        if (text.Length > maxLength)
        {
            builder.Append("...");
        }

        return builder.ToString();
    }
}

internal sealed class PseudoConsolePipe : IDisposable
{
    public PseudoConsolePipe()
    {
        if (!PseudoConsoleApi.CreatePipe(out var readSide, out var writeSide, IntPtr.Zero, 0))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe failed.");
        }

        ReadSide = readSide;
        WriteSide = writeSide;
    }

    public SafeFileHandle ReadSide { get; }

    public SafeFileHandle WriteSide { get; }

    public void Dispose()
    {
        ReadSide.Dispose();
        WriteSide.Dispose();
    }
}

internal sealed class NativeProcess : IDisposable
{
    private readonly IntPtr _attributeList;
    private readonly PseudoConsoleApi.PROCESS_INFORMATION _processInfo;
    private bool _disposed;

    private NativeProcess(IntPtr attributeList, PseudoConsoleApi.PROCESS_INFORMATION processInfo)
    {
        _attributeList = attributeList;
        _processInfo = processInfo;
    }

    public int ProcessId => _processInfo.dwProcessId;

    public static NativeProcess Start(
        string commandLine,
        string workingDirectory,
        IReadOnlyDictionary<string, string> environmentOverrides,
        IntPtr pseudoConsole)
    {
        var attributeListSize = IntPtr.Zero;
        _ = PseudoConsoleApi.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
        if (attributeListSize == IntPtr.Zero)
        {
            throw new InvalidOperationException("InitializeProcThreadAttributeList did not return a valid attribute list size.");
        }

        var attributeList = Marshal.AllocHGlobal(attributeListSize);
        try
        {
            if (!PseudoConsoleApi.InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList failed.");
            }

            var pseudoConsoleHandle = pseudoConsole;
            if (!PseudoConsoleApi.UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    (IntPtr)PseudoConsoleApi.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    pseudoConsoleHandle,
                    (IntPtr)IntPtr.Size,
                    IntPtr.Zero,
                    IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute failed.");
            }

            var startupInfo = new PseudoConsoleApi.STARTUPINFOEX
            {
                StartupInfo = new PseudoConsoleApi.STARTUPINFO
                {
                    cb = Marshal.SizeOf<PseudoConsoleApi.STARTUPINFOEX>()
                },
                lpAttributeList = attributeList
            };

            var processAttributes = new PseudoConsoleApi.SECURITY_ATTRIBUTES
            {
                nLength = Marshal.SizeOf<PseudoConsoleApi.SECURITY_ATTRIBUTES>()
            };

            var threadAttributes = new PseudoConsoleApi.SECURITY_ATTRIBUTES
            {
                nLength = Marshal.SizeOf<PseudoConsoleApi.SECURITY_ATTRIBUTES>()
            };

            var environmentBlock = EnvironmentBlockBuilder.Create(environmentOverrides);
            try
            {
                var creationFlags = PseudoConsoleApi.EXTENDED_STARTUPINFO_PRESENT;
                if (environmentBlock != IntPtr.Zero)
                {
                    creationFlags |= PseudoConsoleApi.CREATE_UNICODE_ENVIRONMENT;
                }

                if (!PseudoConsoleApi.CreateProcess(
                        null,
                        commandLine,
                        ref processAttributes,
                        ref threadAttributes,
                        false,
                        creationFlags,
                        environmentBlock,
                        workingDirectory,
                        ref startupInfo,
                        out var processInfo))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), $"CreateProcess failed for '{commandLine}'.");
                }

                attributeList = IntPtr.Zero;
                return new NativeProcess(startupInfo.lpAttributeList, processInfo);
            }
            finally
            {
                if (environmentBlock != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(environmentBlock);
                }
            }
        }
        finally
        {
            if (attributeList != IntPtr.Zero)
            {
                PseudoConsoleApi.DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
            }
        }
    }

    public int? WaitForExit()
    {
        if (_processInfo.hProcess == IntPtr.Zero)
        {
            return null;
        }

        var waitResult = PseudoConsoleApi.WaitForSingleObject(_processInfo.hProcess, PseudoConsoleApi.INFINITE);
        if (waitResult == PseudoConsoleApi.WAIT_FAILED)
        {
            var error = Marshal.GetLastWin32Error();
            if (error == 6)
            {
                return TryGetExitCode();
            }

            throw new Win32Exception(error, "WaitForSingleObject failed.");
        }

        return TryGetExitCode();
    }

    public bool WaitForExit(uint timeoutMilliseconds, out int? exitCode)
    {
        exitCode = null;
        if (_processInfo.hProcess == IntPtr.Zero)
        {
            return true;
        }

        var waitResult = PseudoConsoleApi.WaitForSingleObject(_processInfo.hProcess, timeoutMilliseconds);
        if (waitResult == PseudoConsoleApi.WAIT_OBJECT_0)
        {
            exitCode = TryGetExitCode();
            return true;
        }

        if (waitResult == PseudoConsoleApi.WAIT_TIMEOUT)
        {
            return false;
        }

        var errorCode = Marshal.GetLastWin32Error();
        if (errorCode == 6)
        {
            exitCode = TryGetExitCode();
            return true;
        }

        throw new Win32Exception(errorCode, "WaitForSingleObject failed.");
    }

    public void TryTerminate(uint exitCode)
    {
        if (_processInfo.hProcess == IntPtr.Zero)
        {
            return;
        }

        _ = PseudoConsoleApi.TerminateProcess(_processInfo.hProcess, exitCode);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_attributeList != IntPtr.Zero)
        {
            PseudoConsoleApi.DeleteProcThreadAttributeList(_attributeList);
            Marshal.FreeHGlobal(_attributeList);
        }

        if (_processInfo.hThread != IntPtr.Zero)
        {
            _ = PseudoConsoleApi.CloseHandle(_processInfo.hThread);
        }

        if (_processInfo.hProcess != IntPtr.Zero)
        {
            _ = PseudoConsoleApi.CloseHandle(_processInfo.hProcess);
        }
    }

    private int? TryGetExitCode()
    {
        if (_processInfo.hProcess == IntPtr.Zero)
        {
            return null;
        }

        return PseudoConsoleApi.GetExitCodeProcess(_processInfo.hProcess, out var exitCode)
            ? unchecked((int)exitCode)
            : null;
    }
}

internal static class EnvironmentBlockBuilder
{
    public static IntPtr Create(IReadOnlyDictionary<string, string> overrides)
    {
        if (overrides.Count == 0)
        {
            return IntPtr.Zero;
        }

        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            if (entry.Key is string key && entry.Value is string value)
            {
                environment[key] = value;
            }
        }

        foreach (var pair in overrides)
        {
            environment[pair.Key] = pair.Value;
        }

        var builder = new StringBuilder();
        foreach (var pair in environment.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase))
        {
            builder.Append(pair.Key);
            builder.Append('=');
            builder.Append(pair.Value);
            builder.Append('\0');
        }

        builder.Append('\0');

        var bytes = Encoding.Unicode.GetBytes(builder.ToString());
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }
}
