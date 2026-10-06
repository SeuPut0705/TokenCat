using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using static TokenCat.Lang;

namespace TokenCat;

/// What every row needs from the list: the clock, the shared column rules and the selection.
sealed record RowContext(DateTimeOffset Now, IReadOnlySet<TokenSource> Restart, bool ShowsSpeed, IReadOnlySet<string> SharedProjects,
    string? SelectedId, string? DetailId, Action<string> Tap, Action<TokenReading> Menu)
{
    public double DetailHeight(SessionRowItem item) => DetailId == item.Id ? SessionPresentation.DetailHeight(item.Reading, item.State) : 0;
    public SpeedSlot? Speed(SessionRowItem item) => SessionPresentation.SpeedCell(item.Reading, item.State, Now, ShowsSpeed, Restart);
    public bool ShowsID(TokenReading reading) => reading.Project is { } project && SharedProjects.Contains(project);

    /// One line of help; a client waiting for a restart adds why its speed is missing.
    public string Help(TokenReading reading) => Loc("클릭: 상세 · 우클릭: 메뉴", "Click: details · Right-click: menu")
        + (Restart.Contains(reading.Source) ? Loc($"\n{reading.Source.Title}를 새로 실행하면 속도가 표시됩니다", $"\nRestart {reading.Source.Title} to show speed") : "");
}

