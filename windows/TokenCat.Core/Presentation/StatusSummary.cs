using System.Globalization;
using static TokenCat.Lang;

namespace TokenCat;

// StatusBarView.swift 1–232 (DESIGN §6.1): the AI summary, the rate and tooltip texts and the quick menu summary. The menu-bar
// metrics, layouts and presets are cut (§3.2); the tray tooltip and the context menu use these.

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

    public static string PhaseTitle(TokenActivityState phase) => phase switch
    {
        TokenActivityState.Input => Loc("입력 필요", "Input needed"),
        TokenActivityState.Tool => Loc("도구 실행", "Running tool"),
        TokenActivityState.Working => Loc("진행", "Working"),
        TokenActivityState.Stale => Loc("로그 대기", "Waiting for log"),
        _ => Loc("활동 없음", "No activity"),
    };
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
        var lines = new List<string> { "TokenCat" };
        if (hasSample)
        {
            var parts = new[]
            {
                Capacity(system.MemoryUsedBytes, system.MemoryTotalBytes) is { } memory ? Loc("메모리 ", "Memory ") + memory : null,
                Capacity(system.DiskUsedBytes, system.DiskTotalBytes) is { } disk ? Loc("저장 공간 ", "Storage ") + disk : null,
            }.OfType<string>().ToList();
            if (parts.Count > 0) lines.Add(string.Join(" · ", parts));
        }
        lines.Add(hasTokenSample ? Loc("AI ", "AI: ") + AICountLine(counts, ai) : Loc("AI 기록 확인 중", "Reading AI records"));
        lines.Add(Loc("클릭: 세션 상세 · 우클릭: 빠른 메뉴", "Click: details · Right-click: quick menu"));
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
