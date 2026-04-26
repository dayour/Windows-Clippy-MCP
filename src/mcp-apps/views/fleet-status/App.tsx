import { useEffect, useState } from "react";
import { useApp } from "@modelcontextprotocol/ext-apps/react";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

type FleetSnapshot = {
  schemaVersion?: string;
  principal?: string;
  sessionId?: string | null;
  tabs?: {
    total?: number;
    byState?: { idle?: number; running?: number; exited?: number };
    list?: Array<{
      tabKey?: string;
      sessionId?: string;
      displayName?: string;
      status?: string;
    }>;
  };
  groups?: {
    total?: number;
    active?: string | null;
    list?: Array<{
      label?: string;
      members?: Array<{
        tabKey?: string;
        sessionId?: string;
        displayName?: string;
      }>;
    }>;
  };
  agents?: {
    catalogSize?: number;
    active?: string | null;
    catalog?: Array<{
      id?: string;
      displayName?: string;
      filePath?: string;
      relativePath?: string;
      contentHash?: string;
      pathPatterns?: string[];
      source?: string;
      isActive?: boolean;
    }>;
  };
  adaptiveManifestProtocol?: {
    schemaVersion?: string;
    manifests?: AdaptiveManifest[];
  };
  events?: { recent?: unknown[] };
  capturedAt?: string | null;
  error?: string;
};

type AdaptiveManifest = {
  schemaVersion?: string;
  manifestType?: string;
  entityId?: string;
  source?: string;
  capturedAt?: string;
  state?: {
    lifecycle?: string;
    mode?: string;
    agentId?: string;
    modelId?: string;
    isBusy?: boolean;
    error?: string;
    latestPrompt?: string;
    latestReply?: string;
    latestToolSummary?: string;
  };
  card?: {
    cardId?: string;
    cardType?: string;
    defaultFace?: string;
    front?: FlipField[];
    back?: FlipField[];
  };
  refs?: Array<{ kind?: string; value?: string }>;
  attachments?: Array<{
    kind?: string;
    name?: string;
    relativePath?: string;
    contentHash?: string;
    pathPatterns?: string[];
  }>;
};

type FlipField = { label?: string; value?: string };

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
  const manifests = snapshot.adaptiveManifestProtocol?.manifests ?? [];
  const visibleManifests = prioritizeManifests(manifests).slice(0, 12);

  return (
    <>
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

      <section className="clippy-manifests" aria-label="adaptive manifest flipcards">
        <div className="clippy-section-title">
          <span>Adaptive manifest flipcards</span>
          <span>{snapshot.adaptiveManifestProtocol?.schemaVersion ?? "n/a"}</span>
        </div>
        {visibleManifests.length > 0 ? (
          <div className="clippy-flipgrid">
            {visibleManifests.map((manifest, index) => (
              <ManifestFlipCard
                key={`${manifest.manifestType ?? "manifest"}-${manifest.entityId ?? index}`}
                manifest={manifest}
              />
            ))}
          </div>
        ) : (
          <p className="clippy-fleet__placeholder">
            No adaptive manifests are available in this snapshot.
          </p>
        )}
      </section>
    </>
  );
}

function ManifestFlipCard({ manifest }: { manifest: AdaptiveManifest }) {
  const [face, setFace] = useState<"front" | "back">(
    manifest.card?.defaultFace === "back" ? "back" : "front",
  );
  const front = normalizeFields(manifest.card?.front);
  const back = buildBackFields(manifest);
  const fields = face === "front" ? front : back;
  const lifecycle = manifest.state?.lifecycle ?? "unknown";
  const title = manifest.manifestType ?? manifest.card?.cardType ?? "manifest";
  const entity = manifest.entityId ?? "unknown";

  return (
    <article className={`clippy-flipcard is-${face}`}>
      <header className="clippy-flipcard__header">
        <div>
          <div className="clippy-flipcard__type">{title}</div>
          <div className="clippy-flipcard__entity">{entity}</div>
        </div>
        <span className={`clippy-flipcard__state state-${normalizeClass(lifecycle)}`}>
          {lifecycle}
        </span>
      </header>

      <dl className="clippy-flipcard__fields">
        {fields.length > 0 ? (
          fields.slice(0, 8).map((field, index) => (
            <div className="clippy-flipcard__field" key={`${field.label}-${index}`}>
              <dt>{field.label}</dt>
              <dd title={field.value}>{field.value}</dd>
            </div>
          ))
        ) : (
          <div className="clippy-flipcard__field">
            <dt>State</dt>
            <dd>No fields published</dd>
          </div>
        )}
      </dl>

      <footer className="clippy-flipcard__footer">
        <button type="button" onClick={() => setFace(face === "front" ? "back" : "front")}>
          Show {face === "front" ? "schema" : "summary"}
        </button>
        <span>{manifest.schemaVersion ?? "adaptive-manifest/v1"}</span>
      </footer>
    </article>
  );
}

