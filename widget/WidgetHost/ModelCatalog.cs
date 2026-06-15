using System;
using System.Linq;

namespace WidgetHost;

internal sealed record ModelDefinition(string Id, string DisplayName, string RateLabel);

internal static class ModelCatalog
{
    public static readonly ModelDefinition[] Models =
    [
        new("gpt-5.4", "GPT-5.4", "1x"),
        new("gpt-5.3-codex", "GPT-5.3-Codex", "1x"),
        new("gpt-5.2-codex", "GPT-5.2-Codex", "1x"),
        new("gpt-5.2", "GPT-5.2", "1x"),
        new("gpt-5.1-codex-max", "GPT-5.1-Codex-Max", "1x"),
        new("gpt-5.1-codex", "GPT-5.1-Codex", "1x"),
        new("gpt-5.1", "GPT-5.1", "1x"),
        new("gpt-5.1-codex-mini", "GPT-5.1-Codex-Mini (Preview)", "0.33x"),
        new("gpt-5-mini", "GPT-5 mini", "0x"),
        new("gpt-4.1", "GPT-4.1", "0x"),
        new("claude-sonnet-4.6", "Claude Sonnet 4.6", "1x"),
        new("claude-sonnet-4.5", "Claude Sonnet 4.5", "1x"),
        new("claude-haiku-4.5", "Claude Haiku 4.5", "0.33x"),
        new("claude-opus-4.6", "Claude Opus 4.6 (default)", "3x"),
        new("claude-opus-4.6-1m", "Claude Opus 4.6 (1M context)", "6x"),
        new("claude-opus-4.5", "Claude Opus 4.5", "3x"),
        new("claude-sonnet-4", "Claude Sonnet 4", "1x"),
        new("gemini-3-pro-preview", "Gemini 3 Pro (Preview)", "1x"),
    ];

    public const string DefaultModelId = "gpt-5.4";

    public static ModelDefinition? FindById(string? id)
    {
        if (string.IsNullOrWhiteSpace(id))
        {
            return null;
        }

        return Models.FirstOrDefault(m =>
            m.Id.Equals(id, StringComparison.OrdinalIgnoreCase));
    }
}
