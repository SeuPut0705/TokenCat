namespace TokenCat;

/// PreferenceChecks.swift `runPreferenceChecks`, the kept preferences (DESIGN §3.2 cuts the input sound); the menu-bar items,
/// layout, presets and character visibility drive the widget (§4.7), plus its size. On temp settings files; ⌘Z is `Restore`
/// with the snapshot `Reset` returns.
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
            check(open().AutoCheckUpdates && !open().NotifyUpdate && open().DismissedUpdateVersion == null && open().LiveUsageLimits,
                  "A new install did not default to automatic update checks and live usage limits on and the new-version notification off");
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
            guarded.LiveUsageLimits = false;
            var stored = open();
            check(stored.NotifyInput && stored.NotifyTurnComplete && stored.AnimationSource == RunnerMotion.Still && stored.NotifyUpdate
                  && !stored.AutoCheckUpdates && stored.DismissedUpdateVersion == "0.9.1" && store.Get<string>("animationSource") == "still"
                  && !stored.LiveUsageLimits && store.Get<bool?>("liveUsageLimits") == false,
                  "The input sound, new-version notification, automatic check, live usage limits or dismissed version did not persist");
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

            // The on-screen widget (DESIGN §4.7): on, two lines, the six standard items; presets set the mac keys; reset leaves it alone.
            var widget = open();
            check(widget.ShowWidget && widget.Layout == StatusBarLayout.Compact && widget.Preset == DisplayPreset.SystemMonitor
                  && widget.ShownItems.SequenceEqual(MetricID.Standard) && widget.Order.SequenceEqual(Enum.GetValues<MetricID>())
                  && Enum.GetValues<MetricID>()[^2..].SequenceEqual([MetricID.CodexSpeed, MetricID.ClaudeSpeed])
                  && MetricID.Standard.SequenceEqual([MetricID.Cpu, MetricID.Memory, MetricID.Disk, MetricID.Battery, MetricID.Network, MetricID.Ai])
                  && Enum.GetValues<DisplayPreset>().Select(preset => preset.Items)
                      .SequenceEqual([null, [MetricID.Ai, MetricID.Cpu, MetricID.Memory], MetricID.Standard, MetricID.Standard],
                          EqualityComparer<IReadOnlyList<MetricID>?>.Create((a, b) => a is null ? b is null : b is not null && a.SequenceEqual(b))),
                  "A new install did not show the widget on two lines with the six standard items (the speed items off, last), or a preset's item set changed");
            widget.Apply(DisplayPreset.AiFocus);
            var focus = open();
            check(focus.Layout == StatusBarLayout.Compact && focus.ShownItems.SequenceEqual([MetricID.Ai, MetricID.Cpu, MetricID.Memory])
                  && focus.Preset == DisplayPreset.AiFocus && store.Get<string>("statusBarLayout") == "compact"
                  && store.Get<string[]>("visibleMetrics") is ["ai", "cpu", "memory"] && store.Get<string[]>("metricOrder")?.Length == 8,
                  "The AI Focus preset did not persist its layout and items in the mac keys");
            focus.Apply(DisplayPreset.Minimal);
            check(open().Preset == DisplayPreset.Minimal && open().ShownItems.SequenceEqual([MetricID.Ai, MetricID.Cpu, MetricID.Memory]),
                  "The minimal preset changed the item list");
            focus.Apply(DisplayPreset.SystemMonitor);
            store.Set("visibleMetrics", new[] { "cpu", "memory", "disk", "network", "ai", "unknown" });
            var unplugged = open();
            unplugged.HasBattery = false;
            check(unplugged.Preset == DisplayPreset.SystemMonitor && unplugged.ShownItems.Count == 5,
                  "A PC without a battery item did not still match System Monitor, or an unknown item was kept");
            // An existing order and item set from before the speed items: they append, hidden, and 시스템 모니터 still matches. Turned
            // on they draw last as 사용자 지정, stored by their mac raw names; 시스템 모니터 hides them again.
            store.Set("metricOrder", new[] { "cpu", "memory", "disk", "battery", "network", "ai" });
            store.Set("visibleMetrics", new[] { "cpu", "memory", "disk", "battery", "network", "ai" });
            var upgraded = open();
            var appended = upgraded.Order.SequenceEqual(Enum.GetValues<MetricID>()) && upgraded.Visible.SetEquals(MetricID.Standard)
                           && upgraded.Preset == DisplayPreset.SystemMonitor;
            upgraded.SetVisible(MetricID.ClaudeSpeed, true);
            var speedOn = (upgraded.Preset, upgraded.ShownItems[^1], open().Visible.Contains(MetricID.ClaudeSpeed));
            var raw = store.Get<string[]>("metricOrder")?[^2..];
            upgraded.Apply(DisplayPreset.SystemMonitor);
            check(appended && speedOn == (null, MetricID.ClaudeSpeed, true) && raw is ["codexSpeed", "claudeSpeed"]
                  && upgraded.Preset == DisplayPreset.SystemMonitor && !upgraded.Visible.Contains(MetricID.ClaudeSpeed) && open().Order.SequenceEqual(Enum.GetValues<MetricID>()),
                  "An existing order and item set did not get the speed items appended and hidden, a speed item turned on did not draw last as 사용자 지정 or "
                  + "round-trip as \"claudeSpeed\", or 시스템 모니터 did not hide it again");
            focus.ShowWidget = false;
            focus.Reset();
            store.Set("statusBarLayout", "sideways");
            check(!open().ShowWidget && store.Get<bool?>("showWidget") == false && open().Layout == StatusBarLayout.Compact,
                  "Hiding the widget did not persist, reset showed it again, or an unknown layout did not fall back to two lines");

            // Items and the character (mac MetricRows and CharacterPane): the widget never draws nothing.
            var items = new SettingsStore(Path.Combine(folder.FullName, "items.json"));
            items.Set("statusBarLayout", "compact");
            items.Set("visibleMetrics", Array.Empty<string>());
            items.Set("showRunner", false);
            check(new Preferences(items).ShowRunner, "A stored empty widget was not repaired by showing the character");
            items.Set("visibleMetrics", new[] { "cpu" });
            var guard = new Preferences(items);
            guard.SetVisible(MetricID.Cpu, false);
            check(!guard.ShowRunner && guard.Visible.SetEquals([MetricID.Cpu]) && guard.CanHideRunner && !guard.CanHide(MetricID.Cpu),
                  "The last visible item could be hidden while the character was hidden");
            guard.SetShowRunner(true);
            guard.SetVisible(MetricID.Cpu, false);
            guard.SetShowRunner(false);
            check(guard.Visible.Count == 0 && guard.ShowRunner, "The character could be hidden with no item left to show");
            guard.SetVisible(MetricID.Battery, true);
            guard.HasBattery = false;
            check(!guard.CanHideRunner && guard.ShownItems.Count == 0 && guard.Visible.SetEquals([MetricID.Battery]),
                  "A battery item on a PC without a battery counted as something visible");
            guard.Layout = StatusBarLayout.Minimal;
            guard.SetShowRunner(false);
            check(!guard.ShowRunner && guard.CanHideRunner, "The minimal layout (always showing AI) blocked hiding the character");
            guard.Layout = StatusBarLayout.Compact;
            check(guard.ShowRunner && items.Get<bool?>("showRunner") == true, "Leaving the minimal layout with nothing to draw did not bring the character back");

            guard.Move(MetricID.Cpu, onto: MetricID.Battery);
            var down = guard.Order.ToList();
            guard.Move(MetricID.Network, onto: MetricID.Memory);
            guard.Move(MetricID.Ai, onto: MetricID.Ai);
            guard.Move(MetricID.ClaudeSpeed, onto: MetricID.CodexSpeed);
            check(down.SequenceEqual([MetricID.Memory, MetricID.Disk, MetricID.Battery, MetricID.Cpu, MetricID.Network, MetricID.Ai, MetricID.CodexSpeed, MetricID.ClaudeSpeed])
                  && new Preferences(items).Order.SequenceEqual([MetricID.Network, MetricID.Memory, MetricID.Disk, MetricID.Battery, MetricID.Cpu, MetricID.Ai,
                                                                 MetricID.ClaudeSpeed, MetricID.CodexSpeed]),
                  "Dropping a row onto another did not take its place in either direction, or did not persist");
            guard.Move(MetricID.Network, -1);
            guard.Move(MetricID.CodexSpeed, 1);
            guard.Move(MetricID.Cpu, -1);
            guard.Move(MetricID.Memory, 1);
            check(guard.Order.SequenceEqual([MetricID.Network, MetricID.Disk, MetricID.Memory, MetricID.Cpu, MetricID.Battery, MetricID.Ai, MetricID.ClaudeSpeed, MetricID.CodexSpeed])
                  && items.Get<string[]>("metricOrder") is ["network", "disk", "memory", "cpu", "battery", "ai", "claudeSpeed", "codexSpeed"],
                  "Moving up or down did not swap with the neighbour, moved past either end, or did not persist");
            // A speed item alone is drawn and, with the character hidden, can't be hidden as the last item.
            guard.SetVisible(MetricID.CodexSpeed, true);
            guard.SetShowRunner(false);
            guard.SetVisible(MetricID.Battery, false);
            check(guard.ShownItems.SequenceEqual([MetricID.CodexSpeed]) && !guard.CanHide(MetricID.CodexSpeed) && !guard.ShowRunner,
                  "A speed item was not drawn, or could be hidden as the last item");
            guard.SetShowRunner(true);
            guard.SetVisible(MetricID.CodexSpeed, false);
            guard.SetVisible(MetricID.Battery, true);

            // Presets: each applied is the one matched and shows the character; the default is 최소; a hand edit is 사용자 지정.
            var presets = new Preferences(items);
            presets.Reset();
            var matchedDefault = presets.Preset;
            var applied = new List<DisplayPreset?>();
            var shown = true;
            foreach (var preset in Enum.GetValues<DisplayPreset>().Reverse())
            {
                presets.Layout = StatusBarLayout.Minimal;
                presets.SetShowRunner(false);
                presets.Apply(preset);
                applied.Add(presets.Preset);
                shown &= presets.ShowRunner;
            }
            var aiFocus = presets.Order.Take(3).SequenceEqual([MetricID.Ai, MetricID.Cpu, MetricID.Memory])
                          && presets.Visible.SetEquals([MetricID.Ai, MetricID.Cpu, MetricID.Memory]);
            presets.Layout = StatusBarLayout.Compact;
            presets.SetVisible(MetricID.Disk, true);
            var handEdit = presets.Preset;
            presets.Apply(DisplayPreset.AiFocus);
            presets.SetShowRunner(false);
            check(matchedDefault == DisplayPreset.SystemMonitor && applied.SequenceEqual(Enum.GetValues<DisplayPreset>().Reverse().Cast<DisplayPreset?>())
                  && shown && aiFocus && handEdit == null && presets.Preset == null,
                  "Display presets did not match after applying or did not show the character, the default is not 최소, or a hand edit or a hidden character was not 사용자 지정");
            presets.Apply(DisplayPreset.SystemMonitor);
            presets.HasBattery = false;
            presets.SetVisible(MetricID.Battery, false);
            var unpluggedPreset = presets.Preset;
            presets.HasBattery = true;
            check(unpluggedPreset == DisplayPreset.SystemMonitor && presets.Preset == null,
                  "On a PC without a battery the undrawn battery item turned 시스템 모니터 into 사용자 지정, or with a battery hiding it did not");

            // Reset covers the widget's layout, items, character and size; showing it and its positions stay; ⌘Z brings it all back.
            presets.SetShowRunner(false);
            presets.WidgetScale = 175;
            presets.Move(MetricID.Ai, -1);
            presets.ShowWidget = false;
            WidgetPlacement.Save(items, "display", new(12, 34, 56, 78));
            var custom = presets.Current;
            var undo = presets.Reset();
            var reset = new Preferences(items);
            check(presets.Current == Preferences.DefaultSnapshot && reset.Current == Preferences.DefaultSnapshot && reset.Layout == StatusBarLayout.Compact
                  && reset.ShowRunner && reset.WidgetScale == 100 && reset.Order.SequenceEqual(Enum.GetValues<MetricID>()) && reset.Visible.Count == 6
                  && !reset.ShowWidget && WidgetPlacement.Saved(items, "display") == new System.Drawing.Rectangle(12, 34, 56, 78),
                  "Reset did not restore the widget's layout, items, character and size, or showed it again or moved it");
            presets.Restore(undo);
            check(undo == custom && presets.Current == custom && new Preferences(items).Current == custom && custom.WidgetScale == 175
                  && !custom.ShowRunner && custom.Layout == StatusBarLayout.Compact && custom.Order[4] == MetricID.Ai && !custom.Visible.Contains(MetricID.Battery),
                  "Undoing a reset did not bring back the widget's layout, items, order, character visibility and size");

            // Size: 100 % by default; a stored value outside the seven becomes the nearest; steps stop at 100 and 300.
            var scales = new SettingsStore(Path.Combine(folder.FullName, "scale.json"));
            int scaleOf(Action write) { write(); return new Preferences(scales).WidgetScale; }
            check(scaleOf(() => { }) == 100 && scaleOf(() => scales.Set("widgetScale", 150)) == 150 && scaleOf(() => scales.Set("widgetScale", 160)) == 150
                  && scaleOf(() => scales.Set("widgetScale", 1_000)) == 300 && scaleOf(() => scales.Set("widgetScale", -5)) == 100
                  && scaleOf(() => scales.Set("widgetScale", 112.5)) == 100 && scaleOf(() => scales.Set("widgetScale", "big")) == 100,
                  "A missing, unknown or unreadable widget size did not fall back to the nearest size or 100 %");
            var sized = new Preferences(scales);
            var announced = new List<string?>();
            sized.PropertyChanged += (_, change) => announced.Add(change.PropertyName);
            sized.WidgetScale = 260;
            sized.WidgetScale = 250;
            check(sized.WidgetScale == 250 && scales.Get<int?>("widgetScale") == 250 && announced.SequenceEqual(["WidgetScale"])
                  && Preferences.Step(100, -1) == 100 && Preferences.Step(100, 1) == 125 && Preferences.Step(250, 1) == 300
                  && Preferences.Step(300, 1) == 300 && Preferences.Step(175, -2) == 125 && Preferences.Step(160, 1) == 175,
                  "The widget size did not persist once as the nearest size, or a step went past 100 % or 300 %");
        }
        finally { folder.Delete(true); }
        return c.Done();
    }
}
