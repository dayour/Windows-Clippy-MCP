# MCP Apps 2026-01-26 Stable Specification Summary — Rev. 2

**Date:** 2025-01-26  
**Status:** Stable (SEP-1865)  
**Specification Source:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx

---

## 1. Entity Model

### 1.1 Tool

A standard MCP Tool enhanced with optional UI metadata:

```typescript
interface Tool {
  name: string;
  description: string;
  inputSchema: object;
  _meta?: {
    ui?: McpUiToolMeta;
  };
}
```

**Requirements (per spec §"Resource Discovery"):**
- Tool MUST be declarable via standard `tools/list`
- Tool _meta.ui field SHOULD reference `resourceUri` to link to a UIResource
- Tool visibility is controlled via `_meta.ui.visibility` array

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L335-L344

---

### 1.2 `_meta.ui.resourceUri`

**Definition:** The URI of a UI Resource used to render tool results.

```typescript
interface McpUiToolMeta {
  /** URI of UI resource for rendering tool results */
  resourceUri?: string;
  /**
   * Who can access this tool. Default: ["model", "app"]
   * - "model": Tool visible to and callable by the agent
   * - "app": Tool callable by the app from this server only
   */
  visibility?: Array<"model" | "app">;
}
```

**MUST/SHOULD/MAY Rules:**
- **MUST:** Resource referenced by `resourceUri` exists on the MCP server
- **SHOULD:** Host use `resources/read` to fetch the resource by URI before rendering
- **MAY:** Host prefetch and cache UI resource content for performance
- **Default:** If `visibility` omitted, defaults to `["model", "app"]`

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L321-L347

---

### 1.3 UIResource

A resource declared with `ui://` URI scheme, containing HTML content for interactive UIs.

```typescript
interface UIResource {
  /** MUST use ui:// URI scheme */
  uri: string;
  /** Human-readable display name */
  name: string;
  /** Optional description */
  description?: string;
  /** MUST be "text/html;profile=mcp-app" */
  mimeType: string;
  /** Resource metadata for security and rendering */
  _meta?: {
    ui?: UIResourceMeta;
  };
}

interface UIResourceMeta {
  csp?: McpUiResourceCsp;
  permissions?: {
    camera?: {};
    microphone?: {};
    geolocation?: {};
    clipboardWrite?: {};
  };
  domain?: string;
  prefersBorder?: boolean;
}

interface McpUiResourceCsp {
  /** Origins for network requests (fetch/XHR/WebSocket) - maps to CSP connect-src */
  connectDomains?: string[];
  /** Origins for static resources (scripts, images, styles, fonts) */
  resourceDomains?: string[];
  /** Origins for nested iframes - maps to CSP frame-src */
  frameDomains?: string[];
  /** Allowed base URIs for the document */
  baseUriDomains?: string[];
}
```

**MUST/SHOULD/MAY Rules:**
- **MUST:** URI start with `ui://` scheme
- **MUST:** mimeType be `text/html;profile=mcp-app`
- **MUST:** content be provided via either `text` (string) or `blob` (base64-encoded)
- **MUST:** content be valid HTML5 document
- **SHOULD:** Server declare CSP domains for security
- **Default CSP (if omitted):** `default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none';`

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L59-L231

---

### 1.4 View (UI iframe)

An MCP client running inside an iframe, communicating with the Host via postMessage JSON-RPC.

**Properties:**
- Acts as MCP client (not server)
- Communicates with Host via `postMessage` transport over standard MCP JSON-RPC 2.0
- Sends requests (e.g., `ui/initialize`, `tools/call`, `ui/open-link`)
- Sends notifications (e.g., `ui/notifications/initialized`, `ui/notifications/size-changed`)
- Receives notifications from Host (e.g., `ui/notifications/tool-input`, `ui/notifications/host-context-changed`)

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L415-L468

---

### 1.5 Host

An MCP client or wrapper that renders UI Resources and acts as a bridge between Views and MCP Servers.

**Responsibilities:**
- **MUST:** Support `io.modelcontextprotocol/ui` extension capability during Phase A handshake
- **MUST:** Fetch UI Resources using `resources/read`
- **MUST:** Render View iframes with CSP enforcement
- **MUST:** Listen to View messages via postMessage and route them appropriately
- **MUST NOT:** Send requests/notifications to View before receiving `ui/notifications/initialized`
- **SHOULD:** Provide `hostContext` (theme, styles, displayMode, containerDimensions, etc.) in response to `ui/initialize`
- **MAY:** Further restrict CSP domains beyond what Server declares

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L468-L488

