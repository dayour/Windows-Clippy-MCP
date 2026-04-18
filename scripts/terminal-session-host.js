#!/usr/bin/env node
'use strict';

const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawn } = require('child_process');
const { randomUUID } = require('crypto');
const {
  createLaunchConfig,
  buildTerminalSpawnArgs,
  buildPromptSpawnArgs,
  resolveSpawnPlan,
  TranscriptSink,
  TOOL_FLAG_ALIASES,
  normalizeMode,
  createTerminalCardRuntime,
  beginTerminalCardTurn,
  applyTerminalCardCopilotEvent,
  applyTerminalCardRawOutput,
  recordTerminalCardSessionReady,
  recordTerminalCardSessionError,
  recordTerminalCardSessionExit,
  createTerminalCardSnapshot
} = require('../src/terminal');
const {
  defaultConfigDir,
  loadLastSessionId,
  saveLastSessionId,
  isUuid
} = require('./clippy-session');
const {
  HOST_COMMANDS,
  buildCapabilities,
  createEnvelope,
  normalizeIncomingCommand
} = require('./terminal-bridge-protocol');

const packageDir = path.resolve(__dirname, '..');

function printUsage() {
  process.stdout.write(
    [
      'Usage: node scripts/terminal-session-host.js [options]',
      '',
      'Options:',
      '  --session-id <uuid>           Explicit Clippy/Copilot session ID',
      '  --resume <uuid>               Alias for --session-id',
      '  --continue                    Reuse the last saved session ID when available',
      '  --config-dir <path>           Copilot config directory',
      '  --agent <id>                  Agent ID',
      '  --model <id>                  Model ID',
      '  --mode <agent|plan|swarm|ask> Copilot mode',
      '  --runtime <copilot|terminal>  Backing runtime kind',
      '  --shell <powershell|cmd|copilot|pwsh|bash>',
      '  --command <text>              Terminal command line to launch',
      '  --env <KEY=VALUE>             Terminal environment variable',
      '  --working-directory <path>    Child process working directory',
      '  --display-name <label>        Tab display name override',
      '  --allow-all-tools             Pass through tool flag',
      '  --allow-all-paths             Pass through tool flag',
      '  --allow-all-urls              Pass through tool flag',
      '  --experimental                Pass through tool flag',
      '  --autopilot                   Pass through tool flag',
      '  --enable-all-github-mcp-tools Pass through tool flag',
      '  --extra-flag <value>          Append an extra CLI flag',
      '  --json                        Emit JSON metadata to stdout',
      '  --bridge-stdio                Accept newline-delimited JSON control messages on stdin',
      '  --dry-run                     Print the resolved launch plan and exit',
      '  --echo-output                 Mirror raw child stdout/stderr to this console',
      '  --auto-exit-ms <ms>           Stop the hosted tab after the given duration',
      '  --help                        Show this message',
      ''
    ].join('\n')
  );
}

function parseEnvironmentVariable(rawValue) {
  const text = String(rawValue || '').trim();
  if (!text) {
    throw new Error('terminal-session-host: --env requires KEY=VALUE format.');
  }

  const separatorIndex = text.indexOf('=');
  if (separatorIndex <= 0) {
    throw new Error('terminal-session-host: --env requires KEY=VALUE format.');
  }

  return {
    name: text.slice(0, separatorIndex),
    value: text.slice(separatorIndex + 1)
  };
}

