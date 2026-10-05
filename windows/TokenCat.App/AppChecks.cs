using System.Windows;
using System.Windows.Media;
using static TokenCat.Lang;

namespace TokenCat;

/// The App half of `--self-test` (DESIGN §11 WP5), run before the Core suites on Windows: the embedded artwork, HICON
/// hygiene, the theme tokens (runDesignTokenChecks) and the Swift check cases about App-side types (PreferenceChecks'
/// legend and telemetry rows, SessionPresentationChecks' first-run outcomes and fixture IDs). Descriptions are the Swift
/// ones where the case is ported unchanged.
static class AppChecks
{
    public static List<string> Run()
    {
        var c = new Check("App");
        void check(bool valid, string description) => c.That(valid, description);
        void guarded(string name, Action body)
        {
            try { body(); }
            catch (Exception error) { check(false, $"{name} threw {error.GetType().Name}: {error.Message}"); }
        }

        guarded("artwork", () => Artwork(check));
        guarded("icons", () => Icons(check));
        guarded("tokens", () => Tokens(check));
        guarded("glyphs", () => Glyphs(check));
        guarded("settings rows", () => SettingsRows(check));
        guarded("fixtures", () => FixtureChecks(check));
        return c.Done();
    }

    /// Every embedded PNG decodes with the manifest's dimensions; pixel art keeps alpha 0 or 255.
    static void Artwork(Action<bool, string> check)
    {
        var manifest = Json.Parse(Sprites.Resource("runner-v2.json"));
        var cell = manifest?.Field("cell");
        int width = (int)(cell?.Field("width")?.Number ?? 0), height = (int)(cell?.Field("height")?.Number ?? 0);
        var poses = manifest?.Field("poses")?.EnumerateArray().ToList() ?? [];
        var columns = poses.Select(pose => (int)(pose.Field("frames")?.Number ?? 0)).DefaultIfEmpty(0).Max();
        check(width == Sprites.CellWidth && height == Sprites.CellHeight && poses.Count == Enum.GetValues<RunnerPose>().Length,
            "runner-v2.json: the frame size must be 30×18 with one row per pose");
        var wrong = new List<string>();
        var soft = new List<string>();
        void Expect(string name, int w, int h)
        {
            var sheet = Sprites.Sheet(name);
            if (sheet.Width != w || sheet.Height != h) wrong.Add($"{name} {sheet.Width}×{sheet.Height}");
            for (var i = 3; i < sheet.Bgra.Length; i += 4)
                if (sheet.Bgra[i] is not (0 or 255)) { soft.Add(name); break; }
        }
        foreach (var character in Enum.GetValues<RunnerCharacter>())
            foreach (var scale in new[] { 1, 2 }) Expect(Sprites.SheetName(character, scale), width * columns * scale, height * poses.Count * scale);
        foreach (var head in Enum.GetValues<RunnerHead>())
            foreach (var scale in new[] { 1, 2 }) Expect(Sprites.HeadName(head, scale), 12 * scale, 11 * scale);
        var glyphs = manifest?.Field("glyphs")?.EnumerateObject().Select(glyph => glyph.Value).ToList() ?? [];
        int fxWidth = glyphs.Select(g => (int)((g.Field("x")?.Number ?? 0) + (g.Field("width")?.Number ?? 0))).DefaultIfEmpty(0).Max();
        int fxHeight = glyphs.Select(g => (int)((g.Field("y")?.Number ?? 0) + (g.Field("height")?.Number ?? 0))).DefaultIfEmpty(0).Max();
        foreach (var scale in new[] { 1, 2 }) Expect(Sprites.FxName(scale), fxWidth * scale, fxHeight * scale);
        check(wrong.Count == 0, "embedded artwork has the manifest's dimensions: " + string.Join(", ", wrong));
        check(soft.Count == 0, "embedded artwork has alpha 0 or 255 only: " + string.Join(", ", soft));
    }

