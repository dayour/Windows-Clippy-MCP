using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WidgetHost;

internal sealed class WidgetToolSettings
{
    [JsonPropertyName("AllowAllTools")]
    public bool AllowAllTools { get; set; } = true;

    [JsonPropertyName("AllowAllPaths")]
    public bool AllowAllPaths { get; set; } = true;

    [JsonPropertyName("AllowAllUrls")]
    public bool AllowAllUrls { get; set; } = true;

    [JsonPropertyName("Experimental")]
    public bool Experimental { get; set; }

    [JsonPropertyName("Autopilot")]
    public bool Autopilot { get; set; }

    [JsonPropertyName("EnableAllGitHubMcpTools")]
    public bool EnableAllGitHubMcpTools { get; set; } = true;

    public WidgetToolSettings Clone() => new()
    {
        AllowAllTools = AllowAllTools,
        AllowAllPaths = AllowAllPaths,
        AllowAllUrls = AllowAllUrls,
        Experimental = Experimental,
        Autopilot = Autopilot,
        EnableAllGitHubMcpTools = EnableAllGitHubMcpTools
    };

    public int EnabledCount =>
        (AllowAllTools ? 1 : 0) +
        (AllowAllPaths ? 1 : 0) +
        (AllowAllUrls ? 1 : 0) +
        (Experimental ? 1 : 0) +
        (Autopilot ? 1 : 0) +
        (EnableAllGitHubMcpTools ? 1 : 0);

    public bool TrySet(string name, bool value)
    {
        switch (name)
        {
            case nameof(AllowAllTools):
                AllowAllTools = value;
                return true;
            case nameof(AllowAllPaths):
                AllowAllPaths = value;
                return true;
            case nameof(AllowAllUrls):
                AllowAllUrls = value;
                return true;
            case nameof(Experimental):
                Experimental = value;
                return true;
            case nameof(Autopilot):
                Autopilot = value;
                return true;
            case nameof(EnableAllGitHubMcpTools):
                EnableAllGitHubMcpTools = value;
                return true;
            default:
                return false;
        }
    }
}

internal sealed class WidgetExtensionSettings
{
    [JsonPropertyName("IncludeRegularSettings")]
    public bool IncludeRegularSettings { get; set; } = true;

    [JsonPropertyName("IncludeInsidersSettings")]
    public bool IncludeInsidersSettings { get; set; } = true;

    [JsonPropertyName("IncludeRegularExtensions")]
    public bool IncludeRegularExtensions { get; set; } = true;

    [JsonPropertyName("IncludeInsidersExtensions")]
    public bool IncludeInsidersExtensions { get; set; } = true;

    public WidgetExtensionSettings Clone() => new()
    {
        IncludeRegularSettings = IncludeRegularSettings,
        IncludeInsidersSettings = IncludeInsidersSettings,
        IncludeRegularExtensions = IncludeRegularExtensions,
        IncludeInsidersExtensions = IncludeInsidersExtensions
    };

    public int EnabledCount =>
        (IncludeRegularSettings ? 1 : 0) +
        (IncludeInsidersSettings ? 1 : 0) +
        (IncludeRegularExtensions ? 1 : 0) +
        (IncludeInsidersExtensions ? 1 : 0);

    public bool TrySet(string name, bool value)
    {
        switch (name)
        {
            case nameof(IncludeRegularSettings):
                IncludeRegularSettings = value;
                return true;
            case nameof(IncludeInsidersSettings):
                IncludeInsidersSettings = value;
                return true;
            case nameof(IncludeRegularExtensions):
                IncludeRegularExtensions = value;
                return true;
            case nameof(IncludeInsidersExtensions):
                IncludeInsidersExtensions = value;
                return true;
            default:
                return false;
        }
    }
}

internal sealed class WidgetSettings
{
    private static readonly string SettingsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Windows-Clippy-MCP");

