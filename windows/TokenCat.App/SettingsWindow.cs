using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using static TokenCat.Lang;

namespace TokenCat;

/// The Settings pages (§4.4), in navigation order: the mac's, with "메뉴 막대" as "위젯" (the on-screen widget, §4.7).
enum SettingsPage { General, Widget, Character, Telemetry, About }

/// `Pose`: the character's current pose, which the widget preview shows (frame 0). `SetupInFlight`: a telemetry connection or
/// disconnection is running.
sealed record SettingsInput(DashboardInput Dashboard, IReadOnlyDictionary<TokenSource, DateTimeOffset> Batches, LoginItem.State Login, RunnerPose Pose = RunnerPose.Sit,
    bool SetupInFlight = false);

/// `SetTelemetryConnected`: true connects (clearing the opt-out), false disconnects (setting it), like the CLI flags.
sealed record SettingsActions(Preferences Preferences, Action RetryTelemetry, Action<UpdateCommand> Update, Action ReshowOnboarding, Action<bool> SetLogin,
    Action<bool> SetTelemetryConnected);

static class AppInfo
{
    public static string Version => typeof(AppInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "—";

    /// The About page's privacy bullets.
    public static IReadOnlyList<string> PrivacyLines =>
    [
        Loc("로컬 로그·실측의 메타데이터만 읽고, 프롬프트·응답 본문은 저장하거나 표시하지 않습니다",
            "Reads only metadata from local logs and telemetry; never stores or shows prompts or responses"),
        Loc("모델을 호출하거나 계정에 로그인하지 않으며, 인터넷은 GitHub 업데이트 확인과 내려받기에만 씁니다",
            "Never calls a model or signs in; goes online only to check GitHub for updates and download them"),
        Loc("실시간 한도 확인이 켜져 있으면 저장된 Codex·Claude Code 로그인으로 OpenAI·Anthropic 사용량을 묻습니다. 토큰은 저장하지 않습니다",
            "With Live usage limits on, asks OpenAI and Anthropic for usage with Codex and Claude Code's saved sign-in. Tokens are never stored"),
    ];

    /// The release zip puts LICENSE next to TokenCat.exe.
    public static string License()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "LICENSE");
        try { return File.ReadAllText(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return Loc("TokenCat.exe 옆에서 LICENSE 파일을 찾지 못했습니다.", "Couldn't find the LICENSE file next to TokenCat.exe.");
        }
    }
}

sealed class SettingsWindow : Window
{
    readonly SettingsActions actions;
    SettingsView view;
    SettingsInput input;
    SettingsPage page = SettingsPage.General;
    const string PageKey = "settingsPane";

    public SettingsWindow(SettingsActions actions, SettingsInput input)
    {
        this.actions = actions;
        this.input = input;
        // The last page is remembered (the mac keeps "settingsPane").
        if (Enum.TryParse<SettingsPage>(SettingsStore.Shared.Get<string>(PageKey), true, out var saved)) page = saved;
        ResizeMode = ResizeMode.CanMinimize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SourceInitialized += (_, _) => Native.StyleWindow(this, round: false);
        view = Build();
    }

    SettingsView Build()
    {
        var built = new SettingsView(input, actions, page, chosen =>
        {
            page = chosen;
            SettingsStore.Shared.Set(PageKey, chosen.ToString().ToLowerInvariant());
            Title = Titles(chosen);
        });
        Content = built;
        Background = Theme.Brush(Theme.Background);
        Title = Titles(page);
        return built;
    }

    public static string Titles(SettingsPage page) => page switch
    {
        SettingsPage.General => Loc("일반", "General"),
        SettingsPage.Widget => Loc("위젯", "Widget"),
        SettingsPage.Character => Loc("캐릭터", "Character"),
        SettingsPage.Telemetry => Loc("실측", "Telemetry"),
        _ => Loc("정보", "About"),
    };

    public void Select(SettingsPage chosen) => view.Select(chosen);

    public void Refresh(SettingsInput next)
    {
        input = next;
        view.Refresh(next);
    }

    public void Rebuild()
    {
        view = Build();
        if (IsLoaded) Native.StyleWindow(this, round: false);
    }
}

