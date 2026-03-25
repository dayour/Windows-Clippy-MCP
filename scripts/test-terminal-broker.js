#!/usr/bin/env node
'use strict';

/**
 * scripts/test-terminal-broker.js
 *
 * Smoke-tests for the pty-renderer-architecture scaffold.
 * Validates that the module graph loads cleanly, all exported symbols have the
 * right types, and the broker/tab/sink APIs behave correctly without spawning
 * a real child process.
 *
 * Run with: node scripts/test-terminal-broker.js
 * Also invoked by: npm test (via validate.js && integration-test.js chain)
 */

const fs = require('fs');
const path = require('path');

const PASS = '\x1b[32mPASS\x1b[0m';
const FAIL = '\x1b[31mFAIL\x1b[0m';

let failures = 0;

function assert(condition, description) {
  if (condition) {
    console.log(`  ${PASS}  ${description}`);
  } else {
    console.error(`  ${FAIL}  ${description}`);
    failures += 1;
  }
}

function assertThrows(fn, description) {
  try {
    fn();
    console.error(`  ${FAIL}  ${description} (expected throw, got none)`);
    failures += 1;
  } catch {
    console.log(`  ${PASS}  ${description}`);
  }
}

async function assertRejects(fn, description) {
  try {
    await fn();
    console.error(`  ${FAIL}  ${description} (expected rejection, got none)`);
    failures += 1;
  } catch {
    console.log(`  ${PASS}  ${description}`);
  }
}

// ---------------------------------------------------------------------------
// Load the module graph
// ---------------------------------------------------------------------------

console.log('\n[1/6] Module loading');

let terminalModule;
try {
  terminalModule = require(path.join(__dirname, '..', 'src', 'terminal', 'index.js'));
  assert(true, 'src/terminal/index.js loads without error');
} catch (err) {
  assert(false, `src/terminal/index.js loads without error -- ERROR: ${err.message}`);
  process.exit(1);
}

const {
  SessionBroker,
  getBroker,
  BROKER_EVENTS,
  _setBrokerForTest,
  SessionTab,
  TAB_STATE,
  ChildHost,
  HOST_STATE,
  TranscriptSink,
  createNullSink,
  EVENT_TYPES,
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
  createLaunchConfig,
  resolveSpawnPlan,
  buildPromptSpawnArgs,
  resolvePromptSpawnPlan,
  isUuid,
  DEFAULT_CONFIG_DIR,
  TOOL_FLAG_ALIASES,
  VALID_MODES
} = terminalModule;

assert(typeof SessionBroker === 'function', 'SessionBroker is a constructor');
assert(typeof getBroker === 'function', 'getBroker is a function');
assert(typeof BROKER_EVENTS === 'object', 'BROKER_EVENTS is an object');
assert(typeof SessionTab === 'function', 'SessionTab is a constructor');
assert(typeof TAB_STATE === 'object', 'TAB_STATE is an object');
assert(typeof ChildHost === 'function', 'ChildHost is a constructor');
assert(typeof HOST_STATE === 'object', 'HOST_STATE is an object');
assert(typeof TranscriptSink === 'function', 'TranscriptSink is a constructor');
assert(typeof createNullSink === 'function', 'createNullSink is a function');
assert(typeof EVENT_TYPES === 'object', 'EVENT_TYPES is an object');
assert(typeof createTerminalCardRuntime === 'function', 'createTerminalCardRuntime is a function');
assert(typeof createTerminalCardSnapshot === 'function', 'createTerminalCardSnapshot is a function');
assert(typeof createLaunchConfig === 'function', 'createLaunchConfig is a function');
assert(typeof resolveSpawnPlan === 'function', 'resolveSpawnPlan is a function');
assert(typeof buildPromptSpawnArgs === 'function', 'buildPromptSpawnArgs is a function');
assert(typeof resolvePromptSpawnPlan === 'function', 'resolvePromptSpawnPlan is a function');
assert(typeof isUuid === 'function', 'isUuid is a function');
assert(typeof DEFAULT_CONFIG_DIR === 'string', 'DEFAULT_CONFIG_DIR is a string');
assert(typeof TOOL_FLAG_ALIASES === 'object', 'TOOL_FLAG_ALIASES is an object');
assert(typeof VALID_MODES === 'object', 'VALID_MODES is a Set');

// ---------------------------------------------------------------------------
// SessionCore
// ---------------------------------------------------------------------------