function parseArguments(rawArgs) {
  const parsed = {
    sessionId: null,
    continueLastSession: false,
    configDir: defaultConfigDir,
    agent: null,
    model: null,
    mode: null,
    runtime: 'copilot',
    shell: null,
    command: null,
    env: [],
    tools: [],
    extraFlags: [],
    workingDirectory: packageDir,
    displayName: null,
    emitJson: false,
    dryRun: false,
    echoOutput: false,
    bridgeStdio: false,
    autoExitMs: null,
    executable: null
  };

  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];

    switch (arg) {
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      case '--session-id':
      case '--resume':
        parsed.sessionId = rawArgs[index + 1] || null;
        index += 1;
        break;
      case '--continue':
        parsed.continueLastSession = true;
        break;
      case '--config-dir':
        parsed.configDir = rawArgs[index + 1] || parsed.configDir;
        index += 1;
        break;
      case '--agent':
        parsed.agent = rawArgs[index + 1] || null;
        index += 1;
        break;
      case '--model':
        parsed.model = rawArgs[index + 1] || null;
        index += 1;
        break;
      case '--mode':
        parsed.mode = rawArgs[index + 1] || null;
        index += 1;
        break;
      case '--runtime':
        parsed.runtime = rawArgs[index + 1] || parsed.runtime;
        index += 1;
        break;
      case '--shell':
        parsed.shell = rawArgs[index + 1] || null;
        index += 1;
        break;
      case '--command':
        parsed.command = rawArgs[index + 1] || null;
        index += 1;
        break;
      case '--env':
        parsed.env.push(parseEnvironmentVariable(rawArgs[index + 1] || ''));
        index += 1;
        break;
      case '--working-directory':
      case '--cwd':
        parsed.workingDirectory = rawArgs[index + 1] || parsed.workingDirectory;
        index += 1;
        break;
      case '--display-name':
        parsed.displayName = rawArgs[index + 1] || null;
        index += 1;
        break;
      case '--extra-flag':
        if (rawArgs[index + 1]) {
          parsed.extraFlags.push(rawArgs[index + 1]);
          index += 1;
        }
        break;
      case '--json':
        parsed.emitJson = true;
        break;
      case '--dry-run':
        parsed.dryRun = true;
        break;
      case '--echo-output':
        parsed.echoOutput = true;
        break;
      case '--bridge-stdio':
        parsed.bridgeStdio = true;
        break;
      case '--auto-exit-ms':
        parsed.autoExitMs = Number.parseInt(rawArgs[index + 1] || '', 10);
        index += 1;
        break;
      case '--executable':
        parsed.executable = rawArgs[index + 1] || null;
        index += 1;
        break;
      default:
        if (arg.startsWith('--session-id=')) {
          parsed.sessionId = arg.slice('--session-id='.length);
          break;
        }
        if (arg.startsWith('--resume=')) {
          parsed.sessionId = arg.slice('--resume='.length);
          break;
        }
        if (arg.startsWith('--config-dir=')) {
          parsed.configDir = arg.slice('--config-dir='.length);
          break;
        }
        if (arg.startsWith('--agent=')) {
          parsed.agent = arg.slice('--agent='.length);
          break;
        }
        if (arg.startsWith('--model=')) {
          parsed.model = arg.slice('--model='.length);
          break;
        }
        if (arg.startsWith('--mode=')) {
          parsed.mode = arg.slice('--mode='.length);
          break;
        }
        if (arg.startsWith('--runtime=')) {
          parsed.runtime = arg.slice('--runtime='.length);
          break;
        }
        if (arg.startsWith('--shell=')) {
          parsed.shell = arg.slice('--shell='.length);
          break;
        }
        if (arg.startsWith('--command=')) {
          parsed.command = arg.slice('--command='.length);
          break;
        }
        if (arg.startsWith('--env=')) {
          parsed.env.push(parseEnvironmentVariable(arg.slice('--env='.length)));
          break;
        }
        if (arg.startsWith('--working-directory=')) {
          parsed.workingDirectory = arg.slice('--working-directory='.length);
          break;
        }
        if (arg.startsWith('--cwd=')) {
          parsed.workingDirectory = arg.slice('--cwd='.length);
          break;
        }
        if (arg.startsWith('--display-name=')) {
          parsed.displayName = arg.slice('--display-name='.length);
          break;
        }
        if (arg.startsWith('--auto-exit-ms=')) {
          parsed.autoExitMs = Number.parseInt(arg.slice('--auto-exit-ms='.length), 10);
          break;
        }
        if (arg.startsWith('--executable=')) {
          parsed.executable = arg.slice('--executable='.length);
          break;
        }
        if (TOOL_FLAG_ALIASES[arg.replace(/^--/, '')] || TOOL_FLAG_ALIASES[arg]) {
          parsed.tools.push(arg);
          break;
        }
        parsed.extraFlags.push(arg);
        break;
    }
  }

  return parsed;
}

