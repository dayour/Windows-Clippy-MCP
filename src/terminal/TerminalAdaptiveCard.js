'use strict';

const ADAPTIVE_CARD_SCHEMA_URL = 'http://adaptivecards.io/schemas/adaptive-card.json';
const ADAPTIVE_CARD_VERSION = '1.2';
const TERMINAL_CARD_TEMPLATE_VERSION = '1.0.0';
const TERMINAL_CARD_TEMPLATE_PATH = 'widget/adaptive-cards/terminal-session.template.json';
const TERMINAL_CARD_DATA_SCHEMA_PATH = 'widget/adaptive-cards/terminal-session.data.schema.json';

const MAX_PROMPT_PREVIEW = 240;
const MAX_TRANSCRIPT_PREVIEW = 360;
const MAX_TOOL_PREVIEW = 140;
const MAX_FACT_VALUE = 84;
const MAX_RECENT_TOOLS = 4;

const TOOL_FLAG_LABELS = Object.freeze({
  '--allow-all-tools': 'All tools',
  '--allow-all-paths': 'All paths',
  '--allow-all-urls': 'All URLs',
  '--experimental': 'Experimental',
  '--autopilot': 'Autopilot',
  '--enable-all-github-mcp-tools': 'All GitHub MCP tools'
});

function now() {
  return new Date().toISOString();
}

function normalizeText(value) {
  if (typeof value !== 'string') {
    return '';
  }

  return value
    .replace(/\r/g, '')
    .replace(/\u0000/g, '')
    .trim();
}

