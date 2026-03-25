#!/usr/bin/env node
'use strict';

/**
 * src/terminal/index.js -- public API surface for the terminal broker layer.
 *
 * This is the single import point for any module outside of src/terminal that
 * needs to interact with the child-host/session-broker architecture.
 *
 * Usage (from widget bridge layer or future terminal-launch-real-session code):
 *
 *   const {
 *     getBroker,
 *     createLaunchConfig,
 *     EVENT_TYPES,
 *     BROKER_EVENTS,
 *     TAB_STATE,
 *     HOST_STATE
 *   } = require('./src/terminal');
 *
 *   const broker = getBroker();
 *   const tab = await broker.createTab({
 *     displayName: 'dayour-swe',
 *     launchConfig: {
 *       agent: 'dayour-swe',
 *       model: 'gpt-5.4',
 *       mode: 'agent'
 *     }
 *   });
 *
 *   tab.sink.onRawStdout(({ chunk }) => appendTranscript(chunk));
 *   broker.writeToActive('What is the capital of France?');
 */

const { SessionBroker, getBroker, BROKER_EVENTS, _setBrokerForTest } = require('./SessionBroker');
const { SessionTab, TAB_STATE } = require('./SessionTab');
const { ChildHost, HOST_STATE } = require('./ChildHost');
const { TranscriptSink, createNullSink, EVENT_TYPES, payloads } = require('./TranscriptSink');
const {
  ADAPTIVE_CARD_VERSION,
  TERMINAL_CARD_TEMPLATE_VERSION,
  TERMINAL_CARD_TEMPLATE_PATH,
  TERMINAL_CARD_DATA_SCHEMA_PATH,
  createTerminalCardRuntime,
  beginTerminalCardTurn,
  applyTerminalCardCopilotEvent,
  applyTerminalCardRawOutput,
  recordTerminalCardSessionReady,
  recordTerminalCardSessionError,
  recordTerminalCardSessionExit,
  createTerminalCardData,
  createTerminalAdaptiveCard,
  createTerminalCardSnapshot
} = require('./TerminalAdaptiveCard');
const {
  SessionCore,
  createLaunchConfig,
  resolveSpawnPlan,
  buildSpawnArgs,
  buildPromptSpawnArgs,
  resolvePromptSpawnPlan,
  isUuid,
  DEFAULT_CONFIG_DIR,
  DEFAULT_COPILOT_EXECUTABLE,
  TOOL_FLAG_ALIASES,
  VALID_MODES,
  normalizeMode
} = require('./SessionCore');

module.exports = {
  // Broker
  SessionBroker,
  getBroker,
  BROKER_EVENTS,
  _setBrokerForTest,

  // Tab
  SessionTab,
  TAB_STATE,

  // ChildHost
  ChildHost,
  HOST_STATE,

  // TranscriptSink
  TranscriptSink,
  createNullSink,
  EVENT_TYPES,
  payloads,
  ADAPTIVE_CARD_VERSION,
  TERMINAL_CARD_TEMPLATE_VERSION,
  TERMINAL_CARD_TEMPLATE_PATH,
  TERMINAL_CARD_DATA_SCHEMA_PATH,
  createTerminalCardRuntime,
  beginTerminalCardTurn,
  applyTerminalCardCopilotEvent,
  applyTerminalCardRawOutput,
  recordTerminalCardSessionReady,
  recordTerminalCardSessionError,
  recordTerminalCardSessionExit,
  createTerminalCardData,
  createTerminalAdaptiveCard,
  createTerminalCardSnapshot,

  // SessionCore
  createLaunchConfig,
  resolveSpawnPlan,
  buildSpawnArgs,
  buildPromptSpawnArgs,
  resolvePromptSpawnPlan,
  isUuid,
  DEFAULT_CONFIG_DIR,
  DEFAULT_COPILOT_EXECUTABLE,
  TOOL_FLAG_ALIASES,
  VALID_MODES,
  normalizeMode
};