console.log('\n[2/6] SessionCore -- createLaunchConfig / resolveSpawnPlan');

const config1 = createLaunchConfig({});
assert(isUuid(config1.sessionId), 'createLaunchConfig() generates a UUID sessionId');
assert(config1.configDir === DEFAULT_CONFIG_DIR, 'createLaunchConfig() uses default configDir');
assert(config1.agent === null, 'createLaunchConfig() agent defaults to null');
assert(config1.model === null, 'createLaunchConfig() model defaults to null');
assert(config1.mode === null, 'createLaunchConfig() mode defaults to null');
assert(Array.isArray(config1.tools), 'createLaunchConfig() tools is an array');
assert(Array.isArray(config1.extensions), 'createLaunchConfig() extensions is an array');
assert(Object.isFrozen(config1), 'createLaunchConfig() result is frozen');

const config2 = createLaunchConfig({
  agent: 'dayour-swe',
  model: 'gpt-5.4',
  mode: 'Agent',
  tools: ['allow-all-tools', '--experimental'],
  workingDirectory: path.join(__dirname, '..')
});
assert(config2.agent === 'dayour-swe', 'createLaunchConfig() stores agent');
assert(config2.model === 'gpt-5.4', 'createLaunchConfig() stores model');
assert(config2.mode === 'agent', 'createLaunchConfig() stores mode');
assert(config2.tools.includes('--allow-all-tools'), 'createLaunchConfig() normalizes known tool aliases');
assert(config2.tools.includes('--experimental'), 'createLaunchConfig() preserves raw tool flags');
assert(path.isAbsolute(config2.workingDirectory), 'createLaunchConfig() resolves workingDirectory to absolute path');

const config3 = createLaunchConfig({ mode: 'invalid-mode' });
assert(config3.mode === null, 'createLaunchConfig() ignores invalid mode');

const plan = resolveSpawnPlan(config2);
assert(typeof plan.executable === 'string', 'resolveSpawnPlan() returns executable');
assert(Array.isArray(plan.argv), 'resolveSpawnPlan() returns argv array');
assert(plan.argv.some((a) => a.startsWith('--resume=')), 'argv includes --resume flag');
assert(plan.argv.includes('--agent'), 'argv includes --agent flag');
assert(plan.argv.includes('dayour-swe'), 'argv includes agent name');
assert(plan.argv.includes('--model'), 'argv includes --model flag');
assert(plan.argv.includes('gpt-5.4'), 'argv includes model name');
assert(plan.argv.includes('--allow-all-tools'), 'argv includes tool flag');
assert(plan.argv.includes('--experimental'), 'argv includes raw tool flag');
assert(plan.argv.includes('--add-dir'), 'argv includes working directory access flag');
assert(plan.argv.includes(config2.workingDirectory), 'argv includes working directory value');
assert(plan.sessionId === config2.sessionId, 'resolveSpawnPlan() echoes sessionId');
assert(plan.cwd === config2.workingDirectory, 'resolveSpawnPlan() includes cwd');
assert(plan.env.CLIPPY_SESSION_MODE === 'agent', 'resolveSpawnPlan() includes session mode env var');
assert(Object.isFrozen(plan), 'resolveSpawnPlan() result is frozen');

const promptArgs = buildPromptSpawnArgs(config2, 'Say hello');
assert(promptArgs.argv[0] === '-p', 'buildPromptSpawnArgs() prefixes prompt mode flag');
assert(promptArgs.argv[1] === 'Say hello', 'buildPromptSpawnArgs() includes prompt text');
assert(promptArgs.argv.includes('--stream'), 'buildPromptSpawnArgs() includes streaming flag');
assert(promptArgs.argv.includes('on'), 'buildPromptSpawnArgs() defaults streaming to on');

const promptPlan = resolvePromptSpawnPlan(config2, 'Say hello');
assert(promptPlan.argv[0] === '-p', 'resolvePromptSpawnPlan() returns prompt-mode argv');
assert(promptPlan.prompt === 'Say hello', 'resolvePromptSpawnPlan() preserves prompt text');
assert(promptPlan.cwd === config2.workingDirectory, 'resolvePromptSpawnPlan() includes cwd');
assert(Object.isFrozen(promptPlan), 'resolvePromptSpawnPlan() result is frozen');

