using System.Globalization;
using static TokenCat.Lang;

namespace TokenCat;

// StatusBarView.swift 1–232 (DESIGN §6.1): the AI summary, the rate and tooltip texts, the quick menu summary, and the menu-bar
// items, layouts, presets and cell widths the on-screen widget draws (§4.7). The tray tooltip and the context menu use the rest.

/// `StatusBarLayout`; raw values as stored ("minimal", "compact", "inline").
public enum StatusBarLayout { Minimal, Compact, Inline }

/// `MetricID`, the menu-bar items in their default order. Stored as the Swift raw values ("cpu", "codexSpeed").
public enum MetricID { Cpu, Memory, Disk, Battery, Network, Ai, CodexSpeed, ClaudeSpeed }

/// `DisplayPreset`: one-pick widget setups. They set the layout and, except Minimal, the shown items with their order.
public enum DisplayPreset { Minimal, AiFocus, SystemMonitor, EverythingInline }

public static class StatusBarLayouts
{
    extension(StatusBarLayout layout)
    {
        public string Title => layout switch
        {
            StatusBarLayout.Minimal => Loc("최소", "Minimal"),
            StatusBarLayout.Compact => Loc("두 줄", "Two Lines"),
            _ => Loc("한 줄", "One Line"),
        };

        public string Summary => layout switch
        {
            StatusBarLayout.Minimal => Loc("캐릭터와 AI 상태·세션 수만 표시합니다", "Shows only the character, AI status and session count"),
            StatusBarLayout.Compact => Loc("지표 이름 아래에 값을 표시합니다", "Shows each value under its name"),
            // The mac draws SF Symbols here; Windows has no matching icons, so the short names stand in.
            _ => Loc("이름 옆에 값을 한 줄로 표시합니다", "Shows values on one line beside their names"),
        };
    }

    static readonly MetricID[] standard = [MetricID.Cpu, MetricID.Memory, MetricID.Disk, MetricID.Battery, MetricID.Network, MetricID.Ai];

    extension(MetricID)
    {
        /// Shown by default and by the full presets; the speed items are opt-in.
        public static IReadOnlyList<MetricID> Standard => standard;
    }

    extension(MetricID id)
    {
        /// The item list's name (mac `MetricID.title`).
        public string Title => id switch
        {
            MetricID.Cpu => "CPU",
            MetricID.Memory => Loc("메모리", "Memory"),
            MetricID.Disk => Loc("저장 공간", "Storage"),
            MetricID.Battery => Loc("배터리", "Battery"),
            MetricID.Network => Loc("네트워크", "Network"),
            MetricID.Ai => Loc("AI 세션", "AI sessions"),
            MetricID.CodexSpeed => Loc("Codex 속도", "Codex speed"),
            _ => Loc("Claude 속도", "Claude speed"),
        };

        /// The label the widget draws, shown after the title in the item list (mac `barLabel`); null when it equals the title, or
        /// for a speed item, whose row shows its glyph instead.
        public string? BarLabel => id switch
        {
            MetricID.Memory => "RAM",
            MetricID.Disk => "DISK",
            MetricID.Battery => "BAT",
            MetricID.Network => "NET",
            MetricID.Ai => "AI",
            _ => null,
        };

        /// The client whose "지금 속도" a speed item shows.
        public TokenSource? SpeedSource => id switch
        {
            MetricID.CodexSpeed => TokenSource.Codex,
            MetricID.ClaudeSpeed => TokenSource.Claude,
            _ => null,
        };
    }

    extension(DisplayPreset preset)
    {
        public string Title => preset switch
        {
            DisplayPreset.Minimal => Loc("최소", "Minimal"),
            DisplayPreset.AiFocus => Loc("AI 집중", "AI Focus"),
            DisplayPreset.SystemMonitor => Loc("시스템 모니터", "System Monitor"),
            _ => Loc("전체 한 줄", "All on One Line"),
        };

        public StatusBarLayout Layout => preset switch
        {
            DisplayPreset.Minimal => StatusBarLayout.Minimal,
            DisplayPreset.EverythingInline => StatusBarLayout.Inline,
            _ => StatusBarLayout.Compact,
        };

