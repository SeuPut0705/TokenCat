using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace TokenCat;

/// App.swift `Preferences`, the fields Windows keeps: the input sound is cut (DESIGN §3.2). The menu bar's layout, items and
/// character visibility drive the on-screen widget (§4.7), which adds its size. Same keys and raw values as the mac's UserDefaults.
/// A change writes its own key (the motion also marks itself confirmed) and raises PropertyChanged for Settings and the shell.
public sealed class Preferences : INotifyPropertyChanged
{
    /// The choices "기본값으로 되돌리기" covers; login item, automatic update checks, live usage limits, showing the widget and its
    /// saved positions are not here.
    public sealed record Snapshot(RunnerMotion AnimationSource, RunnerCharacter Character, bool NotifyTurnComplete, bool NotifyInput, bool NotifyUpdate,
        StatusBarLayout Layout, IReadOnlyList<MetricID> Order, IReadOnlySet<MetricID> Visible, bool ShowRunner, int WidgetScale)
    {
        /// The item list and set compare by content.
        public bool Equals(Snapshot? other) => other is not null
            && (AnimationSource, Character, NotifyTurnComplete, NotifyInput, NotifyUpdate, Layout, ShowRunner, WidgetScale)
               == (other.AnimationSource, other.Character, other.NotifyTurnComplete, other.NotifyInput, other.NotifyUpdate, other.Layout, other.ShowRunner, other.WidgetScale)
            && Order.SequenceEqual(other.Order) && Visible.SetEquals(other.Visible);

        public override int GetHashCode() => HashCode.Combine(AnimationSource, Character, Layout, ShowRunner, WidgetScale, Order.Count, Visible.Count);
    }

    /// Like the mac bar, the widget starts on two lines with the standard items shown (the speed items off, last), the character
    /// in it, at 100 %.
    public static Snapshot DefaultSnapshot { get; } = new(RunnerMotion.Activity, RunnerCharacter.Cat, false, false, false,
        StatusBarLayout.Compact, Enum.GetValues<MetricID>(), MetricID.Standard.ToHashSet(), true, 100);

    /// "크기": the widget's sizes in percent. At 100 % a point is the display scale rounded to whole pixels (§4.7).
    public static IReadOnlyList<int> WidgetScales { get; } = [100, 125, 150, 175, 200, 250, 300];

    readonly SettingsStore store;
    RunnerMotion animationSource;
    RunnerCharacter character;
    bool notifyTurnComplete, notifyInput, autoCheckUpdates, notifyUpdate, showWidget, liveUsageLimits, showRunner, hasBattery = true;
    string? dismissedUpdateVersion;
    StatusBarLayout layout;
    int widgetScale;
    IReadOnlyList<MetricID> order;
    IReadOnlySet<MetricID> visible;

    public Preferences(SettingsStore? store = null)
    {
        this.store = store ??= SettingsStore.Shared;
        // New installs, the legacy "tokens" value and an unconfirmed older "cpu" start on AI activity.
        animationSource = RunnerMotion.Stored(store.Get<string>("animationSource"), store.Get<bool?>(RunnerMotion.ConfirmedKey) ?? false);
        var characterID = store.Get<string>("runnerCharacter");
        character = Enum.GetValues<RunnerCharacter>().FirstOrDefault(value => Raw(value) == characterID, RunnerCharacter.Cat);
        notifyTurnComplete = store.Get<bool?>("notifyTurnComplete") ?? false;
        notifyInput = store.Get<bool?>("notifyInput") ?? false;
        autoCheckUpdates = store.Get<bool?>("autoCheckUpdates") ?? true;
        notifyUpdate = store.Get<bool?>("notifyUpdate") ?? false;
        liveUsageLimits = store.Get<bool?>("liveUsageLimits") ?? true;
        dismissedUpdateVersion = store.Get<string>("dismissedUpdateVersion");
        // The widget starts on, on two lines like the mac bar; unknown item names are dropped. Items added later (the speed
        // items) append to a stored order and stay hidden until turned on.
        showWidget = store.Get<bool?>("showWidget") ?? true;
        layout = RunnerCharacterText.Parse<StatusBarLayout>(store.Get<string>("statusBarLayout")) ?? StatusBarLayout.Compact;
        static IEnumerable<MetricID> Items(string[]? names) => (names ?? []).Select(RunnerCharacterText.Parse<MetricID>).OfType<MetricID>();
        order = [.. Items(store.Get<string[]>("metricOrder")).Concat(Enum.GetValues<MetricID>()).Distinct()];
        visible = (store.Get<string[]>("visibleMetrics") is { } shown ? Items(shown) : MetricID.Standard).ToHashSet();
        showRunner = store.Get<bool?>("showRunner") ?? true;
        widgetScale = NearestScale(store.Get<double?>("widgetScale"));
        // A stored widget with neither items nor the character comes back with the character (not written until a change).
        if (layout != StatusBarLayout.Minimal && !showRunner && ShownItems.Count == 0) showRunner = true;
    }