    /// 2,000 icon swaps leave the GDI and USER object counts flat (±4); tray frames have the icon's size for every pose.
    static void Icons(Action<bool, string> check)
    {
        const int size = 32;
        var pixels = new byte[size * size * 4];
        for (var i = 0; i < pixels.Length; i += 4) { pixels[i] = (byte)i; pixels[i + 3] = 255; }
        System.Drawing.Icon? last = null;
        // Warm up GDI+ and the first HICON before counting.
        TrayIcon.Release(Native.IconFromBgra(pixels, size));
        var before = Native.GuiResources();
        for (var i = 0; i < 2_000; i++)
        {
            var next = Native.IconFromBgra(pixels, size);
            TrayIcon.Release(last);
            last = next;
        }
        TrayIcon.Release(last);
        var after = Native.GuiResources();
        check(Math.Abs((int)after.Gdi - (int)before.Gdi) <= 4 && Math.Abs((int)after.User - (int)before.User) <= 4,
            $"2,000 tray icon swaps leak no handles (GDI {before.Gdi} → {after.Gdi}, USER {before.User} → {after.User})");

        var wrongSize = new List<string>();
        foreach (var icon in new[] { 16, 20, 24, 28, 32, 40 })
            foreach (var pose in Enum.GetValues<RunnerPose>())
                foreach (var character in Enum.GetValues<RunnerCharacter>())
                {
                    var frame = TrayIcon.Pixels(icon, character, pose, 0, pose == RunnerPose.Sleep ? 2 : null, StateDot.Attention, false);
                    if (frame.Length != icon * icon * 4) wrongSize.Add($"{character} {pose}@{icon}");
                }
        check(wrongSize.Count == 0, "tray frames are icon × icon BGRA for every pose and character: " + string.Join(", ", wrongSize));
        var artErrors = RunnerArtwork.ResourceErrors(RunnerManifest.Parse(Sprites.Resource("runner-v2.json")), Sprites.Load);
        check(artErrors.Count == 0, "embedded artwork passes RunnerArtwork's sheet, fx and head checks: " + string.Join(", ", artErrors));
        check(!TrayIcon.Pixels(32, RunnerCharacter.Cat, RunnerPose.Sleep, 0, 2, StateDot.None, false)
                .SequenceEqual(TrayIcon.Pixels(32, RunnerCharacter.Cat, RunnerPose.Sleep, 0, null, StateDot.None, false)),
            "the body-mode tray icon draws the sleep z");
        var tooltip = TrayIcon.Truncate("TokenCat\n" + new string('가', 80) + "\n" + new string('b', 60), 127);
        check(tooltip == "TokenCat\n" + new string('가', 80) && TrayIcon.Truncate(new string('x', 200), 127).Length == 127,
            "the tray tooltip keeps whole lines under 128 characters");
    }

    /// runDesignTokenChecks' colour cases, plus the contrast pairs the light values were chosen for.
    static void Tokens(Action<bool, string> check)
    {
        var saved = Theme.Dark;
        try
        {
            Theme.Dark = false;
            var light = (Activity: Theme.Activity, Warning: Theme.Warning, Neutral: Theme.Neutral, Secondary: Theme.Secondary, Label: Theme.Label,
                Container: Theme.ContainerOpaque, Selection: Theme.Selection, Accent: Theme.Accent);
            Theme.Dark = true;
            var dark = (Activity: Theme.Activity, Warning: Theme.Warning, Neutral: Theme.Neutral, Secondary: Theme.Secondary, Label: Theme.Label,
                Container: Theme.ContainerOpaque);
            check(light.Activity == Color.FromRgb(0x24, 0x8A, 0x3D) && dark.Activity == Color.FromRgb(0x30, 0xD1, 0x58), "activity green per appearance");
            check(light.Warning == Color.FromRgb(0xC8, 0x64, 0) && dark.Warning == Color.FromRgb(0xFF, 0x9F, 0x0A)
                && Theme.Contrast(Theme.Over(light.Warning, light.Container), light.Container) >= 3,
                "warning: a darker orange in light (≥ 3:1 on the light container), systemOrange in dark");
            check(Math.Abs(light.Neutral.A - light.Label.A * 0.5) <= 1 && Math.Abs(dark.Neutral.A - dark.Label.A * 0.5) <= 1
                && dark.Neutral.R == dark.Label.R && light.Neutral.R == light.Label.R,
                "neutral is the label colour at 0.50 of its opacity, like Color.primary.opacity");
            check(Math.Abs(light.Secondary.A - light.Label.A * 0.66) <= 1 && dark.Secondary == Color.FromArgb(140, 255, 255, 255),
                "secondary text: light primary 0.66, dark system secondary");
            check(Math.Abs(light.Selection.A - 255 * 0.16) <= 1 && light.Selection.R == light.Accent.R, "selection is accent 0.16");
            double On((Color Color, Color Container) pair) => Theme.Contrast(Theme.Over(pair.Color, pair.Container), pair.Container);
            check(On((light.Secondary, light.Container)) >= 4.5 && On((dark.Secondary, dark.Container)) >= 4.5,
                "secondary text is at least 4.5:1 on its container in both themes");
            check(On((light.Neutral, light.Container)) >= 3 && On((dark.Neutral, dark.Container)) >= 3
                && On((light.Activity, light.Container)) >= 3 && On((dark.Activity, dark.Container)) >= 3 && On((dark.Warning, dark.Container)) >= 3,
                "meters, the activity green and the warning orange are at least 3:1 on their container");
        }
        finally { Theme.Dark = saved; }
    }

