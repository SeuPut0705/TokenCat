using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;
using static TokenCat.Lang;

namespace TokenCat;

/// What the dashboard asks of the shell; views never reach windows or processes themselves.
sealed record DashboardActions(Action Settings, Action Quit, Action About, Action TaskManager, Action Detach,
    Action OpenTelemetrySettings, Action<UpdateCommand> Update, Action RecheckLogFolders, Action DismissOnboarding)
{
    /// Snapshots and fixtures: every action does nothing.
    public static DashboardActions None { get; } = new(() => { }, () => { }, () => { }, () => { }, () => { }, () => { }, _ => { }, () => { }, () => { });
}

/// Everything one publish shows: the monitor state plus what the shell owns (DashboardModel's other fields).
sealed record DashboardInput(MonitorState State, UpdateState Update, string? DismissedUpdateVersion, DateTimeOffset? QuietSince,
    string? SetupNote, TelemetrySetupFailure? SetupFailure, IReadOnlyList<TelemetrySetupNote> ConnectNotes, bool? ClaudeBridged,
    bool OnboardingSeen, bool OptedOut);

/// DashboardView.swift: the flyout and the "Open as window" content. Built once; each publish updates the elements in place
/// (rows are kept by id), so hover, tooltips, clicks and the keyboard selection survive the 1 s cadence.
sealed class Dashboard : UserControl
{
    /// The 4 DIP grid (A0-5): 420 wide, gutters 16, content 388.
    public const double PanelWidth = 420, Gutter = 16, Block = 12, TitleGap = 8, Inset = 12, InsetVertical = 10,
        GlyphX = 12, TextX = 28, GuideX = 17, ChildTextX = 44;

    readonly bool panel, snapshot;
    readonly DashboardActions actions;
    readonly Header header;
    readonly Border onboardingSlot = new() { Margin = new Thickness(0, Block, 0, 0) };
    readonly FlowCard flow;
    readonly StackPanel limits = new();
    readonly SessionsHeader sessionsHeader;
    readonly SessionList list;
    readonly SystemArea system;
    readonly Footer footer;
    OnboardingOutcome? onboardingShown;
    bool flowOpened;
    public DashboardInput? Input { get; private set; }

