using static TokenCat.Lang;

namespace TokenCat;

/// SnapshotFixtures.swift: synthetic dashboard states for `--snapshot`. Every value is made up: no local logs, collector,
/// host name, address or home path is read. IDs are visibly fake (sessions `00000000-0000-4000-8000-…`, Claude Code agents
/// `aNNNNNNN…`); AppChecks checks this. The mac "contrast" fixture is left out: Windows has no Increase Contrast tokens (§3.2).
static class Fixtures
{
    public const string SessionPrefix = "00000000-0000-4000-8000-";

    public sealed record Fixture(string Name)
    {
        public IReadOnlyList<TokenReading> Tokens { get; init; } = [];
        public bool Sampled { get; init; } = true;
        public bool Expanded { get; init; }
        public TelemetryCollectorState Telemetry { get; init; } = TelemetryCollectorState.Receiving;
        public string? Note { get; init; }
        public TelemetrySetupFailure? Failure { get; init; }
        public IReadOnlySet<TokenSource> Restart { get; init; } = new HashSet<TokenSource>();
        public bool FoldersFound { get; init; } = true;
        /// Seconds the AI collection lags behind the system sample, for the footer's longest state.
        public double Lag { get; init; }
        public bool Battery { get; init; } = true;
        /// A keyboard-selected row and an open inline detail, by reading id.
        public string? Selection { get; init; }
        public string? Detail { get; init; }
        public string? Update { get; init; }
        public ClaudeUsageLimits ClaudeLimits { get; init; } = ClaudeUsageLimits.Empty;
    }

    /// Thursday 15:00:03 local time, so 오늘/어제/이번 주/이전 all have members.
    public static readonly DateTimeOffset Now = new(new DateTime(2026, 10, 1, 15, 0, 3, DateTimeKind.Local));
    static DateTimeOffset At(double offset) => Now.AddSeconds(offset);

    /// A made-up newer release (version 1.0.0) checked 3 minutes before `now`; `install` is "available", "downloading" (45 %)
    /// or "failed" (network).
    public static UpdateState Update(string install, DateTimeOffset now)
    {
        var page = new Uri("https://github.com/SeuPut0705/TokenCat/releases/tag/v1.0.0");
        return new UpdateState
        {
            Check = new UpdateCheck.Done(),
            Install = install switch
            {
                "downloading" => new UpdateInstall.Downloading(0.45),
                "failed" => new UpdateInstall.Failed(UpdateFailure.Network),
                _ => new UpdateInstall.None(),
            },
            CheckedAt = now.AddSeconds(-180),
            Available = new UpdateRelease("1.0.0", "v1.0.0", page, new UpdateAsset(page, 5_242_880, new string('0', 64))),
        };
    }

    public static SystemSnapshot System(bool battery, bool sampled) => new()
    {
        CpuPercent = 14,
        MemoryUsedBytes = 19_219_755_008,
        MemoryTotalBytes = 25_769_803_776,
        DiskUsedBytes = 676_115_828_736,
        DiskTotalBytes = 994_662_584_320,
        UploadBytesPerSecond = 1_200,
        DownloadBytesPerSecond = 52_000,
        LocalIPs = ["192.0.2.10"],
        BatteryPresent = battery,
        BatteryPercent = 58,
        IsCharging = sampled ? true : null,
        SampledAt = Now,
    };

