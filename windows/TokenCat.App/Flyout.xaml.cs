using System.Windows;
using static TokenCat.Lang;

namespace TokenCat;

/// The tray flyout window; the shell owns showing, placement and hiding (§4.2).
public partial class Flyout : Window
{
    internal Dashboard Dashboard { get; private set; } = null!;

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
}

/// "Open as window" (the mac "패널로 열기"): the same dashboard in a normal window whose session list fills the height.
sealed class DashboardWindow : Window
{
    internal Dashboard Dashboard { get; private set; } = null!;

    internal DashboardWindow(DashboardActions actions)
    {
        Title = "TokenCat";
        ResizeMode = ResizeMode.CanResize;
        // 420 DIP of content at a fixed width (the frame adds its own); the height is the person's.
        SizeToContent = SizeToContent.Width;
        Height = 560;
        MinHeight = 510;
        SourceInitialized += (_, _) => Native.StyleWindow(this, round: false);
        Loaded += (_, _) => MinWidth = MaxWidth = ActualWidth;
        Rebuild(actions);
        System.Windows.Automation.AutomationProperties.SetName(this, Loc("TokenCat 대시보드", "TokenCat dashboard"));
    }

    internal void Rebuild(DashboardActions actions)
    {
        Dashboard = new Dashboard(actions, panel: true);
        Content = Dashboard;
        Background = Theme.Brush(Theme.Background);
        if (IsLoaded) Native.StyleWindow(this, round: false);
    }
}
