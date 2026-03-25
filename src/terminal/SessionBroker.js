#!/usr/bin/env node
'use strict';

/**
 * SessionBroker -- process-level tab registry and lifecycle orchestrator.
 *
 * Architecture note (mirrors Windows Terminal WindowEmperor.h):
 *   WindowEmperor is the single object that manages the entire terminal
 *   process: it holds all AppHost instances (windows), handles commandline
 *   dispatch, routes new-tab requests to the right window, and coordinates
 *   global state like hotkeys and the notification icon.
 *
 *   SessionBroker plays the same role in Clippy space:
 *     - It is a singleton per Clippy widget process.
 *     - It owns the tab registry (Map<tabId, SessionTab>).
 *     - It creates tabs, routes input to the active tab, and destroys tabs.
 *     - It broadcasts broker-level lifecycle events that the widget can listen to
 *       (tabCreated, tabClosed, activeTabChanged, brokerReady).
 *     - It exposes the activeTab concept mirroring TerminalPage.ActiveTab().
 *
 * Key WindowEmperor patterns reflected here:
 *   - _windows  list          ->  _tabs  Map
 *   - CreateNewWindow()       ->  createTab()
 *   - _mostRecentWindow()     ->  activeTab (getter)
 *   - HandleCommandlineArgs() ->  dispatch() / writeToActive()
 *   - _postQuitIfNeeded()     ->  shutdown()
 *
 * Responsibilities:
 *   - Create, track, switch, and destroy SessionTabs.
 *   - Maintain the ordered tab sequence and active-tab pointer.
 *   - Route writeInput() to the currently active tab.
 *   - Provide a unified event surface for the widget layer (tab strip, toolbar).
 *   - Support serialising broker state for widget persistence.
 *
 * NOT responsible for:
 *   - Spawning child processes directly (ChildHost's job).
 *   - Widget layout or PowerShell UI.
 *   - Parsing session output.
 */

const { EventEmitter } = require('events');
const { SessionTab, TAB_STATE } = require('./SessionTab');
const { createLaunchConfig } = require('./SessionCore');

// ---------------------------------------------------------------------------
// Broker events emitted to the widget layer
// ---------------------------------------------------------------------------

const BROKER_EVENTS = Object.freeze({
  /** A new tab was created. Payload: { tabId, displayName, sessionId, index } */
  TAB_CREATED: 'broker:tabCreated',

  /** A tab was closed. Payload: { tabId, sessionId, index } */
  TAB_CLOSED: 'broker:tabClosed',

  /** The active tab changed. Payload: { previousTabId, activeTabId, index } */
  ACTIVE_TAB_CHANGED: 'broker:activeTabChanged',

  /** A tab's state changed. Payload: tabSnapshot */
  TAB_STATE_CHANGED: 'broker:tabStateChanged',

  /** The broker is ready (called after the first tab is started). */
  BROKER_READY: 'broker:ready',

  /** The broker is shutting down. */
  BROKER_SHUTDOWN: 'broker:shutdown'
});

// ---------------------------------------------------------------------------
// SessionBroker class
// ---------------------------------------------------------------------------

class SessionBroker extends EventEmitter {
  constructor() {
    super();
    /** @type {Map<string, SessionTab>} */
    this._tabs = new Map();
    /** @type {string[]}  Ordered tab IDs, mirrors the tab-strip order. */
    this._tabOrder = [];
    /** @type {string|null}  Currently active tab ID. */
    this._activeTabId = null;
    this._started = false;
    this.setMaxListeners(30);
  }

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  /**
   * The currently active SessionTab, or null if no tab exists.
   * Mirrors WindowEmperor._mostRecentWindow().
   *
   * @returns {SessionTab|null}
   */
  get activeTab() {
    return this._activeTabId ? (this._tabs.get(this._activeTabId) || null) : null;
  }

  /**
   * All tabs in strip order.
   *
   * @returns {SessionTab[]}
   */
  get tabs() {
    return this._tabOrder.map((id) => this._tabs.get(id)).filter(Boolean);
  }

  /**
   * Number of open (non-closed) tabs.
   *
   * @returns {number}
   */
  get tabCount() {
    return this._tabs.size;
  }

  // ---------------------------------------------------------------------------
  // Tab creation
  // ---------------------------------------------------------------------------

