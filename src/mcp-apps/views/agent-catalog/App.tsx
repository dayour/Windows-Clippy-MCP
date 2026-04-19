import { useEffect, useMemo, useState } from "react";
import { useApp } from "@modelcontextprotocol/ext-apps/react";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

type AgentRecord = {
  id: string;
  displayName: string;
  filePath: string;
  source: "bundled" | "user" | "unknown";
  isActive: boolean;
};

type AgentCatalogPayload = {
  active?: string | null;
  catalogSize?: number;
  returned?: number;
  agents?: AgentRecord[];
  capturedAt?: string | null;
  error?: string | null;
};

const APP_INFO = { name: "clippy.agent-catalog", version: "0.2.0-alpha.1" };

export function App() {
  const [payload, setPayload] = useState<AgentCatalogPayload | null>(null);
  const [lastError, setLastError] = useState<string | null>(null);
  const [search, setSearch] = useState("");

  const { isConnected, error } = useApp({
    appInfo: APP_INFO,
    capabilities: {},
    onAppCreated: (app) => {
      app.ontoolresult = (params: CallToolResult) => {
        const structured = params?.structuredContent as
          | AgentCatalogPayload
          | undefined;
        if (structured) {
          setPayload(normalizePayload(structured));
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

  const agents = useMemo(
    () => sortAgents(Array.isArray(payload?.agents) ? payload.agents : []),
    [payload],
  );
  const activeAgent = useMemo(
    () =>
      agents.find((agent) => agent.isActive) ??
      (payload?.active
        ? agents.find((agent) => agent.id === payload.active)
        : undefined) ??
      null,
    [agents, payload],
  );
  const visibleAgents = useMemo(
    () => filterAgents(agents, search),
    [agents, search],
  );
  const summaryLine = payload
    ? `Showing ${visibleAgents.length} of ${payload.catalogSize ?? agents.length} agents`
    : "Waiting for catalog data";

  return (
    <>
      <style>{STYLES}</style>
      <main className="clippy-catalog">
        <header className="clippy-catalog__header">
          <div>
            <h1>Clippy Agent Catalog</h1>
            <p className="clippy-catalog__subtitle">
              {summaryLine}
            </p>
          </div>
          <span
            className={
              "clippy-catalog__status" +
              (isConnected ? " is-connected" : " is-pending")
            }
          >
            {isConnected ? "connected" : "connecting"}
          </span>
        </header>

        {lastError ? (
          <div className="clippy-catalog__warning" role="alert">
            <strong>Warning:</strong> {lastError}
          </div>
        ) : null}

        {payload ? (
          <>
            <section className="clippy-catalog__grid" aria-label="catalog summary">
              <Metric
                label="Active"
                value={activeAgent?.displayName ?? payload.active ?? "none"}
              />
              <Metric label="Catalog size" value={String(payload.catalogSize ?? 0)} />
              <Metric label="Visible" value={String(visibleAgents.length)} />
              <Metric
                label="Captured"
                value={payload.capturedAt ? formatTimestamp(payload.capturedAt) : "n/a"}
              />
            </section>

            <section className="clippy-catalog__panel">
              <div className="clippy-catalog__panel-header">
                <div>
                  <h2>Agents</h2>
                  <p className="clippy-catalog__panel-copy">
                    Search by name, id, source, or file path.
                  </p>
                </div>
                <label className="clippy-catalog__search">
                  <span className="clippy-catalog__search-label">Filter</span>
                  <input
                    type="search"
                    value={search}
                    onChange={(event) => setSearch(event.currentTarget.value)}
                    placeholder="Search agents"
                    aria-label="Search agents"
                  />
                </label>
              </div>

              {activeAgent ? (
                <section className="clippy-catalog__active" aria-label="active agent">
                  <div className="clippy-catalog__active-label">Active agent</div>
                  <div className="clippy-catalog__active-name">
                    {activeAgent.displayName}
                  </div>
                  <div className="clippy-catalog__active-meta">
                    <code>{activeAgent.id}</code>
                    <span>{labelForSource(activeAgent.source)}</span>
                  </div>
                </section>
              ) : null}

              {agents.length ? (
                visibleAgents.length ? (
                <ul className="clippy-catalog__list">
                  {visibleAgents.map((agent, index) => {
                    const isActive = agent.isActive || payload.active === agent.id;
                    return (
                      <li
                        key={`${agent.id}-${index}`}
                        className={"clippy-catalog__item" + (isActive ? " is-active" : "")}
                      >
                        <div className="clippy-catalog__item-header">
                          <div className="clippy-catalog__identity">
                            <strong>{agent.displayName}</strong>
                            <code>{agent.id}</code>
                          </div>
                          <div className="clippy-catalog__badges">
                            {isActive ? (
                              <span className="clippy-catalog__badge is-active">
                                active
                              </span>
                            ) : null}
                            <span className="clippy-catalog__badge">
                              {labelForSource(agent.source)}
                            </span>
                          </div>
                        </div>
                        <dl className="clippy-catalog__meta">
                          <div>
                            <dt>Display name</dt>
                            <dd>{agent.displayName}</dd>
                          </div>
                          <div>
                            <dt>Id</dt>
                            <dd>
                              <code>{agent.id}</code>
                            </dd>
                          </div>
                          <div>
                            <dt>Source</dt>
                            <dd>{labelForSource(agent.source)}</dd>
                          </div>
                          <div className="is-wide">
                            <dt>File path</dt>
                            <dd>
                              {agent.filePath ? (
                                <code>{agent.filePath}</code>
                              ) : (
                                <span className="clippy-catalog__missing">
                                  Not reported
                                </span>
                              )}
                            </dd>
                          </div>
                        </dl>
                      </li>
                    );
                  })}
                </ul>
                ) : (
                  <div className="clippy-catalog__empty">
                    <strong>No matching agents.</strong>
                    <p>Adjust the filter to see more catalog entries.</p>
                  </div>
                )
              ) : (
                <div className="clippy-catalog__empty">
                  <strong>No agents returned yet.</strong>
                  <p>Call <code>clippy.agent-catalog</code> to populate this panel.</p>
                </div>
              )}
            </section>
          </>
        ) : (
          <p className="clippy-catalog__placeholder">
            Call <code>clippy.agent-catalog</code> to populate this panel.
          </p>
        )}
      </main>
    </>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="clippy-metric">
      <div className="clippy-metric__value">{value}</div>
      <div className="clippy-metric__label">{label}</div>
    </div>
  );
}

function normalizePayload(payload: AgentCatalogPayload): AgentCatalogPayload {
  const agents = Array.isArray(payload.agents)
    ? payload.agents.map(normalizeAgent).filter(Boolean)
    : [];
  return {
    active: asText(payload.active),
    catalogSize:
      typeof payload.catalogSize === "number" ? payload.catalogSize : agents.length,
    returned: typeof payload.returned === "number" ? payload.returned : agents.length,
    agents,
    capturedAt: asText(payload.capturedAt),
    error: asText(payload.error),
  };
}

function normalizeAgent(agent: AgentRecord | Record<string, unknown>) {
  const id = asText(agent.id);
  if (!id) return null;
  const source = normalizeSource(agent.source);
  return {
    id,
    displayName: asText(agent.displayName) ?? id,
    filePath: asText(agent.filePath) ?? "",
    source,
    isActive: agent.isActive === true,
  } satisfies AgentRecord;
}

function filterAgents(agents: AgentRecord[], search: string) {
  const query = search.trim().toLowerCase();
  if (!query) return agents;
  return agents.filter((agent) =>
    `${agent.displayName} ${agent.id} ${agent.source} ${agent.filePath}`
      .toLowerCase()
      .includes(query),
  );
}

function sortAgents(agents: AgentRecord[]) {
  return [...agents].sort((left, right) => {
    if (left.isActive !== right.isActive) {
      return left.isActive ? -1 : 1;
    }
    return left.displayName.localeCompare(right.displayName);
  });
}

function labelForSource(source: AgentRecord["source"]) {
  if (source === "bundled") return "Bundled";
  if (source === "user") return "User";
  return "Unknown";
}

function normalizeSource(value: unknown): AgentRecord["source"] {
  return value === "bundled" || value === "user" ? value : "unknown";
}

function asText(value: unknown): string | null {
  return typeof value === "string" && value ? value : null;
}

function formatTimestamp(iso: string) {
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleString();
  } catch {
    return iso;
  }
}

const STYLES = `
  :root { color-scheme: light dark; }
  body { margin: 0; }
  code { font-family: Consolas, "SFMono-Regular", monospace; }
  .clippy-catalog {
    font: 13px/1.45 "Segoe UI", system-ui, -apple-system, sans-serif;
    color: var(--mcp-ui-color-foreground, #111);
    background: var(--mcp-ui-color-background, #fff);
    padding: 12px 14px;
    min-width: 320px;
  }
  .clippy-catalog__header {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 10px;
  }
  .clippy-catalog__header h1,
  .clippy-catalog__panel h2 {
    margin: 0;
  }
  .clippy-catalog__header h1 {
    font-size: 14px;
    font-weight: 600;
  }
  .clippy-catalog__subtitle {
    margin: 4px 0 0;
    font-size: 11px;
    color: #666;
  }
  .clippy-catalog__status {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 2px 6px;
    border-radius: 3px;
    background: rgba(127, 127, 127, 0.12);
    height: fit-content;
  }
  .clippy-catalog__status.is-connected {
    background: rgba(38, 166, 91, 0.15);
    color: #0a7d3a;
  }
  .clippy-catalog__status.is-pending {
    background: rgba(235, 170, 50, 0.18);
    color: #8a5a00;
  }
  .clippy-catalog__warning,
  .clippy-catalog__panel {
    border-radius: 4px;
    padding: 8px 10px;
    margin-bottom: 10px;
    border: 1px solid rgba(127, 127, 127, 0.25);
  }
  .clippy-catalog__warning {
    background: rgba(216, 64, 64, 0.10);
    border-color: rgba(216, 64, 64, 0.35);
    color: #8a1f1f;
  }
  .clippy-catalog__placeholder {
    margin: 0;
    color: #666;
  }
  .clippy-catalog__grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
    margin-bottom: 10px;
  }
  .clippy-metric {
    border: 1px solid rgba(127, 127, 127, 0.25);
    border-radius: 4px;
    padding: 6px 8px;
    min-width: 0;
  }
  .clippy-metric__value {
    font-size: 16px;
    font-weight: 600;
    line-height: 1.15;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .clippy-metric__label {
    font-size: 10px;
    margin-top: 2px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
  }
  .clippy-catalog__panel h2 {
    font-size: 12px;
  }
  .clippy-catalog__panel-header {
    display: flex;
    justify-content: space-between;
    align-items: end;
    gap: 12px;
    margin-bottom: 10px;
  }
  .clippy-catalog__panel-copy {
    margin: 4px 0 0;
    font-size: 11px;
    color: #666;
  }
  .clippy-catalog__search {
    display: grid;
    gap: 4px;
    min-width: 180px;
  }
  .clippy-catalog__search-label {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
  }
  .clippy-catalog__search input {
    font: inherit;
    color: inherit;
    background: transparent;
    border: 1px solid rgba(127, 127, 127, 0.35);
    border-radius: 4px;
    padding: 6px 8px;
    min-width: 0;
  }
  .clippy-catalog__active {
    border: 1px solid rgba(46, 107, 255, 0.28);
    background: rgba(46, 107, 255, 0.06);
    border-radius: 4px;
    padding: 8px;
    margin-bottom: 10px;
  }
  .clippy-catalog__active-label {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
  }
  .clippy-catalog__active-name {
    font-size: 15px;
    font-weight: 600;
    margin-top: 2px;
  }
  .clippy-catalog__active-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 6px;
    color: #666;
  }
  .clippy-catalog__list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    gap: 8px;
  }
  .clippy-catalog__item {
    border: 1px solid rgba(127, 127, 127, 0.25);
    border-radius: 4px;
    padding: 8px;
  }
  .clippy-catalog__item.is-active {
    border-color: rgba(46, 107, 255, 0.55);
    background: rgba(46, 107, 255, 0.06);
  }
  .clippy-catalog__item-header {
    display: flex;
    justify-content: space-between;
    align-items: start;
    gap: 10px;
    margin-bottom: 8px;
  }
  .clippy-catalog__identity {
    min-width: 0;
  }
  .clippy-catalog__identity strong,
  .clippy-catalog__identity code {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .clippy-catalog__identity code {
    margin-top: 2px;
  }
  .clippy-catalog__badges {
    display: flex;
    flex-wrap: wrap;
    justify-content: end;
    gap: 6px;
  }
  .clippy-catalog__badge {
    border-radius: 999px;
    padding: 2px 8px;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    background: rgba(127, 127, 127, 0.12);
  }
  .clippy-catalog__badge.is-active {
    background: rgba(46, 107, 255, 0.16);
    color: #2259d1;
  }
  .clippy-catalog__meta {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
    margin: 0;
  }
  .clippy-catalog__meta div {
    min-width: 0;
  }
  .clippy-catalog__meta .is-wide {
    grid-column: 1 / -1;
  }
  .clippy-catalog__meta dt {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
    margin: 0 0 3px;
  }
  .clippy-catalog__meta dd {
    margin: 0;
    word-break: break-word;
  }
  .clippy-catalog__missing {
    color: #666;
  }
  .clippy-catalog__empty {
    border: 1px dashed rgba(127, 127, 127, 0.35);
    border-radius: 4px;
    padding: 12px 10px;
  }
  .clippy-catalog__empty strong,
  .clippy-catalog__empty p {
    margin: 0;
  }
  .clippy-catalog__empty p {
    margin-top: 4px;
    color: #666;
  }
  @media (max-width: 560px) {
    .clippy-catalog__panel-header,
    .clippy-catalog__item-header {
      grid-template-columns: none;
      flex-direction: column;
      align-items: stretch;
    }
    .clippy-catalog__search {
      min-width: 0;
    }
    .clippy-catalog__badges {
      justify-content: start;
    }
    .clippy-catalog__meta {
      grid-template-columns: minmax(0, 1fr);
    }
  }
  @media (prefers-color-scheme: dark) {
    .clippy-catalog__subtitle,
    .clippy-catalog__placeholder,
    .clippy-metric__label,
    .clippy-catalog__panel-copy,
    .clippy-catalog__search-label,
    .clippy-catalog__active-label,
    .clippy-catalog__active-meta,
    .clippy-catalog__meta dt,
    .clippy-catalog__missing,
    .clippy-catalog__empty p {
      color: #aaa;
    }
    .clippy-catalog__status.is-connected { color: #6ad48a; }
    .clippy-catalog__status.is-pending { color: #f2c56a; }
    .clippy-catalog__warning { color: #ff9b9b; }
    .clippy-catalog__badge.is-active { color: #8eb2ff; }
  }
`;
