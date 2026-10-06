using System.Collections.Immutable;
using System.Text.Json.Serialization;
using static TokenCat.Lang;

namespace TokenCat;

// Models.swift, TokenSpeed.swift and Telemetry.swift's models, field for field (DESIGN §11 WP0). Swift `struct` → sealed record,
// changed with `with`. Behaviour belongs to the package that owns it: records that Swift gives computed members are `partial`
// (members marked [JsonIgnore], since Codable only encodes stored fields) and enums get C# 14 `extension` blocks.

/// Every client TokenCat recognises; `TokenProvider.All` (Tracking/TokenProviders.cs) says where each keeps its logs and which are read.
/// JSON names are the Swift raw values (`Id`); camelCase gives them for every case but OpenCode.
public enum TokenSource { Codex, Claude, [JsonStringEnumMemberName("opencode")] OpenCode, Gemini, Qwen, Copilot, Amp, Cline, Omp, Droid }

/// `idle`… `input` as in Models.swift: `stale` is an open turn past its liveness horizon but logged within 30 minutes,
/// `unfinished` one with no log for longer, `input` waits for the person.
public enum TokenActivityState { Idle, Working, Tool, Output, Complete, Interrupted, Stale, Unfinished, Input }

/// Category of the running tool, derived from the tool name only (never its input).
public enum ToolCategory { Command, File, Web, Agent, Mcp, Question, Other }

public enum TokenRateKind { ServerGeneration, ServerAggregate, RequestProcessing }

/// Collector lifecycle as shown to people. A busy port is told apart by asking its /health.
public enum TelemetryCollectorState { Starting, Waiting, Receiving, BusyTokenCat, BusyOtherApp, Failed, Stopped }

public static class ModelText
{
    extension(TokenSource source)
    {
        /// The Swift raw value, used in ids and JSON.
        public string Id => source switch
        {
            TokenSource.Codex => "codex",
            TokenSource.Claude => "claude",
            TokenSource.OpenCode => "opencode",
            TokenSource.Gemini => "gemini",
            TokenSource.Qwen => "qwen",
            TokenSource.Copilot => "copilot",
            TokenSource.Amp => "amp",
            TokenSource.Cline => "cline",
            TokenSource.Omp => "omp",
            TokenSource.Droid => "droid",
            _ => throw new ArgumentOutOfRangeException(nameof(source)),
        };

        public string Title => source switch
        {
            TokenSource.Codex => "Codex",
            TokenSource.Claude => "Claude Code",
            TokenSource.OpenCode => "OpenCode",
            TokenSource.Gemini => "Gemini CLI",
            TokenSource.Qwen => "Qwen Code",
            TokenSource.Copilot => "Copilot CLI",
            TokenSource.Amp => "Amp",
            TokenSource.Cline => "Cline",
            TokenSource.Omp => "omp",
            TokenSource.Droid => "Droid",
            _ => throw new ArgumentOutOfRangeException(nameof(source)),
        };

        /// The vendor name alone, before a word like "한도" ("Claude 5시간 한도").
        public string ShortTitle => source switch
        {
            TokenSource.Claude => "Claude",
            TokenSource.Gemini => "Gemini",
            TokenSource.Qwen => "Qwen",
            TokenSource.Copilot => "Copilot",
            _ => source.Title,
        };

        /// The command that resumes a session when followed by its ID; null where none is known.
        public string? ResumeCommand => source switch
        {
            TokenSource.Codex => "codex resume",
            TokenSource.Claude => "claude --resume",
            TokenSource.OpenCode => "opencode --session",
            TokenSource.Gemini => "gemini --resume",
            TokenSource.Copilot => "copilot --resume",
            TokenSource.Amp => "amp threads continue",
            _ => null,
        };
    }

    extension(TokenSource)
    {
        /// The clients telemetry setup, live limits, the status line bridge and the per-client speed items apply to.
        public static IReadOnlyList<TokenSource> TelemetryClients => telemetryClients;

        /// Sources a list names: the telemetry clients always (a Codex and Claude Code user sees no change), any other
        /// once its data folder is detected or a reading carries it.
        public static IReadOnlyList<TokenSource> Listed(IReadOnlySet<TokenSource> detected, IEnumerable<TokenReading> readings)
        {
            var seen = readings.Select(reading => reading.Source).ToHashSet();
            return [.. Enum.GetValues<TokenSource>().Where(source => telemetryClients.Contains(source) || detected.Contains(source) || seen.Contains(source))];
        }
    }

