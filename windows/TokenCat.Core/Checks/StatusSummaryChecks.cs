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
              && tip.Contains("메모리 18 / 24 GB") && tip.Contains("진행 중 1개") && tip.Contains("입력 필요 1"));

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
                  && englishTip.StartsWith("TokenCat\nAI: Working 1 · Running tool 1 · Subagents 0 · Waiting for log 0 · Input needed 1\nMemory 18 / 24 GB",
                                           StringComparison.Ordinal)
                  && englishTip.EndsWith("\nClick: details · Right-click: quick menu", StringComparison.Ordinal));
            // The tray keeps whole lines under 128 characters: with storage too, the AI line and its input count still fit.
            var fullTip = StatusBarContent.Tooltip(busy with { DiskUsedBytes = 1_000_000_000_000, DiskTotalBytes = 2_000_000_000_000 }, busyCounts, busyAI, true, true);
            check($"the English tooltip keeps 'Input needed' within 127 characters: {fullTip}",
                  fullTip.IndexOf("Input needed 1\n", StringComparison.Ordinal) is >= 0 and var end && end + "Input needed 1".Length <= 127);
        });

        // The widget's items and layout contract (the mac menu-bar item's).
        var everything = Enum.GetValues<MetricID>();
        IReadOnlyList<StatusBarMetric> metrics(SystemSnapshot system, IReadOnlyList<TokenReading> readings, StatusBarLayout layout = StatusBarLayout.Compact,
            IReadOnlyList<MetricID>? items = null, bool hasSample = true, bool hasTokenSample = true) =>
            StatusBarContent.Metrics(system, summary(readings).AI, layout, items ?? everything, hasSample, hasTokenSample);
        static string? valueOf(IReadOnlyList<StatusBarMetric> list, MetricID id) => list.FirstOrDefault(metric => metric.Id == id)?.Value;
        var idleCpu = new SystemSnapshot { CpuPercent = 0 };
        var loadingItems = metrics(idleCpu, [], hasSample: false, hasTokenSample: false);
        var zero = metrics(idleCpu, []);
        var waitingForTokens = metrics(idleCpu, [], hasTokenSample: false);
        check("loading differs from sampled zero", valueOf(loadingItems, MetricID.Ai) == "—" && valueOf(loadingItems, MetricID.Cpu) == "—"
              && valueOf(waitingForTokens, MetricID.Cpu) == "0%" && valueOf(waitingForTokens, MetricID.Ai) == "—"
              && valueOf(zero, MetricID.Ai) == "0" && valueOf(zero, MetricID.Cpu) == "0%");
        check("absent battery is omitted", zero.All(metric => metric.Id != MetricID.Battery) && zero.Count == everything.Length - 1);
        check("idle AI has no mark and is not active",
              zero.First(metric => metric.Id == MetricID.Ai) is { IsActive: false } idleAI && StatusBarContent.MarkWidth(idleAI.ActivityState) == 0);
        var selected = metrics(idleCpu, [new TokenReading(TokenSource.Codex, "a") { Active = true }, new TokenReading(TokenSource.Claude, "b") { Active = true }],
            items: [MetricID.Ai, MetricID.Cpu]);
        check("selected items keep their order and the AI count is active", selected.Select(metric => metric.Id).SequenceEqual([MetricID.Ai, MetricID.Cpu])
              && selected[0] is { Value: "2", IsActive: true, ActivityState: A.Working });
        var minimal = metrics(idleCpu, [tool], StatusBarLayout.Minimal, [MetricID.Cpu]);
        check("minimal layout shows the AI item even when it is hidden from the list",
              minimal.Select(metric => metric.Id).SequenceEqual([MetricID.Ai]) && minimal[0].Value == "1" && minimal[0].ActivityState == A.Tool);
        check("waiting-only AI shows the log-wait count with the half disc, not active",
              metrics(idleCpu, [stale]).First(metric => metric.Id == MetricID.Ai) is { Value: "1", IsActive: false, ActivityState: A.Stale });
        // Speed items: each client's own "지금 속도" (`Format.Tps`, then a smaller "tok/s"), "—" without one, spoken per client;
        // the average item is the mean of every fresh per-session rate; the minimal layout still draws only AI.
        var timed = new TokenReading(TokenSource.Codex, "timed")
        {
            SessionID = "t1", Model = "g1", Active = true, ActivityState = A.Working, SampledAt = at,
            SpeedMeasurement = new TokenSpeedMeasurement(new TelemetryReading { Provider = TokenSource.Codex, At = at.AddSeconds(-3) }) { Model = "g1", ServerTokenIntervalMs = 18 },
        };
        var untimed = new TokenReading(TokenSource.Claude, "untimed") { SessionID = "u1", Model = "m1", Active = true, ActivityState = A.Working, SampledAt = at };
        IReadOnlyDictionary<MetricID, double> speeds(IReadOnlyList<TokenReading> readings, params TokenSource[] restart) =>
            StatusBarContent.Speeds(SessionListModel.Make(readings, at, false), at, restart.ToHashSet());
        IReadOnlyList<StatusBarMetric> speedItems(StatusBarLayout layout = StatusBarLayout.Compact) =>
            StatusBarContent.Metrics(idleCpu, summary([timed, untimed]).AI, layout, [MetricID.CodexSpeed, MetricID.ClaudeSpeed, MetricID.AverageSpeed], true, true,
                speeds([timed, untimed]));
        check($"speed items show each client's own rate with its unit, or a dash: {string.Join(" / ", speedItems().Select(item => $"{item.Value} {item.Spoken}"))}",
              speedItems().Select(item => (item.Id, item.Label, item.Value, item.Spoken)).SequenceEqual(
                  [(MetricID.CodexSpeed, "", "55.6tok/s", "Codex 속도 55.6 토큰/초"), (MetricID.ClaudeSpeed, "", "—", "Claude 속도 측정 없음"),
                   (MetricID.AverageSpeed, "AVG", "55.6tok/s", "평균 속도 55.6 토큰/초")])
              && speeds([timed, untimed], TokenSource.Codex).Count == 0 && speedItems(StatusBarLayout.Minimal).Select(item => item.Id).SequenceEqual([MetricID.Ai])
              && StatusBarContent.SplitRate("55.6tok/s") == ("55.6", "tok/s") && zero.First(metric => metric.Id == MetricID.Cpu).Spoken == "CPU 0%"
              && StatusBarContent.Metrics(idleCpu, new StatusAISummary(), StatusBarLayout.Compact, [MetricID.Network], true, true)[0].Spoken == "NET ↑— ↓—"
              && MetricID.CodexSpeed.SpeedSource == TokenSource.Codex && MetricID.ClaudeSpeed.SpeedSource == TokenSource.Claude && MetricID.Ai.SpeedSource == null
              && MetricID.AverageSpeed.SpeedSource == null && MetricID.CodexSpeed.BarLabel == null && MetricID.AverageSpeed.BarLabel == "AVG"
              && MetricID.ClaudeSpeed.Title == "Claude 속도" && MetricID.AverageSpeed.Title == "평균 속도");
        // Two fresh sessions at 40 and 60 tok/s average to 50 across clients; a 3-minute-old measurement is not current.
        TokenReading rated(TokenSource source, string id, double tokensPerSecond, double age) => new(source, id)
        {
            SessionID = id, Model = "m", Active = true, ActivityState = A.Working, SampledAt = at,
            SpeedMeasurement = new TokenSpeedMeasurement(new TelemetryReading { Provider = source, At = at.AddSeconds(-age) })
                { Model = "m", ServerTokenIntervalMs = 1_000 / tokensPerSecond },
        };
        var averaged = speeds([rated(TokenSource.Codex, "a40", 40, 3), rated(TokenSource.Claude, "a60", 60, 10), rated(TokenSource.Codex, "a-stale", 500, 180)]);
        check($"the average speed is the mean of fresh per-session rates, a stale one excluded: {string.Join(", ", averaged)}",
              Math.Abs(averaged.GetValueOrDefault(MetricID.AverageSpeed) - 50) < 1e-9 && Math.Abs(averaged.GetValueOrDefault(MetricID.CodexSpeed) - 40) < 1e-9
              && Math.Abs(averaged.GetValueOrDefault(MetricID.ClaudeSpeed) - 60) < 1e-9);
        With(AppLanguage.En, () => check("English speed items are spoken per client",
            speedItems().Select(item => item.Spoken).SequenceEqual(["Codex speed 55.6 tokens per second", "Claude speed no measurement",
                "Average speed 55.6 tokens per second"])
            && MetricID.CodexSpeed.Title == "Codex speed"));
        check("marks are 7 pt glyphs, the input disc 8 pt, in the unchanged 11 pt slot",
              StatusBarContent.MarkWidth(A.Tool) == 7 && StatusBarContent.MarkWidth(A.Working) == 7 && StatusBarContent.MarkWidth(A.Stale) == 7
              && StatusBarContent.MarkWidth(A.Input) == 8 && StatusBarContent.MarkWidth(A.Output) == 0 && StatusBarContent.MarkSlot == 11);
        check("no state maps to the record-event glyph; output has no menu-bar mark",
              StateGlyphKind.From(A.Output) == null && StateGlyphKind.From(A.Stale) == StateGlyphKind.Waiting && StateGlyphKind.From(A.Idle) == null
              && StateGlyphKind.From(A.Input) == StateGlyphKind.Input && StateGlyphKind.From(A.Tool) == StateGlyphKind.Tool);
        var maximum = new SystemSnapshot
        {
            CpuPercent = 100, BatteryPresent = true, BatteryPercent = 100, MemoryUsedBytes = ulong.MaxValue, MemoryTotalBytes = ulong.MaxValue,
            DiskUsedBytes = ulong.MaxValue, DiskTotalBytes = ulong.MaxValue, UploadBytesPerSecond = double.MaxValue, DownloadBytesPerSecond = double.MaxValue,
        };
        var busyReadings = Enumerable.Range(0, 12).Select(index => new TokenReading(TokenSource.Codex, $"busy-{index}")
            { SessionID = $"b{index}", Active = true, ActivityState = A.Tool, SampledAt = at }).ToList();
        var widths = new Dictionary<string, double>();
        var stable = true;
        foreach (var items in new[] { MetricID.Standard, everything })
            foreach (var layout in Enum.GetValues<StatusBarLayout>())
            {
                var unknown = StatusBarContent.RequiredWidth(layout, metrics(new SystemSnapshot { BatteryPresent = true }, [], layout, items, hasSample: false, hasTokenSample: false)
                    .Select(metric => metric.Id));
                var full = StatusBarContent.Metrics(maximum, summary(busyReadings).AI, layout, items, true, true,
                    new Dictionary<MetricID, double> { [MetricID.CodexSpeed] = 999.94, [MetricID.ClaudeSpeed] = 99_999, [MetricID.AverageSpeed] = 9_999 });
                var key = $"{layout}{(items == everything ? "/speed" : "")}";
                widths[key] = StatusBarContent.RequiredWidth(layout, full.Select(metric => metric.Id));
                stable = stable && unknown == widths[key];
            }
        check("layout width is stable from unknown to maximum values", stable);
        // edge 4+4, runner 32+2; compact cells 32 / NET 66 / AI 36; inline 52 / 114 / 46; minimal AI 30; each speed item 56 on two
        // lines, 69 on one.
        check($"cell widths match the layout contract: {string.Join(", ", widths)}", widths["Compact"] == 272 && widths["Inline"] == 410 && widths["Minimal"] == 72
              && widths["Compact/speed"] == 440 && widths["Inline/speed"] == 617 && widths["Minimal/speed"] == 72);
        // Without the character (mac StatusBarContentView): no runner slot, the minimal AI cell 41, nothing at all the 28 pt "TC".
        check("without the character the runner slot goes, the minimal cell widens and an empty strip is 28 pt",
              StatusBarContent.RequiredWidth(StatusBarLayout.Minimal, [MetricID.Ai], showRunner: false) == 49
              && StatusBarContent.RequiredWidth(StatusBarLayout.Compact, MetricID.Standard, showRunner: false) == 272 - 34
              && StatusBarContent.RequiredWidth(StatusBarLayout.Inline, [MetricID.Cpu], showRunner: false) == 60
              && StatusBarContent.RequiredWidth(StatusBarLayout.Compact, [], showRunner: false) == 28
              && StatusBarContent.RequiredWidth(StatusBarLayout.Compact, []) == 40);

        // Widget placement (DESIGN §4.7), physical pixels.
        var area = new System.Drawing.Rectangle(0, 0, 1920, 1032);
        check("the widget snaps to work-area edges within the threshold and is kept inside the work area",
              WidgetPlacement.Fit(new(10, 500, 100, 40), area, 12) == new System.Drawing.Point(0, 500)
              && WidgetPlacement.Fit(new(1815, 985, 100, 40), area, 12) == new System.Drawing.Point(1820, 992)
              && WidgetPlacement.Fit(new(30, 500, 100, 40), area, 12) == new System.Drawing.Point(30, 500)
              && WidgetPlacement.Fit(new(-300, 2000, 100, 40), area) == new System.Drawing.Point(0, 992)
              && WidgetPlacement.Fit(new(5000, -50, 100, 40), new(1920, 0, 2560, 1400)) == new System.Drawing.Point(4380, 0)
              && WidgetPlacement.Fit(new(50, 50, 3000, 40), area) == new System.Drawing.Point(0, 50));
        check("the flyout hangs below a widget in the top half and above one in the bottom half",
              WidgetPlacement.FlyoutAnchor(new(1800, 980, 100, 40), area, 6) == (new System.Drawing.Point(1850, 974), false)
              && WidgetPlacement.FlyoutAnchor(new(100, 10, 100, 40), area, 6) == (new System.Drawing.Point(150, 56), true));
        // A resize that isn't a drag keeps the edges nearest the work area: corners, the exact middle, each quadrant, too big.
        System.Drawing.Size bigger = new(200, 80);
        check("a resized widget keeps the edges nearest its work area and stays inside it",
              WidgetPlacement.Resized(new(1808, 980, 100, 40), bigger, area) == new System.Drawing.Point(1708, 940)
              && WidgetPlacement.Resized(new(0, 0, 100, 40), bigger, area) == new System.Drawing.Point(0, 0)
              && WidgetPlacement.Resized(new(910, 496, 100, 40), bigger, area) == new System.Drawing.Point(910, 496)
              && WidgetPlacement.Resized(new(300, 200, 100, 40), bigger, area) == new System.Drawing.Point(300, 200)
              && WidgetPlacement.Resized(new(1500, 100, 100, 40), bigger, area) == new System.Drawing.Point(1400, 100)
              && WidgetPlacement.Resized(new(100, 800, 100, 40), bigger, area) == new System.Drawing.Point(100, 760)
              && WidgetPlacement.Resized(new(1700, 900, 200, 80), new(100, 40), area) == new System.Drawing.Point(1800, 940)
              && WidgetPlacement.Resized(new(2000, 900, 100, 40), bigger, new(1920, 0, 2560, 1400)) == new System.Drawing.Point(2000, 860)
              && WidgetPlacement.Resized(new(1808, 980, 100, 40), new(2500, 1200), area) == new System.Drawing.Point(0, 0));
        // Shown again from the last drag's bounds at another size (changed while hidden, or narrower before the first sample and
        // then back): the same edges stay, nothing drifts; a 0.12.0 spot without a size keeps its top-left.
        System.Drawing.Rectangle dropped = new(1500, 980, 300, 40);
        var early = new System.Drawing.Rectangle(WidgetPlacement.Resized(dropped, new(250, 40), area), new(250, 40));
        check("a widget shown at another size than its last drag keeps that drag's nearest edges, and an old saved spot its top-left",
              WidgetPlacement.Resized(new(1708, 940, 200, 80), new(100, 40), area) == new System.Drawing.Point(1808, 980)
              && early.Location == new System.Drawing.Point(1550, 980) && WidgetPlacement.Resized(early, dropped.Size, area) == dropped.Location
              && WidgetPlacement.Resized(new(1808, 980, 0, 0), bigger, area) == new System.Drawing.Point(1720, 952));
        check("only a full-screen app, D3D full screen or presentation mode hides the widget, never the desktop",
              WidgetPlacement.HidesFor(2, "Chrome_WidgetWin_1") && WidgetPlacement.HidesFor(3, null) && WidgetPlacement.HidesFor(4, "PPTFrameClass")
              && !WidgetPlacement.HidesFor(1, null) && !WidgetPlacement.HidesFor(5, "Notepad") && !WidgetPlacement.HidesFor(6, null)
              && !WidgetPlacement.HidesFor(7, null) && !WidgetPlacement.HidesFor(2, "Progman") && !WidgetPlacement.HidesFor(2, "WorkerW"));
        System.Drawing.Rectangle laptop = new(0, 0, 1920, 1080), monitor = new(1920, 0, 2560, 1440);
        var docked = WidgetPlacement.DisplayKey([monitor, laptop]);
        var folder = Directory.CreateTempSubdirectory("tokencat-widget-checks-");
        try
        {
            var store = new SettingsStore(Path.Combine(folder.FullName, "settings.json"));
            var before = WidgetPlacement.Saved(store, docked);
            WidgetPlacement.Save(store, docked, new(3900, 1300, 300, 40));
            WidgetPlacement.Save(store, WidgetPlacement.DisplayKey([laptop]), new(-5, 12, 120, 40));
            store.Set("unrelatedKey", true);
            var kept = WidgetPlacement.Saved(store, docked) == new System.Drawing.Rectangle(3900, 1300, 300, 40)
                       && WidgetPlacement.Saved(store, WidgetPlacement.DisplayKey([laptop])) == new System.Drawing.Rectangle(-5, 12, 120, 40)
                       && WidgetPlacement.Saved(store, WidgetPlacement.DisplayKey([monitor])) == null;
            store.Set(WidgetPlacement.PositionsKey, new Dictionary<string, int[]> { [docked] = [3900, 1300], ["flat"] = [1, 2, 0, 40] });
            var old = WidgetPlacement.Saved(store, docked) == new System.Drawing.Rectangle(3900, 1300, 0, 0) && WidgetPlacement.Saved(store, "flat") == null;
            store.Set(WidgetPlacement.PositionsKey, "garbage");
            check("the widget's last drag is remembered per monitor set, a 0.12.0 top-left still reads, and an unreadable value is ignored",
                  before == null && kept && old && docked == "0,0,1920x1080;1920,0,2560x1440" && WidgetPlacement.Saved(store, docked) == null);
        }
        finally { folder.Delete(true); }
        return c.Done();
    }
}
