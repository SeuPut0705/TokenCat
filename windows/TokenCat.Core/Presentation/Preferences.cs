using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace TokenCat;

/// App.swift `Preferences`, the fields Windows keeps: the input sound and per-item editing are cut (DESIGN §3.2); the layout
/// and items are set by presets and drawn by the on-screen widget (§4.7). Same keys and raw values as the mac's UserDefaults.
/// A change writes its own key (the motion also marks itself confirmed) and raises PropertyChanged for Settings and the shell.
public sealed class Preferences : INotifyPropertyChanged
{
    /// The choices "기본값으로 되돌리기" covers; login item and automatic update checks are not here.
    public sealed record Snapshot(RunnerMotion AnimationSource, RunnerCharacter Character, bool NotifyTurnComplete, bool NotifyInput, bool NotifyUpdate);

    public static Snapshot DefaultSnapshot { get; } = new(RunnerMotion.Activity, RunnerCharacter.Cat, false, false, false);

    readonly SettingsStore store;
    RunnerMotion animationSource;
    RunnerCharacter character;
    bool notifyTurnComplete, notifyInput, autoCheckUpdates, notifyUpdate, showWidget, liveUsageLimits;
    string? dismissedUpdateVersion;
    StatusBarLayout layout;
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
        // The widget starts on, in the minimal layout (the mac bar starts compact); unknown item names are dropped.
        showWidget = store.Get<bool?>("showWidget") ?? true;
        layout = RunnerCharacterText.Parse<StatusBarLayout>(store.Get<string>("statusBarLayout")) ?? StatusBarLayout.Minimal;
        static IEnumerable<MetricID> Items(string[]? names) => (names ?? []).Select(RunnerCharacterText.Parse<MetricID>).OfType<MetricID>();
        order = [.. Items(store.Get<string[]>("metricOrder")).Concat(Enum.GetValues<MetricID>()).Distinct()];
        visible = store.Get<string[]>("visibleMetrics") is { } shown ? Items(shown).ToHashSet() : Enum.GetValues<MetricID>().ToHashSet();
    }

    /// "화면에 위젯 표시": on by default. Not part of "기본값으로 되돌리기".
    public bool ShowWidget { get => showWidget; set => Change(ref showWidget, value, "showWidget", value); }
    public StatusBarLayout Layout => layout;
    /// What the two-line and one-line layouts draw, in order.
    public IReadOnlyList<MetricID> ShownItems => [.. order.Where(visible.Contains)];

    /// The preset the widget matches (the battery is ignored: a PC without one draws none); null is "사용자 지정".
    public DisplayPreset? Preset => Enum.GetValues<DisplayPreset>().Cast<DisplayPreset?>().FirstOrDefault(preset =>
        preset!.Value.Layout == layout && (preset.Value.Items is not { } items
            || items.Where(id => id != MetricID.Battery).SequenceEqual(ShownItems.Where(id => id != MetricID.Battery))));

    public void Apply(DisplayPreset preset)
    {
        if (preset.Items is { } items)
        {
            order = [.. items, .. order.Except(items)];
            visible = items.ToHashSet();
            store.Set("metricOrder", order.Select(Raw).ToArray());
            store.Set("visibleMetrics", items.Select(Raw).ToArray());
        }
        layout = preset.Layout;
        store.Set("statusBarLayout", Raw(layout));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Preset)));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// The Swift raw value ("activity", "penguin"), as stored.
    static string Raw<T>(T value) where T : struct, Enum => value.ToString().ToLowerInvariant();

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

    public Snapshot Current => new(AnimationSource, Character, NotifyTurnComplete, NotifyInput, NotifyUpdate);

    public void Restore(Snapshot snapshot)
    {
        Character = snapshot.Character;
        AnimationSource = snapshot.AnimationSource;
        NotifyTurnComplete = snapshot.NotifyTurnComplete;
        NotifyInput = snapshot.NotifyInput;
        NotifyUpdate = snapshot.NotifyUpdate;
    }

    /// Character, motion and notification choices only. Returns the previous choices, which `Restore` brings back (undo).
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
