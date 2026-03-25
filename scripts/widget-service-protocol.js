#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');

const SERVICE_PROTOCOL_NAME = 'windows-clippy.widget-service';
const SERVICE_PROTOCOL_VERSION = 2;

const SERVICE_COMMAND_TYPES = Object.freeze({
  WIDGET_LAUNCH: 'widget.launch'
});

function now() {
  return new Date().toISOString();
}

function ensureDirectory(directoryPath) {
  fs.mkdirSync(directoryPath, { recursive: true });
}

function createServiceState(payload = {}) {
  const capabilities = payload.capabilities || {};
  return {
    protocol: SERVICE_PROTOCOL_NAME,
    version: SERVICE_PROTOCOL_VERSION,
    name: payload.name || 'clippy_widget_service',
    pid: payload.pid || null,
    startedAt: payload.startedAt || now(),
    heartbeatAt: payload.heartbeatAt || now(),
    capabilities: {
      commands: Array.isArray(capabilities.commands) && capabilities.commands.length > 0
        ? capabilities.commands
        : [SERVICE_COMMAND_TYPES.WIDGET_LAUNCH],
      responses: capabilities.responses !== false,
      durableState: capabilities.durableState !== false
    },
    activeCommandId: payload.activeCommandId || null,
    lastCommandId: payload.lastCommandId || null,
    lastCompletedAt: payload.lastCompletedAt || null,
    lastError: payload.lastError || null
  };
}

function buildWidgetLaunchPayload(options = {}) {
  return {
    sessionId: options.sessionId || null,
    openChat: !!options.openChat,
    noWelcome: !!options.noWelcome,
    extraArgs: Array.isArray(options.extraArgs) ? options.extraArgs.slice() : []
  };
}

function createServiceCommand(type, payload = {}, options = {}) {
  const commandId = options.commandId || randomUUID();
  const createdAt = options.createdAt || now();
  return {
    protocol: SERVICE_PROTOCOL_NAME,
    version: SERVICE_PROTOCOL_VERSION,
    id: commandId,
    type,
    createdAt,
    replyPath: options.replyPath || null,
    payload
  };
}

function createWidgetLaunchCommand(options = {}) {
  return createServiceCommand(
    SERVICE_COMMAND_TYPES.WIDGET_LAUNCH,
    buildWidgetLaunchPayload(options),
    options
  );
}

function normalizeServiceCommand(command) {
  if (!command || typeof command !== 'object') {
    throw new Error('Widget service command payload must be an object.');
  }

  if (typeof command.type === 'string' && command.type.trim()) {
    return {
      protocol: command.protocol || SERVICE_PROTOCOL_NAME,
      version: Number.parseInt(command.version, 10) || SERVICE_PROTOCOL_VERSION,
      id: command.id || randomUUID(),
      type: command.type.trim(),
      createdAt: command.createdAt || now(),
      replyPath: command.replyPath || null,
      payload: command.payload && typeof command.payload === 'object'
        ? command.payload
        : {}
    };
  }

  return createWidgetLaunchCommand({
    commandId: command.id || randomUUID(),
    createdAt: command.createdAt || now(),
    replyPath: command.replyPath || null,
    sessionId: command.sessionId || null,
    openChat: !!command.openChat,
    noWelcome: !!command.noWelcome,
    extraArgs: Array.isArray(command.extraArgs) ? command.extraArgs : []
  });
}

function createServiceResponse(command, options = {}) {
  return {
    protocol: SERVICE_PROTOCOL_NAME,
    version: SERVICE_PROTOCOL_VERSION,
    id: command.id,
    type: `${command.type}.result`,
    commandType: command.type,
    createdAt: now(),
    status: options.status || 'succeeded',
    result: options.result || null,
    error: options.error || null
  };
}

function writeJsonFile(filePath, value) {
  ensureDirectory(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeServiceCommandFile(commandsDir, command) {
  ensureDirectory(commandsDir);
  const filePath = path.join(commandsDir, `${Date.now()}-${command.id}.json`);
  writeJsonFile(filePath, command);
  return filePath;
}

function writeServiceResponseFile(filePath, response) {
  writeJsonFile(filePath, response);
  return filePath;
}

module.exports = {
  SERVICE_PROTOCOL_NAME,
  SERVICE_PROTOCOL_VERSION,
  SERVICE_COMMAND_TYPES,
  createServiceState,
  createServiceCommand,
  createWidgetLaunchCommand,
  createServiceResponse,
  normalizeServiceCommand,
  writeServiceCommandFile,
  writeServiceResponseFile,
  readJsonFile,
  writeJsonFile,
  ensureDirectory
};
