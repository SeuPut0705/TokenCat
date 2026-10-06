namespace TokenCat;

/// LogTurnState.swift: the turn bookkeeping the Copilot CLI, Amp and Droid readers share, with TokenLogParser's liveness
/// rules: an open turn counts as running for 600 s of silence, 900 s while a tool runs and 24 h while it waits for the
/// person; past that it is `Stale` for up to 30 minutes after the newest record, then `Unfinished`. Only counts, times,
/// names and ids are kept.
public sealed class LogTurnState(IReadOnlySet<string>? inputTools = null)
{
    /// Tool names that wait for the person rather than run.
    readonly IReadOnlySet<string> inputTools = inputTools ?? new HashSet<string>();
    public DateTimeOffset? LastActivity { get; private set; }
    /// Newest record of any kind; liveness only.
    public DateTimeOffset? LastLogAt { get; private set; }
    public bool TurnOpen { get; private set; }
    DateTimeOffset? startedAt;
    /// The open turn was seen from its start, so its output is whole.
    bool accurate;
    int output;
    TokenActivityState observedState = TokenActivityState.Idle;
    readonly List<(string Id, string? Name)> pendingTools = [];
    /// A permission prompt or another request for the person that is not a tool.
    readonly HashSet<string> pendingRequests = new(StringComparer.Ordinal);
    readonly List<TokenOutputEvent> recentOutputs = [];
    DateTimeOffset? lastOutputAt;
    int? lastOutputDelta;
    /// The last completed turn. Output logged after its close (before anything else happens) still belongs to it.
    (int Output, bool Accurate, DateTimeOffset FinishedAt, string? Model)? closed;
    bool closedTakesOutput;

    public void Logged(DateTimeOffset? date)
    {
        if (date is { } at) LastLogAt = LastLogAt is { } current && current > at ? current : at;
    }

    public void Touch(DateTimeOffset? date)
    {
        if (date is { } at) LastActivity = LastActivity is { } current && current > at ? current : at;
    }

    /// A record stamped ahead of the clock must not keep the newest times in the future.
    public void Clamp(DateTimeOffset ceiling)
    {
        if (LastLogAt > ceiling) LastLogAt = ceiling;
        if (LastActivity > ceiling) LastActivity = ceiling;
    }

    /// A new turn from the person's input. `whole` is false when its start may lie before what was read.
    public void Begin(DateTimeOffset? date, bool whole = true)
    {
        TurnOpen = true;
        startedAt = date;
        accurate = whole;
        output = 0;
        observedState = TokenActivityState.Working;
        pendingTools.Clear();
        pendingRequests.Clear();
        lastOutputAt = null;
        lastOutputDelta = null;
        closedTakesOutput = false;
        Touch(date);
    }

    /// Turn content while no turn is open: the turn began before what was read, so its output is not whole.
    public void Resume(DateTimeOffset? date)
    {
        if (!TurnOpen) Begin(date, whole: false);
    }

    public void SetState(TokenActivityState state, DateTimeOffset? date)
    {
        if (TurnOpen) observedState = state;
        Touch(date);
    }

    /// One logged output increment at its log time.
    public void AddOutput(int tokens, DateTimeOffset? date)
    {
        if (tokens <= 0) return;
        Touch(date);
        if (TurnOpen) output += tokens;
        else if (closedTakesOutput && closed is { } last) closed = last with { Output = last.Output + tokens };
        lastOutputAt = date;
        lastOutputDelta = tokens;
        if (date is not { } at) return;
        recentOutputs.Add(new TokenOutputEvent(at, tokens));
        if (recentOutputs.Count > 512) recentOutputs.RemoveRange(0, recentOutputs.Count - 512);
    }

    public void StartTool(string id, string? name, DateTimeOffset? date)
    {
        pendingTools.RemoveAll(tool => tool.Id == id);
        pendingTools.Add((id, name));
        if (pendingTools.Count > 256) pendingTools.RemoveRange(0, pendingTools.Count - 256);
        SetState(TokenActivityState.Tool, date);
    }

    public void FinishTool(string id, DateTimeOffset? date)
    {
        var index = pendingTools.FindIndex(tool => tool.Id == id);
        if (index < 0) return;
        pendingTools.RemoveAt(index);
        SetState(pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool, date);
    }

