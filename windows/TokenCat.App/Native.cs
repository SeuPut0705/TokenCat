using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace TokenCat;

/// The Win32 calls the shell needs (DESIGN §2.5, §2.9, §4.2, §7.6, §7.7).
static class Native
{
    public const int ASFW_ANY = -1;
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string className, string? windowName);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr process, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int processId);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

    struct Rect { public int Left, Top, Right, Bottom; }
    const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    public struct MemoryStatus
    {
        public uint Length, MemoryLoad;
        public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        public static MemoryStatus Create() => new() { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
    }

    /// §7.7: a WinExe has no console. Attach to the parent's only when stdout is not already usable (a pipe or file in CI).
    /// A redirected stdout gets UTF-8, so Korean survives Git Bash and log files.
    public static void UseParentConsole()
    {
        var handle = GetStdHandle(-11);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) AttachConsole(-1);
        else Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true });
    }

    /// The taskbar's DPI (the tray icon lives there), else the system DPI.
    public static uint TaskbarDpi()
    {
        var taskbar = FindWindowW("Shell_TrayWnd", null);
        var dpi = taskbar == IntPtr.Zero ? 0 : GetDpiForWindow(taskbar);
        return dpi == 0 ? GetDpiForSystem() : dpi;
    }

    /// SM_CXSMICON at `dpi`: 16/20/24/28/32 at 100–200 %.
    public static int SmallIconSize(uint dpi) => Math.Max(16, GetSystemMetricsForDpi(49, dpi));

    /// GR_GDIOBJECTS + GR_USEROBJECTS of this process.
    public static (uint Gdi, uint User) GuiResources()
    {
        var process = System.Diagnostics.Process.GetCurrentProcess().Handle;
        return (GetGuiResources(process, 0), GetGuiResources(process, 1));
    }

    /// An icon from `size × size` BGRA. The caller owns the HICON: dispose the Icon, then DestroyIcon(Handle).
    public static Drawing.Icon IconFromBgra(byte[] bgra, int size)
    {
        var handle = GCHandle.Alloc(bgra, GCHandleType.Pinned);
        try
        {
            using var bitmap = new Drawing.Bitmap(size, size, size * 4, Drawing.Imaging.PixelFormat.Format32bppArgb, handle.AddrOfPinnedObject());
            return Drawing.Icon.FromHandle(bitmap.GetHicon());
        }
        finally { handle.Free(); }
    }

    /// Windows 11 rounded corners (DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND) and the dark title bar
    /// (DWMWA_USE_IMMERSIVE_DARK_MODE). Both are ignored where unsupported.
    public static void StyleWindow(Window window, bool round)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        int dark = Theme.Dark ? 1 : 0, corner = 2;
        DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
        if (round) DwmSetWindowAttribute(hwnd, 33, ref corner, sizeof(int));
    }

    /// Physical pixels throughout (PerMonitorV2): move onto the anchor's monitor first so WPF rescales for its DPI, then
    /// measure and clamp into that monitor's working area (which excludes the taskbar on any edge), above/centred on the anchor.
    /// `onto: false` only re-clamps a window already on the anchor's monitor (its size changed).
    public static void Place(Window window, Drawing.Point anchor, bool onto = true)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        if (onto) SetWindowPos(hwnd, IntPtr.Zero, anchor.X, anchor.Y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        window.UpdateLayout();
        GetWindowRect(hwnd, out var r);
        int width = r.Right - r.Left, height = r.Bottom - r.Top, margin = (int)(12 * GetDpiForWindow(hwnd) / 96);
        var area = Forms.Screen.FromPoint(anchor).WorkingArea;
        int x = Math.Clamp(anchor.X - width / 2, area.Left + margin, Math.Max(area.Left + margin, area.Right - margin - width));
        int y = Math.Clamp(anchor.Y - height, area.Top + margin, Math.Max(area.Top + margin, area.Bottom - margin - height));
        SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    /// The working-area height of the anchor's monitor in the window's DIPs (the flyout's MaxHeight).
    public static double WorkingHeight(Window window, Drawing.Point anchor)
    {
        var dpi = window.IsLoaded ? System.Windows.Media.VisualTreeHelper.GetDpi(window).DpiScaleY : TaskbarDpi() / 96.0;
        return Forms.Screen.FromPoint(anchor).WorkingArea.Height / dpi;
    }
}
