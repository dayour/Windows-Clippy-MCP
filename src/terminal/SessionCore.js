#!/usr/bin/env node
'use strict';

/**
 * SessionCore -- PTY-level session configuration and spawn-parameter builder.
 *
 * Architecture note (mirrors Windows Terminal ControlCore.h):
 *   ControlCore encapsulates a Terminal instance, renderer, and
 *   ITerminalConnection without any regard for how the UX works. SessionCore
 *   does the same for Copilot CLI: it owns only the process invocation details
 *   and the stdio contract.  No widget, no UI, no tab concept lives here.
 *
 * Responsibilities:
 *   - Accept a SessionLaunchConfig and build the argv + environment block
 *     that a ChildHost will pass to child_process.spawn.
 *   - Provide helpers for assembling --resume, --config-dir, --agent, --model,
 *     tool/extension flags, and session metadata environment variables.
 *   - Validate the config before it reaches the spawner so ChildHost gets a
 *     clean invocation or a clear early error.
 *
 * NOT responsible for:
 *   - Spawning (that is ChildHost's job).
 *   - Tab metadata like display name or active/inactive state (SessionTab's job).
 *   - Transcript parsing or streaming (TranscriptSink's job).
 */

const os = require('os');
const path = require('path');
const { randomUUID } = require('crypto');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_COPILOT_EXECUTABLE = 'copilot';

/** Default config dir mirrors what clippy-session.js already uses. */
const DEFAULT_CONFIG_DIR = path.join(os.homedir(), '.copilot');

/**
 * Allowed mode values that map to the --mode flag recognised by the CLI.
 * Extend as new modes ship.
 */
const VALID_MODES = new Set(['agent', 'plan', 'swarm', 'ask']);

const TOOL_FLAG_ALIASES = Object.freeze({
  'allow-all-tools': '--allow-all-tools',
  allowAllTools: '--allow-all-tools',
  'allow-all-paths': '--allow-all-paths',
  allowAllPaths: '--allow-all-paths',
  'allow-all-urls': '--allow-all-urls',
  allowAllUrls: '--allow-all-urls',
  experimental: '--experimental',
  autopilot: '--autopilot',
  'enable-all-github-mcp-tools': '--enable-all-github-mcp-tools',
  enableAllGitHubMcpTools: '--enable-all-github-mcp-tools'
});

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

function isUuid(value) {
  return (
    typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  );
}

function assertString(value, label) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new TypeError(`SessionCore: ${label} must be a non-empty string`);
  }
}

function assertStringArray(value, label) {
  if (!Array.isArray(value) || !value.every((v) => typeof v === 'string')) {
    throw new TypeError(`SessionCore: ${label} must be an array of strings`);
  }
}

function normalizeMode(mode) {
  if (typeof mode !== 'string' || !mode.trim()) {
    return null;
  }

  const normalizedMode = mode.trim().toLowerCase();
  return VALID_MODES.has(normalizedMode) ? normalizedMode : null;
}

function normalizeToolFlag(toolName) {
  if (typeof toolName !== 'string' || !toolName.trim()) {
    return null;
  }

  const trimmed = toolName.trim();
  if (trimmed.startsWith('--')) {
    return trimmed;
  }

  if (TOOL_FLAG_ALIASES[trimmed]) {
    return TOOL_FLAG_ALIASES[trimmed];
  }

  throw new TypeError(`SessionCore: unsupported tool flag "${toolName}"`);
}

// ---------------------------------------------------------------------------
// SessionLaunchConfig (data-only struct, no behaviour)
// ---------------------------------------------------------------------------

/**
 * Creates a validated, normalised SessionLaunchConfig.
 *
 * Fields:
 *   sessionId  {string}   UUID that maps to --resume on the CLI.
 *   configDir  {string}   Path passed as --config-dir.
 *   agent      {string|null} Agent name (e.g. "dayour-swe").
 *   model      {string|null} Model hint (e.g. "gpt-5.4").
 *   mode       {string|null} Session mode metadata (not currently emitted as a CLI flag).
 *   tools      {string[]} List of additional tool names.
 *   extensions {string[]} List of VS Code extension IDs to activate.
 *   workingDirectory {string} Working directory passed to child_process.spawn.
 *   executable {string}   Copilot CLI executable name or path.
 *   extraFlags {string[]} Arbitrary extra flags appended verbatim.
 *
 * @param {Partial<SessionLaunchConfig>} options
 * @returns {SessionLaunchConfig}
 */
function createLaunchConfig(options = {}) {
  const sessionId = options.sessionId || randomUUID();
  if (!isUuid(sessionId)) {
    throw new TypeError(`SessionCore: sessionId must be a valid UUID, got: ${sessionId}`);
  }

  const configDir =
    typeof options.configDir === 'string' && options.configDir.trim()
      ? options.configDir.trim()
      : DEFAULT_CONFIG_DIR;

  const agent = typeof options.agent === 'string' && options.agent.trim() ? options.agent.trim() : null;
  const model = typeof options.model === 'string' && options.model.trim() ? options.model.trim() : null;
  const mode = normalizeMode(options.mode);

  const tools = Array.isArray(options.tools)
    ? options.tools
      .filter((t) => typeof t === 'string' && t.trim())
      .map((toolName) => normalizeToolFlag(toolName))
    : [];

  const extensions = Array.isArray(options.extensions)
    ? options.extensions.filter((e) => typeof e === 'string' && e.trim())
    : [];

  const executable =
    typeof options.executable === 'string' && options.executable.trim()
      ? options.executable.trim()
      : DEFAULT_COPILOT_EXECUTABLE;

  const workingDirectory =
    typeof options.workingDirectory === 'string' && options.workingDirectory.trim()
      ? path.resolve(options.workingDirectory.trim())
      : process.cwd();

  const extraFlags = Array.isArray(options.extraFlags)
    ? options.extraFlags.filter((f) => typeof f === 'string')
    : [];

  return Object.freeze({
    sessionId,
    configDir,
    agent,
    model,
    mode,
    tools,
    extensions,
    workingDirectory,
    executable,
    extraFlags
  });
}