function resolveSessionId(parsed) {
  if (parsed.sessionId) {
    if (!isUuid(parsed.sessionId)) {
      throw new Error(`terminal-session-host: invalid session ID "${parsed.sessionId}"`);
    }
    return parsed.sessionId;
  }

  if (parsed.continueLastSession) {
    return loadLastSessionId();
  }

  return null;
}

function resolveRuntime(parsed) {
  const runtime = String(parsed.runtime || 'copilot').trim().toLowerCase();
  if (!runtime) {
    return 'copilot';
  }

  if (runtime === 'copilot' || runtime === 'terminal') {
    return runtime;
  }

  throw new Error(`terminal-session-host: unsupported runtime "${parsed.runtime}"`);
}

function buildLaunchOptions(parsed) {
  const sessionId = resolveSessionId(parsed);
  const mode = normalizeMode(parsed.mode);

  if (parsed.mode && !mode) {
    throw new Error(`terminal-session-host: unsupported mode "${parsed.mode}"`);
  }

  const runtime = resolveRuntime(parsed);
  const launchConfig = createLaunchConfig({
    sessionId,
    configDir: parsed.configDir,
    agent: parsed.agent,
    model: parsed.model,
    mode,
    tools: parsed.tools,
    extraFlags: parsed.extraFlags,
    workingDirectory: parsed.workingDirectory,
    executable: parsed.executable || undefined
  });

  const terminalSpec = {
    shell: parsed.shell,
    command: parsed.command,
    env: parsed.env.slice(),
    cols: 120,
    rows: 30
  };

  return {
    displayName:
      parsed.displayName ||
      launchConfig.agent ||
      (runtime === 'terminal'
        ? `Terminal ${launchConfig.sessionId.slice(0, 8)}`
        : (launchConfig.mode ? `${launchConfig.mode} session` : `Session ${launchConfig.sessionId.slice(0, 8)}`)),
    runtime,
    launchConfig,
    terminalSpec
  };
}

function createHostContext(launchOptions, options = {}) {
  return {
    tabId: randomUUID(),
    displayName: launchOptions.displayName,
    sessionId: launchOptions.launchConfig.sessionId,
    runtime: launchOptions.runtime,
    launchConfig: launchOptions.launchConfig,
    terminalSpec: Object.assign({}, launchOptions.terminalSpec),
    hostState: 'starting',
    pid: process.pid,
    sink: new TranscriptSink(launchOptions.launchConfig.sessionId),
    activePrompt: null,
    shutdownRequested: false,
    echoOutput: Boolean(options.echoOutput),
    cardRuntime: createTerminalCardRuntime(),
    terminalBackend: null
  };
}

function formatLaunchMetadata(context, launchOptions) {
  const spawnPlan = resolveLaunchMetadataPlan(context);
  return {
    tabId: context.tabId,
    displayName: context.displayName,
    sessionId: context.sessionId,
    hostState: context.hostState,
    pid: context.pid,
    runtime: context.runtime,
    capabilities: buildCapabilities({
      runtime: context.runtime,
      features: {
        resize: true,
        restart: true,
        shutdown: true,
        rawOutput: true,
        copilotEvents: context.runtime === 'copilot',
        pty: context.runtime === 'terminal'
      }
    }),
    launchConfig: {
      sessionId: context.launchConfig.sessionId,
      configDir: context.launchConfig.configDir,
      agent: context.launchConfig.agent,
      model: context.launchConfig.model,
      mode: context.launchConfig.mode,
      tools: context.launchConfig.tools,
      workingDirectory: context.launchConfig.workingDirectory,
      extraFlags: context.launchConfig.extraFlags
    },
    terminalSpec: context.runtime === 'terminal'
      ? {
        shell: context.terminalSpec.shell || null,
        command: context.terminalSpec.command || null,
        cols: context.terminalSpec.cols,
        rows: context.terminalSpec.rows
      }
      : null,
    spawnPlan: {
      executable: spawnPlan.executable,
      cwd: spawnPlan.cwd,
      argv: spawnPlan.argv
    },
    requestedDisplayName: launchOptions.displayName,
    sessionTransport: context.runtime === 'terminal' ? 'pty-stream' : 'resume-prompt-stream'
  };
}