    private static readonly string SettingsPath = Path.Combine(SettingsDirectory, "widget-settings.json");

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = null
    };

    [JsonPropertyName("Mode")]
    public string Mode { get; set; } = "Agent";

    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; set; } = "widget-settings/v1";

    [JsonPropertyName("Model")]
    public string Model { get; set; } = ModelCatalog.DefaultModelId;

    [JsonPropertyName("Agent")]
    public string? Agent { get; set; }

    [JsonPropertyName("Tools")]
    public WidgetToolSettings Tools { get; set; } = new();

    [JsonPropertyName("Extensions")]
    public WidgetExtensionSettings Extensions { get; set; } = new();

    [JsonPropertyName("LauncherLeft")]
    public double? LauncherLeft { get; set; }

    [JsonPropertyName("LauncherTop")]
    public double? LauncherTop { get; set; }

    [JsonPropertyName("VoiceLive")]
    public WidgetVoiceLiveSettings VoiceLive { get; set; } = new();

    public static WidgetSettings Load()
    {
        var settings = new WidgetSettings();

        try
        {
            if (!File.Exists(SettingsPath))
            {
                return settings;
            }

            var json = File.ReadAllText(SettingsPath);
            var loaded = JsonSerializer.Deserialize<WidgetSettings>(json, SerializerOptions) ?? new WidgetSettings();
            settings.SchemaVersion = string.IsNullOrWhiteSpace(loaded.SchemaVersion)
                ? "widget-settings/v1"
                : loaded.SchemaVersion;

            if (loaded.Mode is "Agent" or "Plan" or "Swarm")
            {
                settings.Mode = loaded.Mode;
            }

            if (!string.IsNullOrWhiteSpace(loaded.Model) && ModelCatalog.FindById(loaded.Model) is not null)
            {
                settings.Model = loaded.Model;
            }

            settings.Agent = loaded.Agent;
            settings.Tools = loaded.Tools ?? new WidgetToolSettings();
            settings.Extensions = loaded.Extensions ?? new WidgetExtensionSettings();
            settings.LauncherLeft = loaded.LauncherLeft;
            settings.LauncherTop = loaded.LauncherTop;
            settings.VoiceLive = loaded.VoiceLive ?? new WidgetVoiceLiveSettings();

            WidgetHostLogger.Log(
                $"Settings loaded: Mode={settings.Mode}; Model={settings.Model}; Agent={settings.Agent ?? "(none)"}; " +
                $"Tools={settings.Tools.EnabledCount}; Extensions={settings.Extensions.EnabledCount}");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Failed to load settings: {ex.Message}");
        }

        return settings;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SettingsDirectory);
            var json = JsonSerializer.Serialize(this, SerializerOptions);

            // Atomic write: write to temp, then move
            var tempPath = SettingsPath + ".tmp";
            File.WriteAllText(tempPath, json);
            File.Move(tempPath, SettingsPath, overwrite: true);

            WidgetHostLogger.Log(
                $"Settings saved: Mode={Mode}; Model={Model}; Agent={Agent ?? "(none)"}; " +
                $"Tools={Tools.EnabledCount}; Extensions={Extensions.EnabledCount}; " +
                $"Launcher=({LauncherLeft?.ToString("F0") ?? "auto"},{LauncherTop?.ToString("F0") ?? "auto"})");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Failed to save settings: {ex.Message}");
        }
    }
}

internal sealed class WidgetVoiceLiveSettings
{
    [JsonPropertyName("Enabled")]
    public bool Enabled { get; set; } = false;

    [JsonPropertyName("WssEndpoint")]
    public string WssEndpoint { get; set; } = "wss://eastus2.api.cognitive.microsoft.com";

    [JsonPropertyName("Model")]
    public string Model { get; set; } = "phi4-mm-realtime";

    [JsonPropertyName("TtsVoiceName")]
    public string TtsVoiceName { get; set; } = "en-US-AvaMultilingualNeural";

    /// <summary>
    /// Resolved at runtime from environment variables. Check registry scopes
    /// directly so a running shell does not need to be restarted after setting
    /// the User-scoped key.
    /// Never persisted to disk.
    /// </summary>
    [JsonIgnore]
    public string? ApiKey => ResolveApiKey();

    private static string? ResolveApiKey()
    {
        foreach (var name in new[] { "VOICELIVE_API_KEY", "COPILOT_DY_FOUNDRY_KEY" })
        {
            var value = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }

            value = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }

            value = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }
}