    static readonly TokenSource[] telemetryClients = [TokenSource.Codex, TokenSource.Claude];

    extension(TokenRateKind kind)
    {
        public string Title => kind switch
        {
            TokenRateKind.ServerGeneration => Loc("생성 tok/s", "generation tok/s"),
            TokenRateKind.ServerAggregate => Loc("모델 tok/s", "model tok/s"),
            _ => Loc("요청 tok/s", "request tok/s"),
        };
    }
}

public sealed record SystemSnapshot
{
    public double? CpuPercent { get; init; }
    public ulong? MemoryUsedBytes { get; init; }
    public ulong? MemoryTotalBytes { get; init; }
    public ulong? DiskUsedBytes { get; init; }
    public ulong? DiskTotalBytes { get; init; }
    public double? UploadBytesPerSecond { get; init; }
    public double? DownloadBytesPerSecond { get; init; }
    public IReadOnlyList<string> LocalIPs { get; init; } = [];
    public double? BatteryPercent { get; init; }
    public bool? IsCharging { get; init; }
    /// "AC Power" / "Battery Power" as on mac, so `Format.Power` is shared.
    public string? PowerSource { get; init; }
    public bool BatteryPresent { get; init; }
    public DateTimeOffset SampledAt { get; init; } = DateTimeOffset.UtcNow;
}

/// Claude Code API retry progress from system/api_error records (counts and delays only).
public sealed record TokenRetryState(int Attempt, int? MaxAttempts, DateTimeOffset? RetryAt, bool NetworkDown, DateTimeOffset At);

/// Codex usage limit window as last written by the client. `RecordedAt` is the log time.
public sealed record TokenRateLimit(double UsedPercent, int? WindowMinutes, DateTimeOffset? ResetsAt, DateTimeOffset RecordedAt)
{
    /// From a live poll (LiveLimits), not a log; `RecordedAt` is then the poll time.
    public bool Live { get; init; }
}

/// Context occupied by the latest request. Claude reports no window size, so `WindowTokens` stays null there.
public sealed record TokenContextUsage(int UsedTokens, int? WindowTokens, DateTimeOffset RecordedAt, DateTimeOffset? CompactedAt);

/// One log-recorded output increment. `At` is the log write time, not a streaming time.
public readonly record struct TokenOutputEvent(DateTimeOffset At, int Tokens);

public sealed record TokenReading
{
    public TokenReading(TokenSource source, string? id = null)
    {
        Source = source;
        Id = id ?? source.Id;
    }

    public string Id { get; init; }
    public TokenSource Source { get; init; }
    public string? SessionID { get; init; }
    /// Exact identifier of the session a subagent belongs to (Claude: shared sessionId, Codex: root thread). Null for main sessions.
    public string? ParentSessionID { get; init; }
    public string? AgentID { get; init; }
    public string? Project { get; init; }
    /// Full working directory, used only for "Open in Explorer"; never displayed.
    public string? ProjectPath { get; init; }
    public string? Model { get; init; }
    public bool IsSubagent { get; init; }
    /// Duration of the last completed turn as reported by the client (never divided into a rate).
    public double? LastTurnDurationSeconds { get; init; }
    public ToolCategory? ToolCategory { get; init; }
    /// Raw tool name for help text only (e.g. "Bash"); inputs are never read.
    public string? ToolName { get; init; }
    public TokenRetryState? Retry { get; init; }
    public TokenRateLimit? RateLimit { get; init; }
    public TokenContextUsage? Context { get; init; }
    /// Codex reasoning effort / service tier as written in turn_context.
    public string? Effort { get; init; }
    /// Subagent role or nickname (Codex agent_nickname/role, Claude agentType).
    public string? AgentRole { get; init; }
    public TokenSpeedMeasurement? SpeedMeasurement { get; init; }
    public int? LastOutputTokens { get; init; }
    public bool Active { get; init; }
    public TokenActivityState ActivityState { get; init; } = TokenActivityState.Idle;
    public DateTimeOffset? CurrentTurnStartedAt { get; init; }
    public int? CurrentTurnOutputTokens { get; init; }
    public DateTimeOffset? LastOutputAt { get; init; }
    public int? LastOutputDelta { get; init; }
    public IReadOnlyList<TokenOutputEvent> RecentOutputs { get; init; } = [];
    public DateTimeOffset? SampledAt { get; init; }
    public DateTimeOffset? LastActivity { get; init; }
    /// Newest timestamp of any record in the log; liveness only, not shown as activity.
    public DateTimeOffset? LastLogAt { get; init; }
    public DateTimeOffset? MeasurementAt { get; init; }
    /// Claude: request IDs of the responses in this log (at most 256), matched against telemetry; never shown.
    public ImmutableHashSet<string> RequestIDs { get; init; } = [];
}

