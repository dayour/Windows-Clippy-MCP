#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const {
  appendLog,
  ensureStateDirectories,
  launchWidget,
  readServiceState,
  requestsDir,
  responsesDir,
  serviceLogPath,
  serviceStatePath
} = require('./start-widget');
const {
  SERVICE_COMMAND_TYPES,
  createServiceResponse,
  createServiceState,
  normalizeServiceCommand,
  readJsonFile,
  writeJsonFile,
  writeServiceResponseFile
} = require('./widget-service-protocol');

process.title = 'clippy_widget_service';

let isProcessing = false;
let lastCommandId = null;
let lastCompletedAt = null;
let lastError = null;
let serviceStartedAt = null;

function persistServiceState(overrides = {}) {
  ensureStateDirectories();
  writeJsonFile(
    serviceStatePath,
    createServiceState({
      pid: process.pid,
      startedAt: overrides.startedAt || serviceStartedAt || new Date().toISOString(),
      heartbeatAt: new Date().toISOString(),
      activeCommandId: Object.prototype.hasOwnProperty.call(overrides, 'activeCommandId')
        ? overrides.activeCommandId
        : null,
      lastCommandId: Object.prototype.hasOwnProperty.call(overrides, 'lastCommandId')
        ? overrides.lastCommandId
        : lastCommandId,
      lastCompletedAt: Object.prototype.hasOwnProperty.call(overrides, 'lastCompletedAt')
        ? overrides.lastCompletedAt
        : lastCompletedAt,
      lastError: Object.prototype.hasOwnProperty.call(overrides, 'lastError')
        ? overrides.lastError
        : lastError
    })
  );
}

function writeServiceState() {
  serviceStartedAt = new Date().toISOString();
  persistServiceState({ startedAt: serviceStartedAt });
}

function removeServiceState() {
  try {
    const state = readJsonFile(serviceStatePath);
    if (state.pid === process.pid) {
      fs.unlinkSync(serviceStatePath);
    }
  } catch {
  }
}

function listPendingRequests() {
  ensureStateDirectories();
  return fs
    .readdirSync(requestsDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
    .map((entry) => entry.name)
    .sort()
    .map((entry) => path.join(requestsDir, entry));
}

function claimRequest(requestPath) {
  const claimedPath = `${requestPath}.processing`;
  fs.renameSync(requestPath, claimedPath);
  return claimedPath;
}

function completeRequest(requestPath) {
  try {
    fs.unlinkSync(requestPath);
  } catch {
  }
}

function writeResponseForCommand(command, options = {}) {
  if (!command.replyPath) {
    return null;
  }

  ensureStateDirectories();
  return writeServiceResponseFile(command.replyPath, createServiceResponse(command, options));
}

function isStaleRequest(requestPath) {
  const filename = path.basename(requestPath);
  const match = /^(\d+)-/.exec(filename);
  if (!match) {
    return false;
  }
  const fileTimestamp = Number(match[1]);
  return Date.now() - fileTimestamp > 30000;
}

async function processRequests() {
  if (isProcessing) {
    return;
  }

  isProcessing = true;
  try {
    const requestPaths = listPendingRequests();
    for (const requestPath of requestPaths) {
      if (isStaleRequest(requestPath)) {
        appendLog(
          serviceLogPath,
          `Skipping stale request file: ${path.basename(requestPath)}`
        );
        completeRequest(requestPath);
        continue;
      }

      let claimedPath = requestPath;
      try {
        claimedPath = claimRequest(requestPath);
      } catch {
        continue;
      }

      try {
        const request = normalizeServiceCommand(readJsonFile(claimedPath));
        persistServiceState({ activeCommandId: request.id });
        appendLog(
          serviceLogPath,
          `Processing widget command ${request.id} (${request.type}) for session ${request.payload.sessionId || 'none'}.`
        );

        if (request.type !== SERVICE_COMMAND_TYPES.WIDGET_LAUNCH) {
          throw new Error(`Unsupported widget service command "${request.type}".`);
        }

        const launch = launchWidget(request.payload);

        appendLog(
          serviceLogPath,
          `Widget command ${request.id} launched successfully${launch.pid ? ` with host PID ${launch.pid}` : ''}.`
        );
        lastCommandId = request.id;
        lastCompletedAt = new Date().toISOString();
        lastError = null;
        writeResponseForCommand(request, {
          status: 'succeeded',
          result: {
            pid: launch.pid || null,
            logPath: launch.logPath || null,
            reusedExisting: !!launch.reusedExisting,
            url: launch.url || null,
            protocolVersion: 2
          }
        });
      } catch (error) {
        lastError = error.message;
        appendLog(serviceLogPath, `ERROR: Failed to process widget command: ${error.message}`);
        try {
          const failedCommand = normalizeServiceCommand(readJsonFile(claimedPath));
          writeResponseForCommand(failedCommand, {
            status: 'failed',
            error: {
              message: error.message
            }
          });
        } catch {
        }
      } finally {
        persistServiceState({
          activeCommandId: null,
          lastCommandId,
          lastCompletedAt,
          lastError
        });
        completeRequest(claimedPath);
      }
    }
  } finally {
    isProcessing = false;
  }
}

function shutdown() {
  appendLog(serviceLogPath, 'clippy_widget_service shutting down.');
  removeServiceState();
  process.exit(0);
}

async function main() {
  const existingState = readServiceState();
  if (existingState && existingState.pid !== process.pid) {
    appendLog(
      serviceLogPath,
      `Existing clippy_widget_service detected at PID ${existingState.pid}; exiting duplicate process ${process.pid}.`
    );
    return;
  }

  writeServiceState();
  appendLog(serviceLogPath, `clippy_widget_service started with PID ${process.pid}. protocol=v2 responses=${responsesDir}`);

  await processRequests();
  setInterval(() => {
    persistServiceState();
    processRequests();
  }, 1000);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.on('uncaughtException', (error) => {
  appendLog(serviceLogPath, `ERROR: Uncaught exception: ${error.stack || error.message}`);
  shutdown();
});
process.on('unhandledRejection', (error) => {
  const message = error && error.stack ? error.stack : String(error);
  appendLog(serviceLogPath, `ERROR: Unhandled rejection: ${message}`);
  shutdown();
});
process.on('exit', removeServiceState);

if (require.main === module) {
  main().catch((error) => {
    appendLog(serviceLogPath, `ERROR: Service failed to start: ${error.stack || error.message}`);
    shutdown();
  });
}
