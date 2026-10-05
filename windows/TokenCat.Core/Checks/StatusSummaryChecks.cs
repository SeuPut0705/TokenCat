using static TokenCat.Lang;
using A = TokenCat.TokenActivityState;

namespace TokenCat;

/// StatusBarView.swift `runStatusBarChecks`, text and summary part (DESIGN §6.1): rates, the AI summary, the tooltip and the
/// quick menu. Menu-bar widths, rendering, presets and the preview cache are cut with the menu bar; the cat's run is WP4's.
/// The AI item's count and mark are read from `StatusAISummary` the way the mac item derives them.
public static class StatusSummaryChecks
{
    public static List<string> Run()
    {
        var c = new Check("Status bar", "Status bar ");
        void check(string name, bool valid) => c.That(valid, name);
        (string Name, double? Value, string Expected)[] cases =
        [
            ("missing rate", null, "—"), ("zero rate", 0, "0B/s"),
            ("byte rounding", 999.49, "999B/s"), ("byte unit crossover", 999.5, "1.0kB/s"),
            ("kilobyte unit", 1_000, "1.0kB/s"), ("kilobyte precision", 1_499, "1.5kB/s"),
            ("ten kilobytes drop the decimal", 9_960, "10kB/s"), ("two-digit kilobytes", 12_345, "12kB/s"),
            ("kilobyte rounding", 999_499, "999kB/s"), ("megabyte crossover", 999_500, "1.0MB/s"),
            ("gigabyte unit", 1_000_000_000, "1.0GB/s"), ("terabyte unit", 1_000_000_000_000, "1.0TB/s"),
            ("invalid rate", double.PositiveInfinity, "—"), ("negative rate", -1, "—"),
        ];
        foreach (var (name, value, expected) in cases)
        {
            var actual = StatusBarContent.NetworkRate(value);
            check($"{name}: expected {expected}, got {actual}", actual == expected);
        }

        var at = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        (SessionCounts Counts, StatusAISummary AI) summary(IReadOnlyList<TokenReading> readings, DateTimeOffset? now = null)
        {
            var groups = SessionPresentation.Groups(readings, now ?? at);
            var counts = new SessionCounts(groups);
            return (counts, new StatusAISummary(groups, counts));
        }
        // The mac AI item: running groups with their phase; with none running, the log-wait groups and the half disc.
        (int Value, A Mark) ai(IReadOnlyList<TokenReading> readings, DateTimeOffset? now = null)
        {
            var value = summary(readings, now).AI;
            var waitingOnly = value.Running == 0 && value.Waiting > 0;
            return (waitingOnly ? value.Waiting : value.Running, value.Running > 0 ? value.Phase : waitingOnly ? A.Stale : A.Idle);
        }

        check("selected order and activity count do not aggregate speed", ai([
            new TokenReading(TokenSource.Codex, "active-codex") { Model = "current-codex", Active = true },
            new TokenReading(TokenSource.Claude, "active-claude") { Model = "current-claude", Active = true },
            new TokenReading(TokenSource.Codex, "inactive-codex"),
        ]) == (2, A.Working));
        var output = new TokenReading(TokenSource.Codex, "output")
        { Active = true, ActivityState = A.Output, LastOutputAt = at, LastOutputDelta = 12, SampledAt = at };
        var tool = new TokenReading(TokenSource.Claude, "tool") { Active = true, ActivityState = A.Tool, SampledAt = at };
        check("pending tool remains visible alongside output", ai([output, tool]) == (2, A.Tool));
        check("a fresh record is an event: the mark stays working", ai([output]) == (1, A.Working));
        check("old output keeps the working mark while the turn remains active", ai([output with { SampledAt = at.AddSeconds(6) }], at.AddSeconds(6)).Mark == A.Working);
        var stale = new TokenReading(TokenSource.Codex, "stale") { LastActivity = at.AddSeconds(-180), ActivityState = A.Stale, SampledAt = at };
        check("with nothing running, log-wait groups show their count and the half-disc mark, not as running",
              ai([stale]) == (1, A.Stale) && summary([stale]).AI.Running == 0);
        var unfinished = new TokenReading(TokenSource.Codex, "unfinished") { LastActivity = at.AddSeconds(-3_600), ActivityState = A.Unfinished, SampledAt = at };
        check("unfinished turns are neither counted nor marked", ai([unfinished]) == (0, A.Idle));
        check("a running session outranks waiting for the mark and the count", ai([stale, tool]) == (1, A.Tool));
        var question = new TokenReading(TokenSource.Claude, "question") { SessionID = "q1", Active = true, ActivityState = A.Input, SampledAt = at };
        var questionSummary = summary([question, tool]);
        check("input outranks tool and counts once per group", ai([question, tool]) == (2, A.Input) && questionSummary.AI.Input == 1
              && StatusBarContent.Tooltip(new SystemSnapshot(), questionSummary.Counts, questionSummary.AI, false, true).Contains("입력 필요 1"));
        var parent = new TokenReading(TokenSource.Claude, "claude:parent") { SessionID = "s1", Active = true, ActivityState = A.Working, SampledAt = at };
        var child = new TokenReading(TokenSource.Claude, "claude:child")
        { SessionID = "s1", AgentID = "a1", IsSubagent = true, Active = true, ActivityState = A.Tool, SampledAt = at };
        check("subagents count once with their session", ai([parent, child]) == (1, A.Tool) && summary([parent, child]).Counts.RunningSubagents == 1);
        parent = parent with { ActivityState = A.Complete, Active = false };
        child = child with { ParentSessionID = "s1" };
        check("a running subagent keeps an idle parent's group running", ai([parent, child]).Value == 1);
        child = child with { ActivityState = A.Input };
        check("a subagent waiting for input marks its top-level group", ai([parent, child]) == (1, A.Input));
        check("rate split keeps the unit", StatusBarContent.SplitRate("1.5kB/s") == ("1.5", "kB/s")
              && StatusBarContent.SplitRate("≥999GB/s") == ("≥999", "GB/s") && StatusBarContent.SplitRate("—") == ("—", ""));
        var busy = new SystemSnapshot { CpuPercent = 37, UploadBytesPerSecond = 1_499, MemoryUsedBytes = 19_000_000_000, MemoryTotalBytes = 25_769_803_776 };
        var (busyCounts, busyAI) = summary([tool, question]);
        var tip = StatusBarContent.Tooltip(busy, busyCounts, busyAI, hasSample: true, hasTokenSample: true);
        var laterTip = StatusBarContent.Tooltip(busy with { CpuPercent = 81, UploadBytesPerSecond = 88_000 }, busyCounts, busyAI, true, true);
        check("tooltip omits per-second values and names the quick menu",
              tip == laterTip && !tip.Contains('%') && !tip.Contains("B/s") && tip.Contains("우클릭: 빠른 메뉴")
              && tip.Contains("메모리 18 / 24 GB") && tip.Contains("입력 필요 1"));

        // Quick menu (M-5): headline counts and up to three groups in urgency order, minutes only.
        TokenReading live(string id, string? project, A state, ToolCategory? category = null, double? turn = null, double last = -2) =>
            new(TokenSource.Claude, id)
            {
                SessionID = id, Project = project, Active = state != A.Stale, LastActivity = at.AddSeconds(last), ActivityState = state,
                SampledAt = at, ToolCategory = category, CurrentTurnStartedAt = turn is { } seconds ? at.AddSeconds(-seconds) : null,
            };
        var menuGroups = SessionPresentation.Groups([live("w", "web", A.Working, turn: 30), live("t", "api-server", A.Tool, ToolCategory.Command, turn: 420),
                                                     live("q", "TokenCat", A.Input, last: -185), live("s", null, A.Stale, last: -190),
                                                     live("z", "zz", A.Working, turn: 5)], at);
        var quick = QuickMenuSummary.Make(menuGroups, new SessionCounts(menuGroups), true, at);
        check($"the quick menu summarises live groups by urgency: {quick.Headline} / {string.Join(", ", quick.Rows.Select(row => row.Title))}",
              quick.Headline == "AI 세션 · 입력 1 · 도구 1 · 진행 2 · 로그 대기 1"
              && quick.Rows.Select(row => row.Title).SequenceEqual(["TokenCat — 입력 대기 3분", "api-server — 명령 실행 · 턴 7분", "web — 진행 · 턴 1분 미만"])
              && quick.Rows.Select(row => row.Kind).SequenceEqual([StateGlyphKind.Input, StateGlyphKind.Tool, StateGlyphKind.Working])
              && quick.Rows.FirstOrDefault()?.Id == "q");
        var waitingOnly = SessionPresentation.Groups([live("s", null, A.Stale, last: -190)], at);
        var loading = QuickMenuSummary.Make(menuGroups, new SessionCounts(menuGroups), false, at);
        check("quiet and loading quick menus say so",
              QuickMenuSummary.Make([], new SessionCounts(), true, at).Headline == "진행 중인 세션 없음"
              && loading.Headline == "AI 기록 확인 중" && loading.Rows.Count == 0
              && QuickMenuSummary.Make(waitingOnly, new SessionCounts(waitingOnly), true, at).Rows.FirstOrDefault()?.Title
                 == "프로젝트 미확인 — 로그 대기 · 3분째 기록 없음");
        With(AppLanguage.En, () =>
        {
            var english = QuickMenuSummary.Make(menuGroups, new SessionCounts(menuGroups), true, at);
            var englishTip = StatusBarContent.Tooltip(busy, busyCounts, busyAI, true, true);
            check($"English quick menu, tooltip and AI value: {english.Headline} / {string.Join(", ", english.Rows.Select(row => row.Title))} / {englishTip}",
                  english.Headline == "AI sessions · Input 1 · Tool 1 · Working 2 · Waiting for log 1"
                  && english.Rows.FirstOrDefault()?.Title == "TokenCat — Waiting for input · 3m" && english.Rows.LastOrDefault()?.Title == "web — Working · turn <1m"
                  && QuickMenuSummary.Minutes(3_900) == "1h 5m"
                  && QuickMenuSummary.Make(waitingOnly, new SessionCounts(waitingOnly), true, at).Rows.FirstOrDefault()?.Title
                     == "Unknown project — Waiting for log · no record for 3m"
                  && englishTip.EndsWith("AI: Working 2 · Running tool 1 · Subagents 0 · Waiting for log 0 · Input needed 1\nClick: details · Right-click: quick menu",
                                         StringComparison.Ordinal)
                  && englishTip.Contains("Memory 18 / 24 GB"));
        });
        return c.Done();
    }
}