---

### 1.6 Server (MCP Apps Server)

Standard MCP server that declares UI resources and tools with UI metadata.

**Capabilities:**
- Declares resources with `ui://` URI scheme (via `resources/list`, `resources/read`)
- Declares tools with `_meta.ui.resourceUri` metadata
- Declares `_meta.ui.visibility` to control model vs. app access
- **MAY:** Omit UI-only resources from `notifications/resources/list_changed` if not needed

**Extension Capability:** `extensions: { "io.modelcontextprotocol/ui": { ... } }`

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L38-L409

---

## 2. Handshake Protocol

### 2.1 Phase A: Host ↔ Server (Standard MCP Initialize)

**Direction:** Host → Server (request), Server → Host (response)

| Step | Actor | Message | Direction | Description |
|------|-------|---------|-----------|-------------|
| 1 | Host | `initialize` | Host → Server | Host sends MCP initialize request with `extensions: { "io.modelcontextprotocol/ui": { "mimeTypes": ["text/html;profile=mcp-app"] } }` |
| 2 | Server | `initialize` response | Server → Host | Server acknowledges capability support; returns `capabilities` with extension confirmation |
| 3 | Host | `resources/list` | Host → Server | Host discovers UI resources (uri starting with `ui://`) and tools with `_meta.ui` |
| 4 | Server | `resources/list` response | Server → Host | Server returns list of UIResources with `uri`, `name`, `mimeType`, `_meta.ui` |

**Negotiation:**
- Server checks Host's `extensions["io.modelcontextprotocol/ui"].mimeTypes` to confirm `text/html;profile=mcp-app` is supported
- Host checks Server's `capabilities.extensions["io.modelcontextprotocol/ui"]` to confirm extension is enabled
- Both sides MUST confirm before proceeding to Phase B

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L38-L53

---

### 2.2 Phase B: View ↔ Host (UI Initialize)

**Direction: View → Host (request), Host → View (response)**

| Step | Actor | Message | Direction | **CORRECTED** | Description |
|------|-------|---------|-----------|---|-------------|
| 1 | View | `ui/initialize` | **View → Host** | **REQUEST** | View sends MCP-style initialize request with `appCapabilities`, `clientInfo`, `protocolVersion` |
| 2 | Host | `ui/initialize` response | **Host → View** | **RESPONSE** | Host responds with `hostCapabilities`, `hostContext` (theme, styles, containerDimensions, displayMode, etc.), `hostInfo` |
| 3 | View | `ui/notifications/initialized` | **View → Host** | **NOTIFICATION** | View confirms initialization complete; MUST be sent after Host's response to initialize |
| 4 | Host | `ui/notifications/tool-input-partial` | **Host → View** | **NOTIFICATION** | (Optional) Host sends partial tool arguments as agent streams them (0..n times) |
| 5 | Host | `ui/notifications/tool-input` | **Host → View** | **NOTIFICATION** | Host sends complete tool arguments (REQUIRED before tool-result) |
| 6 | Host | `ui/notifications/tool-result` | **Host → View** | **NOTIFICATION** | Host sends tool execution result |

**Phase B Requirements:**
- **View MUST send** `ui/initialize` request first (containing `appCapabilities`)
- **Host MUST respond** with `McpUiInitializeResult` containing:
  - `protocolVersion`: "2026-01-26" (or negotiated version)
  - `hostCapabilities`: features Host supports
  - `hostContext`: theme, styles, containerDimensions, locale, timezone, displayMode, userAgent, platform, deviceCapabilities
  - `hostInfo`: Host name and version
- **View MUST send** `ui/notifications/initialized` after receiving Host's response
- **Host MUST NOT** send any message to View before receiving `ui/notifications/initialized`
- **Host MUST send** `ui/notifications/tool-input` (complete) before `ui/notifications/tool-result`

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L510-L1323

---

## 3. Full Notification Inventory

### View-Sent Notifications (View → Host)

