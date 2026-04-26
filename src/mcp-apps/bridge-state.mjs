/**
 * bridge-state — Fleet snapshot provider for the MCP Apps server (L2-5).
 *
 * L2 goal: basic-host and reference clients can render live-looking fleet
 * data without requiring the widget to be running. The state source is
 * pluggable so L3 can swap in the real CommanderHub bridge without
 * changing tool handlers or views.
 *
 * Source resolution order:
 *   1. Explicit constructor arg: new FleetState({ source })
 *   2. CLIPPY_FLEET_STATE_PATH env var -> JSON file on disk (widget will
 *      keep this file up to date while running; Apps server reads lazily)
 *   3. Deterministic zero-fleet default (no sessions, no tabs)
 *
 * Snapshot shape is the single source of truth for fleet-status.mjs and
 * every View that consumes fleet data. Keep it stable or version-bump it.
 */

import { readFile } from "node:fs/promises";
import { statSync } from "node:fs";

const DEFAULT_SNAPSHOT = Object.freeze({
  schemaVersion: "fleet-state/v1",
  principal: "clippy",
  sessionId: null,
  tabs: {
    total: 0,
    byState: { idle: 0, running: 0, exited: 0 },
    list: [],
  },
  groups: {
    total: 0,
    active: null,
    list: [],
  },
  agents: {
    catalogSize: 0,
    active: null,
    catalog: [],
  },
  events: {
    recent: [],
  },
  adaptiveManifestProtocol: {
    schemaVersion: "adaptive-manifest/v1",
    manifests: [],
  },
});

export class FleetState {
  constructor({ source, path, env = process.env } = {}) {
    this._source = source || null;
    this._path = path || env.CLIPPY_FLEET_STATE_PATH || null;
    this._lastReadMtime = 0;
    this._cachedSnapshot = null;
  }

  async snapshot({ includeEvents = false } = {}) {
    let snap = DEFAULT_SNAPSHOT;
    try {
      if (this._source) {
        const fromSrc = await this._source();
        snap = this._merge(fromSrc);
      } else if (this._path) {
        snap = await this._readFromPath();
      }
    } catch (err) {
      return {
        ...DEFAULT_SNAPSHOT,
        error: `state source failed: ${err?.message || String(err)}`,
      };
    }
    if (!includeEvents) {
      snap = { ...snap, events: { recent: [] } };
    }
    return snap;
  }

  async _readFromPath() {
    let mtime = 0;
    try {
      mtime = statSync(this._path).mtimeMs;
    } catch (err) {
      if (err?.code === "ENOENT") return DEFAULT_SNAPSHOT;
      throw err;
    }
    if (this._cachedSnapshot && mtime === this._lastReadMtime) {
      return this._cachedSnapshot;
    }
    const raw = await readFile(this._path, "utf-8");
    const parsed = JSON.parse(raw);
    this._cachedSnapshot = this._merge(parsed);
    this._lastReadMtime = mtime;
    return this._cachedSnapshot;
  }

  _merge(partial) {
    if (!partial || typeof partial !== "object") return DEFAULT_SNAPSHOT;
    // L3-FW-1: harden pass-through merge against hostile input from the
    // widget bridge or an external state file. See
    // docs/mcp-apps/tactician/l3-webview2-integration.md for the threat
    // model. Rules:
    //   - principal is never user-configurable; always coerced to "clippy".
    //   - tabs.list / groups.list / events.recent are clamped.
    //   - Prototype-pollution keys are stripped from every merged object.
    //   - Free-form string fields are capped to MAX_STRING.
    const tabList = Array.isArray(partial.tabs?.list)
      ? partial.tabs.list.slice(0, MAX_TABS).map((v) => safeShallow(v))
      : [];
    const groupList = Array.isArray(partial.groups?.list)
      ? partial.groups.list.slice(0, MAX_GROUPS).map((v) => safeShallow(v))
      : [];
    const recentEvents = Array.isArray(partial.events?.recent)
      ? partial.events.recent.slice(0, MAX_EVENTS).map((v) => safeShallow(v))
      : [];
    const agentCatalog = normalizeAgentCatalog(partial.agents);
    const commanderSlice = safeShallow(partial.commander);
    return {
      principal: "clippy",
      schemaVersion: safeString(partial.schemaVersion) ?? "fleet-state/v1",
      sessionId: safeString(partial.sessionId),
      tabs: {
        total: num(partial.tabs?.total),
        byState: {
          idle: num(partial.tabs?.byState?.idle),
          running: num(partial.tabs?.byState?.running),
          exited: num(partial.tabs?.byState?.exited),
        },
        list: tabList,
      },
      groups: {
        total: num(partial.groups?.total),
        active: safeString(partial.groups?.active),
        list: groupList,
      },
      agents: {
        catalogSize: num(partial.agents?.catalogSize) || agentCatalog.length,
        active: safeString(partial.agents?.active),
        catalog: agentCatalog,
      },
      commander: commanderSlice && typeof commanderSlice === "object" ? commanderSlice : null,
      events: {
        recent: recentEvents,
      },
      adaptiveManifestProtocol: normalizeAdaptiveManifestProtocol(
        partial.adaptiveManifestProtocol,
      ),
    };
  }
}