// ---------------------------------------------------------------------------
// Argv builder
// ---------------------------------------------------------------------------

/**
 * Builds the shared argv array to pass to child_process.spawn for a Copilot
 * CLI session. Callers can prepend prompt-mode flags when they need a
 * resumable non-TTY run.
 *
 * @param {SessionLaunchConfig} config
 * @returns {{ argv: string[], env: Record<string,string> }}
 */
function buildSpawnArgs(config) {
  const argv = [];

  // Session resume ID -- always present so the session is addressable.
  argv.push(`--resume=${config.sessionId}`);

  // Config dir -- mirrors clippy-session.js convention.
  argv.push('--config-dir', config.configDir);

  // Force structured, transcript-friendly output for hidden widget sessions.
  argv.push('--output-format', 'json');
  argv.push('--no-color');
  argv.push('--no-alt-screen');

  // Agent selection.
  if (config.agent) {
    argv.push('--agent', config.agent);
  }

  // Model hint.
  if (config.model) {
    argv.push('--model', config.model);
  }

  for (const toolFlag of config.tools) {
    argv.push(toolFlag);
  }

  if (config.workingDirectory) {
    argv.push('--add-dir', config.workingDirectory);
  }

  // Extension activations -- CLI accepts repeated --extension flags.
  for (const ext of config.extensions) {
    argv.push('--extension', ext);
  }

  // Extra flags added verbatim (for future use by terminal-launch-real-session).
  argv.push(...config.extraFlags);

  // Environment block -- inherit the parent process environment and inject
  // any session-specific overrides here.  Nothing sensitive; this is the
  // place to add things like COPILOT_SESSION_ID in future.
  const env = Object.assign({}, process.env, {
    CLIPPY_SESSION_ID: config.sessionId,
    CLIPPY_SESSION_MODE: config.mode || '',
    CLIPPY_WORKING_DIRECTORY: config.workingDirectory
  });

  return { argv, env };
}

/**
 * Builds the argv array for a single resumable prompt-mode run. This is the
 * transport used by the widget host because Copilot streams JSONL correctly in
 * prompt mode over redirected pipes, while hidden interactive stdio sessions do
 * not.
 *
 * @param {SessionLaunchConfig} config
 * @param {string} prompt
 * @param {{ stream?: boolean }} [options]
 * @returns {{ argv: string[], env: Record<string,string> }}
 */
function buildPromptSpawnArgs(config, prompt, options = {}) {
  assertString(prompt, 'prompt');

  const { argv, env } = buildSpawnArgs(config);
  const streamMode = options.stream === false ? 'off' : 'on';

  return {
    argv: ['-p', prompt, ...argv, '--stream', streamMode],
    env
  };
}

/**
 * Describes a fully-resolved spawn plan.  ChildHost consumes this directly.
 *
 * @typedef {Object} SpawnPlan
 * @property {string}   executable  -- Copilot CLI binary name or path.
 * @property {string[]} argv        -- Argument list (no executable prepended).
 * @property {Record<string,string>} env  -- Full environment block.
 * @property {string}   sessionId   -- UUID echoed from config for convenience.
 * @property {string}   cwd         -- Working directory for child spawn.
 */

/**
 * Produces the complete SpawnPlan from a SessionLaunchConfig.
 *
 * @param {SessionLaunchConfig} config
 * @returns {SpawnPlan}
 */
function resolveSpawnPlan(config) {
  const { argv, env } = buildSpawnArgs(config);
  return Object.freeze({
    executable: config.executable,
    argv,
    env,
    sessionId: config.sessionId,
    cwd: config.workingDirectory
  });
}

/**
 * Produces the complete SpawnPlan for a single resumable prompt-mode run.
 *
 * @param {SessionLaunchConfig} config
 * @param {string} prompt
 * @param {{ stream?: boolean }} [options]
 * @returns {SpawnPlan & { prompt: string }}
 */
function resolvePromptSpawnPlan(config, prompt, options = {}) {
  const { argv, env } = buildPromptSpawnArgs(config, prompt, options);
  return Object.freeze({
    executable: config.executable,
    argv,
    env,
    sessionId: config.sessionId,
    cwd: config.workingDirectory,
    prompt
  });
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  DEFAULT_COPILOT_EXECUTABLE,
  DEFAULT_CONFIG_DIR,
  TOOL_FLAG_ALIASES,
  VALID_MODES,
  createLaunchConfig,
  buildSpawnArgs,
  buildPromptSpawnArgs,
  resolveSpawnPlan,
  resolvePromptSpawnPlan,
  isUuid,
  normalizeMode
};
