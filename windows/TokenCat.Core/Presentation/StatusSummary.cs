using System.Globalization;
using static TokenCat.Lang;

namespace TokenCat;

// StatusBarView.swift 1–232 (DESIGN §6.1): the AI summary, the rate and tooltip texts, the quick menu summary, and the menu-bar
// items, layouts, presets and cell widths the on-screen widget draws (§4.7). The tray tooltip and the context menu use the rest.

/// `StatusBarLayout`; raw values as stored ("minimal", "compact", "inline").
public enum StatusBarLayout { Minimal, Compact, Inline }

/// `MetricID`, the menu-bar items in their default order. Stored as the Swift raw values ("cpu", "averageSpeed").
public enum MetricID { Cpu, Memory, Disk, Battery, Network, Ai, AverageSpeed, WeeklyLimit }

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
        /// Shown by default and by the full presets; speed and weekly limit are opt-in.
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
            MetricID.WeeklyLimit => Loc("주간 한도", "Weekly limit"),
            _ => Loc("평균 속도", "Average speed"),
        };

        /// The label the widget draws, shown after the title in the item list (mac `barLabel`); null when it equals the title.
        public string? BarLabel => id switch
        {
            MetricID.Memory => "RAM",
            MetricID.Disk => "DISK",
            MetricID.Battery => "BAT",
            MetricID.Network => "NET",
            MetricID.Ai => "AI",
            MetricID.AverageSpeed => "AVG",
            MetricID.WeeklyLimit => "WK",
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

public enum StatusBarValueTone { Label, Warning, Critical }

/// One menu-bar item as drawn. Provider glyphs label measured speed and weekly remaining; their details supply spoken words.
/// Weekly tooltip text includes every contributing account, while its single source is the least-left account's provider.
public sealed record StatusBarMetric(MetricID Id, string Label, string Value, bool IsActive = false,
    TokenActivityState ActivityState = TokenActivityState.Idle, string? Detail = null, IReadOnlyList<TokenSource>? Sources = null,
    StatusBarValueTone ValueTone = StatusBarValueTone.Label, string? Tooltip = null)
{
    /// What Narrator reads for the item: its detail, else the words drawn.
    public string Spoken => Detail ?? $"{Label} {Value.Replace('\n', ' ')}";

    public IReadOnlyList<TokenSource> Contributors => Sources ?? [];

    /// By value, the contributors included, so an unchanged strip is not redrawn.
    public bool Equals(StatusBarMetric? other) => other is not null && Id == other.Id && Label == other.Label && Value == other.Value
        && IsActive == other.IsActive && ActivityState == other.ActivityState && Detail == other.Detail && ValueTone == other.ValueTone
        && Tooltip == other.Tooltip && Contributors.SequenceEqual(other.Contributors);

    public override int GetHashCode() => HashCode.Combine(Id, Label, Value, IsActive, ActivityState, Detail, ValueTone, Tooltip);
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

    /// Without the character the minimal AI cell widens to 41 pt. The speed item fits "9999 tok/s" (`Format.BarTps` drops the decimal
    /// from 100 up; an 11 pt value, a thin space and an 8.5 pt unit) beside three glyphs side by side, 1 pt apart, so a 4-digit rate
    /// never shrinks: on one line the row's 22 pt beyond one glyph widen the cell from 69 to 91.
    public static double CellWidth(StatusBarLayout layout, MetricID id, bool showRunner = true) => layout switch
    {
        StatusBarLayout.Minimal => showRunner ? 30 : 41,
        StatusBarLayout.Compact => id switch { MetricID.Network => 66, MetricID.Ai => 36, MetricID.AverageSpeed => 56, MetricID.WeeklyLimit => 36, _ => 32 },
        _ => id switch { MetricID.Network => 114, MetricID.Ai => 46, MetricID.AverageSpeed => 91, MetricID.WeeklyLimit => 56, _ => 52 },
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

    /// Weekly windows from the already-selected accounts, least remaining first; reset windows never contribute.
    public static IReadOnlyList<UsageLimitSummary> WeeklyLimits(IReadOnlyList<UsageLimitSummary> limits, DateTimeOffset now)
    {
        var weekly = new List<UsageLimitSummary>();
        foreach (var limit in limits)
        {
            if (limit.WindowMinutes == 10_080 && !limit.Expired(now)) weekly.Add(limit);
            if (limit.OtherSummary(now) is { WindowMinutes: 10_080 } other && !other.Expired(now)) weekly.Add(other);
        }
        return [.. weekly.OrderBy(limit => Math.Clamp(100 - limit.UsedPercent, 0, 100))];
    }

    public static StatusBarMetric WeeklyMetric(IReadOnlyList<UsageLimitSummary> limits, DateTimeOffset now)
    {
        var weekly = WeeklyLimits(limits, now);
        if (weekly.Count == 0)
        {
            var empty = Loc("주간 한도 기록 없음", "No weekly limit recorded");
            return new(MetricID.WeeklyLimit, "WK", "—", Detail: empty, Tooltip: empty);
        }
        var labels = UsageLimitSummary.CompactAccountLabels([.. weekly.Select(limit => limit.AccountLabel is null && limit.Account is { } account
            ? limit with { AccountLabel = account.Label + (account.OrganizationName is { } organization ? " · " + organization : "") }
            : limit)]);
        string Detail(int index)
        {
            var limit = weekly[index];
            var percent = Format.Percent(Math.Clamp(100 - limit.UsedPercent, 0, 100));
            var account = limit.Source.ShortTitle + (labels[index] is { } label ? " " + label : "");
            var text = Loc($"주간 한도 {percent} 남음", $"Weekly limit {percent} left") + " · " + account;
            if (limit.ResetDate is { } reset)
            {
                var countdown = SessionPresentation.Countdown(reset, now);
                text += Loc($" · {countdown} 후 초기화", $" · resets in {countdown}");
            }
            return text;
        }
        var remaining = Math.Clamp(100 - weekly[0].UsedPercent, 0, 100);
        var detail = string.Join("\n", Enumerable.Range(0, weekly.Count).Select(Detail));
        return new(MetricID.WeeklyLimit, "WK", Format.Percent(remaining), Detail: detail, Sources: [weekly[0].Source],
            ValueTone: remaining <= 5 ? StatusBarValueTone.Critical : remaining <= 15 ? StatusBarValueTone.Warning : StatusBarValueTone.Label,
            Tooltip: detail);
    }

    /// `StatusBarContent.metrics`: `items` are the shown items in order (the minimal layout draws only AI). An absent battery
    /// is omitted; values before the first sample are "—", and so is the speed item without a `speed`
    /// (`SessionPresentation.Average`).
    public static IReadOnlyList<StatusBarMetric> Metrics(SystemSnapshot system, StatusAISummary ai, StatusBarLayout layout,
        IReadOnlyList<MetricID> items, bool hasSample, bool hasTokenSample, AverageSpeed? speed = null,
        IReadOnlyList<UsageLimitSummary>? usageLimits = null, DateTimeOffset now = default)
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
                    // Running groups with their phase mark; while any waits for the person, only those (the number to act on);
                    // with none running, the log-wait groups (secondary, half disc); otherwise a tertiary "0" without a mark (M-2).
                    var waitingOnly = ai.Running == 0 && ai.Waiting > 0;
                    var shown = waitingOnly ? ai.Waiting : ai.Running > 0 && ai.Phase == TokenActivityState.Input ? ai.Input : ai.Running;
                    var value = hasTokenSample ? shown.ToString(CultureInfo.InvariantCulture) : "—";
                    var state = !hasTokenSample ? TokenActivityState.Idle : ai.Running > 0 ? ai.Phase : waitingOnly ? TokenActivityState.Stale : TokenActivityState.Idle;
                    metrics.Add(new(id, "AI", value, hasTokenSample && ai.Running > 0, state));
                    break;
                case MetricID.AverageSpeed:
                    // The contributing clients' glyphs, or "AVG" without a measurement, label the item; the unit is split off and
                    // drawn smaller like "%".
                    var rate = speed is null ? null : Format.Tps(speed.Rate);
                    var names = speed is null ? "" : " · " + string.Join(", ", speed.Sources.Select(source => source.Title));
                    metrics.Add(new(id, "AVG", speed is null ? "—" : Format.BarTps(speed.Rate) + "tok/s", Detail: id.Title + " "
                        + (rate is null ? Loc("측정 없음", "no measurement") : Loc($"{rate} 토큰/초", $"{rate} tokens per second") + names),
                        Sources: speed?.Sources));
                    break;
                case MetricID.WeeklyLimit:
                    metrics.Add(WeeklyMetric(usageLimits ?? [], now));
                    break;
            }
        }
        return metrics;
    }

    public static IReadOnlyList<StatusBarMetric> Metrics(MonitorState state, StatusBarLayout layout, IReadOnlyList<MetricID> items) =>
        Metrics(state.System, new StatusAISummary(state.Groups, state.Sessions.Counts), layout, items, state.HasSample, state.TokensSampledAt is not null,
            SessionPresentation.Average(state.Sessions, state.Now, state.TelemetryRestartNeeded), state.UsageLimits, state.Now);

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

    /// Live groups beyond `Rows`, reached through the dashboard.
    public int More { get; init; }

    /// "그 외 9개 세션…": the quick menu's last summary row when more groups are live than it lists.
    public static string MoreTitle(int count) => Loc($"그 외 {count}개 세션…", count == 1 ? "1 more session…" : $"{count} more sessions…");

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
            .OrderBy(group => Rank(group.State)).ThenByDescending(group => group.LastActivity).ThenBy(group => group.Id, StringComparer.Ordinal).ToList();
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
        { Rows = rows, More = Math.Max(0, live.Count - 3) };
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
