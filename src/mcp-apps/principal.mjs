/**
 * L3-6 — server-side principal enforcement.
 *
 * Every Windows Clippy MCP Apps tool call MUST carry
 *   _meta.clippy = { principal: "clippy", session: <string> }
 *
 * The widget host (McpAppsBridge.BuildToolCallParams) stamps this on every
 * outbound tools/call. External clients (Claude Desktop, VS Code, ChatGPT)
 * that want to drive Clippy tools must do the same.
 *
 * This module exposes `enforceClippyPrincipal(extra)` and `wrapToolWithPrincipal(handler)`.
 * Tool handlers call enforce on entry; the wrapper applies it transparently
 * so new tools can never silently regress.
 */
export const CLIPPY_PRINCIPAL = "clippy";
export const CLIPPY_META_KEY = "clippy";
export const PRINCIPAL_ERROR_CODE = "clippy.principal.rejected";

/**
 * Throws if the request does not assert Clippy as the principal.
 *
 * Accepts the `extra` argument passed to MCP SDK tool handlers
 * (RequestHandlerExtra with `_meta?: Record<string, unknown>`).
 *
 * @param {{ _meta?: Record<string, unknown> }} extra
 * @returns {{ principal: "clippy", session: string | null }} the asserted principal
 */
export function enforceClippyPrincipal(extra) {
  if (!extra || typeof extra !== "object") {
    throw buildPrincipalError("missing _meta.clippy assertion on tools/call");
  }
  if (!Object.prototype.hasOwnProperty.call(extra, "_meta")) {
    throw buildPrincipalError("missing _meta.clippy assertion on tools/call");
  }
  const meta = extra._meta;
  if (!meta || typeof meta !== "object") {
    throw buildPrincipalError("missing _meta.clippy assertion on tools/call");
  }
  if (!Object.prototype.hasOwnProperty.call(meta, CLIPPY_META_KEY)) {
    throw buildPrincipalError("missing _meta.clippy assertion on tools/call");
  }
  const clippy = meta[CLIPPY_META_KEY];

  if (!clippy || typeof clippy !== "object") {
    throw buildPrincipalError(
      "missing _meta.clippy assertion on tools/call",
    );
  }

  if (!Object.prototype.hasOwnProperty.call(clippy, "principal")) {
    throw buildPrincipalError(
      `principal must equal "clippy", received undefined`,
    );
  }
  const principal = clippy.principal;
  if (principal !== CLIPPY_PRINCIPAL) {
    throw buildPrincipalError(
      `principal must equal "clippy", received ${JSON.stringify(principal)}`,
    );
  }

  const rawSession = Object.prototype.hasOwnProperty.call(clippy, "session")
    ? clippy.session
    : undefined;
  const session =
    typeof rawSession === "string" && rawSession.length > 0 && rawSession.length <= 256
      ? rawSession
      : null;

  return { principal: CLIPPY_PRINCIPAL, session };
}

/**
 * Wrap a tool handler so the principal is asserted before the body runs.
 *
 * The MCP SDK dispatches tool callbacks as either `(args, extra)` (when the
 * tool declares an input schema) or `(extra)` (when it does not). This helper
 * handles both shapes by inspecting arity at call time.
 *
 * @template {(...args: any[]) => any} H
 * @param {H} handler
 * @returns {H}
 */
export function wrapToolWithPrincipal(handler) {
  return /** @type {H} */ (
    async function enforced(...args) {
      const extra = args.length >= 2 ? args[1] : args[0];
      enforceClippyPrincipal(extra);
      return handler.apply(this, args);
    }
  );
}

function buildPrincipalError(detail) {
  const err = new Error(
    `[${PRINCIPAL_ERROR_CODE}] Windows Clippy tool calls must assert the Clippy principal: ${detail}`,
  );
  err.code = PRINCIPAL_ERROR_CODE;
  return err;
}
