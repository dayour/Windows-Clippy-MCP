import { randomUUID } from "node:crypto";
import { appendFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { CLIPPY_PRINCIPAL } from "./principal.mjs";

export const COMMANDER_MODES = ["Agent", "Plan", "Swarm"];

const RESERVED_FIELDS = new Set(["id", "kind", "principal", "session", "enqueuedAt"]);

export function readClippySession(extra) {
  if (!extra || typeof extra !== "object") return null;
  const meta = extra._meta;
  if (!meta || typeof meta !== "object") return null;
  const clippy = meta.clippy;
  if (!clippy || typeof clippy !== "object") return null;
  const session = clippy.session;
  return typeof session === "string" && session.length > 0 && session.length <= 256
    ? session
    : null;
}

export function buildIntentEnvelope(kind, fields = {}, extra, { id, enqueuedAt } = {}) {
  const safeFields = {};
  if (fields && typeof fields === "object") {
    for (const [key, value] of Object.entries(fields)) {
      if (RESERVED_FIELDS.has(key)) continue;
      safeFields[key] = value;
    }
  }

  return {
    id: id ?? randomUUID(),
    kind,
    principal: CLIPPY_PRINCIPAL,
    session: readClippySession(extra),
    enqueuedAt: enqueuedAt ?? new Date().toISOString(),
    ...safeFields,
  };
}

export async function appendIntent(path, intent) {
  try {
    await mkdir(dirname(path), { recursive: true });
  } catch {
    /* dir exists or cannot be created; let appendFile surface the error below */
  }
  await appendFile(path, JSON.stringify(intent) + "\n", "utf8");
}