/// The session list (S-1–S-8): a grow-only viewport while open, rows kept by id, ↑↓/Enter/Ctrl+C, order frozen under the pointer.
sealed class SessionList : Border
{
    readonly Dashboard owner;
    readonly bool panel, snapshot;
    readonly ScrollViewer scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = true };
    readonly StackPanel entries = new();
    readonly Dictionary<string, FrameworkElement> cache = [];
    readonly Border fallback = new();
    object? fallbackKey;
    SessionListModel shown = SessionListModel.Empty;
    IReadOnlyList<string> navigation = [];
    bool showOlder, pointerInside, menuOpen;
    string? selectedId, detailId, focusAnchor;
    int selectedIndex;
    double viewportFloor;
    IReadOnlyList<string>? frozenOrder;

    public bool Expanded { get; private set; }

    public SessionList(Dashboard owner, bool panel, bool snapshot, string? selection, string? detail, bool expanded)
    {
        this.owner = owner;
        Expanded = expanded;
        this.panel = panel;
        this.snapshot = snapshot;
        selectedId = selection;
        detailId = detail;
        scroll.Content = entries;
        scroll.FocusVisualStyle = null;
        var host = new Grid();
        host.Children.Add(fallback);
        host.Children.Add(scroll);
        var container = Ui.Container(host);
        Child = container;
        System.Windows.Automation.AutomationProperties.SetName(scroll, Loc("세션 목록", "Session list"));
        scroll.ToolTip = Loc("↑↓ 이동 · Enter 상세 · Ctrl+C ID 복사", "↑↓ move · Enter details · Ctrl+C copy ID");
        ToolTipService.SetInitialShowDelay(scroll, 1500);
        scroll.PreviewKeyDown += OnKey;
        scroll.MouseEnter += (_, _) => { pointerInside = true; UpdateFreeze(); };
        scroll.MouseLeave += (_, _) => { pointerInside = false; UpdateFreeze(); };
    }

    public SessionListModel Model(DashboardInput input)
    {
        var state = input.State;
        return Expanded ? SessionListModel.Make(state.Tokens, state.Now, true, state.TelemetryRestartNeeded) : state.Sessions;
    }

    void Refresh() { if (owner.Input is { } input) owner.Show(input); }

    public void Opened()
    {
        frozenOrder = null;
        pointerInside = menuOpen = false;
        showOlder = false;
        detailId = selectedId = null;
        viewportFloor = shown.Viewport(false);
        Refresh();
        if (!snapshot) Dispatcher.BeginInvoke(() => Keyboard.Focus(scroll), System.Windows.Threading.DispatcherPriority.Input);
    }

    public void ToggleExpanded()
    {
        Expanded = !Expanded;
        viewportFloor = 0;
        if (frozenOrder is not null && owner.Input is { } input) frozenOrder = [.. Model(input).Blocks.Select(block => block.Id)];
        Refresh();
        // A focused group folded into "이전" opens that section so the scroll can reach it.
        showOlder = focusAnchor is { } id && shown.Blocks.FirstOrDefault(block => block.Id == id) is { Older: true };
        var anchor = focusAnchor;
        focusAnchor = null;
        Refresh();
        Dispatcher.BeginInvoke(() =>
        {
            if (anchor is not null && cache.GetValueOrDefault(anchor) is { } target) target.BringIntoView();
            else scroll.ScrollToTop();
        });
    }

    /// A notification or quick-menu request: select that group and scroll to it, once.
    public void Focus(string id)
    {
        frozenOrder = null;
        if (!shown.Blocks.Any(block => block.Id == id) && !Expanded) { focusAnchor = id; ToggleExpanded(); }
        if (shown.Blocks.FirstOrDefault(block => block.Id == id) is not { } found) return;
        showOlder = showOlder || found.Older;
        Refresh();
        Select(id);
        if (!snapshot) Keyboard.Focus(scroll);
    }

    public void Show(DashboardInput input, SessionListModel model)
    {
        var state = input.State;
        var display = frozenOrder is { } order ? model.Reordered(order) : model;
        shown = display;
        if (state.TokensSampledAt is null) { ShowFallback("skeleton", Skeleton); return; }
        if (display.Blocks.Count == 0) { ShowFallback(("empty", state.LogFoldersFound), () => Empty(state.LogFoldersFound)); return; }
        fallback.Visibility = Visibility.Collapsed;
        fallbackKey = null;
        scroll.Visibility = Visibility.Visible;

        var detailExtra = detailId is { } open && display.Item(open) is { } item ? SessionPresentation.DetailHeight(item.Reading, item.State) : 0;
        var goal = Math.Min(SessionListModel.MaxViewport, display.Viewport(showOlder) + detailExtra);
        if (viewportFloor == 0) viewportFloor = goal;
        viewportFloor = Math.Max(viewportFloor, goal);
        var height = Math.Min(SessionListModel.MaxViewport, Math.Max(goal, viewportFloor));
        var overflows = panel || display.Height(showOlder) + detailExtra > height + 0.5;
        if (panel) { scroll.Height = double.NaN; scroll.MinHeight = Math.Min(height, SessionRowItem.LiveDetailHeight); }
        else scroll.Height = height;
        // A short fade at the cut says the list continues.
        scroll.OpacityMask = overflows && height > 14 ? new LinearGradientBrush(
            [new GradientStop(Colors.Black, 0), new GradientStop(Colors.Black, 1 - 14 / Math.Max(height, scroll.ActualHeight)), new GradientStop(Color.FromArgb(38, 0, 0, 0), 1)], 90) : null;

        var context = new RowContext(state.Now, state.TelemetryRestartNeeded, display.ShowsSpeedColumn, display.SharedProjects(showOlder),
            selectedId, detailId, Tap, OpenMenu);
        var items = new List<Reconcile.Entry>();
        foreach (var entry in display.Entries(showOlder))
        {
            switch (entry)
            {
                case SessionListEntry.Divider divider:
                    items.Add(Reconcile.Item("divider:" + divider.Key, () => new Border
                    {
                        Height = SessionListModel.DividerHeight,
                        Child = new Border { Height = 1, Background = Theme.Brush(Theme.Hairline), Margin = new Thickness(Dashboard.TextX, 0, Dashboard.Inset, 0), VerticalAlignment = VerticalAlignment.Center },
                    }, (Border _) => { }));
                    break;
                case SessionListEntry.Caption caption:
                    items.Add(Reconcile.Item("caption:" + caption.Anchor + caption.Text, () => Caption(caption.Text, caption.Rule), (Border _) => { }));
                    break;
                case SessionListEntry.Older older:
                    items.Add(Reconcile.Item(SessionListModel.OlderID, () => new OlderRow(() => { showOlder = true; Refresh(); }),
                        (OlderRow row) => row.Update(older.Count, selectedId == SessionListModel.OlderID)));
                    break;
                case SessionListEntry.Block block:
                    items.Add(Reconcile.Item("block:" + block.Value.Id, () => new BlockView(() => Expand(block.Value.Id)),
                        (BlockView view) => view.Update(block.Value, context)));
                    break;
            }
        }
        // Lets the last row scroll clear of the fade.
        if (overflows && !snapshot) items.Add(Reconcile.Item("end", () => new Border { Height = 10 }, (Border _) => { }));
        Reconcile.Panel(entries, cache, items);
        KeepSelection(display.Navigation(showOlder));
    }

    void ShowFallback(object key, Func<FrameworkElement> build)
    {
        scroll.Visibility = Visibility.Collapsed;
        fallback.Visibility = Visibility.Visible;
        if (Equals(key, fallbackKey)) return;
        fallbackKey = key;
        fallback.Child = build();
    }

    void Expand(string id)
    {
        focusAnchor = id;
        if (!Expanded) ToggleExpanded();
    }

    void Tap(string id)
    {
        detailId = detailId == id ? null : id;
        if (selectedId is not null) selectedId = id;
        if (!snapshot) Keyboard.Focus(scroll);
        Refresh();
        if (detailId is not null) Dispatcher.BeginInvoke(() => cache.GetValueOrDefault("block:" + BlockOf(id))?.BringIntoView());
    }

    /// The group holding the open detail or the keyboard selection (a flyout dragged out keeps it).
    public string? SelectedGroup => (detailId ?? selectedId) is { } id && id != SessionListModel.OlderID ? BlockOf(id) : null;

    string BlockOf(string id) => shown.Blocks.FirstOrDefault(block => block.Id == id || block.Children.Any(child => child.Id == id) || block.MoreID == id)?.Id ?? id;

    void OpenMenu(TokenReading reading)
    {
        var actions = SessionPresentation.RowActions(reading, AppPaths.Home);
        if (actions.Count == 0) return;
        menuOpen = true;
        UpdateFreeze();
        Menus.ShowAtCursor(menu =>
        {
            var copies = actions.Where(action => !action.IsReveal).ToList();
            var reveals = actions.Where(action => action.IsReveal).ToList();
            foreach (var action in copies) menu.Add(action.Title, () => Shell.Copy(action.Copy!));
            if (copies.Count > 0 && reveals.Count > 0) menu.Separator();
            foreach (var action in reveals) menu.Add(action.Title, () => Shell.Reveal(action.Reveal!));
        }, () => { menuOpen = false; UpdateFreeze(); });
    }

    /// While the pointer is over the list or a row menu is open, blocks keep their order (S-8).
    void UpdateFreeze()
    {
        var freeze = !snapshot && (pointerInside || menuOpen);
        if (freeze && frozenOrder is null) frozenOrder = [.. shown.Blocks.Select(block => block.Id)];
        else if (!freeze && frozenOrder is not null) { frozenOrder = null; Refresh(); }
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        // Shift+F10 arrives as a system key; other system keys (Alt+Space: the window menu) are left alone.
        var key = e.Key == Key.System && e.SystemKey == Key.F10 ? Key.F10 : e.Key;
        switch (key)
        {
            case Key.Up or Key.Down:
                Move(key == Key.Up ? -1 : 1);
                e.Handled = true;
                break;
            case Key.Enter or Key.Space when selectedId is not null:
                Activate();
                e.Handled = true;
                break;
            case Key.C when Keyboard.Modifiers == ModifierKeys.Control:
                if (selectedId is { } id && shown.Item(id)?.Reading is { } reading
                    && (reading.IsSubagent ? reading.AgentID ?? reading.SessionID : reading.SessionID) is { } text) Shell.Copy(text);
                e.Handled = true;
                break;
            // The row menu from the keyboard (Apps key, Shift+F10), at the pointer like a right-click.
            case Key.Apps or Key.F10 when (key == Key.Apps || Keyboard.Modifiers == ModifierKeys.Shift)
                                          && selectedId is { } row && shown.Item(row)?.Reading is { } target:
                OpenMenu(target);
                e.Handled = true;
                break;
        }
    }

    void Move(int delta)
    {
        if (navigation.Count == 0) return;
        var index = selectedId is { } id ? navigation.ToList().IndexOf(id) : -1;
        if (index < 0) Select(shown.StartRow(showOlder) ?? navigation[0]);
        else Select(navigation[Math.Clamp(index + delta, 0, navigation.Count - 1)]);
    }

    void Select(string id)
    {
        selectedId = id;
        selectedIndex = Math.Max(0, navigation.ToList().IndexOf(id));
        Refresh();
        Dispatcher.BeginInvoke(() => cache.GetValueOrDefault("block:" + BlockOf(id))?.BringIntoView());
        // Keyboard focus stays on the list, so Narrator hears the newly selected row only from this notification.
        if (shown.Item(id) is { } item)
            UIElementAutomationPeer.CreatePeerForElement(scroll)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted,
                AutomationNotificationProcessing.MostRecent, SessionPresentation.SpokenLabel(item.Reading, item.State), "tokencat.selection");
    }

    void Activate()
    {
        if (selectedId is not { } id) return;
        if (id == SessionListModel.OlderID) { showOlder = true; Refresh(); }
        else if (id.StartsWith("more:", StringComparison.Ordinal)) Expand(id[5..]);
        else Tap(id);
    }

    /// Keeps the selection by id through reorders; a vanished row hands it to the nearest position.
    void KeepSelection(IReadOnlyList<string> rows)
    {
        navigation = rows;
        if (detailId is { } open && !rows.Contains(open)) detailId = null;
        if (selectedId is not { } id) return;
        var index = rows.ToList().IndexOf(id);
        if (index >= 0) { selectedIndex = index; return; }
        selectedId = rows.Count == 0 ? null : rows[Math.Min(selectedIndex, rows.Count - 1)];
    }

    static Border Caption(string title, bool rule)
    {
        var text = Ui.Text(title, Font.Caption, Theme.Secondary);
        text.VerticalAlignment = VerticalAlignment.Bottom;
        text.Margin = new Thickness(Dashboard.GlyphX, 0, 0, 4);
        var grid = new Grid();
        grid.Children.Add(text);
        if (rule) grid.Children.Add(new Border { Height = 1, VerticalAlignment = VerticalAlignment.Top, Background = Theme.Brush(Theme.Hairline) });
        return new Border { Height = SessionListModel.CaptionHeight, Child = grid };
    }

    /// Three 28 DIP placeholder rows while the first sample is read (O-2); no spinner, no shimmer.
    static FrameworkElement Skeleton()
    {
        var stack = new StackPanel();
        for (var i = 0; i < 3; i++)
        {
            var row = new Grid { Height = 28, Margin = new Thickness(Dashboard.TextX, 0, Dashboard.Inset, 0) };
            row.Children.Add(new Border { Width = 140, Height = 10, CornerRadius = new CornerRadius(3), Background = Theme.Brush(Theme.Primary(0.05)), HorizontalAlignment = HorizontalAlignment.Left });
            row.Children.Add(new Border { Width = 64, Height = 10, CornerRadius = new CornerRadius(3), Background = Theme.Brush(Theme.Primary(0.05)), HorizontalAlignment = HorizontalAlignment.Right });
            stack.Children.Add(row);
        }
        System.Windows.Automation.AutomationProperties.SetName(stack, Loc("세션 목록", "Session list") + ", " + Loc("기록 확인 중", "Reading records"));
        return stack;
    }

    static string WebNote => Loc("Claude 웹·데스크톱 채팅은 수집하지 않습니다", "Claude web and desktop chats aren't collected");
    static string WslNote => Loc("WSL 세션은 아직 추적하지 않습니다", "WSL sessions aren't tracked yet");

    /// No sessions yet, or no log folders (O-3). Folder existence comes from the monitor, never from here.
    FrameworkElement Empty(bool foldersFound)
    {
        var stack = new StackPanel { MinHeight = 120, Margin = new Thickness(0, Dashboard.InsetVertical, 0, Dashboard.InsetVertical) };
        var sprite = Sprites.Sprite(RunnerCharacter.Cat, foldersFound ? RunnerPose.Sleep : RunnerPose.Sit, 0, 2, foldersFound ? 2 : null);
        sprite.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(sprite);
        TextBlock Centered(TextBlock text) { text.TextAlignment = TextAlignment.Center; text.HorizontalAlignment = HorizontalAlignment.Center; text.TextWrapping = TextWrapping.Wrap; return text; }
        // The clients TokenCat reads (providers with a format): "Codex·Claude Code" / "Codex or Claude Code" / "A, B or C".
        var read = TokenProvider.All.Where(provider => provider.Format is not null).ToList();
        var titles = read.Select(provider => provider.Source.Title).ToList();
        var names = Loc(string.Join("·", titles),
            titles.Count < 2 ? string.Concat(titles) : string.Join(", ", titles.SkipLast(1)) + " or " + titles[^1]);
        var title = Centered(Ui.Text(foldersFound ? Loc($"아직 {names} 세션 기록이 없습니다", $"No {names} sessions yet")
            : Loc($"{names} 기록 폴더를 찾지 못했습니다", $"Couldn't find {names} log folders"), Font.BodyMedium));
        title.Margin = new Thickness(0, 8, 0, 4);
        stack.Children.Add(title);
        if (foldersFound)
        {
            stack.Children.Add(Centered(Ui.Text(Loc("새 세션을 시작하면 여기에 표시됩니다", "New sessions appear here when you start them"), Font.Meta, Theme.Secondary)));
            stack.Children.Add(Centered(Ui.Text(WebNote, Font.Meta, Theme.Secondary)));
            stack.Children.Add(Centered(Ui.Text(WslNote, Font.Meta, Theme.Secondary)));
        }
        else
        {
            // Default folders, home written as %USERPROFILE% (no environment override applied).
            var folders = read.SelectMany(provider => provider.Roots("%USERPROFILE%", _ => null));
            stack.Children.Add(Centered(Ui.Text(string.Join(" · ", folders), Font.MetaMono, Theme.Secondary)));
            var again = Ui.SmallButton(Loc("다시 확인", "Check Again"), () => Recheck?.Invoke());
            again.HorizontalAlignment = HorizontalAlignment.Center;
            again.Margin = new Thickness(0, 8, 0, 0);
            stack.Children.Add(again);
            var note = Centered(Ui.Text(WebNote + "\n" + WslNote, Font.Meta, Theme.Secondary));
            note.Margin = new Thickness(0, 8, 0, 0);
            stack.Children.Add(note);
        }
        return stack;
    }

    /// "다시 확인": set by the dashboard to its RecheckLogFolders action.
    public Action? Recheck { get; set; }
}