function resolveLaunchMetadataPlan(context) {
  const shell = String(context.terminalSpec.shell || '').trim().toLowerCase();
  if (context.runtime === 'terminal' && shell === 'copilot') {
    const { argv, env } = buildTerminalSpawnArgs(context.launchConfig);
    return {
      executable: context.launchConfig.executable,
      argv,
      env,
      cwd: context.launchConfig.workingDirectory
    };
  }

  return resolveSpawnPlan(context.launchConfig);
}

function emitBridgeMessage(type, payload) {
  process.stdout.write(`${JSON.stringify(createEnvelope(type, payload))}\n`);
}

function emitHostReady(context, launchOptions) {
  emitBridgeMessage('host.ready', {
    tabId: context.tabId,
    sessionId: context.sessionId,
    displayName: context.displayName,
    pid: context.pid,
    hostState: context.hostState,
    runtime: context.runtime,
    capabilities: formatLaunchMetadata(context, launchOptions).capabilities
  });
}

function emitHostMetadata(context, launchOptions) {
  emitBridgeMessage('host.metadata', formatLaunchMetadata(context, launchOptions));
}

function emitHostState(context, detail = {}) {
  emitBridgeMessage('host.state', {
    tabId: context.tabId,
    sessionId: context.sessionId,
    displayName: context.displayName,
    pid: context.pid,
    runtime: context.runtime,
    hostState: context.hostState,
    previousHostState: detail.previous || null,
    currentHostState: detail.current || context.hostState
  });
}

function emitHostError(context, error) {
  emitBridgeMessage('host.error', {
    tabId: context.tabId,
    sessionId: context.sessionId,
    displayName: context.displayName,
    message: error instanceof Error ? error.message : String(error)
  });
}

function emitSessionOutput(context, text, stream = 'stdout', category = 'raw') {
  if (text === undefined || text === null || text === '') {
    return;
  }

  const payload = {
    tabId: context.tabId,
    sessionId: context.sessionId,
    displayName: context.displayName,
    runtime: context.runtime,
    stream,
    category,
    text: String(text)
  };

  emitBridgeMessage('session.output', payload);
  if (stream !== 'stderr') {
    emitBridgeMessage('transcript.text', payload);
  }
}

function emitTerminalCard(context) {
  emitBridgeMessage('terminal.card', createTerminalCardSnapshot({
    tabId: context.tabId,
    displayName: context.displayName,
    sessionId: context.sessionId,
    hostState: context.hostState,
    pid: context.pid,
    launchConfig: context.launchConfig,
    sessionTransport: context.runtime === 'terminal' ? 'pty-stream' : 'resume-prompt-stream',
    runtimeInfo: context.runtime === 'terminal'
      ? {
        shell: context.terminalSpec.shell || null,
        command: context.terminalSpec.command || null
      }
      : undefined,
    runtimeState: context.runtime === 'terminal' && context.terminalBackend
      ? {
        cols: context.terminalSpec.cols,
        rows: context.terminalSpec.rows
      }
      : undefined,
    runtime: context.cardRuntime
  }));
}

function transitionHostState(context, nextState) {
  const previous = context.hostState;
  if (previous === nextState) {
    return;
  }

  context.hostState = nextState;
  emitHostState(context, { previous, current: nextState });
}

function normalizeOutputLine(line) {
  return String(line || '')
    .replace(/\u001b\][^\u0007]*(?:\u0007|\u001b\\)/g, '')
    .replace(/\u001b\[[0-9;?]*[A-Za-z]/g, '')
    .replace(/\r/g, '')
    .trim();
}

function tryParseCopilotEvent(line) {
  const cleanLine = normalizeOutputLine(line);
  if (!cleanLine) {
    return null;
  }

  const jsonStart = cleanLine.indexOf('{');
  if (jsonStart === -1) {
    return null;
  }

  try {
    const event = JSON.parse(cleanLine.slice(jsonStart));
    return event && typeof event.type === 'string' ? event : null;
  } catch {
    return null;
  }
}