    public void StartRequest(string id, DateTimeOffset? date)
    {
        if (TurnOpen) pendingRequests.Add(id);
        Touch(date);
    }

    public void FinishRequest(string id) => pendingRequests.Remove(id);

    public bool HasPendingTools => pendingTools.Count > 0;

    /// Ends the open turn. A completed one becomes the last completed turn (its output counts when the whole turn was
    /// read); an interrupted one leaves the previous completed turn in place.
    public void Close(TokenActivityState state, DateTimeOffset? date, string? model)
    {
        if (!TurnOpen) return;
        TurnOpen = false;
        observedState = state;
        pendingTools.Clear();
        pendingRequests.Clear();
        Touch(date);
        closedTakesOutput = state == TokenActivityState.Complete;
        if (closedTakesOutput) closed = (output, accurate, date ?? LastActivity ?? DateTimeOffset.MinValue, model);
    }

    public TokenTurnCompletion? Completion =>
        closed is { Accurate: true, Output: > 0 } last ? new TokenTurnCompletion(last.Output, null, last.FinishedAt, last.Model) : null;

    /// The outstanding tool that holds an open turn: one waiting for the person, else the newest.
    public (string Id, string? Name)? RunningTool =>
        !TurnOpen || pendingTools.Count == 0 ? null
        : pendingTools.LastOrDefault(tool => inputTools.Contains(tool.Name ?? "")) is { Id: not null } waiting ? waiting : pendingTools[^1];

    bool WaitsForInput => TurnOpen && (pendingRequests.Count > 0 || pendingTools.Any(tool => inputTools.Contains(tool.Name ?? "")));

    DateTimeOffset? LiveAt => LastLogAt is { } log && LastActivity is { } activity ? (log > activity ? log : activity) : LastLogAt ?? LastActivity;

    double LiveHorizon => WaitsForInput ? 86_400 : pendingTools.Count == 0 ? 600 : 900;

    public bool IsActive(DateTimeOffset now) =>
        TurnOpen && LiveAt is { } live && (now - live).TotalSeconds is var age && age >= -5 && age <= LiveHorizon;

    public bool IsRecent(DateTimeOffset now) => TurnOpen || LiveAt is { } live && (now - live).TotalSeconds <= 3_600;

    public TokenActivityState ActivityState(DateTimeOffset now)
    {
        if (!TurnOpen) return observedState;
        if (WaitsForInput) return IsActive(now) ? TokenActivityState.Input : TokenActivityState.Unfinished;
        if (IsActive(now)) return observedState;
        return LiveAt is { } live && (now - live).TotalSeconds <= 1_800 ? TokenActivityState.Stale : TokenActivityState.Unfinished;
    }

    /// The shared reading fields; null until the log showed content. `cwd` gives Project and ProjectPath.
    public TokenReading? Reading(TokenSource source, string id, string? model, string? cwd, DateTimeOffset now)
    {
        if (LastActivity is null) return null;
        var completion = Completion;
        var tool = RunningTool;
        return new TokenReading(source, id)
        {
            Model = model ?? completion?.Model,
            ToolName = tool?.Name,
            ToolCategory = tool is { } running ? running.Name is { } name ? TokenLogParser.Category(name) : ToolCategory.Other : null,
            // Windows logs hold C:\Users\me\proj, so split on both separators on every OS (rule 7).
            Project = string.IsNullOrEmpty(cwd) ? null : cwd.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries) is [.., var last] ? last : cwd,
            ProjectPath = string.IsNullOrEmpty(cwd) ? null : cwd,
            LastActivity = LastActivity,
            LastLogAt = LastLogAt,
            MeasurementAt = completion?.FinishedAt ?? LastActivity,
            Active = IsActive(now),
            ActivityState = ActivityState(now),
            CurrentTurnStartedAt = TurnOpen ? startedAt : null,
            CurrentTurnOutputTokens = TurnOpen && accurate ? output : null,
            LastOutputAt = lastOutputAt,
            LastOutputDelta = lastOutputDelta,
            RecentOutputs = [.. recentOutputs.Where(e => (now - e.At).TotalSeconds is >= -5 and <= TokenTracker.RecentOutputWindow)],
            LastOutputTokens = completion?.Output,
            SampledAt = now,
        };
    }
}