assertThrows(() => createLaunchConfig({ sessionId: 'not-a-uuid' }), 'createLaunchConfig() throws on invalid sessionId');
assertThrows(() => createLaunchConfig({ tools: ['not-a-tool-flag'] }), 'createLaunchConfig() throws on unsupported tool flag');
assertThrows(() => buildPromptSpawnArgs(config2, ''), 'buildPromptSpawnArgs() throws on empty prompt');

// ---------------------------------------------------------------------------
// TranscriptSink
// ---------------------------------------------------------------------------

console.log('\n[3/6] TranscriptSink -- event emission');

const { randomUUID } = require('crypto');
const testSessionId = randomUUID();
const sink = new TranscriptSink(testSessionId);
assert(sink.sessionId === testSessionId, 'TranscriptSink stores sessionId');

let stdoutReceived = null;
sink.onRawStdout((payload) => { stdoutReceived = payload; });
sink.emitRawStdout('hello world');
assert(stdoutReceived !== null, 'emitRawStdout fires onRawStdout listener');
assert(stdoutReceived.chunk === 'hello world', 'onRawStdout payload has correct chunk');
assert(stdoutReceived.sessionId === testSessionId, 'onRawStdout payload has correct sessionId');

let exitReceived = null;
sink.onSessionExit((payload) => { exitReceived = payload; });
sink.emitSessionExit(0, null);
assert(exitReceived !== null, 'emitSessionExit fires onSessionExit listener');
assert(exitReceived.exitCode === 0, 'onSessionExit payload has correct exitCode');

let copilotEventReceived = null;
sink.onCopilotEvent((payload) => { copilotEventReceived = payload; });
sink.emitCopilotEvent({ type: 'assistant.message', data: { content: 'hello' } });
assert(copilotEventReceived !== null, 'emitCopilotEvent fires onCopilotEvent listener');
assert(copilotEventReceived.event.type === 'assistant.message', 'onCopilotEvent payload preserves event type');

const nullSink = createNullSink(testSessionId);
assert(nullSink instanceof TranscriptSink, 'createNullSink returns a TranscriptSink');
// Null sink should not throw when emitting.
try {
  nullSink.emitRawStdout('test');
  nullSink.emitSessionError('boom');
  assert(true, 'createNullSink emits do not throw');
} catch (err) {
  assert(false, `createNullSink emits do not throw -- ERROR: ${err.message}`);
}

assertThrows(() => new TranscriptSink(''), 'TranscriptSink throws on empty sessionId');

// ---------------------------------------------------------------------------
// Terminal Adaptive Card
// ---------------------------------------------------------------------------

console.log('\n[4/7] TerminalAdaptiveCard -- snapshot generation');

const cardRuntime = createTerminalCardRuntime();
beginTerminalCardTurn(cardRuntime, 'Summarize the repository status');
applyTerminalCardCopilotEvent(cardRuntime, {
  type: 'assistant.reasoning_delta',
  data: { deltaContent: 'Inspecting repository layout' }
});
applyTerminalCardCopilotEvent(cardRuntime, {
  type: 'tool.execution_start',
  data: { toolCallId: 'tool-1', toolName: 'rg', arguments: { path: 'src' } }
});
applyTerminalCardCopilotEvent(cardRuntime, {
  type: 'tool.execution_complete',
  data: { toolCallId: 'tool-1', toolName: 'rg', result: { matches: 3 } }
});
applyTerminalCardCopilotEvent(cardRuntime, {
  type: 'assistant.message',
  data: { content: 'Repository summary ready' }
});
applyTerminalCardRawOutput(cardRuntime, 'fallback transcript preview');
recordTerminalCardSessionReady(cardRuntime);
recordTerminalCardSessionExit(cardRuntime, 0, null);

const cardData = createTerminalCardData({
  tabId: 'tab-1',
  displayName: 'Adaptive Card Test',
  sessionId: testSessionId,
  hostState: 'running',
  pid: 4321,
  sessionTransport: 'resume-prompt-stream',
  launchConfig: {
    sessionId: testSessionId,
    configDir: DEFAULT_CONFIG_DIR,
    agent: 'dayour-swe',
    model: 'gpt-5.4',
    mode: 'agent',
    tools: ['--allow-all-tools'],
    extraFlags: ['--sandbox=workspace-write'],
    workingDirectory: path.join(__dirname, '..')
  },
  runtime: cardRuntime
});
const adaptiveCard = createTerminalAdaptiveCard(cardData);
const cardSnapshot = createTerminalCardSnapshot({
  tabId: 'tab-1',
  displayName: 'Adaptive Card Test',
  sessionId: testSessionId,
  hostState: 'running',
  pid: 4321,
  sessionTransport: 'resume-prompt-stream',
  launchConfig: {
    sessionId: testSessionId,
    configDir: DEFAULT_CONFIG_DIR,
    agent: 'dayour-swe',
    model: 'gpt-5.4',
    mode: 'agent',
    tools: ['--allow-all-tools'],
    extraFlags: ['--sandbox=workspace-write'],
    workingDirectory: path.join(__dirname, '..')
  },
  runtime: cardRuntime
});
const templateJson = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', TERMINAL_CARD_TEMPLATE_PATH), 'utf8')
);
const dataSchemaJson = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', TERMINAL_CARD_DATA_SCHEMA_PATH), 'utf8')
);