    public Dashboard(DashboardActions actions, bool panel = false, bool snapshot = false, string? selection = null, string? detail = null,
        bool expanded = false)
    {
        this.actions = actions;
        this.panel = panel;
        this.snapshot = snapshot;
        header = new Header(actions, panel, interactive: !snapshot);
        flow = new FlowCard();
        list = new SessionList(this, panel, snapshot, selection, detail, expanded) { Recheck = actions.RecheckLogFolders };
        sessionsHeader = new SessionsHeader(() => list.ToggleExpanded());
        system = new SystemArea(actions.TaskManager);
        footer = new Footer(actions);

        var aiContainer = new StackPanel();
        aiContainer.Children.Add(flow);
        aiContainer.Children.Add(limits);
        var root = new Grid { Width = PanelWidth, Margin = new Thickness(0), Background = Theme.Brush(Theme.Background) };
        var content = new Grid { Margin = new Thickness(Gutter, 12, Gutter, 12) };
        UIElement[] rows =
        [
            header, onboardingSlot, Pad(Ui.Container(aiContainer), Block), Pad(sessionsHeader, Block), Pad(list, TitleGap),
            Pad(system, Block), Pad(footer, Block),
        ];
        for (var i = 0; i < rows.Length; i++)
        {
            content.RowDefinitions.Add(new RowDefinition { Height = panel && i == 4 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            Grid.SetRow(rows[i], i);
            content.Children.Add(rows[i]);
        }
        root.Children.Add(content);
        Content = root;
        Width = PanelWidth;
        UseLayoutRounding = true;
        Ui.Styled(this, Font.Body, Theme.Label);
    }

    static FrameworkElement Pad(FrameworkElement element, double top)
    {
        element.Margin = new Thickness(element.Margin.Left, top, element.Margin.Right, element.Margin.Bottom);
        return element;
    }

    /// A new showing (F-5, S-8, H-3): the flow card collapses again when empty, the list forgets its scroll state, the head blinks.
    public void Opened()
    {
        if (Input is { } input) flowOpened = !FlowEmpty(input);
        header.Blink();
        list.Opened();
    }

    /// Selects and scrolls to a top-level group (notification or quick menu).
    public void Focus(string group) => list.Focus(group);

    static bool Loading(DashboardInput input) => input.State.TokensSampledAt is null;
    static bool FlowEmpty(DashboardInput input) =>
        !Loading(input) && input.State.Flow.Total == 0 && input.State.Sessions.Counts.LiveGroups == 0;

    public void Show(DashboardInput input)
    {
        var first = Input is null;
        Input = input;
        var state = input.State;
        var loading = Loading(input);
        if (first) flowOpened = !FlowEmpty(input);
        if (!FlowEmpty(input)) flowOpened = true;

        header.Update(SessionPresentation.Header(state.Sessions.Counts, loading, state.Now, input.QuietSince, false));

        var notice = TelemetryNoticeFor(input);
        // The status line bridge note only while the original status line command is known.
        OnboardingOutcome? outcome = snapshot || input.OnboardingSeen ? null : OnboardingOutcome.Make(notice, input.SetupNote, input.SetupFailure,
            state.TelemetryState, input.ClaudeBridged == true && !input.ConnectNotes.Contains(TelemetrySetupNote.OriginalUnknown), input.OptedOut);
        if (!Equals(outcome, onboardingShown))
        {
            onboardingShown = outcome;
            onboardingSlot.Child = outcome is null ? null : OnboardingCard.Build(outcome, actions);
            onboardingSlot.Visibility = outcome is null ? Visibility.Collapsed : Visibility.Visible;
        }

        var lists = list.Model(input);
        flow.Update(state, loading, FlowEmpty(input) && !flowOpened,
            loading ? null : SessionPresentation.Headline(lists, state.Now, state.TelemetryRestartNeeded));
        var limitRows = new List<UsageLimitSummary>();
        if (state.Sessions.UsageLimit is { } codex && codex.IsShown(state.Now)) limitRows.Add(codex);
        if (SessionPresentation.ClaudeUsageLimit(state.ClaudeLimits, state.Now) is { } claude && claude.IsShown(state.Now)) limitRows.Add(claude);
        Reconcile.Panel(limits, limitCache, limitRows.Select((limit, index) => Reconcile.Item(index.ToString(),
            () => new LimitRow(), (LimitRow row) => row.Update(limit, state.Now))));

        sessionsHeader.Update(lists, list.Expanded);
        list.Show(input, lists);
        system.Update(state);
        var tokenDelay = state.TokensSampledAt is { } sampled ? (int)(state.Now - sampled).TotalSeconds : 0;
        var status = SessionPresentation.Footer(!state.HasSample || loading, tokenDelay, (int)(state.Now - state.System.SampledAt).TotalSeconds, notice);
        var help = Loc("시스템과 AI 기록을 1초마다, 로그 변경 시 즉시 확인합니다", "Checks system and AI records every second, and right away when a log changes")
            + $"\n{SessionPresentation.TelemetryReceipt(state.TelemetryLastReceived, state.Now)}\n{state.TelemetryStatus}";
        footer.Update(status, notice, help, input.Update.Notice(input.DismissedUpdateVersion));
    }

    readonly Dictionary<string, FrameworkElement> limitCache = [];

    public static TelemetryNotice? TelemetryNoticeFor(DashboardInput input) =>
        SessionPresentation.Notice(input.State.TelemetryState, input.SetupNote, input.State.TelemetryRestartNeeded, input.State.TelemetryStatus,
            input.SetupFailure, input.State.TelemetryRestartExpired);

    /// Measures `candidates` in order and returns the first that fits `available` (SwiftUI ViewThatFits); else the last.
    public static FrameworkElement Fit(double available, params Func<FrameworkElement>[] candidates)
    {
        FrameworkElement? last = null;
        foreach (var make in candidates)
        {
            last = make();
            last.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            if (last.DesiredSize.Width <= available + 0.5) return last;
        }
        return last!;
    }

    public static StackPanel Row(double spacing, params UIElement?[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var first = true;
        foreach (var child in children)
        {
            if (child is null) continue;
            if (!first && child is FrameworkElement element) element.Margin = new Thickness(element.Margin.Left + spacing, element.Margin.Top, element.Margin.Right, element.Margin.Bottom);
            first = false;
            row.Children.Add(child);
        }
        return row;
    }

    /// Leading content stretched with trimming, trailing content at its natural width.
    public static DockPanel Spread(UIElement leading, UIElement? trailing, double gap = 8)
    {
        var dock = new DockPanel { LastChildFill = true };
        if (trailing is FrameworkElement right)
        {
            right.Margin = new Thickness(gap, right.Margin.Top, right.Margin.Right, right.Margin.Bottom);
            DockPanel.SetDock(right, Dock.Right);
            dock.Children.Add(right);
        }
        dock.Children.Add(leading);
        return dock;
    }

    public static Ellipse Dot(Color color, double side = 6) => new() { Width = side, Height = side, Fill = Theme.Brush(color), VerticalAlignment = VerticalAlignment.Center };

    /// SwiftUI `.redacted(.placeholder)`: the text's shape in a faint fill.
    public static TextBlock Redacted(TextBlock text)
    {
        text.Foreground = Brushes.Transparent;
        text.Background = Theme.Brush(Theme.Primary(0.1));
        return text;
    }
}

/// Keyed reuse of child elements: unchanged keys keep their element (hover, tooltip and click state), order follows the items.
static class Reconcile
{
    public sealed record Entry(string Key, Func<FrameworkElement> Create, Action<FrameworkElement> Update);

    public static Entry Item<T>(string key, Func<T> create, Action<T> update) where T : FrameworkElement =>
        new(key, create, element => update((T)element));

    public static void Panel(Panel panel, Dictionary<string, FrameworkElement> cache, IEnumerable<Entry> items)
    {
        var wanted = new List<FrameworkElement>();
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            if (!used.Add(item.Key)) continue;
            if (!cache.TryGetValue(item.Key, out var element)) cache[item.Key] = element = item.Create();
            item.Update(element);
            wanted.Add(element);
        }
        foreach (var key in cache.Keys.Where(key => !used.Contains(key)).ToList()) cache.Remove(key);
        for (var i = 0; i < wanted.Count; i++)
        {
            if (i < panel.Children.Count && ReferenceEquals(panel.Children[i], wanted[i])) continue;
            panel.Children.Remove(wanted[i]);
            panel.Children.Insert(i, wanted[i]);
        }
        while (panel.Children.Count > wanted.Count) panel.Children.RemoveAt(panel.Children.Count - 1);
    }
}

/// Pixel head, state glyph and the one status sentence (H-1–H-3); settings and the ⋯ menu on the right.
sealed class Header : Grid
{
    readonly Image head = Sprites.HeadImage(RunnerHead.Normal, 24, 22);
    readonly GlyphView glyph = new(StateGlyphKind.Idle) { Margin = new Thickness(0, 0, 4, 0) };
    readonly TextBlock sentence = Ui.Line();
    readonly TrimLine status;
    readonly bool interactive;
    RunnerHead current = RunnerHead.Normal;
    bool blinking;

    public Header(DashboardActions actions, bool panel, bool interactive)
    {
        this.interactive = interactive;
        Height = 28;
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition());
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.VerticalAlignment = VerticalAlignment.Center;
        status = new TrimLine(glyph, TrimLine.Shrink(sentence));
        status.Margin = new Thickness(8, 0, 8, 0);
        status.VerticalAlignment = VerticalAlignment.Center;
        System.Windows.Automation.AutomationProperties.SetName(status, Loc("세션 상태", "Session status"));
        var gear = Ui.HoverButton(Sized(Ui.Icon(Ui.Gear, 14, Theme.Secondary)), actions.Settings, Loc("설정", "Settings"), circle: true);
        Button? more = null;
        more = Ui.HoverButton(Sized(Ui.Icon(Ui.More, 14, Theme.Secondary)), () => Menus.Show(more!, menu =>
        {
            if (!panel) menu.Add(Loc("창으로 열기", "Open as Window"), actions.Detach);
            menu.Add(Loc("설정…", "Settings…"), actions.Settings);
            menu.Add(Loc("작업 관리자", "Task Manager"), actions.TaskManager);
            menu.Add(Loc("TokenCat 정보", "About TokenCat"), actions.About);
            menu.Separator();
            menu.Add(Loc("TokenCat 종료", "Quit TokenCat"), actions.Quit);
        }), Loc("더 보기", "More"), circle: true);
        more.Margin = new Thickness(4, 0, 0, 0);
        UIElement[] cells = [head, status, gear, more];
        for (var i = 0; i < cells.Length; i++) { SetColumn(cells[i], i); Children.Add(cells[i]); }
    }

    static Border Sized(UIElement icon) => new() { Child = icon, Width = 24, Height = 24 };

    public void Update(HeaderStatus value)
    {
        if (current != value.Head) { current = value.Head; if (!blinking) head.Source = Sprites.Head(current); }
        glyph.Visibility = value.Glyph is null ? Visibility.Collapsed : Visibility.Visible;
        if (value.Glyph is { } kind) glyph.Kind = kind;
        sentence.Inlines.Clear();
        sentence.Inlines.Add(Ui.Run(value.Sentence, Font.Title, value.Muted ? Theme.Secondary : Theme.Label));
        sentence.Inlines.Add(Ui.Run(value.Suffix, Font.Meta, Theme.Secondary));
        Ui.Help(status, value.Help);
        System.Windows.Automation.AutomationProperties.SetHelpText(status, value.Spoken);
    }

    /// One 0.12 s blink 0.35 s after the dashboard shows; never in snapshots or with animations off.
    public void Blink()
    {
        if (!interactive || !SystemParameters.ClientAreaAnimation) return;
        Shell.After(TimeSpan.FromMilliseconds(350), () =>
        {
            blinking = true;
            head.Source = Sprites.Head(RunnerHead.Blink);
            Shell.After(TimeSpan.FromMilliseconds(120), () => { blinking = false; head.Source = Sprites.Head(current); });
        });
    }
}

/// Shown once in the interactive dashboard, never in snapshots of the whole flyout; only ✕ dismisses it.
static class OnboardingCard
{
    public static string BackupPath => @"%LOCALAPPDATA%\TokenCat\telemetry-backups";