    /// runDesignTokenChecks' shape cases on the WPF geometry.
    static void Glyphs(Action<bool, string> check)
    {
        var outside = new List<string>();
        foreach (var side in new[] { 7.0, 8, 10 })
        {
            var rect = new Rect(3, 5, side, side);
            foreach (var kind in Enum.GetValues<StateGlyphKind>().Where(kind => kind != StateGlyphKind.Retry))
            {
                var shape = GlyphView.Shape(kind, rect, out var stroke);
                var reach = stroke is null ? 0 : stroke.Thickness / 2;
                var bounds = shape.Bounds;
                bounds.Inflate(reach, reach);
                var box = rect;
                box.Inflate(0.01, 0.01);
                if (shape.IsEmpty() || !box.Contains(bounds)) outside.Add($"{kind}@{side}");
            }
        }
        check(outside.Count == 0, "every glyph but retry is a non-empty shape inside its box: " + string.Join(", ", outside));
        var unit = new Rect(0, 0, 8, 8);
        check(GlyphView.Shape(StateGlyphKind.Retry, unit, out _).IsEmpty(), "retry is an empty path (callers draw arrow.clockwise)");
        var stroked = Enum.GetValues<StateGlyphKind>().Where(kind => { GlyphView.Shape(kind, unit, out var pen); return pen is not null; }).ToList();
        GlyphView.Shape(StateGlyphKind.Unfinished, unit, out var dashed);
        GlyphView.Shape(StateGlyphKind.Working, unit, out var solid);
        var dashes = dashed!.DashStyle.Dashes.Select(dash => dash * dashed.Thickness).ToList();
        check(stroked.SequenceEqual([StateGlyphKind.Working, StateGlyphKind.Unfinished]) && solid!.Thickness == 1.5 && solid.DashStyle.Dashes.Count == 0
            && dashes.Count == 2 && Math.Abs(dashes[0] - 2) < 1e-9 && Math.Abs(dashes[1] - 1.5) < 1e-9,
            "rings are 1.5 pt strokes; the unfinished ring is dashed 2 / 1.5");
        // WPF's default hit tolerance (0.25) is wider than the 0.5 pt gap between the bar and the ring.
        bool Filled(StateGlyphKind kind, double x, double y) =>
            GlyphView.Shape(kind, unit, out _).FillContains(new Point(x, y), 0.001, ToleranceType.Absolute);
        check(Filled(StateGlyphKind.Waiting, 2.5, 4) && !Filled(StateGlyphKind.Waiting, 5.5, 4) && Filled(StateGlyphKind.Waiting, 7.6, 4) && Filled(StateGlyphKind.Waiting, 4, 0.4),
            "log wait is a ring with its left half filled");
        check(Filled(StateGlyphKind.Interrupted, 4, 4) && !Filled(StateGlyphKind.Interrupted, 4, 2.2) && Filled(StateGlyphKind.Interrupted, 4, 0.4)
            && !Filled(StateGlyphKind.Interrupted, 1.85, 4), "interrupted is a ring with a clear centred bar");
        check(Filled(StateGlyphKind.RecordEvent, 4, 4) && Filled(StateGlyphKind.Tool, 4, 0.8) && Filled(StateGlyphKind.Input, 4, 4)
            && Math.Abs(GlyphView.Shape(StateGlyphKind.Idle, unit, out _).Bounds.Width - 6) < 0.01, "filled shapes; idle is a 6 pt dot in an 8 pt box");
        var mark = GlyphView.InputMark(unit).Bounds;
        check(!mark.IsEmpty && unit.Contains(mark) && mark.Width < 6 && Math.Abs(mark.X + mark.Width / 2 - 4) < 0.01 && Math.Abs(mark.Y + mark.Height / 2 - 4) < 0.01,
            "the input mark is centred inside the disc");
        SessionDisplayState[] rows = [SessionDisplayState.Input, SessionDisplayState.Retrying, SessionDisplayState.Tool, SessionDisplayState.Working,
            SessionDisplayState.Waiting, SessionDisplayState.Complete, SessionDisplayState.Interrupted, SessionDisplayState.Unfinished, SessionDisplayState.Idle];
        check(rows.All(state => GlyphView.For(state) is not null) && GlyphView.For(SessionDisplayState.Measurement) is null
            && !rows.Any(state => GlyphView.For(state) == StateGlyphKind.RecordEvent), "no state maps to the record-event glyph");
    }

