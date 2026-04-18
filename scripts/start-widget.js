#!/usr/bin/env node

const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const {
  SERVICE_COMMAND_TYPES,
  createWidgetLaunchCommand,
  readJsonFile,
  writeServiceCommandFile
} = require('./widget-service-protocol');

const packageDir = path.resolve(__dirname, '..');
const nativeWidgetHostPath = path.join(
  packageDir,
  'widget',
  'WidgetHost',
  'bin',
  'Debug',
  'net8.0-windows',
  'WidgetHost.exe'
);
const legacyWidgetScriptPath = path.join(packageDir, 'widget', 'clippy-widget.ps1');
const dashboardWidgetScriptPath = path.join(packageDir, 'widget', 'start.js');
const dashboardServerScriptPath = path.join(packageDir, 'widget', 'app', 'server.py');
const serviceScriptPath = path.join(__dirname, 'clippy_widget_service.js');
const dashboardLockfilePath = process.env.MCS_LOCKFILE || path.join(os.homedir(), '.mcs-agent-builder.lock');

const stateDir = path.join(
  process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'),
  'Windows-Clippy-MCP'
);
const logsDir = path.join(stateDir, 'logs');
const requestsDir = path.join(stateDir, 'widget-requests');
const responsesDir = path.join(stateDir, 'widget-responses');

const widgetLogPath = path.join(logsDir, 'widget-launch.log');
const widgetDebugLogPath = path.join(stateDir, 'widget-debug.log');
const serviceLogPath = path.join(logsDir, 'clippy_widget_service.log');
const serviceStatePath = path.join(stateDir, 'clippy_widget_service.json');
const sessionStatePath = path.join(stateDir, 'copilot-session.json');
const VALID_RUNTIME_SELECTIONS = new Set(['auto', 'native', 'powershell']);

function quoteForPowerShell(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function runPowerShellCommand(command, fallbackErrorMessage) {
  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', command],
    {
      cwd: packageDir,
      windowsHide: true,
      encoding: 'utf8'
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    throw new Error(detail || fallbackErrorMessage);
  }

  return result.stdout || '';
}

function parseJsonCollection(rawValue) {
  const trimmed = String(rawValue || '').trim();
  if (!trimmed) {
    return [];
  }

  const parsed = JSON.parse(trimmed);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function ensureStateDirectories() {
  fs.mkdirSync(logsDir, { recursive: true });
  fs.mkdirSync(requestsDir, { recursive: true });
  fs.mkdirSync(responsesDir, { recursive: true });
}

function appendLog(logPath, message) {
  ensureStateDirectories();
  fs.appendFileSync(logPath, `[${new Date().toISOString()}] ${message}\n`, 'utf8');
}

function normalizeWidgetArguments(rawArgs) {
  const normalized = [];

  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];

    if (arg === '--no-welcome') {
      normalized.push('-NoWelcome');
      continue;
    }

    if (arg === '--open-chat') {
      normalized.push('-OpenChat');
      continue;
    }

    if (arg === '--session-id' && rawArgs[index + 1]) {
      normalized.push('-SessionId', rawArgs[index + 1]);
      index += 1;
      continue;
    }

    if (arg.startsWith('--session-id=')) {
      normalized.push('-SessionId', arg.slice('--session-id='.length));
      continue;
    }

    normalized.push(arg);
  }

  return normalized;
}

function normalizeNativeWidgetArguments(rawArgs) {
  return rawArgs.map((arg) => String(arg));
}

function isProcessRunning(pid) {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }

  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function parseCsvLine(line) {
  const values = [];
  let current = '';
  let inQuotes = false;

  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];

    if (char === '"') {
      if (inQuotes && line[index + 1] === '"') {
        current += '"';
        index += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char === ',' && !inQuotes) {
      values.push(current);
      current = '';
      continue;
    }

    current += char;
  }

  values.push(current);
  return values;
}

function listNativeWidgetProcesses() {
  return listTasklistProcessesByImageName('WidgetHost.exe')
    .map((processInfo) => ({
      ...processInfo,
      commandLine: processInfo.commandLine || 'WidgetHost.exe'
    }));
}

function listNativeTerminalHostProcesses() {
  return listTasklistProcessesByImageName('TerminalHost.exe');
}