    /// The shell-side state DashboardView reads, as DashboardModel would publish it for `fixture`.
    public static DashboardInput Input(Fixture fixture)
    {
        var tokensSampledAt = fixture.Sampled ? At(-fixture.Lag) : (DateTimeOffset?)null;
        var system = System(fixture.Battery, fixture.Sampled);
        var now = tokensSampledAt is { } sampled && sampled > system.SampledAt ? sampled : system.SampledAt;
        var flow = FlowSeries.Make(fixture.Tokens, now);
        var history = Enumerable.Range(0, 30).Select(index => 10 + 6 * Math.Sin(index / 3.0) + index % 4).ToList();
        var state = new MonitorState(now, system, fixture.Sampled, fixture.Sampled ? history : [], fixture.Tokens, tokensSampledAt,
            SessionPresentation.Groups(fixture.Tokens, now), SessionListModel.Make(fixture.Tokens, now, false, fixture.Restart), flow,
            fixture.Tokens.Where(reading => !SessionPresentation.IsTelemetry(reading)).Select(reading => reading.LastOutputAt).Max(),
            fixture.Telemetry, fixture.Telemetry.Status, null, fixture.Restart, new HashSet<TokenSource>(),
            new Dictionary<TokenSource, DateTimeOffset>(), new Dictionary<string, ClaudeUsageLimits> { ["legacy"] = fixture.ClaudeLimits },
            fixture.FoldersFound, new HashSet<TokenSource>())
        {
            UsageLimits = SessionPresentation.UsageLimits(fixture.Tokens, [], new Dictionary<string, ClaudeUsageLimits> { ["legacy"] = fixture.ClaudeLimits },
                new Dictionary<TokenSource, LimitAccount>(), new Dictionary<TokenSource, IReadOnlyList<LimitAccount>>(), now),
        };
        return new DashboardInput(state, fixture.Update is { } install ? Update(install, now) : new UpdateState(),
            null, null, fixture.Note, fixture.Failure, [], null, OnboardingSeen: true, OptedOut: false);
    }

    // MARK: Readings

    static TokenReading Reading(string name, TokenSource source, string project, string? model, TokenActivityState state, bool active = true,
        double last = -2, double? turn = -420, int? output = null, IReadOnlyDictionary<double, int>? outputs = null)
    {
        var session = SessionPrefix + new string('0', Math.Max(0, 12 - name.Length)) + name[..Math.Min(12, name.Length)];
        var folder = source == TokenSource.Codex ? ".codex/sessions/2026/10/01" : $".claude/projects/C--work-{project}";
        var recent = (outputs ?? new Dictionary<double, int>()).OrderBy(pair => pair.Key).Select(pair => new TokenOutputEvent(At(pair.Key), pair.Value)).ToList();
        var open = active || state == TokenActivityState.Stale;
        return new TokenReading(source, $"{source.Id}:{folder}/{session}.jsonl")
        {
            SessionID = session, Project = project, Model = model, Active = active, LastActivity = At(last), ActivityState = state,
            CurrentTurnStartedAt = open && turn is { } t ? At(t) : null, CurrentTurnOutputTokens = open ? output : null, SampledAt = Now,
            RecentOutputs = recent, LastOutputAt = recent.Count > 0 ? recent[^1].At : null, LastOutputDelta = recent.Count > 0 ? recent[^1].Tokens : null,
            LastLogAt = At(last), ProjectPath = $@"C:\work\{project}",
        };
    }

    static TokenReading Child(TokenReading parent, string agent, string? role, TokenActivityState state, bool active = true, double last = -2,
        int? output = null, IReadOnlyDictionary<double, int>? outputs = null, string? project = null)
    {
        var value = Reading(agent, parent.Source, project ?? parent.Project ?? "", parent.Model, state, active, last, output: output, outputs: outputs);
        value = value with
        {
            Id = parent.Id.Replace(".jsonl", $"/subagents/agent-{agent}.jsonl"), IsSubagent = true,
            AgentID = parent.Source == TokenSource.Codex ? $"/root/{agent}" : agent, AgentRole = role,
        };
        return parent.Source == TokenSource.Codex ? value with { ParentSessionID = parent.SessionID } : value with { SessionID = parent.SessionID };
    }

    static TokenReading Measured(TokenReading value, int tokens, double milliseconds, double ago) => value with
    {
        SpeedMeasurement = new TokenSpeedMeasurement(new TelemetryReading { Provider = value.Source, At = At(ago) })
            { Model = value.Model, OutputTokens = tokens, RequestDurationMs = milliseconds },
    };

