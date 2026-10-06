using System.Drawing;

namespace TokenCat;

/// Where "창으로 열기" comes back (DESIGN §4.2), in physical pixels: pure apart from the store, so the checks run on any OS.
public static class DashboardBounds
{
    public const string Key = "dashboardWindowBounds";

    /// The work area holding most of `saved`, moved and shortened to fit inside it; null when none of it is on a work area (that
    /// monitor is gone), so the window opens where Windows puts a new one.
    public static Rectangle? Restore(Rectangle saved, IEnumerable<Rectangle> areas)
    {
        static long Overlap(Rectangle area, Rectangle bounds)
        {
            var shared = Rectangle.Intersect(area, bounds);
            return (long)shared.Width * shared.Height;
        }
        var area = areas.OrderByDescending(candidate => Overlap(candidate, saved)).FirstOrDefault();
        if (saved.Width <= 0 || saved.Height <= 0 || Overlap(area, saved) == 0) return null;
        var size = new Size(saved.Width, Math.Min(saved.Height, area.Height));
        return new(WidgetPlacement.Fit(new(saved.Location, size), area), size);
    }

    public static Rectangle? Saved(SettingsStore store, IEnumerable<Rectangle> areas) =>
        store.Get<int[]>(Key) is [var x, var y, var width, var height] ? Restore(new(x, y, width, height), areas) : null;

    public static void Save(SettingsStore store, Rectangle bounds) => store.Set(Key, new[] { bounds.X, bounds.Y, bounds.Width, bounds.Height });
}