/// Only model/request identifiers and explicitly measured numeric fields survive ingestion.
public sealed record TelemetryReading
{
    public required TokenSource Provider { get; init; }
    public string? SessionID { get; init; }
    public string? AgentID { get; init; }
    public string? Model { get; init; }
    public string? RequestID { get; init; }
    public required DateTimeOffset At { get; init; }
    public int? OutputTokens { get; init; }
    public double? RequestDurationMs { get; init; }
    public bool RequestDurationIncludesRetries { get; init; }
    public double? TtftMs { get; init; }
    public double? ServerTokenIntervalMs { get; init; }
    public string? ServerTokenIntervalMetric { get; init; }
    public int? ServerTokenIntervalSampleCount { get; init; }
    public DateTimeOffset? MetricWindowStartedAt { get; init; }
    public double? ServerInferenceMs { get; init; }
}

/// TokenSpeed.swift's measurement. `Kind`, `TokensPerSecond` and `Details` are WP1's (Tracking/TokenSpeed.cs).
public sealed partial record TokenSpeedMeasurement
{
    public TokenSpeedMeasurement() { }

    public TokenSpeedMeasurement(TelemetryReading reading)
    {
        Model = reading.Model;
        At = reading.At;
        RequestID = reading.RequestID;
        OutputTokens = reading.OutputTokens;
        RequestDurationMs = reading.RequestDurationMs;
        RequestDurationIncludesRetries = reading.RequestDurationIncludesRetries;
        TtftMs = reading.TtftMs;
        ServerTokenIntervalMs = reading.ServerTokenIntervalMs;
        ServerTokenIntervalMetric = reading.ServerTokenIntervalMetric;
        ServerTokenIntervalSampleCount = reading.ServerTokenIntervalSampleCount;
        MetricWindowStartedAt = reading.MetricWindowStartedAt;
        ServerInferenceMs = reading.ServerInferenceMs;
    }

    public string? Model { get; init; }
    public DateTimeOffset At { get; init; }
    public string? RequestID { get; init; }
    public int? OutputTokens { get; init; }
    public double? RequestDurationMs { get; init; }
    public bool RequestDurationIncludesRetries { get; init; }
    public double? TtftMs { get; init; }
    public double? ServerTokenIntervalMs { get; init; }
    public string? ServerTokenIntervalMetric { get; init; }
    public int? ServerTokenIntervalSampleCount { get; init; }
    public DateTimeOffset? MetricWindowStartedAt { get; init; }
    public double? ServerInferenceMs { get; init; }
}

/// One Claude usage-limit window. `ResetsAt` is null from the desktop app, which records no reset time.
/// `ReceivedAt` is when TokenCat received it, or the desktop app's record time.
public sealed record ClaudeLimitWindow(double UsedPercent, DateTimeOffset? ResetsAt, DateTimeOffset ReceivedAt)
{
    /// From a live poll (LiveLimits), not the status line or the desktop app. Not stored: a relaunch shows it as a record.
    [JsonIgnore] public bool Live { get; init; }
}

/// `rate_limits.five_hour` and `.seven_day`. Merge/decode live in WP2's `ClaudeUsage`; persisted under `DefaultsKey` in
/// `SettingsStore`.
public sealed record ClaudeUsageLimits(ClaudeLimitWindow? FiveHour = null, ClaudeLimitWindow? SevenDay = null)
{
    public const string DefaultsKey = "claudeUsageLimits";
    public static ClaudeUsageLimits Empty { get; } = new();
    [JsonIgnore] public bool IsEmpty => FiveHour is null && SevenDay is null;
}

/// A decoded sprite sheet, 4 bytes per pixel (B, G, R, A), rows top to bottom. Decoded by the App, composed by Core.
public sealed record PixelSheet(byte[] Bgra, int Width, int Height);
