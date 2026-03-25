#!/usr/bin/env node
'use strict';

const HOST_PROTOCOL_NAME = 'windows-clippy.terminal-host';
const HOST_PROTOCOL_VERSION = 1;

const HOST_COMMANDS = Object.freeze({
  SESSION_INPUT: 'session.input',
  SESSION_WRITE: 'session.write',
  SESSION_RESIZE: 'session.resize',
  SESSION_RESTART: 'session.restart',
  HOST_SHUTDOWN: 'host.shutdown'
});

const LEGACY_ACTION_TO_COMMAND = Object.freeze({
  input: HOST_COMMANDS.SESSION_INPUT,
  write: HOST_COMMANDS.SESSION_WRITE,
  resize: HOST_COMMANDS.SESSION_RESIZE,
  restart: HOST_COMMANDS.SESSION_RESTART,
  shutdown: HOST_COMMANDS.HOST_SHUTDOWN,
  close: HOST_COMMANDS.HOST_SHUTDOWN
});

function now() {
  return new Date().toISOString();
}

function createEnvelope(type, payload = {}) {
  return {
    protocol: HOST_PROTOCOL_NAME,
    version: HOST_PROTOCOL_VERSION,
    type,
    timestamp: now(),
    payload
  };
}

function createCommand(command, payload = {}) {
  return createEnvelope('host.command', { command, ...payload });
}

function normalizeIncomingCommand(message) {
  if (!message || typeof message !== 'object') {
    throw new Error('Host bridge message must be a JSON object.');
  }

  if (message.type === 'host.command') {
    const payload = message.payload && typeof message.payload === 'object' ? message.payload : {};
    const commandName = payload.command || message.command;
    if (typeof commandName !== 'string' || !commandName.trim()) {
      throw new Error('Host command messages must include payload.command.');
    }

    return {
      command: commandName.trim(),
      payload
    };
  }

  if (typeof message.command === 'string' && message.command.trim()) {
    return {
      command: message.command.trim(),
      payload: message.payload && typeof message.payload === 'object' ? message.payload : message
    };
  }

  if (typeof message.action === 'string' && LEGACY_ACTION_TO_COMMAND[message.action]) {
    return {
      command: LEGACY_ACTION_TO_COMMAND[message.action],
      payload: message
    };
  }

  throw new Error('Unsupported host bridge message shape.');
}

function buildCapabilities(overrides = {}) {
  return {
    protocol: HOST_PROTOCOL_NAME,
    version: HOST_PROTOCOL_VERSION,
    commands: Array.isArray(overrides.commands) && overrides.commands.length > 0
      ? overrides.commands
      : Object.values(HOST_COMMANDS),
    events: Array.isArray(overrides.events) ? overrides.events : [
      'host.ready',
      'host.metadata',
      'host.state',
      'host.error',
      'session.ready',
      'session.output',
      'session.exit',
      'session.error',
      'terminal.card',
      'copilot.event'
    ],
    runtime: overrides.runtime || 'copilot-prompt',
    features: overrides.features && typeof overrides.features === 'object'
      ? overrides.features
      : {}
  };
}

module.exports = {
  HOST_PROTOCOL_NAME,
  HOST_PROTOCOL_VERSION,
  HOST_COMMANDS,
  LEGACY_ACTION_TO_COMMAND,
  createEnvelope,
  createCommand,
  normalizeIncomingCommand,
  buildCapabilities
};