  /**
   * Creates a new SessionTab and adds it to the registry.
   * Mirrors WindowEmperor.CreateNewWindow().
   *
   * @param {Object} options
   * @param {string}  [options.displayName]  Tab display name.
   * @param {Object}  [options.launchConfig] Passed to SessionCore.createLaunchConfig().
   * @param {boolean} [options.autoStart]    If true, starts the session immediately.
   *                                         Default: true.
   * @param {boolean} [options.makeActive]   If true, makes this tab the active one.
   *                                         Default: true.
   * @returns {Promise<SessionTab>}
   */
  async createTab(options = {}) {
    const {
      displayName,
      launchConfig,
      autoStart = true,
      makeActive = true
    } = options;

    const tab = new SessionTab({
      displayName,
      launchConfig
    });

    // Register the tab.
    this._tabs.set(tab.tabId, tab);
    this._tabOrder.push(tab.tabId);

    // Forward tab-level events to broker consumers.
    tab.on('tabStateChange', (detail) => {
      this.emit(BROKER_EVENTS.TAB_STATE_CHANGED, tab.toSnapshot());
    });

    tab.on('closed', (detail) => {
      this._unregisterTab(detail.tabId);
    });

    const index = this._tabOrder.indexOf(tab.tabId);
    this.emit(BROKER_EVENTS.TAB_CREATED, {
      tabId: tab.tabId,
      displayName: tab.displayName,
      sessionId: tab.sessionId,
      index
    });

    if (makeActive) {
      this.setActiveTab(tab.tabId);
    }

    if (autoStart) {
      await tab.start();
      if (!this._started) {
        this._started = true;
        this.emit(BROKER_EVENTS.BROKER_READY);
      }
    }

    return tab;
  }

  // ---------------------------------------------------------------------------
  // Active tab management
  // ---------------------------------------------------------------------------

  /**
   * Changes the active tab.
   * Mirrors the tab-switching logic in TerminalPage / tab-strip click handler.
   *
   * @param {string} tabId
   */
  setActiveTab(tabId) {
    if (!this._tabs.has(tabId)) {
      throw new Error(`SessionBroker: no tab with ID "${tabId}"`);
    }

    const previous = this._activeTabId;
    this._activeTabId = tabId;

    if (previous !== tabId) {
      const index = this._tabOrder.indexOf(tabId);
      this.emit(BROKER_EVENTS.ACTIVE_TAB_CHANGED, {
        previousTabId: previous,
        activeTabId: tabId,
        index
      });
    }
  }

  /**
   * Activates the tab at the given zero-based index.
   *
   * @param {number} index
   */
  setActiveTabByIndex(index) {
    const tabId = this._tabOrder[index];
    if (!tabId) {
      throw new RangeError(`SessionBroker: no tab at index ${index}`);
    }
    this.setActiveTab(tabId);
  }

  /**
   * Activates the next tab (wraps around).
   */
  nextTab() {
    if (this._tabOrder.length === 0) {
      return;
    }
    const current = this._tabOrder.indexOf(this._activeTabId);
    const next = (current + 1) % this._tabOrder.length;
    this.setActiveTabByIndex(next);
  }

  /**
   * Activates the previous tab (wraps around).
   */
  prevTab() {
    if (this._tabOrder.length === 0) {
      return;
    }
    const current = this._tabOrder.indexOf(this._activeTabId);
    const prev = (current - 1 + this._tabOrder.length) % this._tabOrder.length;
    this.setActiveTabByIndex(prev);
  }

  // ---------------------------------------------------------------------------
  // Input dispatch
  // ---------------------------------------------------------------------------

  /**
   * Sends text input to the currently active tab.
   * Called by the bridge layer that wires the bottom input box to sessions.
   * Mirrors the "dispatch commandline to active window" path in WindowEmperor.
   *
   * @param {string} text
   */
  writeToActive(text) {
    const tab = this.activeTab;
    if (!tab) {
      throw new Error('SessionBroker: no active tab to write to');
    }
    if (!tab.isActive) {
      throw new Error(
        `SessionBroker: active tab "${tab.tabId}" is in state "${tab.tabState}" and cannot accept input`
      );
    }
    tab.writeInput(text);
  }

  // ---------------------------------------------------------------------------
  // Tab retrieval
  // ---------------------------------------------------------------------------

  /**
   * Returns a tab by ID, or null.
   *
   * @param {string} tabId
   * @returns {SessionTab|null}
   */
  getTab(tabId) {
    return this._tabs.get(tabId) || null;
  }