    /// "화면에 위젯 표시": on by default. Not part of "기본값으로 되돌리기".
    public bool ShowWidget { get => showWidget; set => Change(ref showWidget, value, "showWidget", value); }

    public StatusBarLayout Layout
    {
        get => layout;
        set { if (Change(ref layout, value, "statusBarLayout", Raw(value))) KeepSomethingVisible(); }
    }

    /// Every item in the stored order, and the ones switched on.
    public IReadOnlyList<MetricID> Order => order;
    public IReadOnlySet<MetricID> Visible => visible;

    /// "위젯에 캐릭터 표시": the widget's runner slot (the tray icon always shows the character). Changed through `SetShowRunner`.
    public bool ShowRunner
    {
        get => showRunner;
        private set { if (Change(ref showRunner, value, "showRunner", value)) KeepSomethingVisible(); }
    }

    /// Runtime only, from the system sampler: a battery item on a PC without one draws nothing.
    public bool HasBattery
    {
        get => hasBattery;
        set
        {
            if (hasBattery == value) return;
            hasBattery = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasBattery)));
            KeepSomethingVisible();
        }
    }

    /// The widget's size in percent, one of `WidgetScales` (another value becomes the nearest one).
    public int WidgetScale
    {
        get => widgetScale;
        set { var scale = NearestScale(value); Change(ref widgetScale, scale, "widgetScale", scale); }
    }

    /// What the two-line and one-line layouts draw, in order; a battery item without a battery is left out.
    public IReadOnlyList<MetricID> ShownItems => [.. order.Where(id => visible.Contains(id) && (id != MetricID.Battery || hasBattery))];

    /// With the character hidden, the last drawn item stays on. The minimal layout always draws the AI item.
    public bool CanHide(MetricID id) => layout == StatusBarLayout.Minimal || showRunner || !ShownItems.SequenceEqual([id]);
    public bool CanHideRunner => layout == StatusBarLayout.Minimal || ShownItems.Count > 0;

    public void SetVisible(MetricID id, bool on)
    {
        if (on == visible.Contains(id) || !on && !CanHide(id)) return;
        var next = visible.ToHashSet();
        if (on) next.Add(id);
        else next.Remove(id);
        SetItems(order, next);
    }

    public void SetShowRunner(bool on)
    {
        if (on || CanHideRunner) ShowRunner = on;
    }

    /// Keyboard and menu reordering: swaps with the neighbour `by` away (−1 up, +1 down).
    public void Move(MetricID id, int by)
    {
        var next = order.ToList();
        var index = next.IndexOf(id);
        if (index < 0 || index + by < 0 || index + by >= next.Count) return;
        (next[index], next[index + by]) = (next[index + by], next[index]);
        SetItems(next, visible);
    }

    /// Drag reordering: `id` takes `onto`'s place (after it when moving down).
    public void Move(MetricID id, MetricID onto)
    {
        var next = order.ToList();
        int from = next.IndexOf(id), to = next.IndexOf(onto);
        if (id == onto || from < 0 || to < 0) return;
        next.RemoveAt(from);
        next.Insert(to, id);
        SetItems(next, visible);
    }

    void SetItems(IReadOnlyList<MetricID> nextOrder, IReadOnlySet<MetricID> nextVisible)
    {
        if (nextOrder.SequenceEqual(order) && nextVisible.SetEquals(visible)) return;
        (order, visible) = ([.. nextOrder], nextVisible.ToHashSet());
        store.Set("metricOrder", order.Select(Raw).ToArray());
        store.Set("visibleMetrics", order.Where(visible.Contains).Select(Raw).ToArray());
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ShownItems)));
        KeepSomethingVisible();
    }

    /// The widget never draws nothing: outside the minimal layout, no item left brings the character back.
    void KeepSomethingVisible()
    {
        if (layout != StatusBarLayout.Minimal && !showRunner && ShownItems.Count == 0) ShowRunner = true;
    }

    /// The preset the widget matches (a PC without a battery leaves the preset's battery item out, as it draws none); null is
    /// "사용자 지정".
    public DisplayPreset? Preset => Enum.GetValues<DisplayPreset>().Cast<DisplayPreset?>().FirstOrDefault(preset =>
        preset!.Value.Layout == layout && showRunner && (preset.Value.Items is not { } items
            || items.Where(id => id != MetricID.Battery || hasBattery).SequenceEqual(ShownItems)));

    /// The layout, the character shown and, except Minimal, the items with their order.
    public void Apply(DisplayPreset preset)
    {
        Layout = preset.Layout;
        store.Set("statusBarLayout", Raw(preset.Layout)); // a picked preset is kept even when it matches the default layout
        ShowRunner = true;
        if (preset.Items is { } items) SetItems([.. items, .. order.Except(items)], items.ToHashSet());
    }

    /// A stored size that isn't one of `WidgetScales` becomes the nearest (the smaller on a tie); unset or unreadable is 100.
    public static int NearestScale(double? stored) =>
        stored is { } value && double.IsFinite(value) ? WidgetScales.MinBy(scale => Math.Abs(scale - value)) : 100;

    /// `by` sizes up (+) or down (−) from `scale`, kept within 100–300 %.
    public static int Step(int scale, int by) =>
        WidgetScales[Math.Clamp(WidgetScales.ToList().IndexOf(NearestScale(scale)) + by, 0, WidgetScales.Count - 1)];

    public event PropertyChangedEventHandler? PropertyChanged;

    /// The Swift raw value ("activity", "penguin", "codexSpeed"), as stored.
    static string Raw<T>(T value) where T : struct, Enum => RunnerCharacterText.Raw(value);

    public RunnerMotion AnimationSource
    {
        get => animationSource;
        set
        {
            if (!Change(ref animationSource, value, "animationSource", Raw(value))) return;
            store.Set(RunnerMotion.ConfirmedKey, true);
        }
    }

    public RunnerCharacter Character { get => character; set => Change(ref character, value, "runnerCharacter", Raw(value)); }
    /// Opt-in notifications; both default off.
    public bool NotifyTurnComplete { get => notifyTurnComplete; set => Change(ref notifyTurnComplete, value, "notifyTurnComplete", value); }
    public bool NotifyInput { get => notifyInput; set => Change(ref notifyInput, value, "notifyInput", value); }
    /// "새 버전 자동 확인": on by default; the GitHub release check. Not part of "기본값으로 되돌리기".
    public bool AutoCheckUpdates { get => autoCheckUpdates; set => Change(ref autoCheckUpdates, value, "autoCheckUpdates", value); }
    /// "실시간 한도 확인": on by default; Codex and Claude usage from OpenAI and Anthropic (LiveLimits). Not part of
    /// "기본값으로 되돌리기" either.
    public bool LiveUsageLimits { get => liveUsageLimits; set => Change(ref liveUsageLimits, value, "liveUsageLimits", value); }
    /// "새 버전 알림": off by default like every notification; silent, once per version.
    public bool NotifyUpdate { get => notifyUpdate; set => Change(ref notifyUpdate, value, "notifyUpdate", value); }
    /// The version whose flyout notice was closed with ✕; a newer version shows again.
    public string? DismissedUpdateVersion
    {
        get => dismissedUpdateVersion;
        set => Change(ref dismissedUpdateVersion, value, "dismissedUpdateVersion", value);
    }

    public Snapshot Current => new(AnimationSource, Character, NotifyTurnComplete, NotifyInput, NotifyUpdate, layout, order, visible, showRunner, widgetScale);

    /// The layout first, then the items, then the character's visibility, so the keep-something-visible rule sees the final setup.
    public void Restore(Snapshot snapshot)
    {
        Layout = snapshot.Layout;
        SetItems(snapshot.Order, snapshot.Visible);
        ShowRunner = snapshot.ShowRunner;
        WidgetScale = snapshot.WidgetScale;
        Character = snapshot.Character;
        AnimationSource = snapshot.AnimationSource;
        NotifyTurnComplete = snapshot.NotifyTurnComplete;
        NotifyInput = snapshot.NotifyInput;
        NotifyUpdate = snapshot.NotifyUpdate;
    }

    /// Display, character and notification choices only. Returns the previous choices, which `Restore` brings back (undo).
    public Snapshot Reset()
    {
        var previous = Current;
        Restore(DefaultSnapshot);
        return previous;
    }

    bool Change<T, TStored>(ref T field, T value, string key, TStored stored, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        store.Set(key, stored);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }
}
