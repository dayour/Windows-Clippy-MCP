using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace WidgetHost;

internal sealed class CommanderBroadcastOutcome
{
    public CommanderBroadcastOutcome(TerminalTabSession session, CommanderDispatchResult result)
    {
        Session = session;
        Result = result;
    }

    public TerminalTabSession Session { get; }
    public CommanderDispatchResult Result { get; }
}

internal sealed class CommanderLinkGroup
{
    public CommanderLinkGroup(string label)
    {
        Label = label;
    }

    public string Label { get; }

    private readonly HashSet<Guid> _tabKeys = new();

    public IReadOnlyCollection<Guid> TabKeys
    {
        get
        {
            lock (_tabKeys)
            {
                return _tabKeys.ToArray();
            }
        }
    }

    public bool Add(Guid tabKey)
    {
        lock (_tabKeys) return _tabKeys.Add(tabKey);
    }

    public bool Remove(Guid tabKey)
    {
        lock (_tabKeys) return _tabKeys.Remove(tabKey);
    }

    public int Count
    {
        get { lock (_tabKeys) return _tabKeys.Count; }
    }
}

/// <summary>
/// Cross-tab Commander registry. Tracks every live TerminalTabSession so the
/// Commander can broadcast prompts, link sessions into named groups, and
/// observe the streaming copilot.event fan-out produced by clippy-swe.
///
/// Primary identity key is <see cref="TerminalTabSession.TabKey"/> (C#-generated Guid),
/// not the user-visible sessionId, because sessionId uniqueness is not enforced at
/// tab-creation time. sessionId is surfaced as a secondary lookup for user commands.
/// </summary>
internal sealed class CommanderHub
{
    private readonly ConcurrentDictionary<Guid, TerminalTabSession> _sessions = new();
    private readonly object _groupGate = new();
    private readonly Dictionary<string, CommanderLinkGroup> _groups = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<Guid, string> _tabToGroup = new();

    public event EventHandler<TerminalTabSession>? SessionRegistered;
    public event EventHandler<TerminalTabSession>? SessionUnregistered;
    public event EventHandler<CopilotEventArgs>? CopilotEvent;
    public event EventHandler? GroupsChanged;

    public int SessionCount => _sessions.Count;

    public IReadOnlyCollection<TerminalTabSession> Sessions => _sessions.Values.ToArray();

    public int WaitingCount => _sessions.Values.Count(static s => s.IsWaitingForResponse);

    public int GroupCount
    {
        get { lock (_groupGate) return _groups.Count; }
    }

    public void Register(TerminalTabSession session)
    {
        if (session is null)
        {
            return;
        }

        if (_sessions.TryAdd(session.TabKey, session))
        {
            session.CopilotEventReceived += OnSessionCopilotEvent;
            session.MetadataChanged += OnSessionMetadataChanged;
            SessionRegistered?.Invoke(this, session);
        }
    }

    public void Unregister(TerminalTabSession session)
    {
        if (session is null)
        {
            return;
        }

        if (_sessions.TryRemove(session.TabKey, out _))
        {
            session.CopilotEventReceived -= OnSessionCopilotEvent;
            session.MetadataChanged -= OnSessionMetadataChanged;
            RemoveFromGroup(session.TabKey, notify: true);
            SessionUnregistered?.Invoke(this, session);
        }
    }

    public TerminalTabSession? FindBySessionId(string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            return null;
        }

