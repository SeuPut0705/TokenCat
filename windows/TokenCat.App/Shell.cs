using System.IO;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using static TokenCat.Lang;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace TokenCat;

/// App.swift's AppDelegate for Windows: the tray icon and its menu, the flyout, "Open as window", Settings, notifications,
/// the character and the automatic telemetry connection. Everything here runs on the WPF dispatcher.
sealed class Shell
{
    public const string OnboardingSeenKey = "onboardingSeen";
    /// The first-run balloon about the ^ overflow (§4.6) is shown once.
    const string TrayTipKey = "trayTipShown";

    readonly Application app;
    readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    readonly Preferences preferences = new(SettingsStore.Shared);
    readonly TelemetryCollector collector = new();
    readonly WindowsSystemSampler sampler = new();
    readonly LiveMonitor monitor;
    readonly Updater updater = new();
    readonly Forms.ContextMenuStrip trayMenu = new();
    readonly TrayIcon tray;
    readonly RunnerAnimator animator;
    readonly DispatcherTimer frameTimer = new(DispatcherPriority.Render), replanTimer = new();
    readonly AttentionTracker attention = new();
    readonly Flyout flyout;
    readonly DashboardActions actions;
    readonly List<string> playedContent = [];
    DashboardWindow? window;
    SettingsWindow? settings;
    RunnerDirector director;
    RunnerActivity activity = new() { Known = false };
    Dictionary<string, AttentionSignal> latestSignals = [];
    MonitorState? state, pending;
    int publishQueued;
    UpdateState update = new();
    string? setupNote;
    TelemetrySetupFailure? setupFailure;
    IReadOnlyList<TelemetrySetupNote> connectNotes = [];
    bool? claudeBridged;
    bool setupInFlight, locked, suspended, quitting;
    DateTimeOffset? quietSince;
    string? balloonGroup;
    DateTime hiddenAt = DateTime.MinValue;
    Drawing.Point anchor;

    public Shell(Application app)
    {
        this.app = app;
        actions = new DashboardActions(() => OpenSettings(), Quit, ShowAbout, OpenTaskManager, OpenWindow,
            () => OpenSettings(SettingsPage.Telemetry), HandleUpdate, () => monitor!.Refresh(), () =>
            {
                SettingsStore.Shared.Set(OnboardingSeenKey, true);
                RefreshViews();
            });
        animator = new RunnerAnimator(RunnerManifest.Parse(Sprites.Resource("runner-v2.json")), () => DateTimeOffset.UtcNow);
        tray = new TrayIcon(trayMenu);
        flyout = new Flyout(actions);
        monitor = new LiveMonitor(new MonitorOptions(AppPaths.Home, AppPaths.Support, sampler.Sample, collector));
    }

    MonitorState Current => state ?? monitor.Current;

