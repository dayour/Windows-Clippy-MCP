namespace WidgetHost;

internal sealed record SlashSuggestion(string Command, string Description, bool HasArgument = false);

internal static class SlashCommandCatalog
{
    public static readonly SlashSuggestion[] RootCommands =
    [
        new("/new",        "Open a fresh Clippy bench tab"),
        new("/session",    "Show the active bench session id"),
        new("/mode",       "Set Commander mode",                   HasArgument: true),
        new("/agent",      "Switch the active agent",              HasArgument: true),
        new("/agents",     "List discovered agents"),
        new("/model",      "Switch the language model",            HasArgument: true),
        new("/mcp",        "Add or configure an MCP server",       HasArgument: true),
        new("/skill",      "Invoke a Copilot skill",               HasArgument: true),
        new("/tools",      "Open tool settings"),
        new("/extensions", "Open extension settings"),
        new("/files",      "Inspect local Commander attachments"),
        new("/link",       "Add current tab to a link group",      HasArgument: true),
        new("/unlink",     "Remove current tab from its link group"),
        new("/groups",     "List Commander link groups"),
        new("/broadcast",  "Send a prompt to every tab",           HasArgument: true),
        new("/group",      "Send a prompt to current tab's group", HasArgument: true),
        new("/help",       "Show Commander help"),
        new("/?",          "Show Commander help"),
        new("/clear",      "Clear conversation history"),
        new("/apps",       "MCP Apps: list / mount / unmount / inspect", HasArgument: true),
        new("/apps-dev",   "Toggle MCP Apps text-fallback diagnostics"),
    ];

    // MCP Apps sub-commands (completed when user types "/apps ")
    public static readonly SlashSuggestion[] AppsSubCommands =
    [
        new("list",    "List every registered MCP App (tool + ui resource)"),
        new("mount",   "Mount a named MCP App view in the widget",   HasArgument: true),
        new("unmount", "Unmount a named MCP App view",                HasArgument: true),
        new("inspect", "Show diagnostics for a mounted MCP App view", HasArgument: true),
    ];

    // MCP server names known from the DAYOURBOT fleet configuration
    public static readonly string[] McpServers =
    [
        "ado --org powercatteam",
        "ado --org domoreexp",
        "bluebird --org powercatteam",
        "icm",
        "kusto",
        "workiq",
        "es-chat",
        "msft-learn",
        "security-context",
        "calculator",
        "stack",
        "remote",
        "local",
        "npx",
    ];

    // Skill names from the GitHub Copilot CLI skills directory
    public static readonly string[] Skills =
    [
        "appinsights-instrumentation",
        "azure-ai",
        "azure-aigateway",
        "azure-compliance",
        "azure-cost-optimization",
        "azure-deploy",
        "azure-diagnostics",
        "azure-kusto",
        "azure-observability",
        "azure-postgres",
        "azure-prepare",
        "azure-rbac",
        "azure-resource-lookup",
        "azure-resource-visualizer",
        "azure-storage",
        "azure-validate",
        "customizing-copilot-cloud-agents-environment",
        "entra-app-registration",
        "microsoft-foundry",
    ];
}