/// Lays children out left to right at their natural width; the one marked `Shrink` takes what is left and trims.
sealed class TrimLine : Panel
{
    public static readonly DependencyProperty ShrinkProperty = DependencyProperty.RegisterAttached("Shrink", typeof(bool), typeof(TrimLine),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsParentMeasure));

    public static T Shrink<T>(T element) where T : UIElement { element.SetValue(ShrinkProperty, true); return element; }

    public TrimLine(params UIElement?[] children)
    {
        foreach (var child in children) if (child is not null) Children.Add(child);
    }

    /// A named line (the header status) reaches UI Automation with its name and help, its sentence still readable inside;
    /// an unnamed one stays transparent (a detail line's copy button is the detail's child).
    protected override AutomationPeer? OnCreateAutomationPeer() =>
        string.IsNullOrEmpty(AutomationProperties.GetName(this)) ? base.OnCreateAutomationPeer() : new FrameworkElementAutomationPeer(this);

    protected override Size MeasureOverride(Size available)
    {
        double used = 0, height = 0;
        UIElement? shrink = null;
        foreach (UIElement child in InternalChildren)
        {
            if ((bool)child.GetValue(ShrinkProperty)) { shrink = child; continue; }
            child.Measure(new Size(double.PositiveInfinity, available.Height));
            used += child.DesiredSize.Width;
            height = Math.Max(height, child.DesiredSize.Height);
        }
        if (shrink is not null)
        {
            shrink.Measure(new Size(Math.Max(0, (double.IsInfinity(available.Width) ? double.PositiveInfinity : available.Width - used)), available.Height));
            used += shrink.DesiredSize.Width;
            height = Math.Max(height, shrink.DesiredSize.Height);
        }
        return new Size(double.IsInfinity(available.Width) ? used : Math.Min(used, available.Width), height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double x = 0;
        foreach (UIElement child in InternalChildren)
        {
            var width = child.DesiredSize.Width;
            child.Arrange(new Rect(x, (final.Height - child.DesiredSize.Height) / 2, width, child.DesiredSize.Height));
            x += width;
        }
        return final;
    }
}