function listTasklistProcessesByImageName(imageName) {
  const result = spawnSync(
    'tasklist',
    ['/FI', `IMAGENAME eq ${imageName}`, '/FO', 'CSV', '/NH', '/V'],
    {
      cwd: packageDir,
      windowsHide: true,
      encoding: 'utf8'
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    throw new Error(detail || 'Failed to inspect running WidgetHost.exe processes.');
  }

  return String(result.stdout || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !/^INFO:/i.test(line))
    .map(parseCsvLine)
    .filter((fields) => String(fields[0] || '').toLowerCase() === imageName.toLowerCase())
    .map((fields) => ({
      pid: Number.parseInt(fields[1], 10),
      parentProcessId: null,
      creationDate: null,
      commandLine: fields[0] || imageName,
      windowTitle: fields[8] || null
    }))
    .filter((processInfo) => Number.isInteger(processInfo.pid) && processInfo.pid > 0 && isProcessRunning(processInfo.pid));
}

function getWidgetEntryPoint(runtimePreference = 'auto') {
  const normalizedRuntime = VALID_RUNTIME_SELECTIONS.has(runtimePreference)
    ? runtimePreference
    : 'auto';

  if (normalizedRuntime === 'powershell') {
    if (fs.existsSync(legacyWidgetScriptPath)) {
      return {
        kind: 'legacy',
        path: legacyWidgetScriptPath
      };
    }

    throw new Error(`PowerShell widget host not found at ${legacyWidgetScriptPath}.`);
  }

  if (fs.existsSync(nativeWidgetHostPath)) {
    return {
      kind: 'native',
      path: nativeWidgetHostPath
    };
  }

  if (fs.existsSync(dashboardWidgetScriptPath) && fs.existsSync(dashboardServerScriptPath)) {
    return {
      kind: 'dashboard',
      path: dashboardWidgetScriptPath
    };
  }

  if (fs.existsSync(legacyWidgetScriptPath)) {
    return {
      kind: 'legacy',
      path: legacyWidgetScriptPath
    };
  }

  throw new Error(
    `Widget entrypoint not found. Checked: ${nativeWidgetHostPath}, ${dashboardWidgetScriptPath}, ${legacyWidgetScriptPath}`
  );
}

function readDashboardLockState() {
  try {
    const payload = JSON.parse(fs.readFileSync(dashboardLockfilePath, 'utf8'));
    const pid = Number.parseInt(payload.pid, 10);
    const port = Number.parseInt(payload.port, 10);

    if (!Number.isInteger(pid) || pid <= 0 || !isProcessRunning(pid)) {
      try {
        fs.unlinkSync(dashboardLockfilePath);
      } catch {
      }
      return null;
    }

    return {
      pid,
      port: Number.isInteger(port) && port > 0 ? port : null,
      url: Number.isInteger(port) && port > 0 ? `http://localhost:${port}` : null
    };
  } catch {
    return null;
  }
}

function probeHttpReady(url, timeoutMs = 1500) {
  return new Promise((resolve) => {
    const request = http.get(url, (response) => {
      response.resume();
      resolve(response.statusCode === 200);
    });

    request.setTimeout(timeoutMs, () => {
      request.destroy();
      resolve(false);
    });

    request.on('error', () => resolve(false));
  });
}

function readServiceState() {
  try {
    const payload = readJsonFile(serviceStatePath);
    if (payload && isProcessRunning(payload.pid)) {
      // Guard against false-positive PID checks on Windows: if heartbeat
      // is older than 10 seconds the service is likely gone.
      if (payload.heartbeatAt) {
        const heartbeatAge = Date.now() - Date.parse(payload.heartbeatAt);
        if (heartbeatAge > 10000) {
          // Stale heartbeat -- fall through to cleanup
        } else {
          return payload;
        }
      } else {
        return payload;
      }
    }
  } catch {
    return null;
  }

  try {
    fs.unlinkSync(serviceStatePath);
  } catch {
  }

  return null;
}

function readWidgetSessionState() {
  try {
    return JSON.parse(fs.readFileSync(sessionStatePath, 'utf8'));
  } catch {
    return null;
  }
}

function readWidgetDebugLogLines() {
  try {
    return fs.readFileSync(widgetDebugLogPath, 'utf8')
      .split(/\r?\n/)
      .filter((line) => line.trim().length > 0);
  } catch {
    return [];
  }
}

function parseWidgetLogTimestamp(line) {
  const match = /^\[([^\]]+)\]/.exec(String(line || ''));
  if (!match) {
    return Number.NaN;
  }

  return Date.parse(match[1]);
}

function getFreshWidgetLifecycleState(requestCreatedAt) {
  const lines = readWidgetDebugLogLines();
  let hostStarted = false;
  let widgetRendered = false;
  let hostReady = false;
  let fatalError = null;

  for (const line of lines) {
    const timestamp = parseWidgetLogTimestamp(line);
    if (!Number.isFinite(timestamp) || timestamp < requestCreatedAt) {
      continue;
    }

    if (line.includes('Started Node bridge host') || line.includes('Started embedded terminal')) {
      hostStarted = true;
    }

    if (line.includes('Widget content rendered')) {
      widgetRendered = true;
    }

    if (
      line.includes('"type":"session.ready"')
      || (line.includes('"type":"host.metadata"') && line.includes('"hostState":"running"'))
      || line.includes('TERM-STDOUT [pending] {"type":"ready"')
      || line.includes('Started embedded terminal')
    ) {
      hostReady = true;
    }

    if (line.includes(' FATAL ') || line.includes('DispatcherUnhandledException')) {
      fatalError = line;
    }
  }

  return {
    hostStarted,
    widgetRendered,
    hostReady,
    fatalError
  };
}

function hasRunningWidgetHost(sessionState) {
  if (!sessionState || !Array.isArray(sessionState.Tabs)) {
    return false;
  }

  return sessionState.Tabs.some((tab) => {
    if (!tab || String(tab.HostState || '').toLowerCase() !== 'running') {
      return false;
    }

    const hostPid = Number.parseInt(tab.HostPid, 10);
    return Number.isInteger(hostPid) && isProcessRunning(hostPid);
  });
}

async function waitForWidgetReady(options = {}) {
  const widgetEntryPoint = getWidgetEntryPoint(options.runtime);
  if (widgetEntryPoint.kind === 'native') {
    return waitForNativeWidgetReady(options);
  }

  if (widgetEntryPoint.kind === 'dashboard') {
    return waitForDashboardWidgetReady(options);
  }

  return waitForLegacyWidgetReady(options);
}

async function waitForDashboardWidgetReady(options = {}) {
  const {
    expectedPid = null,
    timeoutMs = 30000
  } = options;

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const dashboardState = readDashboardLockState();
    const widgetProcesses = listWidgetProcesses();
    const matchesExpectedPid = expectedPid
      ? (dashboardState && dashboardState.pid === expectedPid)
        || widgetProcesses.some((processInfo) => processInfo.pid === expectedPid)
      : widgetProcesses.length > 0 || !!dashboardState;

    if (dashboardState && matchesExpectedPid && dashboardState.url) {
      if (await probeHttpReady(dashboardState.url)) {
        return {
          readySource: 'dashboard-lockfile',
          widgetProcesses,
          dashboardState
        };
      }
    }

    await wait(250);
  }

  throw new Error('Widget dashboard did not become ready within 30 seconds.');
}