assert(cardData.templateVersion === TERMINAL_CARD_TEMPLATE_VERSION, 'createTerminalCardData() uses the shared template version');
assert(cardData.session.shortSessionId === testSessionId.slice(0, 8), 'createTerminalCardData() derives shortSessionId');
assert(cardData.status.toolFlagSummary.includes('All tools'), 'createTerminalCardData() summarizes tool flags');
assert(cardData.recentTools.length === 1, 'createTerminalCardData() captures recent tools');
assert(cardData.transcript.latestAssistantText === 'Repository summary ready', 'createTerminalCardData() stores assistant preview');
assert(adaptiveCard.type === 'AdaptiveCard', 'createTerminalAdaptiveCard() returns an Adaptive Card');
assert(adaptiveCard.version === ADAPTIVE_CARD_VERSION, 'createTerminalAdaptiveCard() targets the shared adaptive card version');
assert(cardSnapshot.card.fallbackText.includes('Windows Clippy terminal session'), 'createTerminalCardSnapshot() includes fallback text');
assert(templateJson.version === ADAPTIVE_CARD_VERSION, 'terminal-session.template.json targets the shared adaptive card version');
assert(dataSchemaJson.title.includes('Terminal Session'), 'terminal-session.data.schema.json describes the terminal card data contract');

recordTerminalCardSessionError(cardRuntime, 'Synthetic failure');
assert(cardRuntime.lastError === 'Synthetic failure', 'recordTerminalCardSessionError() stores the latest error');

// ---------------------------------------------------------------------------
// SessionTab (without real spawn -- STATE machine only)
// ---------------------------------------------------------------------------

console.log('\n[5/7] SessionTab -- construction and metadata');

const tab = new SessionTab({
  displayName: 'Test Tab',
  launchConfig: { agent: 'dayour-swe', model: 'gpt-5.4' }
});

assert(typeof tab.tabId === 'string', 'SessionTab generates a tabId');
assert(tab.displayName === 'Test Tab', 'SessionTab stores displayName');
assert(tab.tabState === TAB_STATE.CREATING, 'SessionTab starts in CREATING state');
assert(isUuid(tab.sessionId), 'SessionTab has a UUID sessionId');
assert(tab.launchConfig.agent === 'dayour-swe', 'SessionTab stores agent from launchConfig');
assert(tab.launchConfig.model === 'gpt-5.4', 'SessionTab stores model from launchConfig');
assert(tab.sink instanceof TranscriptSink, 'SessionTab exposes a TranscriptSink');
assert(tab.host instanceof ChildHost, 'SessionTab exposes a ChildHost');

const snapshot = tab.toSnapshot();
assert(snapshot.tabId === tab.tabId, 'toSnapshot() includes tabId');
assert(snapshot.sessionId === tab.sessionId, 'toSnapshot() includes sessionId');
assert(snapshot.agent === 'dayour-swe', 'toSnapshot() includes agent');
assert(snapshot.model === 'gpt-5.4', 'toSnapshot() includes model');

// ---------------------------------------------------------------------------
// SessionBroker and constant checks run inside an async main so that top-level
// await is not required (Node CJS does not support top-level await).
// ---------------------------------------------------------------------------