    public void Start()
    {
        tray.OnLeftClick(TrayClicked);
        tray.OnBalloonClick(() => OpenDashboard(balloonGroup));
        // Built at open, like the mac quick menu. WinForms pre-cancels opening an empty strip, so un-cancel it once filled.
        trayMenu.Opening += (_, e) => { HideFlyout(); Menus.Fill(trayMenu, BuildTrayMenu); e.Cancel = false; };
        flyout.Deactivated += (_, _) => { if (!Menus.IsOpen) HideFlyout(); };
        flyout.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) HideFlyout(); };
        flyout.SizeChanged += (_, _) => { if (flyout.IsVisible) Native.Place(flyout, anchor, onto: false); };
        Menus.Closed += () => { if (flyout.IsVisible) flyout.Activate(); };
        // The frame timer follows the animator's own arming only, so a publish with an unchanged plan never restarts it.
        animator.Scheduled = ArmFrame;
        frameTimer.Tick += (_, _) => { frameTimer.Stop(); animator.Advance(); RenderTray(); };
        replanTimer.Tick += (_, _) => { replanTimer.Stop(); PlanRunner(); };

        monitor.Updated += next =>
        {
            Volatile.Write(ref pending, next);
            if (Interlocked.Exchange(ref publishQueued, 1) == 0)
                dispatcher.BeginInvoke(() => { Volatile.Write(ref publishQueued, 0); if (Volatile.Read(ref pending) is { } latest) Publish(latest); });
        };
        updater.StateChanged += next => dispatcher.BeginInvoke(() => { update = next; RefreshViews(); });
        updater.Discovered += release => dispatcher.BeginInvoke(() => UpdateDiscovered(release));
        updater.Shutdown = () => dispatcher.BeginInvoke(Quit);
        preferences.PropertyChanged += (_, _) => dispatcher.BeginInvoke(() =>
        {
            RenderTray(); // a new character draws the same pose and frame
            PlanRunner();
            updater.SetAutomatic(preferences.AutoCheckUpdates);
            RefreshViews();
        });
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
        SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;

        tray.Visible = true;
        RenderTray();
        collector.Start(() => dispatcher.BeginInvoke(ConnectTelemetryAutomatically));
        monitor.Start();
        updater.Start(preferences.AutoCheckUpdates);
        Publish(monitor.Current);

        if (SettingsStore.Shared.Get<bool?>(TrayTipKey) != true)
        {
            SettingsStore.Shared.Set(TrayTipKey, true);
            balloonGroup = null;
            tray.Balloon("TokenCat", Loc("TokenCat이 알림 영역에 있습니다. 보이지 않으면 ^를 열고 고양이를 작업 표시줄로 끌어 놓으세요.",
                "TokenCat is in the notification area. If you don't see it, open ^ and drag the cat onto the taskbar"));
            if (SettingsStore.Shared.Get<bool?>(OnboardingSeenKey) != true) OpenAtCorner();
        }
    }

    /// A second launch (payload-free hand-off) opens the dashboard at the primary work area's corner.
    public void OpenAtCorner()
    {
        if (window is { IsVisible: true }) { Front(window); return; }
        var area = Forms.Screen.PrimaryScreen!.WorkingArea;
        ShowFlyout(new Drawing.Point(area.Right, area.Bottom));
    }

    void OnPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e) => dispatcher.BeginInvoke(() =>
    {
        var dark = !Theme.AppsUseLightTheme();
        if (dark != Theme.Dark)
        {
            Theme.Dark = dark;
            flyout.Rebuild(actions);
            window?.Rebuild(actions);
            settings?.Rebuild();
            RefreshViews();
        }
        tray.Resize(); // the dot outline follows the taskbar tone
        PlanRunner(); // animation effects may have been turned off
    });

    void OnDisplayChanged(object? sender, EventArgs e) => dispatcher.BeginInvoke(() => { tray.Resize(); RenderTray(); });

    void OnSessionSwitch(object? sender, SessionSwitchEventArgs e) => dispatcher.BeginInvoke(() =>
    {
        if (e.Reason == SessionSwitchReason.SessionLock) locked = true;
        else if (e.Reason == SessionSwitchReason.SessionUnlock) locked = false;
        PlanRunner();
    });

    void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e) => dispatcher.BeginInvoke(() =>
    {
        if (e.Mode == PowerModes.Suspend) suspended = true;
        else if (e.Mode == PowerModes.Resume) { suspended = false; updater.SystemDidWake(); }
        PlanRunner();
    });

    /// Runs once per monitor publish: the tooltip, the character's state, notifications and the visible views.
    void Publish(MonitorState next)
    {
        if (quitting) return;
        state = next;
        var groups = next.Groups;
        var now = DateTimeOffset.UtcNow;
        activity = new RunnerActivity(groups, next.HasSample ? next.System.CpuPercent : null, now) { Known = next.TokensSampledAt is not null };
        if (activity.Known) director.Observe(activity, now);
        quietSince = director.QuietSince(activity);
        PlanRunner();
        // The baseline is the first real token sample, so sessions already waiting at launch are not announced.
        if (next.TokensSampledAt is not null) HandleAttention(groups);
        var counts = next.Sessions.Counts;
        tray.Tooltip = StatusBarContent.Tooltip(next.System, counts, new StatusAISummary(groups, counts), next.HasSample, next.TokensSampledAt is not null);
        RefreshViews();
    }

    DashboardInput Input() => new(Current, update, preferences.DismissedUpdateVersion, quietSince, setupNote, setupFailure, connectNotes, claudeBridged,
        SettingsStore.Shared.Get<bool?>(OnboardingSeenKey) == true, SettingsStore.Shared.Get<bool?>(TelemetrySetup.OptOutKey) == true);

    SettingsInput SettingsInput() => new(Input(), collector.LastBatchAt, LoginItem.Status);

    /// Only what is on screen re-renders (the mac releases a closed popover's views).
    void RefreshViews()
    {
        if (quitting) return;
        if (flyout.IsVisible) flyout.Dashboard.Show(Input());
        if (window is { IsVisible: true }) window.Dashboard.Show(Input());
        if (settings is { IsVisible: true }) settings.Refresh(SettingsInput());
    }

    /// A panel behind other windows doesn't count, so its notifications still arrive.
    bool DashboardVisible => flyout.IsVisible || window is { IsVisible: true, IsActive: true };

    // MARK: Character

    StateDot Dot => Current.Groups.Any(group => group.State == SessionDisplayState.Input) ? StateDot.Attention
        : Current.Groups.Any(group => group.State == SessionDisplayState.Retrying) ? StateDot.Warning : StateDot.None;

    void PlanRunner()
    {
        var plan = director.Plan(preferences.AnimationSource, activity, DateTimeOffset.UtcNow, reduceMotion: !SystemParameters.ClientAreaAnimation);
        animator.Paused = locked || suspended;
        animator.Apply(plan);
        replanTimer.Stop();
        if (plan.Until is { } until)
        {
            replanTimer.Interval = TimeSpan.FromMilliseconds(Math.Max(50, (until - DateTimeOffset.UtcNow).TotalMilliseconds));
            replanTimer.Start();
        }
        RenderTray();
    }

    /// Nothing animates while the session is locked or the PC sleeps (§4.1): `Paused` disarms it (null).
    void ArmFrame(TimeSpan? delay)
    {
        frameTimer.Stop();
        if (delay is not { } next) return;
        frameTimer.Interval = next < TimeSpan.FromMilliseconds(15) ? TimeSpan.FromMilliseconds(15) : next;
        frameTimer.Start();
    }

    void RenderTray()
    {
        if (quitting) return;
        var (pose, frame, fx) = animator.Current;
        tray.Render(preferences.Character, pose, frame, fx, Dot);
    }

    // MARK: Notifications

    void HandleAttention(IReadOnlyList<SessionGroup> groups)
    {
        var signals = AttentionSignal.Make(groups);
        latestSignals = signals.GroupBy(signal => signal.Id).ToDictionary(group => group.Key, group => group.First());
        // The baseline always advances, so turning a toggle on later never replays old transitions.
        foreach (var attentionEvent in attention.Update(signals))
        {
            switch (attentionEvent)
            {
                case { Kind: AttentionKind.Input }:
                    if (preferences.NotifyInput && !DashboardVisible) Balloon(attentionEvent);
                    break;
                case { Kind: AttentionKind.Finished } finished:
                    // A Stop hook can continue the turn right after a soft close; act only if it stayed closed.
                    After(TimeSpan.FromSeconds(3), () =>
                    {
                        if (latestSignals.GetValueOrDefault(finished.Signal.Id)?.Live == true) return;
                        TurnEnded(finished.Signal);
                        if (preferences.NotifyTurnComplete && !DashboardVisible) Balloon(finished);
                    });
                    break;
            }
        }
    }

    /// A confirmed turn end plays the character's `content` once per signal and event time, whatever the toggles (K-5).
    void TurnEnded(AttentionSignal signal)
    {
        var key = $"{signal.Id}@{signal.EndedAt?.ToUnixTimeMilliseconds() ?? 0}";
        if (playedContent.Contains(key)) return;
        playedContent.Add(key);
        if (playedContent.Count > 64) playedContent.RemoveRange(0, playedContent.Count - 64);
        if (preferences.AnimationSource != RunnerMotion.Activity) return;
        if (animator.PlayContent()) RenderTray();
    }

    void Balloon(AttentionEvent attentionEvent)
    {
        if (quitting) return;
        balloonGroup = attentionEvent.Signal.Id;
        tray.Balloon(attentionEvent.Title, string.Join("\n", new[] { attentionEvent.Subtitle, attentionEvent.Body }.Where(text => !string.IsNullOrEmpty(text))));
    }

    /// "새 버전 알림": silent, once per version, not while the dashboard or Settings already shows it.
    void UpdateDiscovered(UpdateRelease release)
    {
        if (quitting || !preferences.NotifyUpdate || DashboardVisible || settings is { IsActive: true } || release.Version == preferences.DismissedUpdateVersion) return;
        balloonGroup = null;
        tray.Balloon(Loc($"새 버전 {release.Version}", $"New version {release.Version}"),
            Loc("TokenCat 상세 화면이나 설정에서 업데이트할 수 있습니다", "Update from the TokenCat dashboard or Settings"));
    }

    // MARK: Flyout, window, Settings

    void TrayClicked()
    {
        // Clicking the icon while the flyout is open first deactivates (hides) it; that same click must not reopen it.
        if (DateTime.UtcNow - hiddenAt < TimeSpan.FromMilliseconds(300)) return;
        if (window is { IsVisible: true }) { Front(window); return; }
        ShowFlyout(Forms.Cursor.Position);
    }

    void ShowFlyout(Drawing.Point at)
    {
        anchor = at;
        updater.DashboardOpened();
        flyout.Dashboard.Show(Input());
        flyout.MaxHeight = Math.Max(300, Native.WorkingHeight(flyout, at) - 24);
        flyout.Show();
        flyout.Activate();
        Native.Place(flyout, at);
        flyout.Dashboard.Opened();
    }

    void HideFlyout()
    {
        if (!flyout.IsVisible) return;
        flyout.Hide();
        hiddenAt = DateTime.UtcNow;
        // "…로 업데이트했습니다" shows for one showing of the dashboard.
        updater.ClearUpdatedNote();
    }

    /// `focus` (a top-level group id from a notification or the menu) is selected once the dashboard shows it.
    void OpenDashboard(string? focus = null)
    {
        Dashboard target;
        if (window is { IsVisible: true }) { Front(window); target = window.Dashboard; }
        else
        {
            if (!flyout.IsVisible) OpenAtCorner();
            target = flyout.Dashboard;
        }
        if (focus is not null) target.Focus(focus);
    }

    void OpenWindow()
    {
        HideFlyout();
        if (window is null)
        {
            window = new DashboardWindow(actions);
            window.Closed += (_, _) => { window = null; updater.ClearUpdatedNote(); };
        }
        updater.DashboardOpened();
        window.Dashboard.Show(Input());
        window.Show();
        Front(window);
        window.Dashboard.Opened();
    }

    void OpenSettings(SettingsPage? page = null)
    {
        HideFlyout();
        if (settings is null)
        {
            settings = new SettingsWindow(new SettingsActions(preferences, () => { monitor.RetryTelemetryNow(); After(TimeSpan.FromMilliseconds(300), monitor.Refresh); },
                HandleUpdate, ReshowOnboarding, on =>
                {
                    LoginItem.Set(on);
                    RefreshViews();
                }), SettingsInput());
            settings.Closed += (_, _) => settings = null;
        }
        if (page is { } chosen) settings.Select(chosen);
        settings.Refresh(SettingsInput());
        settings.Show();
        Front(settings);
    }

    /// Activate alone doesn't restore a minimized window: it would stay on the taskbar while the click shows nothing.
    static void Front(Window target)
    {
        if (target.WindowState == WindowState.Minimized) target.WindowState = WindowState.Normal;
        target.Activate();
    }

    void ShowAbout() => OpenSettings(SettingsPage.About);

    void OpenTaskManager() => Open("taskmgr.exe");

    /// "처음 안내 다시 보기": the first-run card shows again in the dashboard.
    void ReshowOnboarding()
    {
        SettingsStore.Shared.Set(OnboardingSeenKey, false);
        OpenDashboard();
    }

    // MARK: Menu and updates

    /// Live summary first (M-5), then the controls. Built at open and not refreshed while the menu stays open.
    void BuildTrayMenu(MenuBuilder menu)
    {
        var current = Current;
        var summary = QuickMenuSummary.Make(current.Groups, current.Sessions.Counts, current.TokensSampledAt is not null, current.Now);
        menu.Add(summary.Headline, null, enabled: false);
        foreach (var row in summary.Rows) menu.Add(row.Title, () => OpenDashboard(row.Id), image: MenuBuilder.Square(Theme.GlyphColor(row.Kind)));
        menu.Separator();
        menu.Add(Loc("열기", "Open"), () => OpenDashboard());
        menu.Add(Loc("창으로 열기", "Open as Window"), OpenWindow);
        menu.Separator();
        var characters = menu.Sub(Loc("캐릭터", "Character"));
        foreach (var character in Enum.GetValues<RunnerCharacter>())
            characters.Add(character.Title, () => preferences.Character = character, check: preferences.Character == character);
        var motions = menu.Sub(Loc("움직임 기준", "Motion Source"));
        foreach (var motion in Enum.GetValues<RunnerMotion>())
            motions.Add(motion.Title, () => preferences.AnimationSource = motion, check: preferences.AnimationSource == motion);
        menu.Separator();
        if (update.QuickMenuTitle is { } title) menu.Add(title, QuickMenuUpdateAction);
        menu.Add(Loc("설정…", "Settings…"), () => OpenSettings());
        menu.Add(Loc("작업 관리자", "Task Manager"), OpenTaskManager);
        menu.Add(Loc("TokenCat 정보", "About TokenCat"), ShowAbout);
        menu.Separator();
        menu.Add(Loc("TokenCat 종료", "Quit TokenCat"), Quit);
    }

    /// An install opens the dashboard to show the progress; after a failure that blocks the install, the release page.
    void QuickMenuUpdateAction()
    {
        switch (update.QuickMenuCommand)
        {
            case UpdateCommand.Install:
                updater.Install();
                OpenDashboard();
                break;
            case { } command:
                HandleUpdate(command);
                break;
        }
    }

    /// Install is only ever started here, from a button or menu item.
    void HandleUpdate(UpdateCommand command)
    {
        switch (command)
        {
            case UpdateCommand.Check: updater.CheckNow(); break;
            case UpdateCommand.Install: updater.Install(); break;
            case UpdateCommand.OpenReleasePage: Open((update.Available?.Page ?? UpdateClient.Releases).AbsoluteUri); break;
            case UpdateCommand.Dismiss:
                if (update.Notice(preferences.DismissedUpdateVersion) is not { } notice) return;
                if (notice.Kind == UpdateNoticeKind.Updated) updater.ClearUpdatedNote();
                else if (notice.Kind is UpdateNoticeKind.Available or UpdateNoticeKind.Failed)
                {
                    updater.ClearFailure();
                    if (notice.Version.Length > 0) preferences.DismissedUpdateVersion = notice.Version;
                }
                RefreshViews();
                break;
        }
    }

    // MARK: Telemetry

    void ConnectTelemetryAutomatically()
    {
        if (setupInFlight) return;
        // `--disconnect-telemetry` opted out; only `--connect-telemetry` opts back in.
        if (SettingsStore.Shared.Get<bool?>(TelemetrySetup.OptOutKey) == true) { claudeBridged = false; RefreshViews(); return; }
        if (collector.State is not (TelemetryCollectorState.Waiting or TelemetryCollectorState.Receiving))
        {
            setupNote = Loc("수집기가 실행되지 않아 연결할 수 없습니다.", "Can't connect because the collector isn't running.");
            setupFailure = new TelemetrySetupFailure.Unavailable();
            RefreshViews();
            return;
        }
        setupInFlight = true;
        Task.Run(() =>
        {
            TelemetrySetupResult? result = null;
            string? message = null;
            TelemetrySetupFailure? failure = null;
            try { result = new TelemetrySetup(AppPaths.Home, AppPaths.Support).Connect(); }
            catch (Exception error)
            {
                message = OnboardingOutcome.NotePrefix + error.Message;
                failure = (error as TelemetrySetupError)?.Failure ?? new TelemetrySetupFailure.WriteFailed(true);
            }
            dispatcher.BeginInvoke(() =>
            {
                setupInFlight = false;
                setupNote = message;
                setupFailure = failure;
                // The status line notes are shown on the Telemetry page and decide the first-run card's sentence.
                connectNotes = result?.Notes ?? [];
                claudeBridged = result?.Bridged;
                // Running clients keep their old config; remember to say so until each one reports.
                monitor.NoteTelemetryConnected(result?.RestartRequired ?? []);
                RefreshViews();
            });
        });
    }

    /// A quit during "설치 중…" waits for that step (a few seconds, at most 60 s) so TokenCat.exe is never left renamed
    /// mid-swap: exiting kills the install's worker thread (mac `applicationShouldTerminate`).
    public void Quit()
    {
        if (!quitting && !updater.DeferQuit(Exit)) Exit();
    }

    void Exit()
    {
        if (quitting) return;
        // Work already queued on the dispatcher (a publish, a delayed turn end) must not touch the disposed tray.
        quitting = true;
        frameTimer.Stop();
        replanTimer.Stop();
        SystemEvents.UserPreferenceChanged -= OnPreferenceChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        animator.Stop();
        updater.Stop();
        monitor.Stop();
        collector.Stop();
        tray.Dispose();
        trayMenu.Dispose();
        settings?.Close();
        window?.Close();
        flyout.Close();
        app.Shutdown();
    }

    // MARK: Helpers

    /// A one-shot timer on the UI thread.
    public static void After(TimeSpan delay, Action action)
    {
        var timer = new DispatcherTimer { Interval = delay };
        timer.Tick += (_, _) => { timer.Stop(); action(); };
        timer.Start();
    }

    public static void Open(string target, string? arguments = null)
    {
        try { Process.Start(new ProcessStartInfo(target, arguments ?? "") { UseShellExecute = true })?.Dispose(); }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException) { }
    }

    /// Shows `path` selected in File Explorer; never opens the file.
    public static void Reveal(string path)
    {
        if (File.Exists(path) || Directory.Exists(path)) Open("explorer.exe", $"/select,\"{path}\"");
        else if (Path.GetDirectoryName(path) is { } parent && Directory.Exists(parent)) Open("explorer.exe", $"\"{parent}\"");
    }

    public static void Copy(string text)
    {
        // The clipboard can be held briefly by another app.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try { Clipboard.SetText(text); return; }
            catch (System.Runtime.InteropServices.COMException) { Thread.Sleep(50); }
        }
    }
}
