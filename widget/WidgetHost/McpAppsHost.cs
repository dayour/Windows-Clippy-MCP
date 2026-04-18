// L3-2: WebView2 host for MCP Apps Views inside the WidgetHost bench.
//
// This control renders a single MCP App View (e.g. ui://clippy/fleet-status.html)
// inside a sandboxed WebView2 surface, brokering JSON-RPC-over-postMessage
// traffic between the View and the C# McpAppsBridge.
//
// URI translation (L3-2 design):
//   The MCP Apps spec identifies Views with a ui:// URI. WebView2 cannot
//   register truly custom schemes, so we pin a virtual host name
//   ("clippy-ui.local") to the on-disk views folder via
//   CoreWebView2.SetVirtualHostNameToFolderMapping. Any inbound reference
//   ui://clippy/<path>  is translated to  https://clippy-ui.local/<path>
//   before navigation. The reverse translation is applied on outbound
//   URIs posted from the view.
//
// CSP:
//   Enforced via WebResourceRequested handler so we can add a real
//   response header instead of relying on a <meta> tag that the view
//   bundle may or may not emit:
//     default-src 'self' https://clippy-ui.local;
//     script-src 'self' 'unsafe-inline' https://clippy-ui.local;
//     connect-src 'self' https://clippy-ui.local;
//     frame-ancestors 'self'
//
// View <-> Host protocol (from L1 carry-forwards):
//   View -> Host:  ui/initialize,
//                  ui/notifications/initialized,
//                  ui/notifications/size-changed,
//                  tools/call,
//                  resources/read,
//                  resources/list
//   Host -> View:  ui/notifications/tool-input*,
//                  ui/notifications/tool-result,
//                  ui/notifications/host-context-changed,
//                  notifications/resources/list_changed  (bare signal; View re-fetches)
//                  clippy/notifications/event-stream    (private extension channel)
//
// Do NOT send tool-result as a general event bus. Use event-stream for
// unrelated CommanderHub signals.

using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace WidgetHost;

internal sealed class McpAppsToolCall
{
    public McpAppsToolCall(int? requestId, string toolName, JsonElement arguments)
    {
        RequestId = requestId;
        ToolName = toolName;
        Arguments = arguments;
    }

    public int? RequestId { get; }
    public string ToolName { get; }
    public JsonElement Arguments { get; }
}

internal sealed class McpAppsHost : UserControl, IDisposable
{
    private const string VirtualHost = "clippy-ui.local";
    private const string UiSchemePrefix = "ui://clippy/";
    private const string VirtualHostOrigin = "https://" + VirtualHost;

    private const string ContentSecurityPolicy =
        "default-src 'self' https://clippy-ui.local; " +
        "script-src 'self' 'unsafe-inline' https://clippy-ui.local; " +
        "style-src 'self' 'unsafe-inline' https://clippy-ui.local; " +
        "img-src 'self' data: https://clippy-ui.local; " +
        "font-src 'self' data: https://clippy-ui.local; " +
        "connect-src 'self' https://clippy-ui.local; " +
        "frame-ancestors 'self'";

