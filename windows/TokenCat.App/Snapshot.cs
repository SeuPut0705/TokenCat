using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TokenCat;

/// `--snapshot <dir>` (DESIGN §11 WP5): the Fixtures dashboard, the component sheets, every Settings page and the widget in {ko, en},
/// each PNG dark | light at 2×, plus the tray frames at 16/20/24/28/32 px for every pose. Offscreen RenderTargetBitmap;
/// nothing local is read and no window is shown. CI uploads the folder for review.
static class Snapshot
{
    public static int Write(string directory)
    {
        Directory.CreateDirectory(directory);
        var saved = 0;
        var failures = new List<string>();
        var store = Path.Combine(Path.GetTempPath(), $"tokencat-snapshot-{Guid.NewGuid():N}.json");
        var dark = Theme.Dark;
        try
        {
            // A throwaway store: the fixtures show default preferences and never write the real settings.json.
            var actions = new SettingsActions(new Preferences(new SettingsStore(store)), () => { }, _ => { }, () => { }, _ => { });
            foreach (var language in new[] { AppLanguage.Ko, AppLanguage.En })
            {
                Lang.With(language, () =>
                {
                    var code = language.Code;
                    foreach (var fixture in Fixtures.All())
                        Save($"flyout-{fixture.Name}-{code}.png", () => Dashboard(fixture));
                    Save($"onboarding-{code}.png", () => Sheet(Fixtures.Outcomes().Select(outcome => OnboardingCard.Build(outcome, DashboardActions.None))));
                    Save($"usage-limits-{code}.png", () => Sheet(Fixtures.Limits().Select(limit =>
                    {
                        var row = new LimitRow();
                        row.Update(limit, Fixtures.Now);
                        return (FrameworkElement)Ui.Container(row);
                    })));
                    foreach (var page in Enum.GetValues<SettingsPage>())
                        Save($"settings-{page.ToString().ToLowerInvariant()}-{code}.png", () => new SettingsView(Fixtures.Settings(), actions, page, _ => { }, snapshot: true));
                    Save($"widget-{code}.png", Widgets);
                });
            }
            try
            {
                Theme.Dark = false;
                Write(Path.Combine(directory, "tray.png"), Tray());
                saved++;
            }
            catch (Exception error) { failures.Add($"tray.png: {error.GetType().Name}: {error.Message}"); }
        }
        finally
        {
            Theme.Dark = dark;
            File.Delete(store);
        }
        foreach (var failure in failures) Console.WriteLine($"FAIL: {failure}");
        Console.WriteLine($"Snapshots saved: {saved} in {Path.GetFullPath(directory)}");
        return failures.Count == 0 ? 0 : 1;

        void Save(string name, Func<FrameworkElement> build)
        {
            try
            {
                Write(Path.Combine(directory, name), SideBySide(Render(build, dark: true), Render(build, dark: false)));
                saved++;
            }
            catch (Exception error) { failures.Add($"{name}: {error.GetType().Name}: {error.Message}"); }
        }
    }

    static FrameworkElement Dashboard(Fixtures.Fixture fixture)
    {
        var view = new Dashboard(DashboardActions.None, snapshot: true, selection: fixture.Selection, detail: fixture.Detail, expanded: fixture.Expanded);
        view.Show(Fixtures.Input(fixture));
        return view;
    }