async function waitForNativeWidgetReady(options = {}) {
  const {
    expectedPid = null,
    timeoutMs = 20000
  } = options;

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const widgetProcesses = listWidgetProcesses();
    const terminalHostProcesses = listNativeTerminalHostProcesses();
    const readyProcess = expectedPid
      ? widgetProcesses.find((processInfo) => processInfo.pid === expectedPid)
      : widgetProcesses[0];
    const title = String(readyProcess?.windowTitle || '');
    const hasReadyWindowTitle = /Opened |Active tab:/i.test(title);

    if (readyProcess && (hasReadyWindowTitle || terminalHostProcesses.length > 0)) {
      return {
        readySource: terminalHostProcesses.length > 0 ? 'native-terminal-host' : 'native-window',
        widgetProcesses,
        terminalHostProcesses
      };
    }

    await wait(250);
  }

  throw new Error('Native WidgetHost did not become ready within 20 seconds.');
}

async function waitForLegacyWidgetReady(options = {}) {
  const {
    requestCreatedAt = Date.now(),
    expectedPid = null,
    timeoutMs = 20000
  } = options;

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const widgetProcesses = listWidgetProcesses();
    const terminalHostProcesses = listEmbeddedTerminalHostProcesses();
    const widgetRunning = expectedPid
      ? widgetProcesses.some((processInfo) => processInfo.pid === expectedPid)
      : widgetProcesses.length > 0;
    const widgetProcessIds = new Set(widgetProcesses.map((processInfo) => processInfo.pid));
    const embeddedTerminalRunning = terminalHostProcesses.some(
      (processInfo) => processInfo.parentProcessId && widgetProcessIds.has(processInfo.parentProcessId)
    );

    const sessionState = readWidgetSessionState();
    const updatedAt = sessionState && sessionState.UpdatedAt
      ? Date.parse(sessionState.UpdatedAt)
      : Number.NaN;
    const stateIsFresh = Number.isFinite(updatedAt) && updatedAt >= requestCreatedAt;
    const lifecycleState = getFreshWidgetLifecycleState(requestCreatedAt);

    if (lifecycleState.fatalError) {
      throw new Error(`Widget startup failed: ${lifecycleState.fatalError}`);
    }

    if (lifecycleState.hostReady && (widgetRunning || lifecycleState.widgetRendered || lifecycleState.hostStarted || embeddedTerminalRunning)) {
      return {
        readySource: 'widget-debug-log',
        widgetProcesses,
        terminalHostProcesses,
        sessionState
      };
    }

    if (widgetRunning && embeddedTerminalRunning) {
      return {
        readySource: 'terminal-host-process',
        widgetProcesses,
        terminalHostProcesses,
        sessionState
      };
    }

    if ((widgetRunning || lifecycleState.widgetRendered) && stateIsFresh && hasRunningWidgetHost(sessionState)) {
      return {
        readySource: 'session-state',
        widgetProcesses,
        terminalHostProcesses,
        sessionState
      };
    }

    await wait(250);
  }

  throw new Error('Widget did not become ready with a running integrated terminal host within 20 seconds.');
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function normalizeLaunchOptions(options = {}) {
  return {
    runtime: VALID_RUNTIME_SELECTIONS.has(options.runtime) ? options.runtime : 'auto',
    sessionId: options.sessionId || null,
    openChat: !!options.openChat,
    noWelcome: !!options.noWelcome,
    extraArgs: normalizeWidgetArguments(options.extraArgs || [])
  };
}

function mergeLaunchOptions(baseOptions = {}, overrideOptions = {}) {
  const base = normalizeLaunchOptions(baseOptions);
  const override = normalizeLaunchOptions(overrideOptions);

  return {
    runtime: override.runtime !== 'auto' ? override.runtime : base.runtime,
    sessionId: override.sessionId || base.sessionId || null,
    openChat: base.openChat || override.openChat,
    noWelcome: base.noWelcome || override.noWelcome,
    extraArgs: normalizeWidgetArguments([
      ...base.extraArgs,
      ...override.extraArgs
    ])
  };
}

function buildNativeWidgetArguments(options = {}) {
  const args = [];

  if (options.noWelcome) {
    args.push('--no-welcome');
  }

  if (options.openChat) {
    args.push('--open-chat');
  }

  if (options.sessionId) {
    args.push('--session-id', options.sessionId);
  }

  args.push(...normalizeNativeWidgetArguments(options.extraArgs || []));
  return args;
}

function buildLegacyWidgetArguments(options = {}) {
  const args = [];

  if (options.noWelcome) {
    args.push('-NoWelcome');
  }

  if (options.openChat) {
    args.push('-OpenChat');
  }

  if (options.sessionId) {
    args.push('-SessionId', options.sessionId);
  }

  args.push(...normalizeWidgetArguments(options.extraArgs || []));
  return args;
}