    static (string Title, string Detail, string? Tail) Telemetry(OnboardingOutcome outcome) => outcome switch
    {
        OnboardingOutcome.Added(var bridged) => (Loc("실측을 위해 Codex·Claude Code 설정에 로컬 전송을 추가했습니다", "Added local telemetry to Codex and Claude Code settings"),
            bridged ? Loc("Claude Code 상태 표시줄에 한도만 읽는 브리지를 추가했습니다(출력 없음)", "Also added a status line bridge that only reads limits (prints nothing)")
                : Loc("새로 실행할 때부터 적용됩니다", "Applies from the next launch"),
            bridged ? Loc("새로 실행할 때부터 적용", "Applies from the next launch") : null),
        OnboardingOutcome.Skipped(var reason) => (Loc("실측 연결을 건너뛰었습니다", "Skipped connecting telemetry"), reason, null),
        OnboardingOutcome.Failed(var reason) => (Loc("실측 연결을 완료하지 못했습니다", "Couldn't finish connecting telemetry"), reason, null),
        OnboardingOutcome.CollectorDown(var text) => (Loc("실측 연결을 하지 않았습니다", "Didn't connect telemetry"), text, null),
        _ => (Loc("실측 수집기를 준비하고 있습니다", "Preparing the telemetry collector"),
            Loc("준비되면 Codex·Claude Code 설정에 로컬 전송을 추가합니다", "Adds local telemetry to Codex and Claude Code settings when it's ready"), null),
    };

    public static FrameworkElement Build(OnboardingOutcome outcome, DashboardActions actions)
    {
        var added = outcome is OnboardingOutcome.Added;
        var needsSettings = outcome is OnboardingOutcome.Skipped or OnboardingOutcome.Failed or OnboardingOutcome.CollectorDown;
        var stack = new StackPanel { Margin = new Thickness(12) };
        var close = Ui.HoverButton(new Border { Width = 18, Height = 18, Child = Center(Ui.Icon(Ui.Close, 10, Theme.Secondary)) },
            actions.DismissOnboarding, Loc("안내 닫기", "Close welcome"), circle: true);
        var title = Dashboard.Row(6, Sprites.HeadImage(RunnerHead.Normal, 12, 11), Ui.Text(Loc("TokenCat이 하는 일", "What TokenCat does"), Font.Title));
        title.VerticalAlignment = VerticalAlignment.Center;
        stack.Children.Add(Dashboard.Spread(title, close));
        stack.Children.Add(Line(Ui.Shield, Loc("대화 본문은 저장하지 않습니다", "Doesn't store conversation text"),
            Loc("모델·토큰 수·도구 종류·프로젝트 폴더 같은 메타데이터만 읽습니다", "Reads only metadata such as models, token counts, tool types and project folders")));
        var telemetry = Telemetry(outcome);
        // A factory: each layout candidate needs its own link elements (a WPF element has one parent).
        UIElement[] Links()
        {
            var links = new List<UIElement>();
            if (added)
                links.Add(Ui.Link(Loc("백업 보기", "Show backup"), () => Shell.Reveal(System.IO.Path.Combine(AppPaths.Support, "telemetry-backups")),
                    Loc($"원본 백업 {BackupPath} · 탐색기에서 보여 주기만 합니다", $"Original backup {BackupPath} · only shows it in File Explorer")));
            links.Add(Ui.Link(Loc("설정 열기", "Open settings"), actions.OpenTelemetrySettings, Loc("설정의 실측 탭을 엽니다", "Opens the Telemetry tab in Settings"), needsSettings));
            return [.. links];
        }
        stack.Children.Add(Line(Ui.Sliders, telemetry.Title, telemetry.Detail, telemetry.Tail, Links));
        stack.Children.Add(Line(Ui.Blocked, Loc("모델 호출·계정 로그인을 하지 않습니다", "Doesn't call models or sign in to accounts"),
            Loc("인터넷 요청은 GitHub 새 버전 확인과 업데이트를 누를 때의 내려받기뿐입니다(설정 › 정보에서 확인 끄기)",
                "Only goes online to check GitHub for new versions and to download one when you click Update (turn off checks in Settings › About)")));
        return Ui.Container(stack, tint: true);
    }

    static Border Center(UIElement child) => new() { Child = child, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    /// The links follow the detail on its line when they fit, otherwise they start the next line (after `tail`).
    static FrameworkElement Line(char icon, string title, string detail, string? tail = null, Func<UIElement[]>? links = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var symbol = Ui.Icon(icon, 13, Theme.Accent);
        symbol.VerticalAlignment = VerticalAlignment.Top;
        symbol.Margin = new Thickness(0, 1, 0, 0);
        grid.Children.Add(symbol);
        var texts = new StackPanel();
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        texts.Children.Add(Wrap(Ui.Text(title, Font.MetaMedium)));
        if (links is null) { texts.Children.Add(Wrap(Ui.Text(detail, Font.Meta, Theme.Secondary))); return grid; }
        const double width = Dashboard.PanelWidth - 2 * Dashboard.Gutter - 24 - 20;
        texts.Children.Add(Dashboard.Fit(width,
            () => Dashboard.Row(6, [Ui.Text(string.Join(" · ", new[] { detail, tail }.OfType<string>()), Font.Meta, Theme.Secondary), .. links()]),
            () =>
            {
                var two = new StackPanel();
                two.Children.Add(Wrap(Ui.Text(detail, Font.Meta, Theme.Secondary)));
                two.Children.Add(Dashboard.Row(6, [tail is null ? null : Ui.Text(tail, Font.Meta, Theme.Secondary), .. links()]));
                return two;
            }));
        return grid;
    }

    static TextBlock Wrap(TextBlock text)
    {
        text.Text = Ui.KeepWords(text.Text);
        text.TextWrapping = TextWrapping.Wrap;
        text.TextTrimming = TextTrimming.None;
        return text;
    }
}

/// The output-token card (F-1–F-6): log records, never a speed, plus the measured "지금 속도".
sealed class FlowCard : Border
{
    static string HelpText => Loc("막대 하나는 5초 동안 로그에 기록된 출력 토큰 수입니다. Codex는 응답이 끝날 때, Claude Code는 메시지가 끝날 때 기록하므로 생성 중인 토큰은 아직 포함되지 않습니다. 속도로 환산하지 않습니다.",
        "Each bar is the number of output tokens recorded in the log over 5 seconds. Codex records them when a response ends and Claude Code when a message ends, so tokens still being generated aren't included yet. They're never converted into a speed.");

