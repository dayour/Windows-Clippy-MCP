// L3-4: FleetStateSnapshot — the single C# shape mirroring
// DEFAULT_SNAPSHOT in src/mcp-apps/bridge-state.mjs. This is written to
// %LOCALAPPDATA%\WindowsClippy\fleet-state.json by McpAppsBridge and
// read by the Node server's FleetState._readFromPath. Cap invariants
// are enforced both here (C# side, as defense in depth) and in
// bridge-state.mjs (server side, see L3-FW-1 in the tests).

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace WidgetHost;

internal sealed record FleetStateSnapshot(
    string Principal,
    string Session,
    string CapturedAt,
    FleetCounts Fleet,
    FleetTabs Tabs,
    FleetGroups Groups,
    FleetAgents Agents,
    CommanderSnapshot? Commander = null,
    IReadOnlyList<AdaptiveManifestEnvelope>? Manifests = null
);

internal sealed record CommanderSnapshot(
    string SessionId,
    string DisplayName,
    string Model,
    string Agent,
    string Mode,
    bool IsReady,
    bool IsBusy,
    string LatestPrompt,
    string LatestReply,
    string LatestToolSummary,
    string LastError,
    int HistoryCount,
    IReadOnlyList<CommanderHistoryEntry> History
);

internal sealed record CommanderHistoryEntry(string Role, string Text, string At);

internal sealed record FleetCounts(int Total, int Waiting, int Groups);

internal sealed record FleetTab(
    string TabKey,
    string DisplayName,
    string SessionId,
    string Mode,
    string AgentId,
    string ModelId,
    string GroupLabel,
    string Status
);

internal sealed record FleetTabs(IReadOnlyList<FleetTab> List);

internal sealed record FleetGroup(string Label, IReadOnlyList<FleetGroupMember> Members);

internal sealed record FleetGroupMember(
    string TabKey,
    string SessionId,
    string DisplayName);

internal sealed record FleetGroups(IReadOnlyList<FleetGroup> List);

internal sealed record FleetAgentCatalogEntry(
    string Id,
    string DisplayName,
    string FilePath,
    string Source,
    string RelativePath,
    string ContentHash,
    IReadOnlyList<string> PathPatterns,
    bool IsActive
);

internal sealed record FleetAgents(
    int CatalogSize,
    string Active,
    IReadOnlyList<FleetAgentCatalogEntry> Catalog
);

