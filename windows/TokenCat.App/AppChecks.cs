using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
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
        guarded("automation", () => Automation(check));
        guarded("widget", () => WidgetChecks(check));
        guarded("widget settings", () => WidgetSettings(check));
        guarded("detach", () => Detach(check)); // last: its windows must not move the handle counts above
        return c.Done();
    }

    static IEnumerable<DependencyObject> Tree(DependencyObject root) =>
        LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>().SelectMany(child => Tree(child).Prepend(child));

    /// Dragging the flyout out (§4.2), without a mouse: the header and the System area's edge start a drag, the session list and
    /// the Task Manager area don't; a press released in place or within the drag distance stays a click, a longer drag along one
    /// axis hands over the pointer and the grabbed offset, and the window opens with that point under the pointer (one grabbed
    /// lower than the window is tall still lands inside it); closed, it comes back with the same spot and height. Real windows,
    /// shown without activating, and a throwaway store.
    static void Detach(Action<bool, string> check)
    {
        static void Settle() => System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        var path = Path.Combine(Path.GetTempPath(), $"tokencat-appchecks-{Guid.NewGuid():N}.json");
        var store = new SettingsStore(path);
        var flyout = new Flyout(DashboardActions.None) { ShowActivated = false };
        DashboardWindow? window = null;
        try
        {
            flyout.Show();
            Settle();
            var nodes = Tree(flyout).ToList();
            var system = nodes.OfType<SystemArea>().Single();
            check(flyout.Draggable(nodes.OfType<Header>().Single()) && flyout.Draggable(system) && !flyout.Draggable(nodes.OfType<SessionList>().Single())
                  && !flyout.Draggable(Tree(system).OfType<FrameworkElement>().First(element => element.Cursor == System.Windows.Input.Cursors.Hand)),
                "the flyout's header and empty space start a drag, the session list and the Task Manager area keep their clicks");
            flyout.Hide();
            (System.Drawing.Point Cursor, System.Drawing.Point Grab)? dragged = null;
            flyout.DraggedOut += (cursor, grab) => dragged = (cursor, grab);
            var origin = Native.Bounds(flyout).Location;
            var press = new System.Drawing.Point(origin.X + 40, origin.Y + 12);
            flyout.Press(press);
            flyout.Release();
            flyout.Press(press);
            flyout.Drag(press with { X = press.X + 1 });
            flyout.Release();
            flyout.Drag(press with { X = press.X + 200 });
            var clicks = dragged is null;
            var pointer = press with { X = press.X + 60 };
            flyout.Press(press);
            flyout.Drag(pointer);
            check(clicks && dragged == (pointer, new System.Drawing.Point(40, 12)),
                "a flyout press released in place or within the drag distance stays a click, and a longer drag detaches with the grabbed offset");

            window = new DashboardWindow(DashboardActions.None, store) { ShowActivated = false };
            window.Follow(pointer, new(40, 12));
            window.Show();
            Settle();
            var client = window.PointToScreen(new Point());
            check(Math.Abs(client.X + 40 - pointer.X) <= 1 && Math.Abs(client.Y + 12 - pointer.Y) <= 1 && Native.Bounds(window).Contains(pointer),
                "the detached window opens with the grabbed point under the pointer");
            window.Follow(pointer, new(40, 5000));
            var low = Native.Bounds(window).Contains(pointer);
            window.Follow(pointer, new(40, 12));
            check(low, "a point grabbed lower than the detached window is tall still lands inside it");
            window.Height += 40;
            Settle();
            var closed = Native.Bounds(window);
            window.Close();
            window = new DashboardWindow(DashboardActions.None, store) { ShowActivated = false };
            window.Show();
            Settle();
            var back = Native.Bounds(window);
            var expected = DashboardBounds.Restore(closed, System.Windows.Forms.Screen.AllScreens.Select(screen => screen.WorkingArea));
            check(expected is { } spot && Math.Abs(back.X - spot.X) <= 1 && Math.Abs(back.Y - spot.Y) <= 1 && Math.Abs(back.Height - spot.Height) <= 1,
                $"the dashboard window comes back with its last position and height ({closed} → {back})");
        }
        finally
        {
            window?.Close();
            flyout.Close();
            File.Delete(path);
        }
    }

    /// The widget view (§4.7): its width follows the layout, never the values, and is the Core contract at its scale; the
    /// worst-case numbers draw at natural size; offscreen frames leave the GDI and USER counts flat.
    static void WidgetChecks(Action<bool, string> check)
    {
        var saved = Theme.Dark;
        try
        {
            var maximum = new SystemSnapshot
            {
                CpuPercent = 100, BatteryPresent = true, BatteryPercent = 100, MemoryUsedBytes = 9, MemoryTotalBytes = 9, DiskUsedBytes = 9,
                DiskTotalBytes = 9, UploadBytesPerSecond = 999e6, DownloadBytesPerSecond = 125e6,
            };
            var busy = new StatusAISummary { Running = 99, Input = 99, Phase = TokenActivityState.Input };
            var items = Enum.GetValues<MetricID>();
            // The speed items' worst realistic rate, "9999.9 tok/s" (a sub-millisecond time between tokens).
            var speeds = new Dictionary<TokenSource, double> { [TokenSource.Codex] = 9999.94, [TokenSource.Claude] = 9999.94 };
            List<string> unstable = [], shrunk = [];
            foreach (var layout in Enum.GetValues<StatusBarLayout>())
            {
                var view = new WidgetView();
                double Width(IReadOnlyList<StatusBarMetric> metrics)
                {
                    view.Update(metrics, layout);
                    view.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                    return view.DesiredSize.Width;
                }
                var unknown = Width(StatusBarContent.Metrics(new SystemSnapshot { BatteryPresent = true }, new StatusAISummary(), layout, items, false, false));
                var full = StatusBarContent.Metrics(maximum, busy, layout, items, true, true, speeds);
                var width = Width(full);
                var contract = (StatusBarContent.RequiredWidth(layout, full.Select(metric => metric.Id)) + 2 * WidgetView.Inset) * view.Scale;
                if (unknown != width || Math.Abs(width - contract) > 0.01) unstable.Add($"{layout} {unknown}/{width}/{contract}");
                Snapshot.Render(() => view, dark: false);
                shrunk.AddRange(view.Drawn.Where(text => text.Fit < 1 && text.Text.Any(char.IsDigit)).Select(text => $"{layout} '{text.Text}' {text.Fit:F2}"));
            }
            check(unstable.Count == 0, "the widget's width follows its layout, not its values: " + string.Join(", ", unstable));
            check(shrunk.Count == 0, "worst-case widget values fit their cells without shrinking: " + string.Join(", ", shrunk));
            // Narrator reads the items as one named text element; a speed item by its client, rate and unit.
            var spoken = new WidgetView();
            spoken.Update(StatusBarContent.Metrics(maximum, busy, StatusBarLayout.Compact, [MetricID.Cpu, MetricID.CodexSpeed, MetricID.ClaudeSpeed], true, true,
                new Dictionary<TokenSource, double> { [TokenSource.Codex] = 55.56 }), StatusBarLayout.Compact);
            check(UIElementAutomationPeer.CreatePeerForElement(spoken) is { } widgetPeer && widgetPeer.GetAutomationControlType() == AutomationControlType.Text
                  && widgetPeer.GetName() == "CPU 100%, Codex 속도 55.6 토큰/초, Claude 속도 측정 없음",
                  "Narrator reads the widget's items, the speed items by client and rate");
            // Speed items on one line without the character (mac "speed glyphs and dashes are secondary"): the glyph (12–22 pt) and "—"
            // in the secondary tone, digits in the label tone. The light label is black, so on the clear backdrop a pixel's alpha is its
            // tone: secondary tops out at 184 (0.72), label at 217 (0.85).
            var toned = StatusBarContent.Metrics(maximum, busy, StatusBarLayout.Inline, [MetricID.CodexSpeed, MetricID.ClaudeSpeed], true, true,
                new Dictionary<TokenSource, double> { [TokenSource.Codex] = 55.56 });
            byte Darkest(StatusBarMetric metric, double from, double to)
            {
                var toneView = new WidgetView();
                toneView.Update([metric], StatusBarLayout.Inline, nextRunner: false);
                var image = Snapshot.Render(() => toneView, dark: false);
                var pixels = new byte[image.PixelWidth * image.PixelHeight * 4];
                image.CopyPixels(pixels, image.PixelWidth * 4, 0);
                int first = (int)(from * toneView.Scale * 2), last = Math.Min(image.PixelWidth, (int)Math.Ceiling(to * toneView.Scale * 2));
                byte darkest = 0;
                for (var y = 0; y < image.PixelHeight; y++)
                    for (var x = first; x < last; x++) darkest = Math.Max(darkest, pixels[(y * image.PixelWidth + x) * 4 + 3]);
                return darkest;
            }
            byte[] tones = [Darkest(toned[0], 12, 22), Darkest(toned[1], 12, 22), Darkest(toned[1], 25, 45), Darkest(toned[0], 25, 45)];
            check(tones[0] is >= 170 and <= 187 && tones[1] is >= 170 and <= 187 && tones[2] is > 60 and <= 187 && tones[3] > 190,
                  $"speed glyphs and dashes are secondary, digits label-toned (alpha {string.Join(", ", tones)})");

            // Sizes: the width is the contract × the size, with and without the character; whole pixels per point keep the runner
            // nearest-neighbour at exactly that size, a fractional size scales the next whole size up down smoothly.
            List<string> scaled = [], resampled = [];
            foreach (var runner in new[] { true, false })
                foreach (var layout in Enum.GetValues<StatusBarLayout>())
                {
                    var metrics = StatusBarContent.Metrics(maximum, busy, layout, items, true, true);
                    var points = StatusBarContent.RequiredWidth(layout, metrics.Select(metric => metric.Id), runner) + 2 * WidgetView.Inset;
                    double? natural = null;
                    foreach (var percent in new[] { 100, 150, 200, 300 })
                    {
                        var view = new WidgetView();
                        view.Update(metrics, layout, runner, percent);
                        view.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                        natural ??= view.DesiredSize.Width;
                        var dpi = VisualTreeHelper.GetDpi(view).DpiScaleX;
                        var expected = points * WidgetView.DevicePixels(dpi, percent) / dpi;
                        if (Math.Abs(view.DesiredSize.Width - expected) > 0.01 || Math.Abs(view.DesiredSize.Width - natural.Value * percent / 100) > 0.01)
                            scaled.Add($"{layout}{(runner ? "" : " without the character")} {percent}% {view.DesiredSize.Width:F2}/{expected:F2}");
                    }
                }
            foreach (var percent in Preferences.WidgetScales)
            {
                var view = new WidgetView();
                view.Update(StatusBarContent.Metrics(maximum, busy, StatusBarLayout.Minimal, items, true, true), StatusBarLayout.Minimal, true, percent);
                Snapshot.Render(() => view, dark: false);
                var whole = view.PixelsPerPoint == Math.Floor(view.PixelsPerPoint);
                if (view.SpriteScaling != (whole ? BitmapScalingMode.NearestNeighbor : BitmapScalingMode.HighQuality)
                    || view.SpritePixels != RunnerManifest.CellWidth * (int)Math.Ceiling(view.PixelsPerPoint))
                    resampled.Add($"{percent}% at {view.PixelsPerPoint} px/pt: {view.SpriteScaling} {view.SpritePixels} px");
            }
            check(scaled.Count == 0, "the widget's width is its contract × its size, with and without the character: " + string.Join(", ", scaled));
            check(resampled.Count == 0, "whole pixels per point draw the runner nearest-neighbour at that size, and fractional sizes resample the next size up smoothly: "
                + string.Join(", ", resampled));

            // "위젯 크기" (tray and widget menu, Settings) and Ctrl + wheel over the widget, through their handlers.
            var store = Path.Combine(Path.GetTempPath(), $"tokencat-appchecks-{Guid.NewGuid():N}.json");
            try
            {
                var preferences = new Preferences(new SettingsStore(store));
                using var strip = new System.Windows.Forms.ContextMenuStrip();
                Menus.Fill(strip, menu => Shell.SizeMenu(menu, preferences));
                var sizes = strip.Items.OfType<System.Windows.Forms.ToolStripMenuItem>().ToList();
                var listed = sizes.Select(item => item.Text).SequenceEqual(["100%", "125%", "150%", "175%", "200%", "250%", "300%"])
                             && sizes.Count(item => item.Checked) == 1 && sizes[0].Checked;
                sizes[2].PerformClick();
                var picked = preferences.WidgetScale == 150;
                var widget = new Widget();
                widget.Zoomed += notches => Shell.Zoom(preferences, notches);
                var steps = new List<int>();
                foreach (var (delta, control) in new[] { (120, true), (60, true), (60, true), (-120, true), (120, false), (-360, true), (-120, true), (1_200, true) })
                {
                    widget.Wheel(delta, control);
                    steps.Add(preferences.WidgetScale);
                }
                check(listed && picked && steps.SequenceEqual([175, 175, 200, 175, 175, 100, 100, 300]) && !widget.Wheel(120, false),
                      "the size menu lists every size with the current one checked, and Ctrl + wheel steps one size per notch within 100–300 %: "
                      + string.Join(", ", steps));
            }
            finally { File.Delete(store); }

            var frames = new WidgetView();
            frames.Update(StatusBarContent.Metrics(maximum, busy, StatusBarLayout.Compact, items, true, true), StatusBarLayout.Compact);
            Snapshot.Render(() => frames, dark: true);
            // The 300 RenderTargetBitmaps are the harness's, not the widget's: let them finalize before counting.
            static (uint Gdi, uint User) Settled()
            {
                GC.Collect();
                GC.WaitForPendingFinalizers();
                GC.Collect();
                System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                return Native.GuiResources();
            }
            var before = Settled();
            for (var i = 0; i < 300; i++)
            {
                frames.UpdateRunner(RunnerCharacter.Cat, RunnerPose.Walk, i % 4, null);
                Snapshot.Render(() => frames, dark: i % 2 == 0);
            }
            var after = Settled();
            check(Math.Abs((int)after.Gdi - (int)before.Gdi) <= 4 && Math.Abs((int)after.User - (int)before.User) <= 4,
                $"300 widget frames leak no handles (GDI {before.Gdi} → {after.Gdi}, USER {before.User} → {after.User})");
        }
        finally { Theme.Dark = saved; }
    }

    /// Settings › 위젯 and the pages it changed (§4.4): they build in ko and en with the widget's controls inside the page; the
    /// item rows are check boxes named "title · bar label" in the stored order with the mac's locked and no-battery cases;
    /// Alt+↑/↓ moves the focused item; the character toggle moved to Character.
    static void WidgetSettings(Action<bool, string> check)
    {
        static IEnumerable<DependencyObject> Descendants(DependencyObject root) =>
            LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>().SelectMany(child => Descendants(child).Prepend(child));
        static AutomationPeer? Peer(UIElement element) => UIElementAutomationPeer.CreatePeerForElement(element);
        static ToggleState? Toggled(UIElement element) => (Peer(element)?.GetPattern(PatternInterface.Toggle) as IToggleProvider)?.ToggleState;
        static string? Named(IEnumerable<DependencyObject> tree, string name) =>
            tree.OfType<System.Windows.Controls.Primitives.ToggleButton>().FirstOrDefault(toggle => AutomationProperties.GetName(toggle) == name) is { } found
                ? Toggled(found)?.ToString() : null;
        var saved = Theme.Dark;
        var store = Path.Combine(Path.GetTempPath(), $"tokencat-appchecks-{Guid.NewGuid():N}.json");
        try
        {
            var preferences = new Preferences(new SettingsStore(store));
            var actions = new SettingsActions(preferences, () => { }, _ => { }, () => { }, _ => { });
            var outside = new List<string>();
            foreach (var language in new[] { AppLanguage.Ko, AppLanguage.En })
                With(language, () =>
                {
                    foreach (var page in new[] { SettingsPage.General, SettingsPage.Widget, SettingsPage.Character })
                    {
                        SettingsView? view = null;
                        var image = Snapshot.Render(() => view = new SettingsView(Fixtures.Settings(), actions, page, _ => { }, snapshot: true), dark: true);
                        if (image.PixelWidth != (int)((SettingsView.NavWidth + SettingsView.PageWidth) * 2)) outside.Add($"{page}/{language.Code} {image.PixelWidth} px");
                        var controls = Descendants(view!).OfType<FrameworkElement>()
                            .Where(element => AutomationProperties.GetAutomationId(element).StartsWith("widget-", StringComparison.Ordinal)).ToList();
                        if (page == SettingsPage.Widget && controls.Count != 3) outside.Add($"{page}/{language.Code} {controls.Count} controls");
                        foreach (var control in controls)
                        {
                            var right = control.TransformToAncestor(view!).TransformBounds(new Rect(control.RenderSize)).Right;
                            if (control.RenderSize.Width < 1 || right > SettingsView.NavWidth + SettingsView.PageWidth - 20 + 0.5)
                                outside.Add($"{page}/{language.Code} {AutomationProperties.GetAutomationId(control)} ends at {right:F1}");
                        }
                    }
                });
            check(outside.Count == 0, "the General, Widget and Character pages build in ko and en, with the widget's size, preset and layout inside the page: "
                + string.Join(", ", outside));

            // Two lines, the character hidden, only memory drawn (the battery item is on, but this PC has none): memory is locked.
            preferences.Apply(DisplayPreset.SystemMonitor);
            preferences.HasBattery = false;
            foreach (var id in new[] { MetricID.Cpu, MetricID.Disk, MetricID.Network, MetricID.Ai }) preferences.SetVisible(id, false);
            preferences.SetShowRunner(false);
            var settings = new SettingsView(Fixtures.Settings(), actions, SettingsPage.Widget, _ => { }, snapshot: true);
            List<CheckBox> rows() => [.. Descendants(settings).OfType<CheckBox>()];
            var shown = rows();
            var named = shown.Select(row => Peer(row)?.GetName()).SequenceEqual(["CPU", "메모리 · RAM", "저장 공간 · DISK", "배터리 · BAT", "네트워크 · NET", "AI 세션 · AI",
                "Codex 속도", "Claude 속도"]);
            var states = shown.Select(row => (Toggled(row), row.IsEnabled)).SequenceEqual(
                [(ToggleState.Off, true), (ToggleState.On, false), (ToggleState.Off, true), (ToggleState.Off, false), (ToggleState.Off, true), (ToggleState.Off, true),
                 (ToggleState.Off, true), (ToggleState.Off, true)]);
            var note = Descendants(settings).OfType<TextBlock>().Any(text => text.Text.Replace("⁠", "") == "이 PC에는 배터리가 없습니다");
            // The speed rows show their glyph where the others show their label.
            var glyphs = Descendants(settings).OfType<TextBlock>().SelectMany(text => text.Inlines.OfType<System.Windows.Documents.InlineUIContainer>())
                .Select(container => container.Child).OfType<SpeedGlyph>().Count();
            check(named && states && note && glyphs == 2,
                "the widget's item rows are check boxes named title · bar label (a speed item by its title, its glyph beside it) in the stored order, "
                + "locked and no-battery rows disabled with the note");

            // UI Automation's Toggle (Narrator scan mode, voice access) raises no Click: it must still show and hide the item.
            var cpu = (IToggleProvider)Peer(shown[0])!.GetPattern(PatternInterface.Toggle)!;
            cpu.Toggle();
            var toggledOn = preferences.Visible.Contains(MetricID.Cpu);
            cpu.Toggle();
            check(toggledOn && !preferences.Visible.Contains(MetricID.Cpu), "toggling an item row through UI Automation did not show and hide the item");

            var handled = settings.RowKey(MetricID.Memory, Key.System, Key.Up, ModifierKeys.Alt);
            var ignored = !settings.RowKey(MetricID.Memory, Key.Up, Key.None, ModifierKeys.None) && !settings.RowKey(MetricID.Memory, Key.System, Key.Up, ModifierKeys.Control);
            var top = settings.RowKey(MetricID.Memory, Key.System, Key.Up, ModifierKeys.Alt) && preferences.Order[0] == MetricID.Memory;
            settings.Refresh(Fixtures.Settings());
            var rebuilt = AutomationProperties.GetName(rows()[0]) == "메모리 · RAM";
            settings.RowKey(MetricID.Memory, Key.System, Key.Down, ModifierKeys.Alt);
            check(handled && ignored && top && rebuilt && preferences.Order.SequenceEqual(Enum.GetValues<MetricID>()),
                  "Alt+↑/↓ on an item row moves it one place (not past the top), other keys are left alone, and the rebuilt list follows");

            var character = Descendants(new SettingsView(Fixtures.Settings(), actions, SettingsPage.Character, _ => { }, snapshot: true)).ToList();
            var general = Descendants(new SettingsView(Fixtures.Settings(), actions, SettingsPage.General, _ => { }, snapshot: true)).ToList();
            check(Named(character, "위젯에 캐릭터 표시") == nameof(ToggleState.Off) && Named(general, "화면에 위젯 표시") is null
                  && Named(Descendants(settings), "화면에 위젯 표시") == nameof(ToggleState.On),
                  "the widget's switch is on the Widget page and the character's in the widget on the Character page");
        }
        finally
        {
            Theme.Dark = saved;
            File.Delete(store);
        }
    }

    /// What Narrator reads (UI Automation): rows, limits and the header by name, the detail with its copy buttons, switches and
    /// choices with their state, text buttons by their visible words. Also the keyboard selection's outline and the footer refit.
    static void Automation(Action<bool, string> check)
    {
        static AutomationPeer? Peer(UIElement element) => UIElementAutomationPeer.CreatePeerForElement(element);
        static Dashboard Shown(string name)
        {
            var fixture = Fixtures.All().First(fixture => fixture.Name == name);
            var view = new Dashboard(DashboardActions.None, snapshot: true, selection: fixture.Selection, detail: fixture.Detail, expanded: fixture.Expanded);
            view.Show(Fixtures.Input(fixture));
            return view;
        }

        var selection = Shown("keyboard-selection");
        var rows = Tree(selection).OfType<RowShell>().ToList();
        check(rows.Count > 1 && rows.All(row => Peer(row) is { } peer && peer.GetAutomationControlType() == AutomationControlType.ListItem && peer.GetName().Length > 0)
              && rows.Count(row => row.Children[0] is Border { BorderThickness.Left: 1.5 }) == 1,
              "session rows are named list items in UI Automation, and only the keyboard selection is outlined");
        var status = Tree(selection).OfType<TrimLine>().FirstOrDefault(line => AutomationProperties.GetName(line).Length > 0);
        var limit = new LimitRow();
        limit.Update(Fixtures.Limits()[0], Fixtures.Now);
        check(status is not null && Peer(status) is { } statusPeer && statusPeer.GetName() == "세션 상태" && statusPeer.GetHelpText().Length > 0
              && statusPeer.GetChildren()?.Any(child => child.GetAutomationControlType() == AutomationControlType.Text) == true
              && Peer(limit) is { } limitPeer && limitPeer.GetAutomationControlType() == AutomationControlType.Text && limitPeer.GetName().StartsWith("Codex"),
              "the header status and limit rows reach UI Automation by name");
        // A flyout dragged out (§4.2) hands the window the top-level group of its selected child row or open detail.
        foreach (var name in new[] { "keyboard-selection", "detail-open" })
        {
            var group = Shown(name).SelectedGroup;
            var target = new Dashboard(DashboardActions.None, panel: true, snapshot: true);
            target.Show(Fixtures.Input(Fixtures.All().First(fixture => fixture.Name == name)));
            if (group is not null) target.Focus(group);
            check(group is not null && target.SelectedGroup == group, $"{name}: the selected group is still selected in the detached window ({group})");
        }
        var detail = Tree(Shown("detail-open")).OfType<DetailView>().FirstOrDefault();
        check(detail is not null && Peer(detail)?.GetName() == "세션 상세"
              && Peer(detail)?.GetChildren()?.Any(child => child.GetAutomationControlType() == AutomationControlType.Button) == true,
              "the inline detail is named and keeps its copy buttons in UI Automation");

        static ToggleState? Toggle(UIElement element) => (Peer(element)?.GetPattern(PatternInterface.Toggle) as IToggleProvider)?.ToggleState;
        var on = SettingsView.Switch(true, _ => { }, "턴 완료");
        check(Toggle(on) == ToggleState.On && Toggle(SettingsView.Switch(false, _ => { }, "턴 완료")) == ToggleState.Off && Peer(on)?.GetName() == "턴 완료",
              "settings switches report on/off to UI Automation");
        var store = Path.Combine(Path.GetTempPath(), $"tokencat-appchecks-{Guid.NewGuid():N}.json");
        try
        {
            var actions = new SettingsActions(new Preferences(new SettingsStore(store)), () => { }, _ => { }, () => { }, _ => { });
            var page = Tree(new SettingsView(Fixtures.Settings(), actions, SettingsPage.Character, _ => { }, snapshot: true)).ToList();
            var choices = page.OfType<RadioButton>().ToList();
            check(choices.Select(choice => AutomationProperties.GetName(choice))
                      .SequenceEqual([.. Enum.GetValues<RunnerCharacter>().Select(character => character.Title), .. Enum.GetValues<RunnerMotion>().Select(motion => motion.Title)])
                  && choices.Count(choice => choice.IsChecked == true) == 2
                  && page.OfType<Button>().Count(button => AutomationProperties.GetItemStatus(button) == "현재 페이지") == 1,
                  "character and motion choices are radio buttons named by their titles, and the current settings page is announced");
        }
        finally { File.Delete(store); }

        var link = Ui.Link("백업 보기", () => { }, "원본 백업");
        check(AutomationProperties.GetName(Ui.SmallButton("지금 다시 시도", () => { })) == "지금 다시 시도" && AutomationProperties.GetName(link) == "백업 보기"
              && Equals(link.ToolTip, "원본 백업"), "text buttons are named by their visible words, with the help as a tooltip");

        var footer = new Footer(DashboardActions.None);
        var failed = Fixtures.Update("failed", Fixtures.Now).Notice(null);
        footer.Update(new FooterStatus(FooterStatusKind.Live, "실시간"), null, "", failed);
        var trailing = (Border)footer.Children[1];
        var first = trailing.Child;
        footer.Update(new FooterStatus(FooterStatusKind.AiDelay, "AI 기록 지연 · 수집기 응답 없음"), null, "", failed);
        var refitted = trailing.Child;
        footer.Update(new FooterStatus(FooterStatusKind.AiDelay, "AI 수집 지연 12초"), null, "", failed);
        var counting = trailing.Child;
        footer.Update(new FooterStatus(FooterStatusKind.AiDelay, "AI 수집 지연 13초"), null, "", failed);
        check(first is not null && !ReferenceEquals(first, refitted) && ReferenceEquals(counting, trailing.Child),
              "the footer's update item is not fitted again when the status beside it changes, or is rebuilt as a delay counts");
        var overlaps = new List<string>();
        foreach (var language in new[] { AppLanguage.Ko, AppLanguage.En })
            With(language, () =>
            {
                var shown = Tree(Shown("restart-needed")).OfType<Footer>().Single();
                var widths = shown.Children.OfType<FrameworkElement>().Select(side =>
                {
                    side.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                    return side.DesiredSize.Width;
                }).ToList();
                if (widths.Sum() + 12 > Dashboard.PanelWidth - 2 * Dashboard.Gutter + 0.5) overlaps.Add($"{language.Code} {string.Join(" + ", widths)}");
            });
        check(overlaps.Count == 0, "the restart notice and a failed update overlap in the footer: " + string.Join("; ", overlaps));
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
        check(SettingsPageTitles() == "일반 · 위젯 · 캐릭터 · 실측 · 정보", "Settings pages are not 일반 · 위젯 · 캐릭터 · 실측 · 정보");
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
            && SettingsView.ClaudeLimitsStatus([], false, at.AddSeconds(-720), true, at) == (SettingsView.StatusRow.Received, "Claude 데스크톱 앱 기록 · 12분 전", null)
            && SettingsView.ClaudeLimitsStatus([], false, at.AddSeconds(-30), false, at, live: true) == (SettingsView.StatusRow.Received, "실시간 확인 1분 이내", null),
            "Claude limit row is not checked empty status line → skipped → received → waiting → none");
        check(LoginItem.Describe(LoginItem.State.NotRegistered) == "꺼짐 · 켤 때만 시작 프로그램에 등록합니다", "Korean startup app captions changed");
        const string command = "\"C:\\Users\\me\\AppData\\Local\\Programs\\TokenCat\\TokenCat.exe\"";
        check(LoginItem.StateFor(null, null, command) == LoginItem.State.NotRegistered
              && LoginItem.StateFor("\"C:\\Other\\TokenCat.exe\"", null, command) == LoginItem.State.NotRegistered
              && LoginItem.StateFor(command.ToLowerInvariant(), new byte[] { 0x02, 0, 0, 0 }, command) == LoginItem.State.Enabled
              && LoginItem.StateFor(command, new byte[] { 0x03, 0, 0, 0 }, command) == LoginItem.State.DisabledInTaskManager,
              "a startup entry for another path is not off, or Task Manager's switch is misread");
        var screen = new System.Drawing.Rectangle(0, 0, 1920, 1080);
        check(Shell.Corner(new(0, 0, 1920, 1032), screen) == new System.Drawing.Point(1920, 1032)
              && Shell.Corner(new(0, 48, 1920, 1032), screen) == new System.Drawing.Point(1920, 48)
              && Shell.Corner(new(62, 0, 1858, 1080), screen) == new System.Drawing.Point(62, 1080),
              "the flyout opened from the menu or a notification is not at the taskbar's corner");
        check(Ui.KeepWords("권장합니다 Claude 데스크톱") == "권\u2060장\u2060합\u2060니\u2060다 Claude 데\u2060스\u2060크\u2060톱",
            "Korean captions can still break inside a word");
        With(AppLanguage.En, () =>
        {
            check(SettingsPageTitles() == "General · Widget · Character · Telemetry · About"
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
