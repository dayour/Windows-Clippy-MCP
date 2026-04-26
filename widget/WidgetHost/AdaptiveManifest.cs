using System;
using System.Collections.Generic;
using System.Linq;

namespace WidgetHost;

internal static class AdaptiveManifestProtocol
{
    public const string SchemaVersion = "adaptive-manifest/v1";
    public const string FleetStateSchemaVersion = "fleet-state/v1";

    public static IReadOnlyList<AdaptiveManifestEnvelope> BuildFleetManifests(
        CommanderSnapshot commander,
        IReadOnlyList<FleetTab> tabs,
        IReadOnlyList<FleetAgentCatalogEntry> agents)
    {
        var manifests = new List<AdaptiveManifestEnvelope>
        {
            BuildCommanderManifest(commander, agents)
        };

        foreach (var tab in tabs)
        {
            manifests.Add(BuildSessionManifest(tab, agents));
        }

        foreach (var agent in agents.Take(FleetStateSerializer.MaxAgents))
        {
            manifests.Add(BuildAgentManifest(agent));
        }

        return manifests;
    }

    private static AdaptiveManifestEnvelope BuildCommanderManifest(
        CommanderSnapshot commander,
        IReadOnlyList<FleetAgentCatalogEntry> agents)
    {
        var agent = FindAgent(agents, commander.Agent);
        var state = new AdaptiveManifestState(
            Lifecycle: commander.IsReady
                ? commander.IsBusy ? "thinking" : "ready"
                : "starting",
            Mode: commander.Mode,
            AgentId: commander.Agent,
            ModelId: commander.Model,
            IsBusy: commander.IsBusy,
            Error: commander.LastError,
            LatestPrompt: commander.LatestPrompt,
            LatestReply: commander.LatestReply,
            LatestToolSummary: commander.LatestToolSummary);

        var front = new[]
        {
            new AdaptiveFlipCardField("Session", commander.DisplayName),
            new AdaptiveFlipCardField("State", state.Lifecycle),
            new AdaptiveFlipCardField("Agent", NullIfEmpty(commander.Agent) ?? "(default)"),
            new AdaptiveFlipCardField("Model", commander.Model),
            new AdaptiveFlipCardField("Latest", FirstNonEmpty(commander.LatestToolSummary, commander.LatestReply, commander.LatestPrompt))
        };
        var back = BuildSchemaBackFields(agent);

        return new AdaptiveManifestEnvelope(
            SchemaVersion,
            "commander-session",
            commander.SessionId,
            "WidgetHost",
            DateTime.UtcNow.ToString("o"),
            state,
            new AdaptiveFlipCard("commander", "session-summary", "front", front, back),
            BuildRefs("agent", commander.Agent, "model", commander.Model),
            BuildAttachments(agent));
    }

    private static AdaptiveManifestEnvelope BuildSessionManifest(
        FleetTab tab,
        IReadOnlyList<FleetAgentCatalogEntry> agents)
    {
        var agent = FindAgent(agents, tab.AgentId);
        var isBusy = string.Equals(tab.Status, "working", StringComparison.OrdinalIgnoreCase);
        var state = new AdaptiveManifestState(
            Lifecycle: isBusy ? "thinking" : "ready",
            Mode: tab.Mode,
            AgentId: tab.AgentId,
            ModelId: tab.ModelId,
            IsBusy: isBusy,
            Error: string.Empty,
            LatestPrompt: string.Empty,
            LatestReply: string.Empty,
            LatestToolSummary: string.Empty);

        var front = new[]
        {
            new AdaptiveFlipCardField("Session", tab.DisplayName),
            new AdaptiveFlipCardField("State", state.Lifecycle),
            new AdaptiveFlipCardField("Agent", NullIfEmpty(tab.AgentId) ?? "(default)"),
            new AdaptiveFlipCardField("Mode", tab.Mode),
            new AdaptiveFlipCardField("Group", NullIfEmpty(tab.GroupLabel) ?? "none")
        };

        return new AdaptiveManifestEnvelope(
            SchemaVersion,
            "terminal-session",
            tab.TabKey,
            "WidgetHost",
            DateTime.UtcNow.ToString("o"),
            state,
            new AdaptiveFlipCard("terminal-session", "session-summary", "front", front, BuildSchemaBackFields(agent)),
            BuildSessionRefs(tab),
            BuildAttachments(agent));
    }