        return _sessions.Values.FirstOrDefault(s =>
            string.Equals(s.SessionId, sessionId, StringComparison.OrdinalIgnoreCase));
    }

    public IReadOnlyDictionary<string, IReadOnlyCollection<string>> DescribeGroups()
    {
        lock (_groupGate)
        {
            var result = new Dictionary<string, IReadOnlyCollection<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (var (label, group) in _groups)
            {
                var keys = group.TabKeys;
                var names = keys
                    .Select(k => _sessions.TryGetValue(k, out var s) ? s.DisplayName : "(closed)")
                    .ToArray();
                result[label] = names;
            }

            return result;
        }
    }

    public string? GetGroupLabel(TerminalTabSession session)
    {
        if (session is null)
        {
            return null;
        }

        lock (_groupGate)
        {
            return _tabToGroup.TryGetValue(session.TabKey, out var label) ? label : null;
        }
    }

    public CommanderLinkGroup Link(TerminalTabSession session, string label)
    {
        if (session is null)
        {
            throw new ArgumentNullException(nameof(session));
        }

        var trimmed = (label ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            throw new ArgumentException("Link label cannot be empty.", nameof(label));
        }

        lock (_groupGate)
        {
            if (_tabToGroup.TryGetValue(session.TabKey, out var existingLabel))
            {
                if (string.Equals(existingLabel, trimmed, StringComparison.OrdinalIgnoreCase) &&
                    _groups.TryGetValue(existingLabel, out var existingGroup))
                {
                    return existingGroup;
                }

                RemoveFromGroupLocked(session.TabKey, notify: false);
            }

            if (!_groups.TryGetValue(trimmed, out var group))
            {
                group = new CommanderLinkGroup(trimmed);
                _groups[trimmed] = group;
            }

            group.Add(session.TabKey);
            _tabToGroup[session.TabKey] = trimmed;
            session.GroupLabel = trimmed;
            GroupsChanged?.Invoke(this, EventArgs.Empty);
            return group;
        }
    }

    public bool Unlink(TerminalTabSession session)
    {
        if (session is null)
        {
            return false;
        }

        return RemoveFromGroup(session.TabKey, notify: true);
    }

    public async Task<IReadOnlyList<CommanderBroadcastOutcome>> BroadcastAsync(
        string prompt,
        IReadOnlyCollection<TerminalTabSession>? targets = null,
        bool force = false)
    {
        var selected = (targets ?? (IReadOnlyCollection<TerminalTabSession>)Sessions).ToArray();
        if (selected.Length == 0)
        {
            return Array.Empty<CommanderBroadcastOutcome>();
        }

        var dispatchTasks = selected.Select(session => Task.Run(() =>
        {
            try
            {
                var result = session.TryDispatchCommanderPrompt(prompt, force);
                return new CommanderBroadcastOutcome(session, result);
            }
            catch (Exception ex)
            {
                WidgetHostLogger.Log($"Commander broadcast to {session.DisplayName} failed: {ex.Message}");
                return new CommanderBroadcastOutcome(session, CommanderDispatchResult.NotReady);
            }
        })).ToArray();

        var results = await Task.WhenAll(dispatchTasks);
        return results;
    }

    public IReadOnlyCollection<TerminalTabSession> ResolveGroupMembers(string label)
    {
        if (string.IsNullOrWhiteSpace(label))
        {
            return Array.Empty<TerminalTabSession>();
        }

        lock (_groupGate)
        {
            if (!_groups.TryGetValue(label.Trim(), out var group))
            {
                return Array.Empty<TerminalTabSession>();
            }

            return group.TabKeys
                .Select(k => _sessions.TryGetValue(k, out var s) ? s : null)
                .Where(s => s is not null)
                .Cast<TerminalTabSession>()
                .ToArray();
        }
    }

    private void OnSessionCopilotEvent(object? sender, CopilotEventArgs e)
    {
        CopilotEvent?.Invoke(sender, e);
    }

    private void OnSessionMetadataChanged(object? sender, EventArgs e)
    {
        // MainWindow uses this hook to refresh aggregate counters.
        GroupsChanged?.Invoke(this, EventArgs.Empty);
    }

    private bool RemoveFromGroup(Guid tabKey, bool notify)
    {
        lock (_groupGate)
        {
            return RemoveFromGroupLocked(tabKey, notify);
        }
    }

    private bool RemoveFromGroupLocked(Guid tabKey, bool notify)
    {
        if (!_tabToGroup.TryGetValue(tabKey, out var label))
        {
            return false;
        }

        _tabToGroup.Remove(tabKey);
        if (_groups.TryGetValue(label, out var group))
        {
            group.Remove(tabKey);
            if (group.Count == 0)
            {
                _groups.Remove(label);
            }
        }

        if (_sessions.TryGetValue(tabKey, out var session))
        {
            session.GroupLabel = null;
        }

        if (notify)
        {
            GroupsChanged?.Invoke(this, EventArgs.Empty);
        }

        return true;
    }
}
