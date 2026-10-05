namespace TokenCat;

/// PreferenceChecks.swift `runPreferenceChecks`, the kept preferences (DESIGN §3.2 cuts menu-bar order, items, layout,
/// presets and the input sound). On a temp settings file; ⌘Z is `Restore` with the snapshot `Reset` returns.
public static class PreferenceChecks
{
    public static List<string> Run()
    {
        var c = new Check("Preference");
        void check(bool valid, string description) => c.That(valid, description);
        var folder = Directory.CreateTempSubdirectory("tokencat-preference-checks-");
        try
        {
            var store = new SettingsStore(Path.Combine(folder.FullName, "settings.json"));
            Preferences open() => new(store);
            check(open().AnimationSource == RunnerMotion.Activity && !open().NotifyTurnComplete && !open().NotifyInput,
                  "A new install did not default to AI activity motion with notifications and their sound off");
            check(open().AutoCheckUpdates && !open().NotifyUpdate && open().DismissedUpdateVersion == null,
                  "A new install did not default to automatic update checks on and the new-version notification off");
            store.Set("animationSource", "tokens");
            check(open().AnimationSource == RunnerMotion.Activity,
                  "Migration lost a visible provider, unrelated preferences, or kept the legacy 'tokens' motion");
            store.Set(RunnerMotion.ConfirmedKey, true);
            store.Set("animationSource", "cpu");
            check(open().AnimationSource == RunnerMotion.Cpu, "A CPU motion saved by this version was not kept, or an unknown layout did not fall back");
            // Older builds saved their "cpu" default on any change; that unconfirmed value moves to AI activity once.
            store.Remove(RunnerMotion.ConfirmedKey);
            var legacy = open();
            var legacyUntouched = legacy.AnimationSource == RunnerMotion.Activity && store.Get<bool?>(RunnerMotion.ConfirmedKey) == null
                                  && store.Get<string>("animationSource") == "cpu";
            legacy.AnimationSource = RunnerMotion.Cpu;
            check(legacyUntouched && open().AnimationSource == RunnerMotion.Cpu,
                  "An unconfirmed older 'cpu' did not start on AI activity without writing, or a CPU choice made afterwards was lost");

            var guarded = open();
            store.Set("unrelatedKey", 1_234.0);
            guarded.NotifyInput = true;
            guarded.NotifyTurnComplete = true;
            guarded.AnimationSource = RunnerMotion.Still;
            guarded.NotifyUpdate = true;
            guarded.AutoCheckUpdates = false;
            guarded.DismissedUpdateVersion = "0.9.1";
            var stored = open();
            check(stored.NotifyInput && stored.NotifyTurnComplete && stored.AnimationSource == RunnerMotion.Still && stored.NotifyUpdate
                  && !stored.AutoCheckUpdates && stored.DismissedUpdateVersion == "0.9.1" && store.Get<string>("animationSource") == "still",
                  "The input sound, new-version notification, automatic check or dismissed version did not persist");
            // Character: persisted, announced to the tray, part of reset; an unknown stored id falls back to the cat.
            var changed = new List<string?>();
            guarded.PropertyChanged += (_, change) => changed.Add(change.PropertyName);
            guarded.Character = RunnerCharacter.Penguin;
            check(open().Character == RunnerCharacter.Penguin && store.Get<string>("runnerCharacter") == "penguin" && changed.SequenceEqual(["Character"]),
                  "The character did not persist, or the runner did not switch to its own frames");
            var before = guarded.Current;
            var previous = guarded.Reset();
            check(guarded.Current == Preferences.DefaultSnapshot && open().Current == Preferences.DefaultSnapshot
                  && guarded.Character == RunnerCharacter.Cat && guarded.AnimationSource == RunnerMotion.Activity
                  && !guarded.NotifyInput && !guarded.NotifyTurnComplete && !guarded.NotifyUpdate && store.Get<double?>("unrelatedKey") == 1_234
                  && !guarded.AutoCheckUpdates && guarded.DismissedUpdateVersion == "0.9.1",
                  "Reset did not restore display and notification defaults, or touched unrelated state, the automatic check or the dismissed version");
            guarded.Restore(previous);
            check(previous == before && guarded.Current == before && open().Current == before && before.Character == RunnerCharacter.Penguin
                  && before.NotifyInput && before.NotifyTurnComplete && before.NotifyUpdate,
                  "⌘Z after reset did not restore the previous order and all four notification toggles, or ⇧⌘Z did not reapply");
            store.Set("runnerCharacter", "unicorn");
            check(open().Character == RunnerCharacter.Cat, "An unknown stored character did not fall back to the cat");
        }
        finally { folder.Delete(true); }
        return c.Done();
    }
}