    readonly Grid collapsed = new() { Height = 20 };
    readonly TextBlock collapsedLast = Ui.Text("", Font.MetaMono, Theme.Secondary);
    readonly StackPanel card = new();
    readonly TextBlock total = Ui.Line();
    readonly GlyphView captionGlyph = new(StateGlyphKind.Input) { Margin = new Thickness(0, 0, 4, 0) };
    readonly TextBlock caption = Ui.Text("", Font.Meta);
    readonly StackPanel captionRow;
    readonly Border lastSlot = new() { HorizontalAlignment = HorizontalAlignment.Right };
    // 21 tall with -3 below: the metric font's descenders fit while the card keeps its 18 + 2 rhythm (like line 3 rows).
    readonly Border lowerSlot = new() { Height = 21, Margin = new Thickness(0, 2, 0, -3) };
    readonly FlowChart chart = new() { Height = 61, Margin = new Thickness(0, 8, 0, 0) };
    object? lastKey, lowerKey;

    public FlowCard()
    {
        Padding = new Thickness(Dashboard.Inset, Dashboard.InsetVertical, Dashboard.Inset, Dashboard.InsetVertical);
        var collapsedTitle = Dashboard.Row(6, Ui.Text(Loc("출력 토큰", "Output tokens"), Font.Title),
            Ui.Text(Loc("최근 5분 기록 없음", "None in the last 5 min"), Font.Meta, Theme.Secondary));
        collapsedTitle.VerticalAlignment = collapsedLast.VerticalAlignment = VerticalAlignment.Center;
        collapsed.Children.Add(Dashboard.Spread(collapsedTitle, collapsedLast));

        var info = Ui.HoverButton(new Border { Width = 20, Height = 20, Child = new Border
            { Child = Ui.Icon(Ui.InfoIcon, 11, Theme.Secondary), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } },
            () => { }, Loc("출력 토큰 설명", "About output tokens"), circle: true);
        var popup = new Popup { PlacementTarget = info, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = false, Child = Help() };
        info.Click += (_, _) => popup.IsOpen = !popup.IsOpen;
        var titleRow = Dashboard.Spread(Dashboard.Row(6, Ui.Text(Loc("출력 토큰", "Output tokens"), Font.Title),
            Ui.Text(Loc("최근 5분 · 로그 기록 기준", "Last 5 min · based on log records"), Font.Meta, Theme.Secondary)), info, 4);
        titleRow.Height = 16;
        card.Children.Add(titleRow);

        captionRow = Dashboard.Row(0, captionGlyph, caption);
        captionRow.HorizontalAlignment = HorizontalAlignment.Right;
        captionRow.MaxWidth = 220;
        var right = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom };
        right.Children.Add(captionRow);
        right.Children.Add(lastSlot);
        total.VerticalAlignment = VerticalAlignment.Bottom;
        var numberRow = Dashboard.Spread(total, right);
        numberRow.Height = 32;
        numberRow.Margin = new Thickness(0, 6, 0, 0);
        card.Children.Add(numberRow);
        card.Children.Add(lowerSlot);
        card.Children.Add(chart);
        var stack = new Grid();
        stack.Children.Add(collapsed);
        stack.Children.Add(card);
        Child = stack;
    }

    /// ⓘ: the full explanation and the two-line legend.
    static Border Help()
    {
        var stack = new StackPanel { Width = 256 };
        var text = Ui.Text(HelpText, Font.Meta);
        text.TextWrapping = TextWrapping.Wrap;
        stack.Children.Add(text);
        FrameworkElement Legend(Color color, string label)
        {
            var bar = new Border { Width = 6, Height = 10, Background = Theme.Brush(color), CornerRadius = new CornerRadius(1, 1, 0, 0), Margin = new Thickness(2, 0, 2, 0) };
            var row = Dashboard.Row(6, bar, Ui.Text(label, Font.Meta));
            row.Margin = new Thickness(0, 8, 0, 0);
            return row;
        }
        stack.Children.Add(Legend(Theme.Neutral, Loc("막대 하나 = 5초 동안 기록된 출력", "One bar = output recorded over 5 s")));
        stack.Children.Add(Legend(Theme.Activity, Loc("초록 = 최근 5초 안 기록", "Green = recorded in the last 5 s")));
        return new Border
        {
            Child = stack, Padding = new Thickness(12), Background = Theme.Brush(Theme.Over(Theme.ContainerFill, Theme.Background)),
            BorderBrush = Theme.Brush(Theme.Hairline), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8),
        };
    }

    public void Update(MonitorState state, bool loading, bool isCollapsed, SpeedHeadline? speed)
    {
        var now = state.Now;
        collapsed.Visibility = isCollapsed ? Visibility.Visible : Visibility.Collapsed;
        card.Visibility = isCollapsed ? Visibility.Collapsed : Visibility.Visible;
        // Without any output yet the row already says "기록 없음" once.
        collapsedLast.Text = state.NewestOutputAt is { } newest ? Loc("마지막 출력 ", "Last output ") + SessionPresentation.HelpAge(newest, now, false) : "";
        if (isCollapsed) return;

        var flow = state.Flow;
        var sum = flow.Total;
        total.Inlines.Clear();
        total.Inlines.Add(Ui.Run(loading ? "0,000" : Format.Tokens(sum), Font.Hero, sum == 0 && !loading ? Theme.Secondary : Theme.Label));
        total.Inlines.Add(Ui.Run(" tok", Font.Body, Theme.Secondary));
        total.Opacity = loading ? 0.25 : 1;

        var value = SessionPresentation.Caption(state.Sessions.Counts, flow.Last?.At, now, false);
        captionGlyph.Visibility = value.Glyph is not null && !loading ? Visibility.Visible : Visibility.Collapsed;
        if (value.Glyph is { } kind) captionGlyph.Kind = kind;
        caption.Text = loading ? SessionPresentation.LastRecordCaption : value.Text;
        caption.Foreground = Theme.Brush(value.Emphasized && !loading ? Theme.Label : Theme.Secondary);
        Ui.Help(captionRow, value.Help);

        var fresh = flow.Last is { } record && SessionPresentation.IsFresh(record.At, now);
        var lastText = loading ? null : flow.Last is { } last ? $"+{Format.Tokens(last.Tokens)} tok · {SessionPresentation.RecordAge(last.At, now, false)}" : "—";
        var key = (loading, lastText, fresh);
        if (!Equals(key, lastKey))
        {
            lastKey = key;
            lastSlot.Child = loading ? Dashboard.Redacted(Ui.Text(Loc("+0,000 tok · 방금", "+0,000 tok · just now"), Font.BodyMediumMono))
                : flow.Last is null ? Ui.Text("—", Font.BodyMediumMono, Theme.Tertiary)
                : Dashboard.Row(4, fresh ? Dashboard.Dot(Theme.Activity) : null, Ui.Text(lastText!, Font.BodyMediumMono));
        }

        // The slot under the number: the provider split on the left, "지금 속도" on the right. Always 18 DIP, so the card
        // does not move each time the speed comes and goes.
        var shows = !loading && (sum > 0 || speed is not null);
        lowerSlot.Visibility = shows ? Visibility.Visible : Visibility.Collapsed;
        var parts = Enum.GetValues<TokenSource>().Select(source => (source, value: flow.ByProvider.GetValueOrDefault(source))).Where(p => p.value > 0).ToList();
        var providers = parts.Count > 1 ? string.Join(" · ", parts.Select(p => $"{p.source.Title} {Format.CompactTokens(p.value)}")) : parts.FirstOrDefault().source.Title;
        if (parts.Count == 0) providers = "";
        var lower = (providers, speed);
        if (shows && !Equals(lower, lowerKey))
        {
            lowerKey = lower;
            var left = Ui.Text(providers, Font.MetaMono, Theme.Secondary);
            left.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - 2 * Dashboard.Inset - left.DesiredSize.Width - 8;
            lowerSlot.Child = Dashboard.Spread(left, speed is null ? null : SpeedHeadlineView(speed, room));
        }
        chart.Set(flow.Hero, flow.Fresh, loading);
    }

