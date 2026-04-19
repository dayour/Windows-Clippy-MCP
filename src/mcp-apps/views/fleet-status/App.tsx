import { useEffect, useState } from "react";
import { useApp } from "@modelcontextprotocol/ext-apps/react";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

type FleetSnapshot = {
  principal?: string;
  sessionId?: string | null;
  tabs?: {
    total?: number;
    byState?: { idle?: number; running?: number; exited?: number };
  };
  groups?: {
    total?: number;
    active?: string | null;
  };
  agents?: {
    catalogSize?: number;
    active?: string | null;
    catalog?: Array<{
      id?: string;
      displayName?: string;
      filePath?: string;
      source?: string;
      isActive?: boolean;
    }>;
  };
  events?: { recent?: unknown[] };
  capturedAt?: string | null;
  error?: string;
};

const APP_INFO = { name: "clippy.fleet-status", version: "0.2.0-alpha.1" };

export function App() {
  const [snapshot, setSnapshot] = useState<FleetSnapshot | null>(null);
  const [lastError, setLastError] = useState<string | null>(null);

  const { isConnected, error } = useApp({
    appInfo: APP_INFO,
    capabilities: {},
    onAppCreated: (app) => {
      app.ontoolresult = (params: CallToolResult) => {
        const structured = params?.structuredContent as
          | FleetSnapshot
          | undefined;
        if (structured) {
          setSnapshot(structured);
          setLastError(structured.error ?? null);
        }
      };
      app.onerror = (err: unknown) => {
        const message =
          err instanceof Error ? err.message : String(err ?? "unknown error");
        setLastError(message);
      };
    },
  });

  useEffect(() => {
    if (error) {
      setLastError(error.message);
    }
  }, [error]);

  return (
    <>
      <style>{STYLES}</style>
      <main className="clippy-fleet">
        <header className="clippy-fleet__header">
          <h1>Clippy Fleet Status</h1>
          <span
            className={
              "clippy-fleet__status" +
              (isConnected ? " is-connected" : " is-pending")
            }
          >
            {isConnected ? "connected" : "connecting"}
          </span>
        </header>

        {lastError ? (
          <div className="clippy-fleet__warning" role="alert">
            <strong>Warning:</strong> {lastError}
          </div>
        ) : null}

        {snapshot ? (
          <FleetBody snapshot={snapshot} />
        ) : (
          <p className="clippy-fleet__placeholder">
            Waiting for Commander snapshot. Call the clippy.fleet-status tool to
            populate the panel.
          </p>
        )}
      </main>
    </>
  );
}

function FleetBody({ snapshot }: { snapshot: FleetSnapshot }) {
  const tabsTotal = snapshot.tabs?.total ?? 0;
  const idle = snapshot.tabs?.byState?.idle ?? 0;
  const running = snapshot.tabs?.byState?.running ?? 0;
  const exited = snapshot.tabs?.byState?.exited ?? 0;
  const groupsTotal = snapshot.groups?.total ?? 0;
  const activeGroup = snapshot.groups?.active ?? "none";
  const catalogSize = snapshot.agents?.catalogSize ?? 0;
  const capturedAt = snapshot.capturedAt ?? null;

  return (
    <section className="clippy-fleet__grid" aria-label="fleet counters">
      <Metric label="Total tabs" value={tabsTotal} />
      <Metric label="Idle" value={idle} />
      <Metric label="Running" value={running} />
      <Metric label="Exited" value={exited} />
      <Metric label="Groups" value={groupsTotal} />
      <Metric label="Active group" value={String(activeGroup)} />
      <Metric label="Agent catalog" value={catalogSize} />
      <Metric
        label="Captured"
        value={capturedAt ? formatTimestamp(capturedAt) : "n/a"}
      />
    </section>
  );
}

function Metric({ label, value }: { label: string; value: number | string }) {
  return (
    <div className="clippy-metric">
      <div className="clippy-metric__value">{value}</div>
      <div className="clippy-metric__label">{label}</div>
    </div>
  );
}

function formatTimestamp(iso: string): string {
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleTimeString();
  } catch {
    return iso;
  }
}

const STYLES = `
  :root { color-scheme: light dark; }
  body { margin: 0; }
  .clippy-fleet {
    font: 13px/1.45 "Segoe UI", system-ui, -apple-system, sans-serif;
    color: var(--mcp-ui-color-foreground, #111);
    background: var(--mcp-ui-color-background, #fff);
    padding: 12px 14px;
    min-width: 260px;
  }
  .clippy-fleet__header {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
    margin: 0 0 10px;
  }
  .clippy-fleet__header h1 {
    font-size: 14px;
    font-weight: 600;
    margin: 0;
    letter-spacing: 0.01em;
  }
  .clippy-fleet__status {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 2px 6px;
    border-radius: 3px;
    background: rgba(127, 127, 127, 0.12);
    color: inherit;
  }
  .clippy-fleet__status.is-connected {
    background: rgba(38, 166, 91, 0.15);
    color: #0a7d3a;
  }
  .clippy-fleet__status.is-pending {
    background: rgba(235, 170, 50, 0.18);
    color: #8a5a00;
  }
  .clippy-fleet__warning {
    font-size: 11px;
    background: rgba(216, 64, 64, 0.10);
    border: 1px solid rgba(216, 64, 64, 0.35);
    color: #8a1f1f;
    padding: 6px 8px;
    border-radius: 3px;
    margin: 0 0 10px;
  }
  .clippy-fleet__placeholder {
    font-size: 12px;
    color: #666;
    margin: 0;
  }
  .clippy-fleet__grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
  }
  .clippy-metric {
    border: 1px solid rgba(127, 127, 127, 0.25);
    border-radius: 4px;
    padding: 6px 8px;
    min-width: 0;
  }
  .clippy-metric__value {
    font-size: 18px;
    font-weight: 600;
    line-height: 1.1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .clippy-metric__label {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
    margin-top: 2px;
  }
  @media (prefers-color-scheme: dark) {
    .clippy-metric__label { color: #aaa; }
    .clippy-fleet__placeholder { color: #aaa; }
    .clippy-fleet__status.is-connected { color: #6ad48a; }
    .clippy-fleet__status.is-pending { color: #f2c56a; }
    .clippy-fleet__warning { color: #ff9b9b; }
  }
`;
