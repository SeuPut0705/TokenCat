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

    readonly bool snapshot;
    readonly DashboardActions actions;
    readonly Header header;
    readonly Border onboardingSlot = new() { Margin = new Thickness(0, Block, 0, 0) };
    readonly FlowCard flow;
    readonly StackPanel limits = new();
    readonly Border limitsBox;
    readonly SessionsHeader sessionsHeader;
    readonly SessionList list;
    readonly SystemArea system;
    readonly Footer footer;
    OnboardingOutcome? onboardingShown;
    IReadOnlyList<TokenSource> onboardingClients = TokenSource.DefaultClients;
    bool flowOpened;
    public DashboardInput? Input { get; private set; }

    public Dashboard(DashboardActions actions, bool panel = false, bool snapshot = false, string? selection = null, string? detail = null,
        bool expanded = false)
    {
        this.actions = actions;
        this.snapshot = snapshot;
        header = new Header(actions, panel, interactive: !snapshot);
        flow = new FlowCard();
        list = new SessionList(this, panel, snapshot, selection, detail, expanded) { Recheck = actions.RecheckLogFolders };
        sessionsHeader = new SessionsHeader();
        system = new SystemArea(actions.TaskManager);
        footer = new Footer(actions);

        // The usage limits get their own container right under the header, above the output-token card.
        limitsBox = Ui.Container(new Border { Child = limits, Padding = new Thickness(Inset, InsetVertical, Inset, InsetVertical) });
        var root = new Grid { Width = PanelWidth, Margin = new Thickness(0), Background = Theme.Brush(Theme.Background) };
        var content = new Grid { Margin = new Thickness(Gutter, 12, Gutter, 12) };
        UIElement[] rows =
        [
            header, onboardingSlot, Pad(limitsBox, Block), Pad(Ui.Container(flow), Block), Pad(sessionsHeader, Block), Pad(list, TitleGap),
            Pad(system, Block), Pad(footer, Block),
        ];
        for (var i = 0; i < rows.Length; i++)
        {
            content.RowDefinitions.Add(new RowDefinition { Height = panel && ReferenceEquals(rows[i], list) ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
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

    public string? SelectedGroup => list.SelectedGroup;

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

        var headerStatus = SessionPresentation.Header(state.Sessions.Counts, loading, state.Now, input.QuietSince, false);

        var notice = TelemetryNoticeFor(input);
        // The status line bridge note only while the original status line command is known.
        OnboardingOutcome? outcome = snapshot || input.OnboardingSeen ? null : OnboardingOutcome.Make(notice, input.SetupNote, input.SetupFailure,
            state.TelemetryState, input.ClaudeBridged == true && !input.ConnectNotes.Contains(TelemetrySetupNote.OriginalUnknown), input.OptedOut);
        var clients = OnboardingCard.Clients(state.ListedSources, input.ConnectNotes);
        if (!Equals(outcome, onboardingShown) || !clients.SequenceEqual(onboardingClients))
        {
            onboardingShown = outcome;
            onboardingClients = clients;
            onboardingSlot.Child = outcome is null ? null : OnboardingCard.Build(outcome, actions, clients);
            onboardingSlot.Visibility = outcome is null ? Visibility.Collapsed : Visibility.Visible;
        }

        var lists = list.Model(input);
        flow.Update(state, loading, FlowEmpty(input) && !flowOpened,
            loading ? null : SessionPresentation.Headline(lists, state.Now, state.TelemetryRestartNeeded));
        var limitRows = state.UsageLimits;
        limitsBox.Visibility = limitRows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Reconcile.Panel(limits, limitCache, limitRows.Select((limit, index) => Reconcile.Item($"{limit.Source}:{limit.Account?.Key ?? "legacy"}",
            () => new LimitRow(), (LimitRow row) => row.Update(limit, state.Now, first: index == 0))));

        sessionsHeader.Update(lists);
        list.Show(input, lists);
        system.Update(state);
        var tokenDelay = state.TokensSampledAt is { } sampled ? (int)(state.Now - sampled).TotalSeconds : 0;
        var status = SessionPresentation.Footer(!state.HasSample || loading, tokenDelay, (int)(state.Now - state.System.SampledAt).TotalSeconds, notice);
        var help = Loc("시스템과 AI 기록을 1초마다, 로그 변경 시 즉시 확인합니다", "Checks system and AI records every second, and right away when a log changes")
            + $"\n{SessionPresentation.TelemetryReceipt(state.TelemetryLastReceived, state.Now)}\n{state.TelemetryStatus}";
        // "실시간" alone says nothing, so the footer shows only for a delay, a notice or an update; its help moves to the header.
        header.Update(headerStatus with { Help = headerStatus.Help + "\n\n" + help });
        var update = input.Update.Notice(input.DismissedUpdateVersion);
        footer.Visibility = status.Kind != FooterStatusKind.Live || update is not null ? Visibility.Visible : Visibility.Collapsed;
        footer.Update(status, notice, help, update);
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

    /// The clients the telemetry line names: Codex and Claude Code, plus Gemini CLI and Qwen Code once detected and not skipped.
    public static IReadOnlyList<TokenSource> Clients(IReadOnlyList<TokenSource> listed, IReadOnlyList<TelemetrySetupNote> notes) =>
        [.. TokenSource.TelemetryClients.Where(source => listed.Contains(source)
            && !notes.Any(note => note is TelemetrySetupNote.ClientSkipped skipped && skipped.Source == source))];

    static (string Title, string Detail, string? Tail) Telemetry(OnboardingOutcome outcome, IReadOnlyList<TokenSource> clients)
    {
        var names = string.Join(Loc("·", " and "), clients.Select(source => source.Title));
        return outcome switch
        {
            OnboardingOutcome.Added(var bridged) => (Loc($"실측을 위해 {names} 설정에 로컬 전송을 추가했습니다", $"Added local telemetry to {names} settings"),
                bridged ? Loc("Claude Code 상태 표시줄에 한도만 읽는 브리지를 추가했습니다(출력 없음)", "Also added a status line bridge that only reads limits (prints nothing)")
                    : Loc("새로 실행할 때부터 적용됩니다", "Applies from the next launch"),
                bridged ? Loc("새로 실행할 때부터 적용", "Applies from the next launch") : null),
            OnboardingOutcome.Skipped(var reason) => (Loc("실측 연결을 건너뛰었습니다", "Skipped connecting telemetry"), reason, null),
            OnboardingOutcome.Failed(var reason) => (Loc("실측 연결을 완료하지 못했습니다", "Couldn't finish connecting telemetry"), reason, null),
            OnboardingOutcome.CollectorDown(var text) => (Loc("실측 연결을 하지 않았습니다", "Didn't connect telemetry"), text, null),
            _ => (Loc("실측 수집기를 준비하고 있습니다", "Preparing the telemetry collector"),
                Loc($"준비되면 {names} 설정에 로컬 전송을 추가합니다", $"Adds local telemetry to {names} settings when it's ready"), null),
        };
    }

    /// `clients`: the names the telemetry line gives (`Clients`); Codex and Claude Code by default.
    public static FrameworkElement Build(OnboardingOutcome outcome, DashboardActions actions, IReadOnlyList<TokenSource>? clients = null)
    {
        var added = outcome is OnboardingOutcome.Added;
        var needsSettings = outcome is OnboardingOutcome.Skipped or OnboardingOutcome.Failed or OnboardingOutcome.CollectorDown;
        var stack = new StackPanel { Margin = new Thickness(12) };
        var close = Ui.HoverButton(new Border { Width = 18, Height = 18, Child = Center(Ui.Icon(Ui.Close, 10, Theme.Secondary)) },
            actions.DismissOnboarding, Loc("안내 닫기", "Close welcome"), circle: true);
        var title = Dashboard.Row(6, Sprites.HeadImage(RunnerHead.Normal, 12, 11), Ui.Text(Loc("TokenCat이 하는 일", "What TokenCat does"), Font.MetaMedium));
        title.VerticalAlignment = VerticalAlignment.Center;
        stack.Children.Add(Dashboard.Spread(title, close));
        stack.Children.Add(Line(Ui.Shield, Loc("대화 본문은 저장하지 않습니다", "Doesn't store conversation text"),
            Loc("모델·토큰 수·도구 종류·프로젝트 폴더 같은 메타데이터만 읽습니다", "Reads only metadata such as models, token counts, tool types and project folders")));
        var telemetry = Telemetry(outcome, clients ?? TokenSource.DefaultClients);
        // A factory: each layout candidate needs its own link elements (a WPF element has one parent).
        UIElement[] Links() => added
            ? [Ui.Link(Loc("백업 보기", "Show backup"), () => Shell.Reveal(System.IO.Path.Combine(AppPaths.Support, "telemetry-backups")),
                Loc($"원본 백업 {BackupPath} · 탐색기에서 보여 주기만 합니다", $"Original backup {BackupPath} · only shows it in File Explorer"))]
            : [Ui.Link(Loc("설정 열기", "Open settings"), actions.OpenTelemetrySettings, Loc("설정의 실측 탭을 엽니다", "Opens the Telemetry tab in Settings"), true)];
        var telemetryHelp = string.Join(" · ", new[] { telemetry.Detail, telemetry.Tail }.OfType<string>());
        stack.Children.Add(Line(Ui.Sliders, telemetry.Title, telemetryHelp, added || needsSettings ? Links : null, needsSettings ? telemetry.Detail : null));
        stack.Children.Add(Line(Ui.Blocked, Loc("모델 호출·계정 로그인을 하지 않습니다", "Doesn't call models or sign in to accounts"),
            Loc("인터넷 요청은 GitHub 새 버전 확인·내려받기와 OpenAI·Anthropic 사용량 확인뿐입니다(설정에서 끄기)",
                "Only goes online to check GitHub for new versions and to ask OpenAI and Anthropic for usage (turn off in Settings)")));
        return Ui.Container(stack, tint: true);
    }

    static Border Center(UIElement child) => new() { Child = child, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    /// One line per point: the title, its sentence in help. `detail` (telemetry that needs Settings) stays visible with the links
    /// after it; otherwise the links follow the title when they fit, else start the next line.
    static FrameworkElement Line(char icon, string title, string help, Func<UIElement[]>? links = null, string? detail = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 0), Background = Brushes.Transparent, ToolTip = help };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var symbol = Ui.Icon(icon, 13, Theme.Accent);
        symbol.VerticalAlignment = VerticalAlignment.Top;
        symbol.Margin = new Thickness(0, 1, 0, 0);
        grid.Children.Add(symbol);
        var texts = new StackPanel();
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        System.Windows.Automation.AutomationProperties.SetHelpText(grid, help);
        const double width = Dashboard.PanelWidth - 2 * Dashboard.Gutter - 24 - 20;
        FrameworkElement TwoLines(string first, Font font, Color color)
        {
            var two = new StackPanel();
            two.Children.Add(Wrap(Ui.Text(first, font, color)));
            two.Children.Add(Dashboard.Row(6, links!()));
            return two;
        }
        if (detail is not null)
        {
            texts.Children.Add(Wrap(Ui.Text(title, Font.MetaMedium)));
            texts.Children.Add(Dashboard.Fit(width, () => Dashboard.Row(6, [Ui.Text(detail, Font.Meta, Theme.Secondary), .. links!()]),
                () => TwoLines(detail, Font.Meta, Theme.Secondary)));
        }
        else if (links is not null)
            texts.Children.Add(Dashboard.Fit(width, () => Dashboard.Row(6, [Ui.Text(title, Font.MetaMedium), .. links()]),
                () => TwoLines(title, Font.MetaMedium, Theme.Label)));
        else texts.Children.Add(Wrap(Ui.Text(title, Font.MetaMedium)));
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

/// The output-token card (F-1–F-6): log records, never a speed, plus the measured "지금 속도". Title row 16 (the provider
/// split and the total), meta row 16 (the last record or why none, then the speed), chart 43: about 109 DIP with padding,
/// so the session list gets the height.
sealed class FlowCard : Border
{
    static string HelpText => Loc("막대 하나는 5초 동안 로그에 기록된 출력 토큰 수입니다. 코딩 에이전트는 응답이나 메시지가 끝날 때 기록하므로 생성 중인 토큰은 아직 포함되지 않습니다. 속도로 환산하지 않습니다.",
        "Each bar is the number of output tokens recorded in the log over 5 seconds. Coding agents record them when a response or message ends, so tokens still being generated aren't included yet. They're never converted into a speed.");
    static string Subtitle => Loc("최근 5분 · 로그 기록 기준", "Last 5 min · based on log records");
    const double Room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - 2 * Dashboard.Inset;

    readonly Grid collapsed = new() { Height = 20 };
    readonly TextBlock collapsedLast = Ui.Text("", Font.MetaMono, Theme.Secondary);
    readonly StackPanel card = new();
    readonly TextBlock title = Ui.Text(Loc("출력 토큰", "Output tokens"), Font.Title);
    readonly Border splitSlot = new() { Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock total = Ui.Line();
    readonly FrameworkElement trailing;
    readonly Border metaSlot = new() { Height = 16, Margin = new Thickness(0, 6, 0, 0) };
    readonly FlowChart chart = new() { Height = FlowChart.ChartHeight, Margin = new Thickness(0, 8, 0, 0) };
    object? splitKey, metaKey;

    public FlowCard()
    {
        Padding = new Thickness(Dashboard.Inset, Dashboard.InsetVertical, Dashboard.Inset, Dashboard.InsetVertical);
        // One line, so the caption sits on the title's baseline.
        var collapsedTitle = Ui.Line(Ui.Run(Loc("출력 토큰", "Output tokens"), Font.Title),
            Ui.Run("  " + Loc("최근 5분 기록 없음", "None in the last 5 min"), Font.Meta, Theme.Secondary));
        collapsedTitle.VerticalAlignment = collapsedLast.VerticalAlignment = VerticalAlignment.Center;
        collapsed.Children.Add(Dashboard.Spread(collapsedTitle, collapsedLast));

        var info = Ui.HoverButton(new Border { Width = 20, Height = 20, Child = new Border
            { Child = Ui.Icon(Ui.InfoIcon, 11, Theme.Secondary), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } },
            () => { }, Loc("출력 토큰 설명", "About output tokens"), circle: true);
        var popup = new Popup { PlacementTarget = info, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = false, Child = Help() };
        info.Click += (_, _) => popup.IsOpen = !popup.IsOpen;
        title.VerticalAlignment = total.VerticalAlignment = VerticalAlignment.Center;
        title.TextTrimming = TextTrimming.None;
        Ui.Help(title, Subtitle);
        Ui.Help(total, Subtitle);
        // 22 tall with -3 above and below: the metric total's ascent and descenders fit while the row keeps 16.
        trailing = Dashboard.Row(4, total, info);
        trailing.Margin = new Thickness(0, -3, -4, -3);
        trailing.VerticalAlignment = VerticalAlignment.Center;
        var titleRow = Dashboard.Spread(Dashboard.Row(0, title, splitSlot), trailing);
        titleRow.Height = 16;
        card.Children.Add(titleRow);
        card.Children.Add(metaSlot);
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

    /// The subtitle, plus the bar scale that used to sit above the plot.
    static string ChartHelp(IReadOnlyList<int> hero, bool loading)
    {
        var peak = loading || hero.Count == 0 ? 0 : hero.Max();
        if (peak <= 0) return Subtitle;
        var scale = Format.CompactTokens((int)FlowMath.NiceMax(peak));
        return Subtitle + Loc($"\n막대 눈금: 5초당 최대 {scale} tok", $"\nBar scale: up to {scale} tok per 5 s");
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
        total.Inlines.Add(Ui.Run(loading ? "0,000" : Format.Tokens(sum), Font.Metric, sum == 0 && !loading ? Theme.Secondary : Theme.Label));
        total.Inlines.Add(Ui.Run(" tok", Font.Micro, Theme.Secondary));
        total.Opacity = loading ? 0.25 : 1;

        // `SessionPresentation.ProviderSplits`: the first candidate that fits beside the total; none when even one does not.
        IReadOnlyList<string> texts = !loading && sum > 0 ? SessionPresentation.ProviderSplits(flow.ByProvider) : [];
        trailing.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        title.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var splitRoom = Room - title.DesiredSize.Width - 6 - 8 - (trailing.DesiredSize.Width - 4);
        var split = (string.Join("|", texts), Math.Round(splitRoom));
        if (!Equals(split, splitKey))
        {
            splitKey = split;
            splitSlot.Child = texts.Count == 0 ? null : Dashboard.Fit(splitRoom,
                [.. texts.Select(text => (Func<FrameworkElement>)(() => Ui.Text(text, Font.MetaMono, Theme.Secondary))), () => new Border()]);
        }

        // The meta row: the last record, or why nothing new was recorded (with the record when both fit); "지금 속도" on the right.
        var caption = SessionPresentation.Caption(state.Sessions.Counts, flow.Last?.At, now, false);
        var explains = caption.Text != SessionPresentation.LastRecordCaption || caption.Glyph is not null;
        var fresh = flow.Last is { } record && SessionPresentation.IsFresh(record.At, now);
        var recordText = flow.Last is { } last ? $"+{Format.Tokens(last.Tokens)} tok · {SessionPresentation.RecordAge(last.At, now, false)}" : null;
        var key = (loading, recordText, fresh, explains ? caption : null, speed);
        if (!Equals(key, metaKey))
        {
            metaKey = key;
            FrameworkElement Record()
            {
                var row = Dashboard.Row(4, fresh ? Dashboard.Dot(Theme.Activity) : null,
                    Ui.Text(recordText!, fresh ? Font.MetaMonoSemibold : Font.MetaMono, fresh ? Theme.Label : Theme.Secondary));
                row.ToolTip = Loc("최근 5분 안에 로그에 기록된 마지막 출력입니다", "The latest output recorded in the logs within the last 5 min");
                return row;
            }
            FrameworkElement Caption()
            {
                var row = Dashboard.Row(4, caption.Glyph is { } kind ? new GlyphView(kind) : null,
                    Ui.Text(caption.Text, Font.Meta, caption.Emphasized ? Theme.Label : Theme.Secondary));
                row.ToolTip = caption.Help;
                return row;
            }
            var speedMin = 0.0;
            if (speed is not null)
            {
                var shortest = SpeedHeadlineView(speed, 0);
                shortest.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                speedMin = shortest.DesiredSize.Width + 8;
            }
            var left = loading ? Dashboard.Redacted(Ui.Text(Loc("+0,000 tok · 방금", "+0,000 tok · just now"), Font.MetaMono))
                : recordText is not null
                    ? explains ? Dashboard.Fit(Room - speedMin, () => Dashboard.Row(6, Record(), Caption()), Caption, Record) : Record()
                : explains ? Caption()
                : Ui.Text(Loc("최근 5분 기록 없음", "None in the last 5 min"), Font.Meta, Theme.Secondary);
            left.VerticalAlignment = VerticalAlignment.Center;
            left.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            metaSlot.Child = Dashboard.Spread(left, speed is null ? null : SpeedHeadlineView(speed, Room - left.DesiredSize.Width - 8));
        }
        Ui.Help(chart, ChartHelp(flow.Hero, loading));
        chart.Set(flow.Hero, flow.Fresh, loading);
    }

    /// "지금 속도 · TokenCat  52.3 요청 tok/s": the label drops first when the row is tight, then the session (its title, else
    /// project) is cut short, then it goes; help and the screen reader always name the session. Without a measurement it says
    /// so in words, so no "—" can read as a rule.
    static FrameworkElement SpeedHeadlineView(SpeedHeadline headline, double room)
    {
        FrameworkElement view;
        if (!headline.Known) view = Ui.Text(Loc("속도 실측 없음", "No measured speed"), Font.Meta, Theme.Tertiary);
        else
        {
            // The label is the line's first run, so it shares the value's baseline.
            TextBlock Value(string? label = null)
            {
                var line = Ui.Line(Ui.Run(headline.Value, Font.Value), Ui.Run(" " + (headline.Kind ?? "tok/s"), Font.Micro, Theme.Secondary));
                if (label is not null) line.Inlines.InsertBefore(line.Inlines.FirstInline, Ui.Run(label + " ", Font.Meta, Theme.Secondary));
                return line;
            }
            // A long title ends in "…" within 140 DIP instead of hiding the label.
            FrameworkElement Cut(string label)
            {
                var text = Ui.Text(label, Font.Meta, Theme.Secondary);
                text.MaxWidth = 140;
                text.VerticalAlignment = VerticalAlignment.Bottom;
                var value = Value();
                value.VerticalAlignment = VerticalAlignment.Bottom;
                return Dashboard.Row(6, text, value);
            }
            var candidates = new List<Func<FrameworkElement>>
            {
                () => Value(headline.Label is { } label ? Loc("지금 속도 · ", "Speed now · ") + label : Loc("지금 속도", "Speed now")),
                () => Value(headline.Label ?? Loc("지금 속도", "Speed now")),
            };
            if (headline.Label is { } cut) candidates.Add(() => Cut(cut));
            candidates.Add(() => Value());
            view = Dashboard.Fit(room, [.. candidates]);
        }
        view.VerticalAlignment = VerticalAlignment.Center;
        view.ToolTip = headline.Help;
        System.Windows.Automation.AutomationProperties.SetName(view, Loc("지금 속도", "Speed now") + ", " + headline.Spoken);
        return view;
    }
}

/// Plot 28 + gap 3 + axis 12 (F-3); the bar scale is in the card's help. Loading draws only the baseline and the axis.
sealed class FlowChart : FrameworkElement
{
    public const double ChartHeight = 43;
    const double Plot = 28;
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
        if (peak > 0)
        {
            var scale = FlowMath.NiceMax(peak);
            context.DrawRectangle(Theme.Brush(Theme.Primary(0.08)), null, new Rect(0, 0, width, 0.5));
            var plot = new Rect(0, 0, width, Plot - 1);
            context.DrawGeometry(Theme.Brush(Theme.Neutral), null, Bars(plot, scale, null));
            context.DrawGeometry(Theme.Brush(Theme.Activity), null, Bars(plot, scale, fresh));
        }
        context.DrawRectangle(Theme.Brush(Theme.Primary(0.12)), null, new Rect(0, Plot - 1, width, 1));
        // Minute marks below the baseline at −4, −3, −2 and −1 min.
        for (var minute = 1; minute <= 4; minute++)
            context.DrawRectangle(Theme.Brush(Theme.Primary(0.18)), null, new Rect(Math.Round(width * (1 - minute / 5.0) * 2) / 2 - 0.5, Plot, 1, 3));
        var start = Label(Format.Ago(Format.Span(5, Format.TimeUnit.Minute)));
        context.DrawText(start, new Point(0, Plot + 3));
        var end = Label(Loc("지금", "now"));
        context.DrawText(end, new Point(width - end.Width, Plot + 3));
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

/// One provider in the limits container (Codex, then Claude): its window, then its other live window as a compact row 6 DIP
/// under it; 8 + hairline + 8 between providers. Always with the record age or "실시간"; no forecast.
sealed class LimitRow : StackPanel
{
    readonly Border rule = Ui.Hairline();
    readonly LimitWindow main = new(), other = new() { Margin = new Thickness(0, 6, 0, 0) };
    readonly TextBlock account = Ui.Text("", Font.Meta, Theme.Secondary);

    public LimitRow()
    {
        rule.Margin = new Thickness(0, 0, 0, 8);
        Children.Add(rule);
        Children.Add(main);
        Children.Add(account);
        Children.Add(other);
    }

    protected override System.Windows.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new LeafPeer(this, System.Windows.Automation.Peers.AutomationControlType.Text);

    /// `first`: no hairline above (the first provider in the container).
    public void Update(UsageLimitSummary limit, DateTimeOffset now, bool first = true)
    {
        Margin = new Thickness(0, first ? 0 : 8, 0, 0);
        rule.Visibility = first ? Visibility.Collapsed : Visibility.Visible;
        account.Text = limit.AccountLabel ?? "";
        account.Visibility = limit.AccountLabel is null ? Visibility.Collapsed : Visibility.Visible;
        main.Update(limit, now);
        var second = limit.OtherSummary(now);
        other.Visibility = second is null ? Visibility.Collapsed : Visibility.Visible;
        if (second is not null) other.Update(second, now);
        // Spoken carries the other window too (`OtherText`), so the provider is one element.
        System.Windows.Automation.AutomationProperties.SetName(this, limit.Title + ", " + limit.Spoken(now));
    }
}

/// "Claude · 5시간  42% 사용 … 2시간 13분 후 초기화" over a 4 DIP meter.
sealed class LimitWindow : StackPanel
{
    readonly TextBlock title = Ui.Text("", Font.MetaMedium);
    readonly TextBlock value = Ui.Line();
    readonly Border details = new();
    readonly Meter meter = new() { Margin = new Thickness(0, 4, 0, 0) };
    object? shown;

    public LimitWindow()
    {
        title.TextTrimming = TextTrimming.None;
        // 13 DIP value beside 11 DIP texts: raised by the ascent difference so all three share one baseline.
        value.Margin = new Thickness(0, -2, 0, 0);
        var line = Dashboard.Spread(Dashboard.Row(6, title, value), details);
        line.Height = 16;
        Children.Add(line);
        Children.Add(meter);
    }

    public void Update(UsageLimitSummary limit, DateTimeOffset now)
    {
        var expired = limit.Expired(now);
        title.Text = limit.ShortTitle;
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
        var key = (string.Join("|", texts), title.Text, limit.PercentText, expired);
        if (!Equals(key, shown))
        {
            shown = key;
            title.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            value.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - 2 * Dashboard.Inset - title.DesiredSize.Width - 6 - value.DesiredSize.Width - 8;
            details.Child = Dashboard.Fit(room, [.. texts.Select(text => (Func<FrameworkElement>)(() => Ui.Text(text, Font.MetaMono, Theme.Secondary)))]);
        }
        meter.Visibility = expired ? Visibility.Collapsed : Visibility.Visible;
        meter.Set(limit.UsedPercent / 100, Theme.MeterColor(limit.UsedPercent));
        Ui.Help(this, limit.Help(now));
    }
}

/// The list's title; its one disclosure control is the last row of the list (`SessionListEntry.Toggle`).
sealed class SessionsHeader : Border
{
    readonly TextBlock title = Ui.Text(Loc("세션", "Sessions"), Font.Title);

    public SessionsHeader()
    {
        Height = 18;
        title.VerticalAlignment = VerticalAlignment.Center;
        Child = title;
    }

    public void Update(SessionListModel list) =>
        Ui.Help(title, SessionList.KeyboardHint
            + (list.ShowsSpeedColumn ? "" : Loc("\n속도 실측 없음 · 로그 시각으로 추정하지 않습니다", "\nNo measured speed · not estimated from log times")));
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
    double cpuWidth = 58;
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

        /// The title as its name; the value texts stay readable inside (CPU, storage and battery have no spoken value).
        protected override System.Windows.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
            new System.Windows.Automation.Peers.FrameworkElementAutomationPeer(this);
    }

    public SystemArea(Action open)
    {
        Children.Add(new Border { Height = 1, Background = Theme.Brush(Theme.Hairline), Margin = new Thickness(-Dashboard.Gutter, 0, -Dashboard.Gutter, 0) });
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
        // Equal meters (Network keeps room for "↓ 999 kB/s"); both sets sum to 364 with the 12 DIP gaps.
        double[] widths = hasBattery ? [58, 58, 58, 58, 84] : [72, 72, 72, 112];
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
        // A peak at the fill edge reads as a glitch: the mark shows only 5 points or more above the value.
        peak.Visibility = cpuPeak is { } top && top - (cpuValue ?? 0) >= 5 ? Visibility.Visible : Visibility.Collapsed;
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
                FooterStatusKind.Notice => Named(Ui.HoverButton(new Border { Padding = new Thickness(5, 0, 5, 0), Child = Item(
                    Ui.Icon(notice?.IsProblem ?? true ? Ui.WarningIcon : Ui.InfoIcon, 11, notice?.IsProblem ?? true ? Theme.Warning : Theme.Secondary),
                    status.Text, notice?.IsProblem ?? true) }, actions.OpenTelemetrySettings, notice?.Help ?? help), status.Text),
                _ => Named(Ui.HoverButton(new Border { Padding = new Thickness(5, 0, 5, 0), Child = Item(Dashboard.Dot(Theme.Activity), status.Text, false) },
                    actions.OpenTelemetrySettings, help), status.Text),
            };
            if (status.Kind is FooterStatusKind.Notice or FooterStatusKind.Live) leading.Margin = new Thickness(-5, 0, 0, 0);
            else leading.Margin = new Thickness(0);
        }
        if (status.Kind is FooterStatusKind.Loading) Ui.Help(leading, Loc("첫 수집을 준비하고 있습니다", "Preparing the first sample"));
        else if (status.Kind is FooterStatusKind.AiDelay or FooterStatusKind.SystemDelay) Ui.Help(leading, help);
        else if (leading.Child is Button button) Ui.Help(button, status.Kind == FooterStatusKind.Notice ? notice?.Help ?? help : help);

        // The update item is fitted beside the status: a longer status later (port busy, restart needed) fits it again. Keyed
        // by the room, not the status, so a delay counting seconds does not rebuild its buttons every tick.
        leading.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var room = Dashboard.PanelWidth - 2 * Dashboard.Gutter - leading.DesiredSize.Width - 12;
        var fit = (update, Math.Round(room));
        if (!Equals(fit, trailingKey))
        {
            trailingKey = fit;
            trailing.Child = update is null ? null : Dashboard.Fit(room, () => UpdateItem(update, true), () => UpdateItem(update, false),
                () => UpdateItem(update, false, text: false));
        }
    }

    /// A text button is named by its visible words (WCAG 2.5.3); the help stays its tooltip.
    static Button Named(Button button, string title)
    {
        System.Windows.Automation.AutomationProperties.SetName(button, title);
        return button;
    }

    static FrameworkElement Item(UIElement mark, string text, bool primary)
    {
        var row = Dashboard.Row(5, mark, Ui.Text(text, Font.MetaMono, primary ? Theme.Label : Theme.Secondary));
        row.Height = 18;
        foreach (FrameworkElement child in row.Children) child.VerticalAlignment = VerticalAlignment.Center;
        return row;
    }

    /// The quiet update line: secondary text, accent text buttons, ✕ hides it for that version only.
    /// The failure's short reason drops first when the row is narrow, then the text itself (to the tooltip; a failure keeps its ⚠).
    FrameworkElement UpdateItem(UpdateNotice notice, bool detail, bool text = true)
    {
        var failed = notice.Kind == UpdateNoticeKind.Failed;
        var label = Dashboard.Row(4, failed ? Ui.Icon(Ui.WarningIcon, 11, Theme.Warning) : null,
            text ? Ui.Text(detail ? string.Join(" · ", new[] { notice.Text, notice.Detail }.OfType<string>()) : notice.Text, Font.MetaMono, Theme.Secondary) : null);
        label.ToolTip = text ? notice.Help : notice.Text;
        label.Margin = new Thickness(0, 0, 2, 0);
        label.VerticalAlignment = VerticalAlignment.Center;
        var row = Dashboard.Row(0, label);
        Button TextButton(string title, string help, UpdateCommand command) =>
            Named(Ui.HoverButton(new Border { Padding = new Thickness(5, 0, 5, 0), Height = 18, Child = Centered(Ui.Text(title, Font.MetaMedium, Theme.Accent)) },
                () => actions.Update(command), help), title);
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