function launchWidget(options = {}) {
  if (process.platform !== 'win32') {
    throw new Error('Windows Clippy widget can only be launched on Windows.');
  }

  const widgetEntryPoint = getWidgetEntryPoint(options.runtime);

  const {
    debug = false,
    sessionId,
    openChat = false,
    noWelcome = false,
    extraArgs = []
  } = options;

  if (widgetEntryPoint.kind === 'native') {
    const existingNativeWidgets = listNativeWidgetProcesses();
    if (existingNativeWidgets.length > 0) {
      appendLog(
        widgetLogPath,
        `Native widget host already running (pid ${existingNativeWidgets[0].pid}).`
      );
      return {
        child: null,
        pid: existingNativeWidgets[0].pid,
        logPath: widgetLogPath,
        reusedExisting: true
      };
    }

    ensureStateDirectories();
    appendLog(widgetLogPath, `Native widget launch requested from ${packageDir}`);

    const widgetArgs = buildNativeWidgetArguments({
      sessionId,
      openChat,
      noWelcome,
      extraArgs
    });

    if (debug) {
      const child = spawn(widgetEntryPoint.path, widgetArgs, {
        cwd: packageDir,
        windowsHide: false,
        detached: false,
        stdio: 'inherit'
      });

      return {
        child,
        pid: child.pid || null,
        logPath: widgetLogPath
      };
    }

    const child = spawn(widgetEntryPoint.path, widgetArgs, {
      cwd: packageDir,
      detached: true,
      stdio: 'ignore',
      windowsHide: true
    });

    child.unref();

    if (!Number.isInteger(child.pid) || child.pid <= 0) {
      throw new Error('Failed to start the native widget host process.');
    }

    return {
      child: null,
      pid: Number.isInteger(child.pid) ? child.pid : null,
      logPath: widgetLogPath
    };
  }

  if (widgetEntryPoint.kind === 'dashboard') {
    const existingDashboard = readDashboardLockState();
    if (existingDashboard) {
      appendLog(
        widgetLogPath,
        `Dashboard widget already running at ${existingDashboard.url || 'an unknown URL'} (pid ${existingDashboard.pid}).`
      );
      return {
        child: null,
        pid: existingDashboard.pid,
        url: existingDashboard.url,
        port: existingDashboard.port,
        logPath: widgetLogPath,
        reusedExisting: true
      };
    }

    if (sessionId || openChat || noWelcome || extraArgs.length > 0) {
      appendLog(
        widgetLogPath,
        'Dashboard widget launch ignores legacy per-session options (session/open-chat/no-welcome/extra args).'
      );
    }

    ensureStateDirectories();
    appendLog(widgetLogPath, `Dashboard widget launch requested from ${packageDir}`);

    const dashboardArgs = [widgetEntryPoint.path];
    if (debug) {
      const child = spawn(process.execPath, dashboardArgs, {
        cwd: packageDir,
        windowsHide: false,
        detached: false,
        stdio: 'inherit'
      });

      return {
        child,
        pid: child.pid || null,
        logPath: widgetLogPath
      };
    }

    const child = spawn(process.execPath, dashboardArgs, {
      cwd: packageDir,
      windowsHide: true,
      detached: true,
      stdio: 'ignore'
    });
    child.unref();

    return {
      child: null,
      pid: child.pid || null,
      logPath: widgetLogPath
    };
  }

  if (widgetEntryPoint.kind === 'legacy') {
    const existingLegacyWidgets = listWidgetProcesses('powershell');
    if (existingLegacyWidgets.length > 0) {
      appendLog(
        widgetLogPath,
        `Legacy PowerShell widget host already running (pid ${existingLegacyWidgets[0].pid}).`
      );
      return {
        child: null,
        pid: existingLegacyWidgets[0].pid,
        logPath: widgetLogPath,
        reusedExisting: true
      };
    }

    ensureStateDirectories();
    appendLog(widgetLogPath, `Legacy PowerShell widget launch requested from ${packageDir}`);

    const widgetArgs = buildLegacyWidgetArguments({
      sessionId,
      openChat,
      noWelcome,
      extraArgs
    });

    const psArgs = [
      '-NoProfile',
      '-Sta',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      widgetEntryPoint.path,
      ...widgetArgs
    ];

    if (debug) {
      const child = spawn('pwsh.exe', psArgs, {
        cwd: packageDir,
        windowsHide: false,
        detached: false,
        stdio: 'inherit'
      });

      return {
        child,
        pid: child.pid || null,
        logPath: widgetLogPath
      };
    }

    const child = spawn('pwsh.exe', psArgs, {
      cwd: packageDir,
      detached: true,
      stdio: 'ignore',
      windowsHide: true
    });

    child.unref();

    if (!Number.isInteger(child.pid) || child.pid <= 0) {
      throw new Error('Failed to start the legacy PowerShell widget host process.');
    }

    return {
      child: null,
      pid: Number.isInteger(child.pid) ? child.pid : null,
      logPath: widgetLogPath
    };
  }

  throw new Error(`Unsupported widget entrypoint kind: ${widgetEntryPoint.kind}`);
}

function listWidgetProcesses(runtimePreference = 'auto') {
  if (process.platform !== 'win32') {
    return [];
  }

  const widgetEntryPoint = getWidgetEntryPoint(runtimePreference);
  if (widgetEntryPoint.kind === 'native') {
    return listNativeWidgetProcesses();
  }

  if (widgetEntryPoint.kind === 'dashboard') {
    const dashboardState = readDashboardLockState();
    if (!dashboardState) {
      return [];
    }

    return [
      {
        pid: dashboardState.pid,
        parentProcessId: null,
        creationDate: null,
        commandLine: `${process.execPath} ${widgetEntryPoint.path}`,
        port: dashboardState.port,
        url: dashboardState.url
      }
    ];
  }

  const widgetScriptName = path.basename(widgetEntryPoint.path);
  const command = [
    '$ErrorActionPreference = "Stop"',
    `$widgetScriptName = ${quoteForPowerShell(widgetScriptName)}`,
    '$escapedWidgetScriptName = [regex]::Escape($widgetScriptName)',
    '$processes = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match ("-File.*" + $escapedWidgetScriptName) } | Select-Object ProcessId, ParentProcessId, CreationDate, CommandLine',
    'if ($processes) { $processes | ConvertTo-Json -Compress }'
  ].join('; ');

  return parseJsonCollection(
    runPowerShellCommand(command, 'Failed to inspect running widget host processes.')
  )
    .map((processInfo) => ({
      pid: Number.parseInt(processInfo.ProcessId, 10),
      parentProcessId: Number.parseInt(processInfo.ParentProcessId, 10) || null,
      creationDate: processInfo.CreationDate || null,
      commandLine: processInfo.CommandLine || ''
    }))
    .filter((processInfo) => Number.isInteger(processInfo.pid) && processInfo.pid > 0 && isProcessRunning(processInfo.pid));
}

