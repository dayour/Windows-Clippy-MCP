using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Terminal.Wpf;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Threading;

namespace WidgetHost;

public partial class MainWindow : Window
{
    private sealed record MountedViewBinding(string ResourceUri, string ToolName);

    private static readonly string[] ValidModes = ["Agent", "Plan", "Swarm"];
    private const string DefaultMountedResourceUri = "ui://clippy/fleet-status.html";
    private static readonly (string Name, string Header)[] ToolMenuEntries =
    [
        (nameof(WidgetToolSettings.AllowAllTools), "Allow all tools"),
        (nameof(WidgetToolSettings.AllowAllPaths), "Allow all paths"),
        (nameof(WidgetToolSettings.AllowAllUrls), "Allow all URLs"),
        (nameof(WidgetToolSettings.Experimental), "Experimental"),
        (nameof(WidgetToolSettings.Autopilot), "Autopilot"),
        (nameof(WidgetToolSettings.EnableAllGitHubMcpTools), "Enable all GitHub MCP tools"),
    ];
    private static readonly (string Name, string Header)[] ExtensionMenuEntries =
    [
        (nameof(WidgetExtensionSettings.IncludeRegularSettings), "Include regular settings"),
        (nameof(WidgetExtensionSettings.IncludeInsidersSettings), "Include insiders settings"),
        (nameof(WidgetExtensionSettings.IncludeRegularExtensions), "Include regular extensions"),
        (nameof(WidgetExtensionSettings.IncludeInsidersExtensions), "Include insiders extensions"),
    ];
    private static readonly IReadOnlyDictionary<string, MountedViewBinding> MountedViewBindings =
        new Dictionary<string, MountedViewBinding>(StringComparer.OrdinalIgnoreCase)
        {
            [DefaultMountedResourceUri] = new(DefaultMountedResourceUri, "clippy.fleet-status"),
            ["ui://clippy/commander.html"] = new("ui://clippy/commander.html", "clippy.commander.state"),
            ["ui://clippy/agent-catalog.html"] = new("ui://clippy/agent-catalog.html", "clippy.agent-catalog"),
        };

    private readonly WidgetLaunchOptions _options;
    private readonly string _repoRoot;
    private readonly string _copilotConfigDir;
    private readonly List<TerminalTabSession> _sessions = [];
    private readonly CommanderHub _commanderHub = new();
    private readonly CommanderSession _commanderSession;
    private readonly WidgetSettings _settings;
    private readonly AgentDefinition[] _agents;
    private McpAppsBridge? _appsBridge;
    private McpAppsHost? _appsHost;
    private McpAppsHost? _secondaryAppsHost;
    private FleetStatusWindow? _fleetStatusWindow;
    private bool _allowClose;
    private bool _isShuttingDown;
    private bool _isSyncingUi;
    private string? _commanderNotice;

    public MainWindow(WidgetLaunchOptions options)
    {
        _options = options;
        _resourceUriCurrent = ResolveInitialMountedResourceUri(options);
        _repoRoot = ResolveRepoRoot();
        _copilotConfigDir = ResolveCopilotConfigDirectory();
        _settings = WidgetSettings.Load();
        _agents = AgentCatalog.DiscoverAgents();
        _commanderSession = new CommanderSession(_repoRoot, _copilotConfigDir)
        {
            Mode = _settings.Mode,
            AgentId = ResolveCommanderAgentId(_agents, _settings.Agent),
            ModelId = _settings.Model,
            ToolSettings = _settings.Tools.Clone()
        };
        _commanderSession.MetadataChanged += OnCommanderSessionMetadataChanged;
        _commanderSession.Exited += OnCommanderSessionExited;

        if (string.IsNullOrWhiteSpace(_settings.Agent))
        {
            _settings.Agent = AgentCatalog.GetDefaultAgentId(_agents);
        }

        _commanderSession.AgentId ??= _settings.Agent;

        InitializeComponent();
        PopulateCatalogs();
        SyncToolbarFromSettings();
        _commanderHub.GroupsChanged += OnCommanderHubGroupsChanged;
        _commanderHub.SessionRegistered += OnCommanderHubSessionChanged;
        _commanderHub.SessionUnregistered += OnCommanderHubSessionChanged;
        RefreshToolbarButtonLabels();
        UpdateSessionMeta();
        UpdateFleetStatusBadge();
        WidgetHostLogger.Log($"BenchWindow created. RepoRoot={_repoRoot}; ConfigDir={_copilotConfigDir}; Agents={_agents.Length}");
        Closing += OnClosing;
        InitializeMcpAppsHost();
    }

    public static IReadOnlyList<string> AvailableModes => ValidModes;

    internal IReadOnlyList<AgentDefinition> AvailableAgents => _agents;

    internal WidgetToolSettings ToolSettings => _settings.Tools;

    internal WidgetExtensionSettings ExtensionSettings => _settings.Extensions;

    public static WidgetLaunchOptions ParseArguments(IEnumerable<string> rawArgs)
    {
        var options = new WidgetLaunchOptions();
        using var enumerator = rawArgs.GetEnumerator();

        while (enumerator.MoveNext())
        {
            var current = enumerator.Current ?? string.Empty;
            if (!current.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            string key;
            string? value = null;
            var separatorIndex = current.IndexOf('=');
            if (separatorIndex >= 0)
            {
                key = current[..separatorIndex];
                value = current[(separatorIndex + 1)..];
            }
            else
            {
                key = current;
            }

            switch (key)
            {
                case "--open-chat":
                    options.OpenChat = true;
                    break;
                case "--no-welcome":
                    options.NoWelcome = true;
                    break;
                case "--session-id":
                    options.SessionId = value ?? RequireValue(key, enumerator);
                    break;
                case "--apps-view":
                    options.AppsViewUri = NormalizeAppsViewUri(value ?? RequireValue(key, enumerator));
                    break;
                default:
                    throw new ArgumentException($"Unsupported argument: {current}");
            }
        }

        return options;
    }

    private static string RequireValue(string key, IEnumerator<string> enumerator)
    {
        if (!enumerator.MoveNext() || string.IsNullOrWhiteSpace(enumerator.Current))
        {
            throw new ArgumentException($"{key} requires a value.");
        }

        return enumerator.Current;
    }

    private static string ResolveInitialMountedResourceUri(WidgetLaunchOptions options)
        => string.IsNullOrWhiteSpace(options.AppsViewUri)
            ? DefaultMountedResourceUri
            : NormalizeAppsViewUri(options.AppsViewUri);

    private static string NormalizeAppsViewUri(string resourceUri)
    {
        if (string.IsNullOrWhiteSpace(resourceUri))
        {
            throw new ArgumentException("--apps-view requires a ui://clippy/ uri.");
        }

        var normalized = resourceUri.Trim();
        if (!normalized.StartsWith("ui://clippy/", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException($"--apps-view only accepts ui://clippy/ URIs (got {resourceUri}).");
        }

        if (ResolveMountedViewBinding(normalized) is null)
        {
            var supported = string.Join(", ", MountedViewBindings.Keys.OrderBy(static key => key, StringComparer.OrdinalIgnoreCase));
            throw new ArgumentException($"--apps-view only supports mounted Clippy views: {supported}");
        }

        return normalized;
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            HideBench();
            return;
        }

        _isShuttingDown = true;
        WidgetHostLogger.Log("BenchWindow closing. Disposing terminal sessions.");
        SaveSettingsFromActiveTab();
        _commanderSession.MetadataChanged -= OnCommanderSessionMetadataChanged;
        _commanderSession.Exited -= OnCommanderSessionExited;
        _commanderHub.GroupsChanged -= OnCommanderHubGroupsChanged;
        _commanderHub.SessionRegistered -= OnCommanderHubSessionChanged;
        _commanderHub.SessionUnregistered -= OnCommanderHubSessionChanged;

        try { _appsHost?.Dispose(); }
        catch (Exception ex) { WidgetHostLogger.Log($"McpAppsHost dispose warn: {ex.Message}"); }
        try { _fleetStatusWindow?.Close(); }
        catch (Exception ex) { WidgetHostLogger.Log($"FleetStatusWindow close warn: {ex.Message}"); }
        if (_appsBridge is not null)
        {
            try { _appsBridge.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(3)); }
            catch (Exception ex) { WidgetHostLogger.Log($"McpAppsBridge dispose warn: {ex.Message}"); }
        }

        try { StopVoiceAsync().Wait(TimeSpan.FromSeconds(2)); }
        catch (Exception ex) { WidgetHostLogger.Log($"VoiceLive dispose warn: {ex.Message}"); }

        try { StopLiveAiAsync().Wait(TimeSpan.FromSeconds(2)); }
        catch (Exception ex) { WidgetHostLogger.Log($"LiveAI dispose warn: {ex.Message}"); }

        foreach (var session in _sessions.ToArray())
        {
            _commanderHub.Unregister(session);
            session.Dispose();
        }

        _sessions.Clear();
        _commanderSession.Dispose();
    }

    // ── Catalog population ───────────────────────────────────────

    private void PopulateCatalogs()
    {
        _isSyncingUi = true;
        try
        {
            AgentSelector.Items.Clear();
            if (_agents.Length == 0)
            {
                var placeholder = new ComboBoxItem
                {
                    Content = "No agents found",
                    Tag = string.Empty,
                    IsEnabled = false
                };
                AgentSelector.Items.Add(placeholder);
                AgentSelector.IsEnabled = false;
            }
            else
            {
                AgentSelector.IsEnabled = true;
                foreach (var agent in _agents)
                {
                    AgentSelector.Items.Add(new ComboBoxItem
                    {
                        Content = agent.DisplayName,
                        Tag = agent.Id,
                        ToolTip = AgentCatalog.BuildPortableTooltip(agent)
                    });
                }
            }

            ModelSelector.Items.Clear();
            foreach (var model in ModelCatalog.Models)
            {
                ModelSelector.Items.Add(new ComboBoxItem
                {
                    Content = model.DisplayName,
                    Tag = model.Id,
                    ToolTip = $"Rate: {model.RateLabel}"
                });
            }
        }
        finally
        {
            _isSyncingUi = false;
        }
    }

    private void SyncToolbarFromSettings()
    {
        _isSyncingUi = true;
        try
        {
            SelectComboBoxByTag(AgentSelector, _settings.Agent);
            SelectComboBoxByTag(ModelSelector, _settings.Model);
            SetModeToggle(_settings.Mode);
        }
        finally
        {
            _isSyncingUi = false;
        }
    }

    private void SyncToolbarFromSelectedTab()
    {
        _isSyncingUi = true;
        try
        {
            SelectComboBoxByTag(AgentSelector, _settings.Agent);
            SelectComboBoxByTag(ModelSelector, _settings.Model);
            SetModeToggle(_settings.Mode);
        }
        finally
        {
            _isSyncingUi = false;
        }

        UpdateSessionMeta();
    }