/// Navigation on the left, one page on the right. A page is rebuilt only when what it shows changed, so clicks and focus
/// survive the 1 s refresh.
sealed class SettingsView : Grid
{
    public const double PageWidth = 480, NavWidth = 160, MaximumHeight = 620;
    readonly SettingsActions actions;
    readonly Action<SettingsPage> selected;
    readonly bool snapshot;
    readonly StackPanel nav = new() { Margin = new Thickness(8, 12, 8, 12) };
    readonly ScrollViewer host = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = MaximumHeight, Width = PageWidth };
    SettingsInput input;
    SettingsPage page;
    string? signature;
    string? loginError;
    /// The shown Widget page's live preview, and the one the last build made.
    WidgetView? preview, builtPreview;
    /// The item being dragged in the Widget page's list.
    MetricID? dragging;
    /// The item a keyboard move takes the focus to once the page is rebuilt.
    string? follow;
    const string DragFormat = "TokenCat.MetricRow";

    /// `snapshot`: nothing about this PC (config files, other processes, the exe path) is read.
    public SettingsView(SettingsInput input, SettingsActions actions, SettingsPage page, Action<SettingsPage> selected, bool snapshot = false)
    {
        this.snapshot = snapshot;
        this.input = input;
        this.actions = actions;
        this.page = page;
        this.selected = selected;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(NavWidth) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Background = Theme.Brush(Theme.Background);
        var navHost = new Border { Child = nav, Background = Theme.Brush(Theme.Primary(0.03)), BorderBrush = Theme.Brush(Theme.Hairline), BorderThickness = new Thickness(0, 0, 0.5, 0) };
        Children.Add(navHost);
        SetColumn(host, 1);
        Children.Add(host);
        Ui.Styled(this, Font.Body, Theme.Label);
        Select(page);
    }

    public void Select(SettingsPage chosen)
    {
        page = chosen;
        var hadFocus = nav.IsKeyboardFocusWithin;
        Button? current = null;
        nav.Children.Clear();
        foreach (var item in Enum.GetValues<SettingsPage>())
        {
            var icon = item switch
            {
                SettingsPage.General => Ui.Gear, SettingsPage.Widget => '\uE7F4', SettingsPage.Character => '\uE7FC', SettingsPage.Telemetry => '\uE9D9',
                _ => Ui.InfoIcon,
            };
            var row = Dashboard.Row(10, Ui.Icon(icon, 14, item == page ? Theme.Accent : Theme.Secondary), Ui.Text(SettingsWindow.Titles(item), Font.Body));
            var button = Ui.HoverButton(new Border { Child = row, Padding = new Thickness(10, 7, 10, 7), CornerRadius = new CornerRadius(5),
                Background = item == page ? Theme.Brush(Theme.Selection) : null }, () => Select(item), SettingsWindow.Titles(item));
            button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            // The current page is drawn only as a fill: say it too.
            System.Windows.Automation.AutomationProperties.SetItemStatus(button, item == page ? Loc("현재 페이지", "Current page") : "");
            nav.Children.Add(button);
            if (item == page) current = button;
        }
        if (hadFocus) current?.Focus();
        signature = null;
        selected(chosen);
        Refresh(input);
    }

    public void Refresh(SettingsInput next)
    {
        input = next;
        builtPreview = null;
        var content = page switch
        {
            SettingsPage.General => General(),
            SettingsPage.Widget => Widget(),
            SettingsPage.Character => Character(),
            SettingsPage.Telemetry => Telemetry(),
            _ => About(),
        };
        var built = Signature(content);
        // A press in progress keeps its button until the next tick; swapping it now would lose the click. The kept page's
        // preview still follows the values.
        if (built == signature || host.IsMouseCaptureWithin)
        {
            if (preview is not null) Preview(preview);
            return;
        }
        signature = built;
        // Keyboard focus moves to the element at the same position in the new page, or with the item a key just moved.
        var focused = host.IsKeyboardFocusWithin && host.Content is DependencyObject old && Keyboard.FocusedElement is UIElement focus
            ? Focusables(old).IndexOf(focus) : -1;
        var moved = follow;
        follow = null;
        host.Content = content;
        preview = builtPreview;
        if (focused < 0) return;
        host.UpdateLayout();
        var focusables = Focusables(content);
        (focusables.FirstOrDefault(element => moved is not null && AutomationProperties.GetAutomationId(element) == moved)
            ?? focusables.ElementAtOrDefault(focused))?.Focus();
    }

    /// Focusable elements in logical-tree order (the order Signature walks).
    static List<UIElement> Focusables(DependencyObject root)
    {
        var found = new List<UIElement>();
        void Walk(object node)
        {
            if (node is UIElement { Focusable: true } element) found.Add(element);
            if (node is DependencyObject dependency) foreach (var child in LogicalTreeHelper.GetChildren(dependency)) Walk(child);
        }
        Walk(root);
        return found;
    }

    /// Every text, state and enabled flag in the tree: equal signatures draw the same page.
    static string Signature(DependencyObject root)
    {
        var text = new System.Text.StringBuilder();
        void Walk(object node)
        {
            switch (node)
            {
                case TextBlock block: text.Append(block.Text).Append('|'); break;
                case FrameworkElement element when element.Tag is string tag: text.Append(tag).Append('|'); break;
            }
            if (node is UIElement { IsEnabled: false }) text.Append("!disabled|");
            if (node is DependencyObject dependency) foreach (var child in LogicalTreeHelper.GetChildren(dependency)) Walk(child);
        }
        Walk(root);
        return text.ToString();
    }

    // MARK: Building blocks

    static StackPanel Page(params UIElement?[] sections)
    {
        var stack = new StackPanel { Margin = new Thickness(20, 16, 20, 20) };
        foreach (var section in sections) if (section is not null) stack.Children.Add(section);
        return stack;
    }

    /// A grouped-form section: optional header, rows on one rounded container separated by hairlines, an optional footer.
    static FrameworkElement Section(string? header, IEnumerable<UIElement?> rows, UIElement? footer = null)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 18) };
        if (header is not null) stack.Children.Add(new Border { Child = Ui.Text(header, Font.MetaMedium, Theme.Secondary), Margin = new Thickness(4, 0, 0, 6) });
        var list = new StackPanel();
        foreach (var row in rows)
        {
            if (row is null) continue;
            if (list.Children.Count > 0) list.Children.Add(Ui.Hairline(12, 0));
            list.Children.Add(new Border { Child = row, Padding = new Thickness(12, 9, 12, 9) });
        }
        stack.Children.Add(Ui.Container(list));
        if (footer is not null) stack.Children.Add(new Border { Child = footer, Margin = new Thickness(4, 6, 0, 0) });
        return stack;
    }

    static TextBlock Caption(string text, Color? color = null)
    {
        var block = Ui.Text(Ui.KeepWords(text), Font.Meta, color ?? Theme.Secondary);
        block.TextWrapping = TextWrapping.Wrap;
        block.TextTrimming = TextTrimming.None;
        return block;
    }

    /// Title with an 11 DIP secondary subtitle under it (T-2); `warning` puts a warning mark before the title.
    static FrameworkElement Label(string title, string? subtitle = null, Color? subtitleColor = null, bool warning = false, bool enabled = true)
    {
        var stack = new StackPanel();
        var titleText = Ui.Text(title, Font.Body, enabled ? Theme.Label : Theme.Secondary);
        titleText.TextWrapping = TextWrapping.Wrap;
        titleText.TextTrimming = TextTrimming.None;
        stack.Children.Add(warning ? Dashboard.Row(4, Ui.Icon(Ui.WarningIcon, 12, Theme.Warning), titleText) : titleText);
        if (subtitle is not null) { var sub = Caption(subtitle, subtitleColor); sub.Margin = new Thickness(0, 2, 0, 0); stack.Children.Add(sub); }
        return stack;
    }

    static FrameworkElement Labeled(FrameworkElement label, UIElement? trailing)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(label);
        if (trailing is FrameworkElement right)
        {
            right.Margin = new Thickness(12, 0, 0, 0);
            right.VerticalAlignment = VerticalAlignment.Center;
            SetColumn(right, 1);
            grid.Children.Add(right);
        }
        return grid;
    }

    static FrameworkElement Toggle(string title, string? subtitle, bool on, Action<bool> set, bool enabled = true, string? help = null) =>
        Labeled(Label(title, subtitle, enabled: enabled), Switch(on, set, title, enabled, help));

    /// A switch drawn with the theme tokens (WPF's own controls don't follow dark mode).
    public static FrameworkElement Switch(bool on, Action<bool> set, string name, bool enabled = true, string? help = null)
    {
        var knob = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = Brushes.White,
            HorizontalAlignment = on ? HorizontalAlignment.Right : HorizontalAlignment.Left, Margin = new Thickness(3, 0, 3, 0) };
        var track = new Border { Width = 36, Height = 20, CornerRadius = new CornerRadius(10), Child = knob,
            Background = Theme.Brush(on ? Theme.Accent : Theme.Primary(0.25)) };
        // A ToggleButton, so UI Automation reports on/off (a plain Button only invokes).
        var button = Ui.Hover(new System.Windows.Controls.Primitives.ToggleButton { IsChecked = on }, track, () => set(!on), help ?? name);
        button.IsEnabled = enabled;
        button.Opacity = enabled ? 1 : 0.4;
        button.Tag = on ? "on" : "off";
        System.Windows.Automation.AutomationProperties.SetName(button, name);
        return button;
    }

    /// One choice per row with a check on the selected one (a themed radio list: RadioButtons, so the choice is announced).
    static FrameworkElement Choices<T>(IReadOnlyList<T> values, T current, Func<T, string> title, Func<T, UIElement> label, Action<T> choose)
    {
        var stack = new StackPanel();
        foreach (var value in values)
        {
            var chosen = EqualityComparer<T>.Default.Equals(value, current);
            var check = Ui.Icon(Ui.Check, 12, chosen ? Theme.Accent : Colors.Transparent);
            check.Width = 18;
            var row = Ui.Hover(new RadioButton { IsChecked = chosen, GroupName = typeof(T).Name },
                new Border { Child = Dashboard.Row(6, check, label(value)), Padding = new Thickness(4, 4, 4, 4) }, () => choose(value), title(value));
            row.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            row.Tag = chosen ? "chosen" : null;
            stack.Children.Add(row);
        }
        return stack;
    }

    // MARK: Pages

    FrameworkElement General()
    {
        var preferences = actions.Preferences;
        var login = input.Login;
        var temporary = LoginItem.IsTemporary;
        UIElement? startupFooter = temporary
            ? Caption(Loc("압축 파일 안에서 실행 중이라 켤 수 없습니다. TokenCat을 종료하고 %LOCALAPPDATA%\\Programs\\TokenCat 폴더에 압축을 푼 뒤 거기서 다시 열어 켜세요.",
                "Running from inside the zip, so this can't be turned on. Quit TokenCat, extract it to %LOCALAPPDATA%\\Programs\\TokenCat, then open it from there and turn this on."))
            : LoginItem.IsInRecommendedFolder ? null
            : Caption(Loc("TokenCat을 종료하고 TokenCat.exe를 %LOCALAPPDATA%\\Programs\\TokenCat 폴더로 옮긴 뒤 거기서 다시 열어 켜는 것을 권장합니다. 다른 위치의 앱을 옮기면 등록이 풀릴 수 있습니다.",
                "Quit TokenCat, move TokenCat.exe to %LOCALAPPDATA%\\Programs\\TokenCat, then open it from there before turning this on. A copy elsewhere loses its registration when it's moved."));
        var reset = Ui.SmallButton(Loc("기본값으로 되돌리기…", "Restore Defaults…"), () =>
        {
            var answer = MessageBox.Show(Window.GetWindow(this),
                Loc("위젯의 표시 방식·항목·크기, 캐릭터와 움직임 기준, 알림 선택이 바뀝니다. 시작 프로그램, 새 버전 자동 확인, 위젯 표시 여부와 위치는 그대로입니다.",
                    "This resets the widget's layout, items and size, the character and motion source, and notification choices. The startup setting, automatic update checks, and whether and where the widget shows stay as they are."),
                Loc("위젯·캐릭터·알림 설정을 기본값으로 되돌릴까요?", "Restore the widget, character and notification settings to their defaults?"),
                MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
            if (answer == MessageBoxResult.OK) preferences.Reset();
        });
        var notificationFooter = Caption(Loc("기본값은 꺼짐입니다. 상세 화면이 보이는 동안에는 보내지 않습니다. 프로젝트·모델·토큰 수·소요 시간만 넣고 질문이나 응답 내용은 넣지 않습니다.",
            "Off by default, and never sent while the dashboard is visible. They include only the project, model, token count and duration, never questions or responses."));
        return Page(
            Section(Loc("시작", "Startup"),
            [
                Toggle(Loc("로그인 시 TokenCat 열기", "Open TokenCat at login"), LoginItem.Describe(login), LoginItem.IsOn(login), on =>
                {
                    try { actions.SetLogin(on); loginError = null; }
                    catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException)
                    {
                        loginError = Loc($"시작 프로그램을 바꾸지 못했습니다: {error.Message}", $"Couldn't change the startup app: {error.Message}");
                    }
                    signature = null;
                    Refresh(input);
                }, enabled: !temporary || LoginItem.IsOn(login),
                    help: Loc("켜면 Windows 시작 프로그램에 등록하고, 끄면 해제합니다. 켜기 전에는 등록하지 않습니다.",
                        "When on, TokenCat is added to Windows startup apps; when off, it's removed. Nothing is registered until you turn this on.")),
                loginError is null ? null : Caption(loginError, Theme.Critical),
                login == LoginItem.State.DisabledInTaskManager ? Ui.SmallButton(Loc("작업 관리자 열기", "Open Task Manager"), LoginItem.OpenTaskManagerStartup) : null,
            ], startupFooter),
            Section(Loc("알림", "Notifications"),
            [
                Toggle(Loc("턴 완료", "Turn complete"), Loc("최상위 세션의 턴이 끝나거나 중단되면 알립니다", "Notifies when a top-level session's turn ends or is interrupted"),
                    preferences.NotifyTurnComplete, on => preferences.NotifyTurnComplete = on),
                Toggle(Loc("입력 필요", "Input needed"), Loc("질문·계획 승인을 기다리면 알립니다. 권한 확인 요청은 로그에 남지 않아 알 수 없습니다",
                    "Notifies when a question or plan approval is waiting. Permission prompts aren't logged, so TokenCat can't see them"),
                    preferences.NotifyInput, on => preferences.NotifyInput = on),
            ], notificationFooter),
            Section(null, [Labeled(Caption(Loc("위젯·캐릭터·알림 선택을 처음 상태로 돌립니다", "Resets the widget, character and notification choices")), reset)]));
    }

    /// The mac "메뉴 막대" pane for the on-screen widget (§4.7): showing it, a live preview, its size, preset and layout, then the
    /// items (MenuBarPane, MetricRows).
    FrameworkElement Widget()
    {
        var preferences = actions.Preferences;
        var view = builtPreview = new WidgetView();
        Preview(view);
        // The widget is its strip in points at the display scale rounded to whole pixels, times its size.
        var pixels = WidgetView.DevicePixels(VisualTreeHelper.GetDpi(this).DpiScaleX, preferences.WidgetScale);
        var (width, height) = ((int)Math.Round(view.PointSize.Width * pixels), (int)Math.Round(view.PointSize.Height * pixels));
        var strip = new Border
        {
            Child = view, Background = Theme.Brush(Theme.Background), CornerRadius = new CornerRadius(8), BorderBrush = Theme.Brush(Theme.Hairline),
            BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left,
        };
        // Wider than the row: cut with a short fade, never scaled (mac MenuBarPreview).
        var clip = new Border { Child = strip, ClipToBounds = true };
        clip.SizeChanged += (_, _) => clip.OpacityMask = view.PointSize.Width * view.Scale + 2 > clip.ActualWidth + 0.5
            ? new LinearGradientBrush(Colors.Black, Colors.Transparent, new Point(clip.ActualWidth - 28, 0), new Point(clip.ActualWidth, 0)) { MappingMode = BrushMappingMode.Absolute }
            : null;
        var sized = Caption(Loc($"화면에서 약 {width} × {height} px", $"About {width} × {height} px on screen"));
        sized.Margin = new Thickness(0, 6, 0, 0);
        var shown = new StackPanel();
        shown.Children.Add(clip);
        shown.Children.Add(sized);

        var size = Dropdown($"{preferences.WidgetScale}%", Loc("크기", "Size"), menu => Shell.SizeMenu(menu, preferences));
        AutomationProperties.SetAutomationId(size, "widget-size");
        var current = preferences.Preset;
        var custom = Loc("사용자 지정", "Custom");
        var preset = Dropdown(current?.Title ?? custom, Loc("프리셋", "Preset"), menu =>
        {
            foreach (var choice in Enum.GetValues<DisplayPreset>()) menu.Add(choice.Title, () => preferences.Apply(choice), check: current == choice);
            if (current is null) menu.Add(custom, null, enabled: false, check: true);
        }, Loc("표시 방식과 항목을 한 번에 바꿉니다", "Sets the layout and items in one step"));
        AutomationProperties.SetAutomationId(preset, "widget-preset");
        var layouts = Segmented(Enum.GetValues<StatusBarLayout>(), preferences.Layout, layout => layout.Title, layout => preferences.Layout = layout);
        AutomationProperties.SetAutomationId(layouts, "widget-layout");
        var footer = Caption(preferences.Layout == StatusBarLayout.Minimal
            ? Loc("최소 표시에서는 캐릭터와 AI 상태만 보입니다.", "Minimal shows only the character and AI status.")
            : Loc("끌어서 순서를 바꿉니다. 최소 한 항목은 표시됩니다.", "Drag to reorder. At least one item stays visible."));
        return Page(
            Section(null,
            [
                Toggle(Loc("화면에 위젯 표시", "Show widget on screen"),
                    Loc("작업 표시줄에는 글자를 넣을 수 없어 캐릭터와 AI 상태를 화면 위에 띄웁니다. 끌어서 옮기고, 전체 화면 앱을 쓰는 동안에는 숨깁니다.",
                        "The taskbar can't show text, so the character and AI status float on screen. Drag it anywhere; it hides while a full-screen app is in front."),
                    preferences.ShowWidget, on => preferences.ShowWidget = on),
                shown,
                Labeled(Label(Loc("크기", "Size"), Loc("위젯 위에서 Ctrl을 누른 채 마우스 휠을 돌리거나 위젯 우클릭 메뉴에서도 바꿀 수 있습니다.",
                    "You can also hold Ctrl and turn the mouse wheel over the widget, or use its right-click menu.")), size),
                Labeled(Label(Loc("프리셋", "Preset")), preset),
                Labeled(Label(Loc("표시 방식", "Layout"), preferences.Layout.Summary), layouts),
            ]),
            Section(Loc("항목", "Items"), [CharacterRow(), .. preferences.Order.Select(MetricRow)], footer));
    }

    /// The widget as it is now: values, layout, items, character and size, the current pose at frame 0.
    void Preview(WidgetView view)
    {
        var preferences = actions.Preferences;
        view.Update(StatusBarContent.Metrics(input.Dashboard.State, preferences.Layout, preferences.ShownItems), preferences.Layout, preferences.ShowRunner,
            preferences.WidgetScale);
        view.UpdateRunner(preferences.Character, input.Pose, 0, RunnerAnimator.StillFx(input.Pose));
    }

    static string MetricKey(MetricID id) => "metric-" + id.ToString().ToLowerInvariant();

    /// The item list's check box: an accent box, then `content`. A CheckBox, so UI Automation reports it by `name` with its
    /// checked state; its own Checked/Unchecked act, so a UI Automation Toggle (Narrator scan mode, voice access), which raises
    /// no Click, changes it too. `help` is the tooltip, shown on a disabled box as well.
    static CheckBox ItemCheck(bool on, UIElement content, string name, Action<bool> set, bool enabled, string help)
    {
        var mark = Ui.Icon(Ui.Check, 10, on ? (Theme.Dark ? Colors.Black : Colors.White) : Colors.Transparent);
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        var box = new Border
        {
            Width = 16, Height = 16, CornerRadius = new CornerRadius(4), Child = mark, Background = on ? Theme.Brush(Theme.Accent) : null,
            BorderBrush = Theme.Brush(on ? Theme.Accent : Theme.Primary(0.45)), BorderThickness = new Thickness(1),
        };
        var check = Ui.Hover(new CheckBox { IsChecked = on }, Dashboard.Row(8, box, content), () => { }, name);
        check.Checked += (_, _) => set(true);
        check.Unchecked += (_, _) => set(false);
        check.IsEnabled = enabled;
        check.Opacity = enabled ? 1 : 0.4;
        check.Tag = on ? "on" : "off";
        check.ToolTip = help;
        ToolTipService.SetShowOnDisabled(check, true);
        return check;
    }

    /// The items list's first row (mac "캐릭터"): the widget's runner slot, fixed above the draggable items. The tray icon always
    /// shows the character; it can't be hidden while nothing else would be drawn.
    FrameworkElement CharacterRow()
    {
        var preferences = actions.Preferences;
        var locked = preferences.ShowRunner && !preferences.CanHideRunner;
        var tray = Loc("알림 영역 아이콘에는 항상 표시됩니다", "The notification area icon always shows it");
        var lockedHelp = Loc("표시할 항목이 없어 캐릭터를 숨길 수 없습니다", "The character can't be hidden because no other item is shown");
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(Loc("캐릭터", "Character"), Font.Body));
        text.Children.Add(Caption(tray));
        var sprite = Sprites.Sprite(preferences.Character, RunnerPose.Walk, 0, 1);
        sprite.VerticalAlignment = VerticalAlignment.Center;
        var check = ItemCheck(preferences.ShowRunner, Dashboard.Row(6, sprite, text), Loc("캐릭터", "Character"), preferences.SetShowRunner, !locked,
            locked ? lockedHelp : tray);
        AutomationProperties.SetAutomationId(check, "item-character");
        AutomationProperties.SetHelpText(check, locked ? lockedHelp : tray);
        // The drag handle's width, so the boxes line up.
        return Dashboard.Row(10, new Border { Width = 12 }, check);
    }

    /// One item: a drag handle and a check box "title · bar label" (mac MetricRows). The row is the drag source and drop target
    /// (the dragged item takes each row's place as it passes); Alt+↑/↓ on the focused box and its menu (right-click, the Apps key,
    /// Shift+F10) move it too. The minimal layout draws none of them: the rows are disabled and stay in place.
    FrameworkElement MetricRow(MetricID id)
    {
        var preferences = actions.Preferences;
        var movable = preferences.Layout != StatusBarLayout.Minimal;
        var missing = id == MetricID.Battery && !preferences.HasBattery;
        var on = !missing && preferences.Visible.Contains(id);
        var locked = on && !preferences.CanHide(id);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var line = id.BarLabel is { } bar ? Ui.Line(Ui.Run(id.Title, Font.Body), Ui.Run($" · {bar}", Font.Meta, Theme.Secondary)) : Ui.Line(Ui.Run(id.Title, Font.Body));
        text.Children.Add(line);
        var noBattery = Loc("이 PC에는 배터리가 없습니다", "This PC has no battery");
        if (missing) text.Children.Add(Caption(noBattery));
        // The widget shows the contributing clients' icons in place of "AVG", so the row says what the number is.
        else if (id == MetricID.AverageSpeed)
            text.Children.Add(Caption(Loc("모든 클라이언트 세션의 실측 속도 평균", "Mean of measured session speeds, all clients")));
        var title = id.BarLabel is { } label ? $"{id.Title} · {label}" : id.Title;
        var lockedHelp = Loc("캐릭터나 다른 항목 중 하나는 표시해야 합니다", "The character or another item must stay visible");
        var minimalHelp = Loc("최소 표시에서는 캐릭터와 AI 상태만 보입니다.", "Minimal shows only the character and AI status.");
        var check = ItemCheck(on, text, title, visible => preferences.SetVisible(id, visible), movable && !missing && !locked,
            !movable ? minimalHelp : locked ? lockedHelp : Loc("끌어서 순서를 바꿉니다", "Drag to reorder"));
        AutomationProperties.SetAutomationId(check, MetricKey(id));
        AutomationProperties.SetHelpText(check, missing ? noBattery : !movable ? minimalHelp : locked ? lockedHelp
            : Loc("Alt+↑·↓로 순서를 바꿉니다", "Alt+Up or Alt+Down reorders it"));
        var handle = new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M0,0.5 H12 M0,4.5 H12 M0,8.5 H12"), Stroke = Theme.Brush(Theme.Tertiary), StrokeThickness = 1,
            VerticalAlignment = VerticalAlignment.Center, SnapsToDevicePixels = true, Opacity = movable ? 1 : 0.4,
        };
        // Over the section's row padding, so the whole row takes drags and drops.
        var row = new Border
        {
            Child = Dashboard.Row(10, handle, check), Background = Brushes.Transparent, AllowDrop = movable,
            Margin = new Thickness(-12, -9, -12, -9), Padding = new Thickness(12, 9, 12, 9),
        };
        if (!movable) return row;
        Point? press = null;
        row.PreviewMouseLeftButtonDown += (_, e) => press = e.GetPosition(row);
        row.PreviewMouseLeftButtonUp += (_, _) => press = null;
        row.PreviewMouseMove += (_, e) =>
        {
            if (press is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
            var moved = e.GetPosition(row) - start;
            if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            press = null;
            dragging = id;
            try { DragDrop.DoDragDrop(row, new DataObject(DragFormat, MetricKey(id)), DragDropEffects.Move); }
            finally { dragging = null; }
        };
        // Moves live as it passes another row's middle in the direction of travel (the page is rebuilt under the pointer), so rows
        // of different heights (the battery note) never swap back and forth; only drags from this list count.
        row.DragOver += (_, e) =>
        {
            e.Handled = true;
            e.Effects = DragDropEffects.None;
            if (dragging is not { } moving || !e.Data.GetDataPresent(DragFormat)) return;
            e.Effects = DragDropEffects.Move;
            var order = preferences.Order.ToList();
            if (moving != id && (order.IndexOf(id) > order.IndexOf(moving)) == (e.GetPosition(row).Y >= row.ActualHeight / 2))
                preferences.Move(moving, onto: id);
        };
        row.Drop += (_, e) => e.Handled = true;
        row.MouseRightButtonUp += (_, e) =>
        {
            e.Handled = true;
            ItemMenu(row, id);
        };
        check.PreviewKeyDown += (_, e) => { if (RowKey(id, e.Key, e.SystemKey, Keyboard.Modifiers, row)) e.Handled = true; };
        return row;
    }

    /// An item row's keys: Alt+↑/↓ moves the item; the Apps key or Shift+F10 opens its menu under `anchor`. True when handled.
    internal bool RowKey(MetricID id, Key key, Key systemKey, ModifierKeys modifiers, FrameworkElement? anchor = null)
    {
        if (key == Key.System && modifiers == ModifierKeys.Alt && systemKey is Key.Up or Key.Down)
        {
            MoveItem(id, systemKey == Key.Up ? -1 : 1);
            return true;
        }
        if (anchor is null || !(key == Key.Apps || key == Key.System && systemKey == Key.F10 && modifiers == ModifierKeys.Shift)) return false;
        ItemMenu(anchor, id);
        return true;
    }

    /// Moves one place; the focus follows the item into the rebuilt page and Narrator hears where it went.
    void MoveItem(MetricID id, int by)
    {
        var order = actions.Preferences.Order;
        actions.Preferences.Move(id, by);
        var to = actions.Preferences.Order.ToList().IndexOf(id);
        if (to == order.ToList().IndexOf(id)) return;
        follow = MetricKey(id);
        UIElementAutomationPeer.CreatePeerForElement(host)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted,
            AutomationNotificationProcessing.MostRecent, Loc($"{id.Title}, {order.Count}개 중 {to + 1}번째", $"{id.Title}, {to + 1} of {order.Count}"), "tokencat.move");
    }

    void ItemMenu(FrameworkElement anchor, MetricID id)
    {
        var order = actions.Preferences.Order;
        Menus.Show(anchor, menu =>
        {
            menu.Add(Loc("위로 이동", "Move Up"), () => MoveItem(id, -1), enabled: order[0] != id);
            menu.Add(Loc("아래로 이동", "Move Down"), () => MoveItem(id, 1), enabled: order[^1] != id);
        });
    }

    /// A themed pop-up button (WPF's ComboBox ignores dark mode): the current choice and a chevron; the choices open as a menu
    /// with the current one checked.
    static Button Dropdown(string current, string name, Action<MenuBuilder> build, string? help = null)
    {
        Button? button = null;
        button = Ui.SmallButton(current, () => Menus.Show(button!, build), help, menu: true);
        AutomationProperties.SetName(button, $"{name}: {current}");
        return button;
    }

    /// The mac's segmented picker: one radio button per value in a row, the chosen one filled.
    static FrameworkElement Segmented<T>(IReadOnlyList<T> values, T current, Func<T, string> title, Action<T> choose)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var value in values)
        {
            var chosen = EqualityComparer<T>.Default.Equals(value, current);
            var segment = Ui.Hover(new RadioButton { IsChecked = chosen, GroupName = typeof(T).Name },
                new Border
                {
                    Child = Ui.Text(title(value), Font.Meta, chosen ? Theme.Label : Theme.Secondary), Padding = new Thickness(10, 3, 10, 3),
                    CornerRadius = new CornerRadius(4), Background = chosen ? Theme.Brush(Theme.Selection) : null,
                }, () => choose(value), title(value));
            segment.Tag = chosen ? "chosen" : null;
            row.Children.Add(segment);
        }
        return new Border { Child = row, Padding = new Thickness(2), CornerRadius = new CornerRadius(6), Background = Theme.Brush(Theme.Primary(0.06)) };
    }

    FrameworkElement Character()
    {
        var preferences = actions.Preferences;
        var reduceMotion = !SystemParameters.ClientAreaAnimation;
        var characters = Choices(Enum.GetValues<RunnerCharacter>(), preferences.Character, character => character.Title, character =>
            Dashboard.Row(8, Sprites.Sprite(character, RunnerPose.Walk, 0, 1), Ui.Text(character.Title, Font.Body)), character => preferences.Character = character);
        var motions = Choices(Enum.GetValues<RunnerMotion>(), preferences.AnimationSource, motion => motion.Title, motion => Ui.Text(motion.Title, Font.Body),
            motion => preferences.AnimationSource = motion);
        motions.ToolTip = preferences.AnimationSource.Caption;
        var entries = LegendEntries(preferences.AnimationSource);
        return Page(
            Section(null, [Labeled(Label(Loc("캐릭터", "Character")), null), characters]),
            Section(null,
            [
                Label(Loc("움직임 기준", "Motion source"), preferences.AnimationSource.Subtitle), motions,
                entries.Count == 0 ? null : Legend(entries, preferences.Character, reduceMotion),
                reduceMotion ? Caption(Loc("Windows의 애니메이션 효과가 꺼져 있어 캐릭터는 자세만 바뀝니다.", "Animation effects are off in Windows, so the character only changes poses.")) : null,
            ]));
    }

    public sealed record LegendEntry(RunnerPose Pose, string Name, string Caption);

    /// RunnerLegend.entries: one tile per pose the chosen motion uses.
    public static IReadOnlyList<LegendEntry> LegendEntries(RunnerMotion motion) => motion switch
    {
        RunnerMotion.Activity =>
        [
            new(RunnerPose.Walk, Loc("걷기", "Walk"), Loc("진행·도구 실행", "Working · tool")),
            new(RunnerPose.Run, Loc("달리기", "Run"), Loc("출력 기록 직후", "Just recorded")),
            new(RunnerPose.Alert, Loc("정면 보기", "Facing you"), Loc("입력 필요", "Input needed")),
            new(RunnerPose.Sit, Loc("앉기", "Sit"), Loc("대기·쉬는 중", "Waiting · idle")),
            new(RunnerPose.Sleep, Loc("잠", "Sleep"), Loc("10분간 활동 없음", "Idle 10 min")),
        ],
        RunnerMotion.Cpu =>
        [
            new(RunnerPose.Sit, Loc("앉기", "Sit"), Loc("4% 미만", "Under 4%")),
            new(RunnerPose.Walk, Loc("걷기", "Walk"), Loc("20%까지", "Up to 20%")),
            new(RunnerPose.Run, Loc("달리기", "Run"), Loc("20% 넘음", "Over 20%")),
        ],
        RunnerMotion.Measured =>
        [
            new(RunnerPose.Sit, Loc("앉기", "Sit"), Loc("실측 없음", "Not measured")),
            new(RunnerPose.Walk, Loc("걷기", "Walk"), Loc("40 tok/s 미만", "Under 40 tok/s")),
            new(RunnerPose.Run, Loc("달리기", "Run"), Loc("40 이상", "40 or more")),
        ],
        _ => [],
    };

    static RunnerManifest? manifest;

    /// Frame 0 of each pose 1:1 without smoothing, a caption under it (T-4); hovering plays the pose once unless animations are off.
    static FrameworkElement Legend(IReadOnlyList<LegendEntry> entries, RunnerCharacter character, bool reduceMotion)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var entry in entries)
        {
            var still = RunnerAnimator.StillFx(entry.Pose);
            var image = new Border { Child = Sprites.Sprite(character, entry.Pose, 0, 1, still, Theme.Secondary) };
            var tile = new Border { Width = 64, Height = 36, CornerRadius = new CornerRadius(6), Background = Theme.Brush(Theme.Primary(0.05)), Child = image };
            image.HorizontalAlignment = HorizontalAlignment.Center;
            image.VerticalAlignment = VerticalAlignment.Center;
            var caption = Ui.Text(entry.Caption, Font.Meta, Theme.Secondary);
            caption.HorizontalAlignment = HorizontalAlignment.Center;
            caption.Margin = new Thickness(0, 4, 0, 0);
            var cell = new StackPanel { Width = 76, Margin = new Thickness(0, 0, 8, 0), Background = Brushes.Transparent };
            cell.Children.Add(tile);
            cell.Children.Add(caption);
            System.Windows.Automation.AutomationProperties.SetName(cell, $"{entry.Name}, {entry.Caption}");
            var playing = false;
            cell.MouseEnter += (_, _) =>
            {
                if (reduceMotion || playing) return;
                manifest ??= RunnerManifest.Parse(Sprites.Resource("runner-v2.json"));
                var durations = manifest.Timing(entry.Pose).Durations;
                if (durations.Count < 2) return;
                var steps = entry.Pose == RunnerPose.Sleep
                    ? new List<(int Frame, int? Fx, double Seconds)> { (1, 1, durations[1]), (0, 2, durations[0]) }
                    : [.. Enumerable.Range(1, durations.Count - 1).Select(frame => (frame, (int?)null, durations[frame])), .. durations.Count > 2 ? [(0, (int?)null, durations[0])] : Array.Empty<(int, int?, double)>()];
                playing = true;
                void Play(int index)
                {
                    if (index >= steps.Count) { image.Child = Sprites.Sprite(character, entry.Pose, 0, 1, still, Theme.Secondary); playing = false; return; }
                    image.Child = Sprites.Sprite(character, entry.Pose, steps[index].Frame, 1, steps[index].Fx, Theme.Secondary);
                    Shell.After(TimeSpan.FromSeconds(Math.Max(0.05, steps[index].Seconds)), () => Play(index + 1));
                }
                Play(0);
            };
            row.Children.Add(cell);
        }
        return row;
    }

    /// Collector and client rows (T-3): a state symbol, secondary text and an optional second line.
    public enum StatusRow { Receiving, Listening, Waiting, Starting, Problem, Info, Received }

    /// Segoe Fluent Icons CompletedSolid / Completed (mac checkmark.circle.fill / checkmark.circle) and Folder.
    const char FilledCheck = '\uEC61', OutlineCheck = '\uE930', FolderIcon = '\uE8B7';

    static (char Icon, Color Color) Symbol(StatusRow row) => row switch
    {
        StatusRow.Receiving or StatusRow.Received => (FilledCheck, Theme.Activity),
        StatusRow.Listening => (OutlineCheck, Theme.Activity),
        StatusRow.Problem => (Ui.WarningIcon, Theme.Warning),
        StatusRow.Info => (Ui.InfoIcon, Theme.Secondary),
        _ => (Ui.Dashed, Theme.Secondary),
    };

    public static (StatusRow Row, string Text) CollectorStatus(TelemetryCollectorState state)
    {
        var address = $"127.0.0.1:{TelemetryCollector.DefaultPort}";
        return state switch
        {
            TelemetryCollectorState.Receiving => (StatusRow.Receiving, Loc($"수신 중 · {address}", $"Receiving · {address}")),
            TelemetryCollectorState.Waiting => (StatusRow.Listening, Loc($"켜짐 · {address}", $"On · {address}")),
            TelemetryCollectorState.Starting => (StatusRow.Starting, Loc("준비 중", "Preparing")),
            TelemetryCollectorState.BusyTokenCat => (StatusRow.Problem, Loc("꺼짐 · 다른 TokenCat이 수집 중", "Off · another TokenCat is collecting")),
            TelemetryCollectorState.BusyOtherApp => (StatusRow.Problem, Loc($"꺼짐 · 다른 앱이 {TelemetryCollector.DefaultPort} 포트 사용 중", $"Off · another app is using port {TelemetryCollector.DefaultPort}")),
            TelemetryCollectorState.Failed => (StatusRow.Problem, Loc("꺼짐 · 수집기를 시작하지 못함", "Off · couldn't start the collector")),
            _ => (StatusRow.Problem, Loc("꺼짐", "Off")),
        };
    }

    /// Checked top to bottom: skipped by the last connection, restart needed, a day without a reading, a reading, an
    /// undecodable batch, nothing. `skipped`: why a Gemini CLI or Qwen Code connection left the settings alone.
    public static (StatusRow Row, string Text, string? Detail) ClientStatus(bool restartNeeded, bool expired, DateTimeOffset? lastReceived, DateTimeOffset? batch,
        DateTimeOffset now, string? skipped = null)
    {
        if (skipped is not null) return (StatusRow.Info, Loc("연결 안 함 · 기존 실측 설정 유지", "Not connected · existing telemetry settings kept"), skipped);
        if (restartNeeded) return (StatusRow.Info, Loc("새로 실행하면 실측이 표시됩니다", "Restart to show telemetry"), null);
        if (expired) return (StatusRow.Problem, Loc("이 버전에서 실측을 받지 못했습니다", "No telemetry from this version"), null);
        if (lastReceived is { } at) return (StatusRow.Received, Loc("최근 수신 ", "Last received ") + SessionPresentation.HelpAge(at, now, false), null);
        if (batch is not null)
            return (StatusRow.Waiting, Loc("기록 수신 중 · 속도 형식 없음", "Receiving records · no speed data"),
                Loc("받은 실측에서 요청별 생성 시간을 찾지 못해 속도를 표시하지 않습니다", "Received telemetry has no per-request generation time, so no speed is shown"));
        return (StatusRow.Waiting, Loc("아직 받은 실측 없음", "Nothing received yet"), null);
    }

    /// The usage-limit sources, checked top to bottom. `desktop`: the newest reading is the Claude desktop app's own record;
    /// `live`: a live poll's; `recordedBy`: omp's or Pi's own usage check.
    public static (StatusRow Row, string Text, string? Detail) ClaudeLimitsStatus(IReadOnlyList<TelemetrySetupNote> notes, bool? bridged, DateTimeOffset? received,
        bool desktop, DateTimeOffset now, bool live = false, string? recordedBy = null)
    {
        if (notes.Contains(TelemetrySetupNote.OriginalUnknown))
            return (StatusRow.Problem, Loc("상태 표시줄이 비어 보일 수 있음", "Status line may look empty"), Loc("settings.json의 statusLine을 직접 고쳐 주세요", "Fix statusLine in settings.json by hand"));
        if (notes.Contains(TelemetrySetupNote.StatusLineSkipped))
            return (StatusRow.Info, Loc("연결 안 함 · statusLine 형식이 달라 건너뜀", "Not connected · unsupported statusLine format"), null);
        // Windows v1 keeps an existing status line (§7.4); its limits then come from the desktop app's history.
        var detail = notes.Contains(TelemetrySetupNote.OriginalRecreated) ? Loc("원래 상태 표시줄 명령을 백업 기록에서 다시 만들었습니다", "Recreated the original status line command from backup")
            : notes.Contains(TelemetrySetupNote.StatusLineKept) ? TelemetrySetupNote.StatusLineKept.Text : null;
        if (received is { } polled && live) return (StatusRow.Received, Loc("실시간 확인 ", "Checked live ") + SessionPresentation.HelpAge(polled, now, false), detail);
        if (received is { } recorded && recordedBy is { } by)
            return (StatusRow.Received, Loc($"{by} 기록 · {Format.Age(recorded, now)}", $"{by} · recorded {Format.Age(recorded, now)}"), detail);
        if (received is { } at && desktop)
            return (StatusRow.Received, Loc($"Claude 데스크톱 앱 기록 · {Format.Age(at, now)}", $"Claude desktop app · recorded {Format.Age(at, now)}"), detail);
        if (received is { } last) return (StatusRow.Received, Loc("최근 수신 ", "Last received ") + SessionPresentation.HelpAge(last, now, false), detail);
        if (bridged == true) return (StatusRow.Waiting, Loc("아직 받지 못함 · Claude Code를 새로 실행하면 표시", "Nothing yet · restart Claude Code to show"), detail);
        return (StatusRow.Info, bridged is null ? Loc("연결 확인 전", "Not checked yet") : Loc("연결 안 함", "Not connected"), detail);
    }

    static FrameworkElement StatusLine(StatusRow row, string text, string? detail)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var (icon, color) = Symbol(row);
        var line = Dashboard.Row(6, Ui.Icon(icon, 12, color), Ui.Text(text, Font.Body, Theme.Secondary));
        line.HorizontalAlignment = HorizontalAlignment.Right;
        stack.Children.Add(line);
        if (detail is not null)
        {
            var second = Caption(detail);
            second.TextAlignment = TextAlignment.Right;
            second.MaxWidth = 300;
            second.HorizontalAlignment = HorizontalAlignment.Right;
            second.Margin = new Thickness(0, 2, 0, 0);
            stack.Children.Add(second);
        }
        return stack;
    }

    /// The executable of another running TokenCat, so the person can find the copy holding the port.
    static string? OtherTokenCat()
    {
        foreach (var process in Process.GetProcessesByName("TokenCat"))
        {
            using (process)
            {
                if (process.Id == Environment.ProcessId) continue;
                try { if (process.MainModule?.FileName is { } path) return path; }
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { }
            }
        }
        return null;
    }

    FrameworkElement Telemetry()
    {
        var dashboard = input.Dashboard;
        var state = dashboard.State;
        var now = state.Now;
        var collectorStatus = CollectorStatus(state.TelemetryState);
        var rows = new List<UIElement?> { Labeled(Label(Loc("수집기", "Collector")), StatusLine(collectorStatus.Row, collectorStatus.Text, null)) };
        // The retry and the other copy's location on their own trailing row, so the status stays on one line.
        var collectorActions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        if (state.TelemetryNextRetryAt is { } next)
        {
            var retry = Ui.SmallButton(Loc("지금 다시 시도", "Retry Now"), actions.RetryTelemetry);
            retry.IsEnabled = state.TelemetryState != TelemetryCollectorState.Starting;
            var clock = Ui.Text(Loc("다음 자동 재시도 ", "Automatic retry in ") + SessionPresentation.Clock(Math.Max(0, (int)Math.Ceiling((next - now).TotalSeconds))),
                Font.MetaMono, Theme.Secondary);
            clock.VerticalAlignment = VerticalAlignment.Center;
            clock.Margin = new Thickness(0, 0, 6, 0);
            collectorActions.Children.Add(clock);
            collectorActions.Children.Add(retry);
        }
        if (state.TelemetryState == TelemetryCollectorState.BusyTokenCat && !snapshot && OtherTokenCat() is { } other)
        {
            var show = Ui.SmallButton(Loc("탐색기에서 보기", "Show in File Explorer"), () => Shell.Reveal(other), other);
            if (collectorActions.Children.Count > 0) show.Margin = new Thickness(6, 0, 0, 0);
            collectorActions.Children.Add(show);
        }
        if (collectorActions.Children.Count > 0) rows.Add(collectorActions);
        if (dashboard.SetupNote is { } note) rows.Add(Caption(note, Theme.Warning));
        // Each client's config file, shown in File Explorer from its row when it exists (never in snapshots).
        var configs = new Dictionary<TokenSource, string>
        {
            [TokenSource.Codex] = AppPaths.CodexConfig(AppPaths.Home), [TokenSource.Claude] = AppPaths.ClaudeSettings(AppPaths.Home),
            [TokenSource.Gemini] = Path.Combine(AppPaths.Home, ".gemini", "settings.json"), [TokenSource.Qwen] = Path.Combine(AppPaths.Home, ".qwen", "settings.json"),
        };
        var revealed = false;
        // Gemini CLI and Qwen Code once their folder is detected, like every list.
        foreach (var source in TokenSource.TelemetryClients.Where(state.ListedSources.Contains))
        {
            var skipped = dashboard.ConnectNotes.OfType<TelemetrySetupNote.ClientSkipped>().FirstOrDefault(skip => skip.Source == source)?.Reason;
            var status = ClientStatus(state.TelemetryRestartNeeded.Contains(source), state.TelemetryRestartExpired.Contains(source),
                state.TelemetryLastReceived.TryGetValue(source, out var received) ? received : null,
                input.Batches.TryGetValue(source, out var batch) ? batch : null, now, skipped);
            FrameworkElement trailing = StatusLine(status.Row, status.Text, status.Detail);
            if (!snapshot && configs.TryGetValue(source, out var config) && File.Exists(config))
            {
                revealed = true;
                var shown = config.StartsWith(AppPaths.Home, StringComparison.OrdinalIgnoreCase) ? "%USERPROFILE%" + config[AppPaths.Home.Length..] : config;
                var icon = Ui.Icon(FolderIcon, 13, Theme.Secondary);
                icon.Margin = new Thickness(4, 2, 4, 2);
                var folder = Ui.HoverButton(icon, () => Shell.Reveal(config), Loc($"설정 파일 보기 · {shown}", $"Show config file · {shown}"));
                folder.VerticalAlignment = VerticalAlignment.Center;
                trailing = Dashboard.Row(6, trailing, folder);
            }
            rows.Add(Labeled(Label(source.Title), trailing));
        }
        // Whether the bridge delivers: the newer of the two windows' receipts (no reset time: the desktop app).
        var shownLimits = state.ShownClaudeLimits;
        var newest = new[] { shownLimits.FiveHour, shownLimits.SevenDay }.OfType<ClaudeLimitWindow>().MaxBy(window => window.ReceivedAt);
        var limits = ClaudeLimitsStatus(dashboard.ConnectNotes, dashboard.ClaudeBridged, newest?.ReceivedAt, newest is { ResetsAt: null }, now, newest is { Live: true },
            newest?.RecordedBy);
        rows.Add(Labeled(Label(Loc("Claude 한도", "Claude limits")), StatusLine(limits.Row, limits.Text, limits.Detail)));
        var backups = Path.Combine(AppPaths.Support, "telemetry-backups");
        var backupsShown = !snapshot && Directory.Exists(backups);
        // The folder note only beside a folder button (the rows' or the backups'); the backups' button under the text.
        var footer = new StackPanel();
        footer.Children.Add(Caption(Loc("실측은 출력 토큰·요청 시간 같은 수치만, Claude 한도는 상태 표시줄 JSON과 Claude 데스크톱 앱·omp·Pi 사용량 기록의 사용률만 받습니다. 이미 실행 중인 클라이언트는 새로 실행해야 적용됩니다.",
            "Telemetry receives only numbers such as output tokens and request times. Claude limits use only the usage percentage from the status line JSON and the usage history of the Claude desktop app, omp and Pi. Restart running clients to apply.")
            + (revealed || backupsShown ? Loc(" 폴더 단추는 탐색기에서 위치만 보여 주며 파일을 열거나 바꾸지 않습니다.",
                " Folder buttons only show where the files are in File Explorer; they never open or change them.") : "")));
        if (backupsShown)
        {
            var backup = Ui.SmallButton(Loc("백업 폴더 보기", "Show Backup Folder"), () => Shell.Reveal(backups), backups);
            backup.HorizontalAlignment = HorizontalAlignment.Left;
            backup.Margin = new Thickness(0, 6, 0, 0);
            footer.Children.Add(backup);
        }
        var preferences = actions.Preferences;
        var live = Toggle(Loc("실시간 한도 확인", "Live usage limits"),
            Loc("Codex·Claude Code에 저장된 로그인으로 OpenAI·Anthropic 사용량을 사용 중에는 1분, 평소에는 10분마다 확인합니다. 토큰은 저장하지 않습니다.",
                "Checks usage with OpenAI and Anthropic using Codex and Claude Code's saved sign-in, every minute while in use and every 10 minutes otherwise. Tokens are never stored."),
            preferences.LiveUsageLimits, on => preferences.LiveUsageLimits = on);
        return Page(Section(null, rows, footer), Section(null, [Connection(dashboard.OptedOut), live]));
    }

    /// The second section's first row, above 실시간 한도 확인: disconnect (behind a confirmation) while connected, reconnect once
    /// opted out, like `--disconnect-telemetry` / `--connect-telemetry`. Disabled while a connection or disconnection runs.
    FrameworkElement Connection(bool optedOut)
    {
        var button = optedOut
            ? Ui.SmallButton(Loc("다시 연결", "Reconnect"), () => actions.SetTelemetryConnected(true))
            : Ui.SmallButton(Loc("연결 해제…", "Disconnect…"), () =>
            {
                var answer = MessageBox.Show(Window.GetWindow(this),
                    Loc("클라이언트 설정에서 TokenCat 항목을 지우고 백업해 둔 원래 값을 되돌립니다. 다시 연결하기 전에는 자동으로 연결하지 않습니다. 이미 실행 중인 클라이언트는 새로 실행해야 적용됩니다.",
                        "Removes TokenCat's entries from the client settings and restores the backed-up values. TokenCat won't reconnect until you connect again. Restart running clients to apply."),
                    Loc("실측 연결을 해제할까요?", "Disconnect telemetry?"), MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel);
                if (answer == MessageBoxResult.OK) actions.SetTelemetryConnected(false);
            });
        button.IsEnabled = !input.SetupInFlight;
        button.Opacity = button.IsEnabled ? 1 : 0.4;
        AutomationProperties.SetAutomationId(button, "telemetry-connection");
        return Labeled(Label(Loc("연결", "Connection"), optedOut
            ? Loc("해제됨 · 다시 연결하기 전에는 연결하지 않습니다", "Disconnected · stays off until you reconnect")
            : Loc("클라이언트 설정에 실측 연결이 들어 있습니다", "Client settings send telemetry to TokenCat")), button);
    }

    FrameworkElement About()
    {
        var preferences = actions.Preferences;
        var dashboard = input.Dashboard;
        var update = dashboard.Update;
        var now = dashboard.State.Now;
        var header = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        var head = Sprites.HeadImage(RunnerHead.Normal, 48, 44);
        head.HorizontalAlignment = HorizontalAlignment.Center;
        header.Children.Add(head);
        TextBlock Centered(TextBlock text) { text.HorizontalAlignment = HorizontalAlignment.Center; text.TextAlignment = TextAlignment.Center; return text; }
        var name = Centered(Ui.Text("TokenCat", Font.Title));
        name.FontSize = 15;
        name.Margin = new Thickness(0, 6, 0, 0);
        header.Children.Add(name);
        header.Children.Add(Centered(Ui.Text(Loc($"버전 {AppInfo.Version}", $"Version {AppInfo.Version}"), Font.MetaMono, Theme.Secondary)));
        // The privacy bullets, left-aligned under the centred header.
        var top = new StackPanel();
        top.Children.Add(header);
        var privacy = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var line in AppInfo.PrivacyLines)
        {
            var bullet = new Grid { Margin = new Thickness(0, 2, 0, 0) };
            bullet.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bullet.ColumnDefinitions.Add(new ColumnDefinition());
            var dot = Ui.Text("•", Font.Meta, Theme.Secondary);
            dot.Margin = new Thickness(0, 0, 6, 0);
            var text = Caption(line);
            SetColumn(text, 1);
            bullet.Children.Add(dot);
            bullet.Children.Add(text);
            privacy.Children.Add(bullet);
        }
        top.Children.Add(privacy);
        var buttons = Dashboard.Row(8, Ui.SmallButton(Loc("MIT 라이선스 보기", "Show MIT License"), ShowLicense),
            Ui.SmallButton(Loc("처음 안내 다시 보기", "Show Welcome Again"), actions.ReshowOnboarding,
                Loc("처음 실행 안내(TokenCat이 하는 일)를 상세 화면에 다시 보입니다", "Shows the first-launch welcome (What TokenCat does) on the dashboard again")));

        var status = update.Status(now);
        var failure = update.InstallFailure;
        var updateButtons = new StackPanel { Orientation = Orientation.Horizontal };
        void Add(string title, Action click, string? help = null, bool enabled = true)
        {
            var button = Ui.SmallButton(title, click, help);
            button.IsEnabled = enabled;
            button.Opacity = enabled ? 1 : 0.4;
            button.Margin = new Thickness(6, 0, 0, 0);
            updateButtons.Children.Add(button);
        }
        // At most two: after a retryable failure "다시 시도" and the release page; after one that blocks the install, what the
        // person can do and "지금 확인", since a newer release can be installed again.
        if (failure is not null)
        {
            if (failure.Retryable)
            {
                if (update.CanInstall) Add(Loc("다시 시도", "Try Again"), () => actions.Update(UpdateCommand.Install), Loc("릴리스 정보를 다시 확인하고 내려받습니다", "Checks the release again and downloads it"));
                Add(Loc("릴리스 페이지 열기", "Open Release Page"), () => actions.Update(UpdateCommand.OpenReleasePage));
            }
            else
            {
                if (failure.Kind == UpdateFailureKind.Translocated)
                    Add(Loc("권장 폴더 열기", "Open Recommended Folder"), () => { Directory.CreateDirectory(LoginItem.RecommendedFolder); Shell.Open(LoginItem.RecommendedFolder); },
                        Loc("TokenCat을 이 폴더에 압축 해제한 뒤 다시 여세요", "Extract TokenCat into this folder, then open it again"));
                else Add(Loc("릴리스 페이지 열기", "Open Release Page"), () => actions.Update(UpdateCommand.OpenReleasePage));
                Add(Loc("지금 확인", "Check Now"), () => actions.Update(UpdateCommand.Check), enabled: update.CanCheck);
            }
        }
        else if (update.CanInstall)
        {
            // An available update is the one action: the default button, without "지금 확인".
            Add(Loc("업데이트", "Update"), () => actions.Update(UpdateCommand.Install), Loc("내려받아 설치한 뒤 TokenCat을 다시 엽니다", "Downloads and installs the update, then reopens TokenCat"));
            ((Button)updateButtons.Children[^1]).IsDefault = true;
        }
        else Add(Loc("지금 확인", "Check Now"), () => actions.Update(UpdateCommand.Check), enabled: update.CanCheck);
        var disabled = update.Disabled is not null;
        return Page(
            Section(null, [top, buttons]),
            Section(Loc("업데이트", "Updates"),
            [
                Toggle(Loc("새 버전 자동 확인", "Check for updates automatically"), null, preferences.AutoCheckUpdates, on => preferences.AutoCheckUpdates = on, !disabled,
                    Loc("실행 직후, 15분마다, 잠자기에서 깨어난 뒤 GitHub 최신 릴리스를 확인합니다", "Checks GitHub for the latest release at launch, every 15 minutes and after waking from sleep")),
                Labeled(Label(status.Title, failure is null ? status.Detail : null, warning: status.Problem), updateButtons),
                failure is null ? null : Caption(failure.Text),
                Toggle(Loc("새 버전 알림", "Notify about new versions"), Loc("새 버전을 찾으면 소리 없이 한 번 알립니다", "Notifies once, without sound, when a new version is found"),
                    preferences.NotifyUpdate, on => preferences.NotifyUpdate = on, !disabled),
            ]));
    }

    void ShowLicense()
    {
        var text = Ui.Text(AppInfo.License(), Font.Meta);
        text.TextWrapping = TextWrapping.Wrap;
        text.TextTrimming = TextTrimming.None;
        var stack = new DockPanel { Margin = new Thickness(16) };
        var close = Ui.SmallButton(Loc("닫기", "Close"), () => { });
        close.HorizontalAlignment = HorizontalAlignment.Right;
        close.Margin = new Thickness(0, 12, 0, 0);
        DockPanel.SetDock(close, Dock.Bottom);
        stack.Children.Add(close);
        var title = Ui.Text("MIT License", Font.Title);
        title.Margin = new Thickness(0, 0, 0, 12);
        DockPanel.SetDock(title, Dock.Top);
        stack.Children.Add(title);
        stack.Children.Add(new ScrollViewer { Content = text, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var window = new Window
        {
            Title = "MIT License", Width = 420, Height = 400, Content = stack, Background = Theme.Brush(Theme.Background),
            Owner = Window.GetWindow(this), WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
        };
        Ui.Styled(window, Font.Body, Theme.Label);
        close.Click += (_, _) => window.Close();
        window.KeyDown += (_, e) => { if (e.Key is Key.Escape or Key.Enter) window.Close(); };
        window.SourceInitialized += (_, _) => Native.StyleWindow(window, round: false);
        window.ShowDialog();
    }
}