function num(x) {
  const n = Number(x);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
}

const MAX_TABS = 256;
const MAX_GROUPS = 64;
const MAX_EVENTS = 20;
const MAX_AGENTS = 500;
const MAX_STRING = 1024;
const MAX_RECURSION = 6;
const DANGEROUS_KEYS = new Set(["__proto__", "constructor", "prototype"]);

function safeString(v) {
  if (v === null || v === undefined) return null;
  if (typeof v !== "string") return null;
  return v.length > MAX_STRING ? v.slice(0, MAX_STRING) : v;
}

function safeShallow(obj, depth = 0) {
  if (obj === null || obj === undefined) return obj;
  if (typeof obj === "string") {
    return obj.length > MAX_STRING ? obj.slice(0, MAX_STRING) : obj;
  }
  if (typeof obj !== "object") return obj;
  if (depth >= MAX_RECURSION) return null;
  if (Array.isArray(obj)) {
    return obj.slice(0, MAX_TABS).map((v) => safeShallow(v, depth + 1));
  }
  const out = {};
  for (const key of Object.keys(obj)) {
    if (DANGEROUS_KEYS.has(key)) continue;
    out[key] = safeShallow(obj[key], depth + 1);
  }
  return out;
}

function normalizeAgentCatalog(agentsSlice) {
  const raw = Array.isArray(agentsSlice?.catalog)
    ? agentsSlice.catalog
    : Array.isArray(agentsSlice?.list)
      ? agentsSlice.list
      : [];
  const active = safeString(agentsSlice?.active);
  return raw
    .slice(0, MAX_AGENTS)
    .map((entry) => normalizeAgentEntry(entry, active))
    .filter(Boolean);
}

function normalizeAgentEntry(entry, activeAgentId) {
  if (typeof entry === "string") {
    const id = safeString(entry);
    if (!id) return null;
    return {
      id,
      displayName: id,
      filePath: "",
      source: "unknown",
      isActive: activeAgentId === id,
    };
  }
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    return null;
  }

  const id = safeString(entry.id) ?? safeString(entry.agentId);
  if (!id) return null;

  const source = safeString(entry.source);
  const normalizedSource =
    source === "user" || source === "bundled" ? source : "unknown";
  const isActive =
    entry.isActive === true || (activeAgentId !== null && activeAgentId === id);

  const out = {
    id,
    displayName: safeString(entry.displayName) ?? id,
    filePath: safeString(entry.filePath) ?? "",
    source: normalizedSource,
    isActive,
  };

  const relativePath = safeString(entry.relativePath);
  if (relativePath) out.relativePath = relativePath;

  const contentHash = safeString(entry.contentHash);
  if (contentHash) out.contentHash = contentHash;

  if (Array.isArray(entry.pathPatterns)) {
    const pathPatterns = entry.pathPatterns.slice(0, 16).map(safeString).filter(Boolean);
    if (pathPatterns.length > 0) out.pathPatterns = pathPatterns;
  }

  return out;
}

function normalizeAdaptiveManifestProtocol(slice) {
  const manifests = Array.isArray(slice?.manifests)
    ? slice.manifests.slice(0, MAX_TABS + MAX_AGENTS + 1).map((v) => safeShallow(v))
    : [];
  return {
    schemaVersion:
      safeString(slice?.schemaVersion) ?? DEFAULT_SNAPSHOT.adaptiveManifestProtocol.schemaVersion,
    manifests: manifests.filter(Boolean),
  };
}

export { DEFAULT_SNAPSHOT, MAX_TABS, MAX_GROUPS, MAX_EVENTS, MAX_AGENTS };
