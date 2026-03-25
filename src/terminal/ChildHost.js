#!/usr/bin/env node
'use strict';

/**
 * ChildHost -- per-tab process owner.
 *
 * Architecture note (mirrors Windows Terminal AppHost.cpp):
 *   AppHost owns the window/HWND, listens for commandline dispatch, and
 *   bridges the XAML island to the host window.  ChildHost does the analogous
 *   job in our Node/JS world: it owns the spawned child_process, holds the
 *   stdin/stdout/stderr pipes, and is the only object that knows the raw
 *   process handle.
 *
 * Each SessionTab owns exactly one ChildHost.  The SessionBroker never
 * touches child processes directly; it always goes through a tab's ChildHost.
 *
 * Responsibilities:
 *   - Spawn the Copilot CLI process using a SpawnPlan from SessionCore.
 *   - Hold the child process reference and pipe handles.
 *   - Route raw stdout/stderr bytes into the tab's TranscriptSink.
 *   - Accept input writes from the widget/bridge layer (future: bridge-widget-controls-to-pty).
 *   - Manage process lifecycle (start, stop, restart, graceful drain).
 *   - Emit lifecycle events: started, stopped, error.
 *
 * NOT responsible for:
 *   - Tab-level metadata (display name, index, active state) -- that is SessionTab.
 *   - Parsing terminal output into structured events -- that is TranscriptSink and future parsers.
 *   - The window/widget layout -- that is the PowerShell widget layer.
 *
 * States (mirrors Terminal ControlCore lifecycle):
 *
 *   idle  ->  starting  ->  running  ->  stopping  ->  stopped
 *                                   \->  error
 *
 * Transitions:
 *   start()    idle -> starting -> running (on spawn success) | error
 *   stop()     running -> stopping -> stopped
 *   restart()  any -> start flow
 */

const { spawn } = require('child_process');
const { EventEmitter } = require('events');

// ---------------------------------------------------------------------------
// ChildHost lifecycle states (mirrors ControlCore / connection state)
// ---------------------------------------------------------------------------

const HOST_STATE = Object.freeze({
  IDLE: 'idle',
  STARTING: 'starting',
  RUNNING: 'running',
  STOPPING: 'stopping',
  STOPPED: 'stopped',
  ERROR: 'error'
});

// ---------------------------------------------------------------------------
// ChildHost class
// ---------------------------------------------------------------------------

class ChildHost extends EventEmitter {
  /**
   * @param {string}         tabId          Unique ID of the owning SessionTab.
   * @param {SpawnPlan}      spawnPlan      From SessionCore.resolveSpawnPlan().
   * @param {TranscriptSink} transcriptSink Sink this host routes output to.
   */
  constructor(tabId, spawnPlan, transcriptSink) {
    super();

    if (typeof tabId !== 'string' || !tabId.trim()) {
      throw new TypeError('ChildHost: tabId must be a non-empty string');
    }
    if (!spawnPlan || typeof spawnPlan.executable !== 'string') {
      throw new TypeError('ChildHost: spawnPlan must be a valid SpawnPlan from SessionCore');
    }
    if (!transcriptSink || typeof transcriptSink.emit !== 'function') {
      throw new TypeError('ChildHost: transcriptSink must be a TranscriptSink instance');
    }

    this.tabId = tabId;
    this.sessionId = spawnPlan.sessionId;
    this._spawnPlan = spawnPlan;
    this._sink = transcriptSink;
    this._child = null;
    this._state = HOST_STATE.IDLE;
    this._restartCount = 0;
    this._stdinBuffer = [];
    this._stdoutLineBuffer = '';
    this._assistantBuffer = '';
    this._reasoningBuffer = '';
    this._toolCalls = new Map();
  }

  // ---------------------------------------------------------------------------
  // Public accessors
  // ---------------------------------------------------------------------------

  get state() {
    return this._state;
  }

  get pid() {
    return this._child ? this._child.pid : null;
  }

