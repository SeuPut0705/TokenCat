using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using TokenCat;
using static TokenCat.Lang;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

// WP0 skeleton, handed to WP5 (which owns this folder except the csproj, app.manifest and TokenCat.ico): a tray icon and an
// empty flyout with the spike's mechanics (DESIGN §2.5, §2.9, §4.2). CLI dispatch, the live icon and the dashboard come with WP5.
static class Program
{
    [STAThread]
    static int Main()
    {
        // Swift's interpolation and String(format:) ignore the user's locale; culture-specific text names its culture.
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

        // One per user session. A second launch lets the first take the foreground (only the launched process may grant
        // it), signals it to open the flyout and exits.
        using var mutex = new Mutex(true, @"Local\dev.seuput.TokenCat", out var first);
        using var openRequest = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\dev.seuput.TokenCat.open");
        if (!first)
        {
            Native.AllowSetForegroundWindow(Native.ASFW_ANY);
            openRequest.Set();
            return 0;
        }

        Forms.Application.SetColorMode(Forms.SystemColorMode.System);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var flyout = new Flyout();
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Loc("TokenCat 종료", "Quit TokenCat"), null, (_, _) => app.Shutdown());
        var tray = new Forms.NotifyIcon { Icon = Native.HeadIcon(), Text = "TokenCat", ContextMenuStrip = menu, Visible = true };

        // Click also fires for the right button, so only a left MouseClick toggles. Clicking the icon while the flyout is open
        // first deactivates (hides) it; a click within 300 ms of that hide must not reopen it.
        var hiddenAt = DateTime.MinValue;
        flyout.Deactivated += (_, _) => { flyout.Hide(); hiddenAt = DateTime.UtcNow; };
        flyout.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) flyout.Hide(); };
        tray.MouseClick += (_, e) =>
        {
            if (e.Button != Forms.MouseButtons.Left || DateTime.UtcNow - hiddenAt < TimeSpan.FromMilliseconds(300)) return;
            Native.ShowAt(flyout, Forms.Cursor.Position);
        };
        ThreadPool.RegisterWaitForSingleObject(openRequest, (_, _) => app.Dispatcher.BeginInvoke(() =>
        {
            var area = Forms.Screen.PrimaryScreen!.WorkingArea;
            Native.ShowAt(flyout, new Drawing.Point(area.Right, area.Bottom));
        }), null, -1, false);
        app.Exit += (_, _) => { tray.Visible = false; tray.Dispose(); };
        return app.Run();
    }
}

static class Native
{
    public const int ASFW_ANY = -1;
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    struct Rect { public int Left, Top, Right, Bottom; }
    const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4;

    /// The cat head @2x on a 32 px canvas; Windows scales it to the tray size.
    /// ponytail: one static HICON for the process lifetime. WP5's tray renders TrayFrame pixels at the exact size and
    /// destroys each HICON it replaces.
    public static Drawing.Icon HeadIcon()
    {
        using var stream = typeof(Native).Assembly.GetManifestResourceStream("app-head-normal@2x.png")!;
        using var head = new Drawing.Bitmap(stream);
        using var canvas = new Drawing.Bitmap(32, 32);
        using (var graphics = Drawing.Graphics.FromImage(canvas))
        {
            graphics.InterpolationMode = Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = Drawing.Drawing2D.PixelOffsetMode.Half;
            graphics.DrawImage(head, (32 - head.Width) / 2, (32 - head.Height) / 2, head.Width, head.Height);
        }
        return Drawing.Icon.FromHandle(canvas.GetHicon());
    }

    /// Physical pixels throughout (PerMonitorV2): move onto the anchor's monitor first so WPF rescales for its DPI, then
    /// measure and clamp into that monitor's working area (which excludes the taskbar on any edge), above/left of the anchor.
    public static void ShowAt(Window window, Drawing.Point anchor)
    {
        window.Show();
        window.Activate();
        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        SetWindowPos(hwnd, IntPtr.Zero, anchor.X, anchor.Y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
        window.UpdateLayout();
        GetWindowRect(hwnd, out var r);
        int width = r.Right - r.Left, height = r.Bottom - r.Top, margin = (int)(12 * GetDpiForWindow(hwnd) / 96);
        var area = Forms.Screen.FromPoint(anchor).WorkingArea;
        int x = Math.Clamp(anchor.X - width / 2, area.Left + margin, Math.Max(area.Left + margin, area.Right - margin - width));
        int y = Math.Clamp(anchor.Y - height, area.Top + margin, Math.Max(area.Top + margin, area.Bottom - margin - height));
        SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    }
}