        /// Null leaves the item list alone (the minimal layout ignores it). Fixed sets: a later item never turns an existing setup
        /// into 사용자 지정.
        public IReadOnlyList<MetricID>? Items => preset switch
        {
            DisplayPreset.Minimal => null,
            DisplayPreset.AiFocus => [MetricID.Ai, MetricID.Cpu, MetricID.Memory],
            _ => MetricID.Standard,
        };
    }
}

/// One menu-bar item as drawn. The mac's SF Symbol name is left out, and its VoiceOver `Detail` is kept only for the speed items,
/// whose glyph has no words; the widget's help is the tray tooltip.
public sealed record StatusBarMetric(MetricID Id, string Label, string Value, bool IsActive = false,
    TokenActivityState ActivityState = TokenActivityState.Idle, string? Detail = null)
{
    /// What Narrator reads for the item: its detail, else the words drawn.
    public string Spoken => Detail ?? $"{Label} {Value.Replace('\n', ' ')}";
}

/// AI summary, derived once per publish from the shared session groups.
public sealed record StatusAISummary
{
    /// Top-level groups that are running or waiting for the person.
    public int Running { get; init; }
    /// Top-level groups with a member waiting for the person (question or plan approval).
    public int Input { get; init; }
    /// Top-level groups waiting for a log; counted (secondary) only while nothing runs (M-2).
    public int Waiting { get; init; }
    /// `SessionCounts.Phase` with input forced: input > tool > working (API retry included) > stale (log wait) > idle.
    public TokenActivityState Phase { get; init; } = TokenActivityState.Idle;

    public StatusAISummary() { }

    public StatusAISummary(IReadOnlyList<SessionGroup> groups, SessionCounts counts)
    {
        var waiting = groups.Where(group => group.Members.Any(member => member.Reading.ActivityState == TokenActivityState.Input)).ToList();
        Input = waiting.Count;
        Running = counts.RunningGroups + waiting.Count(group => !group.State.IsRunning);
        Waiting = counts.Waiting;
        Phase = Input > 0 ? TokenActivityState.Input : counts.Phase;
    }
}

public static class StatusBarContent
{
    static readonly string[] Units = ["B/s", "kB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s", "ZB/s", "YB/s"];

    public static string NetworkRate(double? value)
    {
        if (value is not { } amount || !double.IsFinite(amount) || amount < 0) return "—";
        var unit = 0;
        while (amount >= 1_000 && unit < Units.Length - 1) { amount /= 1_000; unit++; }
        // kB/s and above keep one decimal below 10 ("1.0kB/s"), so the flyout and the tooltip read the same string (M-4).
        static (double Value, int Precision) Round(double amount, int unit)
        {
            var tenths = Math.Round(amount * 10, MidpointRounding.AwayFromZero) / 10;
            return unit > 0 && tenths < 10 ? (tenths, 1) : (Math.Round(amount, MidpointRounding.AwayFromZero), 0);
        }
        var rounded = Round(amount, unit);
        // Promote the unit when display rounding would produce 1000kB/s.
        if (rounded.Value >= 1_000 && unit < Units.Length - 1)
        {
            amount /= 1_000;
            unit++;
            rounded = Round(amount, unit);
        }
        if (rounded.Value >= 1_000) return "≥999" + Units[unit];
        return rounded.Value.ToString(rounded.Precision == 1 ? "F1" : "F0", CultureInfo.InvariantCulture) + Units[unit];
    }

    /// The status item's geometry in points (`StatusBarContentView`): 4 pt edges, the 32 × 20 runner slot while the character
    /// is shown and fixed cells, so the width never follows the values.
    public const double Edge = 4, RunnerWidth = 32, Height = 24, MarkSlot = 8 + 3;