async function runBrokerAndConstantTests() {
  // -- [5/6] SessionBroker --

  console.log('\n[6/7] SessionBroker -- registry management');

  const { _setBrokerForTest: setBrokerForTest } = terminalModule;
  const broker = new SessionBroker();
  setBrokerForTest(broker);

  assert(broker.tabCount === 0, 'New broker has 0 tabs');
  assert(broker.activeTab === null, 'New broker has no active tab');
  assert(typeof broker.toSnapshot === 'function', 'Broker exposes toSnapshot()');
  assert(typeof broker.writeToActive === 'function', 'Broker exposes writeToActive()');
  assert(typeof broker.createTab === 'function', 'Broker exposes createTab()');
  assert(typeof broker.closeTab === 'function', 'Broker exposes closeTab()');
  assert(typeof broker.shutdown === 'function', 'Broker exposes shutdown()');

  assert(typeof BROKER_EVENTS.TAB_CREATED === 'string', 'BROKER_EVENTS.TAB_CREATED is a string');
  assert(typeof BROKER_EVENTS.TAB_CLOSED === 'string', 'BROKER_EVENTS.TAB_CLOSED is a string');
  assert(typeof BROKER_EVENTS.ACTIVE_TAB_CHANGED === 'string', 'BROKER_EVENTS.ACTIVE_TAB_CHANGED is a string');
  assert(typeof BROKER_EVENTS.BROKER_READY === 'string', 'BROKER_EVENTS.BROKER_READY is a string');

  let createdEvent = null;
  broker.on(BROKER_EVENTS.TAB_CREATED, (ev) => { createdEvent = ev; });

  // Register a tab manually to avoid spawning a real process.
  const newTab = new SessionTab({
    displayName: 'Broker Test Tab',
    launchConfig: { agent: 'dayour-test', model: 'gpt-5.4' }
  });

  broker._tabs.set(newTab.tabId, newTab);
  broker._tabOrder.push(newTab.tabId);
  broker._activeTabId = newTab.tabId;

  broker.emit(BROKER_EVENTS.TAB_CREATED, {
    tabId: newTab.tabId,
    displayName: newTab.displayName,
    sessionId: newTab.sessionId,
    index: 0
  });

  assert(broker.tabCount === 1, 'Broker has 1 tab after manual registration');
  assert(broker.activeTab !== null, 'Broker has an active tab');
  assert(broker.activeTab.tabId === newTab.tabId, 'Active tab matches registered tab');
  assert(createdEvent !== null, 'TAB_CREATED event was emitted');
  assert(createdEvent.tabId === newTab.tabId, 'TAB_CREATED event carries correct tabId');

  const brokerSnapshot = broker.toSnapshot();
  assert(brokerSnapshot.activeTabId === newTab.tabId, 'toSnapshot activeTabId is correct');
  assert(Array.isArray(brokerSnapshot.tabs), 'toSnapshot includes tabs array');
  assert(brokerSnapshot.tabs.length === 1, 'toSnapshot has 1 tab entry');

  assertThrows(
    () => broker.writeToActive('test prompt'),
    'writeToActive throws when active tab host is not running'
  );

  // nextTab / prevTab with single tab (no-op, should not throw)
  try {
    broker.nextTab();
    broker.prevTab();
    assert(true, 'nextTab/prevTab do not throw with single tab');
  } catch (err) {
    assert(false, `nextTab/prevTab do not throw with single tab -- ERROR: ${err.message}`);
  }

  setBrokerForTest(null);

  // -- [7/7] Constants --

  console.log('\n[7/7] Constant integrity checks');

  const expectedHostStates = ['idle', 'starting', 'running', 'stopping', 'stopped', 'error'];
  for (const state of expectedHostStates) {
    assert(Object.values(HOST_STATE).includes(state), `HOST_STATE includes "${state}"`);
  }

  const expectedTabStates = ['creating', 'active', 'suspended', 'closed', 'error'];
  for (const state of expectedTabStates) {
    assert(Object.values(TAB_STATE).includes(state), `TAB_STATE includes "${state}"`);
  }

  const expectedEventTypes = [
    'raw:stdout', 'raw:stderr', 'transcript:assistant', 'transcript:user',
    'transcript:thought', 'tool:start', 'tool:end', 'copilot:event',
    'session:ready', 'session:exit', 'session:error'
  ];
  for (const et of expectedEventTypes) {
    assert(Object.values(EVENT_TYPES).includes(et), `EVENT_TYPES includes "${et}"`);
  }

  // -- Summary --

  console.log('');
  if (failures === 0) {
    console.log('\x1b[32mAll terminal broker smoke tests passed.\x1b[0m\n');
    process.exit(0);
  } else {
    console.error(`\x1b[31m${failures} test(s) failed.\x1b[0m\n`);
    process.exit(1);
  }
}

runBrokerAndConstantTests().catch((err) => {
  console.error(`FATAL: ${err.message}`);
  process.exit(1);
});
