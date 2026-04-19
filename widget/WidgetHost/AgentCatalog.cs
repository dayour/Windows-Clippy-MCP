using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace WidgetHost;

internal sealed record AgentDefinition(string Id, string DisplayName, string FilePath, string Source);

internal static class AgentCatalog
{
    private static readonly string[] IgnoredFileNames = ["README", "readme", "index"];
    private static readonly string[] PreferredDefaults = ["clippy-swe", "dayour-swe", "dayour", "dayswarm"];
    internal const string UserSource = "user";
    internal const string BundledSource = "bundled";

    public static AgentDefinition[] DiscoverAgents()
    {
        EnsureBundledAgentsInstalled();

        var userAgentsDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".copilot",
            "agents");

        var bundledAgentsDir = GetBundledAgentsDir();

        var userAgents = ReadAgentFiles(userAgentsDir);
        var bundledAgents = ReadAgentFiles(bundledAgentsDir);
        var allIds = userAgents.Keys
            .Union(bundledAgents.Keys, StringComparer.OrdinalIgnoreCase)
            .OrderBy(id => id, StringComparer.OrdinalIgnoreCase);

        return allIds
            .Select(id => CreateDefinition(
                id,
                userAgents.TryGetValue(id, out var userPath) ? userPath : null,
                bundledAgents.TryGetValue(id, out var bundledPath) ? bundledPath : null))
            .Where(static definition => definition is not null)
            .Select(static definition => definition!)
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

    private static Dictionary<string, string> ReadAgentFiles(string? directory)
    {
        var agents = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            return agents;
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

                if (!agents.ContainsKey(name))
                {
                    agents[name] = file;
                }
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Agent discovery failed for {directory}: {ex.Message}");
        }

        return agents;
    }

    private static AgentDefinition? CreateDefinition(string id, string? userPath, string? bundledPath)
    {
        var filePath = userPath ?? bundledPath;
        if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(filePath))
        {
            return null;
        }

        var source = bundledPath is not null && (userPath is null || FileContentsMatch(userPath, bundledPath))
            ? BundledSource
            : UserSource;

        return new AgentDefinition(id, id, filePath, source);
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