    /// Without the character the minimal AI cell widens to 41 pt. Speed items fit "9999.9 tok/s" (an 11 pt value, a thin space and
    /// an 8.5 pt unit), so a 4-digit rate never shrinks.
    public static double CellWidth(StatusBarLayout layout, MetricID id, bool showRunner = true) => layout switch
    {
        StatusBarLayout.Minimal => showRunner ? 30 : 41,
        StatusBarLayout.Compact => id switch { MetricID.Network => 66, MetricID.Ai => 36, MetricID.CodexSpeed or MetricID.ClaudeSpeed => 66, _ => 32 },
        _ => id switch { MetricID.Network => 114, MetricID.Ai => 46, MetricID.CodexSpeed or MetricID.ClaudeSpeed => 80, _ => 52 },
    };

    /// Neither items nor the character: the 28 pt "TC" placeholder.
    public static double RequiredWidth(StatusBarLayout layout, IEnumerable<MetricID> ids, bool showRunner = true)
    {
        var cells = ids.Select(id => CellWidth(layout, id, showRunner)).ToList();
        if (cells.Count == 0 && !showRunner) return 28;
        return Edge * 2 + (showRunner ? RunnerWidth + (cells.Count == 0 ? 0 : 2) : 0) + cells.Sum();
    }

    /// `StateGlyph` sizes in the bar: 7 pt, the input disc 8 pt (A0-3). Every state reserves `MarkSlot`, so the count never moves.
    public static double MarkWidth(TokenActivityState state) => state switch
    {
        TokenActivityState.Input => 8,
        TokenActivityState.Tool or TokenActivityState.Working or TokenActivityState.Stale => 7,
        _ => 0,
    };

    /// Each client's "지금 속도" by the dashboard's rule (`SessionPresentation.CurrentSpeed`); a client without one is absent.
    public static IReadOnlyDictionary<TokenSource, double> Speeds(SessionListModel list, DateTimeOffset now, IReadOnlySet<TokenSource> restart)
    {
        var speeds = new Dictionary<TokenSource, double>();
        foreach (var source in Enum.GetValues<TokenSource>())
            if (SessionPresentation.CurrentSpeed(list, now, restart, source) is { } speed) speeds[source] = speed.Rate;
        return speeds;
    }

    /// `StatusBarContent.metrics`: `items` are the shown items in order (the minimal layout draws only AI). An absent battery
    /// is omitted; values before the first sample are "—", and so is a speed item whose client has no rate in `speeds`.
    public static IReadOnlyList<StatusBarMetric> Metrics(SystemSnapshot system, StatusAISummary ai, StatusBarLayout layout,
        IReadOnlyList<MetricID> items, bool hasSample, bool hasTokenSample, IReadOnlyDictionary<TokenSource, double>? speeds = null)
    {
        string Percentage(double? number) => hasSample && number is { } n && double.IsFinite(n) ? Format.Percent(n) : "—";
        var upload = NetworkRate(hasSample ? system.UploadBytesPerSecond : null);
        var download = NetworkRate(hasSample ? system.DownloadBytesPerSecond : null);
        var metrics = new List<StatusBarMetric>();
        foreach (var id in layout == StatusBarLayout.Minimal ? [MetricID.Ai] : items)
        {
            switch (id)
            {
                case MetricID.Cpu: metrics.Add(new(id, "CPU", Percentage(system.CpuPercent))); break;
                case MetricID.Memory: metrics.Add(new(id, "RAM", Percentage(Format.Ratio(system.MemoryUsedBytes, system.MemoryTotalBytes)))); break;
                case MetricID.Disk: metrics.Add(new(id, "DISK", Percentage(Format.Ratio(system.DiskUsedBytes, system.DiskTotalBytes)))); break;
                case MetricID.Battery when system.BatteryPresent: metrics.Add(new(id, "BAT", Percentage(system.BatteryPercent))); break;
                case MetricID.Network: metrics.Add(new(id, "NET", $"↑{upload}\n↓{download}")); break;
                case MetricID.Ai:
                    // Running groups with their phase mark; with none running, the log-wait groups (secondary, half disc);
                    // otherwise a tertiary "0" without a mark (M-2).
                    var waitingOnly = ai.Running == 0 && ai.Waiting > 0;
                    var value = hasTokenSample ? (waitingOnly ? ai.Waiting : ai.Running).ToString(CultureInfo.InvariantCulture) : "—";
                    var state = !hasTokenSample ? TokenActivityState.Idle : ai.Running > 0 ? ai.Phase : waitingOnly ? TokenActivityState.Stale : TokenActivityState.Idle;
                    metrics.Add(new(id, "AI", value, hasTokenSample && ai.Running > 0, state));
                    break;
                case MetricID.CodexSpeed or MetricID.ClaudeSpeed:
                    // A glyph stands in for the label; the unit is split off and drawn smaller like "%".
                    var rate = speeds is not null && speeds.TryGetValue(id.SpeedSource!.Value, out var measured) ? Format.Tps(measured) : null;
                    metrics.Add(new(id, "", rate is null ? "—" : rate + "tok/s", Detail: id.Title + " "
                        + (rate is null ? Loc("측정 없음", "no measurement") : Loc($"{rate} 토큰/초", $"{rate} tokens per second"))));
                    break;
            }
        }
        return metrics;
    }

