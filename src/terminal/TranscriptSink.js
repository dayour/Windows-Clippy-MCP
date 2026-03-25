#!/usr/bin/env node
'use strict';

/**
 * TranscriptSink -- event sink contract for structured session output.
 *
 * Architecture note (bridges ControlCore output handling to the widget):
 *   In Windows Terminal, ControlCore owns the terminal connection and
 *   emits output events.  The shell/transcript layer above it reads those
 *   events and decides what to render.  TranscriptSink plays that role here:
 *   it defines the event shape contract, provides a concrete in-process event
 *   bus, and will later be the attachment point for streamed output work
 *   (the `stream-copilot-output` todo).
 *
 * Responsibilities:
 *   - Define all event types a live session can emit.
 *   - Provide TranscriptSink: a lightweight EventEmitter wrapper with
 *     typed emit/on helpers.
 *   - Provide createNullSink() for tests and ChildHosts that do not yet
 *     have a consumer attached.
 *
 * NOT responsible for:
 *   - Parsing raw terminal bytes into structured events (future work).
 *   - Writing to the widget DOM/PowerShell layer.
 *   - Process management.
 */

const { EventEmitter } = require('events');

// ---------------------------------------------------------------------------
// Event type registry
// ---------------------------------------------------------------------------

/**
 * All event types that a session may emit through its TranscriptSink.
 * Consumers subscribe by name; emitters call sink.emit(EVENT_TYPES.X, payload).
 */
const EVENT_TYPES = Object.freeze({
  /**
   * Raw stdout chunk from the session process.
   * Payload: { sessionId: string, chunk: string, timestamp: string }
   */
  RAW_STDOUT: 'raw:stdout',

  /**
   * Raw stderr chunk from the session process.
   * Payload: { sessionId: string, chunk: string, timestamp: string }
   */
  RAW_STDERR: 'raw:stderr',

  /**
   * Structured assistant response text (parsed from session output).
   * Payload: { sessionId: string, text: string, done: boolean, timestamp: string }
   * done=false while streaming, done=true on final chunk.
   */
  ASSISTANT_TEXT: 'transcript:assistant',

  /**
   * User message echoed back from the session.
   * Payload: { sessionId: string, text: string, timestamp: string }
   */
  USER_MESSAGE: 'transcript:user',

  /**
   * Agent "thinking" / reasoning text (if CLI exposes it).
   * Payload: { sessionId: string, text: string, timestamp: string }
   */
  THOUGHT: 'transcript:thought',

  /**
   * Tool invocation start event.
   * Payload: { sessionId: string, tool: string, input: unknown, timestamp: string }
   */
  TOOL_USE_START: 'tool:start',

  /**
   * Tool invocation result event.
   * Payload: { sessionId: string, tool: string, result: unknown, error: string|null, timestamp: string }
   */
  TOOL_USE_END: 'tool:end',

  /**
   * Raw structured Copilot JSON event parsed from the session output stream.
   * Payload: { sessionId: string, event: object, timestamp: string }
   */
  COPILOT_EVENT: 'copilot:event',

  /**
   * Session lifecycle: session has connected / is ready to accept input.
   * Payload: { sessionId: string, timestamp: string }
   */
  SESSION_READY: 'session:ready',

  /**
   * Session lifecycle: session has exited.
   * Payload: { sessionId: string, exitCode: number|null, signal: string|null, timestamp: string }
   */
  SESSION_EXIT: 'session:exit',

  /**
   * Session lifecycle: error that did not kill the session but should be surfaced.
   * Payload: { sessionId: string, message: string, timestamp: string }
   */
  SESSION_ERROR: 'session:error'
});

// ---------------------------------------------------------------------------
// Payload factories (ensure consistent shape across emitters)
// ---------------------------------------------------------------------------

function now() {
  return new Date().toISOString();
}

const payloads = {
  rawStdout(sessionId, chunk) {
    return { sessionId, chunk: String(chunk), timestamp: now() };
  },
  rawStderr(sessionId, chunk) {
    return { sessionId, chunk: String(chunk), timestamp: now() };
  },
  assistantText(sessionId, text, done = false) {
    return { sessionId, text: String(text), done: !!done, timestamp: now() };
  },
  userMessage(sessionId, text) {
    return { sessionId, text: String(text), timestamp: now() };
  },
  thought(sessionId, text) {
    return { sessionId, text: String(text), timestamp: now() };
  },
  toolUseStart(sessionId, tool, input) {
    return { sessionId, tool: String(tool), input: input !== undefined ? input : null, timestamp: now() };
  },
  toolUseEnd(sessionId, tool, result, error = null) {
    return {
      sessionId,
      tool: String(tool),
      result: result !== undefined ? result : null,
      error: error ? String(error) : null,
      timestamp: now()
    };
  },
  copilotEvent(sessionId, event) {
    return {
      sessionId,
      event,
      timestamp:
        event &&
        typeof event === 'object' &&
        typeof event.timestamp === 'string' &&
        event.timestamp.trim()
          ? event.timestamp
          : now()
    };
  },
  sessionReady(sessionId) {
    return { sessionId, timestamp: now() };
  },
  sessionExit(sessionId, exitCode, signal) {
    return {
      sessionId,
      exitCode: exitCode !== null && exitCode !== undefined ? exitCode : null,
      signal: signal ? String(signal) : null,
      timestamp: now()
    };
  },
  sessionError(sessionId, message) {
    return { sessionId, message: String(message), timestamp: now() };
  }
};

