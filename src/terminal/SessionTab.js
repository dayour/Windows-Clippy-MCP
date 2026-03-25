#!/usr/bin/env node
'use strict';

/**
 * SessionTab -- per-tab configuration and state machine.
 *
 * Architecture note (mirrors Windows Terminal Tab.h + TerminalPage tab concept):
 *   In Windows Terminal, a Tab holds the user-visible metadata (title, icon,
 *   active state) and is the entry point for operations that go to a
 *   TermControl / content.  SessionTab does the same: it holds the
 *   display-level config for a Clippy tab (name, agent, model, mode, session
 *   ID) and owns the ChildHost + TranscriptSink pair that back it.
 *
 * Lifecycle:
 *   creating  ->  active  ->  suspended  ->  active (resume)
 *                         ->  closed
 *                \-> error
 *
 * A SessionBroker creates SessionTabs; the widget controls plane reads their
 * config to populate the toolbar and tab strip.
 *
 * Responsibilities:
 *   - Hold tab-level metadata: displayName, index, icon hint, launch config.
 *   - Own the ChildHost and TranscriptSink for this tab.
 *   - Expose a start/stop/restart surface that delegates to ChildHost.
 *   - Track the active/suspended/closed state visible to the tab strip.
 *   - Expose a writeInput() relay for the bottom input box.
 *   - Support config updates (agent/model/mode change) that trigger a
 *     controlled restart via terminal-launch-real-session logic (future todo).
 *
 * NOT responsible for:
 *   - Managing other tabs (SessionBroker's job).
 *   - Parsing structured output (TranscriptSink + future parser).
 *   - Widget layout / UI rendering.
 */

const { EventEmitter } = require('events');
const { randomUUID } = require('crypto');
const { createLaunchConfig, resolveSpawnPlan } = require('./SessionCore');
const { ChildHost, HOST_STATE } = require('./ChildHost');
const { TranscriptSink } = require('./TranscriptSink');

// ---------------------------------------------------------------------------
// Tab lifecycle states
// ---------------------------------------------------------------------------

const TAB_STATE = Object.freeze({
  CREATING: 'creating',
  ACTIVE: 'active',
  SUSPENDED: 'suspended',
  CLOSED: 'closed',
  ERROR: 'error'
});

// ---------------------------------------------------------------------------
// SessionTab class
// ---------------------------------------------------------------------------

class SessionTab extends EventEmitter {
  /**
   * @param {Object} options
   * @param {string} [options.tabId]          Unique tab ID (UUID, generated if absent).
   * @param {string} [options.displayName]    Human-readable tab name.
   * @param {Object} [options.launchConfig]   Passed verbatim to SessionCore.createLaunchConfig().
   */
  constructor(options = {}) {
    super();

    this.tabId = typeof options.tabId === 'string' && options.tabId.trim()
      ? options.tabId.trim()
      : randomUUID();

    this.displayName = typeof options.displayName === 'string' && options.displayName.trim()
      ? options.displayName.trim()
      : `Tab ${this.tabId.slice(0, 8)}`;

    // Normalise and freeze the launch config via SessionCore.
    this._launchConfig = createLaunchConfig(options.launchConfig || {});

    // Create the transcript sink bound to this session.
    this._sink = new TranscriptSink(this._launchConfig.sessionId);

    // Build the initial spawn plan.
    const spawnPlan = resolveSpawnPlan(this._launchConfig);

    // Create the child host.
    this._host = new ChildHost(this.tabId, spawnPlan, this._sink);

    // Wire host lifecycle events up to tab-level events.
    this._host.on('started', (detail) => {
      this._setState(TAB_STATE.ACTIVE);
      this.emit('started', { tabId: this.tabId, ...detail });
    });

    this._host.on('stopped', (detail) => {
      if (this._tabState !== TAB_STATE.CLOSED) {
        this._setState(TAB_STATE.SUSPENDED);
      }
      this.emit('stopped', { tabId: this.tabId, ...detail });
    });

    this._host.on('error', (detail) => {
      this._setState(TAB_STATE.ERROR);
      this.emit('error', { tabId: this.tabId, ...detail });
    });

    this._host.on('stateChange', (detail) => {
      this.emit('hostStateChange', detail);
    });

    this._tabState = TAB_STATE.CREATING;
  }

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  get sessionId() {
    return this._launchConfig.sessionId;
  }