    /// PreferenceChecks' Settings cases (T-1, T-3, T-4), with the Windows pages and startup captions.
    static void SettingsRows(Action<bool, string> check)
    {
        check(SettingsPageTitles() == "일반 · 캐릭터 · 실측 · 정보", "Settings pages are not 일반 · 캐릭터 · 실측 · 정보");
        check(SettingsView.LegendEntries(RunnerMotion.Activity).Select(entry => entry.Pose).SequenceEqual([RunnerPose.Walk, RunnerPose.Run, RunnerPose.Alert, RunnerPose.Sit, RunnerPose.Sleep])
            && SettingsView.LegendEntries(RunnerMotion.Cpu).Select(entry => entry.Caption).SequenceEqual(["4% 미만", "20%까지", "20% 넘음"])
            && SettingsView.LegendEntries(RunnerMotion.Measured).Select(entry => entry.Caption).SequenceEqual(["실측 없음", "40 tok/s 미만", "40 이상"])
            && SettingsView.LegendEntries(RunnerMotion.Still).Count == 0,
            "The cat legend does not match the motion source");
        check(SettingsView.CollectorStatus(TelemetryCollectorState.Receiving) == (SettingsView.StatusRow.Receiving, "수신 중 · 127.0.0.1:16493")
            && SettingsView.CollectorStatus(TelemetryCollectorState.Waiting).Text == "수신 대기 · 127.0.0.1:16493"
            && SettingsView.CollectorStatus(TelemetryCollectorState.BusyOtherApp) == (SettingsView.StatusRow.Problem, "꺼짐 · 다른 앱이 16493 포트 사용 중")
            && SettingsView.CollectorStatus(TelemetryCollectorState.Starting) == (SettingsView.StatusRow.Starting, "준비 중"),
            "Collector status rows do not match the T-3 table");
        var at = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        (SettingsView.StatusRow Row, string Text, string? Detail) Client(bool restart, bool expired, DateTimeOffset? received, DateTimeOffset? batch) =>
            SettingsView.ClientStatus(restart, expired, received, batch, at);
        check(Client(true, true, at, at).Row == SettingsView.StatusRow.Info && Client(false, true, at, at).Text == "이 버전에서 실측을 받지 못했습니다"
            && Client(false, false, at.AddSeconds(-30), at).Text == "최근 수신 1분 이내"
            && Client(false, false, at.AddSeconds(-720), null).Text == "최근 수신 12분 전"
            && Client(false, false, null, at).Text == "기록 수신 중 · 속도 형식 없음" && Client(false, false, null, at).Detail is not null
            && Client(false, false, null, null).Text == "이번 실행에서 받은 실측 없음",
            "Client telemetry rows are not checked restart → 24 h → received → batch only → none");
        (SettingsView.StatusRow Row, string Text, string? Detail) Limits(TelemetrySetupNote[] notes, bool? bridged, DateTimeOffset? received) =>
            SettingsView.ClaudeLimitsStatus(notes, bridged, received, false, at);
        check(Limits([TelemetrySetupNote.OriginalUnknown], true, at) == (SettingsView.StatusRow.Problem, "상태 표시줄이 비어 보일 수 있음", "settings.json의 statusLine을 직접 고쳐 주세요")
            && Limits([TelemetrySetupNote.StatusLineSkipped], false, at).Text == "연결 안 함 · statusLine 형식이 달라 건너뜀"
            && Limits([], true, at.AddSeconds(-180)) == (SettingsView.StatusRow.Received, "최근 수신 3분 전", null)
            && Limits([TelemetrySetupNote.OriginalRecreated], true, at.AddSeconds(-50)) == (SettingsView.StatusRow.Received, "최근 수신 1분 이내", "원래 상태 표시줄 명령을 백업 기록에서 다시 만들었습니다")
            && Limits([], true, null) == (SettingsView.StatusRow.Waiting, "아직 받지 못함 · Claude Code를 새로 실행하면 표시", null)
            && Limits([], false, null).Text == "연결 안 함" && Limits([], null, null).Row == SettingsView.StatusRow.Info
            && SettingsView.ClaudeLimitsStatus([], false, at.AddSeconds(-720), true, at) == (SettingsView.StatusRow.Received, "Claude 데스크톱 앱 기록 · 12분 전", null),
            "Claude limit row is not checked empty status line → skipped → received → waiting → none");
        check(LoginItem.Describe(LoginItem.State.NotRegistered) == "꺼짐 · 켤 때만 시작 프로그램에 등록합니다", "Korean startup app captions changed");
        check(Ui.KeepWords("권장합니다 Claude 데스크톱") == "권\u2060장\u2060합\u2060니\u2060다 Claude 데\u2060스\u2060크\u2060톱",
            "Korean captions can still break inside a word");
        With(AppLanguage.En, () =>
        {
            check(SettingsPageTitles() == "General · Character · Telemetry · About"
                && SettingsView.CollectorStatus(TelemetryCollectorState.BusyOtherApp).Text == "Off · another app is using port 16493"
                && Client(false, false, at.AddSeconds(-30), at).Text == "Last received <1m ago"
                && Limits([], true, at.AddSeconds(-180)).Text == "Last received 3m ago"
                && SettingsView.ClaudeLimitsStatus([], false, at.AddSeconds(-720), true, at).Text == "Claude desktop app · recorded 12m ago"
                && SettingsView.LegendEntries(RunnerMotion.Measured).Select(entry => entry.Caption).SequenceEqual(["Not measured", "Under 40 tok/s", "40 or more"])
                && SettingsView.LegendEntries(RunnerMotion.Activity)[^1].Name == "Sleep"
                && LoginItem.Describe(LoginItem.State.DisabledInTaskManager) == "Disabled in Task Manager › Startup apps",
                "English settings tabs, telemetry rows, cat legend or motion titles are wrong");
        });
    }