    /// A Codex server rate ("생성 tok/s"): one token every `interval` ms.
    static TokenReading Generated(TokenReading value, double interval, double ago) => value with
    {
        SpeedMeasurement = new TokenSpeedMeasurement(new TelemetryReading { Provider = value.Source, At = At(ago) })
            { Model = value.Model, ServerTokenIntervalMs = interval, ServerTokenIntervalSampleCount = 1 },
    };

    static TokenReading Idle(string name, string project, double ago, TokenActivityState state = TokenActivityState.Complete, TokenSource source = TokenSource.Claude) =>
        Reading(name, source, project, source == TokenSource.Codex ? "gpt-6.1-sol" : "claude-opus-5-5", state, active: false, last: ago) with
        {
            LastOutputTokens = 7_493, LastOutputAt = At(ago), LastTurnDurationSeconds = 252,
        };

    static TokenRateLimit Limit(double percent, double resetsIn, double recorded) => new(percent, 10_080, At(resetsIn), At(recorded));

    static ClaudeUsageLimits Claude((double Percent, double ResetsIn) fiveHour, (double Percent, double ResetsIn) weekly, double recorded) =>
        new(new ClaudeLimitWindow(fiveHour.Percent, At(fiveHour.ResetsIn), At(recorded)), new ClaudeLimitWindow(weekly.Percent, At(weekly.ResetsIn), At(recorded)));

    static Dictionary<double, int> Outputs(params (double At, int Tokens)[] values) => values.ToDictionary(value => value.At, value => value.Tokens);

