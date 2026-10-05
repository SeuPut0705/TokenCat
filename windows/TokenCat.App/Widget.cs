using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace TokenCat;

/// The on-screen widget (DESIGN §4.7): the mac menu-bar item in a small borderless, topmost window that never takes the focus
/// and stays out of the taskbar and Alt+Tab. Drag to move (edges snap to the work area); a click raises `Clicked` (a
/// double-click counts once), a right-click `MenuRequested`. The shell owns showing, hiding and the saved position.
sealed class Widget : Window
{
    public WidgetView View { get; } = new();
    public event Action? Clicked, MenuRequested;
    /// The end of a drag, with the new top-left in physical pixels.
    public event Action<Drawing.Point>? Dropped;
    Drawing.Point press, origin;
    bool pressed, dragging;

    public Widget()
    {
        Title = "TokenCat";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        Focusable = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        Content = View;
        // Rounded by DWM on Windows 11; no AllowsTransparency (a layered, software-rendered window).
        SourceInitialized += (_, _) => { Native.NoActivate(this); Native.StyleWindow(this, round: true); };
        // A layout or DPI change resizes it from the top-left: keep it on its screen.
        SizeChanged += (_, _) => { if (IsVisible && !dragging) Fit(); };
        Restyle();
    }

    /// A light/dark change: the backdrop, the tones and the sleep z's ink.
    public void Restyle()
    {
        Background = Theme.Brush(Theme.Background);
        if (IsLoaded) Native.StyleWindow(this, round: true);
        View.InvalidateVisual();
    }

    /// Shows it at `saved` (physical px), else at the primary work area's bottom-right corner 12 DIP in, and keeps it on screen.
    /// Moved before it shows, so it never flashes elsewhere; the move also gives WPF the target monitor's DPI.
    public void Present(Drawing.Point? saved)
    {
        new System.Windows.Interop.WindowInteropHelper(this).EnsureHandle();
        var area = Forms.Screen.PrimaryScreen!.WorkingArea;
        var margin = Native.Pixels(this, 12);
        Native.Move(this, saved ?? new(area.Right - margin, area.Bottom - margin));
        Show();
        UpdateLayout();
        if (saved is not null) Fit();
        else Native.Move(this, WidgetPlacement.Fit(Native.Bounds(this), Drawing.Rectangle.Inflate(area, -margin, -margin)));
    }

    /// Alt+F4 (it's in front after its menu) or a WM_CLOSE from outside is refused: a closed window can't be shown again.
    /// The app's shutdown (quit, sign-out) closes it regardless, and nothing is saved here, so a sign-out never turns it off.
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        base.OnClosing(e);
        e.Cancel = true;
    }

    void Fit()
    {
        var bounds = Native.Bounds(this);
        Native.Move(this, WidgetPlacement.Fit(bounds, Forms.Screen.FromRectangle(bounds).WorkingArea));
    }

    // Dragging by hand rather than DragMove: the system move loop would activate the window, and this snaps as it goes.
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (e.ClickCount > 1) return; // the second press of a double-click: the first already acted
        press = Forms.Cursor.Position;
        origin = Native.Bounds(this).Location;
        dragging = false;
        pressed = CaptureMouse();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!pressed) return;
        var cursor = Forms.Cursor.Position;
        int dx = cursor.X - press.X, dy = cursor.Y - press.Y;
        if (!dragging && Math.Abs(dx) < Native.Pixels(this, SystemParameters.MinimumHorizontalDragDistance)
            && Math.Abs(dy) < Native.Pixels(this, SystemParameters.MinimumVerticalDragDistance)) return;
        dragging = true;
        var size = Native.Bounds(this).Size;
        var target = new Drawing.Rectangle(new(origin.X + dx, origin.Y + dy), size);
        Native.Move(this, WidgetPlacement.Fit(target, Forms.Screen.FromPoint(cursor).WorkingArea, Native.Pixels(this, 12)));
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (!pressed) return;
        var click = !dragging;
        ReleaseMouseCapture(); // ends the drag in OnLostMouseCapture
        if (click) Clicked?.Invoke();
    }

    /// Release, or capture taken away mid-drag (Alt+Tab, a dialog): the drag ends where it is. A DPI change on the last move
    /// resized it without a re-fit (SizeChanged skips drags), so it is kept on screen before the spot is saved.
    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        pressed = false;
        if (!dragging) return;
        dragging = false;
        Fit();
        Dropped?.Invoke(Native.Bounds(this).Location);
    }

    protected override void OnMouseRightButtonUp(MouseButtonEventArgs e)
    {
        e.Handled = true;
        MenuRequested?.Invoke();
    }
}

