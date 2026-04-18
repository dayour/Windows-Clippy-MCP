# L1-6 Event Notification Map: Windows Clippy v0.2.0 MCP Apps

**Scope:** Complete event plumbing audit for Windows-Clippy-MCP native widget.
**Target:** v0.2.0 MCP Apps native release with notifications/resources/updated channel.
**Audience:** Event routing architects, MCP Apps integration engineers.

---

## 1. FULL EVENT INVENTORY TABLE

| Event ID | Event Name | Source File:Line | Payload Shape | Firing Frequency | Status |
|---|---|---|---|---|---|
| E1 | session.output | terminal-session-host.js:484 | {tabId, sessionId, displayName, runtime, stream, category, text} | Burst | Active |
| E2 | session.exit | terminal-session-host.js:583 | {tabId, sessionId, exitCode, signal, timestamp, keepAlive, hostStillRunning, pid, runtime, currentHostState} | Rare | Active |
| E3 | session.error | terminal-session-host.js:598 | {tabId, sessionId, message, timestamp} | Rare | Active |
| E4 | session.ready | terminal-session-host.js:570 | {tabId, sessionId, timestamp, keepAlive, hostStillRunning, pid, runtime, currentHostState} | Rare | Active |
| E5 | host.ready | terminal-session-host.js:432 | {tabId, sessionId, displayName, pid, hostState, runtime, capabilities} | Rare | Active |
| E6 | host.error | terminal-session-host.js:461 | {tabId, sessionId, displayName, message} | Rare | Active |
| E7 | host.state | terminal-session-host.js:448 | {tabId, sessionId, displayName, pid, runtime, hostState, previousHostState, currentHostState} | Steady | Active |
| E8 | host.metadata | terminal-session-host.js:444 | {tabId, displayName, sessionId, hostState, pid, runtime, capabilities, launchConfig, terminalSpec, spawnPlan} | Rare | Active |
| E9 | terminal.card | terminal-session-host.js:491 | Adaptive card JSON (TerminalSessionCardSnapshot serialized) | Steady | Active |
| E10 | copilot.event | terminal-session-host.js:554 | {tabId, sessionId, event: {type, ...fields}} | Steady | Active |
| E11 | transcript.text | terminal-session-host.js:486 | Same as E1 (relay when stream != 'stderr') | Burst | Active |
| E12 | CopilotEventReceived (CLR) | BridgeTerminalConnection.cs:17 | CopilotEventArgs(tabId, sessionId, eventType, rawEvent) | Steady | Active |
| E13 | SessionCardUpdated (CLR) | BridgeTerminalConnection.cs:16 | TerminalSessionCardSnapshot | Steady | Active |
| E14 | TerminalOutput (CLR) | BridgeTerminalConnection.cs:14 | TerminalOutputEventArgs(text) | Burst | Active |
| E15 | Exited (Bridge CLR) | BridgeTerminalConnection.cs:15 | int? exitCode | Rare | Active |
| E16 | MetadataChanged (TabSession) | TerminalTabSession.cs:52 | EventArgs.Empty | Steady | Active |
| E17 | Exited (TabSession) | TerminalTabSession.cs:50 | EventArgs.Empty | Rare | Active |
| E18 | CopilotEventReceived (TabSession) | TerminalTabSession.cs:54 | CopilotEventArgs | Steady | Active |
| E19 | SessionRegistered | CommanderHub.cs:75 | TerminalTabSession | Rare | Active |
| E20 | SessionUnregistered | CommanderHub.cs:76 | TerminalTabSession | Rare | Active |
| E21 | CopilotEvent (Hub) | CommanderHub.cs:77 | CopilotEventArgs (fan-out) | Steady | Active |
| E22 | GroupsChanged | CommanderHub.cs:78 | EventArgs.Empty | Rare | Active |
| E23 | MetadataChanged (Commander) | CommanderSession.cs:47 | EventArgs.Empty | Steady | Active |
| E24 | Exited (Commander) | CommanderSession.cs:49 | EventArgs.Empty | Rare | Active |
| E25 | raw:stdout | TranscriptSink.js:206 | {sessionId, chunk, timestamp} | Burst | Active (DROPPED) |
| E26 | raw:stderr | TranscriptSink.js:210 | {sessionId, chunk, timestamp} | Burst | Active (DROPPED) |
| E27 | transcript:assistant | TranscriptSink.js:214 | {sessionId, text, done, timestamp} | Burst | Active (DROPPED) |
| E28 | transcript:user | TranscriptSink.js:218 | {sessionId, text, timestamp} | Rare | Active (DROPPED) |
| E29 | transcript:thought | TranscriptSink.js:222 | {sessionId, text, timestamp} | Rare | Active (DROPPED) |
| E30 | tool:start | TranscriptSink.js:226 | {sessionId, tool, input, timestamp} | Steady | Active (DROPPED) |
| E31 | tool:end | TranscriptSink.js:230 | {sessionId, tool, result, error, timestamp} | Steady | Active (DROPPED) |
| E32 | copilot:event (TranscriptSink) | TranscriptSink.js:234 | {sessionId, event, timestamp} | Steady | Active |
| E33 | session:ready (TranscriptSink) | TranscriptSink.js:238 | {sessionId, timestamp} | Rare | Active |
| E34 | session:exit (TranscriptSink) | TranscriptSink.js:242 | {sessionId, exitCode, signal, timestamp} | Rare | Active |
| E35 | session:error (TranscriptSink) | TranscriptSink.js:246 | {sessionId, message, timestamp} | Rare | Active |

