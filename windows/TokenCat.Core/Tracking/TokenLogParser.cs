using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Text.Unicode;

namespace TokenCat;

/// A fully observed completed turn. Output and the client-reported duration are never divided.
public sealed record TokenTurnCompletion(int Output, double? DurationSeconds, DateTimeOffset FinishedAt, string? Model);

sealed record CodexMetadataCheckpoint(string? TurnID, string? Model, string? Cwd, string? Effort, bool? OpensTurn,
    DateTimeOffset? Timestamp, bool IsInherited, DateTimeOffset? ActualStart, TokenActivityState ActivityState, int? TurnOutputTokens = null);

/// TokenTracker.swift's parser: only usage, timestamps, lifecycle IDs and model names survive parsing.
public sealed class TokenLogParser(TokenSource source, bool isSubagent = false, string? ownSessionID = null)
{
    public enum TurnBoundary { Start, End }
    enum ClaudeInput { Human, Interrupted, ToolResult, None }

    public TokenSource Source { get; } = source;
    public string? SessionID { get; private set; }
    public string? ParentSessionID { get; private set; }
    public string? AgentID { get; private set; }
    public string? Project { get; private set; }
    public string? ProjectPath { get; private set; }
    public bool IsSubagent { get; private set; } = isSubagent;
    public string? Model { get; private set; }
    public string? Effort { get; private set; }
    public string? AgentRole { get; private set; }
    /// Client-reported duration of the last completed turn (Codex duration_ms, Claude durationMs).
    public double? LastTurnDuration { get; private set; }
    public TokenRetryState? Retry { get; private set; }
    public TokenRateLimit? RateLimit { get; private set; }
    public DateTimeOffset? LastActivity { get; private set; }
    /// Newest record timestamp of any kind. Liveness only; content state uses LastActivity.
    public DateTimeOffset? LastLogAt { get; private set; }
    public int? LatestOutput { get; private set; }
    public TokenTurnCompletion? Completion { get; private set; }
    public DateTimeOffset? LastOutputAt { get; private set; }
    public int? LastOutputDelta { get; private set; }
    public IReadOnlyList<TokenOutputEvent> RecentOutputs => recentOutputs;
    /// Claude: request IDs of logged responses, so telemetry for an unlogged side request is not taken as this log's.
    public IReadOnlySet<string> RequestIDs => requestIDs;

    readonly string? ownSessionID = ownSessionID;
    TokenContextUsage? contextUsage;
    DateTimeOffset? compactedAt;
    /// Codex: an own (non-inherited) turn has been observed, so usage snapshots are this thread's.
    bool ownTurnSeen;
    readonly List<TokenOutputEvent> recentOutputs = [];
    DateTimeOffset? startedAt;
    string? turnID;
    int output;
    bool hasUsage;
    bool accurate = true;
    int? cumulativeOutput;
    readonly Dictionary<string, int> messages = new(StringComparer.Ordinal);
    readonly HashSet<string> previousMessages = new(StringComparer.Ordinal);
    HashSet<string> closedTurnIDs = new(StringComparer.Ordinal);
    DateTimeOffset? sessionCreatedAt;
    bool ignoringInheritedTurn;
    string? ignoredTurnID;
    bool inheritedTurnClosed;
    (string? Id, string Model, string? Cwd, string? Effort)? pendingContext;
    bool metadataTurnOpen;
    string? metadataTurnID;
    DateTimeOffset? activityStartedAt;
    TokenActivityState observedState = TokenActivityState.Idle;
    /// Outstanding tool calls in call order, id → name. Inputs are never read.
    readonly List<(string Id, string? Name)> pendingTools = [];
    /// Tools that wait for the person rather than run: Claude's question and plan approval, and
    /// Codex's blocking request_user_input (plan mode). request_user_input_async is non-blocking.
    static readonly HashSet<string> InputTools = new(["AskUserQuestion", "ExitPlanMode", "request_user_input"], StringComparer.Ordinal);
    /// Codex writes token_usage_record right after each response, before the tool
    /// output that precedes the matching token_count. Once present it is authoritative.
    bool usageRecords;
    readonly HashSet<string> seenResponses = new(StringComparer.Ordinal);
    (string TurnID, int Output)? turnUsage;
    bool identityLocked;
    /// Claude: a final reply (end_turn without tool use) or an API error closes the turn unless
    /// later records continue it, e.g. a blocking Stop hook. Subagents write no stop markers.
    bool softClosed;
    readonly HashSet<string> seenRecords = new(StringComparer.Ordinal);
    readonly HashSet<string> requestIDs = new(StringComparer.Ordinal);
    string? outputMessageID;

    public void Consume(ReadOnlySpan<byte> line)
    {
        if (Record(line) is not { } record) return;
        ConsumeMetadata(record);
        var date = Date(record.Field("timestamp"));
        if (Source == TokenSource.Codex) ConsumeCodex(record, date);
        else ConsumeClaude(record, date, LastLogAt);
        if (date is { } at) LastLogAt = Max(LastLogAt, at);
    }

    public void ConsumeMetadata(ReadOnlySpan<byte> line)
    {
        if (Record(line) is { } record) ConsumeMetadata(record);
    }