    public static IReadOnlyList<Fixture> All()
    {
        var quiet = Outputs((-250, 820), (-205, 1_460), (-170, 380), (-120, 2_210), (-85, 640), (-60, 1_120));

        // 1. A question waits for the person; it outranks everything in the order.
        var question = Reading("input01", TokenSource.Claude, "TokenCat", "claude-opus-5-5", TokenActivityState.Input, last: -192, turn: -1_400, output: 12_480, outputs: quiet) with
        {
            ToolCategory = TokenCat.ToolCategory.Question, ToolName = "AskUserQuestion", Context = new TokenContextUsage(182_331, null, At(-192), null),
        };
        var docs = Reading("docs01", TokenSource.Codex, "docs-site", "gpt-6.1-sol", TokenActivityState.Working, last: -8, output: 3_210, outputs: Outputs((-90, 410), (-45, 760))) with
        {
            Effort = "xhigh", Context = new TokenContextUsage(158_204, 258_400, At(-45), null), RateLimit = Limit(28, 5 * 86_400 + 11 * 3_600, -720),
        };
        var plan = Reading("plan01", TokenSource.Claude, "api-server", "claude-opus-5-5", TokenActivityState.Input, last: -40, turn: -600, output: 4_020) with
        {
            ToolCategory = TokenCat.ToolCategory.Question, ToolName = "ExitPlanMode",
        };
        // The Codex session's fresh server rate is the card's "지금 속도"; both account limits sit under the card.
        var input = new Fixture("input-needed")
        {
            Tokens = [question, Generated(docs, 18, -12), plan, Idle("idle01", "notes-app", -1_800)],
            ClaudeLimits = Claude((42, 2 * 3_600 + 13 * 60), (31, 3 * 86_400 + 4 * 3_600), -50),
        };

        // 2. API retries: countdown and network-down.
        var retrying = Reading("retry01", TokenSource.Claude, "api-server", "claude-opus-5-5", TokenActivityState.Working, last: -3, output: 640, outputs: Outputs((-140, 640))) with
        {
            Retry = new TokenRetryState(2, 10, At(4), false, At(-3)),
        };
        var offline = Reading("retry02", TokenSource.Claude, "TokenCat", "claude-sonnet-5", TokenActivityState.Working, last: -1, output: 0) with
        {
            Retry = new TokenRetryState(7, 10, At(20), true, At(-1)),
        };
        var flowing = Measured(Reading("out01", TokenSource.Codex, "docs-site", "gpt-6.1-sol", TokenActivityState.Output, last: -1, output: 8_240,
            outputs: Outputs((-100, 900), (-50, 1_400), (-1, 786))) with { Effort = "high" }, 441, 6_210, -20);
        var retry = new Fixture("retry") { Tokens = [retrying, offline, flowing] };

        // 3. Running tools by category; the raw names stay in help.
        var command = Reading("tool01", TokenSource.Codex, "TokenCat", "gpt-6.1-sol", TokenActivityState.Tool, last: -40, output: 2_048, outputs: quiet) with
        {
            ToolCategory = TokenCat.ToolCategory.Command, ToolName = "exec", Effort = "ultra",
        };
        var file = Reading("tool02", TokenSource.Claude, "docs-site", "claude-opus-5-5", TokenActivityState.Tool, last: -35, output: 5_120, outputs: Outputs((-100, 1_200))) with
        {
            ToolCategory = TokenCat.ToolCategory.File, ToolName = "Edit",
        };
        var web = Reading("tool03", TokenSource.Claude, "api-server", "claude-opus-5-5", TokenActivityState.Tool, last: -50, output: 960, outputs: Outputs((-115, 960))) with
        {
            ToolCategory = TokenCat.ToolCategory.Web, ToolName = "WebFetch",
        };
        var mcp = Reading("tool04", TokenSource.Claude, "sample-chat", "claude-sonnet-5", TokenActivityState.Tool, last: -33, output: 310, outputs: Outputs((-60, 310))) with
        {
            ToolCategory = TokenCat.ToolCategory.Mcp, ToolName = "mcp__tracker__search",
        };
        var tools = new Fixture("tool-categories") { Tokens = [command, file, web, mcp] };

        // 4. Context usage and the Codex limit at the warning level; a quiet row folds to 44.
        var full = Reading("ctx01", TokenSource.Codex, "TokenCat", "gpt-6.1-sol", TokenActivityState.Working, last: -6, output: 9_870, outputs: Outputs((-30, 1_210), (-12, 2_040))) with
        {
            Effort = "ultra", Context = new TokenContextUsage(235_100, 258_400, At(-12), null), RateLimit = Limit(87, 2 * 86_400 + 4 * 3_600, -95),
        };
        var replayed = full with
        {
            Id = full.Id + ".fork", SessionID = SessionPrefix + "0000000fork1", RateLimit = Limit(99, -86_400, -10), RecentOutputs = [], Active = false,
            ActivityState = TokenActivityState.Complete, CurrentTurnStartedAt = null, CurrentTurnOutputTokens = null, LastActivity = At(-7_200),
        };
        var compacted = Measured(Reading("ctx02", TokenSource.Claude, "docs-site", "claude-opus-5-5", TokenActivityState.Output, last: -2, output: 1_840,
            outputs: Outputs((-2, 312))) with { Context = new TokenContextUsage(18_204, null, At(-2), At(-75)) }, 200, 4_532, -30);
        var silent = Reading("ctx03", TokenSource.Claude, "api-server", "claude-sonnet-5", TokenActivityState.Stale, active: false, last: -200);
        var context = new Fixture("context-limit") { Tokens = [full, replayed, compacted, silent] };

        // 5. Subagents fold under their session; waiting children go to the summary while one runs.
        var parent = Reading("parent01", TokenSource.Claude, "TokenCat", "claude-opus-5-5", TokenActivityState.Working, last: -4, output: 6_403,
            outputs: Outputs((-80, 900), (-20, 1_300)));
        var explore = Child(parent, "a1111111e1", "Explore", TokenActivityState.Tool, last: -10, output: 2_269, outputs: Outputs((-70, 2_269))) with
        {
            ToolCategory = TokenCat.ToolCategory.File, ToolName = "Read",
        };
        var writer = Child(parent, "a2222222e2", "workflow-subagent", TokenActivityState.Output, last: -1, output: 15_448, outputs: Outputs((-60, 4_200), (-1, 812)));
        var waiter = Child(parent, "a3333333e3", null, TokenActivityState.Tool, last: -25, output: 13_219, outputs: Outputs((-95, 3_100))) with
        {
            ToolCategory = TokenCat.ToolCategory.Agent, ToolName = "Agent",
        };
        var stale = Enumerable.Range(4, 3).Select(n => Child(parent, $"a{new string((char)('0' + n), 7)}e{n}", "workflow-subagent", TokenActivityState.Stale, active: false,
            last: -40 - 20 * n, output: 51_823)).ToList();
        var codexRoot = Idle("root01", "docs-site", -900, source: TokenSource.Codex);
        var review = Child(codexRoot, "sample_reviewer", "guardian", TokenActivityState.Working, last: -6, output: 1_204, outputs: Outputs((-40, 1_204)));
        var chat = Child(codexRoot, "sample_scout", "explorer", TokenActivityState.Working, last: -9, output: 88, project: "sample-chat");
        var grouped = new Fixture("grouped-children") { Tokens = [parent, explore, writer, waiter, .. stale, codexRoot, review, chat] };

        // 6. Expanded list with date captions; older sessions fold behind one row.
        const double day = 86_400;
        var dates = new Fixture("expanded-dates")
        {
            Tokens =
            [
                Idle("d1", "TokenCat", -600), Idle("d2", "notes-app", -3_600 * 3, TokenActivityState.Interrupted),
                Idle("d3", "docs-site", -day - 3_600, source: TokenSource.Codex), Idle("d5", "sample-chat", -2 * day - 600, TokenActivityState.Unfinished),
                Idle("d6", "TokenCat", -9 * day), Idle("d7", "sandbox-app", -20 * day), Idle("d8", "notes-app", -47 * day),
            ],
            Expanded = true,
        };

        // 7–11. Empty, loading and collector states.
        var empty = new Fixture("empty");
        var noFolders = new Fixture("empty-no-folders")
        {
            Note = OnboardingOutcome.NotePrefix + Loc("Claude Code에 기존 OTLP 전송 대상이 있어 덮어쓰지 않았습니다.", "Claude Code already has an OTLP destination, so it wasn't overwritten."),
            Failure = new TelemetrySetupFailure.Conflict(), FoldersFound = false,
        };
        var loading = new Fixture("loading") { Sampled = false, Telemetry = TelemetryCollectorState.Starting };
        var waitingSpeed = Reading("rs01", TokenSource.Claude, "TokenCat", "claude-opus-5-5", TokenActivityState.Working, last: -3, output: 1_024,
            outputs: Outputs((-50, 1_024))) with { Context = new TokenContextUsage(96_000, null, At(-50), null) };
        var reset = docs with { RateLimit = Limit(64, -600, -7_000), ActivityState = TokenActivityState.Complete, Active = false, LastActivity = At(-7_000) };
        // The longest footer: both clients in the restart notice beside a failed update (it keeps only its buttons).
        var restart = new Fixture("restart-needed") { Tokens = [waitingSpeed, reset], Restart = new HashSet<TokenSource> { TokenSource.Claude, TokenSource.Codex }, Update = "failed" };
        var port = new Fixture("port-busy") { Tokens = [waitingSpeed, Idle("p1", "notes-app", -400)], Telemetry = TelemetryCollectorState.BusyOtherApp };
        // Another TokenCat holds the collector.
        var busy = new Fixture("collector-busy") { Tokens = [waitingSpeed], Telemetry = TelemetryCollectorState.BusyTokenCat };

        // 13. Header "로그 대기 N개" alone: open turns with no new record, one with a stale child.
        var stuck = Reading("wait01", TokenSource.Claude, "api-server", "claude-opus-5-5", TokenActivityState.Stale, active: false, last: -200, output: 2_310);
        var stuckChild = Child(stuck, "a7777777e7", "Explore", TokenActivityState.Stale, active: false, last: -260, output: 940);
        var logWait = new Fixture("log-wait")
        {
            Tokens = [stuck, stuckChild, Reading("wait02", TokenSource.Codex, "docs-site", "gpt-6.1-sol", TokenActivityState.Stale, active: false, last: -420, output: 0)],
            Battery = false,
        };

        // 14. Nothing running for two hours: "진행 중인 세션 없음 · 마지막 활동 2시간 전", sleeping head, collapsed flow card.
        var rest = new Fixture("quiet")
        {
            Tokens =
            [
                Idle("q1", "TokenCat", -7_300) with { LastOutputAt = At(-7_320), LastOutputDelta = 512 },
                Idle("q2", "notes-app", -9_000, TokenActivityState.Interrupted), Idle("q3", "docs-site", -86_400 - 400, source: TokenSource.Codex),
            ],
        };

        // 15–16. Keyboard: the selected row with its inline detail open; a selected child row in the tree.
        var detail = new Fixture("detail-open") { Tokens = [command, file, Idle("idle02", "notes-app", -1_800)], Selection = command.Id, Detail = command.Id };
        var selected = new Fixture("keyboard-selection") { Tokens = [parent, explore, writer, waiter, .. stale], Selection = explore.Id };

        // 17. Only Claude Code runs: its 5-hour limit at the warning level and the newer of two fresh request rates.
        var claudeRun = Measured(Reading("cl01", TokenSource.Claude, "TokenCat", "claude-opus-5-5", TokenActivityState.Working, last: -3, output: 4_812,
            outputs: Outputs((-140, 1_020), (-70, 1_560), (-3, 640))), 612, 9_840, -6);
        var claudeTool = Measured(Reading("cl02", TokenSource.Claude, "api-server", "claude-sonnet-5", TokenActivityState.Tool, last: -25, output: 1_930,
            outputs: Outputs((-90, 1_930))) with { ToolCategory = TokenCat.ToolCategory.Command, ToolName = "Bash" }, 380, 5_100, -40);
        var claudeOnly = new Fixture("claude-only")
        {
            Tokens = [claudeRun, claudeTool, Idle("cl03", "notes-app", -2_400)],
            ClaudeLimits = Claude((87, 3_600 + 20 * 60), (46, 4 * 86_400 + 2 * 3_600), -40),
        };

        // 18–20. The footer's update line: a new version, the download, and a failure beside a telemetry problem.
        TokenReading[] working = [waitingSpeed, Idle("u1", "notes-app", -400)];
        var available = new Fixture("update-available") { Tokens = working, Lag = 12, Update = "available" };
        var downloading = new Fixture("update-downloading") { Tokens = working, Update = "downloading" };
        var failed = new Fixture("update-failed") { Tokens = working, Telemetry = TelemetryCollectorState.BusyOtherApp, Update = "failed" };
        var firstAccount = new LimitAccount("workspace-1234", "alex@example.com");
        var secondAccount = new LimitAccount("workspace-1234", "sam@example.com");
        var firstMember = Generated(docs, 18, -12) with
        {
            LimitAccount = firstAccount, RateLimit = docs.RateLimit! with { UsedPercent = 82, Account = firstAccount },
        };
        var secondMember = Generated(Reading("member02", TokenSource.Codex, "docs-site", "gpt-6.1-sol", TokenActivityState.Working), 18, -12) with
        {
            LimitAccount = secondAccount, RateLimit = docs.RateLimit! with { UsedPercent = 34, Account = secondAccount },
        };
        var multipleAccounts = new Fixture("multiple-accounts") { Tokens = [firstMember, secondMember] };
        return [input, retry, tools, context, grouped, dates, empty, noFolders, loading, restart, port, busy, logWait, rest, detail, selected,
            claudeOnly, available, downloading, failed, multipleAccounts];
    }