  get launchConfig() {
    return this._launchConfig;
  }

  get sink() {
    return this._sink;
  }

  get host() {
    return this._host;
  }

  get tabState() {
    return this._tabState;
  }

  /** Alias for tabState — consistent with ChildHost.state. */
  get state() {
    return this._tabState;
  }

  get hostState() {
    return this._host.state;
  }

  get pid() {
    return this._host.pid;
  }

  get isActive() {
    return this._tabState === TAB_STATE.ACTIVE;
  }

  get isClosed() {
    return this._tabState === TAB_STATE.CLOSED;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /**
   * Starts the backing session (delegates to ChildHost.start()).
   *
   * @returns {Promise<void>}
   */
  start() {
    if (this._tabState === TAB_STATE.CLOSED) {
      return Promise.reject(new Error(`SessionTab(${this.tabId}): tab is closed`));
    }
    return this._host.start();
  }

  /**
   * Stops the backing session without closing the tab.
   * Tab transitions to SUSPENDED; can be resumed with start() or restart().
   *
   * @returns {Promise<void>}
   */
  stop() {
    return this._host.stop();
  }

  /**
   * Restarts the session.  Optionally accepts new config fields to apply
   * before restart (supports agent/model/mode changes from the toolbar).
   *
   * @param {Partial<SessionLaunchConfig>} [configOverrides]
   * @returns {Promise<void>}
   */
  async restart(configOverrides) {
    let newSpawnPlan = null;
    let nextSink = this._sink;
    if (configOverrides) {
      // Re-generate the config with overrides, preserving the session ID unless
      // explicitly replaced so transcript continuity is maintained.
      const merged = Object.assign({}, this._launchConfig, configOverrides);
      this._launchConfig = createLaunchConfig(merged);
      if (this._sink.sessionId !== this._launchConfig.sessionId) {
        nextSink = new TranscriptSink(this._launchConfig.sessionId);
        this._sink = nextSink;
      }
      newSpawnPlan = resolveSpawnPlan(this._launchConfig);
    }
    this._host.setSink(nextSink);
    await this._host.restart(newSpawnPlan);
  }

  /**
   * Permanently closes the tab: stops the session and marks state as CLOSED.
   * The tab cannot be restarted after this.
   *
   * @returns {Promise<void>}
   */
  async close() {
    this._setState(TAB_STATE.CLOSED);
    await this._host.stop();
    this._sink.removeAllListeners();
    this.emit('closed', { tabId: this.tabId, sessionId: this.sessionId });
  }

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------

  /**
   * Sends text input to the active session.
   * Called by the widget bridge layer when the user submits the bottom input box.
   *
   * @param {string} text
   */
  writeInput(text) {
    return this._host.writeInput(text);
  }

  // ---------------------------------------------------------------------------
  // Display metadata
  // ---------------------------------------------------------------------------

  /**
   * Returns a plain serialisable snapshot of this tab for the widget tab strip.
   *
   * @returns {Object}
   */
  toSnapshot() {
    return {
      tabId: this.tabId,
      displayName: this.displayName,
      sessionId: this.sessionId,
      tabState: this._tabState,
      hostState: this._host.state,
      pid: this._host.pid,
      agent: this._launchConfig.agent,
      model: this._launchConfig.model,
      mode: this._launchConfig.mode,
      tools: this._launchConfig.tools.slice(),
      extensions: this._launchConfig.extensions.slice()
    };
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  _setState(newState) {
    const previous = this._tabState;
    this._tabState = newState;
    this.emit('tabStateChange', { tabId: this.tabId, previous, current: newState });
  }
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  TAB_STATE,
  SessionTab
};
