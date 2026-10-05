using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace TokenCat;

/// App.swift `Preferences`, the fields Windows keeps: the menu-bar order, items, layout, presets and the input sound are cut
/// (DESIGN §3.2). Same keys and raw values as the mac's UserDefaults. A change writes its own key (the motion also marks
/// itself confirmed) and raises PropertyChanged for the settings window and the tray.
public sealed class Preferences : INotifyPropertyChanged
{
    /// The choices "기본값으로 되돌리기" covers; login item and automatic update checks are not here.
    public sealed record Snapshot(RunnerMotion AnimationSource, RunnerCharacter Character, bool NotifyTurnComplete, bool NotifyInput, bool NotifyUpdate);

    public static Snapshot DefaultSnapshot { get; } = new(RunnerMotion.Activity, RunnerCharacter.Cat, false, false, false);

    readonly SettingsStore store;
    RunnerMotion animationSource;
    RunnerCharacter character;
    bool notifyTurnComplete, notifyInput, autoCheckUpdates, notifyUpdate;
    string? dismissedUpdateVersion;

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
        dismissedUpdateVersion = store.Get<string>("dismissedUpdateVersion");
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
    /// "새 버전 자동 확인": on by default; TokenCat's only internet request. Not part of "기본값으로 되돌리기".
    public bool AutoCheckUpdates { get => autoCheckUpdates; set => Change(ref autoCheckUpdates, value, "autoCheckUpdates", value); }
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