    /// The widget on a wallpaper-like blue: minimal, two-line and one-line with tools running, the same with input needed,
    /// minimal before the first sample (sleeping, with its z), minimal and two lines without the character, two lines at
    /// 150 % (the runner resampled smoothly) and 200 %, then with the speed items on: Codex's measured rate beside Claude's
    /// "—" on two lines, Codex's "—" beside Claude's rate on one line.
    static FrameworkElement Widgets()
    {
        var stack = new System.Windows.Controls.StackPanel { Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x6E, 0xA5)) };
        void Add(string fixture, StatusBarLayout layout, RunnerPose pose, bool runner = true, int percent = 100, IReadOnlyList<MetricID>? items = null)
        {
            var state = Fixtures.Input(Fixtures.All().First(candidate => candidate.Name == fixture)).State;
            var view = new WidgetView();
            view.Update(StatusBarContent.Metrics(state, layout, items ?? MetricID.Standard), layout, runner, percent);
            view.UpdateRunner(RunnerCharacter.Cat, pose, 0, RunnerAnimator.StillFx(pose));
            stack.Children.Add(new System.Windows.Controls.Border
            {
                Child = view, Background = Theme.Brush(Theme.Background), CornerRadius = new CornerRadius(8),
                Margin = new Thickness(12, 12, 12, 0), HorizontalAlignment = HorizontalAlignment.Left,
            });
        }
        foreach (var layout in Enum.GetValues<StatusBarLayout>()) Add("tool-categories", layout, RunnerPose.Walk);
        foreach (var layout in Enum.GetValues<StatusBarLayout>()) Add("input-needed", layout, RunnerPose.Alert);
        Add("loading", StatusBarLayout.Minimal, RunnerPose.Sleep);
        Add("tool-categories", StatusBarLayout.Minimal, RunnerPose.Walk, runner: false);
        Add("tool-categories", StatusBarLayout.Compact, RunnerPose.Walk, runner: false);
        Add("tool-categories", StatusBarLayout.Compact, RunnerPose.Walk, percent: 150);
        Add("tool-categories", StatusBarLayout.Compact, RunnerPose.Walk, percent: 200);
        Add("input-needed", StatusBarLayout.Compact, RunnerPose.Alert, items: Enum.GetValues<MetricID>());
        Add("context-limit", StatusBarLayout.Inline, RunnerPose.Walk, items: Enum.GetValues<MetricID>());
        stack.Children.Add(new System.Windows.Controls.Border { Height = 12 });
        return stack;
    }

    /// Component previews framed like the dashboard: 16 DIP gutters, 12 between items.
    static FrameworkElement Sheet(IEnumerable<FrameworkElement> items)
    {
        var stack = new System.Windows.Controls.StackPanel { Width = TokenCat.Dashboard.PanelWidth, Background = Theme.Brush(Theme.Background) };
        foreach (var item in items)
        {
            item.Margin = new Thickness(TokenCat.Dashboard.Gutter, 12, TokenCat.Dashboard.Gutter, 0);
            stack.Children.Add(item);
        }
        stack.Children.Add(new System.Windows.Controls.Border { Height = 12 });
        Ui.Styled(stack, Font.Body, Theme.Label);
        return stack;
    }

    /// Lays `build()` out at its own width in the given theme and renders it at 2×.
    public static BitmapSource Render(Func<FrameworkElement> build, bool dark)
    {
        Theme.Dark = dark;
        var element = build();
        element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        element.Arrange(new Rect(element.DesiredSize));
        element.UpdateLayout();
        var size = element.DesiredSize;
        if (size.Width < 1 || size.Height < 1) throw new InvalidOperationException("empty layout");
        // Every root draws its own theme background.
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(size.Width * 2), (int)Math.Ceiling(size.Height * 2), 192, 192, PixelFormats.Pbgra32);
        bitmap.Render(element);
        bitmap.Freeze();
        return bitmap;
    }

    /// Dark | light on a neutral grey, 24 px apart (the mac fixture sheets).
    static BitmapSource SideBySide(BitmapSource left, BitmapSource right)
    {
        const int gap = 24;
        int width = left.PixelWidth + gap + right.PixelWidth, height = Math.Max(left.PixelHeight, right.PixelHeight);
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            context.DrawRectangle(new SolidColorBrush(Color.FromRgb(128, 128, 128)), null, new Rect(0, 0, width, height));
            context.DrawImage(left, new Rect(0, 0, left.PixelWidth, left.PixelHeight));
            context.DrawImage(right, new Rect(left.PixelWidth + gap, 0, right.PixelWidth, right.PixelHeight));
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        return bitmap;
    }

    /// Rows: icon sizes × taskbar tone; columns: every pose frame (sleep with its z steps), then the input and retry dots.
    /// Each icon is drawn ×4 without smoothing so single pixels can be reviewed.
    static BitmapSource Tray()
    {
        var cells = new List<(RunnerPose Pose, int Frame, int? Fx, StateDot Dot)>();
        foreach (var pose in Enum.GetValues<RunnerPose>())
        {
            var frames = pose switch { RunnerPose.Sit or RunnerPose.Sleep or RunnerPose.Alert or RunnerPose.Content => 2, RunnerPose.Walk => 4, RunnerPose.Run => 6, _ => 1 };
            for (var frame = 0; frame < frames; frame++) cells.Add((pose, frame, pose == RunnerPose.Sleep ? frame == 1 ? 1 : 2 : null, StateDot.None));
        }
        cells.Add((RunnerPose.Alert, 0, null, StateDot.Attention));
        cells.Add((RunnerPose.Walk, 0, null, StateDot.Warning));
        int[] sizes = [16, 20, 24, 28, 32];
        const int zoom = 4, pad = 8, cell = 32 * zoom + pad;
        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.NearestNeighbor);
        var rows = sizes.Length * 2;
        using (var context = visual.RenderOpen())
        {
            for (var row = 0; row < rows; row++)
            {
                var size = sizes[row / 2];
                var light = row % 2 == 1;
                context.DrawRectangle(new SolidColorBrush(light ? Color.FromRgb(0xEE, 0xEE, 0xEE) : Color.FromRgb(0x1C, 0x1C, 0x1C)), null,
                    new Rect(0, row * cell, cells.Count * cell, cell));
                for (var column = 0; column < cells.Count; column++)
                {
                    var (pose, frame, fx, dot) = cells[column];
                    var pixels = TrayIcon.Pixels(size, RunnerCharacter.Cat, pose, frame, fx, dot, light);
                    var image = BitmapSource.Create(size, size, 96, 96, PixelFormats.Bgra32, null, pixels, size * 4);
                    context.DrawImage(image, new Rect(column * cell + pad / 2, row * cell + pad / 2, size * zoom, size * zoom));
                }
            }
        }
        var bitmap = new RenderTargetBitmap(cells.Count * cell, rows * cell, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        return bitmap;
    }

    static void Write(string path, BitmapSource image)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var file = File.Create(path);
        encoder.Save(file);
    }
}
