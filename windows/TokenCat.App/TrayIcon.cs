using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace TokenCat;

/// The notification-area icon (DESIGN §4.1): TrayFrame pixels at exactly SM_CXSMICON for the taskbar's DPI, one HICON alive
/// at a time. Below 30 px the cat head stands in for the body (head + 1 art-px bob).
sealed class TrayIcon : IDisposable
{
    readonly Forms.NotifyIcon icon = new() { Text = "TokenCat" };
    Drawing.Icon? current;
    object? drawn;
    bool lightTaskbar;
    public int Size { get; private set; }

    public TrayIcon(Forms.ContextMenuStrip menu)
    {
        icon.ContextMenuStrip = menu;
        Resize();
    }

    /// Left button only: WinForms raises Click and MouseClick for the right button too (§2.5).
    public void OnLeftClick(Action action) => icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) action(); };

    public void OnBalloonClick(Action action) => icon.BalloonTipClicked += (_, _) => action();

    public bool Visible { set => icon.Visible = value; }

    /// Re-read after DPI, display or theme changes (not per frame: the animation can run at 14 fps).
    public void Resize()
    {
        Size = Native.SmallIconSize(Native.TaskbarDpi());
        lightTaskbar = Theme.TaskbarUsesLightTheme();
    }

    /// A new HICON only when the drawn frame changes.
    public void Render(RunnerCharacter character, RunnerPose pose, int frame, int? fxStep, StateDot dot)
    {
        var key = (Size, lightTaskbar, character, pose, frame, fxStep, dot);
        if (Equals(key, drawn)) return;
        drawn = key;
        SetIcon(Native.IconFromBgra(Pixels(Size, character, pose, frame, fxStep, dot, lightTaskbar), Size));
    }

    /// Body at ≥ 30 px (`k = N / 30` of the @1x sheet), else the cat head chosen by HeadScale.
    public static byte[] Pixels(int size, RunnerCharacter character, RunnerPose pose, int frame, int? fxStep, StateDot dot, bool lightTaskbar)
    {
        if (TrayFrame.BodyScale(size) is not null)
        {
            var art = Sprites.Art(character);
            return TrayFrame.Body(art.Sheet!, pose, frame, fxStep is null ? null : art.Fx.GetValueOrDefault(pose), fxStep ?? 0, size, dot, lightTaskbar);
        }
        var (head, bob) = TrayFrame.HeadFor(pose, frame);
        return TrayFrame.Head(Sprites.Sheet(Sprites.HeadName(head, TrayFrame.HeadScale(size))), bob,
            fxStep is null ? null : Sprites.Art(RunnerCharacter.Cat).Fx.GetValueOrDefault(pose), fxStep ?? 0, size, dot, lightTaskbar);
    }

    /// Assign the new icon, then dispose the old one and destroy its HICON (Icon.FromHandle doesn't own it).
    public void SetIcon(Drawing.Icon next)
    {
        var old = current;
        icon.Icon = next;
        current = next;
        Release(old);
    }

    public static void Release(Drawing.Icon? old)
    {
        if (old is null) return;
        var handle = old.Handle;
        old.Dispose();
        Native.DestroyIcon(handle);
    }

    /// NotifyIcon.Text must stay under 128 characters: whole lines while they fit.
    public string Tooltip
    {
        set
        {
            var text = Truncate(value, 127);
            if (icon.Text != text) icon.Text = text;
        }
    }

    public static string Truncate(string text, int limit)
    {
        if (text.Length <= limit) return text;
        var lines = text.Split('\n');
        var kept = lines[0].Length <= limit ? lines[0] : lines[0][..limit];
        foreach (var line in lines.Skip(1))
        {
            if (kept.Length + 1 + line.Length > limit) break;
            kept += "\n" + line;
        }
        return kept;
    }

    /// A balloon (Windows shows it as a toast). The text must not be empty.
    public void Balloon(string title, string text) =>
        icon.ShowBalloonTip(10_000, title, string.IsNullOrWhiteSpace(text) ? title : text, Forms.ToolTipIcon.None);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        Release(current);
        current = null;
    }
}

/// WinForms context menus (they follow the system dark mode with SetColorMode and keep keyboard navigation, §2.5).
sealed class MenuBuilder(Forms.ToolStripItemCollection items, List<IDisposable> owned)
{
    public Forms.ToolStripMenuItem Add(string title, Action? click, bool enabled = true, bool check = false, Drawing.Image? image = null)
    {
        var item = new Forms.ToolStripMenuItem(title) { Enabled = enabled, Checked = check, Image = image };
        if (image is not null) owned.Add(image);
        if (click is not null) item.Click += (_, _) => click();
        items.Add(item);
        return item;
    }

    public void Separator() => items.Add(new Forms.ToolStripSeparator());

    public MenuBuilder Sub(string title)
    {
        var item = new Forms.ToolStripMenuItem(title);
        items.Add(item);
        return new MenuBuilder(item.DropDownItems, owned);
    }

    /// A state colour square for a session row (§4.3).
    public static Drawing.Image Square(System.Windows.Media.Color color)
    {
        var bitmap = new Drawing.Bitmap(16, 16);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        using var brush = new Drawing.SolidBrush(Drawing.Color.FromArgb(color.A, color.R, color.G, color.B));
        graphics.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
        graphics.FillEllipse(brush, 3, 3, 10, 10);
        return bitmap;
    }
}

static class Menus
{
    /// A menu from the flyout is open: its window must not hide on the deactivation the menu may cause.
    public static bool IsOpen { get; private set; }
    public static event Action? Closed;

    /// Rebuilds `menu` in place (the tray menu, built at open like the mac quick menu).
    public static void Fill(Forms.ContextMenuStrip menu, Action<MenuBuilder> build)
    {
        if (menu.Tag is List<IDisposable> previous) previous.ForEach(item => item.Dispose());
        var owned = new List<IDisposable>();
        menu.Tag = owned;
        // Clear() alone keeps a shown submenu's dropdown window alive: dispose the old items (and their dropdowns).
        var old = menu.Items.Cast<Forms.ToolStripItem>().ToArray();
        menu.Items.Clear();
        foreach (var item in old) item.Dispose();
        build(new MenuBuilder(menu.Items, owned));
    }

    /// Under `anchor` (a WPF element), in physical pixels.
    public static void Show(System.Windows.FrameworkElement anchor, Action<MenuBuilder> build)
    {
        var point = anchor.PointToScreen(new System.Windows.Point(0, anchor.ActualHeight));
        Open(build, new Drawing.Point((int)point.X, (int)point.Y), null);
    }

    public static void ShowAtCursor(Action<MenuBuilder> build, Action? closed = null) => Open(build, Forms.Cursor.Position, closed);

    static void Open(Action<MenuBuilder> build, Drawing.Point at, Action? closed)
    {
        var menu = new Forms.ContextMenuStrip();
        Fill(menu, build);
        IsOpen = true;
        menu.Closed += (_, _) =>
        {
            IsOpen = false;
            // After the clicked item's handler ran.
            System.Windows.Threading.Dispatcher.CurrentDispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
            {
                if (menu.Tag is List<IDisposable> owned) owned.ForEach(item => item.Dispose());
                menu.Dispose();
                closed?.Invoke();
                Closed?.Invoke();
            });
        };
        menu.Show(at);
    }
}