    /// "지금 속도 · TokenCat  52.3 요청 tok/s": the label drops first when the row is tight, then the project.
    static FrameworkElement SpeedHeadlineView(SpeedHeadline headline, double room)
    {
        // The label is the line's first run, so it shares the value's baseline.
        TextBlock Value(string? label = null)
        {
            var line = Ui.Line(Ui.Run(headline.Value, Font.Metric, headline.Known ? Theme.Label : Theme.Tertiary),
                Ui.Run(" " + (headline.Kind ?? "tok/s"), Font.Micro, Theme.Secondary));
            if (label is not null) line.Inlines.InsertBefore(line.Inlines.FirstInline, Ui.Run(label + " ", Font.Meta, Theme.Secondary));
            return line;
        }
        var view = Dashboard.Fit(room,
            () => Value(headline.Project is { } project ? Loc("지금 속도 · ", "Speed now · ") + project : Loc("지금 속도", "Speed now")),
            () => Value(headline.Project ?? Loc("지금 속도", "Speed now")), () => Value());
        view.ToolTip = headline.Help;
        System.Windows.Automation.AutomationProperties.SetName(view, Loc("지금 속도", "Speed now") + ", " + headline.Spoken);
        return view;
    }
}

/// Label band 10 + plot 36 + gap 3 + axis 12 (F-3). Loading draws only the baseline and the axis.
sealed class FlowChart : FrameworkElement
{
    IReadOnlyList<int> values = [];
    IReadOnlyList<bool> fresh = [];
    bool loading = true;

    public void Set(IReadOnlyList<int> hero, IReadOnlyList<bool> recent, bool isLoading)
    {
        values = hero;
        fresh = recent;
        loading = isLoading;
        InvalidateVisual();
    }

    FormattedText Label(string text) => new(text, Lang.Culture, FlowDirection.LeftToRight,
        new Typeface(Ui.Family, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal), 10, Theme.Brush(Theme.Secondary), VisualTreeHelper.GetDpi(this).PixelsPerDip);

    protected override void OnRender(DrawingContext context)
    {
        var width = ActualWidth;
        var peak = loading || values.Count == 0 ? 0 : values.Max();
        var scale = FlowMath.NiceMax(peak);
        if (peak > 0)
        {
            var label = Label(Format.CompactTokens((int)scale));
            context.DrawText(label, new Point(width - label.Width, 10 - label.Height + 1));
            context.DrawRectangle(Theme.Brush(Theme.Primary(0.08)), null, new Rect(0, 10, width, 0.5));
            var plot = new Rect(0, 10, width, 35);
            context.DrawGeometry(Theme.Brush(Theme.Neutral), null, Bars(plot, scale, null));
            context.DrawGeometry(Theme.Brush(Theme.Activity), null, Bars(plot, scale, fresh));
        }
        context.DrawRectangle(Theme.Brush(Theme.Primary(0.12)), null, new Rect(0, 45, width, 1));
        // Minute marks below the baseline at −4, −3, −2 and −1 min.
        for (var minute = 1; minute <= 4; minute++)
            context.DrawRectangle(Theme.Brush(Theme.Primary(0.18)), null, new Rect(Math.Round(width * (1 - minute / 5.0) * 2) / 2 - 0.5, 46, 1, 3));
        var start = Label(Format.Ago(Format.Span(5, Format.TimeUnit.Minute)));
        context.DrawText(start, new Point(0, 49));
        var end = Label(Loc("지금", "now"));
        context.DrawText(end, new Point(width - end.Width, 49));
    }

    /// FlowBars: fixed slots, 0.6 of the slot wide, at least 2 × 2, only the top corners rounded (1).
    Geometry Bars(Rect rect, double scale, IReadOnlyList<bool>? mask)
    {
        var geometry = new StreamGeometry();
        if (values.Count == 0 || scale <= 0) return geometry;
        using var g = geometry.Open();
        var slot = rect.Width / values.Count;
        var width = Math.Max(2, slot * 0.6);
        for (var i = 0; i < values.Count; i++)
        {
            if (values[i] <= 0 || (mask is not null && !(i < mask.Count && mask[i]))) continue;
            var height = Math.Min(rect.Height, Math.Max(2, rect.Height * values[i] / scale));
            var x = Math.Round((rect.X + slot * i + (slot - width) / 2) * 2) / 2;
            var bar = new Rect(x, rect.Bottom - height, width, height);
            var r = Math.Min(1, Math.Min(width / 2, height / 2));
            g.BeginFigure(bar.BottomLeft, true, true);
            g.LineTo(new Point(bar.Left, bar.Top + r), false, false);
            g.QuadraticBezierTo(bar.TopLeft, new Point(bar.Left + r, bar.Top), false, false);
            g.LineTo(new Point(bar.Right - r, bar.Top), false, false);
            g.QuadraticBezierTo(bar.TopRight, new Point(bar.Right, bar.Top + r), false, false);
            g.LineTo(bar.BottomRight, false, false);
        }
        geometry.Freeze();
        return geometry;
    }
}