  get isRunning() {
    return this._state === HOST_STATE.RUNNING;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /**
   * Spawns the Copilot CLI child process.
   * Resolves when the process has been spawned (not when it exits).
   * Rejects if the host is not in the idle/stopped/error state.
   *
   * @returns {Promise<void>}
   */
  start() {
    return new Promise((resolve, reject) => {
      if (this._state !== HOST_STATE.IDLE && this._state !== HOST_STATE.STOPPED && this._state !== HOST_STATE.ERROR) {
        return reject(new Error(`ChildHost(${this.tabId}): cannot start from state "${this._state}"`));
      }

      this._setState(HOST_STATE.STARTING);
      this.emit('starting', { tabId: this.tabId, sessionId: this.sessionId });

      let spawnError = null;

      const child = spawn(this._spawnPlan.executable, this._spawnPlan.argv, {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: this._spawnPlan.env,
        cwd: this._spawnPlan.cwd || process.cwd(),
        windowsHide: true,
        // Do not use shell:true -- we want a direct process, not a shell wrapper.
        shell: false
      });

      child.once('error', (err) => {
        spawnError = err;
        this._setState(HOST_STATE.ERROR);
        this._sink.emitSessionError(err.message);
        this.emit('error', { tabId: this.tabId, sessionId: this.sessionId, error: err });
        reject(err);
      });

      child.once('spawn', () => {
        if (spawnError) {
          return;
        }
        this._child = child;
        this._setState(HOST_STATE.RUNNING);
        this._restartCount += 1;

        // Flush any input that was queued before spawn completed.
        this._drainStdinBuffer();

        this._attachIo(child);
        this._sink.emitSessionReady();
        this.emit('started', { tabId: this.tabId, sessionId: this.sessionId, pid: child.pid });
        resolve();
      });

      child.once('exit', (code, signal) => {
        this._child = null;
        if (this._state !== HOST_STATE.STOPPING) {
          // Unexpected exit.
          this._setState(HOST_STATE.STOPPED);
        } else {
          this._setState(HOST_STATE.STOPPED);
        }
        this._sink.emitSessionExit(code, signal);
        this.emit('stopped', { tabId: this.tabId, sessionId: this.sessionId, exitCode: code, signal });
      });
    });
  }

  /**
   * Gracefully stops the child process.
   * Sends SIGTERM (on Windows: taskkill) and resolves when the process exits.
   *
   * @param {number} [timeoutMs=5000]  How long to wait before force-killing.
   * @returns {Promise<void>}
   */
  stop(timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
      if (this._state === HOST_STATE.STOPPED || this._state === HOST_STATE.IDLE) {
        return resolve();
      }
      if (!this._child) {
        this._setState(HOST_STATE.STOPPED);
        return resolve();
      }

      this._setState(HOST_STATE.STOPPING);

      let settled = false;
      const finish = (err) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(forceKillTimer);
        if (err) {
          reject(err);
        } else {
          resolve();
        }
      };

      this.once('stopped', () => finish(null));

      // Try graceful shutdown first.
      try {
        this._child.kill('SIGTERM');
      } catch {
        // Process may already be gone; the 'exit' handler will fire.
      }

      // Force-kill if graceful shutdown does not complete within timeoutMs.
      const forceKillTimer = setTimeout(() => {
        if (this._child) {
          try {
            this._child.kill('SIGKILL');
          } catch {
            // Best-effort.
          }
        }
        finish(null);
      }, timeoutMs);
    });
  }

  /**
   * Stops then re-starts the child process.
   * Used when the widget user changes agent/model and triggers a session restart.
   *
   * @param {SpawnPlan} [newSpawnPlan]  If provided, replaces the current plan before restart.
   * @returns {Promise<void>}
   */
  async restart(newSpawnPlan) {
    await this.stop();
    if (newSpawnPlan) {
      this._spawnPlan = newSpawnPlan;
      this.sessionId = newSpawnPlan.sessionId;
    }
    this._resetOutputTracking();
    this._setState(HOST_STATE.IDLE);
    await this.start();
  }

  setSink(transcriptSink) {
    if (!transcriptSink || typeof transcriptSink.emit !== 'function') {
      throw new TypeError('ChildHost: transcriptSink must be a TranscriptSink instance');
    }
    this._sink = transcriptSink;
    this.sessionId = transcriptSink.sessionId;
  }

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------

  /**
   * Writes text to the child process stdin.
   * If the host is still starting, the write is queued and drained on spawn.
   * Appends a newline if the text does not end with one (mirrors terminal behaviour).
   *
   * @param {string} text  The text to send.
   */
  writeInput(text) {
    const line = String(text).endsWith('\n') ? String(text) : `${String(text)}\n`;

    if (this._state === HOST_STATE.STARTING) {
      this._stdinBuffer.push(line);
      return;
    }

    if (this._state !== HOST_STATE.RUNNING || !this._child || !this._child.stdin) {
      throw new Error(
        `ChildHost(${this.tabId}): cannot write input in state "${this._state}"`
      );
    }

    this._child.stdin.write(line, 'utf8');
    this._sink.emitUserMessage(text.trimEnd());
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  _setState(newState) {
    const previous = this._state;
    this._state = newState;
    this.emit('stateChange', { tabId: this.tabId, previous, current: newState });
  }

  _attachIo(child) {
    this._resetOutputTracking();

    // stdout -> sink raw + future structured parser hook.
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      this._sink.emitRawStdout(chunk);
      this._processStdoutChunk(chunk);
    });

    // stderr -> sink raw.
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      this._sink.emitRawStderr(chunk);
    });
  }

  _drainStdinBuffer() {
    if (!this._child || !this._child.stdin) {
      return;
    }
    while (this._stdinBuffer.length > 0) {
      const line = this._stdinBuffer.shift();
      this._child.stdin.write(line, 'utf8');
    }
  }

  _resetOutputTracking() {
    this._stdoutLineBuffer = '';
    this._assistantBuffer = '';
    this._reasoningBuffer = '';
    this._toolCalls = new Map();
  }

  _processStdoutChunk(chunk) {
    this._stdoutLineBuffer += String(chunk);
    const lines = this._stdoutLineBuffer.split(/\r?\n/);
    this._stdoutLineBuffer = lines.pop() || '';
    for (const line of lines) {
      this._processStructuredLine(line);
    }
  }

  _processStructuredLine(line) {
    const cleanLine = String(line || '').replace(/\u001b/g, '').trim();
    if (!cleanLine) {
      return;
    }

    const jsonStart = cleanLine.indexOf('{');
    if (jsonStart === -1) {
      return;
    }

    let event;
    try {
      event = JSON.parse(cleanLine.slice(jsonStart));
    } catch {
      return;
    }

    if (!event || typeof event !== 'object' || typeof event.type !== 'string') {
      return;
    }

    this._sink.emitCopilotEvent(event);
    this._emitStructuredSinkEvents(event);
  }

  _emitStructuredSinkEvents(event) {
    const eventType = String(event.type || '');
    const data = event.data && typeof event.data === 'object' ? event.data : {};

    switch (eventType) {
      case 'user.message':
        if (typeof data.content === 'string' && data.content.trim()) {
          this._sink.emitUserMessage(data.content);
        }
        return;
      case 'assistant.reasoning_delta': {
        const delta = typeof data.deltaContent === 'string' ? data.deltaContent : '';
        if (delta) {
          this._reasoningBuffer += delta;
          this._sink.emitThought(delta);
        }
        return;
      }
      case 'assistant.reasoning': {
        const content = typeof data.content === 'string' ? data.content : '';
        if (!content) {
          return;
        }

        if (!this._reasoningBuffer) {
          this._sink.emitThought(content);
        } else if (content.startsWith(this._reasoningBuffer)) {
          const suffix = content.slice(this._reasoningBuffer.length);
          if (suffix) {
            this._sink.emitThought(suffix);
          }
        } else {
          this._sink.emitThought(content);
        }

        this._reasoningBuffer = '';
        return;
      }
      case 'assistant.message_delta': {
        const delta = typeof data.deltaContent === 'string' ? data.deltaContent : '';
        if (delta) {
          this._assistantBuffer += delta;
          this._sink.emitAssistantText(delta, false);
        }
        return;
      }
      case 'assistant.message': {
        const content = typeof data.content === 'string' ? data.content : '';
        if (!content) {
          return;
        }

        if (!this._assistantBuffer) {
          this._sink.emitAssistantText(content, true);
        } else if (content.startsWith(this._assistantBuffer)) {
          const suffix = content.slice(this._assistantBuffer.length);
          if (suffix) {
            this._sink.emitAssistantText(suffix, true);
          } else {
            this._sink.emitAssistantText('', true);
          }
        } else {
          this._sink.emitAssistantText(content, true);
        }

        this._assistantBuffer = content;
        return;
      }
      case 'assistant.turn_end':
      case 'result':
        this._assistantBuffer = '';
        this._reasoningBuffer = '';
        this._toolCalls = new Map();
        return;
      case 'tool.execution_start': {
        const toolCallId = typeof data.toolCallId === 'string' ? data.toolCallId : null;
        const toolName = typeof data.toolName === 'string' && data.toolName.trim() ? data.toolName : 'tool';
        if (toolCallId) {
          this._toolCalls.set(toolCallId, toolName);
        }
        this._sink.emitToolUseStart(toolName, data);
        return;
      }
      case 'tool.execution_complete': {
        const toolCallId = typeof data.toolCallId === 'string' ? data.toolCallId : null;
        const toolName =
          (toolCallId && this._toolCalls.get(toolCallId)) ||
          (typeof data.toolName === 'string' && data.toolName.trim() ? data.toolName : 'tool');
        if (toolCallId) {
          this._toolCalls.delete(toolCallId);
        }
        const error = data.success === false ? 'Tool execution failed.' : null;
        this._sink.emitToolUseEnd(toolName, data.result, error);
        return;
      }
      default:
        return;
    }
  }
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  HOST_STATE,
  ChildHost
};