function listEmbeddedTerminalHostProcesses() {
  if (process.platform !== 'win32') {
    return [];
  }

  const command = [
    '$ErrorActionPreference = "Stop"',
    "$processes = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'TerminalHost.exe' } | Select-Object ProcessId, ParentProcessId, CreationDate, CommandLine",
    'if ($processes) { $processes | ConvertTo-Json -Compress }'
  ].join('; ');

  return parseJsonCollection(
    runPowerShellCommand(command, 'Failed to inspect running embedded terminal host processes.')
  )
    .map((processInfo) => ({
      pid: Number.parseInt(processInfo.ProcessId, 10),
      parentProcessId: Number.parseInt(processInfo.ParentProcessId, 10) || null,
      creationDate: processInfo.CreationDate || null,
      commandLine: processInfo.CommandLine || ''
    }))
    .filter((processInfo) => Number.isInteger(processInfo.pid) && processInfo.pid > 0 && isProcessRunning(processInfo.pid));
}

function parseLaunchOptionsFromCommandLine(commandLine) {
  const normalizedCommandLine = String(commandLine || '');
  const sessionIdMatch = normalizedCommandLine.match(
    /(?:-SessionId|--session-id)\s+(?:"([^"]+)"|'([^']+)'|([^\s]+))/i
  ) || normalizedCommandLine.match(
    /--session-id=(?:"([^"]+)"|([^\s]+))/i
  );

  return normalizeLaunchOptions({
    sessionId: sessionIdMatch
      ? sessionIdMatch[1] || sessionIdMatch[2] || sessionIdMatch[3] || sessionIdMatch[4]
      : null,
    openChat: /(^|\s)(?:-OpenChat|--open-chat)(?=\s|$)/i.test(normalizedCommandLine),
    noWelcome: /(^|\s)(?:-NoWelcome|--no-welcome)(?=\s|$)/i.test(normalizedCommandLine)
  });
}

function getWidgetLaunchSnapshots(overrideOptions = {}) {
  const widgetProcesses = listWidgetProcesses();
  if (widgetProcesses.length === 0) {
    return [
      {
        pid: null,
        options: mergeLaunchOptions({}, overrideOptions)
      }
    ];
  }

  return widgetProcesses.map((processInfo) => ({
    pid: processInfo.pid,
    options: mergeLaunchOptions(
      parseLaunchOptionsFromCommandLine(processInfo.commandLine),
      overrideOptions
    )
  }));
}

async function waitForProcessesToExit(pids, timeoutMs = 5000) {
  const trackedPids = [...new Set(pids.filter((pid) => Number.isInteger(pid) && pid > 0))];
  if (trackedPids.length === 0) {
    return [];
  }

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const remainingPids = trackedPids.filter((pid) => isProcessRunning(pid));
    if (remainingPids.length === 0) {
      return [];
    }
    await wait(200);
  }

  return trackedPids.filter((pid) => isProcessRunning(pid));
}

async function stopProcessesById(pids, label) {
  const runningPids = [...new Set(pids.filter((pid) => Number.isInteger(pid) && pid > 0))]
    .filter((pid) => isProcessRunning(pid));

  if (runningPids.length === 0) {
    return [];
  }

  const command = [
    '$ErrorActionPreference = "Stop"',
    `$processIds = @(${runningPids.join(', ')})`,
    'foreach ($processId in $processIds) {',
    '  try {',
    '    Stop-Process -Id $processId -Force -ErrorAction Stop',
    '  } catch {',
    '  }',
    '}'
  ].join('; ');

  runPowerShellCommand(command, `Failed to stop ${label}.`);

  const remainingPids = await waitForProcessesToExit(runningPids);
  if (remainingPids.length > 0) {
    throw new Error(`Failed to stop ${label} PID(s): ${remainingPids.join(', ')}`);
  }

  return runningPids;
}

async function stopWidgetHosts(widgetPids) {
  const widgetEntryPoint = getWidgetEntryPoint();
  if (widgetEntryPoint.kind === 'native') {
    const runningPids = [...new Set(widgetPids.filter((pid) => Number.isInteger(pid) && pid > 0))]
      .filter((pid) => isProcessRunning(pid));

    if (runningPids.length === 0) {
      return [];
    }

    for (const pid of runningPids) {
      const result = spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], {
        cwd: packageDir,
        windowsHide: true,
        encoding: 'utf8'
      });

      if (result.error) {
        throw result.error;
      }

      if (result.status !== 0 && isProcessRunning(pid)) {
        const detail = (result.stderr || result.stdout || '').trim();
        throw new Error(detail || `Failed to stop ${label} PID ${pid}.`);
      }
    }

    const remainingPids = await waitForProcessesToExit(runningPids);
    if (remainingPids.length > 0) {
      throw new Error(`Failed to stop ${label} PID(s): ${remainingPids.join(', ')}`);
    }

    return runningPids;
  }

  return stopProcessesById(widgetPids, 'widget host process');
}

