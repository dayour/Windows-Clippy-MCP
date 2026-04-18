using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace WidgetHost;

internal sealed record AgentDefinition(string Id, string DisplayName, string FilePath);

internal static class AgentCatalog
{
    private static readonly string[] IgnoredFileNames = ["README", "readme", "index"];
    private static readonly string[] PreferredDefaults = ["clippy-swe", "dayour-swe", "dayour", "dayswarm"];

    public static AgentDefinition[] DiscoverAgents()
    {
        EnsureBundledAgentsInstalled();

        var userAgentsDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".copilot",
            "agents");

        var bundledAgentsDir = GetBundledAgentsDir();

        var seen = new Dictionary<string, AgentDefinition>(StringComparer.OrdinalIgnoreCase);

        AppendFrom(userAgentsDir, seen);
        AppendFrom(bundledAgentsDir, seen);

        return seen.Values
            .OrderBy(a => a.Id, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static string? GetDefaultAgentId(AgentDefinition[] agents)
    {
        if (agents.Length == 0)
        {
            return null;
        }

        foreach (var candidate in PreferredDefaults)
        {
            if (agents.Any(a => a.Id.Equals(candidate, StringComparison.OrdinalIgnoreCase)))
            {
                return candidate;
            }
        }

        return agents[0].Id;
    }

    private static void AppendFrom(string? directory, IDictionary<string, AgentDefinition> accumulator)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            return;
        }

        try
        {
            foreach (var file in Directory.GetFiles(directory, "*.md"))
            {
                var name = Path.GetFileNameWithoutExtension(file);
                if (IgnoredFileNames.Contains(name, StringComparer.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (!accumulator.ContainsKey(name))
                {
                    accumulator[name] = new AgentDefinition(name, name, file);
                }
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Agent discovery failed for {directory}: {ex.Message}");
        }
    }

    private static string? GetBundledAgentsDir()
    {
        try
        {
            var baseDir = AppContext.BaseDirectory;
            var candidate = Path.Combine(baseDir, "agents");
            return Directory.Exists(candidate) ? candidate : null;
        }
        catch
        {
            return null;
        }
    }

    private static void EnsureBundledAgentsInstalled()
    {
        var bundled = GetBundledAgentsDir();
        if (bundled is null)
        {
            return;
        }

        var userDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".copilot",
            "agents");

        try
        {
            Directory.CreateDirectory(userDir);
            foreach (var src in Directory.GetFiles(bundled, "*.md"))
            {
                var name = Path.GetFileName(src);
                var dest = Path.Combine(userDir, name);
                if (!File.Exists(dest))
                {
                    File.Copy(src, dest, overwrite: false);
                    WidgetHostLogger.Log($"Installed bundled agent '{name}' to {dest}.");
                    continue;
                }

                if (!FileContentsMatch(src, dest))
                {
                    File.Copy(src, dest, overwrite: true);
                    WidgetHostLogger.Log($"Updated bundled agent '{name}' at {dest}.");
                }
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Bundled agent install skipped: {ex.Message}");
        }
    }

    private static bool FileContentsMatch(string leftPath, string rightPath)
    {
        try
        {
            return string.Equals(
                File.ReadAllText(leftPath),
                File.ReadAllText(rightPath),
                StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }
}

