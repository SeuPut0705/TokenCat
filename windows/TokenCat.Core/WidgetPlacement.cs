using System.Drawing;

namespace TokenCat;

/// The on-screen widget's placement rules (DESIGN §4.7), in physical pixels: pure, so the checks run on any OS.
public static class WidgetPlacement
{
    public const string PositionsKey = "widgetPositions";

    /// SHQueryUserNotificationState: QUNS_BUSY (a full-screen app), QUNS_RUNNING_D3D_FULL_SCREEN, QUNS_PRESENTATION_MODE.
    /// The desktop itself (Progman/WorkerW) covers its monitor too, so it never counts.
    public static bool HidesFor(int notificationState, string? foregroundClass) =>
        notificationState is 2 or 3 or 4 && foregroundClass is not ("Progman" or "WorkerW");

    /// One key per monitor set: each screen's bounds, in a stable order.
    public static string DisplayKey(IEnumerable<Rectangle> screens) =>
        string.Join(";", screens.OrderBy(screen => screen.X).ThenBy(screen => screen.Y).Select(screen => $"{screen.X},{screen.Y},{screen.Width}x{screen.Height}"));

    /// The widget's top-left: edges within `snap` px of the work area's edges stick to them, then it stays inside the area
    /// (top-left wins when it can't fit).
    public static Point Fit(Rectangle widget, Rectangle area, int snap = 0)
    {
        static int Axis(int at, int size, int start, int end, int snap)
        {
            if (Math.Abs(at - start) <= snap) at = start;
            else if (Math.Abs(end - size - at) <= snap) at = end - size;
            return Math.Max(start, Math.Min(at, end - size));
        }
        return new(Axis(widget.X, widget.Width, area.Left, area.Right, snap), Axis(widget.Y, widget.Height, area.Top, area.Bottom, snap));
    }

    /// Where the flyout hangs: below a widget in the top half of its work area, else above, `gap` px away and centred on it.
    public static (Point Anchor, bool Below) FlyoutAnchor(Rectangle widget, Rectangle area, int gap)
    {
        var below = widget.Top + widget.Height / 2 < area.Top + area.Height / 2;
        return (new(widget.Left + widget.Width / 2, below ? widget.Bottom + gap : widget.Top - gap), below);
    }

    /// ponytail: one entry per monitor set ever used, never pruned; cap it if anyone collects hundreds.
    public static Point? Saved(SettingsStore store, string display) =>
        store.Get<Dictionary<string, int[]>>(PositionsKey)?.GetValueOrDefault(display) is [var x, var y] ? new Point(x, y) : null;

    public static void Save(SettingsStore store, string display, Point at)
    {
        var positions = store.Get<Dictionary<string, int[]>>(PositionsKey) ?? [];
        positions[display] = [at.X, at.Y];
        store.Set(PositionsKey, positions);
    }
}
