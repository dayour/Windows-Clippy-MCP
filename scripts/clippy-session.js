#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { randomUUID } = require('crypto');
const { requestWidgetLaunch } = require('./start-widget');

const appDataDir = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
const clippyStateDir = path.join(appDataDir, 'Windows-Clippy-MCP');
const sessionStatePath = path.join(clippyStateDir, 'copilot-last-session.json');
const legacySessionStatePath = path.join(clippyStateDir, 'copilot-session.json');
const defaultConfigDir = path.join(os.homedir(), '.copilot');

const passthroughCommands = new Set(['help', 'version', 'login', 'init', 'plugin', 'update']);
const infoArguments = new Set(['-h', '--help', '-v', '--version']);

function ensureStateDirectory() {
  fs.mkdirSync(clippyStateDir, { recursive: true });
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function loadLastSessionId() {
  for (const candidatePath of [sessionStatePath, legacySessionStatePath]) {
    try {
      const payload = JSON.parse(fs.readFileSync(candidatePath, 'utf8'));
      if (
        payload &&
        typeof payload.sessionId === 'string' &&
        isUuid(payload.sessionId) &&
        !Array.isArray(payload.Tabs)
      ) {
        return payload.sessionId;
      }
    } catch {
      continue;
    }
  }

  return null;
}

function saveLastSessionId(sessionId, source) {
  if (!sessionId || !isUuid(sessionId)) {
    return;
  }

  ensureStateDirectory();
  fs.writeFileSync(
    sessionStatePath,
    JSON.stringify(
      {
        sessionId,
        source,
        updatedAt: new Date().toISOString()
      },
      null,
      2
    ),
    'utf8'
  );
}

function parseArguments(rawArgs) {
  const parsed = {
    args: [],
    attachWidget: true,
    newSession: false,
    printSession: false
  };

  for (const arg of rawArgs) {
    if (arg === '--no-widget') {
      parsed.attachWidget = false;
      continue;
    }

    if (arg === '--attach-widget') {
      parsed.attachWidget = true;
      continue;
    }

    if (arg === '--new-session') {
      parsed.newSession = true;
      continue;
    }

    if (arg === '--print-session') {
      parsed.printSession = true;
      continue;
    }

    parsed.args.push(arg);
  }

  return parsed;
}

function argumentValue(args, names) {
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    for (const name of names) {
      if (arg === name && args[index + 1]) {
        return args[index + 1];
      }
      if (arg.startsWith(`${name}=`)) {
        return arg.slice(name.length + 1);
      }
    }
  }

  return null;
}

function hasArgument(args, names) {
  return args.some((arg) => names.some((name) => arg === name || arg.startsWith(`${name}=`)));
}

function resolveCommandMode(args) {
  const firstCommand = args.find((arg) => !arg.startsWith('-')) || null;
  const promptMode = hasArgument(args, ['-p', '--prompt']);
  const interactiveMode = hasArgument(args, ['-i', '--interactive']);
  const infoMode =
    args.some((arg) => infoArguments.has(arg)) ||
    (firstCommand ? passthroughCommands.has(firstCommand) : false);

  return {
    firstCommand,
    promptMode,
    interactiveMode,
    infoMode
  };
}

function buildCopilotInvocation(parsed) {
  const args = [...parsed.args];
  const { promptMode, interactiveMode, infoMode } = resolveCommandMode(args);
  const explicitResume = argumentValue(args, ['--resume']);
  const hasBareResume = args.includes('--resume');
  const shouldAddConfigDir = !hasArgument(args, ['--config-dir']) && !infoMode;

  let sessionId = null;
  let finalArgs = [...args];

  if (explicitResume && isUuid(explicitResume)) {
    sessionId = explicitResume;
  } else if (hasArgument(args, ['--continue'])) {
    sessionId = loadLastSessionId() || randomUUID();
    finalArgs = finalArgs.filter((arg) => arg !== '--continue');
    finalArgs.unshift(`--resume=${sessionId}`);
  } else if (!hasBareResume && !infoMode) {
    sessionId = parsed.newSession ? randomUUID() : randomUUID();
    finalArgs.unshift(`--resume=${sessionId}`);
  }

  if (shouldAddConfigDir) {
    finalArgs.unshift(defaultConfigDir);
    finalArgs.unshift('--config-dir');
  }

  const shouldAttachWidget =
    parsed.attachWidget &&
    !infoMode &&
    !promptMode &&
    (interactiveMode || finalArgs.length === 0 || !!sessionId);

  if (sessionId) {
    saveLastSessionId(sessionId, 'terminal');
  }

  return {
    finalArgs,
    sessionId,
    shouldAttachWidget
  };
}

async function runCopilot(finalArgs, sessionId, shouldAttachWidget) {
  if (shouldAttachWidget && sessionId) {
    try {
      await requestWidgetLaunch({
        sessionId,
        openChat: true,
        noWelcome: false
      });
      process.stdout.write(`Launched Windows Clippy for session ${sessionId}.\n`);
      return;
    } catch (error) {
      console.error(`WARNING: Failed to launch attached Clippy widget: ${error.message}`);
    }
  }

  const child = spawn('copilot', finalArgs, {
    stdio: 'inherit',
    windowsHide: false
  });

  child.on('error', (error) => {
    if (error.code === 'ENOENT') {
      console.error("ERROR: The 'copilot' command was not found in PATH.");
      console.error('Install GitHub Copilot CLI first, then try the clippy command again.');
    } else {
      console.error(`ERROR: Failed to start Copilot CLI: ${error.message}`);
    }
    process.exit(1);
  });

  child.on('exit', (code) => {
    process.exit(code ?? 0);
  });
}

function main() {
  const parsed = parseArguments(process.argv.slice(2));

  if (parsed.printSession) {
    const sessionId = loadLastSessionId();
    if (!sessionId) {
      console.error('ERROR: No saved Clippy session was found.');
      process.exit(1);
    }

    process.stdout.write(`${sessionId}\n`);
    return;
  }

  const { finalArgs, sessionId, shouldAttachWidget } = buildCopilotInvocation(parsed);
  runCopilot(finalArgs, sessionId, shouldAttachWidget).catch((error) => {
    console.error(`ERROR: Failed to start clippy session: ${error.message}`);
    process.exit(1);
  });
}

if (require.main === module) {
  main();
}

module.exports = {
  buildCopilotInvocation,
  defaultConfigDir,
  isUuid,
  loadLastSessionId,
  parseArguments,
  saveLastSessionId
};