function attachTranscriptBridge(context) {
  context.sink.onCopilotEvent((payload) => {
    emitBridgeMessage('copilot.event', {
      tabId: context.tabId,
      sessionId: payload.sessionId,
      event: payload.event
    });
  });

  context.sink.onRawStdout((payload) => {
    emitSessionOutput(context, payload.chunk, 'stdout', 'raw');
  });

  context.sink.onRawStderr((payload) => {
    emitSessionOutput(context, payload.chunk, 'stderr', 'raw');
  });

  context.sink.onSessionReady((payload) => {
    emitBridgeMessage('session.ready', {
      tabId: context.tabId,
      sessionId: payload.sessionId,
      timestamp: payload.timestamp,
      keepAlive: true,
      hostStillRunning: true,
      pid: context.pid,
      runtime: context.runtime,
      currentHostState: context.hostState
    });
  });

  context.sink.onSessionExit((payload) => {
    emitBridgeMessage('session.exit', {
      tabId: context.tabId,
      sessionId: payload.sessionId,
      exitCode: payload.exitCode,
      signal: payload.signal,
      timestamp: payload.timestamp,
      keepAlive: !context.shutdownRequested,
      hostStillRunning: !context.shutdownRequested,
      pid: context.pid,
      runtime: context.runtime,
      currentHostState: context.hostState
    });
  });

  context.sink.onSessionError((payload) => {
    emitBridgeMessage('session.error', {
      tabId: context.tabId,
      sessionId: payload.sessionId,
      message: payload.message,
      timestamp: payload.timestamp,
      keepAlive: !context.shutdownRequested,
      hostStillRunning: !context.shutdownRequested,
      pid: context.pid,
      runtime: context.runtime,
      currentHostState: context.hostState
    });
  });
}

function handlePromptStdoutChunk(context, bufferState, chunk) {
  bufferState.stdout += String(chunk);
  const lines = bufferState.stdout.split(/\r?\n/);
  bufferState.stdout = lines.pop() || '';

  for (const line of lines) {
    const event = tryParseCopilotEvent(line);
    if (event) {
      context.sink.emitCopilotEvent(event);
      if (applyTerminalCardCopilotEvent(context.cardRuntime, event)) {
        emitTerminalCard(context);
      }
    } else {
      const cleanLine = normalizeOutputLine(line);
      if (cleanLine) {
        if (context.echoOutput) {
          process.stderr.write(`${cleanLine}\n`);
        }
        context.sink.emitRawStdout(cleanLine);
        if (applyTerminalCardRawOutput(context.cardRuntime, cleanLine)) {
          emitTerminalCard(context);
        }
      }
    }
  }
}

function flushPromptStdoutBuffer(context, bufferState) {
  if (!bufferState.stdout) {
    return;
  }

  const event = tryParseCopilotEvent(bufferState.stdout);
  if (event) {
    context.sink.emitCopilotEvent(event);
    if (applyTerminalCardCopilotEvent(context.cardRuntime, event)) {
      emitTerminalCard(context);
    }
  } else {
    const cleanLine = normalizeOutputLine(bufferState.stdout);
    if (cleanLine) {
      context.sink.emitRawStdout(cleanLine);
      if (applyTerminalCardRawOutput(context.cardRuntime, cleanLine)) {
        emitTerminalCard(context);
      }
    }
  }

  bufferState.stdout = '';
}

async function stopActivePrompt(context) {
  if (!context.activePrompt) {
    return;
  }

  const child = context.activePrompt;
  await new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) {
        return;
      }
      settled = true;
      resolve();
    };

    child.once('exit', finish);
    try {
      child.kill('SIGTERM');
    } catch {
      finish();
      return;
    }

    setTimeout(() => {
      if (!settled) {
        try {
          child.kill('SIGKILL');
        } catch {
        }
        finish();
      }
    }, 3000);
  });
}