  /**
   * Returns the tab at the given index, or null.
   *
   * @param {number} index
   * @returns {SessionTab|null}
   */
  getTabByIndex(index) {
    const tabId = this._tabOrder[index];
    return tabId ? (this._tabs.get(tabId) || null) : null;
  }

  /**
   * Returns all tabs in strip order.
   * Convenience method equivalent to the `tabs` getter — mirrors a familiar
   * method-call pattern for callers who expect listTabs().
   *
   * @returns {SessionTab[]}
   */
  listTabs() {
    return this.tabs;
  }

  // ---------------------------------------------------------------------------
  // Tab close
  // ---------------------------------------------------------------------------

  /**
   * Closes and removes a tab by ID.
   *
   * @param {string} tabId
   * @returns {Promise<void>}
   */
  async closeTab(tabId) {
    const tab = this._tabs.get(tabId);
    if (!tab) {
      return;
    }
    await tab.close();
    // _unregisterTab is called via the 'closed' event handler registered in createTab.
  }

  /**
   * Closes the currently active tab.
   *
   * @returns {Promise<void>}
   */
  closeActiveTab() {
    if (!this._activeTabId) {
      return Promise.resolve();
    }
    return this.closeTab(this._activeTabId);
  }

  // ---------------------------------------------------------------------------
  // Broker-level config update helpers
  // ---------------------------------------------------------------------------

  /**
   * Applies a config override to the active tab and restarts its session.
   * Used by toolbar controls (agent, model, mode selectors) when the user
   * changes a setting while a session is live.
   *
   * @param {Partial<SessionLaunchConfig>} overrides
   * @returns {Promise<void>}
   */
  async updateActiveTabConfig(overrides) {
    const tab = this.activeTab;
    if (!tab) {
      throw new Error('SessionBroker: no active tab to update');
    }
    await tab.restart(overrides);
  }

  // ---------------------------------------------------------------------------
  // State snapshot (for widget persistence / tab-strip hydration)
  // ---------------------------------------------------------------------------

  /**
   * Returns a serialisable snapshot of all tabs for the widget layer.
   * This is what the widget reads to draw the tab strip and set toolbar state.
   *
   * @returns {Object}
   */
  toSnapshot() {
    return {
      activeTabId: this._activeTabId,
      tabs: this._tabOrder.map((id) => {
        const tab = this._tabs.get(id);
        return tab ? tab.toSnapshot() : null;
      }).filter(Boolean)
    };
  }

  // ---------------------------------------------------------------------------
  // Shutdown
  // ---------------------------------------------------------------------------

  /**
   * Shuts down all sessions and clears the registry.
   * Mirrors WindowEmperor._postQuitMessageIfNeeded().
   *
   * @returns {Promise<void>}
   */
  async shutdown() {
    this.emit(BROKER_EVENTS.BROKER_SHUTDOWN);
    const closePromises = [...this._tabs.values()].map((tab) => tab.close().catch(() => {}));
    await Promise.all(closePromises);
    this._tabs.clear();
    this._tabOrder.length = 0;
    this._activeTabId = null;
    this._started = false;
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  _unregisterTab(tabId) {
    this._tabs.delete(tabId);
    const index = this._tabOrder.indexOf(tabId);
    if (index !== -1) {
      this._tabOrder.splice(index, 1);
    }

    this.emit(BROKER_EVENTS.TAB_CLOSED, { tabId, index });

    // If the closed tab was active, switch to the nearest remaining tab.
    if (this._activeTabId === tabId) {
      this._activeTabId = null;
      if (this._tabOrder.length > 0) {
        const newIndex = Math.min(index, this._tabOrder.length - 1);
        this.setActiveTabByIndex(newIndex);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Module-level singleton factory
// ---------------------------------------------------------------------------

let _instance = null;

/**
 * Returns the process-wide SessionBroker singleton.
 * Analogous to the single WindowEmperor created in WinMain.
 *
 * @returns {SessionBroker}
 */
function getBroker() {
  if (!_instance) {
    _instance = new SessionBroker();
  }
  return _instance;
}

/**
 * Replaces the singleton (for testing only).
 *
 * @param {SessionBroker|null} instance
 */
function _setBrokerForTest(instance) {
  _instance = instance;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  BROKER_EVENTS,
  SessionBroker,
  getBroker,
  _setBrokerForTest
};
