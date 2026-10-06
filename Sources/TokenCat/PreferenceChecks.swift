import Foundation

func runPreferenceChecks() -> [String] {
    guard let scratch = ScratchDefaults("dev.seuput.TokenCat.check") else { return ["Could not create isolated preference domain"] }
    defer { scratch.discard() }
    let suite = scratch.name, defaults = scratch.defaults
    var failures: [String] = []
    var checks = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append(description) }
    }
    check(Preferences(defaults: defaults).animationSource == .activity && !Preferences(defaults: defaults).notifyTurnComplete
          && !Preferences(defaults: defaults).notifyInput && !Preferences(defaults: defaults).notifyInputSound,
          "A new install did not default to AI activity motion with notifications and their sound off")
    check(Preferences(defaults: defaults).autoCheckUpdates && !Preferences(defaults: defaults).notifyUpdate
          && Preferences(defaults: defaults).dismissedUpdateVersion == nil,
          "A new install did not default to automatic update checks on and the new-version notification off")
    let fresh = Preferences(defaults: defaults)
    check(fresh.order == MetricID.allCases && fresh.visible == Set(MetricID.standard) && fresh.preset == .systemMonitor
          && MetricID.allCases.last == .averageSpeed && MetricID.standard == [.cpu, .memory, .disk, .battery, .network, .ai]
          && DisplayPreset.allCases.map(\.items) == [nil, [.ai, .cpu, .memory], MetricID.standard, MetricID.standard],
          "A new install did not start with the six standard items (the speed item off, last), or a preset's item set changed")
    defaults.set(["cpu", "memory", "disk", "battery", "network", "ai"], forKey: "metricOrder")
    defaults.set(["cpu", "memory", "disk", "battery", "network", "ai"], forKey: "visibleMetrics")
    let upgraded = Preferences(defaults: defaults)
    check(upgraded.order == MetricID.allCases && upgraded.visible == Set(MetricID.standard) && upgraded.preset == .systemMonitor,
          "An existing order and item set did not get the speed item appended and hidden, or left 시스템 모니터")
    upgraded.setVisible(.averageSpeed, true)
    let speedOn = (upgraded.preset, upgraded.shownItems.last)
    upgraded.apply(.systemMonitor)
    check(speedOn == (nil, .averageSpeed) && upgraded.preset == .systemMonitor && !upgraded.visible.contains(.averageSpeed)
          && Preferences(defaults: defaults).order == MetricID.allCases,
          "The speed item turned on did not draw last as 사용자 지정, or 시스템 모니터 did not hide it again")
    defaults.removePersistentDomain(forName: suite)
    defaults.set(["claude", "disk", "codex", "cpu", "memory", "battery", "network"], forKey: "metricOrder")
    defaults.set(["cpu", "claude", "network"], forKey: "visibleMetrics")
    defaults.set(false, forKey: "showRunner")
    defaults.set("tokens", forKey: "animationSource")
    let migrated = Preferences(defaults: defaults)
    check(migrated.order == [.ai, .disk, .cpu, .memory, .battery, .network, .averageSpeed],
          "Migration changed custom metric order or duplicated the AI item")
    check(migrated.visible == [.cpu, .ai, .network] && !migrated.showRunner && migrated.animationSource == .activity,
          "Migration lost a visible provider, unrelated preferences, or kept the legacy 'tokens' motion")
    migrated.visible.insert(.battery)
    let reopened = Preferences(defaults: defaults)
    check(reopened.visible == [.cpu, .ai, .network, .battery]
          && reopened.order == migrated.order
          && defaults.stringArray(forKey: "metricOrder")?.contains("claude") == false
          && defaults.string(forKey: "animationSource") == "activity",
          "Updated preferences did not persist as the migrated format")
    defaults.set(["cpu", "memory"], forKey: "visibleMetrics")
    check(!Preferences(defaults: defaults).visible.contains(.ai),
          "Migration exposed AI when both old provider fields were hidden")
    // The per-client speed items (until 0.13) became the average item: either shown shows it, and their slots leave the order.
    defaults.set(["cpu", "codexSpeed", "memory", "claudeSpeed", "averageSpeed", "ai"], forKey: "metricOrder")
    defaults.set(["cpu", "claudeSpeed", "codexSpeed"], forKey: "visibleMetrics")
    let speedShown = Preferences(defaults: defaults)
    defaults.set(["cpu", "codexSpeed", "claudeSpeed", "memory", "disk", "battery", "network", "ai"], forKey: "metricOrder")
    defaults.set(["cpu", "memory"], forKey: "visibleMetrics")
    let speedHidden = Preferences(defaults: defaults)
    check(speedShown.order == [.cpu, .memory, .averageSpeed, .ai, .disk, .battery, .network] && speedShown.visible == [.cpu, .averageSpeed]
          && speedHidden.order == [.cpu, .memory, .disk, .battery, .network, .ai, .averageSpeed] && speedHidden.visible == [.cpu, .memory],
          "The old Codex/Claude speed items did not migrate to the average item (shown when either was), or kept their slots")
    check(reopened.statusBarLayout == .compact,
          "Existing preferences did not default to the compact menu layout")
    reopened.statusBarLayout = .minimal
    check(Preferences(defaults: defaults).statusBarLayout == .minimal,
          "Menu layout choice did not persist across reopening")
    defaults.set("cpu", forKey: "animationSource")
    defaults.set("unknown", forKey: "statusBarLayout")
    let explicit = Preferences(defaults: defaults)
    check(explicit.animationSource == .cpu && explicit.statusBarLayout == .compact,
          "A CPU motion saved by this version was not kept, or an unknown layout did not fall back")
    // Older builds saved their "cpu" default on any change; that unconfirmed value moves to AI activity once.
    defaults.removeObject(forKey: RunnerMotion.confirmedKey)
    let legacy = Preferences(defaults: defaults)
    let legacyUntouched = legacy.animationSource == .activity && defaults.object(forKey: RunnerMotion.confirmedKey) == nil
        && defaults.string(forKey: "animationSource") == "cpu"
    legacy.animationSource = .cpu
    check(legacyUntouched && Preferences(defaults: defaults).animationSource == .cpu,
          "An unconfirmed older 'cpu' did not start on AI activity without writing, or a CPU choice made afterwards was lost")

    // Guards: never leave the bar with nothing but a placeholder.
    defaults.set([String](), forKey: "visibleMetrics")
    defaults.set(false, forKey: "showRunner")
    check(Preferences(defaults: defaults).showRunner, "A stored empty menu bar was not repaired by showing the cat")
    let guarded = Preferences(defaults: defaults)
    guarded.visible = [.cpu]
    guarded.showRunner = false
    guarded.setVisible(.cpu, false)
    check(guarded.visible == [.cpu] && guarded.canHideRunner && !guarded.canHide(.cpu),
          "The last visible item could be hidden while the cat was hidden")
    guarded.visible = [.averageSpeed]
    check(guarded.shownItems == [.averageSpeed] && !guarded.canHide(.averageSpeed), "The speed item was not drawn, or could be hidden as the last item")
    guarded.visible = [.cpu]
    guarded.setShowRunner(true)
    guarded.setVisible(.cpu, false)
    guarded.setShowRunner(false)
    check(guarded.visible.isEmpty && guarded.showRunner, "The cat could be hidden with no item left to show")
    guarded.visible = [.battery]
    guarded.hasBattery = false
    check(!guarded.canHideRunner && guarded.shownItems.isEmpty,
          "A battery item on a Mac without a battery counted as something visible")
    guarded.statusBarLayout = .minimal
    guarded.setShowRunner(false)
    check(!guarded.showRunner && guarded.canHideRunner, "The minimal layout (always showing AI) blocked hiding the cat")
    guarded.statusBarLayout = .compact
    check(guarded.showRunner, "Leaving the minimal layout with nothing to draw did not bring the cat back")

    guarded.order = MetricID.allCases
    guarded.move(.cpu, onto: .battery)
    let down = guarded.order
    guarded.move(.network, onto: .memory)
    guarded.move(.ai, onto: .ai)
    guarded.move(.averageSpeed, onto: .ai)
    check(down == [.memory, .disk, .battery, .cpu, .network, .ai, .averageSpeed]
          && Preferences(defaults: defaults).order == [.network, .memory, .disk, .battery, .cpu, .averageSpeed, .ai],
          "Dropping a row onto another did not take its place in either direction, or did not persist")
    defaults.set(1_234.0, forKey: "unrelatedKey")
    guarded.notifyInput = true
    guarded.notifyInputSound = true
    guarded.notifyTurnComplete = true
    guarded.animationSource = .still
    guarded.notifyUpdate = true
    guarded.autoCheckUpdates = false
    guarded.dismissedUpdateVersion = "0.9.1"
    let stored = Preferences(defaults: defaults)
    check(stored.notifyInputSound && stored.notifyUpdate && !stored.autoCheckUpdates && stored.dismissedUpdateVersion == "0.9.1",
          "The input sound, new-version notification, automatic check or dismissed version did not persist")
    // Character: persisted, followed by the runner at once, part of reset; an unknown stored id falls back to the cat.
    guarded.character = .penguin
    check(Preferences(defaults: defaults).character == .penguin && Runner.character == .penguin
          && Runner.image(pose: .walk, frame: 0) === Runner.image(pose: .walk, frame: 0, character: .penguin)
          && Runner.image(pose: .walk, frame: 0, character: .penguin) !== Runner.image(pose: .walk, frame: 0, character: .cat),
          "The character did not persist, or the runner did not switch to its own frames")
    let before = guarded.snapshot
    let undo = UndoManager()
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    guarded.reset(undoManager: undo)
    undo.endUndoGrouping()
    check(guarded.snapshot == Preferences.defaultSnapshot && guarded.order == MetricID.allCases && guarded.visible == Set(MetricID.standard)
          && guarded.character == .cat && Runner.character == .cat
          && guarded.animationSource == .activity && guarded.showRunner && guarded.statusBarLayout == .compact && !guarded.notifyInput
          && !guarded.notifyTurnComplete && !guarded.notifyInputSound && !guarded.notifyUpdate && defaults.double(forKey: "unrelatedKey") == 1_234
          && !guarded.autoCheckUpdates && guarded.dismissedUpdateVersion == "0.9.1",
          "Reset did not restore display and notification defaults, or touched unrelated state, the automatic check or the dismissed version")
    undo.undo()
    let undone = guarded.snapshot
    undo.redo()
    check(undone == before && before.order == [.network, .memory, .disk, .battery, .cpu, .averageSpeed, .ai] && before.notifyInputSound && before.notifyUpdate
          && before.character == .penguin
          && guarded.snapshot == Preferences.defaultSnapshot && undo.undoActionName == "기본값으로 되돌리기",
          "⌘Z after reset did not restore the previous order and all four notification toggles, or ⇧⌘Z did not reapply")
    defaults.set("unicorn", forKey: "runnerCharacter")
    check(Preferences(defaults: defaults).character == .cat, "An unknown stored character did not fall back to the cat")

    // Display presets: each one applied is the one matched; the defaults are 시스템 모니터; a hand edit is 사용자 지정.
    let presets = Preferences(defaults: defaults)
    presets.reset()
    let matchedDefault = presets.preset
    var applied: [DisplayPreset?] = []
    for preset in DisplayPreset.allCases.reversed() {
        presets.apply(preset)
        applied.append(presets.preset)
    }
    let aiFocus = (presets.order.prefix(3) == [.ai, .cpu, .memory], presets.visible == [.ai, .cpu, .memory])
    presets.apply(.minimal)
    let minimalKeepsItems = presets.visible == [.ai, .cpu, .memory]
    presets.statusBarLayout = .compact
    presets.setVisible(.disk, true)
    check(matchedDefault == .systemMonitor && applied == DisplayPreset.allCases.reversed().map(Optional.some) && aiFocus == (true, true)
          && minimalKeepsItems && presets.preset == nil,
          "Display presets did not match after applying, the defaults are not 시스템 모니터, or a hand edit was not 사용자 지정")
    let custom = presets.snapshot
    let presetUndo = UndoManager()
    presetUndo.groupsByEvent = false
    presetUndo.beginUndoGrouping()
    presets.apply(.aiFocus, undoManager: presetUndo)
    presetUndo.endUndoGrouping()
    presetUndo.undo()
    check(presets.snapshot == custom, "⌘Z after a preset did not bring back the custom order and items")
    presets.apply(.systemMonitor)
    presets.hasBattery = false
    presets.setVisible(.battery, false)
    check(presets.preset == .systemMonitor, "On a Mac without a battery, the undrawn battery item turned 시스템 모니터 into 사용자 지정")
    presets.reset()
    print("Preference checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}

/// Cat state machine, notification transitions and the telemetry restart notice.
func runShellChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append("Shell: " + description) }
    }
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    func activity(_ build: (inout RunnerActivity) -> Void) -> RunnerActivity {
        var value = RunnerActivity()
        build(&value)
        return value
    }

    // Director (K-4, K-5): CPU gait with hysteresis and linear cadences, measured gait, bursts.
    check(RunnerDirector.fps(cpu: 6, gait: .walk) == 5 && RunnerDirector.fps(cpu: 20, gait: .walk) == 8
          && RunnerDirector.fps(cpu: 20, gait: .run) == 8 && RunnerDirector.fps(cpu: 100, gait: .run) == 14
          && abs(RunnerDirector.fps(cpu: 13, gait: .walk) - 6.5) < 0.001 && abs(RunnerDirector.fps(cpu: 60, gait: .run) - 11) < 0.001,
          "CPU cadence is not walk 6–20% → 5–8 fps, run 20–100% → 8–14 fps")
    var director = RunnerDirector()
    var unread = RunnerActivity()
    unread.known = false
    check(RunnerDirector().plan(.activity, activity: unread, now: at, reduceMotion: false).pose == .sit,
          "Before the first token sample the cat slept (and would yawn when the sample arrived)")
    func cpuPose(_ cpu: Double) -> RunnerPose {
        let value = activity { $0.cpu = cpu }
        director.observe(value, now: at)
        return director.plan(.cpu, activity: value, now: at, reduceMotion: false).pose
    }
    let gaits = [5, 7, 5, 3.9, 12, 25, 18, 14.9, 21, 3].map(cpuPose)
    check(gaits == [.sit, .walk, .walk, .sit, .walk, .run, .run, .walk, .run, .sit],
          "CPU gait lacks sit <4%/>6% and walk <15%/run >20% hysteresis: \(gaits.map(\.rawValue))")
    director.observe(activity { $0.cpu = 50 }, now: at)
    let cpuRun = director.plan(.cpu, activity: activity { $0.cpu = 50 }, now: at, reduceMotion: false)
    check(cpuRun.smooth && cpuRun.pose == .run && cpuRun.fps == RunnerDirector.fps(cpu: 50, gait: .run), "CPU motion does not ease toward its target")
    check(RunnerDirector.measuredPlan(30) == RunnerPlan(pose: .walk, fps: 7.25, smooth: true)
          && RunnerDirector.measuredPlan(40) == RunnerPlan(pose: .run, fps: 8, smooth: true)
          && RunnerDirector.measuredPlan(500) == RunnerPlan(pose: .run, fps: 14, smooth: true)
          && RunnerDirector().plan(.measured, activity: RunnerActivity(), now: at, reduceMotion: false) == RunnerPlan(pose: .sit),
          "Measured motion is not walk below 40 tok/s, run from 40, sit without a measurement")

    director = RunnerDirector()
    let working = activity { $0.running = true; $0.newestActivityAt = at }
    check(director.plan(.activity, activity: working, now: at, reduceMotion: false) == RunnerPlan(pose: .walk),
          "Working or tool sessions do not walk on the manifest timing")
    var output = working
    output.newestOutputAt = at
    director.observe(output, now: at)
    let burst = director.plan(.activity, activity: output, now: at.addingTimeInterval(0.5), reduceMotion: false)
    director.observe(output, now: at.addingTimeInterval(1))
    check(burst == RunnerPlan(pose: .run, until: at.addingTimeInterval(1.2)) && director.burstUntil == at.addingTimeInterval(1.2),
          "A fresh output event does not run once for 1.2 s, or a refresh of the same event retriggers it")
    check(director.plan(.activity, activity: output, now: at.addingTimeInterval(1.3), reduceMotion: false).pose == .walk,
          "The run burst does not end after 1.2 s")
    var during = RunnerDirector()
    output.newestOutputAt = at
    during.observe(output, now: at)
    output.newestOutputAt = at.addingTimeInterval(0.8)
    during.observe(output, now: at.addingTimeInterval(0.9))
    check(abs((during.burstUntil ?? at).timeIntervalSince(at) - 2.1) < 0.001, "A newer output during a run does not extend it")
    output.newestOutputAt = at.addingTimeInterval(2.5)
    during.observe(output, now: at.addingTimeInterval(2.6))
    check(abs((during.burstUntil ?? at).timeIntervalSince(at) - 3.8) < 0.001, "An output within 1 s after a run ended did not run again")
    output.newestOutputAt = at.addingTimeInterval(4)
    during.observe(output, now: at.addingTimeInterval(4.1))
    check(abs((during.burstUntil ?? at).timeIntervalSince(at) - 5.3) < 0.001, "An output well after a run ended did not start a new one")
    var oldOutput = working
    oldOutput.newestOutputAt = at.addingTimeInterval(-30)
    var quiet = RunnerDirector()
    quiet.observe(oldOutput, now: at)
    check(quiet.burstUntil == nil, "An output event older than 5 s triggered a burst")
    let input = activity { $0.input = true; $0.running = true }
    director.observe(activity { $0.newestOutputAt = at.addingTimeInterval(2.4); $0.running = true }, now: at.addingTimeInterval(2.4))
    check(director.plan(.activity, activity: input, now: at.addingTimeInterval(2.5), reduceMotion: false).pose == .alert,
          "Waiting for input does not outrank a run burst")
    check(director.plan(.activity, activity: input, now: at, reduceMotion: true) == RunnerPlan(pose: .alert, still: true),
          "Reduce Motion does not hold a still pose for the state")
    check(RunnerDirector().plan(.activity, activity: activity { $0.waiting = true }, now: at, reduceMotion: false).pose == .sit,
          "A log wait does not sit")
    var idle = RunnerDirector()
    let recent = activity { $0.newestActivityAt = at.addingTimeInterval(-120) }
    check(idle.plan(.activity, activity: recent, now: at, reduceMotion: false).pose == .sit
          && idle.plan(.activity, activity: recent, now: at.addingTimeInterval(481), reduceMotion: false) == RunnerPlan(pose: .sleep),
          "No live group does not sit, then sleep 10 minutes after the last activity")
    idle.observe(working, now: at.addingTimeInterval(400))
    check(idle.plan(.activity, activity: RunnerActivity(), now: at.addingTimeInterval(900), reduceMotion: false).pose == .sit,
          "Sleep is not measured from the last time a session was live")
    check(idle.plan(.still, activity: working, now: at, reduceMotion: false) == RunnerPlan(pose: .sit, still: true),
          "Still motion does not hold the sit pose")

    // Animator (K-2, K-3, K-5, K-6): driven by an injected clock; `advance()` is the timer's action.
    var clock = at
    var drawn: [(RunnerPose, Int, Int?)] = []
    func animator(_ timing: [RunnerPose: RunnerTiming] = [:]) -> RunnerAnimator {
        let value = RunnerAnimator()
        value.clock = { clock }
        value.timing = { timing[$0] ?? Runner.timing($0) }
        value.render = { drawn.append(($0, $1, $2)) }
        return value
    }
    /// Advances `count` timer steps, returning each step's (delay, frame, fx) before it fires.
    func run(_ value: RunnerAnimator, _ count: Int) -> [(delay: TimeInterval, frame: Int, fx: Int?)] {
        (0..<count).compactMap { _ in
            guard let delay = value.scheduledDelay else { return nil }
            let step = (delay, value.frame, value.fx)
            clock = clock.addingTimeInterval(delay)
            value.advance()
            return step
        }
    }
    func near(_ a: [TimeInterval], _ b: [TimeInterval]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.0001 } }

    let interim = animator()
    interim.apply(RunnerPlan(pose: .sit))
    check(near(run(interim, 2).map(\.delay), [Runner.timing(.sit).durations[0], Runner.timing(.sit).durations[1]]),
          "The sit blink does not read Runner.timing")
    interim.stop()

    let sitTiming = RunnerTiming(durations: [6, 0.12], holdSequence: [6, 9.5, 4.5, 11, 7.5], doubleEvery: 4)
    let blinker = animator([.sit: sitTiming])
    blinker.apply(RunnerPlan(pose: .walk))
    clock = clock.addingTimeInterval(5)
    blinker.apply(RunnerPlan(pose: .sit))
    let rhythm = run(blinker, 12)
    check(near(rhythm.map(\.delay), [6, 0.12, 9.5, 0.12, 4.5, 0.12, 11, 0.12, 0.15, 0.12, 7.5, 0.12])
          && rhythm.map(\.frame) == [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1],
          "Sit blinks do not cycle the hold sequence with a double blink every 4th: \(rhythm.map(\.delay))")
    blinker.stop()

    let walkTiming = RunnerTiming(durations: [0.15, 0.15, 0.15, 0.15])
    let walker = animator([.walk: walkTiming, .run: RunnerTiming(durations: Array(repeating: 1 / 14, count: 6))])
    walker.apply(RunnerPlan(pose: .walk))
    let steps = run(walker, 5)
    check(near(steps.map(\.delay), [0.15, 0.15, 0.15, 0.15, 0.15]) && steps.map(\.frame) == [0, 1, 2, 3, 0],
          "Walking does not step 4 frames at the manifest's 0.150 s")
    // Dwell: walk → run waits until the walk has shown 1 s; input never waits.
    clock = at.addingTimeInterval(100)
    walker.apply(RunnerPlan(pose: .sit))
    walker.apply(RunnerPlan(pose: .walk))
    clock = clock.addingTimeInterval(0.3)
    walker.apply(RunnerPlan(pose: .run, until: clock.addingTimeInterval(1.2)))
    let held = walker.shown.pose == .walk && (walker.scheduledDelay ?? 1) <= 0.7 + 0.0001
    clock = clock.addingTimeInterval(0.7)
    walker.advance()
    check(held && walker.shown.pose == .run && walker.frame == 0, "walk → run did not wait for the 1 s dwell, or never switched")
    clock = clock.addingTimeInterval(0.1)
    walker.apply(RunnerPlan(pose: .run, until: clock.addingTimeInterval(1.2)))
    let extended = walker.shown.pose == .run && walker.frame == 0
    walker.apply(RunnerPlan(pose: .alert))
    check(extended && walker.shown.pose == .alert, "A burst extension restarted the run, or input waited for the dwell")
    // A burst within 1 s after a run ended continues that run's stride at once; a later one starts at frame 0.
    clock = clock.addingTimeInterval(5)
    walker.apply(RunnerPlan(pose: .sit))
    walker.apply(RunnerPlan(pose: .run, until: clock.addingTimeInterval(1.2)))
    let strides = run(walker, 3).map(\.frame)
    clock = clock.addingTimeInterval(1.2 - 3.0 / 14)
    walker.apply(RunnerPlan(pose: .walk))
    let walked = walker.shown.pose == .walk
    clock = clock.addingTimeInterval(0.6)
    walker.apply(RunnerPlan(pose: .run, until: clock.addingTimeInterval(1.2)))
    let joined = walker.shown.pose == .run && walker.frame == 4 && abs((walker.scheduledDelay ?? 0) - 1.0 / 14) < 0.0001
    clock = clock.addingTimeInterval(1.2)
    walker.apply(RunnerPlan(pose: .walk))
    clock = clock.addingTimeInterval(1.1)
    walker.apply(RunnerPlan(pose: .run, until: clock.addingTimeInterval(1.2)))
    check(strides == [0, 1, 2] && walked && joined && walker.shown.pose == .run && walker.frame == 0,
          "A burst within 1 s after a run ended did not continue the run's stride at once, or a later one did not start afresh")
    walker.apply(RunnerPlan(pose: .alert))
    walker.paused = true
    let pausedStops = !walker.isTimerRunning
    walker.paused = false
    walker.apply(RunnerPlan(pose: .alert, still: true))
    check(pausedStops && !walker.isTimerRunning, "The cat timer runs while hidden or for a still pose")
    walker.stop()

    // Sleep: 1.6 s breaths A → B (small z) → C (large z), deep sleep after 20 min with no timer; Reduce Motion holds zL.
    clock = at
    drawn = []
    let sleeper = animator()
    sleeper.apply(RunnerPlan(pose: .sleep))
    let breaths = run(sleeper, 4)
    check(breaths.map(\.frame) == [0, 1, 0, 0] && breaths.map(\.fx) == [nil, RunnerAnimator.smallZ, RunnerAnimator.largeZ, nil]
          && breaths.allSatisfy { $0.delay >= 1.0 } && sleeper.isTimerRunning && !sleeper.isDeepSleep,
          "Sleep does not breathe A/B/C on 1.6 s steps (fewer than one wake a second): \(breaths)")
    clock = at.addingTimeInterval(RunnerAnimator.deepSleepAfter)
    sleeper.advance()
    check(sleeper.isDeepSleep && !sleeper.isTimerRunning && sleeper.scheduledDelay == nil && sleeper.frame == 0
          && sleeper.fx == RunnerAnimator.largeZ && drawn.last.map { $0.0 == .sleep && $0.2 == RunnerAnimator.largeZ } == true,
          "Deep sleep after 20 minutes does not hold frame 0 with the large z and stop the timer")
    sleeper.paused = true
    sleeper.paused = false
    check(!sleeper.isTimerRunning, "Resuming a deep sleep restarted the breathing timer")
    // Waking yawns once (0.6 s), then the plan; waking for input does not yawn.
    sleeper.apply(RunnerPlan(pose: .walk))
    let yawning = sleeper.shown.pose == .yawn && sleeper.isPlayingOneShot && abs((sleeper.scheduledDelay ?? 0) - Runner.timing(.yawn).durations[0]) < 0.001
    clock = clock.addingTimeInterval(sleeper.scheduledDelay ?? 0)
    sleeper.advance()
    check(yawning && sleeper.shown.pose == .walk && !sleeper.isDeepSleep, "Waking does not yawn once before the next pose")
    sleeper.apply(RunnerPlan(pose: .sleep))
    sleeper.apply(RunnerPlan(pose: .alert))
    check(sleeper.shown.pose == .alert && !sleeper.isPlayingOneShot, "Input waited for a wake-up yawn")
    sleeper.apply(RunnerPlan(pose: .sleep, still: true))
    check(sleeper.frame == 0 && sleeper.fx == RunnerAnimator.largeZ && !sleeper.isTimerRunning,
          "Reduce Motion sleep is not a still frame with the large z")
    sleeper.apply(RunnerPlan(pose: .sit, still: true))
    check(sleeper.shown.pose == .sit && !sleeper.isPlayingOneShot, "Reduce Motion played the wake-up yawn")
    check(!sleeper.playContent(), "Reduce Motion played the turn-end content")
    sleeper.stop()

    // Content: only on a moving sit; 0.5 → blink 0.45 → 0.55 from the manifest; input and run cancel it, walk waits.
    clock = at
    let contentTiming = RunnerTiming(durations: [0.5, 0.45], holdSequence: [0.5, 0.55])
    let content = animator([.content: contentTiming])
    content.apply(RunnerPlan(pose: .walk))
    let refusesWalk = !content.playContent()
    content.apply(RunnerPlan(pose: .sit))
    let started = content.playContent()
    let played = run(content, 3)
    check(refusesWalk && started && near(played.map(\.delay), [0.5, 0.45, 0.55]) && played.map(\.frame) == [0, 1, 0]
          && content.shown.pose == .sit && !content.isPlayingOneShot,
          "Turn-end content is not sit 0.5 → blink 0.45 → sit 0.55, only while sitting")
    content.playContent()
    content.apply(RunnerPlan(pose: .walk))
    let waits = content.shown.pose == .content
    content.apply(RunnerPlan(pose: .run, until: clock.addingTimeInterval(1.2)))
    check(waits && content.shown.pose == .run && !content.isPlayingOneShot, "A walk interrupted content, or a run did not cancel it")
    // Hidden cat: a playing content is dropped, none starts, and waking does not queue a yawn for later.
    content.apply(RunnerPlan(pose: .sit))
    content.playContent()
    content.paused = true
    let dropped = !content.isPlayingOneShot && content.shown.pose == .sit && !content.isTimerRunning
    let refusedHidden = !content.playContent()
    content.apply(RunnerPlan(pose: .sleep))
    content.apply(RunnerPlan(pose: .walk))
    check(dropped && refusedHidden && content.shown.pose == .walk && !content.isPlayingOneShot,
          "A one-shot stays queued while the cat is hidden and plays late")
    content.paused = false
    content.stop()
    check(RunnerAnimator.stillFX(.sleep) == RunnerAnimator.largeZ && RunnerAnimator.stillFX(.sit) == nil,
          "A still sleep frame does not keep only the large z")
    check(RunnerMotion.stored("tokens", confirmed: true) == .activity && RunnerMotion.stored(nil, confirmed: false) == .activity
          && RunnerMotion.stored("cpu", confirmed: true) == .cpu && RunnerMotion.stored("cpu", confirmed: false) == .activity
          && RunnerMotion.stored("still", confirmed: false) == .still,
          "Motion migration is wrong")
    check(RunnerLegend.entries(.activity).map(\.pose) == [.walk, .run, .alert, .sit, .sleep]
          && RunnerLegend.entries(.cpu).map(\.caption) == ["4% 미만", "20%까지", "20% 넘음"]
          && RunnerLegend.entries(.measured).map(\.caption) == ["실측 없음", "40 tok/s 미만", "40 이상"] && RunnerLegend.entries(.still).isEmpty,
          "The cat legend does not match the motion source")

    // Notifications: top-level transitions only, content-free bodies, no replay at launch.
    var tracker = AttentionTracker()
    var signal = AttentionSignal(id: "claude:s1", source: .claude, project: "TokenCat", model: "claude-opus-5-5", live: true,
                                 input: false, ended: nil, outputTokens: nil, durationSeconds: nil)
    check(tracker.update([signal]).isEmpty, "The first publish replayed existing states")
    signal.input = true
    let asked = tracker.update([signal])
    check(asked.count == 1 && asked.first?.title == "입력 필요 · TokenCat" && asked.first?.subtitle == "Claude Code · claude-opus-5-5"
          && asked.first?.body == "답변하면 계속됩니다" && asked.first?.identifier == "input-claude:s1",
          "Entering input did not notify once with the state-first title and metadata only")
    check(tracker.update([signal]).isEmpty, "Input notified again on an unchanged publish")
    signal.input = false
    signal.live = false
    signal.ended = .complete
    signal.outputTokens = 12_480
    signal.durationSeconds = 252
    let finished = tracker.update([signal])
    check(finished.count == 1 && finished.first?.title == "턴 완료 · TokenCat" && finished.first?.body == "12,480 tok · 4분 12초"
          && finished.first?.identifier == "done-claude:s1",
          "Live → complete did not produce the metadata-only completion")
    check(tracker.update([signal]).isEmpty, "A completed turn notified twice")
    check(Notifier.describeSound(.authorized, .notSupported, on: true).hasPrefix("macOS가 TokenCat 알림 소리를 허용하지 않았습니다")
          && Notifier.soundBlocked(.authorized, .notSupported) && Notifier.soundBlocked(.authorized, .disabled)
          && !Notifier.soundBlocked(.authorized, .enabled) && !Notifier.soundBlocked(.notDetermined, .notSupported)
          && Notifier.describeSound(.notDetermined, .notSupported, on: true) == "알림 권한을 허용하면 소리가 납니다",
          "A sound macOS will not play is captioned as still loading, or offers no way to System Settings")
    var codex = AttentionSignal(id: "codex:t1", source: .codex, project: nil, model: nil, live: false, input: false,
                                ended: .interrupted, outputTokens: 0, durationSeconds: nil)
    check(tracker.update([signal, codex]).isEmpty, "A session first seen already finished was reported")
    codex.live = true
    codex.ended = nil
    _ = tracker.update([signal, codex])
    codex.live = false
    codex.ended = .interrupted
    let interrupted = tracker.update([signal, codex]).first
    check(interrupted?.title == "턴 중단 · 프로젝트 미확인" && interrupted?.subtitle == "Codex" && interrupted?.body == "",
          "An interrupted turn is not reported as 중단 without a project, model or body")
    check(interrupted?.signal.contentKey == nil && finished.first?.signal.contentKey != nil,
          "An interrupted turn (Esc or API error) played the cat's turn-complete content")
    AppLanguage.with(.en) {
        check(asked.first?.title == "Input needed · TokenCat" && asked.first?.body == "Reply to continue"
              && finished.first?.title == "Turn complete · TokenCat" && finished.first?.body == "12,480 tok · 4m 12s"
              && interrupted?.title == "Turn interrupted · Unknown project" && AttentionEvent.duration(3_725) == "1h 2m"
              && Notifier.describe(.denied) == "TokenCat notifications are off in System Settings"
              && Notifier.describeSound(.authorized, .enabled, on: true) == "On · input-needed alerts play the default sound"
              && LoginItem.describe(.requiresApproval) == "Needs approval in System Settings › General › Login Items",
              "English notifications or login item captions are wrong")
    }
    check(AttentionEvent.duration(3_725) == "1시간 2분" && AttentionEvent.duration(5) == "5초"
          && LoginItem.describe(.notRegistered) == "꺼짐 · 켤 때만 로그인 항목에 등록합니다",
          "Korean notification durations or login item captions changed")
    var repeated = signal
    repeated.id = "claude:s2"
    repeated.live = true
    repeated.ended = nil
    _ = tracker.update([repeated])
    repeated.live = false
    repeated.ended = .interrupted
    check(tracker.update([repeated]).first.map { $0.title == "턴 중단 · TokenCat" && $0.body.isEmpty } == true,
          "An interrupted turn carried the previous completed turn's output and duration")
    repeated.live = true
    repeated.ended = nil
    _ = tracker.update([repeated])
    repeated.live = false
    repeated.ended = .complete
    check(tracker.update([repeated]).first.map { $0.title == "턴 완료 · TokenCat" && $0.body.isEmpty } == true,
          "A completion without newly recorded values reused the previous turn's numbers")

    let groups = SessionPresentation.groups([
        TokenReading(source: .claude, id: "claude:parent", sessionID: "p", project: "demo", model: "m", active: false,
                     activityState: .complete, sampledAt: at),
        { var child = TokenReading(source: .claude, id: "claude:child", sessionID: "p", agentID: "a", isSubagent: true,
                                   active: true, activityState: .input, sampledAt: at); child.parentSessionID = "p"; return child }(),
        TokenReading(source: .codex, id: "telemetry:codex", sampledAt: at)
    ], now: at)
    let signals = AttentionSignal.make(groups)
    check(signals.count == 1 && signals.first?.input == true && signals.first?.live == true && signals.first?.ended == nil,
          "A subagent waiting for input does not keep its top-level group live, or telemetry rows were included")
    var planReading = TokenReading(source: .claude, id: "claude:plan", sessionID: "r", project: "demo", active: true, activityState: .input, sampledAt: at)
    planReading.toolName = "ExitPlanMode"
    let planEvent = AttentionSignal.make(SessionPresentation.groups([planReading], now: at)).first.map { AttentionEvent.input($0) }
    check(signals.first?.plan == false && planEvent?.title == "계획 승인 대기 · demo" && planEvent?.body == "승인하면 계속됩니다",
          "A plan approval was notified as 입력 필요 · 답변하면 계속됩니다")
    func staleChildGroup(_ child: TokenActivityState, leadActive: Bool, lead: TokenActivityState) -> [SessionGroup] {
        SessionPresentation.groups([
            TokenReading(source: .claude, id: "claude:lead", sessionID: "q", project: "demo", model: "m", active: leadActive,
                         activityState: lead, sampledAt: at),
            { var c = TokenReading(source: .claude, id: "claude:stale-child", sessionID: "q", agentID: "b", isSubagent: true,
                                   active: false, activityState: child, sampledAt: at); c.parentSessionID = "q"; return c }()
        ], now: at)
    }
    var lateTracker = AttentionTracker()
    _ = lateTracker.update(AttentionSignal.make(staleChildGroup(.stale, leadActive: true, lead: .working)))
    let onTime = lateTracker.update(AttentionSignal.make(staleChildGroup(.stale, leadActive: false, lead: .complete)))
    let late = lateTracker.update(AttentionSignal.make(staleChildGroup(.unfinished, leadActive: false, lead: .complete)))
    check(onTime.count == 1 && late.isEmpty,
          "A stale subagent held back the lead's completion or produced a late notification when it timed out")

    let connected = at
    var state = TelemetryRestartState.resolve(pending: [.claude: connected, .codex: connected],
                                              received: [.claude: connected.addingTimeInterval(-1)], now: at.addingTimeInterval(60))
    check(state.needed == [.claude, .codex] && state.expired.isEmpty, "A reading from before the config change cleared the restart notice")
    state = TelemetryRestartState.resolve(pending: state.pending, received: [.claude: connected.addingTimeInterval(5)],
                                          now: at.addingTimeInterval(60))
    check(state.needed == [.codex] && state.pending[.claude] == nil, "The first reading after connecting did not clear its client")
    let unused = TelemetryRestartState.resolve(pending: state.pending, received: [:], now: at.addingTimeInterval(86_401))
    check(unused.needed.isEmpty && unused.expired.isEmpty && unused.pending[.codex] != nil,
          "A client never used since its config changed was reported as failing after 24 h")
    state = TelemetryRestartState.resolve(pending: state.pending, received: [:], ran: [.codex: connected.addingTimeInterval(600)],
                                          now: at.addingTimeInterval(86_401))
    check(state.needed.isEmpty && state.expired == [.codex] && state.pending[.codex] != nil,
          "A client used after its config change but silent for 24 h did not switch to the 'never received' message")
    // VoiceOver announcements: at most one per 5 s; a held burst keeps its most urgent text.
    var gate = AnnouncementGate()
    let first = gate.offer("턴 완료", priority: 50, now: at)
    let second = gate.offer("턴 완료", priority: 50, now: at.addingTimeInterval(1))
    let third = gate.offer("TokenCat 세션 입력 필요", priority: 90, now: at.addingTimeInterval(2))
    let flushed = gate.flush(now: at.addingTimeInterval(5))
    let later = gate.offer("턴 완료", priority: 50, now: at.addingTimeInterval(10.1))
    check(first.post == "턴 완료" && second.post == nil && second.flushAfter == 4 && third.post == nil && third.flushAfter == nil
          && flushed?.text == "TokenCat 세션 입력 필요" && later.post == "턴 완료",
          "Announcements are not limited to one per 5 s with the most urgent held text")

    // Settings (T-1, T-3): tab order and symbols, collector and client status rows.
    check(SettingsPane.allCases.map(\.title) == ["일반", "메뉴 막대", "캐릭터", "실측", "정보"] && SettingsPane.allCases.allSatisfy { $0.image != nil }
          && SettingsPane(rawValue: "cat") == .character,
          "Settings tabs are not 일반 · 메뉴 막대 · 캐릭터 · 실측 · 정보 with a symbol each, or the remembered 'cat' tab is lost")
    check(TelemetryStatusRow.collector(.receiving) == (.receiving, "수신 중 · 127.0.0.1:16493")
          && TelemetryStatusRow.collector(.waiting).text == "수신 대기 · 127.0.0.1:16493"
          && TelemetryStatusRow.collector(.busyOtherApp) == (.problem, "꺼짐 · 다른 앱이 16493 포트 사용 중")
          && TelemetryStatusRow.collector(.starting) == (.starting, "준비 중"),
          "Collector status rows do not match the T-3 table")
    let client = { (restart: Bool, expired: Bool, received: Date?, batch: Date?) in
        TelemetryStatusRow.client(restartNeeded: restart, expired: expired, lastReceived: received, batch: batch, now: at)
    }
    check(client(true, true, at, at).row == .info && client(false, true, at, at).text == "이 버전에서 실측을 받지 못했습니다"
          && client(false, false, at.addingTimeInterval(-30), at).text == "최근 수신 1분 이내"
          && client(false, false, at.addingTimeInterval(-720), nil).text == "최근 수신 12분 전"
          && client(false, false, nil, at).text == "기록 수신 중 · 속도 형식 없음" && client(false, false, nil, at).detail != nil
          && client(false, false, nil, nil).text == "이번 실행에서 받은 실측 없음",
          "Client telemetry rows are not checked restart → 24 h → received → batch only → none")
    let skippedRow = TelemetryStatusRow.client(skipped: "기존 실측 전송 설정이 있어 덮어쓰지 않았습니다.", restartNeeded: true, expired: false,
                                               lastReceived: at, batch: nil, now: at)
    check(skippedRow == (.info, "연결 안 함 · 기존 실측 설정 유지", "기존 실측 전송 설정이 있어 덮어쓰지 않았습니다."),
          "A Gemini CLI or Qwen Code connection the setup skipped did not say so first, with its reason")
    let limits = { (notes: [TelemetrySetupNote], bridged: Bool?, received: Date?) in
        TelemetryStatusRow.claudeLimits(notes: notes, bridged: bridged, received: received, now: at)
    }
    check(limits([.originalUnknown], true, at) == (.problem, "상태 표시줄이 비어 보일 수 있음", "settings.json의 statusLine을 직접 고쳐 주세요")
          && limits([.statusLineSkipped], false, at).text == "연결 안 함 · statusLine 형식이 달라 건너뜀"
          && limits([], true, at.addingTimeInterval(-180)) == (.received, "최근 수신 3분 전", nil)
          && limits([.originalRecreated], true, at.addingTimeInterval(-50)) == (.received, "최근 수신 1분 이내", "원래 상태 표시줄 명령을 백업 기록에서 다시 만들었습니다")
          && limits([], true, nil) == (.waiting, "아직 받지 못함 · Claude Code를 새로 실행하면 표시", nil)
          && limits([], false, nil).text == "연결 안 함" && limits([], nil, nil).row == .info
          && TelemetryStatusRow.claudeLimits(notes: [], bridged: false, received: at.addingTimeInterval(-720), desktop: true, now: at)
              == (.received, "Claude 데스크톱 앱 기록 · 12분 전", nil),
          "Claude limit row is not checked empty status line → skipped → received → waiting → none")
    AppLanguage.with(.en) {
        check(SettingsPane.allCases.map(\.title) == ["General", "Menu Bar", "Character", "Telemetry", "About"]
              && TelemetryStatusRow.collector(.busyOtherApp).text == "Off · another app is using port 16493"
              && client(false, false, at.addingTimeInterval(-30), at).text == "Last received <1m ago"
              && limits([], true, at.addingTimeInterval(-180)).text == "Last received 3m ago"
              && TelemetryStatusRow.claudeLimits(notes: [], bridged: false, received: at.addingTimeInterval(-720), desktop: true, now: at).text
                  == "Claude desktop app · recorded 12m ago"
              && RunnerLegend.entries(.measured).map(\.caption) == ["Not measured", "Under 40 tok/s", "40 or more"]
              && RunnerLegend.entries(.activity).map(\.name).last == "Sleep" && RunnerMotion.measured.title == "Measured AI Speed",
              "English settings tabs, telemetry rows, cat legend or motion titles are wrong")
    }
    print("Shell checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