/// The AI container's bottom rows (Codex, then Claude): the last recorded window, always with its record age; no forecast.
sealed class LimitRow : StackPanel
{
    readonly TextBlock title = Ui.Text("", Font.Meta, Theme.Secondary);
    readonly TextBlock value = Ui.Line();
    readonly Border details = new();
    readonly Meter meter = new() { Margin = new Thickness(0, 5, 0, 0) };
    IReadOnlyList<string> shown = [];

    public LimitRow()
    {
        Margin = new Thickness(0);
        // 13 DIP value beside 11 DIP texts: raised by the ascent difference so all three share one baseline.
        value.Margin = new Thickness(0, -2, 0, 0);
        var line = Dashboard.Spread(Dashboard.Row(6, title, value), details);
        line.Height = 16;
        var body = new StackPanel { Margin = new Thickness(Dashboard.Inset, 8, Dashboard.Inset, 8) };
        body.Children.Add(line);
        body.Children.Add(meter);
        Children.Add(Ui.Hairline(Dashboard.Inset, Dashboard.Inset));
        Children.Add(body);
    }

    public void Update(UsageLimitSummary limit, DateTimeOffset now)
    {
        var expired = limit.Expired(now);
        title.Text = limit.Title;
        value.Inlines.Clear();
        if (expired) value.Inlines.Add(Ui.Run("—", Font.Value, Theme.Tertiary));
        else
        {
            value.Inlines.Add(Ui.Run(limit.PercentText, Font.Value, limit.IsOld(now) ? Theme.Secondary : Theme.Label));
            value.Inlines.Add(Ui.Run("%", Font.Micro, Theme.Secondary));
            value.Inlines.Add(Ui.Run(Loc(" 사용", " used"), Font.Meta, Theme.Secondary));
        }
        // The reset countdown is never truncated; the record age drops first.
        var texts = limit.Details(now);
        if (!texts.SequenceEqual(shown))
        {
            shown = texts;
            title.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            value.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - 2 * Dashboard.Inset - title.DesiredSize.Width - 6 - value.DesiredSize.Width - 8;
            details.Child = Dashboard.Fit(room, [.. texts.Select(text => (Func<FrameworkElement>)(() => Ui.Text(text, Font.MetaMono, Theme.Secondary)))]);
        }
        meter.Visibility = expired ? Visibility.Collapsed : Visibility.Visible;
        meter.Set(limit.UsedPercent / 100, Theme.MeterColor(limit.UsedPercent));
        Ui.Help(this, limit.Help(now));
        System.Windows.Automation.AutomationProperties.SetName(this, limit.Title + ", " + limit.Spoken(now));
    }
}

sealed class SessionsHeader : Grid
{
    readonly TextBlock title = Ui.Text(Loc("세션", "Sessions"), Font.Title);
    readonly TextBlock toggleText = Ui.Text("", Font.MetaMedium, Theme.Secondary);
    readonly TextBlock chevron = Ui.Icon(Ui.ChevronDown, 9, Theme.Secondary);
    readonly Button toggle;

    public SessionsHeader(Action toggleExpanded)
    {
        Height = 18;
        title.VerticalAlignment = VerticalAlignment.Center;
        chevron.Margin = new Thickness(3, 1, 0, 0);
        toggle = Ui.HoverButton(new Border { Child = Dashboard.Row(0, toggleText, chevron), Padding = new Thickness(6, 0, 6, 0), Height = 20 },
            toggleExpanded, "");
        toggle.HorizontalAlignment = HorizontalAlignment.Right;
        toggle.Margin = new Thickness(0, -1, -6, -1);
        Children.Add(title);
        Children.Add(toggle);
    }

    public void Update(SessionListModel list, bool expanded)
    {
        Ui.Help(title, Loc("↑↓ 이동 · Enter 상세 · Ctrl+C ID 복사", "↑↓ move · Enter details · Ctrl+C copy ID")
            + (list.ShowsSpeedColumn ? "" : Loc("\n속도 실측 없음 · 로그 시각으로 추정하지 않습니다", "\nNo measured speed · not estimated from log times")));
        var visible = list.HiddenGroups + list.HiddenChildren > 0 || expanded;
        toggle.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible) return;
        toggleText.Text = expanded ? Loc("접기", "Show less")
            : list.HiddenGroups > 0 ? Loc($"{list.Counts.Groups}개 모두 보기", $"Show all {list.Counts.Groups}")
            : Loc($"하위 {list.HiddenChildren}개 더 보기", $"Show {Plural(list.HiddenChildren, "more subagent")}");
        chevron.Text = (expanded ? Ui.ChevronUp : Ui.ChevronDown).ToString();
        Ui.Help(toggle, Loc($"하위 에이전트 포함 {list.Counts.Readings}개 기록", $"{Plural(list.Counts.Readings, "record")} including subagents")
            + (expanded || list.HiddenGroups == 0 ? "" : Loc($" · 접힌 세션 {list.HiddenGroups}개", $" · {Plural(list.HiddenGroups, "collapsed session")}")));
        System.Windows.Automation.AutomationProperties.SetName(toggle, expanded ? Loc("세션 목록 접기", "Collapse session list")
            : list.HiddenGroups > 0 ? Loc("세션 목록 모두 보기", "Show all sessions") : Loc("하위 에이전트 더 보기", "Show more subagents"));
    }
}