    /// `JSONSerialization.jsonObject(with:) as? [String: Any]`: an object, and like Foundation it rejects invalid UTF-8 and
    /// unpaired surrogate escapes (System.Text.Json would accept both and throw later, on the first GetString).
    internal static JsonElement? Record(ReadOnlySpan<byte> line)
    {
        if (!Utf8.IsValid(line) || Json.Parse(line) is not { ValueKind: JsonValueKind.Object } record) return null;
        if (line.IndexOf("\\ud"u8) < 0 && line.IndexOf("\\uD"u8) < 0) return record;
        try { Walk(record); return record; }
        catch (InvalidOperationException) { return null; }

        static void Walk(JsonElement value)
        {
            switch (value.ValueKind)
            {
                case JsonValueKind.Object:
                    foreach (var property in value.EnumerateObject()) { _ = property.Name; Walk(property.Value); }
                    break;
                case JsonValueKind.Array:
                    foreach (var item in value.EnumerateArray()) Walk(item);
                    break;
                case JsonValueKind.String:
                    _ = value.GetString();
                    break;
            }
        }
    }

    void ConsumeMetadata(JsonElement record)
    {
        if (Source == TokenSource.Claude && record.Field("isSidechain")?.Bool == true && !IsSubagent) return;
        string? cwd = null;
        if (Source == TokenSource.Codex && record.Field("type")?.Text == "session_meta"
            && record.Field("payload") is { ValueKind: JsonValueKind.Object } payload)
        {
            // Forked logs replay the parent's session_meta after their own; it must not
            // replace this thread's identity or creation time (which detects inherited turns).
            var id = payload.Field("id")?.Text ?? payload.Field("session_id")?.Text;
            if (ownSessionID is not null) { if (id?.ToLowerInvariant() != ownSessionID) return; }
            else if (identityLocked) return;
            identityLocked = true;
            SessionID = id ?? SessionID;
            sessionCreatedAt = Date(payload.Field("timestamp")) ?? sessionCreatedAt;
            cwd = payload.Field("cwd")?.Text;
            if (payload.Field("source")?.Field("subagent") is { } subagent)
            {
                IsSubagent = true;
                AgentID = payload.Field("agent_path")?.Text ?? payload.Field("agent_id")?.Text ?? SessionID;
                var spawn = subagent.Field("thread_spawn");
                var root = payload.Field("session_id")?.Text is { } sessionID && sessionID != id ? sessionID : null;
                ParentSessionID = root ?? spawn?.Field("parent_thread_id")?.Text ?? payload.Field("parent_thread_id")?.Text;
                // Role, then nickname; automatic review threads carry only `subagent.other`.
                AgentRole = new[] { spawn?.Field("agent_role"), payload.Field("agent_role"), payload.Field("agent_nickname"),
                    spawn?.Field("agent_nickname"), subagent.Field("other") }.Select(Label).FirstOrDefault(label => label is not null);
            }
        }
        else if (Source == TokenSource.Claude)
        {
            SessionID = record.Field("sessionId")?.Text ?? SessionID;
            AgentID = record.Field("agentId")?.Text ?? AgentID;
            cwd = record.Field("cwd")?.Text;
            if (IsSubagent) ParentSessionID = SessionID;
        }
        SetProject(cwd);
    }

