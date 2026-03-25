#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');
const {
  ensureWidgetService,
  listWidgetProcesses,
  requestWidgetLaunch
} = require('./start-widget');

const packageDir = path.resolve(__dirname, '..');
const mcpArgs = ['run', 'main.py'];
const restartDelayMs = 5000;

let isStopping = false;
let currentServer = null;
let restartTimer = null;
let widgetStartupPromise = null;

function logServiceStatus(serviceStarted) {
  if (serviceStarted) {
    console.log('Started clippy_widget_service in background.');
    return;
  }

  console.log('clippy_widget_service is already running in background.');
}

async function ensureWidgetStartup() {
  if (widgetStartupPromise) {
    return widgetStartupPromise;
  }

  widgetStartupPromise = (async () => {
    const runningWidgets = listWidgetProcesses();
    if (runningWidgets.length > 0) {
      const service = await ensureWidgetService();
      logServiceStatus(service.started);
      console.log(
        `Clippy widget already running in ${runningWidgets.length} host instance${runningWidgets.length === 1 ? '' : 's'}.`
      );
      return {
        service,
        skippedLaunch: true,
        runningWidgets
      };
    }

    const result = await requestWidgetLaunch();
    logServiceStatus(result.service.started);
    console.log(`Queued widget launch request: ${result.launchRequest.request.id}`);
    console.log(`Service log: ${result.serviceLogPath}`);
    return result;
  })().catch((error) => {
    widgetStartupPromise = null;
    throw error;
  });

  return widgetStartupPromise;
}

function startMCPServer() {
  if (isStopping) {
    return null;
  }

  console.log('Starting Windows Clippy MCP Server...');

  const server = spawn('uv', mcpArgs, {
    cwd: packageDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: false
  });

  currentServer = server;

  server.stdout.on('data', (data) => {
    process.stdout.write(`MCP: ${data.toString()}`);
  });

  server.stderr.on('data', (data) => {
    process.stderr.write(`MCP Error: ${data.toString()}`);
  });

  server.on('close', (code) => {
    if (currentServer === server) {
      currentServer = null;
    }

    console.log(`MCP server exited with code ${code}`);

    if (isStopping) {
      return;
    }

    restartTimer = setTimeout(() => {
      restartTimer = null;
      startMCPServer();
    }, restartDelayMs);
  });

  server.on('error', (error) => {
    console.error(`MCP server error: ${error.message}`);
  });

  return server;
}

function shutdown(exitCode = 0) {
  isStopping = true;

  if (restartTimer) {
    clearTimeout(restartTimer);
    restartTimer = null;
  }

  if (currentServer && currentServer.exitCode === null) {
    const serverToStop = currentServer;
    currentServer = null;

    serverToStop.once('close', () => {
      process.exit(exitCode);
    });

    serverToStop.kill();
    return;
  }

  process.exit(exitCode);
}

async function main() {
  startMCPServer();
  await ensureWidgetStartup();
}

process.on('SIGINT', () => {
  console.log('Service stopping...');
  shutdown(0);
});

process.on('SIGTERM', () => {
  console.log('Service stopping...');
  shutdown(0);
});

if (require.main === module) {
  main().catch((error) => {
    console.error(`Service failed to start: ${error.stack || error.message}`);
    shutdown(1);
  });
}