/// The borderless bottom area (8): label 10, value 13, aux; the whole area opens Task Manager.
sealed class SystemArea : StackPanel
{
    readonly Cell cpu = new("CPU", Loc("CPU 전체 코어 사용률", "CPU usage across all cores"));
    readonly Cell memory = new(Loc("메모리", "Memory"), Loc("메모리: 사용 중 / 실제 메모리", "Memory: in use / physical memory"));
    readonly Cell disk = new(Loc("저장 공간", "Storage"), Loc("저장 공간: 홈 폴더가 있는 볼륨의 사용량 / 전체 용량", "Storage: used / total capacity of the volume with your home folder"));
    readonly Cell battery = new(Loc("배터리", "Battery"), "");
    readonly Cell network = new(Loc("네트워크", "Network"), "");
    readonly Grid cells = new() { Height = 44 };
    readonly Rectangle peak = new() { Width = 1, Height = 6, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    readonly TextBlock upload = Ui.Text("", Font.Micro, Theme.Secondary);
    double cpuWidth = 56;
    bool? batteryShown;

    sealed class Cell : StackPanel
    {
        public readonly TextBlock Value = Ui.Line();
        public readonly Grid Aux = new() { Height = 11, Margin = new Thickness(0, 3, 0, 0) };
        public readonly Meter Meter = new();

        public Cell(string title, string help)
        {
            var label = Ui.Text(title, Font.Micro, Theme.Secondary);
            label.Height = 14;
            Value.Height = 16;
            Children.Add(label);
            Children.Add(Value);
            Children.Add(Aux);
            Meter.VerticalAlignment = VerticalAlignment.Top;
            Aux.Children.Add(Meter);
            ToolTip = string.IsNullOrEmpty(help) ? null : help;
            System.Windows.Automation.AutomationProperties.SetName(this, title);
        }
    }

    public SystemArea(Action open)
    {
        Children.Add(new Border { Height = 0.5, Background = Theme.Brush(Theme.Hairline), Margin = new Thickness(-Dashboard.Gutter, 0, -Dashboard.Gutter, 0) });
        var arrow = Ui.Icon(Ui.OpenOut, 10, Theme.Secondary);
        arrow.HorizontalAlignment = HorizontalAlignment.Right;
        arrow.VerticalAlignment = VerticalAlignment.Top;
        arrow.Margin = new Thickness(6);
        arrow.Visibility = Visibility.Hidden;
        var area = new Grid { Margin = new Thickness(0, 4, 0, 0), Background = Brushes.Transparent, Cursor = System.Windows.Input.Cursors.Hand };
        var hover = new Border { CornerRadius = new CornerRadius(10) };
        area.Children.Add(hover);
        cells.Margin = new Thickness(Dashboard.Inset, 6, Dashboard.Inset, 6);
        area.Children.Add(cells);
        area.Children.Add(arrow);
        area.MouseEnter += (_, _) => { hover.Background = Theme.Brush(Theme.Hover); arrow.Visibility = Visibility.Visible; };
        area.MouseLeave += (_, _) => { hover.Background = null; arrow.Visibility = Visibility.Hidden; };
        area.MouseLeftButtonUp += (_, _) => open();
        area.ToolTip = Loc("작업 관리자에서 자세히 보기", "Show details in Task Manager");
        System.Windows.Automation.AutomationProperties.SetName(area, Loc("시스템", "System"));
        peak.Fill = Theme.Brush(Theme.Primary(0.5));
        cpu.Aux.Children.Add(peak);
        cpu.Meter.Margin = new Thickness(0, 1, 0, 0);
        network.Aux.Children.Clear();
        network.Aux.Children.Add(upload);
        Typography.SetNumeralAlignment(upload, FontNumeralAlignment.Tabular);
        Children.Add(area);
    }

    void Layout(bool hasBattery)
    {
        if (batteryShown == hasBattery) return;
        batteryShown = hasBattery;
        cells.Children.Clear();
        cells.ColumnDefinitions.Clear();
        double[] widths = hasBattery ? [56, 72, 56, 56, 76] : [64, 80, 64, 120];
        cpuWidth = widths[0];
        Cell[] order = hasBattery ? [cpu, memory, disk, battery, network] : [cpu, memory, disk, network];
        for (var i = 0; i < order.Length; i++)
        {
            cells.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(widths[i] + (i < order.Length - 1 ? 12 : 0)) });
            // The 12 DIP gap is the cell's margin, so the cell and its meter are widths[i] wide (the CPU peak mark uses it).
            order[i].Margin = new Thickness(0, 0, i < order.Length - 1 ? 12 : 0, 0);
            Grid.SetColumn(order[i], i);
            cells.Children.Add(order[i]);
        }
    }

    /// Before the first sample a redacted "00%", so the skeleton has the value's width.
    static void Percent(TextBlock text, bool hasSample, double? value)
    {
        text.Inlines.Clear();
        text.Opacity = hasSample ? 1 : 0.25;
        if (!hasSample) { text.Inlines.Add(Ui.Run("00", Font.Value)); text.Inlines.Add(Ui.Run("%", Font.Micro)); return; }
        if (value is not { } v || !double.IsFinite(v)) { text.Inlines.Add(Ui.Run("—", Font.Value, Theme.Tertiary)); return; }
        text.Inlines.Add(Ui.Run(v.ToString("F0", System.Globalization.CultureInfo.InvariantCulture), Font.Value));
        text.Inlines.Add(Ui.Run("%", Font.Micro, Theme.Secondary));
    }

    public void Update(MonitorState state)
    {
        var system = state.System;
        var has = state.HasSample;
        Layout(system.BatteryPresent);

        var cpuValue = has ? system.CpuPercent : null;
        double? cpuPeak = has && state.CpuHistory.Count > 0 ? state.CpuHistory.TakeLast(30).Max() : null;
        Percent(cpu.Value, has, cpuValue);
        cpu.Meter.Set((cpuValue ?? 0) / 100, Theme.MeterColor(cpuValue));
        peak.Visibility = cpuPeak is null ? Visibility.Collapsed : Visibility.Visible;
        peak.Margin = new Thickness(Math.Round(cpuWidth * Math.Clamp((cpuPeak ?? 0) / 100, 0, 1) - 0.5), 0, 0, 0);
        Ui.Help(cpu, Loc("CPU 전체 코어 사용률", "CPU usage across all cores")
            + (cpuPeak is { } p ? Loc($"\n최근 30초 최고 {p:F0}%", $"\nPeak {p:F0}% in the last 30 s") : ""));

        var memoryValue = has ? Format.Ratio(system.MemoryUsedBytes, system.MemoryTotalBytes) : null;
        Percent(memory.Value, has, memoryValue);
        // The mac colours this meter by memory pressure, which Windows doesn't report (DESIGN §3.2): always neutral.
        memory.Meter.Set((memoryValue ?? 0) / 100, Theme.Neutral);
        System.Windows.Automation.AutomationProperties.SetHelpText(memory, $"{Format.Percent(memoryValue)}, {Format.Capacity(system.MemoryUsedBytes, system.MemoryTotalBytes)}");

        var diskValue = has ? Format.Ratio(system.DiskUsedBytes, system.DiskTotalBytes) : null;
        Percent(disk.Value, has, diskValue);
        disk.Meter.Set((diskValue ?? 0) / 100, Theme.MeterColor(diskValue));

        if (system.BatteryPresent)
        {
            var level = has ? system.BatteryPercent : null;
            var charging = system.IsCharging == true;
            Percent(battery.Value, has, level);
            if (charging) battery.Value.Inlines.Add(new System.Windows.Documents.Run(" " + Ui.Bolt) { FontFamily = Ui.IconFamily, FontSize = 10, Foreground = Theme.Brush(Theme.Secondary) });
            var color = level is not { } l || charging ? Theme.Neutral : l <= 10 ? Theme.Critical : l <= 20 ? Theme.Warning : Theme.Neutral;
            battery.Meter.Set((level ?? 0) / 100, color);
            Ui.Help(battery, Loc("배터리 잔량", "Battery level") + $" · {Format.Power(system)}");
        }

        var download = StatusBarContent.SplitRate(StatusBarContent.NetworkRate(has ? system.DownloadBytesPerSecond : null));
        var uploadRate = StatusBarContent.NetworkRate(has ? system.UploadBytesPerSecond : null);
        var up = StatusBarContent.SplitRate(uploadRate);
        var shownDown = has ? download : ("0.0", "kB/s");
        var shownUp = has ? up : ("0.0", "kB/s");
        network.Value.Inlines.Clear();
        network.Value.Opacity = has ? 1 : 0.25;
        network.Value.Inlines.Add(Ui.Run("↓ " + shownDown.Item1, Font.Value));
        network.Value.Inlines.Add(Ui.Run(shownDown.Item2.Length == 0 ? "" : " " + shownDown.Item2, Font.Micro, Theme.Secondary));
        upload.Text = "↑ " + shownUp.Item1 + (shownUp.Item2.Length == 0 ? "" : " " + shownUp.Item2);
        upload.Opacity = has ? 1 : 0.25;
        Ui.Help(network, Loc("네트워크: Wi-Fi·Ethernet 합산, VPN·루프백 제외", "Network: Wi-Fi and Ethernet combined, excluding VPN and loopback")
            + "\n" + (system.LocalIPs.Count == 0 ? Loc("IPv4 주소 미확인", "IPv4 address unknown") : "IPv4 " + string.Join(" · ", system.LocalIPs)));
        System.Windows.Automation.AutomationProperties.SetHelpText(network,
            Loc($"다운로드 {download.Number}{download.Unit}, 업로드 {uploadRate}", $"Download {download.Number}{download.Unit}, upload {uploadRate}"));
    }
}

