import { FormEvent, useEffect, useRef, useState } from "react";
import { useApp } from "@modelcontextprotocol/ext-apps/react";

const APP_INFO = { name: "clippy.commander", version: "0.2.0-alpha.1" };
const COMMANDER_MODES = ["Agent", "Plan", "Swarm"] as const;
const HISTORY_LIMIT = 24;

type CommanderMode = (typeof COMMANDER_MODES)[number];

type CommanderHistoryEntry = {
  role?: string;
  text?: string;
  content?: string;
  timestamp?: string | null;
};

type CommanderState = {
  sessionId?: string | null;
  displayName?: string | null;
  model?: string | null;
  agent?: string | null;
  mode?: string | null;
  isReady?: boolean;
  isBusy?: boolean;
  latestPrompt?: string;
  latestReply?: string;
  latestToolSummary?: string;
  lastError?: string;
  historyCount?: number;
  history?: CommanderHistoryEntry[];
  capturedAt?: string | null;
};

type CommanderSubmitAck = {
  accepted?: boolean;
  intentId?: string;
  intentsPath?: string;
};

type ToolResultLike = {
  toolName?: string;
  structuredContent?: unknown;
  content?: Array<{ type?: string; text?: string }>;
  isError?: boolean;
};

export function App() {
  const [snapshot, setSnapshot] = useState<CommanderState | null>(null);
  const [submitAck, setSubmitAck] = useState<CommanderSubmitAck | null>(null);
  const [mode, setMode] = useState<CommanderMode>("Agent");
  const [prompt, setPrompt] = useState("");
  const [lastError, setLastError] = useState<string | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [hasLoadedSnapshot, setHasLoadedSnapshot] = useState(false);
  const initialLoadDoneRef = useRef(false);

  const { app, isConnected, error } = useApp({
    appInfo: APP_INFO,
    capabilities: {},
    onAppCreated: (createdApp) => {
      createdApp.ontoolresult = (params) => {
        applyToolResult(params as ToolResultLike);
      };
      createdApp.onerror = (err: unknown) => {
        setLastError(getErrorMessage(err));
      };
    },
  });

  useEffect(() => {
    if (error) {
      setLastError(error.message);
    }
  }, [error]);

  useEffect(() => {
    if (!app || !isConnected || initialLoadDoneRef.current) {
      return;
    }
    initialLoadDoneRef.current = true;
    void refreshState(app, {
      setIsRefreshing,
      setHasLoadedSnapshot,
      setLastError,
      setSnapshot,
      setMode,
    });
  }, [app, isConnected]);

  const displayName = snapshot?.displayName?.trim() || "Clippy Commander";
  const history = Array.isArray(snapshot?.history) ? snapshot.history : [];
  const latestReply = snapshot?.latestReply?.trim() || "";
  const latestPrompt = snapshot?.latestPrompt?.trim() || "";
  const canSubmit = Boolean(app && isConnected && prompt.trim() && !isSubmitting);
  const statusLabel = buildStatusLabel(snapshot);

  async function handleRefresh() {
    if (!app) {
      return;
    }
    await refreshState(app, {
      setIsRefreshing,
      setHasLoadedSnapshot,
      setLastError,
      setSnapshot,
      setMode,
    });
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!app || !canSubmit) {
      return;
    }

    setIsSubmitting(true);
    setLastError(null);

    try {
      const result = await app.callServerTool({
        name: "clippy.commander.submit",
        arguments: {
          prompt: prompt.trim(),
          mode,
        },
      });

      if (result.isError) {
        setLastError(extractToolMessage(result));
        return;
      }

      const ack = normalizeSubmitAck(result.structuredContent);
      if (!ack.accepted) {
        setLastError(extractToolMessage(result) || "Commander submit was not accepted.");
        return;
      }

      setSubmitAck(ack);
      setPrompt("");
      await handleRefresh();
    } catch (err) {
      setLastError(getErrorMessage(err));
    } finally {
      setIsSubmitting(false);
    }
  }

  function applyToolResult(result: ToolResultLike) {
    const toolName = result.toolName;

    if (result.isError) {
      setLastError(extractToolMessage(result) || "Tool call failed.");
      return;
    }

    if (toolName === "clippy.commander.submit") {
      const ack = normalizeSubmitAck(result.structuredContent);
      if (ack.accepted) {
        setSubmitAck(ack);
        setLastError(null);
      }
      return;
    }

    const nextSnapshot = normalizeCommanderState(result.structuredContent);
    if (!nextSnapshot) {
      return;
    }

    setSnapshot(nextSnapshot);
    setHasLoadedSnapshot(true);
    setLastError(nextSnapshot.lastError?.trim() || null);

    const nextMode = nextSnapshot.mode;
    if (isCommanderMode(nextMode)) {
      setMode(nextMode);
    }
  }

  return (
    <>
      <style>{STYLES}</style>
      <main className="clippy-commander">
        <header className="clippy-commander__header">
          <div>
            <p className="clippy-commander__eyebrow">MCP App view</p>
            <h1>{displayName}</h1>
            <p className="clippy-commander__subtitle">
              Connected to the Commander state and submit tools through the app bridge.
            </p>
          </div>
          <div className="clippy-commander__header-status">
            <span
              className={
                "clippy-commander__status " +
                (isConnected ? "is-connected" : "is-pending")
              }
            >
              {isConnected ? "connected" : "connecting"}
            </span>
            <span
              className={
                "clippy-commander__status-badge " +
                (snapshot?.isBusy ? "is-busy" : snapshot?.isReady ? "is-ready" : "is-idle")
              }
            >
              {statusLabel}
            </span>
          </div>
        </header>

        {lastError ? (
          <section className="clippy-commander__banner is-error" role="alert">
            <strong>Error:</strong> {lastError}
          </section>
        ) : null}

        {submitAck?.accepted ? (
          <section className="clippy-commander__banner is-info" aria-label="queued intent">
            <strong>Queued intent:</strong> {submitAck.intentId ?? "unknown"}
          </section>
        ) : null}

        <section className="clippy-commander__grid" aria-label="commander summary">
          <Metric label="Mode" value={snapshot?.mode ?? mode} />
          <Metric label="Agent" value={snapshot?.agent ?? "n/a"} />
          <Metric label="Model" value={snapshot?.model ?? "n/a"} />
          <Metric label="Session" value={snapshot?.sessionId ?? "n/a"} />
          <Metric
            label="History"
            value={String(snapshot?.historyCount ?? history.length)}
          />
          <Metric
            label="Captured"
            value={snapshot?.capturedAt ? formatTimestamp(snapshot.capturedAt) : "n/a"}
          />
        </section>

        <section className="clippy-commander__panel">
          <div className="clippy-commander__panel-header">
            <h2>Latest exchange</h2>
            <button
              type="button"
              className="clippy-commander__secondary-button"
              onClick={() => void handleRefresh()}
              disabled={!app || isRefreshing || isSubmitting}
            >
              {isRefreshing ? "Refreshing..." : "Refresh"}
            </button>
          </div>

          <div className="clippy-commander__exchange">
            <section>
              <h3>Prompt</h3>
              <p>{latestPrompt || "No prompt captured yet."}</p>
            </section>
            <section>
              <h3>Reply</h3>
              <p>{latestReply || "No reply captured yet."}</p>
              {snapshot?.latestToolSummary ? (
                <p className="clippy-commander__tool-summary">
                  Tool summary: {snapshot.latestToolSummary}
                </p>
              ) : null}
            </section>
          </div>
        </section>

        <section className="clippy-commander__panel">
          <h2>Transcript</h2>
          {history.length ? (
            <ol className="clippy-commander__history">
              {history.map((entry, index) => (
                <li key={`${entry.role ?? "turn"}-${index}`} className="clippy-commander__history-item">
                  <div className="clippy-commander__history-meta">
                    <span className="clippy-commander__history-role">
                      {entry.role ?? "turn"}
                    </span>
                    {entry.timestamp ? (
                      <time dateTime={entry.timestamp}>{formatTimestamp(entry.timestamp)}</time>
                    ) : null}
                  </div>
                  <p>{entry.text?.trim() || entry.content?.trim() || "(empty turn)"}</p>
                </li>
              ))}
            </ol>
          ) : (
            <p className="clippy-commander__empty">
              {hasLoadedSnapshot
                ? "No transcript entries yet."
                : "Waiting for clippy.commander.state to provide transcript history."}
            </p>
          )}
        </section>

        <section className="clippy-commander__panel">
          <h2>Send a prompt</h2>
          <form className="clippy-commander__composer" onSubmit={handleSubmit}>
            <label className="clippy-commander__field">
              <span>Mode</span>
              <select
                value={mode}
                onChange={(event) => {
                  const nextMode = event.target.value;
                  if (isCommanderMode(nextMode)) {
                    setMode(nextMode);
                  }
                }}
                disabled={!app || isSubmitting}
              >
                {COMMANDER_MODES.map((candidate) => (
                  <option key={candidate} value={candidate}>
                    {candidate}
                  </option>
                ))}
              </select>
            </label>

            <label className="clippy-commander__field">
              <span>Prompt</span>
              <textarea
                value={prompt}
                onChange={(event) => setPrompt(event.target.value)}
                placeholder="Ask Commander to plan work, execute an agent task, or coordinate the swarm."
                rows={5}
                disabled={!app || isSubmitting}
              />
            </label>

            <div className="clippy-commander__composer-actions">
              <p className="clippy-commander__hint">
                Submits via <code>clippy.commander.submit</code> only.
              </p>
              <button type="submit" disabled={!canSubmit}>
                {isSubmitting ? "Submitting..." : "Submit prompt"}
              </button>
            </div>
          </form>
        </section>
      </main>
    </>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="clippy-metric">
      <div className="clippy-metric__value" title={value}>
        {value}
      </div>
      <div className="clippy-metric__label">{label}</div>
    </div>
  );
}