| Method | Direction | Purpose | Parameters | Citation |
|--------|-----------|---------|-----------|----------|
| `ui/notifications/initialized` | **View → Host** | View initialization complete; signals ready to receive Host messages | `{}` (empty) | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1325 |
| `ui/notifications/size-changed` | **View → Host** | View reports content size change (e.g., ResizeObserver event) | `{ width: number, height: number }` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1204-1218 |
| `notifications/message` | **View → Host** | Log message to host | MCP standard `notifications/message` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L503 |
| `ui/notifications/sandbox-proxy-ready` | **Sandbox Proxy → Host** | Sandbox proxy signals ready to receive resource | `{}` (empty) | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1235-1242 |

---

### Host-Sent Notifications (Host → View)

| Method | Direction | Purpose | Parameters | Citation |
|--------|-----------|---------|-----------|----------|
| `ui/notifications/tool-input-partial` | **Host → View** | (Optional) Partial tool arguments during streaming | `{ arguments: Record<string, unknown> }` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1120-1143 |
| `ui/notifications/tool-input` | **Host → View** | Complete tool arguments (REQUIRED before tool-result) | `{ arguments: Record<string, unknown> }` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1106-1118 |
| `ui/notifications/tool-result` | **Host → View** | Tool execution result | `CallToolResult` (MCP standard) | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1145-1155 |
| `ui/notifications/tool-cancelled` | **Host → View** | Tool execution was cancelled | `{ reason: string }` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1157-1170 |
| `ui/notifications/host-context-changed` | **Host → View** | Host context changed (theme, displayMode, containerDimensions, etc.) | `Partial<HostContext>` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1219-1229 |
| `ui/resource-teardown` | **Host → View** | Host notifies View before teardown | `{ reason: string }` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1171-1202 |
| `ui/notifications/sandbox-resource-ready` | **Host → Sandbox Proxy** | HTML resource ready for loading | `{ html: string, sandbox?: string, csp: {…}, permissions: {…} }` | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L1245-1270 |

---

### Server-Sent Notifications (Baseline MCP)

| Method | Direction | Purpose | Parameters | Citation |
|--------|-----------|---------|-----------|----------|
| `notifications/resources/list_changed` | **Server → Host** | Resource list changed (tools, resources, or both) | MCP standard notification | https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L393 |

**Note:** The deprecated channel name was `notifications/resources/updated` in early drafts. The **canonical** channel is `notifications/resources/list_changed` per MCP standard.

---

## 4. Tool Visibility Field Semantics

### Definition

The `visibility` field in `_meta.ui` controls which principals (model agent vs. app View) can see and call a tool.

```typescript
visibility?: Array<"model" | "app">;
```

### Rules (Host Filtering)

**MUST Rules:**

1. **Default:** If `visibility` omitted, defaults to `["model", "app"]` (visible to both)

2. **tools/list filtering (Host → Agent):**
   - Host MUST NOT include tool in `tools/list` response if visibility does NOT include `"model"`
   - Example: `visibility: ["app"]` means tool is **hidden from agent**

3. **tools/call filtering (App → Host → Server):**
   - Host MUST REJECT `tools/call` from app if visibility does NOT include `"app"`
   - Example: `visibility: ["model"]` means app **cannot call** this tool
   - Cross-server tool calls are always blocked for app-only tools

### Semantics

| visibility | Model Agent | App View | Purpose |
|------------|-------------|----------|---------|
| `["model", "app"]` (default) | ✓ Sees & calls | ✓ Calls | Standard tool, shared by both |
| `["model"]` | ✓ Sees & calls | ✗ Cannot call | Model-only; app has no access |
| `["app"]` | ✗ Hidden | ✓ Calls | App-only; UI interaction without model exposure |

### Benefits

- **Performance:** UI can trigger internal refresh/refetch tools without exposing them to model
- **Security:** Model cannot see implementation details of UI-only controls
- **Auditability:** Clear boundaries between model-visible and UI-only operations

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L395-L410

---

## 5. Sandbox + CSP Contract

### CSP Declaration by Server

Server declares CSP domains in UIResource metadata:

```typescript
_meta?: {
  ui?: {
    csp?: {
      connectDomains?: string[];    // fetch/XHR/WebSocket origins
      resourceDomains?: string[];   // script/image/style/font/media origins
      frameDomains?: string[];      // nested iframe origins
      baseUriDomains?: string[];    // allowed base URIs
    };
    permissions?: {                 // Permission Policy
      camera?: {};
      microphone?: {};
      geolocation?: {};
      clipboardWrite?: {};
    };
    domain?: string;                // Dedicated sandbox origin (host-dependent format)
    prefersBorder?: boolean;        // Visual boundary preference
  };
}
```