async function stopOrphanedTerminalHosts(widgetPids) {
  const widgetPidSet = new Set(widgetPids.filter((pid) => Number.isInteger(pid) && pid > 0));
  if (widgetPidSet.size === 0) {
    return [];
  }

  const terminalHosts = listEmbeddedTerminalHostProcesses();
  const orphanedPids = terminalHosts
    .filter((proc) => widgetPidSet.has(proc.parentProcessId))
    .map((proc) => proc.pid);

  if (orphanedPids.length === 0) {
    return [];
  }

  return stopProcessesById(orphanedPids, 'orphaned TerminalHost.exe process');
}

async function stopWidgetService() {
  const existingState = readServiceState();
  if (!existingState) {
    return null;
  }

  await stopProcessesById([existingState.pid], 'clippy_widget_service');
  try {
    fs.unlinkSync(serviceStatePath);
  } catch {
  }

  return existingState;
}

function startWidgetService() {
  if (!fs.existsSync(serviceScriptPath)) {
    throw new Error(`Widget service script not found: ${serviceScriptPath}`);
  }

  ensureStateDirectories();
  appendLog(serviceLogPath, 'Starting clippy_widget_service background process.');

  const child = spawn(process.execPath, [serviceScriptPath, '--service'], {
    cwd: packageDir,
    detached: true,
    stdio: 'ignore',
    windowsHide: true
  });

  child.unref();

  if (!Number.isInteger(child.pid) || child.pid <= 0) {
    throw new Error('Failed to start clippy_widget_service.');
  }
}

async function ensureWidgetService() {
  const existingState = readServiceState();
  if (existingState) {
    return { state: existingState, started: false };
  }

  startWidgetService();

  const timeoutMs = 5000;
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const serviceState = readServiceState();
    if (serviceState) {
      return { state: serviceState, started: true };
    }
    await wait(250);
  }

  throw new Error('clippy_widget_service did not start within 5 seconds.');
}

function createLaunchRequest(options = {}) {
  ensureStateDirectories();

  const replyPath = path.join(
    responsesDir,
    `${Date.now()}-${Math.random().toString(16).slice(2)}.json`
  );
  const request = createWidgetLaunchCommand({
    sessionId: options.sessionId || null,
    openChat: !!options.openChat,
    noWelcome: !!options.noWelcome,
    extraArgs: normalizeWidgetArguments(options.extraArgs || []),
    replyPath
  });

  const requestPath = writeServiceCommandFile(requestsDir, request);
  return { request, requestPath, responsePath: replyPath };
}

async function requestWidgetLaunch(options = {}) {
  const service = await ensureWidgetService();
  const launchRequest = createLaunchRequest(options);
  appendLog(
    serviceLogPath,
    `Queued widget command ${launchRequest.request.id} (${launchRequest.request.type || SERVICE_COMMAND_TYPES.WIDGET_LAUNCH}) for session ${launchRequest.request.payload?.sessionId || launchRequest.request.sessionId || 'none'}.`
  );

  return {
    service,
    launchRequest,
    widgetLogPath,
    serviceLogPath,
    serviceStatePath
  };
}

async function refreshWidgets(options = {}) {
  const widgetEntryPoint = getWidgetEntryPoint(options.runtime);
  if (widgetEntryPoint.kind === 'native' || widgetEntryPoint.kind === 'legacy') {
    const widgetProcesses = listWidgetProcesses(options.runtime);
    const widgetPids = widgetProcesses.map((processInfo) => processInfo.pid);
    const launchOptions = mergeLaunchOptions({}, options);
    const stoppedWidgetPids = await stopWidgetHosts(widgetPids);
    const launch = launchWidget(launchOptions);
    const launcherKind = widgetEntryPoint.kind === 'legacy' ? 'powershell' : 'native';

    appendLog(
      widgetLogPath,
      launch.reusedExisting
        ? `${launcherKind === 'native' ? 'Native' : 'Legacy PowerShell'} widget host was already running; refresh request reused the current instance.`
        : `Launched ${launcherKind === 'native' ? 'native' : 'legacy PowerShell'} widget host${launch.pid ? ` with PID ${launch.pid}` : ''} for refresh request.`
    );

    return {
      stoppedWidgetPids,
      queuedRequests: launch.reusedExisting ? [] : [launch.pid ? String(launch.pid) : 'native-launch'],
      launchCount: launch.reusedExisting ? 0 : 1,
      serviceStarted: false,
      usedFallbackLaunch: widgetPids.length === 0,
      serviceLogPath,
      serviceStatePath,
      reusedExistingWidget: !!launch.reusedExisting,
      widgetPid: launch.pid || null,
      widgetUrl: null,
      logPath: widgetLogPath,
      launcherKind
    };
  }

  if (widgetEntryPoint.kind === 'dashboard') {
    const launch = launchWidget(options);
    appendLog(
      serviceLogPath,
      launch.reusedExisting
        ? `Dashboard widget already running${launch.url ? ` at ${launch.url}` : ''}; refresh request reused the current instance.`
        : `Launched dashboard widget${launch.pid ? ` with PID ${launch.pid}` : ''} for refresh request.`
    );

    return {
      stoppedWidgetPids: [],
      queuedRequests: launch.reusedExisting ? [] : [launch.pid ? String(launch.pid) : 'dashboard-launch'],
      launchCount: launch.reusedExisting ? 0 : 1,
      serviceStarted: false,
      usedFallbackLaunch: false,
      serviceLogPath,
      serviceStatePath,
      reusedExistingWidget: !!launch.reusedExisting,
      widgetPid: launch.pid || null,
      widgetUrl: launch.url || null
    };
  }

  const widgetProcesses = listWidgetProcesses();
  const widgetPids = widgetProcesses.map((processInfo) => processInfo.pid);
  const preservedOptions = widgetProcesses.reduce(
    (merged, processInfo) => mergeLaunchOptions(merged, parseLaunchOptionsFromCommandLine(processInfo.commandLine)),
    {}
  );
  const launchOptions = widgetProcesses.length > 0
    ? mergeLaunchOptions(preservedOptions, options)
    : mergeLaunchOptions({}, options);
  const stoppedWidgetPids = await stopWidgetHosts(widgetPids);
  await stopOrphanedTerminalHosts(widgetPids);

  const queuedRequests = [];
  const result = await requestWidgetLaunch(launchOptions);
  queuedRequests.push(result.launchRequest.request.id);
  const serviceStarted = result.service.started;

  appendLog(
    serviceLogPath,
    `Refreshed a single widget instance after stopping ${stoppedWidgetPids.length} host process(es).`
  );

  return {
    stoppedWidgetPids,
    queuedRequests,
    launchCount: queuedRequests.length,
    serviceStarted,
    usedFallbackLaunch: widgetPids.length === 0,
    serviceLogPath,
    serviceStatePath
  };
}