function normalizeCommanderState(value: unknown): CommanderState | null {
  if (!value || typeof value !== "object") {
    return null;
  }

  const snapshot = value as CommanderState;
  return {
    ...snapshot,
    history: Array.isArray(snapshot.history) ? snapshot.history : [],
    historyCount: Array.isArray(snapshot.history)
      ? snapshot.history.length
      : Number(snapshot.historyCount ?? 0),
  };
}

function normalizeSubmitAck(value: unknown): CommanderSubmitAck {
  if (!value || typeof value !== "object") {
    return {};
  }
  return value as CommanderSubmitAck;
}

async function refreshState(
  app: NonNullable<ReturnType<typeof useApp>["app"]>,
  handlers: {
    setIsRefreshing: (value: boolean) => void;
    setHasLoadedSnapshot: (value: boolean) => void;
    setLastError: (value: string | null) => void;
    setSnapshot: (value: CommanderState | null) => void;
    setMode: (value: CommanderMode) => void;
  },
) {
  const {
    setIsRefreshing,
    setHasLoadedSnapshot,
    setLastError,
    setSnapshot,
    setMode,
  } = handlers;

  setIsRefreshing(true);

  try {
    const result = await app.callServerTool({
      name: "clippy.commander.state",
      arguments: { historyLimit: HISTORY_LIMIT },
    });

    if (result.isError) {
      setLastError(extractToolMessage(result) || "Unable to load commander state.");
      return;
    }

    const nextSnapshot = normalizeCommanderState(result.structuredContent);
    setSnapshot(nextSnapshot);
    setHasLoadedSnapshot(true);
    setLastError(nextSnapshot?.lastError?.trim() || null);

    const nextMode = nextSnapshot?.mode;
    if (isCommanderMode(nextMode)) {
      setMode(nextMode);
    }
  } catch (err) {
    setLastError(getErrorMessage(err));
  } finally {
    setIsRefreshing(false);
  }
}