async function runPrompt(context, promptText) {
  if (typeof promptText !== 'string' || !promptText.trim()) {
    throw new Error('Host bridge input action requires non-empty text.');
  }

  if (context.activePrompt) {
    throw new Error('Copilot is already processing another request.');
  }

  beginTerminalCardTurn(context.cardRuntime, promptText);
  emitTerminalCard(context);

  const { argv, env } = buildPromptSpawnArgs(context.launchConfig, promptText, { stream: true });

  await new Promise((resolve, reject) => {
    const buffers = { stdout: '', stderr: '' };

    const child = spawn(context.launchConfig.executable, argv, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env,
      cwd: context.launchConfig.workingDirectory,
      windowsHide: true,
      shell: false
    });

    context.activePrompt = child;

    child.once('error', (error) => {
      context.activePrompt = null;
      recordTerminalCardSessionError(context.cardRuntime, error.message);
      emitTerminalCard(context);
      reject(error);
    });

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      handlePromptStdoutChunk(context, buffers, chunk);
    });

    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      buffers.stderr += String(chunk);
      context.sink.emitRawStderr(String(chunk));
      if (context.echoOutput) {
        process.stderr.write(String(chunk));
      }
    });

    child.once('exit', (code, signal) => {
      flushPromptStdoutBuffer(context, buffers);
      context.activePrompt = null;

      const stderrText = normalizeOutputLine(buffers.stderr);
      if (typeof code === 'number' && code !== 0 && stderrText) {
        context.sink.emitSessionError(stderrText);
        recordTerminalCardSessionError(context.cardRuntime, stderrText);
        emitTerminalCard(context);
      }

      recordTerminalCardSessionExit(context.cardRuntime, typeof code === 'number' ? code : null, signal);
      emitTerminalCard(context);
      context.sink.emitSessionExit(typeof code === 'number' ? code : null, signal);
      resolve();
    });
  });
}

function resolveTerminalLaunch(context) {
  const terminalEnv = Object.assign({}, process.env);
  for (const entry of context.terminalSpec.env) {
    terminalEnv[entry.name] = entry.value;
  }

  if (context.terminalSpec.command) {
    if (process.platform === 'win32') {
      return {
        executable: 'cmd.exe',
        args: ['/D', '/S', '/C', context.terminalSpec.command],
        env: terminalEnv
      };
    }

    return {
      executable: process.env.SHELL || 'bash',
      args: ['-lc', context.terminalSpec.command],
      env: terminalEnv
    };
  }

  const shell = String(context.terminalSpec.shell || '').trim().toLowerCase();
  switch (shell) {
    case '':
    case 'powershell':
      return {
        executable: 'powershell.exe',
        args: ['-NoLogo'],
        env: terminalEnv
      };
    case 'pwsh':
      return {
        executable: 'pwsh',
        args: ['-NoLogo'],
        env: terminalEnv
      };
    case 'cmd':
      return {
        executable: 'cmd.exe',
        args: [],
        env: terminalEnv
      };
    case 'bash':
      return {
        executable: 'bash',
        args: [],
        env: terminalEnv
      };
    case 'copilot':
      {
        const { argv, env } = buildTerminalSpawnArgs(context.launchConfig);
        return {
          executable: context.launchConfig.executable,
          args: argv,
          env: Object.assign(terminalEnv, env)
        };
      }
    default:
      return {
        executable: context.terminalSpec.shell,
        args: [],
        env: terminalEnv
      };
  }
}

function loadNodePty() {
  try {
    return require('node-pty');
  } catch (error) {
    throw new Error(`terminal-session-host: node-pty is required for terminal runtime (${error.message})`);
  }
}

async function startTerminalRuntime(context) {
  if (context.terminalBackend) {
    return;
  }

  const pty = loadNodePty();
  const launch = resolveTerminalLaunch(context);

  transitionHostState(context, 'running');
  context.terminalBackend = pty.spawn(launch.executable, launch.args, {
    name: process.platform === 'win32' ? 'xterm-color' : 'xterm-256color',
    cols: context.terminalSpec.cols,
    rows: context.terminalSpec.rows,
    cwd: context.launchConfig.workingDirectory,
    env: launch.env
  });

  context.terminalBackend.onData((data) => {
    context.sink.emitRawStdout(data);
    if (applyTerminalCardRawOutput(context.cardRuntime, data)) {
      emitTerminalCard(context);
    }
  });

  context.terminalBackend.onExit(({ exitCode, signal }) => {
    context.terminalBackend = null;
    recordTerminalCardSessionExit(context.cardRuntime, exitCode, signal || null);
    emitTerminalCard(context);
    if (!context.shutdownRequested) {
      transitionHostState(context, 'stopped');
    }
    context.sink.emitSessionExit(exitCode, signal || null);
  });

  recordTerminalCardSessionReady(context.cardRuntime);
  emitTerminalCard(context);
  context.sink.emitSessionReady();
}