function prioritizeManifests(manifests: AdaptiveManifest[]): AdaptiveManifest[] {
  const weight = (manifest: AdaptiveManifest) => {
    switch (manifest.manifestType) {
      case "commander-session":
        return 0;
      case "terminal-session":
        return 1;
      case "agent-schema":
        return 2;
      default:
        return 3;
    }
  };
  return [...manifests].sort((a, b) => weight(a) - weight(b));
}

function normalizeFields(fields?: FlipField[]): Array<{ label: string; value: string }> {
  return (fields ?? [])
    .map((field) => ({
      label: String(field?.label ?? "").trim(),
      value: String(field?.value ?? "").trim(),
    }))
    .filter((field) => field.label.length > 0 && field.value.length > 0);
}

function buildBackFields(manifest: AdaptiveManifest): Array<{ label: string; value: string }> {
  const fields = normalizeFields(manifest.card?.back);
  for (const ref of manifest.refs ?? []) {
    if (ref?.kind && ref?.value) {
      fields.push({ label: `Ref ${ref.kind}`, value: ref.value });
    }
  }
  for (const attachment of manifest.attachments ?? []) {
    if (attachment?.relativePath) {
      fields.push({ label: `${attachment.kind ?? "attachment"} path`, value: attachment.relativePath });
    }
    if (attachment?.contentHash) {
      fields.push({ label: "Hash", value: attachment.contentHash.slice(0, 16) });
    }
    for (const [index, pattern] of (attachment?.pathPatterns ?? []).slice(0, 3).entries()) {
      fields.push({ label: `Pattern ${index + 1}`, value: pattern });
    }
  }
  return fields;
}

function normalizeClass(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9_-]+/g, "-");
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
    margin: 0 0 12px;
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
  .clippy-section-title {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    align-items: baseline;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #666;
    margin: 0 0 8px;
  }
  .clippy-flipgrid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }
  .clippy-flipcard {
    border: 1px solid rgba(127, 127, 127, 0.28);
    border-radius: 8px;
    padding: 8px;
    min-width: 0;
    background: rgba(127, 127, 127, 0.05);
  }
  .clippy-flipcard__header {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    align-items: flex-start;
    margin: 0 0 8px;
  }
  .clippy-flipcard__type {
    font-weight: 600;
    font-size: 12px;
    text-transform: capitalize;
  }
  .clippy-flipcard__entity {
    max-width: 180px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font: 10px/1.4 "Cascadia Code", Consolas, monospace;
    color: #666;
  }
  .clippy-flipcard__state {
    flex: 0 0 auto;
    font-size: 10px;
    border-radius: 999px;
    padding: 2px 6px;
    background: rgba(127, 127, 127, 0.15);
    color: inherit;
  }
  .clippy-flipcard__state.state-thinking,
  .clippy-flipcard__state.state-speaking {
    background: rgba(91, 95, 199, 0.18);
    color: #3b3fbd;
  }
  .clippy-flipcard__state.state-ready,
  .clippy-flipcard__state.state-active {
    background: rgba(38, 166, 91, 0.15);
    color: #0a7d3a;
  }
  .clippy-flipcard__state.state-error,
  .clippy-flipcard__state.state-faulted {
    background: rgba(216, 64, 64, 0.12);
    color: #8a1f1f;
  }
  .clippy-flipcard__fields {
    margin: 0;
    display: grid;
    gap: 5px;
  }
  .clippy-flipcard__field {
    min-width: 0;
  }
  .clippy-flipcard__field dt {
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #666;
  }
  .clippy-flipcard__field dd {
    margin: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 11px;
  }
  .clippy-flipcard__footer {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    align-items: center;
    margin: 8px 0 0;
    color: #666;
    font-size: 10px;
  }
  .clippy-flipcard__footer button {
    border: 1px solid rgba(127, 127, 127, 0.35);
    border-radius: 4px;
    background: transparent;
    color: inherit;
    font: inherit;
    padding: 3px 6px;
    cursor: pointer;
  }
  @media (prefers-color-scheme: dark) {
    .clippy-metric__label { color: #aaa; }
    .clippy-section-title { color: #aaa; }
    .clippy-flipcard__entity,
    .clippy-flipcard__field dt,
    .clippy-flipcard__footer { color: #aaa; }
    .clippy-fleet__placeholder { color: #aaa; }
    .clippy-fleet__status.is-connected { color: #6ad48a; }
    .clippy-fleet__status.is-pending { color: #f2c56a; }
    .clippy-fleet__warning { color: #ff9b9b; }
    .clippy-flipcard__state.state-thinking,
    .clippy-flipcard__state.state-speaking { color: #aaaefa; }
    .clippy-flipcard__state.state-ready,
    .clippy-flipcard__state.state-active { color: #6ad48a; }
    .clippy-flipcard__state.state-error,
    .clippy-flipcard__state.state-faulted { color: #ff9b9b; }
  }
`;