/// UI Automation for a panel that speaks as one element by its AutomationProperties name and help text. WPF gives Panel and
/// Border no peer, so without one their names never reach Narrator; the children are hidden, the name already says them.
sealed class LeafPeer(FrameworkElement owner, AutomationControlType type) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => type;
    protected override List<AutomationPeer>? GetChildrenCore() => null;
}

/// Hover and keyboard selection for one row: inset 4 each side, radius 6; click opens the detail, right-click the menu.
abstract class RowShell : Grid
{
    readonly Border fill = new() { CornerRadius = new CornerRadius(6), Margin = new Thickness(4, 0, 4, 0) };
    protected readonly Grid Body = new();
    bool selected;
    protected TokenReading? Reading;
    protected RowContext? Context;
    protected string? RowId;

    protected RowShell()
    {
        Background = Brushes.Transparent;
        Children.Add(fill);
        Children.Add(Body);
        MouseEnter += (_, _) => Paint();
        MouseLeave += (_, _) => Paint();
        MouseLeftButtonUp += (_, e) => { if (RowId is { } id) { Context?.Tap(id); e.Handled = true; } };
        MouseRightButtonUp += (_, e) => { if (Reading is { } reading) { Context?.Menu(reading); e.Handled = true; } };
    }

    protected void Bind(string id, TokenReading? reading, RowContext context, double height, string help, string spoken)
    {
        RowId = id;
        Reading = reading;
        Context = context;
        Height = height;
        selected = context.SelectedId == id;
        Paint();
        Ui.Help(this, help);
        System.Windows.Automation.AutomationProperties.SetName(this, spoken);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new LeafPeer(this, AutomationControlType.ListItem);

    /// The selection fill is faint (1.4:1), so the keyboard selection also gets an accent outline (at least 3:1).
    void Paint()
    {
        fill.Background = selected ? Theme.Brush(Theme.Selection) : IsMouseOver ? Theme.Brush(Theme.Hover) : null;
        fill.BorderBrush = Theme.Brush(Theme.Accent);
        fill.BorderThickness = new Thickness(selected ? 1.5 : 0);
    }
}

/// A lead row, its children, the inline details and the tree guide that joins them (S-5).
sealed class BlockView : Grid
{
    readonly Path guide = new() { StrokeThickness = 1, IsHitTestVisible = false, SnapsToDevicePixels = true };
    readonly StackPanel rows = new();
    readonly Dictionary<string, FrameworkElement> cache = [];
    readonly Action expand;

    public BlockView(Action expand)
    {
        this.expand = expand;
        guide.Stroke = Theme.Brush(Theme.Primary(0.15));
        Children.Add(guide);
        Children.Add(rows);
    }

    public void Update(SessionBlock block, RowContext context)
    {
        var items = new List<Reconcile.Entry>();
        var lead = block.Lead;
        switch (lead.Kind)
        {
            case SessionRowKind.Live:
                items.Add(Reconcile.Item("live:" + lead.Id, () => new LiveRow(), (LiveRow row) => row.Update(lead, context)));
                break;
            case SessionRowKind.Measurement:
                items.Add(Reconcile.Item("measure:" + lead.Id, () => new MeasurementRow(), (MeasurementRow row) => row.Update(lead, context)));
                break;
            default:
                // Input and retry children are running, so every one of them is in `Children`.
                var urgent = block.State is SessionDisplayState.Input or SessionDisplayState.Retrying;
                var liveChildren = urgent ? block.Children.Count(child => child.State == block.State)
                    : block.State.IsRunning ? block.RunningChildren : block.WaitingChildren;
                items.Add(Reconcile.Item("idle:" + lead.Id, () => new IdleRow(),
                    (IdleRow row) => row.Update(lead, block.State, liveChildren, context)));
                break;
        }
        if (context.DetailId == lead.Id) items.Add(Detail(lead, Dashboard.TextX));
        foreach (var child in block.Children)
        {
            items.Add(Reconcile.Item("child:" + child.Id, () => new ChildRow(), (ChildRow row) => row.Update(child, lead.Reading, context)));
            if (context.DetailId == child.Id) items.Add(Detail(child, Dashboard.ChildTextX));
        }
        if (block.MoreCount > 0)
            items.Add(Reconcile.Item("more", () => new MoreRow(expand), (MoreRow row) => row.Update(block, context)));
        Reconcile.Panel(rows, cache, items);

        // 1 DIP primary 0.15 from below the lead glyph (x = 17) to the last child or "+N 하위" row, with a 6 DIP tail to each.
        if (block.Children.Count == 0 && block.MoreCount == 0) { guide.Data = null; return; }
        var start = lead.Kind == SessionRowKind.Live ? 23.0 : 19.0;
        var y = lead.Height + context.DetailHeight(lead);
        var tails = new List<double>();
        foreach (var child in block.Children)
        {
            tails.Add(y + child.Height / 2);
            y += child.Height + context.DetailHeight(child);
        }
        if (block.MoreCount > 0) tails.Add(y + SessionListModel.MoreHeight / 2);
        var x = Dashboard.GuideX + 0.5;
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(new Point(x, start), false, false);
            g.LineTo(new Point(x, tails[^1]), true, false);
            foreach (var tail in tails)
            {
                g.BeginFigure(new Point(x, tail), false, false);
                g.LineTo(new Point(x + 6, tail), true, false);
            }
        }
        geometry.Freeze();
        guide.Data = geometry;
    }