    private void SetModeToggle(string mode)
    {
        ModeAgentToggle.IsChecked = mode == "Agent";
        ModePlanToggle.IsChecked = mode == "Plan";
        ModeSwarmToggle.IsChecked = mode == "Swarm";
    }

    private static void SelectComboBoxByTag(System.Windows.Controls.ComboBox combo, string? tagValue)
    {
        if (string.IsNullOrWhiteSpace(tagValue))
        {
            return;
        }

        for (var i = 0; i < combo.Items.Count; i++)
        {
            if (combo.Items[i] is ComboBoxItem item &&
                string.Equals(item.Tag as string, tagValue, StringComparison.OrdinalIgnoreCase))
            {
                combo.SelectedIndex = i;
                return;
            }
        }
    }

    private void UpdateSessionMeta(TerminalTabSession? session = null)
    {
        if (session is null && Tabs.SelectedItem is TabItem tab && tab.Tag is TerminalTabSession selected)
        {
            session = selected;
        }

        var commanderStatus = !_commanderSession.IsReady
            ? "Starting"
            : _commanderSession.IsWaitingForResponse ? "Working" : "Idle";

        if (session is not null)
        {
            var shortId = session.SessionId.Length > 8
                ? session.SessionId[..8]
                : session.SessionId;
            var tabStatus = session.IsWaitingForResponse ? "Working" : "Idle";
            var groupLabel = string.IsNullOrWhiteSpace(session.GroupLabel)
                ? "none"
                : session.GroupLabel;
            if (SessionMeta.Visibility == Visibility.Visible)
            {
                SessionMeta.Text =
                    $"Session {shortId}  Card: {session.CardKind}  Mode: {session.Mode}  Agent: {ResolveAgentDisplayName(session.AgentId)}  Model: {ResolveModelDisplayName(session.ModelId)}  Tab: {tabStatus}  Commander: {commanderStatus}  Group: {groupLabel}  Fleet: {_commanderHub.SessionCount} tabs / {_commanderHub.WaitingCount} working / {_commanderHub.GroupCount} groups";
            }
            AttachmentMeta.Text = BuildSessionDetailSummary(session);
        }
        else
        {
            if (SessionMeta.Visibility == Visibility.Visible)
            {
                SessionMeta.Text =
                    $"No active session  Commander: {commanderStatus}  Fleet: {_commanderHub.SessionCount} tabs / {_commanderHub.WaitingCount} working / {_commanderHub.GroupCount} groups";
            }
            AttachmentMeta.Text = BuildSessionDetailSummary(null);
        }
    }

    private string BuildSessionDetailSummary(TerminalTabSession? session)
    {
        var details = new List<string>();

        if (!string.IsNullOrWhiteSpace(_commanderNotice))
        {
            details.Add(_commanderNotice);
        }

        if (!string.IsNullOrWhiteSpace(_commanderSession.LatestPromptPreview))
        {
            details.Add($"Commander latest: {_commanderSession.LatestPromptPreview}");
        }

        if (!string.IsNullOrWhiteSpace(_commanderSession.LatestToolSummary))
        {
            details.Add($"Commander tool: {_commanderSession.LatestToolSummary}");
        }

        if (!string.IsNullOrWhiteSpace(_commanderSession.LatestTranscriptPreview))
        {
            details.Add($"Commander reply: {_commanderSession.LatestTranscriptPreview}");
        }

        if (!string.IsNullOrWhiteSpace(_commanderSession.LastErrorMessage))
        {
            details.Add($"Commander error: {_commanderSession.LastErrorMessage}");
        }

        if (_commanderSession.HistoryCount > 0)
        {
            details.Add($"Commander history: {_commanderSession.BuildHistorySummary(4)}");
        }

        if (session is not null && !string.IsNullOrWhiteSpace(session.LatestToolSummary))
        {
            details.Add($"Tab tool: {session.LatestToolSummary}");
        }

        if (session is not null && !string.IsNullOrWhiteSpace(session.LatestTranscriptPreview))
        {
            details.Add($"Tab preview: {session.LatestTranscriptPreview}");
        }

        if (session is not null && !string.IsNullOrWhiteSpace(session.LastErrorMessage))
        {
            details.Add($"Tab error: {session.LastErrorMessage}");
        }

        details.Add("Files: no user files attached");
        details.Add("Adaptive manifest: v1 flipcards include agent schema refs and path patterns");
        details.Add($"Tools: {_settings.Tools.EnabledCount} enabled");
        details.Add($"Extensions: {_settings.Extensions.EnabledCount} enabled");
        return string.Join("  ", details);
    }

    private void SetCommanderNotice(string? notice)
    {
        _commanderNotice = string.IsNullOrWhiteSpace(notice)
            ? null
            : notice.Trim();
        UpdateSessionMeta();
    }

    private void SaveSettingsFromActiveTab()
    {
        _settings.Save();
    }

    // ── Toolbar event handlers ───────────────────────────────────