// ---------------------------------------------------------------------------
// TranscriptSink class
// ---------------------------------------------------------------------------

/**
 * TranscriptSink wraps an EventEmitter and adds typed emit helpers so
 * consumers never need to remember raw event-name strings.
 *
 * Usage (ChildHost side):
 *   const sink = new TranscriptSink(sessionId);
 *   sink.emitRawStdout(chunk);
 *   sink.emitSessionReady();
 *
 * Usage (widget/consumer side):
 *   sink.on(EVENT_TYPES.RAW_STDOUT, ({ chunk }) => appendToTranscript(chunk));
 *   sink.on(EVENT_TYPES.SESSION_EXIT, ({ exitCode }) => handleExit(exitCode));
 */
class TranscriptSink extends EventEmitter {
  /**
   * @param {string} sessionId  UUID that this sink is bound to.
   */
  constructor(sessionId) {
    super();
    if (typeof sessionId !== 'string' || !sessionId.trim()) {
      throw new TypeError('TranscriptSink: sessionId must be a non-empty string');
    }
    this.sessionId = sessionId;
    // Increase default listener ceiling for multi-consumer widget scenarios.
    this.setMaxListeners(20);
  }

  // -- Emit helpers --

  emitRawStdout(chunk) {
    this.emit(EVENT_TYPES.RAW_STDOUT, payloads.rawStdout(this.sessionId, chunk));
  }

  emitRawStderr(chunk) {
    this.emit(EVENT_TYPES.RAW_STDERR, payloads.rawStderr(this.sessionId, chunk));
  }

  emitAssistantText(text, done = false) {
    this.emit(EVENT_TYPES.ASSISTANT_TEXT, payloads.assistantText(this.sessionId, text, done));
  }

  emitUserMessage(text) {
    this.emit(EVENT_TYPES.USER_MESSAGE, payloads.userMessage(this.sessionId, text));
  }

  emitThought(text) {
    this.emit(EVENT_TYPES.THOUGHT, payloads.thought(this.sessionId, text));
  }

  emitToolUseStart(tool, input) {
    this.emit(EVENT_TYPES.TOOL_USE_START, payloads.toolUseStart(this.sessionId, tool, input));
  }

  emitToolUseEnd(tool, result, error = null) {
    this.emit(EVENT_TYPES.TOOL_USE_END, payloads.toolUseEnd(this.sessionId, tool, result, error));
  }

  emitCopilotEvent(event) {
    this.emit(EVENT_TYPES.COPILOT_EVENT, payloads.copilotEvent(this.sessionId, event));
  }

  emitSessionReady() {
    this.emit(EVENT_TYPES.SESSION_READY, payloads.sessionReady(this.sessionId));
  }

  emitSessionExit(exitCode, signal) {
    this.emit(EVENT_TYPES.SESSION_EXIT, payloads.sessionExit(this.sessionId, exitCode, signal));
  }

  emitSessionError(message) {
    this.emit(EVENT_TYPES.SESSION_ERROR, payloads.sessionError(this.sessionId, message));
  }

  // -- Subscribe helpers (typed aliases) --

  onRawStdout(handler) { return this.on(EVENT_TYPES.RAW_STDOUT, handler); }
  onRawStderr(handler) { return this.on(EVENT_TYPES.RAW_STDERR, handler); }
  onAssistantText(handler) { return this.on(EVENT_TYPES.ASSISTANT_TEXT, handler); }
  onUserMessage(handler) { return this.on(EVENT_TYPES.USER_MESSAGE, handler); }
  onThought(handler) { return this.on(EVENT_TYPES.THOUGHT, handler); }
  onToolUseStart(handler) { return this.on(EVENT_TYPES.TOOL_USE_START, handler); }
  onToolUseEnd(handler) { return this.on(EVENT_TYPES.TOOL_USE_END, handler); }
  onCopilotEvent(handler) { return this.on(EVENT_TYPES.COPILOT_EVENT, handler); }
  onSessionReady(handler) { return this.on(EVENT_TYPES.SESSION_READY, handler); }
  onSessionExit(handler) { return this.on(EVENT_TYPES.SESSION_EXIT, handler); }
  onSessionError(handler) { return this.on(EVENT_TYPES.SESSION_ERROR, handler); }
}

// ---------------------------------------------------------------------------
// Null sink (for tests / detached ChildHosts)
// ---------------------------------------------------------------------------

/**
 * Returns a sink that accepts all emits but does nothing.
 * Useful in unit tests and when a ChildHost is created before any consumer
 * is ready to subscribe.
 *
 * @param {string} sessionId
 * @returns {TranscriptSink}
 */
function createNullSink(sessionId) {
  const sink = new TranscriptSink(sessionId);
  // Remove the standard 'error' event special-casing so unhandled errors do
  // not crash the process when the null sink is used in tests.
  sink.on('error', () => {});
  return sink;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  EVENT_TYPES,
  payloads,
  TranscriptSink,
  createNullSink
};