    static Reconcile.Entry Detail(SessionRowItem item, double indent) =>
        Reconcile.Item("detail:" + item.Id, () => new DetailView(), (DetailView view) => view.Update(item, indent));
}

/// State glyph plus tool category, input kind or state on a tinted capsule.
sealed class StateChip : Border
{
    readonly GlyphView glyph = new(StateGlyphKind.Working) { Margin = new Thickness(1, 0, 5, 0) };
    readonly TextBlock text = Ui.Text("", Font.MetaMedium);

    public StateChip()
    {
        Height = 18;
        CornerRadius = new CornerRadius(9);
        Padding = new Thickness(4, 0, 6, 0);
        Child = Dashboard.Row(0, glyph, text);
        text.VerticalAlignment = VerticalAlignment.Center;
    }

    public void Update(StateGlyphKind kind, string label)
    {
        glyph.Kind = kind;
        text.Text = label;
        var color = Theme.GlyphColor(kind);
        Background = Theme.Brush(Color.FromArgb(41, color.R, color.G, color.B));
    }
}

sealed class LiveRow : RowShell
{
    readonly StateChip chip = new() { Margin = new Thickness(Dashboard.GlyphX - 4, 0, 0, 0) };
    readonly TextBlock project = TrimLine.Shrink(Ui.Text("", Font.Title));
    readonly TextBlock shortId = Ui.Text("", Font.Meta, Theme.Secondary);
    readonly TextBlock number = Ui.Line();
    readonly TextBlock client = Ui.Text("", Font.Meta, Theme.Secondary);
    readonly TextBlock trailing = Ui.Text("", Font.MetaMono);
    // 15 tall for MetaMono's descenders (a comma, a g), drawn 3 into the bottom padding so the row stays 58.
    readonly Border line3 = new() { Height = 15, Margin = new Thickness(Dashboard.GlyphX, 2, 0, -3) };
    object? line3Key;

    public LiveRow()
    {
        project.Margin = new Thickness(8, 0, 0, 0);
        shortId.Margin = new Thickness(6, 0, 0, 0);
        number.MinWidth = 86;
        number.TextAlignment = TextAlignment.Right;
        var first = Dashboard.Spread(new TrimLine(chip, project, shortId), number);
        first.Height = 18;
        var second = Dashboard.Spread(client, trailing);
        second.Height = 14;
        second.Margin = new Thickness(Dashboard.TextX, 2, 0, 0);
        var stack = new StackPanel { Margin = new Thickness(0, 5, Dashboard.Inset, 5) };
        stack.Children.Add(first);
        stack.Children.Add(second);
        stack.Children.Add(line3);
        Body.Children.Add(stack);
    }

    public void Update(SessionRowItem item, RowContext context)
    {
        var reading = item.Reading;
        var now = context.Now;
        Bind(item.Id, reading, context, item.Height, context.Help(reading), SessionPresentation.SpokenLabel(reading, item.State));
        chip.Update(GlyphView.For(item.State) ?? StateGlyphKind.Working, SessionPresentation.ChipText(item.State, reading));
        project.Text = reading.Project ?? Loc("프로젝트 미확인", "Unknown project");
        shortId.Visibility = context.ShowsID(reading) ? Visibility.Visible : Visibility.Collapsed;
        shortId.Text = SessionPresentation.ShortID(reading);

        number.Inlines.Clear();
        if (reading.CurrentTurnOutputTokens is { } output)
        {
            var quiet = output == 0 || item.State == SessionDisplayState.Waiting;
            number.Inlines.Add(Ui.Run(Format.Tokens(output), Font.Metric, quiet ? Theme.Secondary : Theme.Label));
            number.Inlines.Add(Ui.Run(" tok", Font.Micro, Theme.Secondary));
            Ui.Help(number, output == 0 ? Loc("현재 턴에서 아직 기록된 출력이 없습니다", "No output recorded in this turn yet")
                : Loc("현재 턴에서 기록된 출력 토큰", "Output tokens recorded in this turn"));
        }
        else
        {
            number.Inlines.Add(Ui.Run("—", Font.Metric, Theme.Tertiary));
            Ui.Help(number, Loc("현재 턴 시작 부분을 읽지 못해 이번 턴 누적량을 알 수 없습니다", "Couldn't read the start of this turn, so its total is unknown"));
        }

        client.Text = SessionPresentation.ClientLine(reading);
        trailing.Text = item.State switch
        {
            SessionDisplayState.Waiting => Loc("활동 ", "Active ") + Format.Age(SessionPresentation.LiveAt(reading), now),
            SessionDisplayState.Input => Loc("입력 대기 ", "Waiting for input ") + Format.Elapsed(reading.LastActivity, now),
            SessionDisplayState.Retrying => reading.Retry is { } retry ? SessionPresentation.RetryText(retry, now, false, false) : item.State.Title,
            _ => Loc("턴 ", "Turn ") + Format.Elapsed(reading.CurrentTurnStartedAt, now),
        };
        trailing.Foreground = Theme.Brush(item.State is SessionDisplayState.Input or SessionDisplayState.Retrying ? Theme.Label : Theme.Secondary);

        line3.Visibility = item.ShowsDetail ? Visibility.Visible : Visibility.Collapsed;
        if (!item.ShowsDetail) return;
        var record = SessionPresentation.LastRecord(reading);
        var contextSlot = SessionPresentation.Context(reading, now);
        var speed = context.Speed(item);
        var age = record is { } r ? SessionPresentation.RecordAge(r.At, now, false) : null;
        var fresh = record is { } f && SessionPresentation.IsFresh(f.At, now);
        var key = (record, age, fresh, contextSlot, speed);
        if (Equals(key, line3Key)) return;
        line3Key = key;
        const double room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - Dashboard.GlyphX - Dashboard.Inset;
        FrameworkElement Line(bool shortContext, bool shortSpeed, bool withAge) => Dashboard.Spread(
            record is { } last ? LastRecordLabel(last, age!, fresh, withAge) : new Border(),
            Dashboard.Row(10, contextSlot is null ? null : ContextLabel(contextSlot, shortContext), speed is null ? null : SpeedLabel(speed, shortSpeed)));
        line3.Child = Dashboard.Fit(room, () => Line(false, false, true), () => Line(false, true, true), () => Line(true, true, true), () => Line(true, true, false));
    }