    private void OnAgentSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isSyncingUi)
        {
            return;
        }

        if (AgentSelector.SelectedItem is not ComboBoxItem item || item.Tag is not string agentId || string.IsNullOrEmpty(agentId))
        {
            return;
        }

        ApplyAgent(agentId, syncToolbar: false);
    }

    private void OnModelSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isSyncingUi)
        {
            return;
        }

        if (ModelSelector.SelectedItem is not ComboBoxItem item || item.Tag is not string modelId || string.IsNullOrEmpty(modelId))
        {
            return;
        }

        ApplyModel(modelId, syncToolbar: false);
    }

    private void OnModeToggleChecked(object sender, RoutedEventArgs e)
    {
        if (_isSyncingUi)
        {
            return;
        }

        if (sender is not ToggleButton toggle || toggle.Tag is not string mode || !ValidModes.Contains(mode))
        {
            return;
        }

        ApplyMode(mode, syncToolbar: false);
    }

    private void OnToolsBtnClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement anchor)
        {
            OpenToolsMenu(anchor);
        }
    }

    private void OnExtBtnClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement anchor)
        {
            OpenExtensionsMenu(anchor);
        }
    }

    // ── Input handling ───────────────────────────────────────────

    private async void OnSendClick(object sender, RoutedEventArgs e)
    {
        await SubmitInputToActiveTabAsync();
    }

    private async void OnInputKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (SlashPopup.IsOpen)
        {
            switch (e.Key)
            {
                case Key.Down:
                    e.Handled = true;
                    MoveSlashPopupSelection(+1);
                    return;
                case Key.Up:
                    e.Handled = true;
                    MoveSlashPopupSelection(-1);
                    return;
                case Key.Tab:
                case Key.Enter:
                    e.Handled = true;
                    AcceptSlashSuggestion();
                    return;
                case Key.Escape:
                    e.Handled = true;
                    SlashPopup.IsOpen = false;
                    return;
            }
        }

        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            await SubmitInputToActiveTabAsync();
        }
    }

    private void OnInputBoxTextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        var text = InputBox.Text;
        if (!text.StartsWith('/'))
        {
            SlashPopup.IsOpen = false;
            return;
        }

        var suggestions = GetSlashSuggestions(text);
        if (suggestions.Count == 0)
        {
            SlashPopup.IsOpen = false;
            return;
        }

        SlashPopupList.ItemsSource = suggestions;
        SlashPopupList.SelectedIndex = 0;
        SlashPopup.MinWidth = InputBox.ActualWidth;
        SlashPopup.IsOpen = true;
    }

    private System.Collections.Generic.List<SlashSuggestion> GetSlashSuggestions(string text)
    {
        var spaceIdx = text.IndexOf(' ');
        if (spaceIdx < 0)
        {
            // Completing root command name (e.g. "/ag" -> /agent, /mcp ...)
            return [.. SlashCommandCatalog.RootCommands
                .Where(c => c.Command.StartsWith(text, StringComparison.OrdinalIgnoreCase))];
        }

        var cmd = text[..spaceIdx].ToLowerInvariant();
        var partial = text[(spaceIdx + 1)..];

        return cmd switch
        {
            "/mode" => [.. ValidModes
                .Select(static mode => mode.ToLowerInvariant())
                .Where(mode => mode.StartsWith(partial, StringComparison.OrdinalIgnoreCase))
                .Select(mode => new SlashSuggestion(mode, "Commander mode"))],

            "/agent" => [.. _agents
                .Where(a => a.Id.StartsWith(partial, StringComparison.OrdinalIgnoreCase))
                .Select(a => new SlashSuggestion(a.Id, a.DisplayName))],

            "/model" => [.. ModelCatalog.Models
                .Where(m => m.Id.StartsWith(partial, StringComparison.OrdinalIgnoreCase))
                .Select(m => new SlashSuggestion(m.Id, $"{m.DisplayName}  ({m.RateLabel})"))],

            "/mcp" => [.. SlashCommandCatalog.McpServers
                .Where(s => s.StartsWith(partial, StringComparison.OrdinalIgnoreCase))
                .Select(s => new SlashSuggestion(s, "MCP server"))],

            "/skill" => [.. SlashCommandCatalog.Skills
                .Where(s => s.StartsWith(partial, StringComparison.OrdinalIgnoreCase))
                .Select(s => new SlashSuggestion(s, "Copilot skill"))],

            "/files" => [.. new[] { "clear" }
                .Where(option => option.StartsWith(partial, StringComparison.OrdinalIgnoreCase))
                .Select(option => new SlashSuggestion(option, "Clear local attachments"))],

            _ => []
        };
    }

    private void MoveSlashPopupSelection(int delta)
    {
        if (SlashPopupList.Items.Count == 0) return;
        var current = SlashPopupList.SelectedIndex < 0 ? 0 : SlashPopupList.SelectedIndex;
        var next = Math.Clamp(current + delta, 0, SlashPopupList.Items.Count - 1);
        SlashPopupList.SelectedIndex = next;
        SlashPopupList.ScrollIntoView(SlashPopupList.SelectedItem);
    }

    private void AcceptSlashSuggestion()
    {
        if (SlashPopupList.SelectedItem is not SlashSuggestion suggestion)
        {
            SlashPopup.IsOpen = false;
            return;
        }

        var text = InputBox.Text;
        var spaceIdx = text.IndexOf(' ');

        string newText;
        if (spaceIdx < 0)
        {
            // Completing the command name — append space if it takes an argument
            newText = suggestion.HasArgument ? suggestion.Command + " " : suggestion.Command;
        }
        else
        {
            // Completing an argument (agent id, model id, mcp name, skill name)
            newText = text[..spaceIdx] + " " + suggestion.Command;
        }

        InputBox.Text = newText;
        InputBox.CaretIndex = newText.Length;
        SlashPopup.IsOpen = false;
        InputBox.Focus();
    }

    private void OnSlashPopupListMouseUp(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        AcceptSlashSuggestion();
    }

    private async Task SubmitInputToActiveTabAsync()
    {
        var text = InputBox.Text;
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        var session = ResolveSelectedSession();
        var commandResult = await TryHandleCommanderCommandAsync(text, session);
        if (commandResult.Handled)
        {
            InputBox.Clear();
            SlashPopup.IsOpen = false;
            if (commandResult.RefocusInput)
            {
                InputBox.Focus();
            }
            UpdateSessionMeta();
            return;
        }

        await EnsureCommanderInitializedAsync();
        SetCommanderNotice(null);
        var dispatchResult = _commanderSession.TrySubmitPrompt(text);
        if (dispatchResult != CommanderDispatchResult.Delivered)
        {
            var message = dispatchResult switch
            {
                CommanderDispatchResult.Busy => "WARNING: Commander is still working on the previous turn.",
                CommanderDispatchResult.NotReady => "WARNING: Commander is still starting. Try again in a moment.",
                CommanderDispatchResult.Disposed => "ERROR: Commander session is unavailable.",
                _ => "WARNING: Commander could not accept that prompt."
            };
            SetCommanderNotice(message);
            UpdateStatus("Commander prompt was not accepted.");
            UpdateSessionMeta(session);
            return;
        }

        InputBox.Clear();
        SlashPopup.IsOpen = false;
        InputBox.Focus();
        UpdateSessionMeta(session);
        UpdateStatus("Commander prompt submitted.");
        WidgetHostLogger.Log($"Commander prompt submitted to dedicated session: {(text.Length > 80 ? text[..80] + "..." : text)}");
    }

    private async Task<(bool Handled, bool RefocusInput)> TryHandleCommanderCommandAsync(string inputText, TerminalTabSession? session)
    {
        var text = inputText.Trim();
        if (!text.StartsWith("/", StringComparison.Ordinal))
        {
            return (false, true);
        }

        if (text.Equals("/new", StringComparison.OrdinalIgnoreCase))
        {
            await AddTabAsync();
            SetCommanderNotice("Opened a fresh Clippy bench tab.");
            UpdateStatus("Opened a fresh Clippy tab.");
            return (true, true);
        }

        if (text.Equals("/session", StringComparison.OrdinalIgnoreCase))
        {
            var activeLabel = session is null
                ? $"Commander {GetShortSessionId(_commanderSession.SessionId)} is active. No tab is selected."
                : $"Commander {GetShortSessionId(_commanderSession.SessionId)} is active. Bench tab {GetShortSessionId(session.SessionId)} is selected.";
            SetCommanderNotice(activeLabel);
            UpdateStatus(activeLabel);
            return (true, true);
        }

        if (text.Equals("/help", StringComparison.OrdinalIgnoreCase) || text.Equals("/?", StringComparison.OrdinalIgnoreCase))
        {
            var helpText = "Commander commands: /new, /session, /mode <agent|plan|swarm>, /agent <name>, /agents, /model <name>, /tools, /extensions, /files, /link <label>, /unlink, /groups, /broadcast <text>, /group <text>. Other slash commands pass through to the active Copilot tab.";
            SetCommanderNotice(helpText);
            UpdateStatus("Commander help ready.");
            return (true, true);
        }

        if (text.Equals("/tools", StringComparison.OrdinalIgnoreCase))
        {
            OpenToolsMenu(ToolsBtn);
            SetCommanderNotice($"Tool settings opened. {_settings.Tools.EnabledCount} enabled.");
            UpdateStatus("Tool settings opened.");
            return (true, false);
        }

        if (text.Equals("/extensions", StringComparison.OrdinalIgnoreCase))
        {
            OpenExtensionsMenu(ExtBtn);
            SetCommanderNotice($"Extension settings opened. {_settings.Extensions.EnabledCount} enabled.");
            UpdateStatus("Extension settings opened.");
            return (true, false);
        }

        if (text.Equals("/files", StringComparison.OrdinalIgnoreCase))
        {
            SetCommanderNotice("No files are attached to this Commander session.");
            UpdateStatus("No Commander files attached.");
            return (true, true);
        }

        if (text.Equals("/files clear", StringComparison.OrdinalIgnoreCase))
        {
            SetCommanderNotice("No attached files were present to clear.");
            UpdateStatus("Commander attachments cleared.");
            return (true, true);
        }

        if (text.Equals("/agents", StringComparison.OrdinalIgnoreCase))
        {
            var agentSummary = _agents.Length == 0
                ? "No agents were found in ~/.copilot/agents."
                : $"Available agents: {string.Join(", ", _agents.Select(static agent => agent.DisplayName))}";
            SetCommanderNotice(agentSummary);
            UpdateStatus("Agent catalog ready.");
            return (true, true);
        }

        if (TryParseSlashArgument(text, "/mode", out var modeToken))
        {
            var normalizedMode = ValidModes.FirstOrDefault(mode =>
                mode.Equals(modeToken, StringComparison.OrdinalIgnoreCase));
            if (normalizedMode is null)
            {
                SetCommanderNotice("ERROR: Unknown mode. Use /mode agent, /mode plan, or /mode swarm.");
                UpdateStatus("Unknown Commander mode.");
                return (true, true);
            }

            ApplyMode(normalizedMode, syncToolbar: true);
            SetCommanderNotice($"Mode set to {normalizedMode}.");
            UpdateStatus($"Commander mode set to {normalizedMode}.");
            return (true, true);
        }

        if (TryParseSlashArgument(text, "/agent", out var agentToken))
        {
            var resolvedAgent = ResolveAgentToken(agentToken);
            if (resolvedAgent is null)
            {
                SetCommanderNotice($"ERROR: Unknown agent '{agentToken}'.");
                UpdateStatus("Unknown agent.");
                return (true, true);
            }

            ApplyAgent(resolvedAgent.Id, syncToolbar: true);
            SetCommanderNotice($"Agent set to {resolvedAgent.DisplayName}.");
            UpdateStatus($"Active agent set to {resolvedAgent.DisplayName}.");
            return (true, true);
        }

        if (TryParseSlashArgument(text, "/model", out var modelToken))
        {
            var resolvedModel = ResolveModelToken(modelToken);
            if (resolvedModel is null)
            {
                SetCommanderNotice($"ERROR: Unknown model '{modelToken}'.");
                UpdateStatus("Unknown model.");
                return (true, true);
            }

            ApplyModel(resolvedModel.Id, syncToolbar: true);
            SetCommanderNotice($"Model set to {resolvedModel.DisplayName}.");
            UpdateStatus($"Active model set to {resolvedModel.DisplayName}.");
            return (true, true);
        }

        if (TryParseSlashArgument(text, "/link", out var linkLabel))
        {
            if (session is null)
            {
                SetCommanderNotice("ERROR: No active tab to link.");
                UpdateStatus("No active tab to link.");
                return (true, true);
            }

            if (_appsBridge is null)
            {
                SetCommanderNotice("ERROR: MCP Apps bridge unavailable; /link requires the Apps sidecar.");
                UpdateStatus("Apps bridge unavailable for /link.");
                return (true, true);
            }

            if (string.IsNullOrWhiteSpace(linkLabel))
            {
                SetCommanderNotice("ERROR: /link requires a group label.");
                UpdateStatus("Link missing label.");
                return (true, true);
            }
            try
            {
                await _appsBridge.PublishIntentAsync(new
                {
                    kind = "linkgroup.link",
                    sessionId = session.SessionId.ToString(),
                    label = linkLabel
                }).ConfigureAwait(true);
                SetCommanderNotice($"Link intent queued: {session.DisplayName} -> '{linkLabel}'.");
                UpdateStatus($"Link intent queued for '{linkLabel}'.");
            }
            catch (Exception ex)
            {
                SetCommanderNotice($"ERROR: link publish failed: {ex.Message}");
                UpdateStatus("Link publish failed.");
            }
            return (true, true);
        }

        if (text.Equals("/unlink", StringComparison.OrdinalIgnoreCase))
        {
            if (session is null)
            {
                SetCommanderNotice("ERROR: No active tab to unlink.");
                UpdateStatus("No active tab to unlink.");
                return (true, true);
            }

            if (_appsBridge is null)
            {
                SetCommanderNotice("ERROR: MCP Apps bridge unavailable; /unlink requires the Apps sidecar.");
                UpdateStatus("Apps bridge unavailable for /unlink.");
                return (true, true);
            }

            try
            {
                await _appsBridge.PublishIntentAsync(new
                {
                    kind = "linkgroup.unlink",
                    sessionId = session.SessionId.ToString()
                }).ConfigureAwait(true);
                SetCommanderNotice($"Unlink intent queued for {session.DisplayName}.");
                UpdateStatus("Unlink intent queued.");
            }
            catch (Exception ex)
            {
                SetCommanderNotice($"ERROR: unlink publish failed: {ex.Message}");
                UpdateStatus("Unlink publish failed.");
            }
            return (true, true);
        }

        if (text.Equals("/groups", StringComparison.OrdinalIgnoreCase))
        {
            var groups = _commanderHub.DescribeGroups();
            if (groups.Count == 0)
            {
                SetCommanderNotice("No Commander link groups defined.");
                UpdateStatus("No link groups.");
                return (true, true);
            }

            var summary = string.Join("; ", groups.Select(kv => $"{kv.Key}: {string.Join(", ", kv.Value)}"));
            SetCommanderNotice($"Groups: {summary}");
            UpdateStatus($"{groups.Count} link group(s).");
            return (true, true);
        }

        if (TryParseSlashArgument(text, "/broadcast", out var broadcastText))
        {
            if (string.IsNullOrWhiteSpace(broadcastText))
            {
                SetCommanderNotice("ERROR: /broadcast requires prompt text.");
                UpdateStatus("Broadcast missing text.");
                return (true, true);
            }

            if (_commanderHub.SessionCount == 0)
            {
                SetCommanderNotice("No tabs registered for broadcast.");
                UpdateStatus("Broadcast had no targets.");
                return (true, true);
            }

            if (_appsBridge is null)
            {
                SetCommanderNotice("ERROR: MCP Apps bridge unavailable; /broadcast requires the Apps sidecar.");
                UpdateStatus("Apps bridge unavailable for /broadcast.");
                return (true, true);
            }

            try
            {
                await _appsBridge.PublishIntentAsync(new
                {
                    kind = "broadcast.send",
                    prompt = broadcastText,
                    targets = new { mode = "all" }
                }).ConfigureAwait(true);
                SetCommanderNotice($"Broadcast intent queued ({_commanderHub.SessionCount} tab target{(_commanderHub.SessionCount == 1 ? "" : "s")}).");
                UpdateStatus("Broadcast intent queued.");
                WidgetHostLogger.Log($"Commander broadcast (via intent) to {_commanderHub.SessionCount} tab(s): {broadcastText}");
            }
            catch (Exception ex)
            {
                SetCommanderNotice($"ERROR: broadcast publish failed: {ex.Message}");
                UpdateStatus("Broadcast publish failed.");
            }
            return (true, true);
        }

        if (TryParseSlashArgument(text, "/group", out var groupText))
        {
            if (session is null)
            {
                SetCommanderNotice("ERROR: No active tab; cannot resolve group.");
                UpdateStatus("No active tab for /group.");
                return (true, true);
            }

            var label = _commanderHub.GetGroupLabel(session);
            if (string.IsNullOrEmpty(label))
            {
                SetCommanderNotice($"ERROR: {session.DisplayName} is not in a link group. Use /link <label> first.");
                UpdateStatus("Active tab has no group.");
                return (true, true);
            }

            if (string.IsNullOrWhiteSpace(groupText))
            {
                SetCommanderNotice("ERROR: /group requires prompt text.");
                UpdateStatus("Group prompt missing text.");
                return (true, true);
            }

            if (_appsBridge is null)
            {
                SetCommanderNotice("ERROR: MCP Apps bridge unavailable; /group requires the Apps sidecar.");
                UpdateStatus("Apps bridge unavailable for /group.");
                return (true, true);
            }

            try
            {
                await _appsBridge.PublishIntentAsync(new
                {
                    kind = "broadcast.send",
                    prompt = groupText,
                    targets = new { mode = "group", label }
                }).ConfigureAwait(true);
                SetCommanderNotice($"Group broadcast intent queued for '{label}'.");
                UpdateStatus($"Group '{label}' intent queued.");
                WidgetHostLogger.Log($"Commander group '{label}' dispatch (via intent): {groupText}");
            }
            catch (Exception ex)
            {
                SetCommanderNotice($"ERROR: group publish failed: {ex.Message}");
                UpdateStatus("Group publish failed.");
            }
            return (true, true);
        }

        if (text.Equals("/apps-dev", StringComparison.OrdinalIgnoreCase))
        {
            return (await ToggleAppsDevAsync(), true);
        }

        if (text.Equals("/apps", StringComparison.OrdinalIgnoreCase))
        {
            SetCommanderNotice("Usage: /apps list | /apps mount <uri> | /apps unmount | /apps inspect <uri>");
            UpdateStatus("Apps help shown.");
            return (true, true);
        }

        if (TryParseSlashArgument(text, "/apps", out var appsArg))
        {
            return (await HandleAppsCommandAsync(appsArg), true);
        }

        return (false, true);
    }

    private async Task<bool> HandleAppsCommandAsync(string argument)
    {
        if (_appsBridge is null || !_appsBridge.IsReady)
        {
            SetCommanderNotice("ERROR: MCP Apps bridge is not running. Check logs and restart the widget.");
            UpdateStatus("Apps bridge unavailable.");
            return true;
        }

        var parts = argument.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var sub = parts.Length > 0 ? parts[0].ToLowerInvariant() : string.Empty;
        var rest = parts.Length > 1 ? parts[1] : string.Empty;

        try
        {
            switch (sub)
            {
                case "list":
                    await AppsListAsync();
                    return true;
                case "mount":
                    await AppsMountAsync(rest);
                    return true;
                case "unmount":
                    AppsUnmount();
                    return true;
                case "inspect":
                    await AppsInspectAsync(rest);
                    return true;
                default:
                    SetCommanderNotice("Usage: /apps list | /apps mount <uri> | /apps unmount | /apps inspect <uri>");
                    UpdateStatus("Apps help shown.");
                    return true;
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"/apps {sub} failed: {ex.Message}");
            SetCommanderNotice($"ERROR: /apps {sub} failed: {ex.Message}");
            UpdateStatus("Apps command failed.");
            return true;
        }
    }

    private async Task AppsListAsync()
    {
        using var doc = await _appsBridge!.ListResourcesAsync(System.Threading.CancellationToken.None).ConfigureAwait(true);
        if (!doc.RootElement.TryGetProperty("result", out var result)
            || !result.TryGetProperty("resources", out var arr)
            || arr.ValueKind != System.Text.Json.JsonValueKind.Array)
        {
            SetCommanderNotice("No MCP Apps resources returned.");
            UpdateStatus("Apps list empty.");
            return;
        }

        var items = new List<string>(arr.GetArrayLength());
        foreach (var res in arr.EnumerateArray())
        {
            var uri = res.TryGetProperty("uri", out var u) ? u.GetString() ?? "<no-uri>" : "<no-uri>";
            var name = res.TryGetProperty("name", out var n) ? n.GetString() ?? string.Empty : string.Empty;
            items.Add(string.IsNullOrEmpty(name) ? uri : $"{uri} ({name})");
        }

        var mounted = _appsHost is null ? "none" : _resourceUriCurrent ?? "unknown";
        var summary = items.Count == 0
            ? "No MCP Apps resources registered."
            : $"MCP Apps ({items.Count}): {string.Join("; ", items)}. Mounted: {mounted}";
        SetCommanderNotice(summary);
        UpdateStatus($"{items.Count} MCP Apps resource(s).");
    }

    private async Task AppsMountAsync(string uri)
    {
        if (string.IsNullOrWhiteSpace(uri))
        {
            SetCommanderNotice("ERROR: /apps mount requires a ui:// uri.");
            UpdateStatus("Apps mount missing uri.");
            return;
        }

        if (!uri.StartsWith("ui://clippy/", StringComparison.OrdinalIgnoreCase))
        {
            SetCommanderNotice($"ERROR: /apps mount only accepts ui://clippy/ URIs (got {uri}).");
            UpdateStatus("Apps mount rejected.");
            return;
        }

        try { _appsHost?.Dispose(); }
        catch (Exception ex) { WidgetHostLogger.Log($"/apps mount dispose warn: {ex.Message}"); }

        _appsHost = new McpAppsHost(
            resourceUri: uri,
            bridge: _appsBridge!,
            commanderSessionId: _commanderSession.SessionId);
        _appsHost.ViewInitialized += OnAppsViewInitialized;
        AppsHostSlot.Child = _appsHost;
        AppsHostSlot.Height = 140;
        AppsHostSlot.Visibility = Visibility.Visible;
        SessionMeta.Visibility = Visibility.Collapsed;
        _resourceUriCurrent = uri;

        await _appsHost.EnsureReadyAsync().ConfigureAwait(true);
        PublishMountedViewRefresh("mount");
        SetCommanderNotice($"Mounted MCP App view: {uri}");
        UpdateStatus($"Mounted {uri}.");
    }

    private void AppsUnmount()
    {
        if (_appsHost is null && AppsHostSlot.Visibility != Visibility.Visible)
        {
            SetCommanderNotice("No MCP App view is mounted.");
            UpdateStatus("Nothing to unmount.");
            return;
        }

        AppsHostSlot.Visibility = Visibility.Collapsed;
        AppsHostSlot.Height = 0;
        SessionMeta.Visibility = Visibility.Visible;
        _resourceUriCurrent = null;
        SetCommanderNotice("Unmounted MCP App view; session meta text fallback restored.");
        UpdateStatus("App view unmounted.");
    }

    private async Task AppsInspectAsync(string uri)
    {
        if (string.IsNullOrWhiteSpace(uri))
        {
            SetCommanderNotice("ERROR: /apps inspect requires a ui:// uri.");
            UpdateStatus("Apps inspect missing uri.");
            return;
        }

        using var doc = await _appsBridge!.ReadResourceAsync(uri, System.Threading.CancellationToken.None).ConfigureAwait(true);
        if (!doc.RootElement.TryGetProperty("result", out var result)
            || !result.TryGetProperty("contents", out var contents)
            || contents.ValueKind != System.Text.Json.JsonValueKind.Array
            || contents.GetArrayLength() == 0)
        {
            SetCommanderNotice($"No contents returned for {uri}.");
            UpdateStatus("Apps inspect empty.");
            return;
        }

        var first = contents[0];
        var mime = first.TryGetProperty("mimeType", out var m) ? m.GetString() ?? "<unknown>" : "<unknown>";
        var textLen = first.TryGetProperty("text", out var t) && t.ValueKind == System.Text.Json.JsonValueKind.String
            ? t.GetString()!.Length
            : 0;
        SetCommanderNotice($"{uri}: mime={mime}, html={textLen} chars. Mounted: {(_resourceUriCurrent == uri ? "yes" : "no")}.");
        UpdateStatus($"Inspected {uri}.");
    }

    private Task<bool> ToggleAppsDevAsync()
    {
        var showText = SessionMeta.Visibility != Visibility.Visible;
        SessionMeta.Visibility = showText ? Visibility.Visible : Visibility.Collapsed;
        AppsHostSlot.Visibility = showText ? Visibility.Collapsed : Visibility.Visible;
        if (showText)
        {
            RefreshCommanderAggregateMeta();
            SetCommanderNotice("Dev mode: SessionMeta text fallback shown; MCP Apps view hidden.");
            UpdateStatus("Apps dev toggle: text fallback.");
        }
        else
        {
            SetCommanderNotice("Dev mode off: MCP Apps view restored.");
            UpdateStatus("Apps dev toggle: view.");
        }
        return Task.FromResult(true);
    }

    private string? _resourceUriCurrent;

    private static string SummarizeOutcomes(string scope, IReadOnlyList<CommanderBroadcastOutcome> outcomes)
    {
        if (outcomes.Count == 0)
        {
            return $"No tabs matched for {scope}.";
        }

        var delivered = outcomes.Count(o => o.Result == CommanderDispatchResult.Delivered);
        var busy = outcomes.Count(o => o.Result == CommanderDispatchResult.Busy);
        var notReady = outcomes.Count(o => o.Result == CommanderDispatchResult.NotReady);
        var other = outcomes.Count - delivered - busy - notReady;

        var parts = new List<string> { $"{delivered} delivered" };
        if (busy > 0) parts.Add($"{busy} busy");
        if (notReady > 0) parts.Add($"{notReady} not-ready");
        if (other > 0) parts.Add($"{other} other");

        return $"Commander {scope}: {string.Join(", ", parts)}.";
    }

    private static bool TryParseSlashArgument(string text, string command, out string argument)
    {
        argument = string.Empty;
        if (!text.StartsWith(command, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (text.Length == command.Length)
        {
            return false;
        }

        if (!char.IsWhiteSpace(text[command.Length]))
        {
            return false;
        }

        argument = text[(command.Length + 1)..].Trim();
        return !string.IsNullOrWhiteSpace(argument);
    }

    private AgentDefinition? ResolveAgentToken(string token)
    {
        var trimmed = token.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return null;
        }

        var exact = _agents.FirstOrDefault(agent =>
            agent.Id.Equals(trimmed, StringComparison.OrdinalIgnoreCase) ||
            agent.DisplayName.Equals(trimmed, StringComparison.OrdinalIgnoreCase));
        if (exact is not null)
        {
            return exact;
        }

        var matches = _agents
            .Where(agent =>
                agent.Id.StartsWith(trimmed, StringComparison.OrdinalIgnoreCase) ||
                agent.DisplayName.StartsWith(trimmed, StringComparison.OrdinalIgnoreCase))
            .Take(2)
            .ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }

    private static string? ResolveCommanderAgentId(IEnumerable<AgentDefinition> agents, string? requestedAgentId)
    {
        var commanderAgent = agents.FirstOrDefault(agent =>
            string.Equals(agent.Id, "clippy-commander", StringComparison.OrdinalIgnoreCase));
        if (commanderAgent is not null)
        {
            return commanderAgent.Id;
        }

        return string.IsNullOrWhiteSpace(requestedAgentId)
            ? null
            : requestedAgentId;
    }

    private static ModelDefinition? ResolveModelToken(string token)
    {
        var trimmed = token.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return null;
        }

        var exact = ModelCatalog.Models.FirstOrDefault(model =>
            model.Id.Equals(trimmed, StringComparison.OrdinalIgnoreCase) ||
            model.DisplayName.Equals(trimmed, StringComparison.OrdinalIgnoreCase));
        if (exact is not null)
        {
            return exact;
        }

        var matches = ModelCatalog.Models
            .Where(model =>
                model.Id.StartsWith(trimmed, StringComparison.OrdinalIgnoreCase) ||
                model.DisplayName.StartsWith(trimmed, StringComparison.OrdinalIgnoreCase))
            .Take(2)
            .ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }

    private static string GetShortSessionId(string sessionId)
    {
        return sessionId.Length > 8
            ? sessionId[..8]
            : sessionId;
    }

    // ── Existing event handlers ──────────────────────────────────

    private async void OnNewTabClick(object sender, RoutedEventArgs e)
    {
        await AddTabAsync();
    }

    private void OnHideBenchClick(object sender, RoutedEventArgs e)
    {
        HideBench();
    }

    private async void OnCloseTabClick(object sender, RoutedEventArgs e)
    {
        if (Tabs.SelectedItem is not TabItem tabItem || tabItem.Tag is not TerminalTabSession session)
        {
            return;
        }

        await CloseTabAsync(tabItem, session);
    }

    private async void OnTabCloseButtonClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;

        if (sender is not FrameworkElement element ||
            element.Tag is not TabItem tabItem ||
            tabItem.Tag is not TerminalTabSession session)
        {
            return;
        }

        await CloseTabAsync(tabItem, session);
    }

    private void OnTabSwitcherClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;

        if (sender is not FrameworkElement anchor)
        {
            return;
        }

        var menu = new ContextMenu
        {
            Placement = PlacementMode.Bottom,
            PlacementTarget = anchor
        };

        foreach (var item in Tabs.Items)
        {
            if (item is not TabItem tabItem || tabItem.Tag is not TerminalTabSession session)
            {
                continue;
            }

            var shortId = session.SessionId.Length > 8
                ? session.SessionId[..8]
                : session.SessionId;

            var menuItem = new MenuItem
            {
                Header = session.DisplayName,
                Tag = tabItem,
                IsCheckable = true,
                IsChecked = ReferenceEquals(Tabs.SelectedItem, tabItem),
                InputGestureText = shortId
            };
            menuItem.Click += (_, _) =>
            {
                Tabs.SelectedItem = tabItem;
                if (tabItem.Tag is TerminalTabSession selectedSession)
                {
                    selectedSession.FocusEmbeddedSurface();
                    UpdateStatus($"Active tab: {selectedSession.DisplayName}");
                }
            };
            menu.Items.Add(menuItem);
        }

        if (menu.Items.Count > 0)
        {
            menu.Items.Add(new Separator());
        }

        var newTabItem = new MenuItem
        {
            Header = "New tab"
        };
        newTabItem.Click += async (_, _) =>
        {
            await AddTabAsync();
        };
        menu.Items.Add(newTabItem);

        anchor.ContextMenu = menu;
        menu.IsOpen = true;
    }

    private void OnHeaderMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch
        {
        }
    }

    public async Task ToggleBenchAsync(Rect launcherBounds)
    {
        if (IsVisible)
        {
            HideBench();
            return;
        }

        await ShowBenchAsync(launcherBounds, _options.SessionId);
    }

    public async Task ShowBenchAsync(Rect launcherBounds, string? preferredSessionId = null)
    {
        PositionRelativeToLauncher(launcherBounds);

        if (!IsVisible)
        {
            Show();
        }

        await Dispatcher.InvokeAsync(UpdateLayout, DispatcherPriority.Loaded);
        await EnsureBenchInitializedAsync(preferredSessionId);
        PositionRelativeToLauncher(launcherBounds);
        Activate();
        FocusSelectedSession();
    }

    public async Task AddLauncherTabAsync(Rect launcherBounds)
    {
        var hadExistingTabs = _sessions.Count > 0;
        await ShowBenchAsync(launcherBounds);
        if (hadExistingTabs)
        {
            await AddTabAsync();
        }
    }

    public void RepositionNearLauncher(Rect launcherBounds)
    {
        if (!IsVisible)
        {
            return;
        }

        PositionRelativeToLauncher(launcherBounds);
    }

    public void HideBench()
    {
        if (!IsVisible)
        {
            return;
        }

        Hide();
        UpdateStatus("Bench hidden.");
    }

    public void CloseForShutdown()
    {
        if (_allowClose)
        {
            return;
        }

        _allowClose = true;
        _isShuttingDown = true;
        Close();
    }

    public string GetActiveMode()
    {
        return _settings.Mode;
    }

    public string? GetActiveAgentId()
    {
        return _settings.Agent;
    }

    public string GetActiveAgentDisplayName()
    {
        return ResolveAgentDisplayName(GetActiveAgentId());
    }

    public string GetActiveModelId()
    {
        return _settings.Model;
    }

    public string GetActiveModelDisplayName()
    {
        return ResolveModelDisplayName(GetActiveModelId());
    }

    public void ApplyModeFromLauncher(string mode)
    {
        ApplyMode(mode, syncToolbar: true);
    }

    public void ApplyAgentFromLauncher(string agentId)
    {
        ApplyAgent(agentId, syncToolbar: true);
    }

    public void ApplyModelFromLauncher(string modelId)
    {
        ApplyModel(modelId, syncToolbar: true);
    }

    public bool SetToolSetting(string name, bool enabled)
    {
        if (!_settings.Tools.TrySet(name, enabled))
        {
            return false;
        }

        _commanderSession.ToolSettings = _settings.Tools.Clone();
        _settings.Save();
        RefreshToolbarButtonLabels();
        UpdateSessionMeta();
        UpdateStatus($"Tool setting updated: {name} {(enabled ? "enabled" : "disabled")}.");
        if (_commanderSession.IsReady)
        {
            RestartCommanderSessionInBackground("tool settings");
        }

        return true;
    }

    public bool SetExtensionSetting(string name, bool enabled)
    {
        if (!_settings.Extensions.TrySet(name, enabled))
        {
            return false;
        }

        _settings.Save();
        RefreshToolbarButtonLabels();
        UpdateSessionMeta();
        UpdateStatus($"Extension setting updated: {name} {(enabled ? "enabled" : "disabled")}.");
        return true;
    }

    private void RefreshToolbarButtonLabels()
    {
        ToolsBtn.Content = $"Tools ({_settings.Tools.EnabledCount}) v";
        ExtBtn.Content = $"Ext ({_settings.Extensions.EnabledCount}) v";
    }

    private void OpenToolsMenu(FrameworkElement anchor)
    {
        anchor.ContextMenu = BuildSettingsMenu(
            anchor,
            ToolMenuEntries,
            IsToolSettingEnabled,
            SetToolSetting);
        anchor.ContextMenu.IsOpen = true;
    }

    private void OpenExtensionsMenu(FrameworkElement anchor)
    {
        anchor.ContextMenu = BuildSettingsMenu(
            anchor,
            ExtensionMenuEntries,
            IsExtensionSettingEnabled,
            SetExtensionSetting);
        anchor.ContextMenu.IsOpen = true;
    }

    private ContextMenu BuildSettingsMenu(
        FrameworkElement anchor,
        IReadOnlyList<(string Name, string Header)> entries,
        Func<string, bool> isChecked,
        Func<string, bool, bool> applySetting)
    {
        var menu = new ContextMenu
        {
            Placement = PlacementMode.Bottom,
            PlacementTarget = anchor
        };

        foreach (var entry in entries)
        {
            var menuItem = new MenuItem
            {
                Header = entry.Header,
                Tag = entry.Name,
                IsCheckable = true,
                IsChecked = isChecked(entry.Name),
                StaysOpenOnClick = true
            };
            menuItem.Click += (_, _) =>
            {
                applySetting(entry.Name, menuItem.IsChecked);
                SetCommanderNotice($"{entry.Header} {(menuItem.IsChecked ? "enabled" : "disabled")}.");
            };
            menu.Items.Add(menuItem);
        }

        return menu;
    }

    private bool IsToolSettingEnabled(string name)
    {
        return name switch
        {
            nameof(WidgetToolSettings.AllowAllTools) => _settings.Tools.AllowAllTools,
            nameof(WidgetToolSettings.AllowAllPaths) => _settings.Tools.AllowAllPaths,
            nameof(WidgetToolSettings.AllowAllUrls) => _settings.Tools.AllowAllUrls,
            nameof(WidgetToolSettings.Experimental) => _settings.Tools.Experimental,
            nameof(WidgetToolSettings.Autopilot) => _settings.Tools.Autopilot,
            nameof(WidgetToolSettings.EnableAllGitHubMcpTools) => _settings.Tools.EnableAllGitHubMcpTools,
            _ => false
        };
    }

    private bool IsExtensionSettingEnabled(string name)
    {
        return name switch
        {
            nameof(WidgetExtensionSettings.IncludeRegularSettings) => _settings.Extensions.IncludeRegularSettings,
            nameof(WidgetExtensionSettings.IncludeInsidersSettings) => _settings.Extensions.IncludeInsidersSettings,
            nameof(WidgetExtensionSettings.IncludeRegularExtensions) => _settings.Extensions.IncludeRegularExtensions,
            nameof(WidgetExtensionSettings.IncludeInsidersExtensions) => _settings.Extensions.IncludeInsidersExtensions,
            _ => false
        };
    }

    public (double? Left, double? Top) GetSavedLauncherPosition()
    {
        return (_settings.LauncherLeft, _settings.LauncherTop);
    }

    public void SaveLauncherPosition(double left, double top)
    {
        _settings.LauncherLeft = left;
        _settings.LauncherTop = top;
        _settings.Save();
    }

    private async Task EnsureBenchInitializedAsync(string? preferredSessionId = null)
    {
        await EnsureCommanderInitializedAsync();

        if (_sessions.Count > 0)
        {
            return;
        }

        WidgetHostLogger.Log("Bench has no active tabs. Creating a new native tab.");
        await AddTabAsync(preferredSessionId);
    }

    private async Task EnsureCommanderInitializedAsync()
    {
        if (_commanderSession.IsReady)
        {
            return;
        }

        await _commanderSession.EnsureStartedAsync();
        UpdateSessionMeta();
    }

    private async void RestartCommanderSessionInBackground(string reason)
    {
        try
        {
            await _commanderSession.RestartAsync();
            SetCommanderNotice($"Commander session restarted with updated {reason}.");
            UpdateStatus($"Commander updated: {reason}.");
        }
        catch (Exception ex)
        {
            SetCommanderNotice($"ERROR: Commander restart failed after {reason} change: {ex.Message}");
            UpdateStatus("Commander restart failed.");
            WidgetHostLogger.Log($"Commander restart failed after {reason} change: {ex}");
        }
    }

    private void OnTabsSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Tabs.SelectedItem is not TabItem tabItem || tabItem.Tag is not TerminalTabSession session)
        {
            return;
        }

        SyncToolbarFromSelectedTab();

        if (!session.IsReady)
        {
            UpdateSessionMeta(session);
            UpdateStatus($"Initializing {session.DisplayName}...");
            return;
        }

        session.ResizeEmbeddedSurface();
        session.FocusEmbeddedSurface();
        UpdateSessionMeta(session);
        UpdateStatus($"Active tab: {session.DisplayName}");
    }

    private async Task AddTabAsync(string? preferredSessionId = null)
    {
        var tabIndex = _sessions.Count + 1;
        var displayName = tabIndex == 1 ? "Clippy" : $"Clippy {tabIndex}";
        var sessionId = string.IsNullOrWhiteSpace(preferredSessionId)
            ? Guid.NewGuid().ToString()
            : preferredSessionId.Trim();
        if (_sessions.Any(s => string.Equals(s.SessionId, sessionId, StringComparison.OrdinalIgnoreCase)))
        {
            var originalSessionId = sessionId;
            sessionId = Guid.NewGuid().ToString();
            WidgetHostLogger.Log($"Preferred sessionId collision ignored: {originalSessionId}; generated {sessionId}.");
        }

        var terminal = new TerminalControl
        {
            AutoResize = true,
            Focusable = true
        };

        var tabItem = new TabItem
        {
            Header = displayName,
            Content = terminal,
            Style = (Style)FindResource("BenchTabItemStyle"),
            ToolTip = sessionId
        };

        var session = new TerminalTabSession(
            sessionId,
            displayName,
            _repoRoot,
            _copilotConfigDir,
            terminal)
        {
            Mode = _settings.Mode,
            AgentId = _settings.Agent,
            ModelId = _settings.Model,
            ToolSettings = _settings.Tools.Clone()
        };

        session.Exited += OnTerminalSessionExited;
        session.MetadataChanged += OnSessionMetadataChanged;
        terminal.SizeChanged += (_, _) => session.ResizeEmbeddedSurface();

        tabItem.Tag = session;
        _sessions.Add(session);
        _commanderHub.Register(session);
        Tabs.Items.Add(tabItem);
        Tabs.SelectedItem = tabItem;
        WidgetHostLogger.Log($"Added tab {displayName} ({sessionId}). Starting native terminal.");

        try
        {
            await Dispatcher.InvokeAsync(
                () =>
                {
                    UpdateLayout();
                    terminal.UpdateLayout();
                },
                DispatcherPriority.Loaded);

            await session.StartAsync();
            session.ResizeEmbeddedSurface();
            session.FocusEmbeddedSurface();
            SyncToolbarFromSelectedTab();
            UpdateSessionMeta(session);
            UpdateStatus($"Opened {displayName} ({session.SessionId}).");
            WidgetHostLogger.Log($"Native terminal ready for tab {displayName} ({session.SessionId}).");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"Failed to open tab {displayName}: {ex}");

            try
            {
                session.Dispose();
            }
            catch (Exception cleanupEx)
            {
                WidgetHostLogger.Log($"Cleanup failed after tab start error for {displayName}: {cleanupEx}");
            }

            _sessions.Remove(session);
            _commanderHub.Unregister(session);
            Tabs.Items.Remove(tabItem);
            UpdateStatus($"Failed to open {displayName}: {ex.Message}");
            SyncToolbarFromSelectedTab();
        }
    }

    private async void OnTerminalSessionExited(object? sender, EventArgs e)
    {
        if (_isShuttingDown || sender is not TerminalTabSession session)
        {
            return;
        }

        await Dispatcher.InvokeAsync(async () =>
        {
            var tabItem = FindTabForSession(session);
            if (tabItem is not null)
            {
                await CloseTabAsync(tabItem, session, sessionExited: true);
            }
        });
    }

    private async Task CloseTabAsync(TabItem tabItem, TerminalTabSession session, bool sessionExited = false)
    {
        session.Exited -= OnTerminalSessionExited;
        session.MetadataChanged -= OnSessionMetadataChanged;
        _commanderHub.Unregister(session);
        session.Dispose();
        _sessions.Remove(session);
        Tabs.Items.Remove(tabItem);

        if (Tabs.Items.Count == 0)
        {
            UpdateStatus("All tabs closed.");
            HideBench();
            return;
        }

        if (Tabs.SelectedItem is not TabItem)
        {
            Tabs.SelectedIndex = Math.Max(0, Tabs.Items.Count - 1);
        }

        await Dispatcher.InvokeAsync(() =>
        {
            if (Tabs.SelectedItem is TabItem selectedTab && selectedTab.Tag is TerminalTabSession selectedSession)
            {
                selectedSession.ResizeEmbeddedSurface();
                selectedSession.FocusEmbeddedSurface();
            }
        });

        UpdateStatus(sessionExited
            ? $"{session.DisplayName} exited."
            : $"{session.DisplayName} closed.");
    }

    private void OnSessionMetadataChanged(object? sender, EventArgs e)
    {
        _ = Dispatcher.BeginInvoke(() =>
        {
            var selectedSession = ResolveSelectedSession();
            if (selectedSession is not null)
            {
                UpdateSessionMeta(selectedSession);
            }
        });
    }

    private void OnCommanderSessionMetadataChanged(object? sender, EventArgs e)
    {
        RefreshCommanderAggregateMeta();
    }

    private void OnCommanderSessionExited(object? sender, EventArgs e)
    {
        SetCommanderNotice("WARNING: Commander session exited. The next prompt will restart it.");
        RefreshCommanderAggregateMeta();
    }

    private void OnCommanderHubGroupsChanged(object? sender, EventArgs e)
    {
        RefreshCommanderAggregateMeta();
    }

    private void OnCommanderHubSessionChanged(object? sender, TerminalTabSession e)
    {
        RefreshCommanderAggregateMeta();
    }

    private void RefreshCommanderAggregateMeta()
    {
        _ = Dispatcher.BeginInvoke(() =>
        {
            var selectedSession = ResolveSelectedSession();
            if (selectedSession is not null)
            {
                UpdateSessionMeta(selectedSession);
            }
            else
            {
                UpdateSessionMeta();
            }
            UpdateFleetStatusBadge();
            PublishMountedViewRefresh("state-change");
        });
    }

    private void UpdateFleetStatusBadge()
    {
        if (FleetStatusBadge is null) return;
        FleetStatusBadge.Text = $"{_commanderHub.SessionCount} tabs / {_commanderHub.WaitingCount} working / {_commanderHub.GroupCount} groups";
    }

    private void PublishMountedViewRefresh(string reason)
    {
        if (_appsBridge is null) return;
        try
        {
            var snapshot = BuildFleetSnapshot();
            _ = _appsBridge.PublishFleetStateAsync(snapshot);
            _ = RefreshMountedViewAsync(reason);
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"PublishMountedViewRefresh({reason}): {ex.Message}");
        }
    }

    private void OnAppsViewInitialized(object? sender, EventArgs e)
    {
        // View finished ui/initialize handshake and wired ontoolresult.
        // Pre-initialize tool-result pushes are discarded by the SDK, so
        // re-seed live state here, on the dispatcher.
        try
        {
            if (Dispatcher.CheckAccess())
            {
                WidgetHostLogger.Log("OnAppsViewInitialized: re-seeding mounted view post-handshake.");
                PublishMountedViewRefresh("handshake");
            }
            else
            {
                Dispatcher.InvokeAsync(() =>
                {
                    WidgetHostLogger.Log("OnAppsViewInitialized: re-seeding mounted view post-handshake (marshalled).");
                    PublishMountedViewRefresh("handshake");
                });
            }

            _ = Task.Run(async () =>
            {
                await Task.Delay(3000).ConfigureAwait(false);
                try
                {
                    var host = _appsHost;
                    if (host is null) return;
                    var text = await Dispatcher.InvokeAsync(async () => await host.DumpViewTextAsync().ConfigureAwait(true)).Task.Unwrap().ConfigureAwait(false);
                    WidgetHostLogger.Log($"OnAppsViewInitialized: view text dump: {text}");
                }
                catch (Exception dex)
                {
                    WidgetHostLogger.Log($"OnAppsViewInitialized: dump failed: {dex.Message}");
                }
                await Task.Delay(5000).ConfigureAwait(false);
                try
                {
                    var host = _appsHost;
                    if (host is null) return;
                    var text = await Dispatcher.InvokeAsync(async () => await host.DumpViewTextAsync().ConfigureAwait(true)).Task.Unwrap().ConfigureAwait(false);
                    WidgetHostLogger.Log($"OnAppsViewInitialized: view text dump (t+8s): {text}");
                }
                catch (Exception dex)
                {
                    WidgetHostLogger.Log($"OnAppsViewInitialized: dump2 failed: {dex.Message}");
                }
            });
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"OnAppsViewInitialized: {ex.Message}");
        }
    }

    private async Task RefreshMountedViewAsync(string reason)
    {
        if (_appsBridge is null || !_appsBridge.IsReady) return;
        try
        {
            if (_appsHost is not null)
            {
                await _appsHost.PostResourceListChangedAsync().ConfigureAwait(true);
                await PushMcpAppsToolResultToViewAsync(_appsHost, _resourceUriCurrent, reason, "primary").ConfigureAwait(true);
            }
            if (_secondaryAppsHost is not null)
            {
                await _secondaryAppsHost.PostResourceListChangedAsync().ConfigureAwait(true);
                await PushMcpAppsToolResultToViewAsync(_secondaryAppsHost, DefaultMountedResourceUri, reason, "fleet-status").ConfigureAwait(true);
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"RefreshMountedViewAsync({reason}): {ex.Message}");
        }
    }

    private async Task PushMountedViewToolResultToViewAsync(string reason)
    {
        if (_appsBridge is null || !_appsBridge.IsReady) return;
        if (_appsHost is null && _secondaryAppsHost is null) return;

        if (_appsHost is not null)
        {
            await PushMcpAppsToolResultToViewAsync(_appsHost, _resourceUriCurrent, reason, "primary").ConfigureAwait(true);
        }

        if (_secondaryAppsHost is not null)
        {
            await PushMcpAppsToolResultToViewAsync(_secondaryAppsHost, DefaultMountedResourceUri, reason, "fleet-status").ConfigureAwait(true);
        }
    }

    private async Task PushMcpAppsToolResultToViewAsync(McpAppsHost host, string? resourceUri, string reason, string surface)
    {
        if (_appsBridge is null || !_appsBridge.IsReady) return;
        try
        {
            var binding = ResolveMountedViewBinding(resourceUri);
            if (binding is null)
            {
                WidgetHostLogger.Log($"PushMcpAppsToolResultToViewAsync({reason}, {surface}): no binding for {resourceUri ?? "<null>"}.");
                return;
            }

            using var envelope = await _appsBridge.CallToolAsync(
                binding.ToolName,
                default,
                System.Threading.CancellationToken.None).ConfigureAwait(true);
            if (!envelope.RootElement.TryGetProperty("result", out var result))
            {
                WidgetHostLogger.Log($"PushMountedViewToolResultToViewAsync({reason}): envelope missing 'result' for {binding.ToolName}.");
                return;
            }
            if (!result.TryGetProperty("structuredContent", out var structured))
            {
                WidgetHostLogger.Log($"PushMcpAppsToolResultToViewAsync({reason}, {surface}): result missing 'structuredContent' for {binding.ToolName}.");
                return;
            }

            await host.PostToolResultAsync(binding.ToolName, structured).ConfigureAwait(true);
            WidgetHostLogger.Log($"PushMcpAppsToolResultToViewAsync({reason}, {surface}): posted {binding.ToolName} bytes={structured.GetRawText().Length} resource={binding.ResourceUri}");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"PushMcpAppsToolResultToViewAsync({reason}, {surface}): {ex.Message}");
        }
    }

    private void OnFleetStatusBtnClick(object sender, RoutedEventArgs e)
    {
        try
        {
            if (_appsBridge is null || !_appsBridge.IsReady)
            {
                SetCommanderNotice("Fleet Status: MCP Apps bridge is not ready yet.");
                UpdateStatus("Fleet Status bridge is not ready.");
                return;
            }

            if (_fleetStatusWindow is not null)
            {
                if (_fleetStatusWindow.WindowState == WindowState.Minimized)
                {
                    _fleetStatusWindow.WindowState = WindowState.Normal;
                }
                _fleetStatusWindow.Activate();
                _fleetStatusWindow.Focus();
                PublishMountedViewRefresh("fleet-status-popup-focus");
                return;
            }

            _fleetStatusWindow = new FleetStatusWindow(
                _appsBridge,
                DefaultMountedResourceUri,
                _commanderSession.SessionId,
                onHostChanged: host =>
                {
                    _secondaryAppsHost = host;
                    if (host is not null)
                    {
                        host.ViewInitialized += OnAppsViewInitialized;
                        _ = Dispatcher.InvokeAsync(async () =>
                        {
                            try { await PushMountedViewToolResultToViewAsync("fleet-status-popup-open").ConfigureAwait(true); }
                            catch (Exception ex) { WidgetHostLogger.Log($"FleetStatusWindow seed: {ex.Message}"); }
                        });
                    }
                })
            {
                Owner = this
            };
            _fleetStatusWindow.Closed += (_, _) =>
            {
                _fleetStatusWindow = null;
                _secondaryAppsHost = null;
                UpdateFleetStatusBadge();
            };
            _fleetStatusWindow.Show();
            UpdateStatus("Fleet Status opened.");
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"OnFleetStatusBtnClick: {ex.Message}");
            SetCommanderNotice($"Fleet Status open failed: {ex.Message}");
        }
    }

    private static MountedViewBinding? ResolveMountedViewBinding(string? resourceUri)
    {
        if (string.IsNullOrWhiteSpace(resourceUri))
        {
            return null;
        }

        return MountedViewBindings.TryGetValue(resourceUri, out var binding)
            ? binding
            : null;
    }

    private FleetStateSnapshot BuildFleetSnapshot()
    {
        var sessions = _commanderHub.Sessions.ToArray();
        var tabs = sessions.Select(s => new FleetTab(
            TabKey: s.TabKey.ToString(),
            DisplayName: s.DisplayName ?? string.Empty,
            SessionId: s.SessionId ?? string.Empty,
            Mode: s.Mode ?? string.Empty,
            AgentId: s.AgentId ?? string.Empty,
            ModelId: s.ModelId ?? string.Empty,
            GroupLabel: s.GroupLabel ?? string.Empty,
            Status: s.IsWaitingForResponse ? "working" : "idle"
        )).ToArray();

        var groups = _commanderHub.DescribeGroups()
            .Select(kvp => new FleetGroup(
                kvp.Key,
                kvp.Value.Select(m => new FleetGroupMember(
                    TabKey: m.TabKey.ToString(),
                    SessionId: m.SessionId,
                    DisplayName: m.DisplayName)).ToArray()))
            .ToArray();

        var activeAgentId = _commanderSession.AgentId ?? string.Empty;
        var agents = _agents
            .Where(a => !string.IsNullOrWhiteSpace(a.Id))
            .Select(a => new FleetAgentCatalogEntry(
                Id: a.Id ?? string.Empty,
                DisplayName: a.DisplayName ?? a.Id ?? string.Empty,
                FilePath: a.RelativePath ?? string.Empty,
                Source: a.Source ?? string.Empty,
                RelativePath: a.RelativePath ?? string.Empty,
                ContentHash: a.ContentHash ?? string.Empty,
                PathPatterns: a.PathPatterns ?? Array.Empty<string>(),
                IsActive: !string.IsNullOrEmpty(activeAgentId) && string.Equals(a.Id, activeAgentId, StringComparison.OrdinalIgnoreCase)))
            .ToArray();

        var commanderSnapshot = BuildCommanderSnapshot();
        var manifests = AdaptiveManifestProtocol.BuildFleetManifests(commanderSnapshot, tabs, agents);

        return new FleetStateSnapshot(
            Principal: "clippy",
            Session: _commanderSession.SessionId,
            CapturedAt: DateTime.UtcNow.ToString("o"),
            Fleet: new FleetCounts(_commanderHub.SessionCount, _commanderHub.WaitingCount, _commanderHub.GroupCount),
            Tabs: new FleetTabs(tabs),
            Groups: new FleetGroups(groups),
            Agents: new FleetAgents(agents.Length, activeAgentId, agents),
            Commander: commanderSnapshot,
            Manifests: manifests
        );
    }

    private CommanderSnapshot BuildCommanderSnapshot()
    {
        var history = _commanderSession.BuildHistoryEntries(24)
            .Select(e => new CommanderHistoryEntry(
                Role: e.Role ?? string.Empty,
                Text: e.Text ?? string.Empty,
                At: e.At.ToString("o")))
            .ToArray();
        return new CommanderSnapshot(
            SessionId: _commanderSession.SessionId ?? string.Empty,
            DisplayName: "Clippy Commander",
            Model: _commanderSession.ModelId ?? string.Empty,
            Agent: _commanderSession.AgentId ?? string.Empty,
            Mode: _commanderSession.Mode ?? "Agent",
            IsReady: _commanderSession.IsReady,
            IsBusy: _commanderSession.IsWaitingForResponse,
            LatestPrompt: _commanderSession.LatestPromptPreview ?? string.Empty,
            LatestReply: _commanderSession.LatestTranscriptPreview ?? string.Empty,
            LatestToolSummary: _commanderSession.LatestToolSummary ?? string.Empty,
            LastError: _commanderSession.LastErrorMessage ?? string.Empty,
            HistoryCount: _commanderSession.HistoryCount,
            History: history
        );
    }

    private void OnCommanderIntentReceived(object? sender, CommanderIntent intent)
    {
        try
        {
            Dispatcher.InvokeAsync(() =>
            {
                try
                {
                    if (!string.IsNullOrWhiteSpace(intent.Mode)
                        && ValidModes.Contains(intent.Mode)
                        && !string.Equals(_commanderSession.Mode, intent.Mode, StringComparison.OrdinalIgnoreCase))
                    {
                        _commanderSession.Mode = intent.Mode!;
                    }
                    var result = _commanderSession.TrySubmitPrompt(intent.Prompt ?? string.Empty);
                    WidgetHostLogger.Log($"OnCommanderIntentReceived: id={intent.Id} result={result}");
                    PublishMountedViewRefresh("commander-intent");
                }
                catch (Exception ex)
                {
                    WidgetHostLogger.Log($"OnCommanderIntentReceived dispatch: {ex.Message}");
                }
            });
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"OnCommanderIntentReceived: {ex.Message}");
        }
    }

    private void OnBroadcastIntentReceived(object? sender, BroadcastIntent intent)
    {
        try
        {
            Dispatcher.InvokeAsync(async () =>
            {
                try
                {
                    if (string.IsNullOrWhiteSpace(intent.Prompt)) return;
                    IReadOnlyCollection<TerminalTabSession>? targetSessions = null;
                    if (string.Equals(intent.Mode, "tabKeys", StringComparison.OrdinalIgnoreCase) && intent.TabKeys is { Length: > 0 })
                    {
                        var resolved = new List<TerminalTabSession>(intent.TabKeys.Length);
                        foreach (var tabKey in intent.TabKeys)
                        {
                            var match = _commanderHub.FindByTabKey(tabKey);
                            if (match is not null) resolved.Add(match);
                        }
                        targetSessions = resolved;
                    }
                    else if (string.Equals(intent.Mode, "ids", StringComparison.OrdinalIgnoreCase) && intent.Ids is { Length: > 0 })
                    {
                        var resolved = new List<TerminalTabSession>(intent.Ids.Length);
                        foreach (var id in intent.Ids)
                        {
                            var match = _commanderHub.ResolveTarget(id, id);
                            if (match is not null) resolved.Add(match);
                        }
                        targetSessions = resolved;
                    }
                    else if (string.Equals(intent.Mode, "sessionIds", StringComparison.OrdinalIgnoreCase) && intent.SessionIds is { Length: > 0 })
                    {
                        var resolved = new List<TerminalTabSession>(intent.SessionIds.Length);
                        foreach (var sessionId in intent.SessionIds)
                        {
                            var match = _commanderHub.FindBySessionId(sessionId);
                            if (match is not null) resolved.Add(match);
                        }
                        targetSessions = resolved;
                    }
                    else if (string.Equals(intent.Mode, "group", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(intent.Label))
                    {
                        targetSessions = _commanderHub.ResolveGroupMembers(intent.Label!);
                    }

                    var outcomes = await _commanderHub.BroadcastAsync(intent.Prompt, targetSessions).ConfigureAwait(true);
                    WidgetHostLogger.Log($"OnBroadcastIntentReceived: id={intent.Id} mode={intent.Mode} outcomes={outcomes.Count}");
                    PublishMountedViewRefresh("broadcast-intent");
                }
                catch (Exception ex)
                {
                    WidgetHostLogger.Log($"OnBroadcastIntentReceived dispatch: {ex.Message}");
                }
            });
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"OnBroadcastIntentReceived: {ex.Message}");
        }
    }

    private void OnLinkGroupIntentReceived(object? sender, LinkGroupIntent intent)
    {
        try
        {
            Dispatcher.InvokeAsync(async () =>
            {
                try
                {
                    switch (intent.Op)
                    {
                        case "link":
                            if ((!string.IsNullOrWhiteSpace(intent.TabKey) || !string.IsNullOrWhiteSpace(intent.SessionId)) &&
                                !string.IsNullOrWhiteSpace(intent.Label))
                            {
                                var match = _commanderHub.ResolveTarget(intent.TabKey, intent.SessionId);
                                if (match is not null) _commanderHub.Link(match, intent.Label!);
                            }
                            break;
                        case "unlink":
                            if (!string.IsNullOrWhiteSpace(intent.TabKey) || !string.IsNullOrWhiteSpace(intent.SessionId))
                            {
                                var match = _commanderHub.ResolveTarget(intent.TabKey, intent.SessionId);
                                if (match is not null) _commanderHub.Unlink(match);
                            }
                            break;
                        case "broadcast":
                            if (!string.IsNullOrWhiteSpace(intent.Label) && !string.IsNullOrWhiteSpace(intent.Prompt))
                            {
                                var targets = _commanderHub.ResolveGroupMembers(intent.Label!);
                                if (targets.Count > 0)
                                {
                                    await _commanderHub.BroadcastAsync(intent.Prompt!, targets).ConfigureAwait(true);
                                }
                            }
                            break;
                    }
                    WidgetHostLogger.Log($"OnLinkGroupIntentReceived: id={intent.Id} op={intent.Op}");
                    PublishMountedViewRefresh("link-group-intent");
                }
                catch (Exception ex)
                {
                    WidgetHostLogger.Log($"OnLinkGroupIntentReceived dispatch: {ex.Message}");
                }
            });
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"OnLinkGroupIntentReceived: {ex.Message}");
        }
    }

    private async void InitializeMcpAppsHost()
    {
        try
        {
            _appsBridge = new McpAppsBridge(_commanderSession.SessionId, BuildFleetSnapshot, _repoRoot);
            _appsBridge.CommanderIntentReceived += OnCommanderIntentReceived;
            _appsBridge.BroadcastIntentReceived += OnBroadcastIntentReceived;
            _appsBridge.LinkGroupIntentReceived += OnLinkGroupIntentReceived;
            await _appsBridge.StartAsync(System.Threading.CancellationToken.None).ConfigureAwait(true);

            if (!_appsBridge.IsReady)
            {
                WidgetHostLogger.Log("McpAppsBridge not ready after StartAsync; Apps Host disabled.");
                return;
            }

            if (!string.IsNullOrWhiteSpace(_resourceUriCurrent)
                && !string.Equals(_resourceUriCurrent, DefaultMountedResourceUri, StringComparison.OrdinalIgnoreCase))
            {
                _appsHost = new McpAppsHost(
                    resourceUri: _resourceUriCurrent,
                    bridge: _appsBridge,
                    commanderSessionId: _commanderSession.SessionId);
                _appsHost.ViewInitialized += OnAppsViewInitialized;
                AppsHostSlot.Child = _appsHost;
                AppsHostSlot.Height = 140;
                AppsHostSlot.Visibility = Visibility.Visible;
                await _appsHost.EnsureReadyAsync().ConfigureAwait(true);
                PublishMountedViewRefresh("mount");
            }
            else
            {
                _resourceUriCurrent = null;
                AppsHostSlot.Child = null;
                AppsHostSlot.Height = 0;
                AppsHostSlot.Visibility = Visibility.Collapsed;
                PublishMountedViewRefresh("bridge-start");
            }
        }
        catch (Exception ex)
        {
            WidgetHostLogger.Log($"InitializeMcpAppsHost failed: {ex.Message}");
        }
    }

    private TabItem? FindTabForSession(TerminalTabSession session)
    {
        foreach (var item in Tabs.Items)
        {
            if (item is TabItem tabItem && ReferenceEquals(tabItem.Tag, session))
            {
                return tabItem;
            }
        }

        return null;
    }

    private void UpdateStatus(string message)
    {
        Title = $"Clippy Bench - {message}";
        WidgetHostLogger.Log($"Status updated: {message}");
    }

    private void ApplyMode(string mode, bool syncToolbar)
    {
        if (!ValidModes.Contains(mode))
        {
            return;
        }

        if (syncToolbar)
        {
            _isSyncingUi = true;
            try
            {
                SetModeToggle(mode);
            }
            finally
            {
                _isSyncingUi = false;
            }
        }

        _settings.Mode = mode;
        _commanderSession.Mode = mode;
        _settings.Save();
        UpdateSessionMeta();
        WidgetHostLogger.Log($"Commander mode changed to {mode}");
        if (_commanderSession.IsReady)
        {
            RestartCommanderSessionInBackground("mode");
        }
    }

    private void ApplyAgent(string agentId, bool syncToolbar)
    {
        if (string.IsNullOrWhiteSpace(agentId))
        {
            return;
        }

        if (syncToolbar)
        {
            _isSyncingUi = true;
            try
            {
                SelectComboBoxByTag(AgentSelector, agentId);
            }
            finally
            {
                _isSyncingUi = false;
            }
        }

        _settings.Agent = agentId;
        _commanderSession.AgentId = ResolveCommanderAgentId(_agents, agentId);
        _settings.Save();
        UpdateSessionMeta();
        WidgetHostLogger.Log($"Commander agent changed to {_commanderSession.AgentId ?? agentId}");
        if (_commanderSession.IsReady)
        {
            RestartCommanderSessionInBackground("agent");
        }
    }

    private void ApplyModel(string modelId, bool syncToolbar)
    {
        if (string.IsNullOrWhiteSpace(modelId))
        {
            return;
        }

        if (syncToolbar)
        {
            _isSyncingUi = true;
            try
            {
                SelectComboBoxByTag(ModelSelector, modelId);
            }
            finally
            {
                _isSyncingUi = false;
            }
        }

        _settings.Model = modelId;
        _commanderSession.ModelId = modelId;
        _settings.Save();
        UpdateSessionMeta();
        WidgetHostLogger.Log($"Commander model changed to {modelId}");
        if (_commanderSession.IsReady)
        {
            RestartCommanderSessionInBackground("model");
        }
    }

    private TerminalTabSession? ResolveSelectedSession()
    {
        return Tabs.SelectedItem is TabItem tab && tab.Tag is TerminalTabSession session
            ? session
            : null;
    }

    private string ResolveAgentDisplayName(string? agentId)
    {
        if (string.IsNullOrWhiteSpace(agentId))
        {
            return "(none)";
        }

        var agent = _agents.FirstOrDefault(candidate =>
            string.Equals(candidate.Id, agentId, StringComparison.OrdinalIgnoreCase));
        return agent?.DisplayName ?? agentId;
    }

    private static string ResolveModelDisplayName(string? modelId)
    {
        if (string.IsNullOrWhiteSpace(modelId))
        {
            return ModelCatalog.DefaultModelId;
        }

        return ModelCatalog.FindById(modelId)?.DisplayName ?? modelId;
    }

    private void FocusSelectedSession()
    {
        if (Tabs.SelectedItem is not TabItem selectedTab || selectedTab.Tag is not TerminalTabSession selectedSession)
        {
            return;
        }

        selectedSession.ResizeEmbeddedSurface();
        selectedSession.FocusEmbeddedSurface();
        UpdateSessionMeta(selectedSession);
        UpdateStatus($"Active tab: {selectedSession.DisplayName}");
    }

    private void PositionRelativeToLauncher(Rect launcherBounds)
    {
        var workArea = SystemParameters.WorkArea;
        var benchWidth = ActualWidth > 0 ? ActualWidth : Width;
        var benchHeight = ActualHeight > 0 ? ActualHeight : Height;
        var gap = 14d;
        var margin = 8d;

        var left = launcherBounds.Left - benchWidth - gap;
        if (left < workArea.Left)
        {
            left = launcherBounds.Left + launcherBounds.Width + gap;
        }

        left = Math.Max(workArea.Left + margin, Math.Min(left, workArea.Right - benchWidth - margin));

        var top = launcherBounds.Top + launcherBounds.Height - benchHeight;
        top = Math.Max(workArea.Top + margin, Math.Min(top, workArea.Bottom - benchHeight - margin));

        Left = left;
        Top = top;
    }

    private static string ResolveRepoRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            if (File.Exists(Path.Combine(current.FullName, "package.json")) &&
                Directory.Exists(Path.Combine(current.FullName, "widget")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException(
            $"Could not locate the Windows-Clippy-MCP repository root from {AppContext.BaseDirectory}.");
    }

    private static string ResolveCopilotConfigDirectory()
    {
        var configured = Environment.GetEnvironmentVariable("COPILOT_CONFIG_DIR");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured;
        }

        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(userProfile, ".copilot");
    }
}

public sealed class WidgetLaunchOptions
{
    public bool OpenChat { get; set; } = true;

    public bool NoWelcome { get; set; }

    public string? SessionId { get; set; }

    public string? AppsViewUri { get; set; }
}

internal static class WidgetHostLogger
{
    private static readonly object SyncRoot = new();
    private static readonly string LogPath = BuildLogPath();

    public static void Log(string message)
    {
        try
        {
            var directory = Path.GetDirectoryName(LogPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            lock (SyncRoot)
            {
                File.AppendAllText(
                    LogPath,
                    $"[{DateTime.UtcNow:O}] {message}{Environment.NewLine}",
                    Encoding.UTF8);
            }
        }
        catch
        {
        }
    }

    private static string BuildLogPath()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData, "Windows-Clippy-MCP", "logs", "widgethost.log");
    }
}