    // Bridge shim: the ext-apps SDK's PostMessageTransport targets
    // window.parent (iframe model). Our view is top-level in WebView2, so we
    // rewire:
    //   view -> host: hijack window.parent.postMessage AND window.postMessage
    //                 to forward payloads through chrome.webview.postMessage
    //   host -> view: listen for chrome.webview 'message' events and re-emit
    //                 them as a standard 'message' event on window, which the
    //                 SDK's transport is already subscribed to.
    // We keep origin checks inert (SDK accepts '*') because the CSP and
    // SetVirtualHostNameToFolderMapping already sandbox the origin.
    private const string ViewBridgeShim = @"
(function(){
  try {
    if (!window.chrome || !window.chrome.webview) { return; }
    var webview = window.chrome.webview;
    window.__clippyBridgeReady = true;
    var dbg = function(tag, payload){ try { webview.postMessage('__clippy_debug__:' + tag + ':' + (typeof payload==='string'?payload:JSON.stringify(payload||''))); } catch(e){} };
    var send = function(data) {
      try {
        var payload = (typeof data === 'string') ? data : JSON.stringify(data);
        webview.postMessage(payload);
      } catch (e) { dbg('send_err', String(e)); }
    };
    // Strategy: window.parent === window naturally for top-level docs. SDK's
    // PostMessageTransport uses window.parent as both eventTarget and
    // eventSource, and its message listener compares event.source strictly.
    // MessageEvent requires source to be Window or MessagePort, so we keep
    // window.parent as the real Window and forward all outbound postMessage
    // through our patched window.postMessage. Inbound replays use window as
    // source so the identity check passes.
    var origPost = window.postMessage.bind(window);
    window.postMessage = function(m, target) {
      try { send(m); } catch(e){ dbg('post_send_err', String(e)); }
      // Intentionally do NOT call origPost: that would re-dispatch the
      // outbound message to our own listeners and confuse the SDK.
    };
    webview.addEventListener('message', function(ev) {
      try {
        var raw = ev.data;
        if (typeof raw === 'string' && raw.indexOf('__clippy_debug__:') === 0) { return; }
        var data = (typeof raw === 'string') ? JSON.parse(raw) : raw;
        dbg('in', { method: data && data.method, id: data && data.id, hasResult: !!(data && data.result), hasError: !!(data && data.error) });
        var me = new MessageEvent('message', {
          data: data,
          origin: window.location.origin,
          source: window
        });
        window.dispatchEvent(me);
      } catch (e) { dbg('in_err', String(e)); }
    });
    dbg('ready', { parent_is_self: window.parent === window, top_is_self: window.top === window });
  } catch (e) { try { window.chrome.webview.postMessage('__clippy_debug__:outer_err:' + String(e)); } catch(e2){} }
})();
";

    private readonly string _resourceUri;
    private readonly McpAppsBridge _bridge;
    private readonly string _commanderSessionId;
    private readonly WebView2 _webView;
    private readonly string _viewsFolder;
    private readonly string _fallbackFolder;
    private bool _readyInvoked;
    private bool _disposed;

    public McpAppsHost(string resourceUri, McpAppsBridge bridge, string commanderSessionId)
    {
        _resourceUri = resourceUri ?? throw new ArgumentNullException(nameof(resourceUri));
        _bridge = bridge ?? throw new ArgumentNullException(nameof(bridge));
        _commanderSessionId = commanderSessionId ?? throw new ArgumentNullException(nameof(commanderSessionId));

        _viewsFolder = ResolveViewsFolder();
        _fallbackFolder = EnsureFallbackFolder();

        _webView = new WebView2
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 12, 12, 28),
        };

        var grid = new Grid();
        grid.Children.Add(_webView);
        Content = grid;
    }

    public event EventHandler<McpAppsToolCall>? ToolCallRequested;

    /// <summary>
    /// Fires after the view posts <c>ui/notifications/initialized</c>, meaning
    /// the view's <c>ontoolresult</c> / <c>onerror</c> handlers are wired and
    /// any host-pushed tool-result, resource change, or event-stream payload
    /// will actually be processed. Callers should re-seed initial state here.
    /// </summary>
    public event EventHandler? ViewInitialized;

    /// <summary>
    /// Returns the rendered <c>document.body.innerText</c> of the view. Used
    /// by live-smoke evidence capture to prove the View actually rendered
    /// real fleet counters (not a placeholder).
    /// </summary>
    public async Task<string?> DumpViewTextAsync()
    {
        try
        {
            var core = _webView.CoreWebView2;
            if (core is null) return null;
            var js = "document.body ? document.body.innerText : '<no body>'";
            var raw = await core.ExecuteScriptAsync(js).ConfigureAwait(true);
            return raw;
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: DumpViewTextAsync failed: {ex.Message}");
            return null;
        }
    }

    public async Task EnsureReadyAsync()
    {
        if (_readyInvoked) return;
        _readyInvoked = true;

        try
        {
            await _webView.EnsureCoreWebView2Async().ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: EnsureCoreWebView2Async failed: {ex.Message}");
            return;
        }

        var core = _webView.CoreWebView2;
        if (core is null)
        {
            WidgetHostLogger.Log("McpAppsHost: CoreWebView2 is null after EnsureCoreWebView2Async.");
            return;
        }

        ConfigureSettings(core);

        var folderToServe = Directory.Exists(_viewsFolder) && HasViewFile(_viewsFolder)
            ? _viewsFolder
            : _fallbackFolder;

        try
        {
            core.SetVirtualHostNameToFolderMapping(
                VirtualHost,
                folderToServe,
                CoreWebView2HostResourceAccessKind.DenyCors);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: SetVirtualHostNameToFolderMapping failed: {ex.Message}");
        }

        try
        {
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += OnWebResourceRequested;
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: WebResourceRequested wiring failed: {ex.Message}");
        }

        core.NavigationStarting += OnNavigationStarting;
        core.NewWindowRequested += OnNewWindowRequested;
        core.PermissionRequested += OnPermissionRequested;
        core.WebMessageReceived += OnWebMessageReceived;

        // Forward view-side console.log / console.error to host log (DEBUG
        // only) so we can diagnose SDK handshake failures without manually
        // opening DevTools.
#if DEBUG
        try
        {
            await core.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}").ConfigureAwait(true);
            var consoleSub = core.GetDevToolsProtocolEventReceiver("Runtime.consoleAPICalled");
            consoleSub.DevToolsProtocolEventReceived += (_, ev) =>
            {
                try { WidgetHostLogger.Log($"McpAppsHost[view-console]: {ev.ParameterObjectAsJson}"); }
                catch { }
            };
            var exSub = core.GetDevToolsProtocolEventReceiver("Runtime.exceptionThrown");
            exSub.DevToolsProtocolEventReceived += (_, ev) =>
            {
                try { WidgetHostLogger.Log($"McpAppsHost[view-exception]: {ev.ParameterObjectAsJson}"); }
                catch { }
            };
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: CDP Runtime subscribe failed: {ex.Message}");
        }