async function restartWidgets(options = {}) {
  const widgetEntryPoint = getWidgetEntryPoint(options.runtime);
  if (widgetEntryPoint.kind === 'native' || widgetEntryPoint.kind === 'legacy') {
    const widgetProcesses = listWidgetProcesses(options.runtime);
    const widgetPids = widgetProcesses.map((processInfo) => processInfo.pid);
    const launchOptions = mergeLaunchOptions({}, options);
    const stoppedWidgetPids = await stopWidgetHosts(widgetPids);
    const launch = launchWidget(launchOptions);
    const launcherKind = widgetEntryPoint.kind === 'legacy' ? 'powershell' : 'native';

    appendLog(
      widgetLogPath,
      launch.reusedExisting
        ? `${launcherKind === 'native' ? 'Native' : 'Legacy PowerShell'} widget host was already running; restart request reused the current instance.`
        : `Restarted ${launcherKind === 'native' ? 'native' : 'legacy PowerShell'} widget host${launch.pid ? ` with PID ${launch.pid}` : ''}.`
    );

    return {
      stoppedWidgetPids,
      stoppedServicePid: null,
      queuedRequests: launch.reusedExisting ? [] : [launch.pid ? String(launch.pid) : 'native-launch'],
      launchCount: launch.reusedExisting ? 0 : 1,
      serviceStarted: false,
      usedFallbackLaunch: widgetPids.length === 0,
      serviceLogPath,
      serviceStatePath,
      reusedExistingWidget: !!launch.reusedExisting,
      widgetPid: launch.pid || null,
      widgetUrl: null,
      logPath: widgetLogPath,
      launcherKind
    };
  }

  if (widgetEntryPoint.kind === 'dashboard') {
    const launch = launchWidget(options);
    appendLog(
      serviceLogPath,
      launch.reusedExisting
        ? `Dashboard widget already running${launch.url ? ` at ${launch.url}` : ''}; restart request reused the current instance.`
        : `Launched dashboard widget${launch.pid ? ` with PID ${launch.pid}` : ''} for restart request.`
    );

    return {
      stoppedWidgetPids: [],
      stoppedServicePid: null,
      queuedRequests: launch.reusedExisting ? [] : [launch.pid ? String(launch.pid) : 'dashboard-launch'],
      launchCount: launch.reusedExisting ? 0 : 1,
      serviceStarted: false,
      usedFallbackLaunch: false,
      serviceLogPath,
      serviceStatePath,
      reusedExistingWidget: !!launch.reusedExisting,
      widgetPid: launch.pid || null,
      widgetUrl: launch.url || null
    };
  }

  const widgetProcesses = listWidgetProcesses();
  const widgetPids = widgetProcesses.map((processInfo) => processInfo.pid);
  const preservedOptions = widgetProcesses.reduce(
    (merged, processInfo) => mergeLaunchOptions(merged, parseLaunchOptionsFromCommandLine(processInfo.commandLine)),
    {}
  );
  const launchOptions = widgetProcesses.length > 0
    ? mergeLaunchOptions(preservedOptions, options)
    : mergeLaunchOptions({}, options);
  const stoppedWidgetPids = await stopWidgetHosts(widgetPids);
  await stopOrphanedTerminalHosts(widgetPids);
  const stoppedService = await stopWidgetService();

  const queuedRequests = [];
  const result = await requestWidgetLaunch(launchOptions);
  queuedRequests.push(result.launchRequest.request.id);
  const serviceStarted = result.service.started;

  appendLog(
    serviceLogPath,
    `Restarted clippy_widget_service${stoppedService ? ` from PID ${stoppedService.pid}` : ''} and queued a single widget instance.`
  );

  return {
    stoppedWidgetPids,
    stoppedServicePid: stoppedService ? stoppedService.pid : null,
    queuedRequests,
    launchCount: queuedRequests.length,
    serviceStarted,
    usedFallbackLaunch: widgetPids.length === 0,
    serviceLogPath,
    serviceStatePath
  };
}

function parseCliArguments(rawArgs) {
  const options = {
    debug: false,
    noWelcome: false,
    openChat: false,
    runtime: 'auto',
    sessionId: null,
    extraArgs: []
  };

  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];

    if (arg === '--debug') {
      options.debug = true;
      continue;
    }

    if (arg === '--no-welcome') {
      options.noWelcome = true;
      continue;
    }

    if (arg === '--open-chat') {
      options.openChat = true;
      continue;
    }

    if (arg === '--runtime' && rawArgs[index + 1]) {
      const candidate = String(rawArgs[index + 1] || '').toLowerCase();
      if (VALID_RUNTIME_SELECTIONS.has(candidate)) {
        options.runtime = candidate;
        index += 1;
        continue;
      }
    }

    if (arg.startsWith('--runtime=')) {
      const candidate = String(arg.slice('--runtime='.length) || '').toLowerCase();
      if (VALID_RUNTIME_SELECTIONS.has(candidate)) {
        options.runtime = candidate;
        continue;
      }
    }

    if (arg === '--session-id' && rawArgs[index + 1]) {
      options.sessionId = rawArgs[index + 1];
      index += 1;
      continue;
    }

    if (arg.startsWith('--session-id=')) {
      options.sessionId = arg.slice('--session-id='.length);
      continue;
    }

    options.extraArgs.push(arg);
  }

  return options;
}