    void SetProject(string? cwd)
    {
        if (string.IsNullOrEmpty(cwd)) return;
        // Windows logs hold C:\Users\me\proj, so split on both separators on every OS (rule 7).
        Project = cwd.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries) is [.., var last] ? last : cwd;
        ProjectPath = cwd;
    }

    /// A short client-defined name (role, nickname, effort); anything else is dropped.
    public static string? Label(JsonElement? value) =>
        value?.Text is { } text && new StringInfo(text).LengthInTextElements is >= 1 and <= 48
        && text.EnumerateRunes().All(rune => Rune.GetUnicodeCategory(rune) <= UnicodeCategory.OtherNumber // L*, M*, N*
                                             || rune.Value is ' ' or '_' or '.' or ':' or '-')
            ? text : null;

    /// Category from the tool name only. Names verified in local logs: Claude Bash/Read/Write/
    /// Edit/WebFetch/WebSearch/Agent/Workflow/AskUserQuestion/mcp__*; Codex exec/js/spawn_agent/
    /// wait_agent/send_message/followup_task/list_agents/request_user_input_async.
    public static ToolCategory Category(string name) => name.StartsWith("mcp__", StringComparison.Ordinal) ? ToolCategory.Mcp : name switch
    {
        "Bash" or "BashOutput" or "exec" or "exec_command" or "shell" or "local_shell" or "js" or "unified_exec" => ToolCategory.Command,
        "Read" or "Write" or "Edit" or "MultiEdit" or "NotebookEdit" or "Glob" or "Grep" or "apply_patch" => ToolCategory.File,
        "WebFetch" or "WebSearch" or "web_search" or "web_fetch" => ToolCategory.Web,
        "Task" or "Agent" or "Workflow" or "SendMessage" or "ListAgents" or "spawn_agent" or "wait_agent"
            or "send_message" or "followup_task" or "list_agents" or "close_agent" => ToolCategory.Agent,
        "ListMcpResourcesTool" or "ReadMcpResourceTool" => ToolCategory.Mcp,
        "AskUserQuestion" or "ExitPlanMode" or "request_user_input" or "request_user_input_async" => ToolCategory.Question,
        _ => ToolCategory.Other,
    };

    /// The outstanding tool that holds an open turn: one waiting for the person, else the newest.
    public (string Id, string? Name)? RunningTool
    {
        get
        {
            if (!TurnOpen) return null;
            for (var i = pendingTools.Count - 1; i >= 0; i--)
                if (InputTools.Contains(pendingTools[i].Name ?? "")) return pendingTools[i];
            return pendingTools.Count > 0 ? pendingTools[^1] : null;
        }
    }

    bool WaitsForInput => TurnOpen && pendingTools.Any(tool => InputTools.Contains(tool.Name ?? ""));

    public TokenContextUsage? Context => contextUsage is { } usage ? usage with { CompactedAt = compactedAt } : null;

    void AddPendingTool(string id, JsonElement? name)
    {
        pendingTools.RemoveAll(tool => tool.Id == id);
        pendingTools.Add((id, name?.Text));
        if (pendingTools.Count > 256) pendingTools.RemoveRange(0, pendingTools.Count - 256);
    }

    bool RemovePendingTool(string id)
    {
        var index = pendingTools.FindIndex(tool => tool.Id == id);
        if (index < 0) return false;
        pendingTools.RemoveAt(index);
        return true;
    }

    bool TurnOpen => (startedAt is not null || metadataTurnOpen) && !softClosed;
    DateTimeOffset? LiveAt => LastLogAt is { } log ? Max(LastActivity, log) : LastActivity;

    /// How long an open turn may stay silent and still count as running. Codex tools yield
    /// within 30 s; Claude tools (Bash, questions) can run for minutes; model waits reach ~8 min.
    /// A question or plan approval waits for the person, so it never goes stale; a client
    /// that was killed with the question open is capped at 24 hours.
    double LiveHorizon => WaitsForInput ? 86_400 : pendingTools.Count == 0 ? 600 : Source == TokenSource.Claude ? 900 : 120;

    public bool IsActive(DateTimeOffset now)
    {
        if (!TurnOpen || LiveAt is not { } live) return false;
        var age = (now - live).TotalSeconds;
        return age >= -5 && age <= LiveHorizon;
    }

    /// Worth keeping a cursor for even when newer files outrank it.
    public bool IsRecent(DateTimeOffset now) => TurnOpen || LiveAt is { } live && (now - live).TotalSeconds <= 3_600;

    public DateTimeOffset? CurrentTurnStartedAt => TurnOpen ? activityStartedAt : null;

    public int? CurrentTurnOutputTokens
    {
        get
        {
            if (!TurnOpen) return null;
            // Codex reports the whole turn's output directly, even when its start is outside the tail.
            if (turnUsage is { } usage && usage.TurnID == (turnID ?? metadataTurnID)) return usage.Output;
            return startedAt is not null && accurate ? output : null;
        }
    }

    void RecordOutput(int tokens, DateTimeOffset? date)
    {
        if (tokens <= 0) return;
        if (date is { } at) LastActivity = Max(LastActivity, at);
        LastOutputAt = date;
        LastOutputDelta = tokens;
        if (date is not { } time) return;
        recentOutputs.Add(new TokenOutputEvent(time, tokens));
        if (recentOutputs.Count > 512) recentOutputs.RemoveRange(0, recentOutputs.Count - 512);
    }

    public TokenActivityState ActivityState(DateTimeOffset now)
    {
        if (!TurnOpen) return observedState;
        if (WaitsForInput) return IsActive(now) ? TokenActivityState.Input : TokenActivityState.Unfinished;
        if (IsActive(now)) return observedState;
        return LiveAt is { } live && (now - live).TotalSeconds <= 1_800 ? TokenActivityState.Stale : TokenActivityState.Unfinished;
    }

    internal CodexMetadataCheckpoint? CodexMetadataCheckpointOf(ReadOnlySpan<byte> line)
    {
        var prefix = line[..Math.Min(512, line.Length)];
        if (prefix.IndexOf("\"turn_context\""u8) < 0 && prefix.IndexOf("\"event_msg\""u8) < 0
            && prefix.IndexOf("\"token_usage_record\""u8) < 0
            || Record(line) is not { } record || record.Field("payload") is not { ValueKind: JsonValueKind.Object } payload) return null;
        var id = payload.Field("turn_id")?.Text;
        var type = record.Field("type")?.Text;
        var timestamp = Date(record.Field("timestamp"));
        if (type == "token_usage_record")
        {
            if (id is null || Integer(payload.Field("turn_token_usage")?.Field("output_tokens")) is not { } turnOutput) return null;
            return new(id, null, null, null, null, timestamp, false, null, TokenActivityState.Idle, turnOutput);
        }
        if (type == "turn_context" && payload.Field("model")?.Text is { } model)
            return new(id, model, payload.Field("cwd")?.Text, CodexEffort(payload), null, timestamp, false, null, TokenActivityState.Idle);
        if (type != "event_msg" || payload.Field("type")?.Text is not { } lifecycleEvent
            || lifecycleEvent is not ("task_started" or "task_complete" or "turn_aborted" or "task_aborted")) return null;
        var start = Date(payload.Field("started_at")) ?? timestamp;
        var inherited = start is { } begun && sessionCreatedAt is { } created && begun < created.AddSeconds(-1.5);
        var opens = lifecycleEvent == "task_started";
        return new(id, null, null, null, opens, timestamp ?? start, inherited, opens ? start : null,
            opens ? TokenActivityState.Working : lifecycleEvent == "task_complete" ? TokenActivityState.Complete : TokenActivityState.Interrupted);
    }

    internal void RestoreCodexMetadata(CodexMetadataCheckpoint? context, CodexMetadataCheckpoint? lifecycle,
        CodexMetadataCheckpoint? opener, CodexMetadataCheckpoint? usage = null)
    {
        if (lifecycle is null) return;
        // A completion's write time does not establish who owned the turn. Its actual
        // matching start must be found within the bounded scan before restoring history.
        if (opener is null || opener.IsInherited)
        {
            ignoringInheritedTurn = true;
            ignoredTurnID = lifecycle.TurnID;
            inheritedTurnClosed = lifecycle.OpensTurn == false;
            pendingContext = null;
            Model = null;
            Effort = null;
            cumulativeOutput = null;
            metadataTurnOpen = false;
            metadataTurnID = null;
            activityStartedAt = null;
            observedState = TokenActivityState.Idle;
            return;
        }
        if (context is not null)
        {
            Model = context.Model ?? Model;
            Effort = context.Effort ?? Effort;
            SetProject(context.Cwd);
        }
        ownTurnSeen = true;
        metadataTurnOpen = lifecycle.OpensTurn == true;
        metadataTurnID = metadataTurnOpen ? lifecycle.TurnID : null;
        activityStartedAt = metadataTurnOpen ? opener.ActualStart : null;
        observedState = lifecycle.ActivityState;
        if (lifecycle.Timestamp is { } date) LastActivity = Max(LastActivity, date);
        if (usage is null) return;
        usageRecords = true;
        if (metadataTurnOpen && usage.TurnID is { } id && id == metadataTurnID && usage.TurnOutputTokens is { } turnOutput)
        {
            turnUsage = (id, turnOutput);
            if (usage.Timestamp is { } at) LastActivity = Max(LastActivity, at);
        }
    }

    void Begin(string? id, DateTimeOffset? date)
    {
        startedAt = date;
        softClosed = false;
        metadataTurnOpen = false;
        metadataTurnID = null;
        activityStartedAt = date;
        observedState = TokenActivityState.Working;
        LastOutputAt = null;
        LastOutputDelta = null;
        Retry = null;
        pendingTools.Clear();
        turnID = id;
        turnUsage = null;
        output = 0;
        hasUsage = false;
        accurate = true;
        previousMessages.UnionWith(messages.Keys);
        if (previousMessages.Count > 2_048) previousMessages.Clear();
        messages.Clear();
    }

    /// The open turn's whole output when it is known: Codex's recorded turn total, or every
    /// response of a turn observed from its start.
    int? ObservedTurnOutput =>
        turnUsage is { } usage && usage.TurnID == (turnID ?? metadataTurnID) ? usage.Output
        : startedAt is not null && accurate && hasUsage ? output : null;

    /// Records the last completed turn. An unknown output clears it rather than leaving an
    /// earlier turn's value under the "last completed turn" label.
    void RecordCompletion(DateTimeOffset? date, double? duration)
    {
        LastTurnDuration = duration is { } seconds && double.IsFinite(seconds) && seconds > 0 ? seconds : null;
        if (ObservedTurnOutput is { } total && total > 0 && (date ?? LastLogAt) is { } finished)
        {
            Completion = new TokenTurnCompletion(total, LastTurnDuration, finished, Model);
            LatestOutput = total;
        }
        else Completion = null;
    }

    /// `date` is the record's parsed `timestamp`.
    void ConsumeCodex(JsonElement record, DateTimeOffset? date)
    {
        var type = record.Field("type")?.Text;
        var payload = record.Field("payload"); // a non-object reads as Swift's `?? [:]`: every Field is null
        if (type == "session_meta") return;
        if (type == "token_usage_record")
        {
            ConsumeCodexUsageRecord(payload, date);
            return;
        }
        if (type == "turn_context")
        {
            if (payload?.Field("model")?.Text is { } contextModel)
            {
                if (!ignoringInheritedTurn)
                {
                    Model = contextModel;
                    Effort = CodexEffort(payload) ?? Effort;
                    SetProject(payload?.Field("cwd")?.Text);
                }
                else if (inheritedTurnClosed)
                    pendingContext = (payload?.Field("turn_id")?.Text, contextModel, payload?.Field("cwd")?.Text, CodexEffort(payload));
            }
            return;
        }
        // A compaction finished at this time. Forked logs replay the parent's before any own turn.
        if (type == "compacted")
        {
            if (OwnUsageSnapshot && date is { } at) compactedAt = Max(compactedAt, at);
            return;
        }
        if (type == "response_item" && !ignoringInheritedTurn && (startedAt is not null || metadataTurnOpen)
            && payload?.Field("type")?.Text is { } itemType)
        {
            var tool = pendingTools.Count == 0 ? (TokenActivityState?)null : TokenActivityState.Tool;
            TokenActivityState? phase;
            switch (itemType)
            {
                case "function_call" or "custom_tool_call":
                    if (payload?.Field("call_id")?.Text is { } callID) AddPendingTool(callID, payload?.Field("name"));
                    phase = TokenActivityState.Tool;
                    break;
                case "function_call_output" or "custom_tool_call_output":
                    if (payload?.Field("call_id")?.Text is { } resultID) RemovePendingTool(resultID);
                    phase = pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool;
                    break;
                case "reasoning": phase = tool ?? TokenActivityState.Working; break;
                case "agent_message": phase = tool ?? TokenActivityState.Output; break;
                case "message": phase = payload?.Field("role")?.Text == "assistant" ? tool ?? TokenActivityState.Output : null; break;
                default: phase = null; break;
            }
            if (phase is { } state)
            {
                observedState = state;
                if (date is { } at) LastActivity = Max(LastActivity, at);
            }
            return;
        }
        if (type != "event_msg" || payload?.Field("type")?.Text is not { } eventType) return;
        switch (eventType)
        {
            case "task_started":
            {
                var id = payload?.Field("turn_id")?.Text;
                var start = Date(payload?.Field("started_at")) ?? date;
                // Forked logs can replay parent lifecycle events with the child's write time.
                // payload.started_at identifies turns older than this log's actual session.
                if (start is { } begun && sessionCreatedAt is { } created && begun < created.AddSeconds(-1.5))
                {
                    if (startedAt is null)
                    {
                        ignoringInheritedTurn = true;
                        ignoredTurnID = id;
                        inheritedTurnClosed = false;
                        pendingContext = null;
                        Model = null;
                        Effort = null;
                        cumulativeOutput = null;
                    }
                    return;
                }
                if (id is not null && closedTurnIDs.Contains(id)) return;
                if (id is not null && id == turnID) return;
                ignoringInheritedTurn = false;
                ignoredTurnID = null;
                inheritedTurnClosed = false;
                if (pendingContext is { } pending && (pending.Id is null || pending.Id == id))
                {
                    Model = pending.Model;
                    Effort = pending.Effort ?? Effort;
                    SetProject(pending.Cwd);
                }
                pendingContext = null;
                Begin(id, start);
                ownTurnSeen = true;
                metadataTurnOpen = true;
                metadataTurnID = id;
                LastActivity = date ?? LastActivity;
                break;
            }
            case "token_count":
            {
                if (OwnUsageSnapshot && date is { } at) ConsumeCodexSnapshot(payload, at);
                // The matching token_usage_record already counted this response.
                if (ignoringInheritedTurn || usageRecords) return;
                if (payload?.Field("info") is not { ValueKind: JsonValueKind.Object } info) return;
                if (Integer(info.Field("total_token_usage")?.Field("output_tokens")) is not { } count)
                {
                    if (startedAt is not null) accurate = false;
                    return;
                }
                var last = Integer(info.Field("last_token_usage")?.Field("output_tokens"));
                var delta = cumulativeOutput is { } previous ? count >= previous ? count - previous : last : last;
                cumulativeOutput = count;
                if (delta is { } tokens && tokens >= 0)
                {
                    if (tokens > 0)
                    {
                        LastActivity = date ?? LastActivity;
                        LatestOutput = tokens;
                        RecordOutput(tokens, date);
                    }
                    if (startedAt is not null)
                    {
                        output += tokens;
                        hasUsage = true;
                    }
                }
                else if (startedAt is not null) accurate = false;
                break;
            }
            case "task_complete":
            {
                var id = payload?.Field("turn_id")?.Text;
                if (ignoringInheritedTurn && id == ignoredTurnID)
                {
                    inheritedTurnClosed = true;
                    return;
                }
                // Only the open turn's own completion reports this thread's duration.
                if (!(metadataTurnOpen && id == metadataTurnID || startedAt is not null && turnID == id)) return;
                var duration = Number(payload?.Field("duration_ms"), MaxDurationMs) / 1_000;
                CloseTurn(TokenActivityState.Complete, date, duration, Date(payload?.Field("completed_at")));
                if (id is not null)
                {
                    closedTurnIDs.Add(id);
                    if (closedTurnIDs.Count > 256) closedTurnIDs = new([id], StringComparer.Ordinal);
                }
                break;
            }
            case "turn_aborted" or "task_aborted":
            {
                if (ignoringInheritedTurn) return;
                if (payload?.Field("turn_id")?.Text is { } id && (turnID ?? metadataTurnID) is { } current && id != current) return;
                metadataTurnOpen = false;
                metadataTurnID = null;
                startedAt = null;
                turnID = null;
                turnUsage = null;
                activityStartedAt = null;
                observedState = TokenActivityState.Interrupted;
                pendingTools.Clear();
                LastActivity = date ?? LastActivity;
                break;
            }
        }
    }

    /// Codex usage snapshots belong to this thread only after its own turn: forked logs
    /// replay the parent's records (with the child's write time) before the first own turn.
    bool OwnUsageSnapshot => Source == TokenSource.Codex && ownTurnSeen && !ignoringInheritedTurn;

    /// Account usage limit and context fill as the client wrote them; newest record wins.
    void ConsumeCodexSnapshot(JsonElement? payload, DateTimeOffset date)
    {
        // Accounts report one or two windows (e.g. 5-hour primary, weekly secondary); the most
        // constrained one is kept, labelled by its own window length.
        if (payload?.Field("rate_limits") is { ValueKind: JsonValueKind.Object } limits
            && (limits.Field("limit_id")?.Text is not { } limitID || limitID == "codex")
            && (RateLimit is null || date >= RateLimit.RecordedAt))
        {
            TokenRateLimit? window = null;
            foreach (var key in (string[])["primary", "secondary"])
            {
                var limit = limits.Field(key);
                if (limit?.Field("used_percent")?.Number is not { } used || used < 0 || used > 1_000) continue;
                var candidate = new TokenRateLimit(used, Integer(limit?.Field("window_minutes")), Date(limit?.Field("resets_at")), date);
                // Swift's max(by:) keeps the first of equal windows.
                if (window is null || (window.UsedPercent, window.WindowMinutes ?? 0).CompareTo((candidate.UsedPercent, candidate.WindowMinutes ?? 0)) < 0)
                    window = candidate;
            }
            if (window is not null) RateLimit = window;
        }
        // input_tokens already includes cached input; the window comes from the same record.
        var info = payload?.Field("info");
        if (Integer(info?.Field("last_token_usage")?.Field("input_tokens")) is { } input
            && (contextUsage is null || date >= contextUsage.RecordedAt))
            contextUsage = new TokenContextUsage(input, Integer(info?.Field("model_context_window")) is { } size && size > 0 ? size : null, date, null);
    }

    static string? CodexEffort(JsonElement? payload) =>
        Label(payload?.Field("effort")) ?? Label(payload?.Field("collaboration_mode")?.Field("settings")?.Field("reasoning_effort"));

    void ConsumeCodexUsageRecord(JsonElement? payload, DateTimeOffset? date)
    {
        if (ignoringInheritedTurn || Integer(payload?.Field("usage")?.Field("output_tokens")) is not { } delta) return;
        var id = payload?.Field("turn_id")?.Text;
        var current = turnID ?? metadataTurnID;
        // A record for a different turn than the open one is replayed history, not this turn's output.
        if (id is not null && current is not null && id != current) return;
        if (payload?.Field("response_id")?.Text is { } response)
        {
            if (seenResponses.Contains(response)) return;
            if (seenResponses.Count >= 4_096) seenResponses.Clear();
            seenResponses.Add(response);
        }
        usageRecords = true;
        if (id is not null && id == current && Integer(payload?.Field("turn_token_usage")?.Field("output_tokens")) is { } total)
            turnUsage = (id, total);
        if (delta > 0)
        {
            LatestOutput = delta;
            RecordOutput(delta, date);
        }
        if (startedAt is not null)
        {
            output += delta;
            hasUsage = true;
        }
    }

    void ConsumeClaude(JsonElement record, DateTimeOffset? date, DateTimeOffset? previousLog)
    {
        if (record.Field("isSidechain")?.Bool == true && !IsSubagent) return;
        var type = record.Field("type")?.Text;
        // Restored or branched sessions re-append earlier records with their original uuids
        // and timestamps; replaying them would rewind the turn.
        if (record.Field("uuid")?.Text is { } uuid)
        {
            if (seenRecords.Contains(uuid)) return;
            if (seenRecords.Count >= 8_192) seenRecords.Clear();
            seenRecords.Add(uuid);
        }
        if (date is { } written && previousLog is { } previous && written < previous.AddSeconds(-600)) return;
        SessionID = record.Field("sessionId")?.Text ?? SessionID;
        var message = record.Field("message");
        if (type == "user")
        {
            // A peer-session message is marked isMeta but carries `origin`, and starts a turn like a prompt.
            if (!PromptRecord(record)) return;
            switch (ClaudeInputOf(record, message))
            {
                case ClaudeInput.Human:
                    Begin(record.Field("uuid")?.Text, date);
                    if (date is { } at) LastActivity = Max(LastActivity, at);
                    break;
                case ClaudeInput.Interrupted:
                    CloseTurn(TokenActivityState.Interrupted, date);
                    break;
                case ClaudeInput.ToolResult:
                    softClosed = false;
                    metadataTurnOpen = true;
                    foreach (var block in Objects(message?.Field("content")) ?? [])
                        if (block.Field("type")?.Text == "tool_result" && block.Field("tool_use_id")?.Text is { } id) RemovePendingTool(id);
                    observedState = pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool;
                    if (date is { } resultAt) LastActivity = Max(LastActivity, resultAt);
                    // Workflow agents end by returning their result through a tool.
                    if (record.Field("toolEndsTurn")?.Bool == true) CloseTurn(TokenActivityState.Complete, date);
                    break;
            }
        }
        else if (type == "assistant")
        {
            if (record.Field("requestId")?.Text is { } request)
            {
                if (requestIDs.Count >= 256) requestIDs.Clear();
                requestIDs.Add(request);
            }
            var usage = message?.Field("usage");
            if (Integer(usage?.Field("output_tokens")) is not { } count || message?.Field("id")?.Text is not { } id
                || previousMessages.Contains(id)) return;
            var errored = record.Field("isApiErrorMessage")?.Bool == true || message?.Field("model")?.Text == "<synthetic>";
            // A response (or the final failure) ends any API retry in progress.
            Retry = null;
            if (!errored)
            {
                Model = message?.Field("model")?.Text ?? Model;
                // Context occupied by this request: all input-side counts. Claude logs no window size.
                if (date is { } at && Integer(usage?.Field("input_tokens")) is { } input && (contextUsage is null || at >= contextUsage.RecordedAt))
                {
                    var used = input + (Integer(usage?.Field("cache_creation_input_tokens")) ?? 0) + (Integer(usage?.Field("cache_read_input_tokens")) ?? 0);
                    contextUsage = new TokenContextUsage(used, null, at, null);
                }
            }
            var prior = messages.GetValueOrDefault(id);
            messages[id] = Math.Max(prior, count);
            if (date is { } respondedAt) LastActivity = Max(LastActivity, respondedAt);
            softClosed = false;
            var blocks = Objects(message?.Field("content")) ?? [];
            bool Has(string blockType) => blocks.Any(block => block.Field("type")?.Text == blockType);
            var usesTool = Has("tool_use");
            if (usesTool)
            {
                foreach (var block in blocks)
                    if (block.Field("type")?.Text == "tool_use" && block.Field("id")?.Text is { } toolID) AddPendingTool(toolID, block.Field("name"));
                observedState = TokenActivityState.Tool;
            }
            else if (Has("text")) observedState = pendingTools.Count == 0 ? TokenActivityState.Output : TokenActivityState.Tool;
            else if (Has("thinking")) observedState = pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool;
            if (count > prior)
            {
                if (startedAt is not null)
                {
                    output += count - prior;
                    hasUsage = true;
                }
                LatestOutput = startedAt is null ? count : output;
                RecordOutput(count - prior, date);
                outputMessageID = id;
            }
            else if (id == outputMessageID && date is { } blockAt && LastOutputAt is { } lastAt && blockAt > lastAt)
            {
                // Main sessions write a message's blocks at its end with earlier block times;
                // the newest block time is the closest to when its tokens were recorded.
                LastOutputAt = blockAt;
                if (recentOutputs.Count > 0)
                    recentOutputs[^1] = recentOutputs[^1] with { At = Max(recentOutputs[^1].At, blockAt) };
            }
            if (errored)
            {
                softClosed = true;
                observedState = TokenActivityState.Interrupted;
            }
            else if (!usesTool && pendingTools.Count == 0 && message?.Field("stop_reason")?.Text is "end_turn" or "stop_sequence")
            {
                softClosed = true;
                observedState = TokenActivityState.Complete;
                // Subagents write no stop marker; a later continuation records again.
                if (startedAt is not null) RecordCompletion(date, null);
            }
        }
        else if (type == "system")
        {
            var subtype = record.Field("subtype")?.Text;
            // Compaction end time; the boundary itself does not change the turn.
            if (subtype == "compact_boundary" && date is { } compacted) compactedAt = Max(compactedAt, compacted);
            // A marker older than the current prompt belongs to an earlier turn.
            if (date is { } at && startedAt is { } begun && at < begun) return;
            switch (subtype)
            {
                case "turn_duration":
                    CloseTurn(TokenActivityState.Complete, date, Number(record.Field("durationMs"), MaxDurationMs) / 1_000);
                    break;
                case "api_error":
                    // Counts, delay and the network flag only; error messages are never read.
                    if (!TurnOpen || date is not { } failedAt || Integer(record.Field("retryAttempt")) is not { } attempt) break;
                    var delay = Number(record.Field("retryInMs"), 86_400_000);
                    Retry = new TokenRetryState(attempt, Integer(record.Field("maxRetries")),
                        delay is { } ms ? failedAt.AddMilliseconds(ms) : null,
                        record.Field("error")?.Field("isNetworkDown")?.Bool == true, failedAt);
                    break;
                case "stop_hook_summary": CloseTurn(TokenActivityState.Complete, null); break;
                case "turn_aborted" or "task_aborted" or "interrupted": CloseTurn(TokenActivityState.Interrupted, date); break;
            }
        }
    }

    /// Ends the turn. `duration` is only ever the client's own report for this turn.
    void CloseTurn(TokenActivityState state, DateTimeOffset? date, double? duration = null, DateTimeOffset? finishedAt = null)
    {
        // A repeated stop marker after the turn already closed has no turn to complete.
        if (state == TokenActivityState.Complete && (startedAt is not null || metadataTurnOpen)) RecordCompletion(finishedAt ?? date, duration);
        Retry = null;
        startedAt = null;
        turnID = null;
        turnUsage = null;
        softClosed = false;
        metadataTurnOpen = false;
        metadataTurnID = null;
        activityStartedAt = null;
        observedState = state;
        pendingTools.Clear();
        if (date is { } at) LastActivity = Max(LastActivity, at);
    }

    /// Oversized lines are dropped, but a tool result still names its call near the start.
    public void ConsumeOversizedPrefix(ReadOnlySpan<byte> data)
    {
        var text = Encoding.UTF8.GetString(data);
        string? Value(string key)
        {
            var at = text.IndexOf($"\"{key}\":\"", StringComparison.Ordinal);
            if (at < 0) return null;
            var start = at + key.Length + 4;
            var end = text.IndexOf('"', start);
            return end < 0 ? null : text[start..end];
        }
        string? id;
        if (Source == TokenSource.Codex)
        {
            if (ignoringInheritedTurn || !text.Contains("\"type\":\"response_item\"", StringComparison.Ordinal)
                || !text.Contains("\"type\":\"function_call_output\"", StringComparison.Ordinal)
                && !text.Contains("\"type\":\"custom_tool_call_output\"", StringComparison.Ordinal)) return;
            id = Value("call_id");
        }
        else
        {
            if (!text.Contains("\"type\":\"user\"", StringComparison.Ordinal) || !text.Contains("\"type\":\"tool_result\"", StringComparison.Ordinal)
                || !IsSubagent && text.Contains("\"isSidechain\":true", StringComparison.Ordinal)) return;
            id = Value("tool_use_id");
        }
        if (id is null || !RemovePendingTool(id)) return;
        if (TurnOpen) observedState = pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool;
    }

    /// Classifies a line for locating the current turn. Starting earlier than the true start
    /// is harmless: the forward parse resets at every later human input.
    public TurnBoundary? ClaudeTurnBoundary(ReadOnlySpan<byte> line)
    {
        if (line.IndexOf("\"type\":\"user\""u8) < 0 && line.IndexOf("\"type\":\"system\""u8) < 0 || Record(line) is not { } record) return null;
        if (record.Field("isSidechain")?.Bool == true && !IsSubagent) return null;
        switch (record.Field("type")?.Text)
        {
            case "system":
                return record.Field("subtype")?.Text is "turn_duration" or "stop_hook_summary" or "turn_aborted" or "task_aborted" or "interrupted"
                    ? TurnBoundary.End : null;
            case "user":
                if (!PromptRecord(record)) return null;
                if (record.Field("toolEndsTurn")?.Bool == true) return TurnBoundary.End;
                return ClaudeInputOf(record, record.Field("message")) switch
                {
                    ClaudeInput.Human => TurnBoundary.Start,
                    ClaudeInput.Interrupted => TurnBoundary.End,
                    _ => null,
                };
            default: return null;
        }
    }

    static bool PromptRecord(JsonElement record) =>
        (record.Field("isMeta")?.Bool != true || record.Field("origin")?.ValueKind == JsonValueKind.Object)
        && record.Field("isCompactSummary")?.Bool != true;

    /// `origin` marks prompts that start a turn (human, task notifications, peer sessions).
    /// Older logs lack it; local slash-command echoes are not prompts.
    static ClaudeInput ClaudeInputOf(JsonElement record, JsonElement? message)
    {
        var content = message?.Field("content");
        var blocks = Objects(content);
        var text = content?.Text ?? blocks?.FirstOrDefault(block => block.Field("type")?.Text == "text").Field("text")?.Text;
        if (text?.StartsWith("[Request interrupted", StringComparison.Ordinal) == true) return ClaudeInput.Interrupted;
        if (blocks?.Any(block => block.Field("type")?.Text == "tool_result") == true) return ClaudeInput.ToolResult;
        if (record.Field("origin") is { ValueKind: JsonValueKind.Object } origin)
            return origin.Field("kind")?.ValueKind == JsonValueKind.String ? ClaudeInput.Human : ClaudeInput.None;
        if (text is not null && (text.StartsWith("<command-name>", StringComparison.Ordinal)
                                 || text.StartsWith("<command-message>", StringComparison.Ordinal)
                                 || text.StartsWith("<local-command-", StringComparison.Ordinal))) return ClaudeInput.None;
        return text is not null || blocks is { Count: > 0 } ? ClaudeInput.Human : ClaudeInput.None;
    }

    /// Swift's `as? [[String: Any]]`: an array whose every element is an object, else null.
    static List<JsonElement>? Objects(JsonElement? value) =>
        value is { ValueKind: JsonValueKind.Array } array && array.EnumerateArray().All(item => item.ValueKind == JsonValueKind.Object)
            ? [.. array.EnumerateArray()] : null;

    /// Non-negative whole numbers. ponytail: capped at int.MaxValue (Swift: Int.max) because the shared models hold int;
    /// a larger count is dropped as corrupt.
    static int? Integer(JsonElement? value) =>
        value?.Number is { } number && number >= 0 && number <= int.MaxValue && Math.Truncate(number) == number ? (int)number : null;

    /// A week in milliseconds: longer client durations are treated as corrupt rather than shown.
    const double MaxDurationMs = 604_800_000;
    static double? Number(JsonElement? value, double limit) => value?.Number is { } number && number <= limit ? number : null;

    /// Rule 4: what ISO8601DateFormatter accepts, seconds plus an optional fraction (kept to milliseconds, as Foundation
    /// does) and Z or ±hh:mm. Numbers are epoch seconds.
    static DateTimeOffset? Date(JsonElement? value)
    {
        if (value?.Text is { } text)
        {
            if (IsoDate.Match(text) is not { Success: true } match
                || !DateTimeOffset.TryParseExact(match.Groups[1].Value + (match.Groups[3].Value == "Z" ? "+00:00" : match.Groups[3].Value),
                    "yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)) return null;
            var milliseconds = match.Groups[2].Success ? int.Parse(match.Groups[2].Value.PadRight(3, '0'), CultureInfo.InvariantCulture) : 0;
            var at = parsed.ToUniversalTime().AddMilliseconds(milliseconds);
            // ponytail: years 1 and 9999 are dropped (Foundation keeps them) so the day-sized arithmetic on a corrupt
            // date can't overflow DateTimeOffset and throw out of Sample().
            return at.Year is > 1 and < 9999 ? at : null;
        }
        if (value?.Number is { } seconds && seconds > 0 && seconds < 253_370_764_800) // before 9999-01-01, as above
            return DateTimeOffset.UnixEpoch.AddTicks((long)(seconds * TimeSpan.TicksPerSecond));
        return null;
    }

    static readonly Regex IsoDate =
        new(@"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]{1,3})[0-9]*)?(Z|[+-][0-9]{2}:[0-9]{2})$", RegexOptions.CultureInvariant);

    static DateTimeOffset Max(DateTimeOffset? current, DateTimeOffset value) => current is { } existing && existing > value ? existing : value;
}