/// One leading status item (9), and the update item trailing.
sealed class Footer : Grid
{
    readonly DashboardActions actions;
    readonly Border leading = new() { HorizontalAlignment = HorizontalAlignment.Left };
    readonly Border trailing = new() { HorizontalAlignment = HorizontalAlignment.Right };
    object? leadingKey, trailingKey;

    public Footer(DashboardActions actions)
    {
        this.actions = actions;
        Height = 18;
        Children.Add(leading);
        Children.Add(trailing);
    }

    public void Update(FooterStatus status, TelemetryNotice? notice, string help, UpdateNotice? update)
    {
        var key = (status, notice);
        if (!Equals(key, leadingKey))
        {
            leadingKey = key;
            leading.Child = status.Kind switch
            {
                FooterStatusKind.Loading => Item(Dashboard.Dot(Theme.Idle), status.Text, false),
                FooterStatusKind.AiDelay or FooterStatusKind.SystemDelay => Item(Dashboard.Dot(Theme.Warning), status.Text, true),
                FooterStatusKind.Notice => Ui.HoverButton(new Border { Padding = new Thickness(5, 0, 5, 0), Child = Item(
                    Ui.Icon(notice?.IsProblem ?? true ? Ui.WarningIcon : Ui.InfoIcon, 11, notice?.IsProblem ?? true ? Theme.Warning : Theme.Secondary),
                    status.Text, notice?.IsProblem ?? true) }, actions.OpenTelemetrySettings, notice?.Help ?? help),
                _ => Ui.HoverButton(new Border { Padding = new Thickness(5, 0, 5, 0), Child = Item(Dashboard.Dot(Theme.Activity), status.Text, false) },
                    actions.OpenTelemetrySettings, help),
            };
            if (status.Kind is FooterStatusKind.Notice or FooterStatusKind.Live) leading.Margin = new Thickness(-5, 0, 0, 0);
            else leading.Margin = new Thickness(0);
        }
        if (status.Kind is FooterStatusKind.Loading) Ui.Help(leading, Loc("첫 수집을 준비하고 있습니다", "Preparing the first sample"));
        else if (status.Kind is FooterStatusKind.AiDelay or FooterStatusKind.SystemDelay) Ui.Help(leading, help);
        else if (leading.Child is Button button) Ui.Help(button, status.Kind == FooterStatusKind.Notice ? notice?.Help ?? help : help);

        if (!Equals(update, trailingKey))
        {
            trailingKey = update;
            leading.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - leading.DesiredSize.Width - 12;
            trailing.Child = update is null ? null : Dashboard.Fit(room, () => UpdateItem(update, true), () => UpdateItem(update, false));
        }
    }

    static FrameworkElement Item(UIElement mark, string text, bool primary)
    {
        var row = Dashboard.Row(5, mark, Ui.Text(text, Font.MetaMono, primary ? Theme.Label : Theme.Secondary));
        row.Height = 18;
        foreach (FrameworkElement child in row.Children) child.VerticalAlignment = VerticalAlignment.Center;
        return row;
    }

    /// The quiet update line: secondary text, accent text buttons, ✕ hides it for that version only.
    FrameworkElement UpdateItem(UpdateNotice notice, bool detail)
    {
        var failed = notice.Kind == UpdateNoticeKind.Failed;
        var label = Dashboard.Row(4, failed ? Ui.Icon(Ui.WarningIcon, 11, Theme.Warning) : null,
            Ui.Text(detail ? string.Join(" · ", new[] { notice.Text, notice.Detail }.OfType<string>()) : notice.Text, Font.MetaMono, Theme.Secondary));
        label.ToolTip = notice.Help;
        label.Margin = new Thickness(0, 0, 2, 0);
        label.VerticalAlignment = VerticalAlignment.Center;
        var row = Dashboard.Row(0, label);
        Button TextButton(string title, string help, UpdateCommand command) =>
            Ui.HoverButton(new Border { Padding = new Thickness(5, 0, 5, 0), Height = 18, Child = Ui.Text(title, Font.MetaMedium, Theme.Accent) },
                () => actions.Update(command), help);
        Button Close(string help) => Ui.HoverButton(new Border { Width = 18, Height = 18, Child = Centered(Ui.Icon(Ui.Close, 9, Theme.Secondary)) },
            () => actions.Update(UpdateCommand.Dismiss), help, circle: true);
        switch (notice.Kind)
        {
            case UpdateNoticeKind.Available:
                row.Children.Add(TextButton(Loc("업데이트", "Update"), notice.Help, UpdateCommand.Install));
                row.Children.Add(Close(Loc("이 버전 알림 숨기기", "Hide notice for this version")));
                break;
            case UpdateNoticeKind.Failed:
                if (notice.Retryable)
                    row.Children.Add(TextButton(Loc("다시 시도", "Try Again"), Loc("릴리스 정보를 다시 확인하고 내려받습니다", "Checks the release again and downloads it"), UpdateCommand.Install));
                row.Children.Add(Ui.HoverButton(new Border { Width = 18, Height = 18, Child = Centered(Ui.Icon(Ui.OpenOut, 10, Theme.Secondary)) },
                    () => actions.Update(UpdateCommand.OpenReleasePage), Loc("릴리스 페이지 열기", "Open release page"), circle: true));
                row.Children.Add(Close(Loc("이 버전 알림 숨기기", "Hide notice for this version")));
                break;
            case UpdateNoticeKind.Updated:
                row.Children.Add(Close(Loc("알림 닫기", "Close notice")));
                break;
        }
        return row;
    }

    static Border Centered(UIElement child) => new() { Child = child, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
}