    private static AdaptiveManifestEnvelope BuildAgentManifest(FleetAgentCatalogEntry agent)
    {
        var state = new AdaptiveManifestState(
            Lifecycle: agent.IsActive ? "active" : "available",
            Mode: string.Empty,
            AgentId: agent.Id,
            ModelId: string.Empty,
            IsBusy: false,
            Error: string.Empty,
            LatestPrompt: string.Empty,
            LatestReply: string.Empty,
            LatestToolSummary: string.Empty);

        var front = new[]
        {
            new AdaptiveFlipCardField("Agent", agent.DisplayName),
            new AdaptiveFlipCardField("Source", agent.Source),
            new AdaptiveFlipCardField("Schema", agent.RelativePath),
            new AdaptiveFlipCardField("Hash", ShortHash(agent.ContentHash))
        };

        return new AdaptiveManifestEnvelope(
            SchemaVersion,
            "agent-schema",
            agent.Id,
            agent.Source,
            DateTime.UtcNow.ToString("o"),
            state,
            new AdaptiveFlipCard("agent-schema", "schema-reference", "front", front, BuildSchemaBackFields(agent)),
            BuildRefs("agent", agent.Id, "source", agent.Source),
            BuildAttachments(agent));
    }

    private static FleetAgentCatalogEntry? FindAgent(
        IReadOnlyList<FleetAgentCatalogEntry> agents,
        string? agentId)
    {
        if (string.IsNullOrWhiteSpace(agentId))
        {
            return null;
        }

        return agents.FirstOrDefault(a =>
            string.Equals(a.Id, agentId, StringComparison.OrdinalIgnoreCase));
    }

    private static IReadOnlyList<AdaptiveManifestAttachment> BuildAttachments(FleetAgentCatalogEntry? agent)
    {
        if (agent is null)
        {
            return Array.Empty<AdaptiveManifestAttachment>();
        }

        return new[]
        {
            new AdaptiveManifestAttachment(
                "agent-schema",
                agent.DisplayName,
                agent.RelativePath,
                agent.ContentHash,
                agent.PathPatterns)
        };
    }

    private static IReadOnlyList<AdaptiveFlipCardField> BuildSchemaBackFields(FleetAgentCatalogEntry? agent)
    {
        if (agent is null)
        {
            return Array.Empty<AdaptiveFlipCardField>();
        }

        var fields = new List<AdaptiveFlipCardField>
        {
            new("Schema", agent.RelativePath),
            new("Source", agent.Source),
            new("Hash", ShortHash(agent.ContentHash))
        };
        fields.AddRange(agent.PathPatterns.Take(4).Select((p, i) =>
            new AdaptiveFlipCardField($"Pattern {i + 1}", p)));
        return fields;
    }

    private static IReadOnlyList<AdaptiveManifestRef> BuildRefs(
        string firstKind,
        string? firstValue,
        string secondKind,
        string? secondValue)
    {
        var refs = new List<AdaptiveManifestRef>();
        if (!string.IsNullOrWhiteSpace(firstValue))
        {
            refs.Add(new AdaptiveManifestRef(firstKind, firstValue));
        }
        if (!string.IsNullOrWhiteSpace(secondValue))
        {
            refs.Add(new AdaptiveManifestRef(secondKind, secondValue));
        }
        return refs;
    }

    private static IReadOnlyList<AdaptiveManifestRef> BuildSessionRefs(FleetTab tab)
    {
        var refs = new List<AdaptiveManifestRef>
        {
            new("tabKey", tab.TabKey),
            new("sessionId", tab.SessionId)
        };
        if (!string.IsNullOrWhiteSpace(tab.AgentId))
        {
            refs.Add(new AdaptiveManifestRef("agent", tab.AgentId));
        }
        if (!string.IsNullOrWhiteSpace(tab.ModelId))
        {
            refs.Add(new AdaptiveManifestRef("model", tab.ModelId));
        }
        return refs;
    }

    private static string FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v)) ?? string.Empty;

    private static string? NullIfEmpty(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;

    private static string ShortHash(string? hash) =>
        string.IsNullOrWhiteSpace(hash) || hash.Length < 12
            ? string.Empty
            : hash[..12];
}

internal sealed record AdaptiveManifestEnvelope(
    string SchemaVersion,
    string ManifestType,
    string EntityId,
    string Source,
    string CapturedAt,
    AdaptiveManifestState State,
    AdaptiveFlipCard Card,
    IReadOnlyList<AdaptiveManifestRef> Refs,
    IReadOnlyList<AdaptiveManifestAttachment> Attachments);

internal sealed record AdaptiveManifestState(
    string Lifecycle,
    string Mode,
    string AgentId,
    string ModelId,
    bool IsBusy,
    string Error,
    string LatestPrompt,
    string LatestReply,
    string LatestToolSummary);

internal sealed record AdaptiveFlipCard(
    string CardId,
    string CardType,
    string DefaultFace,
    IReadOnlyList<AdaptiveFlipCardField> Front,
    IReadOnlyList<AdaptiveFlipCardField> Back);

internal sealed record AdaptiveFlipCardField(string Label, string Value);

internal sealed record AdaptiveManifestRef(string Kind, string Value);

internal sealed record AdaptiveManifestAttachment(
    string Kind,
    string Name,
    string RelativePath,
    string ContentHash,
    IReadOnlyList<string> PathPatterns);