### Default CSP (If Metadata Omitted)

**Spec Text (§"Resource Content Requirements"):**
> "If `ui.csp` is omitted, Host MUST use: `default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none';`"

**Translation:**
- No external connections (secure default)
- Inline scripts & styles allowed (for typical SPA UI)
- Local images & data URIs only
- No nested iframes

### Host Enforcement

**MUST Rules:**

1. **Construct CSP headers** based on declared domains
2. **Apply restrictive default** if `ui.csp` omitted (above)
3. **Further restrict but NOT loosen** undeclared domains
4. **No dynamic injection** from Host; Server declares all domains upfront
5. **Audit trail:** Host SHOULD log CSP configurations for security review

### Sandbox Proxy Architecture (Web Hosts)

For web-based hosts, a **double-iframe** pattern is REQUIRED:

1. **Outer Sandbox Iframe** (different origin from Host):
   - Permissions: `allow-scripts allow-same-origin`
   - Receives HTML from Host via `ui/notifications/sandbox-resource-ready`
   - Injects CSP headers
   - Renders inner iframe

2. **Inner Content Iframe** (same origin as Sandbox):
   - Loads HTML with CSP headers already applied
   - Communicates with Host via Sandbox (postMessage pass-through)
   - Cannot escape CSP sandbox

**Flow:**
```
Host → Sandbox Proxy: ui/notifications/sandbox-resource-ready (HTML + CSP config)
  ↓
Sandbox Proxy: Injects CSP headers
  ↓
Sandbox Proxy → Content Iframe: Loads HTML
  ↓
Content Iframe ↔ Sandbox Proxy ↔ Host: Bidirectional postMessage
```

**Citation:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx#L272-L488

---

## 6. Clippy-as-Principal Overlay

### NOT Spec-Native — Overlay Proposal

**This section describes how Clippy identity integrates with MCP Apps protocol, but this is NOT part of the official MCP Apps 2026-01-26 specification. It is a Windows Clippy MCP implementation-specific overlay.**

### Conceptual Model

MCP Apps protocol treats communication endpoints as:
- **View:** UI iframe (opaque identity)
- **Host:** MCP client wrapper (opaque identity)
- **Server:** MCP server (explicitly named, versioned)

**Clippy Overlay Mapping:**

| Spec Entity | Clippy Role | Trust Boundary | Identity Source |
|-------------|-------------|-----------------|-----------------|
| View | Clippy UI (animated agent + response renderer) | User device (iframe sandbox) | Win32 process hash / manifest |
| Host | Clippy Host Bridge | User device (desktop app) | Claude Desktop / Copilot integration |
| Server | Third-party MCP Server | Network/Local (untrusted) | Server URL / connection string |

### Trust Model Under Overlay

1. **View ↔ Host boundary (TRUSTED):**
   - Clippy UI iframe ↔ Claude Desktop bridge
   - CSP applied by Host (Claude Desktop) enforces sandbox
   - postMessage filtering by Host (optional per spec)

2. **Host ↔ Server boundary (UNTRUSTED):**
   - Claude Desktop ↔ Third-party MCP Server
   - Server declares CSP domains (self-reported)
   - Host MUST further validate/restrict (Host MAY block messages)
   - Spec §6: "While Host SHOULD ensure View's MCP connection is spec-compliant, it MAY decide to block some messages or subject them to further user approval."

3. **User as implicit principal:**
   - CSP violations logged and surfaced
   - Cross-domain resource requests require Host approval
   - Tool visibility prevents model hallucination of hidden UI tools
   - `ui/update-model-context` gated by Host consent logic

### Clippy-Specific Extensions (NOT in spec)

**Possible (future) additions, not in this spec:**
- Clippy identity header in postMessage (optional)
- Gesture-based trust escalation (e.g., user click to allow elevated permissions)
- Metadata about Clippy agent mode (standalone vs. embedded in chat)
- Telemetry channel for CSP violations / auth failures

---

## 7. Open Questions & Known Gaps

1. **`domain` field semantics:** The spec notes "Host-dependent format and validation rules" for dedicated sandbox origins. Clarification needed on:
   - Whether hosts should support this field or treat as optional
   - Standard domain patterns (hash-based vs. URL-derived)
   - IANA registry or naming authority