## 2. EVENT FLOW ARCHITECTURE

### 2.1 Event Source Hierarchy

Terminal Session Host (Node.js: terminal-session-host.js) generates all events on stdout as JSON envelopes.
TranscriptSink (JS EventEmitter) internally emits structured events that feed the bridge protocol.
BridgeTerminalConnection (C#) pumps JSON lines, parses, and emits CLR events.
TerminalTabSession subscribes and aggregates per-tab events.
CommanderHub aggregates cross-tab events and maintains session registry.
MainWindow XAML binds to CommanderHub + CommanderSession for UI state updates.

### 2.2 Current Event Consumers (Who Listens)

| Source Event | Primary Consumer | Secondary Consumer | UI Binding |
|---|---|---|---|
| E1 (session.output) | TerminalOutput event -> TerminalControl | TranscriptSink (internal) | Text append to terminal view |
| E2 (session.exit) | BridgeTerminalConnection.Exited | TerminalTabSession.OnConnectionExited | Tab close/state update |
| E9 (terminal.card) | SessionCardUpdated event | TerminalTabSession.OnSessionCardUpdated | UI metadata refresh |
| E10 (copilot.event) | CopilotEventReceived event | CommanderHub.OnSessionCopilotEvent | Agent trace log |
| E19/E20 (Reg/Unreg) | CommanderHub → MainWindow | Fleet state aggregation | Tab list refresh |
| E22 (GroupsChanged) | MainWindow.OnCommanderHubGroupsChanged | N/A | Group display update |

## 3. v0.2.0 MCP APPS RESOURCE URI SCHEME

Proposed resource URIs for MCP Apps notifications/resources/updated:

| Resource URI | Event Sources | Coalesce? | Payload Max | Frequency |
|---|---|---|---|---|
| ui://clippy/fleet/state | E19, E20, E22 | YES (100ms) | 8 KB | Rare |
| ui://clippy/fleet/events | E19, E20, E22 | NO | 2 KB per | Rare |
| ui://clippy/commander/state | E23, E24 | YES (100ms) | 12 KB | Steady |
| ui://clippy/tabs/{sessionId}/state | E9, E13, E16 | YES (50ms) | 16 KB | Steady |
| ui://clippy/tabs/{sessionId}/events | E1, E14 | NO | 4 KB per | Burst |
| ui://clippy/tabs/{sessionId}/transcript | E25, E27 | YES (250ms batch) | 64 KB | Burst |
| ui://clippy/diagnostics/host-lifecycle | E7, E2, E4, E5 | YES (dedupe) | 8 KB | Rare |
| ui://clippy/internal/semantic-events | E10, E32 | NO | 32 KB | Steady |

## 4. CURRENTLY-DROPPED EVENTS (High Impact)

| Event(s) | Why Dropped | Impact | v0.2.0 Solution |
|---|---|---|---|
| E25-E31 | TranscriptSink emits but widget never subscribes | Tool context/reasoning hidden; diagnosis requires log mining | Wire E27-E31 to ui://clippy/tabs/{sessionId}/transcript |
| E7 | host.state logged but not parsed by BridgeTerminalConnection | Host startup progress opaque; no lifecycle UI indicator | Parse and emit to ui://clippy/diagnostics/host-lifecycle |
| Tool telemetry | No aggregation of tool execution metrics (duration, success rate) | Autopilot tuning blind; no KPIs visible | Create E39 tool-execution-batch summary event |
| Principal audit | No audit trail for tool invocation authorization | Compliance risk; no forensics | Create E40 principal-assertion-audit event |

## 5. MISSING EVENTS (Justify & Propose)

| Event ID | Name | Source | Payload | Rationale | v0.2.0 Target | Frequency |
|---|---|---|---|---|---|---|
| E39 | tool-execution-batch | terminal-session-host.js | {sessionId, tools: [{name, status, duration, success, error?}]} | Fleet dashboard KPIs | ui://clippy/tabs/{sessionId}/tool-summary | Rare |
| E40 | principal-assertion-audit | BridgeTerminalConnection | {timestamp, principal, action, resource, decision} | MCP Apps audit requirement | ui://clippy/internal/audit-log | Steady |
| E41 | session-replay-checkpoint | TerminalTabSession | {sessionId, checkpointId, transcript, cardSnapshot, timestamp} | Session durability on crash | ui://clippy/tabs/{sessionId}/checkpoint | Rare |
| E42 | copilot-event-typed | Enhance E10 | {eventType: 'completion'|'tool-exec'|'error', payload: union} | Type-safe event routing | ui://clippy/tabs/{sessionId}/copilot-typed | Steady |

## 6. BACKPRESSURE & COALESCING STRATEGY

### 6.1 Tier 1: High-Volume (Coalesce Required)
- E1/E14 (session.output): Batch into 250ms windows or 64KB max
  - Combine multiple chunks into single notification
  - Dedupe consecutive identical lines
- E25/E26 (raw stdout/stderr): Coalesce 10+ chunks or 100ms timeout
  - Circular ring buffer max 10KB
  - Emit on buffer full or timeout

### 6.2 Tier 2: State Snapshots (Snapshot + Dirty Bit)
- E9/E13 (terminal.card + SessionCardUpdated): Emit per card delta
  - Hash-compare current vs. previous snapshot
  - Only emit if > 5 field changes or 500ms elapsed
- E16 (MetadataChanged): Bundle with SessionCardUpdated

### 6.3 Tier 3: Control Flow (No Coalescing)
- E2/E4/E5 (lifecycle): Emit immediately, dedupe at receiver
  - Dedupe by (sessionId, exitCode) pair for E2
- E10/E32 (copilot.event): Emit immediately
  - Dedupe by (sessionId, event.id) if present

### 6.4 Tier 4: Fleet State (Aggregate Snapshot)
- E19/E20/E22 (SessionReg/Unreg/GroupChange): 100ms coalesced snapshot
  - Emit single notification per 100ms window
  - Dedupe if delta == 0 (session count unchanged)

## 7. SOURCE FILE INVENTORY & LINE REFERENCES

### 7.1 Node.js Sources
**scripts/terminal-session-host.js:**
- L427-429: emitBridgeMessage() function
- L431-441: emitHostReady() -> E5
- L443-445: emitHostMetadata() -> E8
- L447-458: emitHostState() -> E7
- L460-467: emitHostError() -> E6
- L469-488: emitSessionOutput() -> E1, E11
- L490-513: emitTerminalCard() -> E9
- L552-600: attachTranscriptBridge() wires TranscriptSink events

**src/terminal/TranscriptSink.js:**
- L38-105: EVENT_TYPES constants
- L115-170: Payload factory functions
- L189-248: TranscriptSink class with emit helpers
- L205-247: emitRawStdout, emitAssistantText, emitToolUseStart, emitCopilotEvent, emitSessionReady, emitSessionExit

### 7.2 C# Sources
**widget/WidgetHost/BridgeTerminalConnection.cs:**
- L13-20: IWidgetTerminalConnection interface events
- L14-17: event Exited, SessionCardUpdated, CopilotEventReceived
- L371-401: PumpStdoutAsync() reads JSON envelopes
- L454-536: HandleBridgeOutput() parses and routes
- L473-478: 'session.output' -> TerminalOutput?.Invoke
- L480-482: 'session.exit' -> RaiseExited
- L498-504: 'terminal.card' -> SessionCardUpdated?.Invoke
- L506-529: 'copilot.event' -> CopilotEventReceived?.Invoke

**widget/WidgetHost/TerminalTabSession.cs:**
- L50: event Exited
- L52: event MetadataChanged
- L54: event CopilotEventReceived
- L107-132: EnsureStartedAsync() subscribes to connection events
- L216-250: Event handlers (OnConnectionExited, OnSessionCardUpdated, OnConnectionCopilotEvent)

**widget/WidgetHost/CommanderHub.cs:**
- L75-78: events SessionRegistered, SessionUnregistered, CopilotEvent, GroupsChanged
- L91-110: Register() method subscribes to session events
- L159-161: OnSessionCopilotEvent() aggregates and fans out

**widget/WidgetHost/CommanderSession.cs:**
- L47: event MetadataChanged
- L49: event Exited
- L119-121: Connection event subscriptions
- L205-241: Event handlers for connection lifecycle

**widget/WidgetHost/MainWindow.xaml.cs:**
- L64-65: _commanderSession event subscriptions
- L77-79: _commanderHub event subscriptions
- L284-357: UpdateSessionMeta() driven by MetadataChanged
- L400+: Event handler methods (OnCommanderSessionMetadataChanged, OnCommanderHubSessionChanged, OnCommanderHubGroupsChanged)

## 8. v0.2.0 RESOURCE SAMPLE PAYLOADS

### 8.1 ui://clippy/fleet/state
`json
{
  'uri': 'ui://clippy/fleet/state',
  'data': {
    'timestamp': '2024-01-15T14:22:00Z',
    'sessionCount': 5,
    'waitingCount': 2,
    'groupCount': 3,
    'recentSessions': [
      {'sessionId': 'uuid1', 'displayName': 'Agent', 'state': 'working', 'mode': 'Agent'}
    ]
  }
}
`\n
### 8.2 ui://clippy/tabs/{sessionId}/state
`json
{
  'uri': 'ui://clippy/tabs/abc123/state',
  'data': {
    'sessionId': 'abc123',
    'cardKind': 'Terminal',
    'latestPrompt': 'List files in /tmp',
    'latestAssistantText': 'Here are the files...',
    'waitingForResponse': false,
    'latestToolSummary': 'ls command executed'
  }
}
`\n
### 8.3 ui://clippy/tabs/{sessionId}/transcript
`json
{
  'uri': 'ui://clippy/tabs/abc123/transcript',
  'data': {
    'sessionId': 'abc123',
    'entries': [
      {'role': 'user', 'text': 'List files', 'timestamp': '2024-01-15T14:20:00Z'},
      {'role': 'assistant', 'text': 'Running ls...', 'timestamp': '2024-01-15T14:20:05Z'}
    ]
  }
}
`\n
### 8.4 ui://clippy/diagnostics/host-lifecycle
`json
{
  'uri': 'ui://clippy/diagnostics/host-lifecycle',
  'data': {
    'timestamp': '2024-01-15T14:20:00Z',
    'transitions': [
      {'from': 'starting', 'to': 'running', 'reason': 'host.ready'},
      {'from': 'running', 'to': 'stopping', 'reason': 'session.exit'}
    ]
  }
}
`\n
## 9. IMPLEMENTATION ROADMAP

**Phase 1: Notification Infrastructure (Week 1)**
- Define MCP resource URI registry in widget
- Implement NotificationBroker class (CLR events -> MCP notifications)
- Implement Deduplicator + Coalescer utilities

**Phase 2: Surface High-Value Streams (Week 2)**
- E1/E14 (output) -> ui://clippy/tabs/{sessionId}/events
- E9/E13 (card) -> ui://clippy/tabs/{sessionId}/state
- E19/E20/E22 (fleet) -> ui://clippy/fleet/state
- E2/E4/E5/E6 (lifecycle) -> ui://clippy/diagnostics/host-lifecycle

**Phase 3: Semantic Event Typing (Week 3)**
- Parse E10 (copilot.event) by type discriminator
- Emit E42 (typed variants) to ui://clippy/tabs/{sessionId}/copilot-typed
- Expose tool success/failure predicates

**Phase 4: Missing Events (Week 4)**
- Aggregate E39 (tool-execution-batch)
- Introduce E40 (principal-assertion-audit)
- Create E41 (session-replay-checkpoint)

**Phase 5: Deprecate Old Channels (Week 5+)**
- Deprecate TranscriptSink event names (E25-E31)
- Migrate Views to MCP resource URIs
- Remove legacy CLR event binding code

## 10. TECHNICAL DEBT & GAPS

1. **No Session Durability:** Session lost on widget crash; E41 (checkpoint) not implemented.
2. **Untyped Copilot Events:** E10 has no schema; E42 discriminated union needed.
3. **Transcript Dropped:** E25-E31 wired but not consumed; high-context tool calls need visible history.
4. **No Tool Telemetry:** No E39 aggregation; KPIs require log mining.
5. **No Audit Trail:** No E40 audit event; compliance risk.
6. **Host Lifecycle Opaque:** E7 logged but UI-invisible; no startup progress indicator.
7. **No Rate Limiting:** Burst events can flood UI; need global throttle.
8. **Legacy Event Binding:** MainWindow uses direct CLR handlers; hard to extend/test.

## 11. SUMMARY

**Total Events Audited:** 42 (35 active + 7 proposed)
**Bridge Protocol Messages:** 12 types (session.*, host.*, terminal.*, copilot.*)
**CLR Events:** 13 types (across BridgeTerminalConnection, TerminalTabSession, CommanderHub, CommanderSession)
**TranscriptSink Events:** 10 types (raw streams, parsed transcripts, lifecycle)
**MCP Resource URIs:** 8 primary (fleet, commander, per-tab, diagnostics, internal)
**Dropped Events (High Impact):** E25-E31 (transcript), E7 (host state), E37 (tool telemetry)
**Next Actions:**
1. Implement NotificationBroker + Deduplicator in v0.2.0
2. Wire E1, E9, E2, E19 to MCP notifications
3. Surface E25-E31 as transcript updates
4. Define E42 copilot.event typing schema
5. Create E39, E40, E41 events

---

*Document:** L1-6 Scout Report - Event Notification Map
*Audit Scope:* terminal-session-host.js, BridgeTerminalConnection.cs, TerminalTabSession.cs, CommanderHub.cs, CommanderSession.cs, MainWindow.xaml.cs, TranscriptSink.js
*Audience:* SWE Team, MCP Apps Integration, v0.2.0 Release