function extractToolMessage(result: ToolResultLike): string {
  if (!Array.isArray(result.content)) {
    return "";
  }
  return result.content
    .filter((item) => item?.type === "text" && typeof item.text === "string")
    .map((item) => item.text?.trim() || "")
    .filter(Boolean)
    .join("\n");
}

function buildStatusLabel(snapshot: CommanderState | null): string {
  if (!snapshot) {
    return "Waiting for state";
  }
  if (snapshot.isBusy) {
    return "Busy";
  }
  if (snapshot.isReady) {
    return "Ready";
  }
  return "Idle";
}

function formatTimestamp(iso: string): string {
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) {
      return iso;
    }
    return d.toLocaleString();
  } catch {
    return iso;
  }
}

function getErrorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err ?? "unknown error");
}

function isCommanderMode(value: unknown): value is CommanderMode {
  return typeof value === "string" && COMMANDER_MODES.includes(value as CommanderMode);
}

const STYLES = `
  :root { color-scheme: light dark; }
  body { margin: 0; }
  code { font-family: Consolas, "SFMono-Regular", monospace; }
  button, input, select, textarea {
    font: inherit;
    color: inherit;
  }
  .clippy-commander {
    font: 13px/1.45 "Segoe UI", system-ui, -apple-system, sans-serif;
    color: var(--mcp-ui-color-foreground, #111);
    background: var(--mcp-ui-color-background, #fff);
    padding: 14px;
    min-width: 340px;
  }
  .clippy-commander__header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 12px;
    margin-bottom: 12px;
  }
  .clippy-commander__eyebrow {
    margin: 0 0 2px;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #666;
  }
  .clippy-commander__header h1,
  .clippy-commander__panel h2,
  .clippy-commander__exchange h3 {
    margin: 0;
  }
  .clippy-commander__header h1 {
    font-size: 15px;
    font-weight: 600;
  }
  .clippy-commander__subtitle {
    margin: 4px 0 0;
    color: #666;
    max-width: 520px;
  }
  .clippy-commander__header-status {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 6px;
  }
  .clippy-commander__status,
  .clippy-commander__status-badge {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 3px 8px;
    border-radius: 999px;
    white-space: nowrap;
  }
  .clippy-commander__status {
    background: rgba(127, 127, 127, 0.12);
  }
  .clippy-commander__status.is-connected {
    background: rgba(38, 166, 91, 0.15);
    color: #0a7d3a;
  }
  .clippy-commander__status.is-pending {
    background: rgba(235, 170, 50, 0.18);
    color: #8a5a00;
  }
  .clippy-commander__status-badge {
    background: rgba(127, 127, 127, 0.12);
  }
  .clippy-commander__status-badge.is-ready {
    background: rgba(38, 166, 91, 0.12);
    color: #0a7d3a;
  }
  .clippy-commander__status-badge.is-busy {
    background: rgba(46, 107, 255, 0.12);
    color: #1f5bd7;
  }
  .clippy-commander__status-badge.is-idle {
    background: rgba(127, 127, 127, 0.12);
    color: #666;
  }
  .clippy-commander__banner,
  .clippy-commander__panel {
    border: 1px solid rgba(127, 127, 127, 0.25);
    border-radius: 8px;
    padding: 10px 12px;
    margin-bottom: 12px;
  }
  .clippy-commander__banner.is-error {
    background: rgba(216, 64, 64, 0.10);
    border-color: rgba(216, 64, 64, 0.35);
    color: #8a1f1f;
  }
  .clippy-commander__banner.is-info {
    background: rgba(46, 107, 255, 0.08);
    border-color: rgba(46, 107, 255, 0.20);
  }
  .clippy-commander__grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 8px;
    margin-bottom: 12px;
  }
  .clippy-metric {
    border: 1px solid rgba(127, 127, 127, 0.25);
    border-radius: 8px;
    padding: 8px 10px;
    min-width: 0;
  }
  .clippy-metric__value {
    font-size: 15px;
    font-weight: 600;
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .clippy-metric__label {
    font-size: 10px;
    margin-top: 3px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
  }
  .clippy-commander__panel-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    margin-bottom: 10px;
  }
  .clippy-commander__secondary-button,
  .clippy-commander__composer button {
    border: 1px solid rgba(127, 127, 127, 0.35);
    border-radius: 6px;
    background: transparent;
    padding: 6px 10px;
    cursor: pointer;
  }
  .clippy-commander__composer button {
    background: rgba(46, 107, 255, 0.10);
    border-color: rgba(46, 107, 255, 0.35);
  }
  .clippy-commander__secondary-button:disabled,
  .clippy-commander__composer button:disabled {
    cursor: default;
    opacity: 0.6;
  }
  .clippy-commander__exchange {
    display: grid;
    gap: 12px;
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .clippy-commander__exchange h3 {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
    margin-bottom: 6px;
  }
  .clippy-commander__exchange p,
  .clippy-commander__history-item p,
  .clippy-commander__hint,
  .clippy-commander__empty {
    margin: 0;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .clippy-commander__tool-summary {
    margin-top: 8px;
    color: #666;
    font-size: 12px;
  }
  .clippy-commander__history {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    gap: 10px;
  }
  .clippy-commander__history-item {
    border: 1px solid rgba(127, 127, 127, 0.18);
    border-radius: 8px;
    padding: 10px;
  }
  .clippy-commander__history-meta {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 6px;
    font-size: 11px;
    color: #666;
  }
  .clippy-commander__history-role {
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-weight: 600;
  }
  .clippy-commander__composer {
    display: grid;
    gap: 12px;
  }
  .clippy-commander__field {
    display: grid;
    gap: 6px;
  }
  .clippy-commander__field span {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
  }
  .clippy-commander__field select,
  .clippy-commander__field textarea {
    width: 100%;
    box-sizing: border-box;
    border: 1px solid rgba(127, 127, 127, 0.35);
    border-radius: 8px;
    padding: 8px 10px;
    background: transparent;
  }
  .clippy-commander__field textarea {
    resize: vertical;
    min-height: 120px;
  }
  .clippy-commander__composer-actions {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
  }
  .clippy-commander__hint {
    color: #666;
    font-size: 12px;
  }
  @media (max-width: 720px) {
    .clippy-commander__grid,
    .clippy-commander__exchange {
      grid-template-columns: 1fr;
    }
    .clippy-commander__header,
    .clippy-commander__composer-actions {
      flex-direction: column;
      align-items: stretch;
    }
    .clippy-commander__header-status {
      align-items: flex-start;
    }
  }
  @media (prefers-color-scheme: dark) {
    .clippy-commander__eyebrow,
    .clippy-commander__subtitle,
    .clippy-metric__label,
    .clippy-commander__exchange h3,
    .clippy-commander__tool-summary,
    .clippy-commander__history-meta,
    .clippy-commander__field span,
    .clippy-commander__hint,
    .clippy-commander__empty {
      color: #aaa;
    }
    .clippy-commander__status.is-connected,
    .clippy-commander__status-badge.is-ready {
      color: #6ad48a;
    }
    .clippy-commander__status.is-pending {
      color: #f2c56a;
    }
    .clippy-commander__status-badge.is-busy {
      color: #8db2ff;
    }
    .clippy-commander__status-badge.is-idle {
      color: #aaa;
    }
    .clippy-commander__banner.is-error {
      color: #ff9b9b;
    }
  }
`;