/// StatusBarContentView.drawContent in WPF: the runner slot and fixed-width cells, in mac points. A point is `unit` whole device
/// pixels (the display scale rounded), so the pixel art is crisp at every scale and the text sits where the mac draws it.
sealed class WidgetView : FrameworkElement
{
    /// Around the mac item's 24 pt strip: 4 pt each side, 2 pt above and below.
    public const double Inset = 4, Pad = 2;
    IReadOnlyList<StatusBarMetric> metrics = [];
    StatusBarLayout layout;
    (RunnerCharacter Character, RunnerPose Pose, int Frame, int? Fx) runner = (RunnerCharacter.Cat, RunnerPose.Sit, 0, null);
    BitmapSource? sprite;
    bool spriteDark;
    int unit = 1;
    Color label, secondary, tertiary;

    /// DIPs per point.
    public double Scale { get; private set; } = 1;
    /// Each text drawn in the last render with its shrink factor (1 = natural size), for the checks.
    public List<(string Text, double Fit)> Drawn { get; } = [];

    public WidgetView() => RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.NearestNeighbor);

    public void Update(IReadOnlyList<StatusBarMetric> next, StatusBarLayout nextLayout)
    {
        if (nextLayout == layout && next.SequenceEqual(metrics)) return;
        var width = PointWidth;
        (metrics, layout) = (next, nextLayout);
        if (width != PointWidth) InvalidateMeasure();
        InvalidateVisual();
    }

    /// Called on the tray animator's frames: the widget shares its one timer.
    /// ponytail: a frame redraws the cells' text too (cheap at this size); move the runner to its own DrawingVisual if it shows in a profile.
    public void UpdateRunner(RunnerCharacter character, RunnerPose pose, int frame, int? fx)
    {
        if (runner == (character, pose, frame, fx)) return;
        runner = (character, pose, frame, fx);
        sprite = null;
        InvalidateVisual();
    }

    double PointWidth => StatusBarContent.RequiredWidth(layout, metrics.Select(metric => metric.Id)) + 2 * Inset;

    void Units()
    {
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var next = Math.Max(1, (int)Math.Round(dpi, MidpointRounding.AwayFromZero));
        if (next != unit) sprite = null;
        unit = next;
        Scale = next / dpi;
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        InvalidateMeasure();
        InvalidateVisual();
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        Units();
        return new(PointWidth * Scale, (StatusBarContent.Height + 2 * Pad) * Scale);
    }

    /// The label colour at the bar's alphas (NSColor.withAlphaComponent replaces the alpha).
    static Color Tone(double alpha) => Color.FromArgb((byte)Math.Round(255 * alpha), Theme.Label.R, Theme.Label.G, Theme.Label.B);

    static int Group(MetricID id) => id switch { MetricID.Network => 1, MetricID.Ai => 2, _ => 0 };

    double Snap(double value) => Math.Round(value * unit) / unit;

    protected override void OnRender(DrawingContext context)
    {
        Units();
        Drawn.Clear();
        (label, secondary, tertiary) = (Theme.Label, Tone(0.72), Tone(0.45));
        context.PushTransform(new ScaleTransform(Scale, Scale));
        var x = Inset + StatusBarContent.Edge;
        var middle = Pad + StatusBarContent.Height / 2;
        // The tray's body frame at `unit` px per art px (a 30 × 30 square with the 30 × 18 cell centred), centred on the
        // 32 × 20 slot; its z is drawn in the label tone of the backdrop.
        if (sprite is null || spriteDark != Theme.Dark)
        {
            var size = RunnerManifest.CellWidth * unit;
            sprite = BitmapSource.Create(size, size, 96, 96, PixelFormats.Bgra32, null,
                TrayIcon.Pixels(size, runner.Character, runner.Pose, runner.Frame, runner.Fx, StateDot.None, !Theme.Dark), size * 4);
            sprite.Freeze();
            spriteDark = Theme.Dark;
        }
        context.DrawImage(sprite, new Rect(x + 1, middle - 15, 30, 30));
        x += StatusBarContent.RunnerWidth + (metrics.Count == 0 ? 0 : 2);
        for (var index = 0; index < metrics.Count; index++)
        {
            var metric = metrics[index];
            var cell = new Rect(x, Pad, StatusBarContent.CellWidth(layout, metric.Id), StatusBarContent.Height);
            if (index > 0 && Group(metrics[index - 1].Id) != Group(metric.Id))
                context.DrawRectangle(Theme.Brush(Tone(0.26)), null, new Rect(Snap(x), Pad + 4, 1.0 / unit, StatusBarContent.Height - 8));
            switch (layout)
            {
                case StatusBarLayout.Minimal: DrawAI(context, metric, middle, cell, 12, centered: true); break;
                case StatusBarLayout.Compact: DrawCompact(context, metric, cell); break;
                default: DrawInline(context, metric, cell); break;
            }
            x += cell.Width;
        }
        context.Pop();
    }

    void DrawCompact(DrawingContext context, StatusBarMetric metric, Rect cell)
    {
        var top = cell.Top + Math.Max(0, (cell.Height - 22) / 2);
        if (metric.Id == MetricID.Network) { DrawNetworkRows(context, metric, new Rect(cell.X, top, cell.Width, 22)); return; }
        var inner = new Rect(cell.X + 1, cell.Y, cell.Width - 2, cell.Height);
        Draw(context, [new(metric.Label, 8.5, FontWeights.SemiBold, secondary)], top + 4.5, inner);
        if (metric.Id == MetricID.Ai) DrawAI(context, metric, top + 15.5, inner, 11, centered: true);
        else Draw(context, ValueRuns(metric.Value), top + 15.5, inner);
    }

    void DrawInline(DrawingContext context, StatusBarMetric metric, Rect cell)
    {
        var middle = cell.Top + cell.Height / 2;
        if (metric.Id == MetricID.Network) { DrawNetworkLine(context, metric, cell, middle); return; }
        if (metric.Id == MetricID.Ai)
        {
            // 4 pt clear of the separator on both sides.
            DrawAI(context, metric, middle, new Rect(cell.X + 4, cell.Y, cell.Width - 6, cell.Height), 11, centered: false,
                [new("AI", 9, FontWeights.SemiBold, secondary)]);
            return;
        }
        // The mac's 16 pt SF Symbol slot holds the short name here (19 pt), trailing-aligned so it hugs its value.
        Draw(context, [new(metric.Label, 8.5, FontWeights.SemiBold, secondary)], middle, new Rect(cell.X + 1, cell.Y, 19, cell.Height), TextAlignment.Right);
        Draw(context, ValueRuns(metric.Value), middle, new Rect(cell.X + 23, cell.Y, cell.Width - 23, cell.Height), TextAlignment.Left);
    }

    /// Digits in the label tone, '%' smaller and secondary; unknown stays "—".
    TextRun[] ValueRuns(string value) =>
        value == "—" ? [new(value, 11, FontWeights.Medium, secondary)]
        : value.EndsWith('%') ? [new(value[..^1], 11, FontWeights.Medium, label), new("%", 8.5, FontWeights.Medium, secondary)]
        : [new(value, 11, FontWeights.Medium, label)];

    /// Mark slot (shape = state) then the count: label while running, secondary for log wait or before the first sample,
    /// tertiary "0" with an empty slot (M-2). The slot is always reserved, so the count never moves.
    void DrawAI(DrawingContext context, StatusBarMetric metric, double centerY, Rect rect, double size, bool centered, TextRun[]? prefix = null)
    {
        var tone = metric.IsActive ? label : metric.Value == "—" || metric.ActivityState == TokenActivityState.Stale ? secondary : tertiary;
        TextRun[] count = [new(metric.Value, size, FontWeights.Medium, tone)];
        var prefixWidth = prefix is null ? 0 : Format(prefix, 1).WidthIncludingTrailingWhitespace + 3;
        var total = prefixWidth + StatusBarContent.MarkSlot + Format(count, 1).WidthIncludingTrailingWhitespace;
        var x = centered ? Math.Max(rect.Left, rect.Left + rect.Width / 2 - total / 2) : rect.Left;
        if (prefix is not null)
        {
            Draw(context, prefix, centerY, new Rect(x, rect.Top, prefixWidth, rect.Height), TextAlignment.Left);
            x += prefixWidth;
        }
        DrawMark(context, metric.ActivityState, new Point(x + (StatusBarContent.MarkSlot - 3) / 2, centerY));
        x += StatusBarContent.MarkSlot;
        Draw(context, count, centerY, new Rect(x, rect.Top, Math.Max(1, rect.Right - x), rect.Height), TextAlignment.Left);
    }

    /// `StateGlyph` marks: purple ring working, blue rounded square tool, yellow "?" input, the half disc in the secondary tone.
    void DrawMark(DrawingContext context, TokenActivityState state, Point center)
    {
        var side = StatusBarContent.MarkWidth(state);
        if (side == 0 || StateGlyphKind.From(state) is not { } kind) return;
        var box = new Rect(Snap(center.X - side / 2), Snap(center.Y - side / 2), side, side);
        var shape = GlyphView.Shape(kind, box, out var stroke);
        var brush = Theme.Brush(kind == StateGlyphKind.Waiting ? secondary : Theme.GlyphColor(kind));
        if (stroke is not null) { stroke.Brush = brush; context.DrawGeometry(null, stroke, shape); }
        else context.DrawGeometry(brush, null, shape);
        if (kind == StateGlyphKind.Input) context.DrawGeometry(Brushes.Black, null, GlyphView.InputMark(box));
    }

    /// Fixed arrow column, numbers right-aligned to one column, units smaller and secondary.
    void DrawNetworkRows(DrawingContext context, StatusBarMetric metric, Rect rect)
    {
        const double arrow = 7, number = 23, suffix = 21;
        var start = rect.X + (rect.Width - (arrow + number + 1 + suffix)) / 2;
        var lines = metric.Value.Split('\n');
        for (var index = 0; index < Math.Min(2, lines.Length); index++)
        {
            var centerY = rect.Y + 5.5 + index * 11;
            var (digits, unitText) = StatusBarContent.SplitRate(lines[index][1..]);
            Draw(context, [new(lines[index][..1], 8, FontWeights.SemiBold, secondary)], centerY, new Rect(start, rect.Y, arrow, rect.Height), TextAlignment.Left, 9.5);
            Draw(context, [new(digits, 9.5, FontWeights.Medium, unitText.Length == 0 ? secondary : label)], centerY,
                new Rect(start + arrow, rect.Y, number, rect.Height), TextAlignment.Right);
            Draw(context, [new(unitText, 8, FontWeights.Normal, secondary)], centerY, new Rect(start + arrow + number + 1, rect.Y, suffix, rect.Height), TextAlignment.Left, 9.5);
        }
    }

    void DrawNetworkLine(DrawingContext context, StatusBarMetric metric, Rect cell, double middle)
    {
        var lines = metric.Value.Split('\n');
        for (var index = 0; index < Math.Min(2, lines.Length); index++)
        {
            var x = cell.X + 5 + index * 53;
            var (digits, unitText) = StatusBarContent.SplitRate(lines[index][1..]);
            Draw(context, [new(lines[index][..1], 9, FontWeights.SemiBold, secondary)], middle, new Rect(x, cell.Y, 8, cell.Height), TextAlignment.Left, 11);
            Draw(context, [new(digits, 11, FontWeights.Medium, unitText.Length == 0 ? secondary : label)], middle, new Rect(x + 8, cell.Y, 22, cell.Height), TextAlignment.Right);
            Draw(context, [new(unitText, 8.5, FontWeights.Normal, secondary)], middle, new Rect(x + 31, cell.Y, 21, cell.Height), TextAlignment.Left, 11);
        }
    }

    readonly record struct TextRun(string Text, double Size, FontWeight Weight, Color Color);

    static readonly Typeface Face = new(Ui.Family, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    static readonly double CapRatio = Face.TryGetGlyphTypeface(out var glyphs) ? glyphs.CapsHeight : 0.7;

    /// One line with the cap height of the largest (or given) size centred on `centerY`. Fixed slots avoid width jitter; a rare
    /// very large value shrinks to fit.
    void Draw(DrawingContext context, TextRun[] runs, double centerY, Rect rect, TextAlignment alignment = TextAlignment.Center, double? capSize = null)
    {
        runs = [.. runs.Where(run => run.Text.Length > 0)];
        if (runs.Length == 0) return;
        var text = Format(runs, 1);
        var fit = 1.0;
        if (text.WidthIncludingTrailingWhitespace > rect.Width && rect.Width > 0)
        {
            fit = rect.Width / text.WidthIncludingTrailingWhitespace;
            text = Format(runs, fit);
        }
        Drawn.Add((text.Text, fit));
        var cap = (capSize ?? runs.Max(run => run.Size) * fit) * CapRatio;
        var width = text.WidthIncludingTrailingWhitespace;
        var left = alignment switch { TextAlignment.Left => rect.Left, TextAlignment.Right => rect.Right - width, _ => rect.Left + (rect.Width - width) / 2 };
        context.DrawText(text, new Point(left, centerY + cap / 2 - text.Baseline));
    }

    FormattedText Format(TextRun[] runs, double fit)
    {
        var text = new FormattedText(string.Concat(runs.Select(run => run.Text)), CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face,
            Math.Max(7, runs[0].Size * fit), Theme.Brush(runs[0].Color), unit);
        var start = 0;
        foreach (var run in runs)
        {
            text.SetFontSize(Math.Max(7, run.Size * fit), start, run.Text.Length);
            text.SetFontWeight(run.Weight, start, run.Text.Length);
            text.SetForegroundBrush(Theme.Brush(run.Color), start, run.Text.Length);
            start += run.Text.Length;
        }
        return text;
    }
}