async function stopTerminalRuntime(context) {
  if (!context.terminalBackend) {
    return;
  }

  const backend = context.terminalBackend;
  context.terminalBackend = null;
  transitionHostState(context, 'stopping');
  try {
    backend.kill();
  } catch {
  }
}

async function restartTerminalRuntime(context, overrides = {}) {
  if (overrides && typeof overrides === 'object') {
    if (typeof overrides.workingDirectory === 'string' && overrides.workingDirectory.trim()) {
      const nextWorkingDirectory = path.resolve(overrides.workingDirectory.trim());
      context.launchConfig = createLaunchConfig({
        ...context.launchConfig,
        workingDirectory: nextWorkingDirectory
      });
    }
    if (typeof overrides.shell === 'string' && overrides.shell.trim()) {
      context.terminalSpec.shell = overrides.shell.trim();
    }
    if (typeof overrides.command === 'string') {
      context.terminalSpec.command = overrides.command;
    }
    if (Array.isArray(overrides.env)) {
      context.terminalSpec.env = overrides.env.slice();
    }
    if (Number.isInteger(overrides.cols) && overrides.cols > 0) {
      context.terminalSpec.cols = overrides.cols;
    }
    if (Number.isInteger(overrides.rows) && overrides.rows > 0) {
      context.terminalSpec.rows = overrides.rows;
    }
  }

  await stopTerminalRuntime(context);
  transitionHostState(context, 'starting');
  await startTerminalRuntime(context);
}

function writeTerminalRuntimeInput(context, text, exact = false) {
  if (!context.terminalBackend) {
    throw new Error('The terminal runtime is not running.');
  }

  const data = exact
    ? String(text || '')
    : (String(text || '').endsWith('\n') || String(text || '').endsWith('\r') ? String(text || '') : `${String(text || '')}\r`);

  beginTerminalCardTurn(context.cardRuntime, String(text || ''));
  emitTerminalCard(context);
  context.terminalBackend.write(data);
}

async function handleBridgeCommand(context, launchOptions, normalized, stopAndExit) {
  const payload = normalized.payload || {};

  switch (normalized.command) {
    case HOST_COMMANDS.SESSION_INPUT:
      if (context.runtime === 'terminal') {
        writeTerminalRuntimeInput(context, payload.text || payload.input || '');
      } else {
        try {
          await runPrompt(context, payload.text || payload.input || '');
        } catch (error) {
          recordTerminalCardSessionError(context.cardRuntime, error.message);
          emitTerminalCard(context);
          context.sink.emitSessionError(error.message);
        }
      }
      return;
    case HOST_COMMANDS.SESSION_WRITE:
      if (context.runtime !== 'terminal') {
        throw new Error('session.write is only supported for terminal runtime.');
      }
      writeTerminalRuntimeInput(context, payload.text || '', true);
      return;
    case HOST_COMMANDS.SESSION_RESIZE:
      if (Number.isInteger(payload.cols) && payload.cols > 0) {
        context.terminalSpec.cols = payload.cols;
      }
      if (Number.isInteger(payload.rows) && payload.rows > 0) {
        context.terminalSpec.rows = payload.rows;
      }
      if (context.runtime === 'terminal' && context.terminalBackend) {
        context.terminalBackend.resize(context.terminalSpec.cols, context.terminalSpec.rows);
      }
      emitHostMetadata(context, launchOptions);
      return;
    case HOST_COMMANDS.SESSION_RESTART:
      if (typeof payload.displayName === 'string' && payload.displayName.trim()) {
        context.displayName = payload.displayName.trim();
        launchOptions.displayName = context.displayName;
      }

      if (context.runtime === 'terminal') {
        await restartTerminalRuntime(context, payload.configOverrides || payload);
      } else {
        const configOverrides =
          payload.configOverrides && typeof payload.configOverrides === 'object'
            ? payload.configOverrides
            : {};
        await stopActivePrompt(context);
        const nextLaunchConfig = createLaunchConfig({
          ...context.launchConfig,
          ...configOverrides
        });
        context.launchConfig = nextLaunchConfig;
        launchOptions.launchConfig = nextLaunchConfig;
        context.cardRuntime = createTerminalCardRuntime();
        saveLastSessionId(context.sessionId, 'terminal-broker');
        recordTerminalCardSessionReady(context.cardRuntime);
        emitTerminalCard(context);
        context.sink.emitSessionReady();
      }
      emitHostMetadata(context, launchOptions);
      return;
    case HOST_COMMANDS.HOST_SHUTDOWN:
      await stopAndExit(0);
      return;
    default:
      throw new Error(`Unsupported host bridge command "${normalized.command}"`);
  }
}