    /// "+1,356 tok · 방금" with a reserved 6 DIP dot (green and primary semibold for 5 s, then secondary).
    static FrameworkElement LastRecordLabel(TokenOutputEvent record, string age, bool fresh, bool withAge)
    {
        var dot = new Border { Width = 12, Child = Dashboard.Dot(Theme.Activity), Opacity = fresh ? 1 : 0 };
        ((FrameworkElement)dot.Child).HorizontalAlignment = HorizontalAlignment.Right;
        var text = Ui.Line(Ui.Run($"+{Format.Tokens(record.Tokens)} tok", fresh ? Font.MetaMonoSemibold : Font.MetaMono, fresh ? Theme.Label : Theme.Secondary),
            Ui.Run(withAge ? " · " + age : "", Font.MetaMono, Theme.Secondary));
        var row = Dashboard.Row(4, dot, text);
        row.ToolTip = Loc("이번 턴의 마지막 출력 기록 · 로그 기록 시점 기준", "Last output record this turn · based on log record times");
        return row;
    }

    public static FrameworkElement ContextLabel(ContextSlot slot, bool shortForm)
    {
        FrameworkElement view;
        if (slot.Compacted is { } compacted)
            view = new Border { Child = Ui.Text(compacted, Font.Meta, Theme.Secondary), Padding = new Thickness(4, 0, 4, 0), CornerRadius = new CornerRadius(6), Background = Theme.Brush(Theme.Primary(0.08)) };
        else
        {
            Meter? meter = null;
            if (slot.Fraction is { } fraction) { meter = new Meter { Width = 32, VerticalAlignment = VerticalAlignment.Center }; meter.Set(fraction, slot.Warning ? Theme.Warning : Theme.Neutral); }
            view = Dashboard.Row(4, meter, Ui.Text(shortForm ? slot.Short : slot.Text, Font.MetaMono, Theme.Secondary));
        }
        view.ToolTip = slot.Help;
        return view;
    }

    public static FrameworkElement SpeedLabel(SpeedSlot slot, bool shortForm)
    {
        TextBlock text;
        if (slot.Known)
        {
            text = Ui.Line();
            if (slot.Prefix is { } prefix) text.Inlines.Add(Ui.Run(prefix + " ", Font.Micro, Theme.Secondary));
            text.Inlines.Add(Ui.Run(slot.Value, Font.MetaMedium, Theme.Secondary));
            Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular);
            text.Inlines.Add(Ui.Run(" " + (shortForm ? "tok/s" : slot.Kind ?? "tok/s"), Font.Micro, Theme.Secondary));
        }
        else
        {
            // The unit keeps a lone "—" from reading as a divider.
            text = Ui.Line(Ui.Run("—", Font.Meta, Theme.Tertiary), Ui.Run(" tok/s", Font.Micro, Theme.Secondary));
        }
        text.ToolTip = slot.Help;
        return text;
    }
}