    /// The five first-run outcomes (never part of a dashboard snapshot).
    public static IReadOnlyList<OnboardingOutcome> Outcomes() =>
    [
        new OnboardingOutcome.Added(true),
        OnboardingOutcome.Make(null, OnboardingOutcome.NotePrefix + Loc("Claude Code에 기존 OTLP 전송 대상이 있어 덮어쓰지 않았습니다.", "Claude Code already has an OTLP destination, so it wasn't overwritten."),
            new TelemetrySetupFailure.Conflict(), TelemetryCollectorState.Waiting),
        OnboardingOutcome.Make(null, OnboardingOutcome.NotePrefix + Loc("설정 파일을 저장하지 못했습니다.", "Couldn't save the settings file."),
            new TelemetrySetupFailure.WriteFailed(true), TelemetryCollectorState.Waiting),
        OnboardingOutcome.Make(SessionPresentation.Notice(TelemetryCollectorState.BusyOtherApp, null, new HashSet<TokenSource>()),
            null, null, TelemetryCollectorState.BusyOtherApp),
        OnboardingOutcome.Make(null, null, null, TelemetryCollectorState.Starting),
    ];

    /// The limit row states: Codex five, Claude four (both live, the 5-hour window at the warning level, both reset), each
    /// ending with a value from a live poll 20 s ago ("· 실시간").
    public static IReadOnlyList<UsageLimitSummary> Limits() =>
    [
        .. new[] { Limit(28, 5 * 86_400 + 8 * 3_600, -4 * 3_600), Limit(87, 2 * 86_400 + 4 * 3_600, -95), Limit(97, 3 * 3_600 + 20 * 60, -30), Limit(64, -600, -7_000) }
            .Select(limit => new UsageLimitSummary(limit.UsedPercent, limit.WindowMinutes, limit.ResetsAt, limit.RecordedAt)),
        new UsageLimitSummary(31, 10_080, At(5 * 86_400 + 8 * 3_600), At(-20)) { Live = true },
        .. new[]
        {
            Claude((42, 2 * 3_600 + 13 * 60), (31, 3 * 86_400 + 4 * 3_600), -50), Claude((91, 47 * 60), (64, 2 * 86_400), -20),
            Claude((77, -1_200), (58, -600), -9_000),
        }.Select(limits => SessionPresentation.ClaudeUsageLimit(limits, Now)).OfType<UsageLimitSummary>(),
        SessionPresentation.ClaudeUsageLimit(Claude((42, 2 * 3_600 + 13 * 60), (31, 3 * 86_400 + 4 * 3_600), -20), Now)! with { Live = true },
    ];