internal static class FleetStateSerializer
{
    // Mirror caps from bridge-state.mjs. See L3-FW-1 carry-forward.
    public const int MaxTabs = 256;
    public const int MaxGroups = 64;
    public const int MaxGroupMembers = 256;
    public const int MaxAgents = 500;
    public const int MaxStringLength = 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false,
    };

    public static string Serialize(FleetStateSnapshot snapshot)
    {
        // Principal is never configurable — coerce to literal "clippy".
        var normalized = new
        {
            schemaVersion = AdaptiveManifestProtocol.FleetStateSchemaVersion,
            principal = "clippy",
            sessionId = Clamp(snapshot.Session),
            tabs = new
            {
                total = snapshot.Fleet.Total,
                byState = new
                {
                    idle = Math.Max(0, snapshot.Fleet.Total - snapshot.Fleet.Waiting),
                    running = Math.Max(0, snapshot.Fleet.Waiting),
                    exited = 0,
                },
                list = snapshot.Tabs.List.Take(MaxTabs).Select(t => new
                {
                    tabKey = Clamp(t.TabKey),
                    displayName = Clamp(t.DisplayName),
                    sessionId = Clamp(t.SessionId),
                    mode = Clamp(t.Mode),
                    agentId = Clamp(t.AgentId),
                    modelId = Clamp(t.ModelId),
                    groupLabel = Clamp(t.GroupLabel),
                    status = Clamp(t.Status),
                }).ToArray(),
            },
            groups = new
            {
                total = snapshot.Fleet.Groups,
                active = (string?)null,
                list = snapshot.Groups.List.Take(MaxGroups).Select(g => new
                {
                    label = Clamp(g.Label),
                    members = g.Members.Take(MaxGroupMembers).Select(m => new
                    {
                        tabKey = Clamp(m.TabKey),
                        sessionId = Clamp(m.SessionId),
                        displayName = Clamp(m.DisplayName),
                    }).ToArray(),
                }).ToArray(),
            },
            agents = new
            {
                catalogSize = snapshot.Agents.CatalogSize,
                active = NullIfEmpty(snapshot.Agents.Active),
                catalog = snapshot.Agents.Catalog.Take(MaxAgents).Select(agent => new
                {
                    id = Clamp(agent.Id),
                    displayName = Clamp(agent.DisplayName),
                    filePath = Clamp(agent.FilePath),
                    source = Clamp(agent.Source),
                    relativePath = Clamp(agent.RelativePath),
                    contentHash = Clamp(agent.ContentHash),
                    pathPatterns = agent.PathPatterns.Take(16).Select(Clamp).ToArray(),
                    isActive = agent.IsActive,
                }).ToArray(),
            },
            commander = snapshot.Commander is null ? null : (object)new
            {
                sessionId = Clamp(snapshot.Commander.SessionId),
                displayName = Clamp(snapshot.Commander.DisplayName),
                model = Clamp(snapshot.Commander.Model),
                agent = Clamp(snapshot.Commander.Agent),
                mode = Clamp(snapshot.Commander.Mode),
                isReady = snapshot.Commander.IsReady,
                isBusy = snapshot.Commander.IsBusy,
                latestPrompt = Clamp(snapshot.Commander.LatestPrompt),
                latestReply = Clamp(snapshot.Commander.LatestReply),
                latestToolSummary = Clamp(snapshot.Commander.LatestToolSummary),
                lastError = Clamp(snapshot.Commander.LastError),
                historyCount = snapshot.Commander.HistoryCount,
                history = snapshot.Commander.History.Take(32).Select(h => new
                {
                    role = Clamp(h.Role),
                    text = Clamp(h.Text),
                    at = Clamp(h.At),
                }).ToArray(),
            },
            adaptiveManifestProtocol = new
            {
                schemaVersion = AdaptiveManifestProtocol.SchemaVersion,
                manifests = (snapshot.Manifests ?? Array.Empty<AdaptiveManifestEnvelope>())
                    .Take(MaxTabs + MaxAgents + 1)
                    .Select(ToManifest)
                    .ToArray(),
            },
            events = new { recent = Array.Empty<object>() },
            capturedAt = Clamp(snapshot.CapturedAt),
        };

        return JsonSerializer.Serialize(normalized, JsonOptions);
    }

    private static string Clamp(string? value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        return value.Length <= MaxStringLength ? value : value[..MaxStringLength];
    }

    private static string? NullIfEmpty(string? value)
    {
        var clamped = Clamp(value);
        return string.IsNullOrEmpty(clamped) ? null : clamped;
    }

    private static object ToManifest(AdaptiveManifestEnvelope manifest)
    {
        return new
        {
            schemaVersion = Clamp(manifest.SchemaVersion),
            manifestType = Clamp(manifest.ManifestType),
            entityId = Clamp(manifest.EntityId),
            source = Clamp(manifest.Source),
            capturedAt = Clamp(manifest.CapturedAt),
            state = new
            {
                lifecycle = Clamp(manifest.State.Lifecycle),
                mode = Clamp(manifest.State.Mode),
                agentId = Clamp(manifest.State.AgentId),
                modelId = Clamp(manifest.State.ModelId),
                isBusy = manifest.State.IsBusy,
                error = Clamp(manifest.State.Error),
                latestPrompt = Clamp(manifest.State.LatestPrompt),
                latestReply = Clamp(manifest.State.LatestReply),
                latestToolSummary = Clamp(manifest.State.LatestToolSummary),
            },
            card = new
            {
                cardId = Clamp(manifest.Card.CardId),
                cardType = Clamp(manifest.Card.CardType),
                defaultFace = Clamp(manifest.Card.DefaultFace),
                front = manifest.Card.Front.Take(32).Select(ToField).ToArray(),
                back = manifest.Card.Back.Take(32).Select(ToField).ToArray(),
            },
            refs = manifest.Refs.Take(32).Select(r => new
            {
                kind = Clamp(r.Kind),
                value = Clamp(r.Value),
            }).ToArray(),
            attachments = manifest.Attachments.Take(32).Select(a => new
            {
                kind = Clamp(a.Kind),
                name = Clamp(a.Name),
                relativePath = Clamp(a.RelativePath),
                contentHash = Clamp(a.ContentHash),
                pathPatterns = a.PathPatterns.Take(16).Select(Clamp).ToArray(),
            }).ToArray(),
        };
    }

    private static object ToField(AdaptiveFlipCardField field)
    {
        return new
        {
            label = Clamp(field.Label),
            value = Clamp(field.Value),
        };
    }
}