function normalizeWhitespace(value) {
  return normalizeText(value)
    .split('\n')
    .map((line) => line.replace(/[ \t]+/g, ' ').trimEnd())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function truncateText(value, maxLength) {
  const normalized = normalizeWhitespace(value);
  if (!normalized) {
    return '';
  }

  if (normalized.length <= maxLength) {
    return normalized;
  }

  return `${normalized.slice(0, Math.max(0, maxLength - 3)).trimEnd()}...`;
}

function appendPreview(existing, addition, maxLength = MAX_TRANSCRIPT_PREVIEW) {
  const normalizedAddition = normalizeWhitespace(addition);
  if (!normalizedAddition) {
    return existing || '';
  }

  const combined = existing ? `${existing}\n${normalizedAddition}` : normalizedAddition;
  return truncateText(combined, maxLength);
}

function formatPreviewValue(value, maxLength = MAX_TOOL_PREVIEW) {
  if (value === null || value === undefined) {
    return '';
  }

  if (typeof value === 'string') {
    return truncateText(value, maxLength);
  }

  try {
    return truncateText(JSON.stringify(value), maxLength);
  } catch {
    return truncateText(String(value), maxLength);
  }
}

function toTitleCase(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return '';
  }

  return normalized
    .split(/[_\-\s]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function summarizeToolFlags(flags) {
  const normalizedFlags = Array.isArray(flags)
    ? flags.map((flag) => normalizeText(flag)).filter(Boolean)
    : [];

  if (normalizedFlags.length === 0) {
    return 'Default approvals';
  }

  return normalizedFlags
    .map((flag) => TOOL_FLAG_LABELS[flag] || flag.replace(/^--/, ''))
    .join(', ');
}

function summarizeExtraFlags(flags) {
  const normalizedFlags = Array.isArray(flags)
    ? flags.map((flag) => normalizeText(flag)).filter(Boolean)
    : [];

  if (normalizedFlags.length === 0) {
    return 'None';
  }

  return truncateText(normalizedFlags.join(' '), MAX_FACT_VALUE);
}

function createToolRecord(toolName, overrides = {}) {
  const normalizedToolName = normalizeText(toolName) || 'tool';
  const status = overrides.status || 'running';

  return {
    id: overrides.id || normalizedToolName,
    name: normalizedToolName,
    status,
    statusLabel: status === 'failed' ? 'Failed' : status === 'succeeded' ? 'Succeeded' : 'Running',
    inputPreview: overrides.inputPreview || '',
    resultPreview: overrides.resultPreview || '',
    errorPreview: overrides.errorPreview || '',
    startedAt: overrides.startedAt || now(),
    endedAt: overrides.endedAt || null
  };
}

function upsertToolRecord(runtime, record) {
  const existing = runtime.recentTools.filter((tool) => tool.id !== record.id);
  runtime.recentTools = [record, ...existing].slice(0, MAX_RECENT_TOOLS);
}

function createTerminalCardRuntime() {
  return {
    userPromptPreview: '',
    assistantPreview: '',
    thoughtPreview: '',
    plainTextPreview: '',
    recentTools: [],
    waitingForResponse: false,
    lastError: '',
    lastUpdatedAt: now(),
    lastExitCode: null,
    lastSignal: null,
    hadStructuredAssistantOutput: false
  };
}

function beginTerminalCardTurn(runtime, promptText) {
  runtime.userPromptPreview = truncateText(promptText, MAX_PROMPT_PREVIEW);
  runtime.assistantPreview = '';
  runtime.thoughtPreview = '';
  runtime.plainTextPreview = '';
  runtime.recentTools = [];
  runtime.waitingForResponse = true;
  runtime.lastError = '';
  runtime.lastExitCode = null;
  runtime.lastSignal = null;
  runtime.hadStructuredAssistantOutput = false;
  runtime.lastUpdatedAt = now();
}

function applyTerminalCardCopilotEvent(runtime, event) {
  if (!runtime || !event || typeof event !== 'object' || typeof event.type !== 'string') {
    return false;
  }

  const eventType = normalizeText(event.type);
  const data = event.data && typeof event.data === 'object' ? event.data : {};

  switch (eventType) {
    case 'user.message':
      if (typeof data.content === 'string' && data.content.trim()) {
        beginTerminalCardTurn(runtime, data.content);
        return true;
      }
      return false;

    case 'assistant.reasoning_delta': {
      const delta = typeof data.deltaContent === 'string' ? data.deltaContent : '';
      if (!delta) {
        return false;
      }

      runtime.thoughtPreview = appendPreview(runtime.thoughtPreview, delta);
      runtime.lastUpdatedAt = now();
      return true;
    }

    case 'assistant.reasoning': {
      const content = typeof data.content === 'string' ? data.content : '';
      if (!content) {
        return false;
      }

      runtime.thoughtPreview = truncateText(content, MAX_TRANSCRIPT_PREVIEW);
      runtime.lastUpdatedAt = now();
      return true;
    }

    case 'assistant.message_delta': {
      const delta = typeof data.deltaContent === 'string' ? data.deltaContent : '';
      if (!delta) {
        return false;
      }

      runtime.assistantPreview = appendPreview(runtime.assistantPreview, delta);
      runtime.hadStructuredAssistantOutput = true;
      runtime.lastUpdatedAt = now();
      return true;
    }

    case 'assistant.message': {
      const content = typeof data.content === 'string' ? data.content : '';
      if (!content) {
        return false;
      }

      runtime.assistantPreview = truncateText(content, MAX_TRANSCRIPT_PREVIEW);
      runtime.hadStructuredAssistantOutput = true;
      runtime.waitingForResponse = false;
      runtime.lastUpdatedAt = now();
      return true;
    }

    case 'assistant.turn_end':
    case 'result':
      runtime.waitingForResponse = false;
      runtime.lastUpdatedAt = now();
      return true;

    case 'tool.execution_start': {
      const toolName = typeof data.toolName === 'string' ? data.toolName : 'tool';
      const toolCallId = typeof data.toolCallId === 'string' && data.toolCallId.trim()
        ? data.toolCallId.trim()
        : `${normalizeText(toolName) || 'tool'}:${runtime.recentTools.length + 1}`;

      upsertToolRecord(
        runtime,
        createToolRecord(toolName, {
          id: toolCallId,
          status: 'running',
          inputPreview: formatPreviewValue(
            data.input !== undefined
              ? data.input
              : data.arguments !== undefined
                ? data.arguments
                : data
          )
        })
      );
      runtime.lastUpdatedAt = now();
      return true;
    }

    case 'tool.execution_complete': {
      const toolName = typeof data.toolName === 'string' ? data.toolName : 'tool';
      const toolCallId = typeof data.toolCallId === 'string' && data.toolCallId.trim()
        ? data.toolCallId.trim()
        : normalizeText(toolName) || 'tool';
      const existing = runtime.recentTools.find((tool) => tool.id === toolCallId);
      const status = data.error ? 'failed' : 'succeeded';
      const nextRecord = createToolRecord(toolName, {
        id: toolCallId,
        status,
        inputPreview: existing ? existing.inputPreview : '',
        resultPreview: formatPreviewValue(
          data.result !== undefined
            ? data.result
            : data.output !== undefined
              ? data.output
              : data.response
        ),
        errorPreview: formatPreviewValue(
          data.error !== undefined ? data.error : data.message
        ),
        startedAt: existing ? existing.startedAt : now(),
        endedAt: now()
      });

      upsertToolRecord(runtime, nextRecord);
      runtime.lastUpdatedAt = now();
      return true;
    }

    default:
      return false;
  }
}

function applyTerminalCardRawOutput(runtime, text) {
  const preview = truncateText(text, MAX_TRANSCRIPT_PREVIEW);
  if (!preview) {
    return false;
  }

  runtime.plainTextPreview = appendPreview(runtime.plainTextPreview, preview);
  runtime.lastUpdatedAt = now();
  return true;
}

function recordTerminalCardSessionReady(runtime) {
  runtime.waitingForResponse = false;
  runtime.lastUpdatedAt = now();
}

function recordTerminalCardSessionError(runtime, message) {
  runtime.lastError = truncateText(message, MAX_TRANSCRIPT_PREVIEW);
  runtime.waitingForResponse = false;
  runtime.lastUpdatedAt = now();
}

function recordTerminalCardSessionExit(runtime, exitCode, signal) {
  runtime.waitingForResponse = false;
  runtime.lastExitCode = exitCode !== undefined && exitCode !== null ? exitCode : null;
  runtime.lastSignal = normalizeText(signal) || null;
  runtime.lastUpdatedAt = now();
}

function buildFallbackText(data) {
  const responsePreview = data.transcript.latestAssistantText || data.transcript.latestPlainText;
  const suffix = responsePreview ? ` Response: ${truncateText(responsePreview, 120)}` : '';

  return [
    `Windows Clippy terminal session ${data.session.displayName}`,
    `status ${data.status.hostStateLabel}`,
    `agent ${data.status.agent}`,
    `mode ${data.status.mode}`
  ].join(', ') + suffix;
}

function createSection(title, text, options = {}) {
  return {
    type: 'Container',
    separator: true,
    items: [
      {
        type: 'TextBlock',
        text: title,
        weight: 'Bolder',
        wrap: true
      },
      {
        type: 'TextBlock',
        text,
        wrap: true,
        fontType: 'Monospace',
        spacing: 'Small',
        color: options.color || 'Default',
        isSubtle: options.isSubtle || false
      }
    ]
  };
}

function createToolElements(recentTools) {
  if (!Array.isArray(recentTools) || recentTools.length === 0) {
    return [];
  }

  return [
    {
      type: 'Container',
      separator: true,
      items: [
        {
          type: 'TextBlock',
          text: 'Recent tools',
          weight: 'Bolder',
          wrap: true
        },
        ...recentTools.flatMap((tool) => {
          const items = [
            {
              type: 'TextBlock',
              text: `${tool.name} [${tool.statusLabel}]`,
              wrap: true,
              spacing: 'Small'
            }
          ];

          if (tool.inputPreview) {
            items.push({
              type: 'TextBlock',
              text: `Input: ${tool.inputPreview}`,
              wrap: true,
              fontType: 'Monospace',
              size: 'Small',
              isSubtle: true,
              spacing: 'None'
            });
          }

          if (tool.resultPreview) {
            items.push({
              type: 'TextBlock',
              text: `Result: ${tool.resultPreview}`,
              wrap: true,
              fontType: 'Monospace',
              size: 'Small',
              spacing: 'None'
            });
          }

          if (tool.errorPreview) {
            items.push({
              type: 'TextBlock',
              text: `Error: ${tool.errorPreview}`,
              wrap: true,
              fontType: 'Monospace',
              size: 'Small',
              color: 'Attention',
              spacing: 'None'
            });
          }

          return items;
        })
      ]
    }
  ];
}

function createTerminalCardData(snapshotInput) {
  const launchConfig = snapshotInput.launchConfig || {};
  const runtime = snapshotInput.runtime || createTerminalCardRuntime();
  const sessionId = normalizeText(snapshotInput.sessionId || launchConfig.sessionId);
  const displayName = normalizeText(snapshotInput.displayName) || 'Clippy session';
  const hostState = normalizeText(snapshotInput.hostState) || 'pending';
  const generatedAt = now();

  return {
    templateVersion: TERMINAL_CARD_TEMPLATE_VERSION,
    adaptiveCardVersion: ADAPTIVE_CARD_VERSION,
    generatedAt,
    assets: {
      templatePath: TERMINAL_CARD_TEMPLATE_PATH,
      dataSchemaPath: TERMINAL_CARD_DATA_SCHEMA_PATH
    },
    session: {
      tabId: normalizeText(snapshotInput.tabId),
      displayName,
      sessionId,
      shortSessionId: sessionId ? sessionId.slice(0, 8) : 'pending',
      workingDirectory: truncateText(launchConfig.workingDirectory || '', MAX_FACT_VALUE),
      configDirectory: truncateText(launchConfig.configDir || '', MAX_FACT_VALUE),
      transport: normalizeText(snapshotInput.sessionTransport) || 'resume-prompt-stream'
    },
    status: {
      hostState,
      hostStateLabel: toTitleCase(hostState) || 'Pending',
      isLive: hostState === 'running',
      pid: Number.isInteger(snapshotInput.pid) ? snapshotInput.pid : null,
      agent: normalizeText(launchConfig.agent) || 'default',
      model: normalizeText(launchConfig.model) || 'default',
      mode: toTitleCase(launchConfig.mode || 'agent') || 'Agent',
      rawMode: normalizeText(launchConfig.mode) || 'agent',
      toolFlags: Array.isArray(launchConfig.tools) ? launchConfig.tools.slice() : [],
      toolFlagSummary: summarizeToolFlags(launchConfig.tools),
      extraFlags: Array.isArray(launchConfig.extraFlags) ? launchConfig.extraFlags.slice() : [],
      extraFlagSummary: summarizeExtraFlags(launchConfig.extraFlags)
    },
    transcript: {
      latestUserPrompt: truncateText(runtime.userPromptPreview, MAX_PROMPT_PREVIEW),
      latestAssistantText: truncateText(runtime.assistantPreview, MAX_TRANSCRIPT_PREVIEW),
      latestThoughtText: truncateText(runtime.thoughtPreview, MAX_TRANSCRIPT_PREVIEW),
      latestPlainText: truncateText(runtime.plainTextPreview, MAX_TRANSCRIPT_PREVIEW),
      lastError: truncateText(runtime.lastError, MAX_TRANSCRIPT_PREVIEW),
      waitingForResponse: Boolean(runtime.waitingForResponse),
      lastUpdatedAt: runtime.lastUpdatedAt || generatedAt,
      lastExitCode: runtime.lastExitCode !== undefined ? runtime.lastExitCode : null,
      lastSignal: runtime.lastSignal || null
    },
    recentTools: runtime.recentTools.map((tool) => ({
      name: normalizeText(tool.name) || 'tool',
      status: normalizeText(tool.status) || 'running',
      statusLabel: normalizeText(tool.statusLabel) || 'Running',
      inputPreview: truncateText(tool.inputPreview, MAX_TOOL_PREVIEW),
      resultPreview: truncateText(tool.resultPreview, MAX_TOOL_PREVIEW),
      errorPreview: truncateText(tool.errorPreview, MAX_TOOL_PREVIEW),
      startedAt: tool.startedAt || null,
      endedAt: tool.endedAt || null
    }))
  };
}

function createTerminalAdaptiveCard(data) {
  const primaryTranscriptText =
    data.transcript.latestAssistantText ||
    data.transcript.latestPlainText ||
    'No assistant output has been captured for this session yet.';
  const primaryTranscriptTitle = data.transcript.latestAssistantText ? 'Assistant' : 'Transcript preview';

  const body = [
    {
      type: 'TextBlock',
      text: data.session.displayName,
      weight: 'Bolder',
      size: 'Medium',
      wrap: true
    },
    {
      type: 'TextBlock',
      text: `Windows Clippy terminal snapshot. ${data.status.agent} in ${data.status.mode} mode.`,
      spacing: 'None',
      isSubtle: true,
      wrap: true
    },
    {
      type: 'FactSet',
      facts: [
        { title: 'Session', value: data.session.shortSessionId },
        { title: 'Host', value: data.status.hostStateLabel },
        { title: 'Model', value: data.status.model },
        { title: 'PID', value: data.status.pid !== null ? String(data.status.pid) : 'pending' },
        { title: 'Tools', value: data.status.toolFlagSummary },
        { title: 'Transport', value: data.session.transport }
      ]
    }
  ];

  if (data.session.workingDirectory) {
    body.push({
      type: 'TextBlock',
      text: `Working directory: ${data.session.workingDirectory}`,
      wrap: true,
      isSubtle: true,
      size: 'Small'
    });
  }

  if (data.transcript.latestUserPrompt) {
    body.push(createSection('Latest prompt', data.transcript.latestUserPrompt));
  }

  body.push(createSection(primaryTranscriptTitle, primaryTranscriptText));

  if (data.transcript.latestThoughtText) {
    body.push(createSection('Reasoning', data.transcript.latestThoughtText, { isSubtle: true }));
  }

  body.push(...createToolElements(data.recentTools));

  if (data.transcript.lastError) {
    body.push(createSection('Last error', data.transcript.lastError, { color: 'Attention' }));
  }

  body.push({
    type: 'TextBlock',
    text: `Updated ${data.generatedAt}`,
    wrap: true,
    size: 'Small',
    isSubtle: true,
    separator: true
  });

  return {
    $schema: ADAPTIVE_CARD_SCHEMA_URL,
    type: 'AdaptiveCard',
    version: ADAPTIVE_CARD_VERSION,
    fallbackText: buildFallbackText(data),
    body
  };
}

function createTerminalCardSnapshot(snapshotInput) {
  const data = createTerminalCardData(snapshotInput);

  return {
    templateVersion: TERMINAL_CARD_TEMPLATE_VERSION,
    adaptiveCardVersion: ADAPTIVE_CARD_VERSION,
    assets: data.assets,
    data,
    card: createTerminalAdaptiveCard(data)
  };
}

module.exports = {
  ADAPTIVE_CARD_VERSION,
  TERMINAL_CARD_TEMPLATE_VERSION,
  TERMINAL_CARD_TEMPLATE_PATH,
  TERMINAL_CARD_DATA_SCHEMA_PATH,
  createTerminalCardRuntime,
  beginTerminalCardTurn,
  applyTerminalCardCopilotEvent,
  applyTerminalCardRawOutput,
  recordTerminalCardSessionReady,
  recordTerminalCardSessionError,
  recordTerminalCardSessionExit,
  createTerminalCardData,
  createTerminalAdaptiveCard,
  createTerminalCardSnapshot
};