    /// Settings › fixtures (mac `--snapshot-settings --fixtures`): the collector off with a retry in 25 s, Codex waiting for a
    /// relaunch, the Claude limit received 50 s ago, version 1.0.0 available (checked 3 min ago), default preferences,
    /// the startup app not registered.
    public static SettingsInput Settings()
    {
        var input = Input(new Fixture("settings") { Telemetry = TelemetryCollectorState.BusyOtherApp, Restart = new HashSet<TokenSource> { TokenSource.Codex } });
        var received = input.State.Now.AddSeconds(-50);
        var state = input.State with
        {
            TelemetryNextRetryAt = input.State.Now.AddSeconds(25),
            ClaudeLimits = new Dictionary<string, ClaudeUsageLimits>
            {
                ["legacy"] = new(new ClaudeLimitWindow(42, input.State.Now.AddSeconds(7_980), received), new ClaudeLimitWindow(31, input.State.Now.AddSeconds(273_600), received)),
            },
            UsageLimits = new[] { SessionPresentation.ClaudeUsageLimit(
                new(new ClaudeLimitWindow(42, input.State.Now.AddSeconds(7_980), received), new ClaudeLimitWindow(31, input.State.Now.AddSeconds(273_600), received)), input.State.Now)! },
        };
        return new SettingsInput(input with { State = state, Update = Update("available", input.State.Now), ClaudeBridged = true }, new Dictionary<TokenSource, DateTimeOffset>(),
            LoginItem.State.NotRegistered);
    }
}