    public static IReadOnlyList<StatusBarMetric> Metrics(MonitorState state, StatusBarLayout layout, IReadOnlyList<MetricID> items) =>
        Metrics(state.System, new StatusAISummary(state.Groups, state.Sessions.Counts), layout, items, state.HasSample, state.TokensSampledAt is not null,
            Speeds(state.Sessions, state.Now, state.TelemetryRestartNeeded));

    /// "1.5kB/s" → ("1.5", "kB/s"); units are drawn smaller but never dropped.
    public static (string Number, string Unit) SplitRate(string text)
    {
        var index = text.ToList().FindIndex(char.IsLetter);
        return index < 0 ? (text, "") : (text[..index], text[index..]);
    }

    /// `Running` includes the input groups; they are named once, at the end (working + input = the tray count).
    static string AICountLine(SessionCounts counts, StatusAISummary ai) =>
        Loc($"진행 중 {ai.Running - ai.Input}개 · 도구 실행 {counts.ToolMembers} · 하위 에이전트 {counts.RunningSubagents} · 로그 대기 {counts.Waiting}",
            $"Working {ai.Running - ai.Input} · Running tool {counts.ToolMembers} · Subagents {counts.RunningSubagents} · Waiting for log {counts.Waiting}")
        + (ai.Input > 0 ? Loc($" · 입력 필요 {ai.Input}", $" · Input needed {ai.Input}") : "");

    /// The tray tooltip: only slow-changing context; live values stay in the flyout. The App truncates it to 127 chars.
    public static string Tooltip(SystemSnapshot system, SessionCounts counts, StatusAISummary ai, bool hasSample, bool hasTokenSample)
    {
        static string? Capacity(ulong? used, ulong? total)
        {
            if (used is not { } u || total is not ({ } t and > 0)) return null;
            var tera = t >= 1_099_511_627_776;
            var factor = tera ? 1_099_511_627_776.0 : 1_073_741_824.0;
            var format = tera ? "F1" : "F0";
            return (u / factor).ToString(format, CultureInfo.InvariantCulture) + " / " + (t / factor).ToString(format, CultureInfo.InvariantCulture)
                   + (tera ? " TB" : " GB");
        }
        // The AI line before memory and storage: the App keeps whole lines under 128 characters, and "Input needed" must survive.
        var lines = new List<string> { "TokenCat", hasTokenSample ? Loc("AI ", "AI: ") + AICountLine(counts, ai) : Loc("AI 기록 확인 중", "Reading AI records") };
        if (hasSample)
        {
            var parts = new[]
            {
                Capacity(system.MemoryUsedBytes, system.MemoryTotalBytes) is { } memory ? Loc("메모리 ", "Memory ") + memory : null,
                Capacity(system.DiskUsedBytes, system.DiskTotalBytes) is { } disk ? Loc("저장 공간 ", "Storage ") + disk : null,
            }.OfType<string>().ToList();
            if (parts.Count > 0) lines.Add(string.Join(" · ", parts));
        }
        lines.Add(Loc("클릭: 상세 화면 · 우클릭: 빠른 메뉴", "Click: details · Right-click: quick menu"));
        return string.Join("\n", lines);
    }
}

/// The context menu's live summary (M-5), built when the menu opens and not refreshed while it stays open.
public sealed record QuickMenuSummary(string Headline)
{
    /// `Id` is the `SessionGroup.Id` the flyout should select.
    public sealed record Row(string Id, StateGlyphKind Kind, string Title);