#endif

        // ext-apps app-bridge defaults to window.parent.postMessage because
        // its reference embedding is an iframe. Our view is top-level inside
        // WebView2 (no parent), so without this shim every message the SDK
        // sends is routed to self and is never surfaced to the native host.
        // Shim: route window.parent.postMessage -> chrome.webview.postMessage,
        // and forward native PostWebMessage* payloads back as 'message'
        // events on window (SDK's PostMessageTransport listens there).
        try
        {
            await core.AddScriptToExecuteOnDocumentCreatedAsync(ViewBridgeShim).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: AddScriptToExecuteOnDocumentCreatedAsync failed: {ex.Message}");
        }

        var targetUrl = TranslateUiUriToHttps(_resourceUri);
        WidgetHostLogger.Log($"McpAppsHost: navigating to {targetUrl} (folder={folderToServe}).");
        try { _webView.CoreWebView2.Navigate(targetUrl); }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: Navigate failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Host -> View: deliver a tools/call result that a previous
    /// <see cref="ToolCallRequested"/> invocation resolved. Do NOT use
    /// this as a general event bus.
    /// </summary>
    public Task PostToolResultAsync(string toolName, JsonElement structuredContent, int? requestId = null)
    {
        ThrowIfDisposed();
        var sb = new StringBuilder(256);
        sb.Append("{\"jsonrpc\":\"2.0\",\"method\":\"ui/notifications/tool-result\",\"params\":{")
          .Append("\"toolName\":").Append(JsonSerializer.Serialize(toolName));
        if (requestId.HasValue)
        {
            sb.Append(",\"requestId\":").Append(requestId.Value);
        }
        sb.Append(",\"structuredContent\":").Append(structuredContent.GetRawText()).Append("}}");
        return PostToViewAsync(sb.ToString());
    }

    /// <summary>
    /// Host -> View: bare <c>notifications/resources/list_changed</c>
    /// signal. Views must re-fetch via resources/read or tools/call.
    /// Never carry state payloads on this channel.
    /// </summary>
    public Task PostResourceListChangedAsync()
    {
        ThrowIfDisposed();
        const string payload = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\"}";
        return PostToViewAsync(payload);
    }

    /// <summary>
    /// Host -> View: private extension channel for CommanderHub events
    /// (tab added, copilot event, etc.). Do NOT fold these into tool-result.
    /// </summary>
    public Task PostEventStreamAsync(string channel, JsonElement payload)
    {
        ThrowIfDisposed();
        var sb = new StringBuilder(256);
        sb.Append("{\"jsonrpc\":\"2.0\",\"method\":\"clippy/notifications/event-stream\",\"params\":{")
          .Append("\"channel\":").Append(JsonSerializer.Serialize(channel))
          .Append(",\"payload\":").Append(payload.GetRawText())
          .Append("}}");
        return PostToViewAsync(sb.ToString());
    }

    public Task PostHostContextChangedAsync(JsonElement context)
    {
        ThrowIfDisposed();
        var sb = new StringBuilder(256);
        sb.Append("{\"jsonrpc\":\"2.0\",\"method\":\"ui/notifications/host-context-changed\",\"params\":")
          .Append(context.GetRawText()).Append('}');
        return PostToViewAsync(sb.ToString());
    }

    /// <summary>
    /// Host -> View: respond to a <c>ui/initialize</c> JSON-RPC request from
    /// the View so its handshake completes, <c>isConnected</c> flips true, and
    /// <c>ontoolresult</c> / <c>onerror</c> get wired. Response shape must
    /// satisfy <c>McpUiInitializeResultSchema</c> from ext-apps SDK:
    /// protocolVersion + hostInfo + hostCapabilities + hostContext are
    /// required. Extra keys pass through (principal, etc.).
    /// </summary>
    private Task PostInitializeResponseAsync(int requestId)
    {
        ThrowIfDisposed();
        var sb = new StringBuilder(512);
        sb.Append("{\"jsonrpc\":\"2.0\",\"id\":").Append(requestId)
          .Append(",\"result\":{")
          .Append("\"protocolVersion\":\"2026-01-26\",")
          .Append("\"hostInfo\":{\"name\":\"windows-clippy-widget\",\"version\":\"0.2.0-alpha.1\"},")
          .Append("\"hostCapabilities\":{},")
          .Append("\"hostContext\":{\"platform\":\"desktop\",\"userAgent\":\"windows-clippy-widget/0.2.0-alpha.1\",\"colorScheme\":\"dark\"},")
          .Append("\"principal\":{\"kind\":\"agent\",\"id\":\"clippy\",\"session\":")
          .Append(JsonSerializer.Serialize(_commanderSessionId))
          .Append("}}}");
        return PostToViewAsync(sb.ToString());
    }

    private Task PostToViewAsync(string json)
    {
        if (_disposed) return Task.CompletedTask;
        if (!Dispatcher.CheckAccess())
        {
            return Dispatcher.InvokeAsync(() => PostToView(json)).Task;
        }
        PostToView(json);
        return Task.CompletedTask;
    }

    private void PostToView(string json)
    {
        try
        {
            _webView.CoreWebView2?.PostWebMessageAsString(json);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: PostWebMessageAsString failed: {ex.Message}");
        }
    }

    private static void ConfigureSettings(CoreWebView2 core)
    {
        var s = core.Settings;
        s.AreDefaultContextMenusEnabled = false;
        s.AreDefaultScriptDialogsEnabled = false;
        s.IsGeneralAutofillEnabled = false;
        s.IsPasswordAutosaveEnabled = false;
        s.IsStatusBarEnabled = false;
        s.AreBrowserAcceleratorKeysEnabled = false;
        s.IsZoomControlEnabled = false;
        s.IsSwipeNavigationEnabled = false;
#if DEBUG
        s.AreDevToolsEnabled = true;
#else
        s.AreDevToolsEnabled = false;
#endif
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (!IsAllowedUri(e.Uri))
        {
            WidgetHostLogger.Log($"McpAppsHost: blocking navigation to {e.Uri}");
            e.Cancel = true;
        }
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        e.Handled = true;
    }

    private void OnPermissionRequested(object? sender, CoreWebView2PermissionRequestedEventArgs e)
    {
        e.State = CoreWebView2PermissionState.Deny;
    }

    private void OnWebResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        try
        {
            var uri = new Uri(e.Request.Uri);
            if (!string.Equals(uri.Host, VirtualHost, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            var rel = uri.AbsolutePath.TrimStart('/');
            if (string.IsNullOrEmpty(rel)) rel = "fleet-status.html";

            var primary = Path.Combine(_viewsFolder, rel);
            var fallback = Path.Combine(_fallbackFolder, rel);
            var filePath = File.Exists(primary) ? primary : File.Exists(fallback) ? fallback : null;

            if (filePath is null)
            {
                var notFound = "<html><body>404</body></html>";
                var notFoundBytes = Encoding.UTF8.GetBytes(notFound);
                using var nfStream = new MemoryStream(notFoundBytes);
                e.Response = _webView.CoreWebView2.Environment.CreateWebResourceResponse(
                    nfStream, 404, "Not Found",
                    "Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: " + ContentSecurityPolicy);
                return;
            }

            var bytes = File.ReadAllBytes(filePath);
            var contentType = ResolveContentType(filePath);
            var headers =
                "Content-Type: " + contentType + "\r\n" +
                "Content-Security-Policy: " + ContentSecurityPolicy + "\r\n" +
                "X-Content-Type-Options: nosniff\r\n" +
                "Referrer-Policy: no-referrer";

            var stream = new MemoryStream(bytes);
            e.Response = _webView.CoreWebView2.Environment.CreateWebResourceResponse(stream, 200, "OK", headers);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: WebResourceRequested failed: {ex.Message}");
        }
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string raw;
        try { raw = e.TryGetWebMessageAsString(); }
        catch
        {
            try { raw = e.WebMessageAsJson ?? string.Empty; } catch { raw = string.Empty; }
        }

        if (string.IsNullOrEmpty(raw)) return;

        // Debug pings from our injected shim (non-JSON), surface them verbatim.
        if (raw.StartsWith("__clippy_debug__:", StringComparison.Ordinal))
        {
            WidgetHostLogger.Log($"McpAppsHost[shim]: {raw.Substring("__clippy_debug__:".Length)}");
            return;
        }

        JsonDocument? doc = null;
        try
        {
            doc = JsonDocument.Parse(raw);
            var root = doc.RootElement;
            if (!root.TryGetProperty("method", out var methodElement) || methodElement.ValueKind != JsonValueKind.String)
            {
                WidgetHostLogger.Log("McpAppsHost: dropping inbound message without method.");
                return;
            }

            int? requestId = null;
            if (root.TryGetProperty("id", out var idElement) && idElement.ValueKind == JsonValueKind.Number && idElement.TryGetInt32(out var parsedId))
            {
                requestId = parsedId;
            }

            var method = methodElement.GetString();
            switch (method)
            {
                case "ui/initialize":
                    WidgetHostLogger.Log($"McpAppsHost[view]: {method} id={requestId?.ToString() ?? "null"}");
                    if (requestId.HasValue)
                    {
                        var rid = requestId.Value;
                        _ = PostInitializeResponseAsync(rid).ContinueWith(t =>
                        {
                            if (t.Exception != null)
                                WidgetHostLogger.Log($"McpAppsHost: PostInitializeResponseAsync failed: {t.Exception.GetBaseException().Message}");
                            else
                                WidgetHostLogger.Log($"McpAppsHost: posted initialize response for id={rid}");
                        }, TaskScheduler.Default);
                    }
                    break;

                case "ui/notifications/initialized":
                    WidgetHostLogger.Log($"McpAppsHost[view]: {method}");
                    try { ViewInitialized?.Invoke(this, EventArgs.Empty); }
                    catch (Exception ex)
                    {
                        WidgetHostLogger.Log($"McpAppsHost: ViewInitialized handler threw: {ex.Message}");
                    }
                    break;

                case "ui/notifications/size-changed":
                    WidgetHostLogger.Log($"McpAppsHost[view]: {method}");
                    break;

                case "tools/call":
                    HandleToolsCall(root, requestId);
                    break;

                case "resources/read":
                    _ = HandleResourceReadAsync(root, requestId);
                    break;

                case "resources/list":
                    _ = HandleResourceListAsync(requestId);
                    break;

                default:
                    WidgetHostLogger.Log($"McpAppsHost: dropping unknown view method {method}.");
                    break;
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: inbound parse failed: {ex.Message}");
        }
        finally
        {
            doc?.Dispose();
        }
    }

    private void HandleToolsCall(JsonElement envelope, int? requestId)
    {
        if (!envelope.TryGetProperty("params", out var paramsElement) || paramsElement.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        var toolName = paramsElement.TryGetProperty("name", out var nameElement) && nameElement.ValueKind == JsonValueKind.String
            ? nameElement.GetString() ?? string.Empty
            : string.Empty;
        if (string.IsNullOrEmpty(toolName)) return;

        var args = paramsElement.TryGetProperty("arguments", out var argsElement)
            ? argsElement.Clone()
            : JsonDocument.Parse("{}").RootElement;

        var call = new McpAppsToolCall(requestId, toolName, args);
        try { ToolCallRequested?.Invoke(this, call); }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: ToolCallRequested handler threw: {ex.Message}");
        }

        _ = BrokerToolCallAsync(call);
    }

    private async Task BrokerToolCallAsync(McpAppsToolCall call)
    {
        try
        {
            using var result = await _bridge.CallToolAsync(call.ToolName, call.Arguments, CancellationToken.None).ConfigureAwait(true);
            var envelope = BuildResponseEnvelope(call.RequestId, result.RootElement);
            await PostToViewAsync(envelope).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: tools/call broker failed for {call.ToolName}: {ex.Message}");
            await PostToViewAsync(BuildErrorEnvelope(call.RequestId, ex.Message)).ConfigureAwait(true);
        }
    }

    private async Task HandleResourceReadAsync(JsonElement envelope, int? requestId)
    {
        try
        {
            if (!envelope.TryGetProperty("params", out var paramsElement) ||
                !paramsElement.TryGetProperty("uri", out var uriElement) ||
                uriElement.ValueKind != JsonValueKind.String)
            {
                await PostToViewAsync(BuildErrorEnvelope(requestId, "resources/read requires params.uri")).ConfigureAwait(true);
                return;
            }
            using var result = await _bridge.ReadResourceAsync(uriElement.GetString()!, CancellationToken.None).ConfigureAwait(true);
            await PostToViewAsync(BuildResponseEnvelope(requestId, result.RootElement)).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            await PostToViewAsync(BuildErrorEnvelope(requestId, ex.Message)).ConfigureAwait(true);
        }
    }

    private async Task HandleResourceListAsync(int? requestId)
    {
        try
        {
            using var result = await _bridge.ListResourcesAsync(CancellationToken.None).ConfigureAwait(true);
            await PostToViewAsync(BuildResponseEnvelope(requestId, result.RootElement)).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            await PostToViewAsync(BuildErrorEnvelope(requestId, ex.Message)).ConfigureAwait(true);
        }
    }

    private static string BuildResponseEnvelope(int? requestId, JsonElement serverEnvelope)
    {
        // Node server already wraps responses in a {jsonrpc, id, result}
        // envelope. Forward its result element to the view so the view's
        // client sees a clean JSON-RPC reply correlated to its own id.
        var result = serverEnvelope.TryGetProperty("result", out var r) ? r.GetRawText() : "{}";
        if (requestId.HasValue)
        {
            return "{\"jsonrpc\":\"2.0\",\"id\":" + requestId.Value + ",\"result\":" + result + "}";
        }
        return "{\"jsonrpc\":\"2.0\",\"result\":" + result + "}";
    }

    private static string BuildErrorEnvelope(int? requestId, string message)
    {
        var err = "{\"code\":-32000,\"message\":" + JsonSerializer.Serialize(message) + "}";
        if (requestId.HasValue)
        {
            return "{\"jsonrpc\":\"2.0\",\"id\":" + requestId.Value + ",\"error\":" + err + "}";
        }
        return "{\"jsonrpc\":\"2.0\",\"error\":" + err + "}";
    }

    private static bool IsAllowedUri(string uri)
    {
        if (string.IsNullOrEmpty(uri)) return false;
        if (string.Equals(uri, "about:blank", StringComparison.OrdinalIgnoreCase)) return true;
        return uri.StartsWith(VirtualHostOrigin + "/", StringComparison.OrdinalIgnoreCase)
            || string.Equals(uri, VirtualHostOrigin, StringComparison.OrdinalIgnoreCase);
    }

    private static string TranslateUiUriToHttps(string uri)
    {
        if (uri.StartsWith(UiSchemePrefix, StringComparison.OrdinalIgnoreCase))
        {
            return VirtualHostOrigin + "/" + uri[UiSchemePrefix.Length..];
        }
        // Already https://clippy-ui.local/... passes through.
        if (uri.StartsWith(VirtualHostOrigin, StringComparison.OrdinalIgnoreCase))
        {
            return uri;
        }
        // Defensive: refuse everything else; serve the default fleet view.
        WidgetHostLogger.Log($"McpAppsHost: refusing unrecognized view URI {uri}; defaulting to fleet-status.");
        return VirtualHostOrigin + "/fleet-status.html";
    }

    private static string ResolveContentType(string filePath)
    {
        return Path.GetExtension(filePath).ToLowerInvariant() switch
        {
            ".html" or ".htm" => "text/html; charset=utf-8",
            ".js" => "text/javascript; charset=utf-8",
            ".css" => "text/css; charset=utf-8",
            ".json" => "application/json; charset=utf-8",
            ".svg" => "image/svg+xml",
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".woff" => "font/woff",
            ".woff2" => "font/woff2",
            _ => "application/octet-stream",
        };
    }

    private static bool HasViewFile(string folder)
    {
        try
        {
            return File.Exists(Path.Combine(folder, "fleet-status.html"));
        }
        catch { return false; }
    }

    private static string ResolveViewsFolder()
    {
        // Preferred: co-located with the widget build output.
        var baseDir = AppContext.BaseDirectory;
        var primary = Path.Combine(baseDir, "mcp-apps", "views");
        if (Directory.Exists(primary) && HasViewFile(primary))
        {
            return primary;
        }

        // Dev path: walking up to the repo root, find dist/mcp-apps/views.
        try
        {
            var current = new DirectoryInfo(baseDir);
            for (var i = 0; i < 8 && current is not null; i++)
            {
                var candidate = Path.Combine(current.FullName, "dist", "mcp-apps", "views");
                if (Directory.Exists(candidate) && HasViewFile(candidate))
                {
                    return candidate;
                }
                current = current.Parent;
            }
        }
        catch { }

        return primary;
    }

    private static string EnsureFallbackFolder()
    {
        var folder = Path.Combine(Path.GetTempPath(), "WindowsClippy", "mcp-apps-fallback");
        try
        {
            Directory.CreateDirectory(folder);
            var target = Path.Combine(folder, "fleet-status.html");
            if (!File.Exists(target))
            {
                File.WriteAllText(target, FallbackHtml, new UTF8Encoding(false));
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"McpAppsHost: fallback folder provisioning failed: {ex.Message}");
        }
        return folder;
    }

    private const string FallbackHtml =
        "<!doctype html>\n" +
        "<html lang=\"en\"><head><meta charset=\"utf-8\">" +
        "<title>Clippy Fleet Status</title>" +
        "<style>body{font:13px/1.4 'Segoe UI',sans-serif;margin:10px;color:#e8e8e8;background:#0c0c1c}" +
        ".warn{background:#3a1a1a;border:1px solid #7a3a3a;padding:8px;border-radius:6px}" +
        "h1{font-size:14px;margin:0 0 8px}</style></head><body>" +
        "<div class=\"warn\"><h1>VIEW BUNDLE MISSING</h1>" +
        "<p>dist/mcp-apps/views/fleet-status.html was not found. Run <code>npm run build:views</code> and redeploy the widget.</p></div>" +
        "</body></html>";

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(McpAppsHost));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { _webView.Dispose(); }
        catch (Exception ex) { WidgetHostLogger.Log($"McpAppsHost: dispose failed: {ex.Message}"); }
    }
}