function attachBridgeController(context, stopAndExit, launchOptions) {
  const input = process.stdin;
  if (!input || input.isTTY) {
    return null;
  }

  const bridge = readline.createInterface({
    input,
    crlfDelay: Infinity,
    terminal: false
  });

  bridge.on('line', async (line) => {
    const payloadText = String(line || '').trim();
    if (!payloadText) {
      return;
    }

    let payload;
    try {
      payload = JSON.parse(payloadText);
    } catch (error) {
      process.stderr.write(`WARNING: Invalid bridge payload: ${error.message}\n`);
      return;
    }

    try {
      const normalized = normalizeIncomingCommand(payload);
      await handleBridgeCommand(context, launchOptions, normalized, stopAndExit);
    } catch (error) {
      emitHostError(context, error);
    }
  });

  bridge.on('close', () => {
    stopAndExit(0).catch((error) => {
      process.stderr.write(`ERROR: Failed to stop after bridge close: ${error.message}\n`);
      process.exit(1);
    });
  });

  return bridge;
}

async function launchHostedSession(options, parsed) {
  const context = createHostContext(options, { echoOutput: parsed.echoOutput });
  saveLastSessionId(context.sessionId, 'terminal-broker');
  return { context };
}

async function main() {
  const parsed = parseArguments(process.argv.slice(2));
  if (parsed.help) {
    printUsage();
    return;
  }

  const launchOptions = buildLaunchOptions(parsed);
  const dryRunPlan = resolveSpawnPlan(launchOptions.launchConfig);

  if (parsed.dryRun) {
    const payload = {
      displayName: launchOptions.displayName,
      runtime: launchOptions.runtime,
      launchConfig: launchOptions.launchConfig,
      terminalSpec: launchOptions.runtime === 'terminal' ? launchOptions.terminalSpec : null,
      spawnPlan: {
        executable: dryRunPlan.executable,
        cwd: dryRunPlan.cwd,
        argv: dryRunPlan.argv
      }
    };

    process.stdout.write(
      parsed.emitJson ? `${JSON.stringify(payload, null, 2)}\n` : `${JSON.stringify(payload)}\n`
    );
    return;
  }

  const { context } = await launchHostedSession(launchOptions, parsed);
  attachTranscriptBridge(context);

  let shutdownStarted = false;
  async function stopAndExit(exitCode = 0) {
    if (shutdownStarted) {
      return;
    }
    shutdownStarted = true;
    context.shutdownRequested = true;
    try {
      await stopActivePrompt(context);
      await stopTerminalRuntime(context);
    } finally {
      process.exit(exitCode);
    }
  }

  if (context.runtime === 'terminal') {
    await startTerminalRuntime(context);
  } else {
    transitionHostState(context, 'running');
    recordTerminalCardSessionReady(context.cardRuntime);
    emitTerminalCard(context);
    context.sink.emitSessionReady();
  }

  emitHostReady(context, launchOptions);
  emitHostMetadata(context, launchOptions);

  process.on('SIGINT', () => {
    stopAndExit(130).catch(() => {
      process.exit(130);
    });
  });

  process.on('SIGTERM', () => {
    stopAndExit(143).catch(() => {
      process.exit(143);
    });
  });

  if (Number.isFinite(parsed.autoExitMs) && parsed.autoExitMs > 0) {
    setTimeout(() => {
      stopAndExit(0).catch(() => {
        process.exit(0);
      });
    }, parsed.autoExitMs);
  }

  if (parsed.bridgeStdio) {
    attachBridgeController(context, stopAndExit, launchOptions);
  }
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  });
}

module.exports = {
  attachTranscriptBridge,
  buildLaunchOptions,
  emitBridgeMessage,
  formatLaunchMetadata,
  launchHostedSession,
  parseArguments,
  printUsage,
  resolveSessionId
};