    /// Up to three live top-level groups in urgency order.
    public IReadOnlyList<Row> Rows { get; init; } = [];

    public static QuickMenuSummary Make(IReadOnlyList<SessionGroup> groups, SessionCounts counts, bool hasTokenSample, DateTimeOffset now)
    {
        if (!hasTokenSample) return new QuickMenuSummary(Loc("AI 기록 확인 중", "Reading AI records"));
        var parts = new[]
        {
            (Loc("입력", "Input"), counts.Input), (Loc("재시도", "Retry"), counts.Retrying), (Loc("도구", "Tool"), counts.Tool),
            (Loc("진행", "Working"), counts.Working), (Loc("로그 대기", "Waiting for log"), counts.Waiting),
        }.Where(part => part.Item2 > 0).Select(part => $"{part.Item1} {part.Item2}").ToList();
        static int Rank(SessionDisplayState state) => SessionDisplayState.LiveOrder.ToList().IndexOf(state) is var index and >= 0 ? index : 99;
        var live = groups.Where(group => group.State.IsLive && group.State != SessionDisplayState.Measurement)
            .OrderBy(group => Rank(group.State)).ThenByDescending(group => group.LastActivity).ThenBy(group => group.Id, StringComparer.Ordinal);
        var rows = new List<Row>();
        foreach (var group in live.Take(3))
        {
            if (StateGlyphKind.From(group.State) is not { } kind) continue;
            var project = group.Lead.Reading.Project is { Length: > 0 } name ? name : Loc("프로젝트 미확인", "Unknown project");
            if (new StringInfo(project).LengthInTextElements > 28) project = SessionPresentation.Prefix(project, 27) + "…";
            rows.Add(new Row(group.Id, kind, $"{project} — {Detail(group, now)}"));
        }
        return new QuickMenuSummary(parts.Count == 0 ? Loc("진행 중인 세션 없음", "No active sessions")
                                        : string.Join(" · ", parts.Prepend(Loc("AI 세션", "AI sessions"))))
        { Rows = rows };
    }

    /// "입력 대기 3분", "명령 실행 · 턴 7분", "로그 대기 · 3분째 기록 없음": minutes only, never seconds.
    public static string Detail(SessionGroup group, DateTimeOffset now)
    {
        var member = group.Members.FirstOrDefault(member => member.State == group.State)?.Reading ?? group.Lead.Reading;
        var turn = group.Members.Select(member => member.Reading.CurrentTurnStartedAt).Min() is { } start
            ? Loc(" · 턴 ", " · turn ") + Minutes((now - start).TotalSeconds) : "";
        switch (group.State)
        {
            case SessionDisplayState.Input:
                var since = member.LastActivity is { } at ? Loc(" ", " · ") + Minutes((now - at).TotalSeconds) : "";
                return (SessionPresentation.IsPlanApproval(member) ? Loc("계획 승인 대기", "Waiting for plan approval") : Loc("입력 대기", "Waiting for input")) + since;
            case SessionDisplayState.Retrying: return Loc("API 재시도", "API retry") + turn;
            case SessionDisplayState.Tool: return SessionPresentation.ToolTitle(member.ToolCategory) + turn;
            case SessionDisplayState.Working: return Loc("진행", "Working") + turn;
        }
        if (SessionPresentation.LiveAt(member) is not { } live || (now - live).TotalSeconds < 60) return Loc("로그 대기", "Waiting for log");
        var quiet = Minutes((now - live).TotalSeconds);
        return Loc($"로그 대기 · {quiet}째 기록 없음", $"Waiting for log · no record for {quiet}");
    }

    public static string Minutes(double seconds)
    {
        var total = Math.Max(0, (int)seconds) / 60;
        if (total < 1) return Loc("1분 미만", "<1m");
        return total >= 60
            ? Format.Span(total / 60, Format.TimeUnit.Hour) + " " + Format.Span(total % 60, Format.TimeUnit.Minute)
            : Format.Span(total, Format.TimeUnit.Minute);
    }
}