sealed class IdleRow : RowShell
{
    readonly GlyphView glyph = new(StateGlyphKind.Idle) { Margin = new Thickness(Dashboard.GlyphX + 1, 0, 1, 0) };
    readonly Border names = new() { Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock lastTurn = Ui.Line();
    readonly TextBlock trailing = Ui.Text("", Font.MetaMono, Theme.Secondary);
    object? namesKey;

    public IdleRow()
    {
        lastTurn.Margin = new Thickness(0, 0, 10, 0);
        trailing.MinWidth = 64;
        trailing.TextAlignment = TextAlignment.Right;
        var right = Dashboard.Row(0, lastTurn, trailing);
        right.VerticalAlignment = VerticalAlignment.Center;
        var line = Dashboard.Spread(new TrimLine(glyph, TrimLine.Shrink(names)), right);
        line.Margin = new Thickness(0, 0, Dashboard.Inset, 0);
        Body.Children.Add(line);
    }

    public void Update(SessionRowItem item, SessionDisplayState groupState, int liveChildren, RowContext context)
    {
        var reading = item.Reading;
        var now = context.Now;
        // An idle lead whose subagents are live shows the group's state instead of its own age.
        var followsGroup = !item.State.IsLive && groupState.IsLive && liveChildren > 0;
        var state = followsGroup ? groupState : item.State;
        Bind(item.Id, reading, context, item.Height, context.Help(reading), SessionPresentation.SpokenLabel(reading, state));
        glyph.Kind = GlyphView.For(state) ?? StateGlyphKind.Idle;
        // "중단", "종료 기록 없음" beside the client; it drops first when the row is tight.
        string? word = followsGroup ? null : item.State switch
        {
            SessionDisplayState.Interrupted => Loc("중단", "Interrupted"),
            SessionDisplayState.Unfinished => Loc("종료 기록 없음", "No end record"),
            _ => null,
        };
        lastTurn.Inlines.Clear();
        var showsLast = !followsGroup && word is null && reading.LastOutputTokens is not null;
        lastTurn.Visibility = showsLast ? Visibility.Visible : Visibility.Collapsed;
        if (showsLast)
        {
            lastTurn.Inlines.Add(Ui.Run(Loc("마지막 턴 ", "Last turn "), Font.Micro, Theme.Secondary));
            lastTurn.Inlines.Add(Ui.Run(Format.CompactTokens(reading.LastOutputTokens!.Value), Font.MetaMono, Theme.Secondary));
            Ui.Help(lastTurn, SessionPresentation.LastTurnSummary(reading) ?? "");
        }
        trailing.Text = followsGroup ? SessionPresentation.ChildGroupText(groupState, liveChildren) : Format.Age(reading.LastActivity, now);
        trailing.MaxWidth = followsGroup ? double.PositiveInfinity : 64;
        Ui.Help(trailing, state.Title + Loc(" · 마지막 활동 ", " · last activity ") + SessionPresentation.HelpAge(reading.LastActivity, now, false));

        var showsId = context.ShowsID(reading);
        var key = (reading.Project, reading.Source, word, showsId, showsLast, trailing.Text);
        if (Equals(key, namesKey)) return;
        namesKey = key;
        lastTurn.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        trailing.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - Dashboard.GlyphX - 12 - 6 - 8 - Dashboard.Inset
            - (showsLast ? lastTurn.DesiredSize.Width + 10 : 0) - trailing.DesiredSize.Width;
        FrameworkElement Names(bool withClient, bool withId, bool withWord, bool trim)
        {
            var title = Ui.Text(reading.Project ?? Loc("프로젝트 미확인", "Unknown project"), Font.Body);
            return new TrimLine(trim ? TrimLine.Shrink(title) : title,
                withClient ? Spaced(Ui.Text(reading.Source.Title, Font.Meta, Theme.Secondary)) : null,
                withWord && word is not null ? Spaced(Ui.Text(word, Font.Micro, Theme.Secondary)) : null,
                withId ? Spaced(Ui.Text(SessionPresentation.ShortID(reading), Font.Meta, Theme.Secondary)) : null);
        }
        names.Child = Dashboard.Fit(room, () => Names(true, showsId, true, false), () => Names(true, showsId, false, false),
            () => Names(true, false, false, false), () => Names(false, false, false, true));
    }

    public static T Spaced<T>(T element, double gap = 6) where T : FrameworkElement
    {
        element.Margin = new Thickness(gap, 0, 0, 0);
        return element;
    }
}

sealed class ChildRow : RowShell
{
    readonly GlyphView glyph = new(StateGlyphKind.Idle) { Margin = new Thickness(Dashboard.TextX + 1, 0, 1, 0) };
    readonly Border names = new() { Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock word = Ui.Text("", Font.Micro, Theme.Secondary);
    readonly Border right = new() { VerticalAlignment = VerticalAlignment.Center };
    object? namesKey, rightKey;

    public ChildRow()
    {
        word.Margin = new Thickness(6, 0, 0, 0);
        var line = Dashboard.Spread(new TrimLine(glyph, TrimLine.Shrink(names), word), right);
        line.Margin = new Thickness(0, 0, Dashboard.Inset, 0);
        Body.Children.Add(line);
    }

    public void Update(SessionRowItem item, TokenReading parent, RowContext context)
    {
        var reading = item.Reading;
        var now = context.Now;
        Bind(item.Id, reading, context, item.Height, context.Help(reading), SessionPresentation.SpokenLabel(reading, item.State));
        glyph.Kind = GlyphView.For(item.State) ?? StateGlyphKind.Idle;
        // Tool category, input, retry and log wait only; a running child says nothing extra.
        word.Text = item.State switch
        {
            SessionDisplayState.Tool => SessionPresentation.ToolTitle(reading.ToolCategory),
            SessionDisplayState.Input => SessionPresentation.InputTitle(reading),
            SessionDisplayState.Retrying => reading.Retry is { } retry ? SessionPresentation.RetryText(retry, now, false, false) : item.State.Title,
            SessionDisplayState.Waiting => item.State.Title,
            _ => "",
        };
        word.Visibility = word.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

        var live = item.State.IsLive;
        var record = live ? SessionPresentation.LastRecord(reading) : null;
        var age = record is { } r ? SessionPresentation.RecordAge(r.At, now, false) : null;
        var rightValue = (live, age, reading.CurrentTurnOutputTokens, item.State, live ? null : Format.Age(reading.LastActivity, now));
        if (!Equals(rightValue, rightKey))
        {
            rightKey = rightValue;
            right.Child = live ? Dashboard.Row(8, RecordAge(age), Number(reading, item.State)) : Fixed(Ui.Text(Format.Age(reading.LastActivity, now), Font.MetaMono, Theme.Secondary), 64);
        }

        var title = SessionPresentation.ChildTitle(reading);
        var project = SessionPresentation.ChildProjectSuffix(reading, parent);
        var key = (title, project, word.Text, rightValue);
        if (Equals(key, namesKey)) return;
        namesKey = key;
        word.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        right.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - Dashboard.TextX - 12 - 6 - 8 - Dashboard.Inset
            - (word.Visibility == Visibility.Visible ? word.DesiredSize.Width + 6 : 0) - right.DesiredSize.Width;
        // Each part shows whole or not at all (the project drops first, then the role); never a cut id.
        FrameworkElement Names(params string?[] parts)
        {
            var line = Ui.Line(Ui.Run(title.Title, Font.Meta));
            foreach (var part in parts.OfType<string>()) line.Inlines.Add(Ui.Run(" · " + part, Font.Meta, Theme.Secondary));
            line.TextTrimming = TextTrimming.None;
            return line;
        }
        names.Child = Dashboard.Fit(room, () => Names(title.Detail, project), () => Names(title.Detail), () => TrimLine.Shrink(Ui.Text(title.Title, Font.Meta)));
    }

    static FrameworkElement Fixed(TextBlock text, double width)
    {
        text.MinWidth = width;
        text.TextAlignment = TextAlignment.Right;
        return text;
    }

    static FrameworkElement RecordAge(string? age)
    {
        var row = Dashboard.Row(4, age == SessionPresentation.JustNow ? Dashboard.Dot(Theme.Activity) : null, age is null ? null : Ui.Text(age, Font.MetaMono, Theme.Secondary));
        row.MinWidth = 44;
        row.HorizontalAlignment = HorizontalAlignment.Right;
        return new Border { MinWidth = 44, Child = row };
    }

    static FrameworkElement Number(TokenReading reading, SessionDisplayState state)
    {
        TextBlock text;
        if (reading.CurrentTurnOutputTokens is { } output)
        {
            // A child waiting for a log is not producing; its total stays quiet.
            var quiet = state == SessionDisplayState.Waiting || output == 0;
            text = Ui.Line(Ui.Run(Format.Tokens(output), quiet ? Font.MetaMono : Font.MetaMonoSemibold, quiet ? Theme.Secondary : Theme.Label),
                Ui.Run(" tok", Font.Micro, Theme.Secondary));
        }
        else text = Ui.Text("—", Font.Meta, Theme.Tertiary);
        return Fixed(text, 56);
    }
}

sealed class MeasurementRow : RowShell
{
    readonly TextBlock project = Ui.Text("", Font.Body);
    readonly TextBlock model = TrimLine.Shrink(Ui.Text("", Font.Meta, Theme.Secondary));
    readonly Border right = new() { VerticalAlignment = VerticalAlignment.Center };