async function main() {
  try {
    const options = parseCliArguments(process.argv.slice(2));
    const widgetEntryPoint = getWidgetEntryPoint(options.runtime);

    if (!options.openChat) {
      options.openChat = true;
    }

    if (options.debug) {
      const { child, logPath } = launchWidget(options);
      if (!child) {
        const ready = await waitForWidgetReady({
          requestCreatedAt: Date.now() - 1000,
          expectedPid: listWidgetProcesses(options.runtime)[0]?.pid || null,
          runtime: options.runtime
        });
        const readyPid = ready.dashboardState?.pid || ready.widgetProcesses?.[0]?.pid || null;

        console.log('Windows Clippy widget is already running.');
        if (readyPid) {
          console.log(`Widget host PID: ${readyPid}`);
        }
        if (ready.dashboardState?.url) {
          console.log(`Dashboard URL: ${ready.dashboardState.url}`);
        }
        console.log(`Ready source: ${ready.readySource}`);
        console.log(`Launch log: ${logPath}`);
        return;
      }

      child.on('error', (error) => {
        console.error(`ERROR: Failed to launch Windows Clippy widget: ${error.message}`);
        process.exit(1);
      });
      child.on('exit', (code) => {
        process.exit(code ?? 0);
      });
      console.log(`Launched Windows Clippy widget in debug mode. Log: ${logPath}`);
      return;
    }

    const runningWidgets = listWidgetProcesses(options.runtime);
    if (runningWidgets.length > 0) {
      if (widgetEntryPoint.kind === 'dashboard') {
        const ready = await waitForWidgetReady({
          requestCreatedAt: Date.now() - 1000,
          runtime: options.runtime
        });

        console.log('Windows Clippy widget dashboard is already running.');
        if (ready.dashboardState?.pid) {
          console.log(`Widget host PID: ${ready.dashboardState.pid}`);
        }
        if (ready.dashboardState?.url) {
          console.log(`Dashboard URL: ${ready.dashboardState.url}`);
        }
        console.log(`Ready source: ${ready.readySource}`);
        console.log(`Launch log: ${widgetLogPath}`);
        return;
      }

      const result = await refreshWidgets(options);
      const ready = await waitForWidgetReady({
        requestCreatedAt: Date.now() - 1000,
        runtime: options.runtime
      });

      if (widgetEntryPoint.kind === 'native' || widgetEntryPoint.kind === 'legacy') {
        const runtimeLabel = result.launcherKind === 'powershell' ? 'legacy PowerShell' : 'native';
        console.log(`Refreshed ${result.launchCount} ${runtimeLabel} widget instance(s).`);
        if (result.stoppedWidgetPids.length > 0) {
          console.log(`Stopped widget host PIDs: ${result.stoppedWidgetPids.join(', ')}`);
        }
        if (result.queuedRequests.length > 0) {
          console.log(`Launched widget host PID(s): ${result.queuedRequests.join(', ')}`);
        }
        console.log(`Ready source: ${ready.readySource}`);
        console.log(`Launch log: ${result.logPath || widgetLogPath}`);
        return;
      }

      const serviceStatus = result.serviceStarted
        ? 'Started clippy_widget_service in background.'
        : 'clippy_widget_service is already running in background.';

      console.log(serviceStatus);
      console.log(`Refreshed ${result.launchCount} running widget instance(s).`);
      if (result.stoppedWidgetPids.length > 0) {
        console.log(`Stopped widget host PIDs: ${result.stoppedWidgetPids.join(', ')}`);
      }
      console.log(`Queued widget request(s): ${result.queuedRequests.join(', ')}`);
      if (ready.sessionState && Array.isArray(ready.sessionState.Tabs)) {
        console.log(`Connected widget tabs: ${ready.sessionState.Tabs.length}`);
      }
      console.log(`Ready source: ${ready.readySource}`);
      console.log(`Service log: ${result.serviceLogPath}`);
      return;
    }

    const launch = launchWidget(options);
      const ready = await waitForWidgetReady({
        requestCreatedAt: Date.now() - 1000,
        expectedPid: launch.pid || null,
        runtime: options.runtime
      });

    console.log('Launched Windows Clippy widget.');
    if (launch.pid) {
      console.log(`Widget host PID: ${launch.pid}`);
    }
    if (ready.dashboardState?.url) {
      console.log(`Dashboard URL: ${ready.dashboardState.url}`);
    }
    if (ready.sessionState && Array.isArray(ready.sessionState.Tabs)) {
      console.log(`Connected widget tabs: ${ready.sessionState.Tabs.length}`);
    }
    console.log(`Ready source: ${ready.readySource}`);
    console.log(`Launch log: ${launch.logPath}`);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  appendLog,
  ensureWidgetService,
  ensureStateDirectories,
  launchWidget,
  listWidgetProcesses,
  parseCliArguments,
  readServiceState,
  refreshWidgets,
  restartWidgets,
  requestWidgetLaunch,
  responsesDir,
  serviceLogPath,
  serviceStatePath,
  stopWidgetHosts,
  stopWidgetService,
  requestsDir,
  widgetLogPath
};
