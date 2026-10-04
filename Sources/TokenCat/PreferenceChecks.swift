import Foundation

func runPreferenceChecks() -> [String] {
    let suite = "dev.seuput.TokenCat.check.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return ["Could not create isolated preference domain"] }
    defer { defaults.removePersistentDomain(forName: suite) }
    var failures: [String] = []
    var checks = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append(description) }
    }
    check(Preferences(defaults: defaults).animationSource == .activity && !Preferences(defaults: defaults).notifyTurnComplete
          && !Preferences(defaults: defaults).notifyInput,
          "A new install did not default to AI activity motion with notifications off")
    defaults.set(["claude", "disk", "codex", "cpu", "memory", "battery", "network"], forKey: "metricOrder")
    defaults.set(["cpu", "claude", "network"], forKey: "visibleMetrics")
    defaults.set(false, forKey: "showRunner")
    defaults.set("tokens", forKey: "animationSource")
    let migrated = Preferences(defaults: defaults)
    check(migrated.order == [.ai, .disk, .cpu, .memory, .battery, .network],
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
    check(down == [.memory, .disk, .battery, .cpu, .network, .ai]
          && Preferences(defaults: defaults).order == [.network, .memory, .disk, .battery, .cpu, .ai],
          "Dropping a row onto another did not take its place in either direction, or did not persist")
    defaults.set(1_234.0, forKey: "unrelatedKey")
    guarded.notifyInput = true
    guarded.animationSource = .still
    guarded.reset()
    check(guarded.order == MetricID.allCases && guarded.visible == Set(MetricID.allCases) && guarded.animationSource == .activity
          && guarded.showRunner && guarded.statusBarLayout == .compact && !guarded.notifyInput && !guarded.notifyTurnComplete
          && defaults.double(forKey: "unrelatedKey") == 1_234,
          "Reset did not restore display defaults or touched unrelated state")
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

    check(RunnerDirector.fps(cpu: 5) == 6 && RunnerDirector.fps(cpu: 100) == 14 && RunnerDirector.fps(cpu: 1) == 6
          && abs(RunnerDirector.fps(cpu: 52.5) - 10) < 0.001, "CPU cadence is not 5–100% → 6–14 fps")
    var director = RunnerDirector()
    func cpuPlan(_ cpu: Double) -> RunnerPlan {
        let value = activity { $0.cpu = cpu }
        director.observe(value, now: at)
        return director.plan(.cpu, activity: value, now: at, reduceMotion: false)
    }
    check(cpuPlan(5).pose == .sit && cpuPlan(7).pose == .run && cpuPlan(5).pose == .run && cpuPlan(3.9).pose == .sit,
          "CPU motion lacks sit <4% / run >6% hysteresis")
    check(cpuPlan(50).smooth && cpuPlan(50).fps == RunnerDirector.fps(cpu: 50), "CPU motion does not ease toward its target")

    director = RunnerDirector()
    let working = activity { $0.running = true; $0.newestActivityAt = at }
    check(director.plan(.activity, activity: working, now: at, reduceMotion: false) == RunnerPlan(pose: .walk, fps: 8),
          "Working or tool sessions do not walk at a fixed 8 fps")
    var output = working
    output.newestOutputAt = at
    director.observe(output, now: at)
    let burst = director.plan(.activity, activity: output, now: at.addingTimeInterval(0.5), reduceMotion: false)
    director.observe(output, now: at.addingTimeInterval(1))
    check(burst.pose == .run && burst.fps == 14 && burst.until == at.addingTimeInterval(1.2)
          && director.burstUntil == at.addingTimeInterval(1.2),
          "A fresh output event does not run once for 1.2 s, or a refresh of the same event retriggers it")
    check(director.plan(.activity, activity: output, now: at.addingTimeInterval(1.3), reduceMotion: false).pose == .walk,
          "The run burst does not end after 1.2 s")
    output.newestOutputAt = at.addingTimeInterval(2)
    director.observe(output, now: at.addingTimeInterval(2.2))
    check(abs((director.burstUntil ?? at).timeIntervalSince(at) - 3.4) < 0.001, "A newer output event does not start a new burst")
    var oldOutput = working
    oldOutput.newestOutputAt = at.addingTimeInterval(-30)
    var quiet = RunnerDirector()
    quiet.observe(oldOutput, now: at)
    check(quiet.burstUntil == nil, "An output event older than 5 s triggered a burst")
    let input = activity { $0.input = true; $0.running = true }
    check(director.plan(.activity, activity: input, now: at.addingTimeInterval(2.5), reduceMotion: false).pose == .alert,
          "Waiting for input does not outrank a run burst")
    check(director.plan(.activity, activity: input, now: at, reduceMotion: true) == RunnerPlan(pose: .alert),
          "Reduce Motion does not hold a still pose for the state")
    check(RunnerDirector().plan(.activity, activity: activity { $0.waiting = true }, now: at, reduceMotion: false).pose == .sit,
          "A log wait does not sit")
    var idle = RunnerDirector()
    let recent = activity { $0.newestActivityAt = at.addingTimeInterval(-120) }
    check(idle.plan(.activity, activity: recent, now: at, reduceMotion: false).pose == .sit
          && idle.plan(.activity, activity: recent, now: at.addingTimeInterval(481), reduceMotion: false) == RunnerPlan(pose: .sleep),
          "No live group does not sit, then sleep (a still pose, fps 0, no blink timer) 10 minutes after the last activity")
    idle.observe(working, now: at.addingTimeInterval(400))
    check(idle.plan(.activity, activity: RunnerActivity(), now: at.addingTimeInterval(900), reduceMotion: false).pose == .sit,
          "Sleep is not measured from the last time a session was live")
    check(idle.plan(.still, activity: working, now: at, reduceMotion: false) == RunnerPlan(pose: .sit)
          && idle.plan(.measured, activity: working, now: at, reduceMotion: false).pose == .sit
          && idle.plan(.measured, activity: activity { $0.measuredRate = 200 }, now: at, reduceMotion: false) == RunnerPlan(pose: .run, fps: 14, smooth: true),
          "Still or measured motion does not follow its source (no measurement sits)")
    let animator = RunnerAnimator()
    var rendered: [RunnerPose] = []
    animator.render = { pose, _ in rendered.append(pose) }
    animator.apply(RunnerPlan(pose: .walk, fps: 8))
    let walking = animator.isTimerRunning
    animator.paused = true
    let pausedStops = !animator.isTimerRunning
    animator.paused = false
    animator.apply(RunnerPlan(pose: .alert))
    check(walking && pausedStops && !animator.isTimerRunning && rendered == [.walk, .alert],
          "The cat timer runs while hidden or for a still pose, or a pose change is not drawn")
    animator.stop()
    check(RunnerMotion.stored("tokens", confirmed: true) == .activity && RunnerMotion.stored(nil, confirmed: false) == .activity
          && RunnerMotion.stored("cpu", confirmed: true) == .cpu && RunnerMotion.stored("cpu", confirmed: false) == .activity
          && RunnerMotion.stored("still", confirmed: false) == .still,
          "Motion migration is wrong")

    // Notifications: top-level transitions only, content-free bodies, no replay at launch.
    var tracker = AttentionTracker()
    var signal = AttentionSignal(id: "claude:s1", source: .claude, project: "TokenCat", model: "claude-opus-5-5", live: true,
                                 input: false, ended: nil, outputTokens: nil, durationSeconds: nil)
    check(tracker.update([signal]).isEmpty, "The first publish replayed existing states")
    signal.input = true
    let asked = tracker.update([signal])
    check(asked.count == 1 && asked.first?.body == "TokenCat · claude-opus-5-5 입력 필요" && asked.first?.title == "Claude Code",
          "Entering input did not notify once with metadata only")
    check(tracker.update([signal]).isEmpty, "Input notified again on an unchanged publish")
    signal.input = false
    signal.live = false
    signal.ended = .complete
    signal.outputTokens = 12_480
    signal.durationSeconds = 252
    let finished = tracker.update([signal])
    check(finished.count == 1 && finished.first?.body == "TokenCat · claude-opus-5-5 턴 완료 · 12,480 tok · 4분 12초",
          "Live → complete did not produce the metadata-only completion body")
    check(tracker.update([signal]).isEmpty, "A completed turn notified twice")
    var codex = AttentionSignal(id: "codex:t1", source: .codex, project: nil, model: nil, live: false, input: false,
                                ended: .interrupted, outputTokens: 0, durationSeconds: nil)
    check(tracker.update([signal, codex]).isEmpty, "A session first seen already finished was reported")
    codex.live = true
    codex.ended = nil
    _ = tracker.update([signal, codex])
    codex.live = false
    codex.ended = .interrupted
    check(tracker.update([signal, codex]).first?.body == "턴 중단", "An interrupted turn is not reported as 중단")
    var repeated = signal
    repeated.id = "claude:s2"
    repeated.live = true
    repeated.ended = nil
    _ = tracker.update([repeated])
    repeated.live = false
    repeated.ended = .interrupted
    check(tracker.update([repeated]).first?.body == "TokenCat · claude-opus-5-5 턴 중단",
          "An interrupted turn carried the previous completed turn's output and duration")
    repeated.live = true
    repeated.ended = nil
    _ = tracker.update([repeated])
    repeated.live = false
    repeated.ended = .complete
    check(tracker.update([repeated]).first?.body == "TokenCat · claude-opus-5-5 턴 완료",
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
    print("Shell checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