    public MeasurementRow()
    {
        var icon = Ui.Icon(Ui.Speedometer, 10, Theme.Secondary);
        icon.Width = 10;
        icon.Margin = new Thickness(Dashboard.GlyphX, 0, 0, 0);
        project.Margin = model.Margin = new Thickness(6, 0, 0, 0);
        var line = Dashboard.Spread(new TrimLine(icon, project, model), right);
        line.Margin = new Thickness(0, 0, Dashboard.Inset, 0);
        Body.Children.Add(line);
    }

    public void Update(SessionRowItem item, RowContext context)
    {
        var reading = item.Reading;
        var now = context.Now;
        var name = reading.Project ?? Loc("모델 실측", "Model measurement");
        var modelName = reading.Model ?? Loc("모델 미확인", "Unknown model");
        Bind(item.Id, reading, context, 28, Loc("클릭: 상세 · 우클릭: 메뉴", "Click: details · Right-click: menu"), $"{name}, {reading.Source.Title} {modelName}");
        project.Text = name;
        model.Text = modelName;
        var speed = SessionPresentation.Speed(reading, now, false);
        var age = Format.Age(reading.SpeedMeasurement?.At ?? reading.LastActivity, now);
        right.Child = Dashboard.Row(10, LiveRow.SpeedLabel(speed, false), Ui.Text(Loc($"측정 {age}", $"Measured {age}"), Font.MetaMono, Theme.Secondary));
    }
}

sealed class MoreRow : RowShell
{
    readonly TextBlock text = Ui.Text("", Font.MetaMono, Theme.Secondary);

    readonly Action expand;

    public MoreRow(Action expand)
    {
        this.expand = expand;
        text.Margin = new Thickness(Dashboard.ChildTextX, 0, Dashboard.Inset, 0);
        text.VerticalAlignment = VerticalAlignment.Center;
        Body.Children.Add(text);
    }

    public void Update(SessionBlock block, RowContext context)
    {
        Bind(block.MoreID, null, context with { Tap = _ => expand() }, SessionListModel.MoreHeight,
            Loc($"실행 중인 하위 에이전트는 모두 보여주고, 로그 대기 하위는 실행 중인 하위가 없을 때만 {SessionListModel.CollapsedChildren}개까지 보여줍니다",
                $"Shows every running subagent. Subagents waiting for log appear only when none are running, up to {SessionListModel.CollapsedChildren}"),
            Loc($"하위 에이전트 {block.MoreCount}개 더 보기", $"Show {Plural(block.MoreCount, "more subagent")}") + ", " + block.MoreSpoken);
        text.Text = block.MoreText;
    }
}

sealed class OlderRow : Border
{
    readonly TextBlock text = Ui.Text("", Font.MetaMedium, Theme.Secondary);
    bool selected;

    public OlderRow(Action open)
    {
        Height = SessionListModel.OlderHeight;
        Background = Brushes.Transparent;
        Cursor = Cursors.Hand;
        var row = Dashboard.Row(3, text, Ui.Icon(Ui.ChevronDown, 9, Theme.Secondary));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        row.VerticalAlignment = VerticalAlignment.Center;
        Child = row;
        MouseEnter += (_, _) => Paint();
        MouseLeave += (_, _) => Paint();
        MouseLeftButtonUp += (_, _) => open();
        System.Windows.Automation.AutomationProperties.SetName(this, Loc("이전 기록 더 보기", "Show earlier records"));
    }

    public void Update(int count, bool isSelected)
    {
        selected = isSelected;
        text.Text = Loc($"이전 기록 {count}개 더 보기", $"Show {Plural(count, "earlier record")}");
        Paint();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new LeafPeer(this, AutomationControlType.ListItem);

    void Paint()
    {
        Background = selected ? Theme.Brush(Theme.Selection) : IsMouseOver ? Theme.Brush(Theme.Hover) : Brushes.Transparent;
        BorderBrush = Theme.Brush(Theme.Accent);
        BorderThickness = new Thickness(selected ? 1.5 : 0);
    }
}

/// The inline detail under a row (S-6): a two-column grid, 15 DIP lines, 8 above and below, a rule on top.
sealed class DetailView : StackPanel
{
    object? key;

    /// Its name reaches Narrator, and the copy buttons stay reachable as its children.
    protected override AutomationPeer OnCreateAutomationPeer() => new FrameworkElementAutomationPeer(this);

    public void Update(SessionRowItem item, double indent)
    {
        var items = SessionPresentation.DetailItems(item.Reading, item.State);
        var value = (indent, string.Join("\n", items.Select(detail => $"{detail.Label}\t{detail.Value}\t{detail.Copy}")));
        Height = SessionPresentation.DetailHeight(item.Reading, item.State);
        if (Equals(value, key)) return;
        key = value;
        Children.Clear();
        Children.Add(Ui.Hairline(indent, Dashboard.Inset));
        var grid = new StackPanel { Margin = new Thickness(indent, 8, Dashboard.Inset, 8) };
        foreach (var detail in items)
        {
            var label = Ui.Text(detail.Label, Font.Meta, Theme.Secondary);
            label.Width = 76;
            var text = TrimLine.Shrink(Ui.Text(detail.Value, Font.MetaMono));
            text.Margin = new Thickness(6, 0, 0, 0);
            Button? copy = null;
            if (detail.Copy is { } copied)
            {
                copy = Ui.HoverButton(new Border { Width = 18, Height = 15, Child = new Border { Child = Ui.Icon(Ui.Copy, 10, Theme.Secondary), HorizontalAlignment = HorizontalAlignment.Center } },
                    () => Shell.Copy(copied), Loc("복사", "Copy"));
                copy.Margin = new Thickness(6, 0, 0, 0);
                System.Windows.Automation.AutomationProperties.SetName(copy, Loc($"{detail.Label} 복사", $"Copy {detail.Label}"));
            }
            grid.Children.Add(new TrimLine(label, text, copy) { Height = 15 });
        }
        Children.Add(grid);
        System.Windows.Automation.AutomationProperties.SetName(this, Loc("세션 상세", "Session details"));
    }
}