    static string SettingsPageTitles() => string.Join(" · ", Enum.GetValues<SettingsPage>().Select(SettingsWindow.Titles));

    /// Fixture PNGs carry only visibly fake identifiers, and every fixture lays out (ko and en).
    static void FixtureChecks(Action<bool, string> check)
    {
        var readings = Fixtures.All().SelectMany(fixture => fixture.Tokens).ToList();
        static bool Synthetic(string agent)
        {
            var digits = agent.Skip(1).Take(7).ToList();
            return agent.StartsWith('a') && digits.Count == 7 && digits.All(digit => digit == digits[0] && char.IsDigit(digit));
        }
        check(readings.Count > 0 && readings.All(reading => reading.SessionID?.StartsWith(Fixtures.SessionPrefix, StringComparison.Ordinal) ?? true)
            && readings.Where(reading => reading.Source == TokenSource.Claude && reading.IsSubagent).All(reading => reading.AgentID is { } id && Synthetic(id)),
            "fixture IDs are synthetic");
        var broken = new List<string>();
        foreach (var language in new[] { AppLanguage.Ko, AppLanguage.En })
            foreach (var fixture in Fixtures.All())
                With(language, () =>
                {
                    try
                    {
                        var image = Snapshot.Render(() =>
                        {
                            var view = new Dashboard(DashboardActions.None, snapshot: true, selection: fixture.Selection, detail: fixture.Detail, expanded: fixture.Expanded);
                            view.Show(Fixtures.Input(fixture));
                            return view;
                        }, dark: true);
                        if (image.PixelWidth != Dashboard.PanelWidth * 2 || image.PixelHeight < 400) broken.Add($"{fixture.Name}/{language.Code} {image.PixelWidth}×{image.PixelHeight}");
                    }
                    catch (Exception error) { broken.Add($"{fixture.Name}/{language.Code}: {error.GetType().Name} {error.Message}"); }
                });
        check(broken.Count == 0, "every fixture renders a 420 DIP dashboard: " + string.Join("; ", broken));
    }
}
