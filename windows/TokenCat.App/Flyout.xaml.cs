using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using static TokenCat.Lang;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace TokenCat;

/// The tray flyout window; the shell owns showing, placement and hiding (§4.2).
public partial class Flyout : Window
{
    internal Dashboard Dashboard { get; private set; } = null!;
    /// Dragged past the system drag distance (§4.2): the pointer and the grabbed point's offset from the flyout's top-left, in
    /// physical pixels.
    internal event Action<Drawing.Point, Drawing.Point>? DraggedOut;
    Drawing.Point? press;

    internal Flyout(DashboardActions actions)
    {
        InitializeComponent();
        Rebuild(actions);
        SourceInitialized += (_, _) => Native.StyleWindow(this, round: true);
    }

    /// A theme change rebuilds the view with the new tokens.
    internal void Rebuild(DashboardActions actions)
    {
        Dashboard = new Dashboard(actions);
        // Taller than the work area (MaxHeight): scrolls instead of cutting off the footer.
        Content = new System.Windows.Controls.ScrollViewer
        {
            Content = Dashboard, VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto, Focusable = false,
        };
        Background = Theme.Brush(Theme.Background);
        if (IsLoaded) Native.StyleWindow(this, round: true);
    }

    /// Buttons, links and the scroll bar take their own presses, so this sees the rest; the session list (rows open on release)
    /// and hand-cursor areas (System → Task Manager) are left out too.
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (Draggable(e.OriginalSource as DependencyObject) && CaptureMouse()) Press(Forms.Cursor.Position);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Drag(Forms.Cursor.Position);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        Release();
    }

    /// Capture taken away (Alt+Tab, a menu) ends the press as well.
    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        press = null;
    }

    internal void Press(Drawing.Point at) => press = at;

    /// A release before the drag distance was a click: nothing else happens.
    internal void Release()
    {
        press = null;
        ReleaseMouseCapture();
    }

    internal void Drag(Drawing.Point at)
    {
        if (press is not { } start) return;
        if (Math.Abs(at.X - start.X) < Native.Pixels(this, SystemParameters.MinimumHorizontalDragDistance)
            && Math.Abs(at.Y - start.Y) < Native.Pixels(this, SystemParameters.MinimumVerticalDragDistance)) return;
        var origin = Native.Bounds(this).Location;
        Release();
        DraggedOut?.Invoke(at, new(start.X - origin.X, start.Y - origin.Y));
    }

    /// Inside this window (a popup's content isn't), not in the session list or the scroll bar, nothing with the hand cursor.
    internal bool Draggable(DependencyObject? node)
    {
        for (; node is not null; node = node is Visual ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
        {
            if (node == this) return true;
            if (node is SessionList or ScrollBar || node is FrameworkElement element && element.Cursor == Cursors.Hand) return false;
        }
        return false;
    }
}

/// "Open as window" (the mac "패널로 열기"): the same dashboard in a normal window whose session list fills the height. It comes
/// back where the last one closed (§4.2).
sealed class DashboardWindow : Window
{
    /// The last bounds while neither minimized nor maximized, in physical pixels; saved on close.
    Drawing.Rectangle? normal;
    internal Dashboard Dashboard { get; private set; } = null!;

    internal DashboardWindow(DashboardActions actions, SettingsStore store)
    {
        Title = "TokenCat";
        ResizeMode = ResizeMode.CanResize;
        // 420 DIP of content at a fixed width (the frame adds its own); the height is the person's.
        SizeToContent = SizeToContent.Width;
        Height = 560;
        MinHeight = 510;
        SourceInitialized += (_, _) => Native.StyleWindow(this, round: false);
        Loaded += (_, _) => MinWidth = MaxWidth = ActualWidth;
        LocationChanged += (_, _) => Remember();
        SizeChanged += (_, _) => Remember();
        Closing += (_, _) => { if (normal is { } bounds) DashboardBounds.Save(store, bounds); };
        Rebuild(actions);
        System.Windows.Automation.AutomationProperties.SetName(this, Loc("TokenCat 상세 화면", "TokenCat dashboard"));
        if (DashboardBounds.Saved(store, Forms.Screen.AllScreens.Select(screen => screen.WorkingArea)) is not { } saved) return;
        // Onto its monitor first, so the height converts at that DPI; then the spot again, in case the DPI change moved it.
        new WindowInteropHelper(this).EnsureHandle();
        Native.Move(this, saved.Location);
        Height = Native.Dips(this, saved.Height);
        Native.Move(this, saved.Location);
    }

    internal void Rebuild(DashboardActions actions)
    {
        Dashboard = new Dashboard(actions, panel: true);
        Content = Dashboard;
        Background = Theme.Brush(Theme.Background);
        if (IsLoaded) Native.StyleWindow(this, round: false);
    }

    void Remember()
    {
        if (Native.Restored(this)) normal = Native.Bounds(this);
    }

    /// Before it shows for a drag out of the flyout: the point grabbed `grab` from the flyout's top-left goes under `cursor`.
    /// The first move puts it on the pointer's monitor, so the frame is measured at that DPI. A point lower than this window is
    /// tall (a long flyout's footer) keeps the pointer 12 DIP inside its bottom edge (the bottom border is as wide as the left one).
    internal void Follow(Drawing.Point cursor, Drawing.Point grab)
    {
        new WindowInteropHelper(this).EnsureHandle();
        Native.Move(this, cursor);
        var frame = Native.Bounds(this);
        var client = Native.ClientOrigin(this);
        int left = client.X - frame.X, top = client.Y - frame.Y;
        var y = Math.Min(grab.Y, frame.Height - top - left - Native.Pixels(this, 12));
        Native.Move(this, new(cursor.X - grab.X - left, cursor.Y - y - top));
    }
}