2. **Cross-server tool calls from View:** Spec says cross-server tool calls are "always blocked for app-only tools" but does NOT explicitly ban cross-server calls for model-visible tools. Clarification:
   - Are Views restricted to same-server tools only?
   - If multi-server, how is tool namespace managed?

3. **Partial argument recovery:** The spec says Host MAY "parse agent's partial JSON output by closing unclosed brackets/braces." But:
   - Which closures are safe (depth limit)?
   - What if agent sends invalid syntax (not just incomplete)?
   - Example recovery heuristics missing

4. **CSP collision with Server-declared domains:** If Server declares `connectDomains: ["https://evil.com"]` and Host policy forbids it, what takes precedence?
   - Spec says Host MAY "further restrict but MUST NOT loosen"
   - Missing: explicit conflict resolution algorithm

5. **`notifications/resources/list_changed` vs. `notifications/tools/list_changed`:** Spec mentions both in capabilities:
   ```
   serverTools?: { listChanged?: boolean }
   serverResources?: { listChanged?: boolean }
   ```
   - Are they separate notifications or one combined notification?
   - MCP core spec does NOT define `tools/list_changed` (only `resources/list_changed`)

6. **Display mode negotiation edge cases:**
   - What if View requests `fullscreen` but Host only supports `inline`?
   - Spec says Host SHOULD return current mode, but does View re-initialize?
   - No re-flow/re-render guidance after mode change

7. **Lifecycle of tool-specific UI Resources:**
   - Can same tool have multiple `resourceUri` values (one per tool name)?
   - Can different tools reference the same resource?
   - Resource versioning / invalidation strategy?

---

## Revision History

### Rev. 2 (This Document)

**Corrections from Rev. 1:**

1. **Protocol Direction Fixed:**
   - ✗ OLD: "Phase 2: Host -> View (ui/initialize Request)"
   - ✓ NEW: "Phase B: View -> Host (ui/initialize Request)"
   - All ui/ messages originate from View (the iframe client), not Host

2. **Notification Direction Audit:**
   - ✗ OLD: All notifications listed as Host → View only
   - ✓ NEW: Proper bidirectional:
     - View → Host: `ui/notifications/initialized`, `ui/notifications/size-changed`
     - Host → View: `ui/notifications/tool-input`, `ui/notifications/tool-input-partial`, `ui/notifications/tool-result`, `ui/notifications/host-context-changed`, `ui/resource-teardown`

3. **Resource Channel Clarification:**
   - ✗ OLD: Conflated `notifications/resources/updated` (not in spec)
   - ✓ NEW: Canonical channel is `notifications/resources/list_changed` (per MCP baseline spec §"Resource Discovery")

4. **Entity Model Formalized:**
   - Added explicit Tool, UIResource, View, Host, Server definitions with MUST/SHOULD/MAY language
   - All rules quoted or paraphrased from spec with direct citation anchors

5. **Sandbox Architecture Expanded:**
   - Added double-iframe flow diagram (Sandbox Proxy ↔ Content Iframe)
   - Clarified CSP injection point and permission policy mapping
   - Web-only requirement clearly marked

6. **Clippy Overlay Marked as Non-Normative:**
   - Explicitly noted NOT part of official MCP Apps spec
   - Separate trust boundary table for clarity
   - Deferred extensions clearly marked as "possible future" not actual

---

## References

- **Official Specification:** https://github.com/modelcontextprotocol/ext-apps/blob/01d826aea000a2f774d1d3e9b57fa352632c1c50/specification/2026-01-26/apps.mdx
- **Reference Implementation (TypeScript):** https://github.com/modelcontextprotocol/ext-apps/tree/01d826aea000a2f774d1d3e9b57fa352632c1c50/src
- **MCP Core Protocol:** https://spec.modelcontextprotocol.io/
- **SEP-1865:** https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/ (Specification Enhancement Proposal)
- **Release:** 2026-01-26 (Stable) — https://github.com/modelcontextprotocol/ext-apps/releases/tag/stable-2026-01-26

---

**Document Version:** 2026-01-26-rev2  
**Last Updated:** 2025 Q1  
**Author Attribution:** Extracted from official MCP Apps spec; errors and overlay proposals are implementation-specific
