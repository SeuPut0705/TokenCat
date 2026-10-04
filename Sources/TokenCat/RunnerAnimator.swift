import AppKit

/// What drives the menu-bar cat. Raw values are persisted; the legacy "tokens" value maps to `.activity`.
enum RunnerMotion: String, CaseIterable, Identifiable {
    case activity, cpu, measured, still
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activity: return "AI 활동 상태"
        case .cpu: return "CPU 사용률"
        case .measured: return "AI 실측 속도"
        case .still: return "멈춤"
        }
    }
    var caption: String {
        switch self {
        case .activity:
            return "고양이 움직임은 상태만 나타내며 속도가 아닙니다. 진행 중이면 걷고, 출력이 기록되면 잠깐 달리고, 입력이 필요하면 앉아서 이쪽을 봅니다. 활동이 없으면 앉아 있다가 10분 뒤 잠듭니다."
        case .cpu: return "CPU 사용률이 4% 미만이면 앉고, 20%까지는 걷고, 그보다 높으면 달립니다. 높을수록 박자가 빨라집니다."
        case .measured: return "최근 5초 안에 받은 실측 속도에만 반응합니다. 40 tok/s 미만은 걷고 그 이상은 달리며, 실측이 없으면 앉아서 기다립니다."
        case .still: return "고양이가 앉은 자세로 멈춰 있습니다."
        }
    }
    /// One line under the picker (T-2); the legend (T-4) says the rest.
    var subtitle: String {
        switch self {
        case .activity: return "움직임은 상태만 나타내며 속도가 아닙니다."
        case .cpu: return "CPU 사용률에 따라 앉기·걷기·달리기가 바뀝니다."
        case .measured: return "최근 5초 안의 실측 속도에만 반응합니다."
        case .still: return "앉은 자세로 멈춰 있습니다."
        }
    }
    /// Set on the first save by this version. Older builds wrote "cpu" (their default) whenever any setting
    /// changed, so an unconfirmed "cpu" was not a choice and moves to the new default once; later choices stay.
    static let confirmedKey = "animationSourceConfirmed"
    static func stored(_ raw: String?, confirmed: Bool) -> RunnerMotion {
        if raw == "tokens" || (raw == "cpu" && !confirmed) { return .activity }
        return raw.flatMap(RunnerMotion.init(rawValue:)) ?? .activity
    }
}

/// What the director wants on screen. fps 0 plays the pose's own timing (`Runner.timing`), the only cadence source
/// for AI activity; CPU and measured modes set a cadence. `until` asks for a re-plan (end of an output burst).
struct RunnerPlan: Equatable {
    var pose: RunnerPose
    /// Frames per second for CPU and measured modes; 0 plays `Runner.timing(pose)`.
    var fps: Double = 0
    /// Holds frame 0 with no timer (still motion, Reduce Motion); a still sleep shows its large z.
    var still = false
    /// CPU and measured modes ease toward the target cadence.
    var smooth = false
    var until: Date? = nil
}

/// AI state for the cat, computed once per publish from the shared top-level groups.
struct RunnerActivity: Equatable {
    var input = false
    var running = false
    var waiting = false
    var newestOutputAt: Date?
    var newestActivityAt: Date?
    var measuredRate: Double?
    var cpu: Double?
    /// False until the first token sample: an empty session list then means "not read yet", not "quiet".
    var known = true

    init() {}
    init(groups: [SessionGroup], cpu: Double?, now: Date) {
        self.cpu = cpu
        for group in groups {
            let measurement = group.state == .measurement
            if !measurement && group.state.isRunning { running = true }
            if !measurement && group.state == .waiting { waiting = true }
            for member in group.members {
                let reading = member.reading
                if let speed = reading.speedMeasurement, speed.model == reading.model, let rate = speed.tokensPerSecond,
                   abs(now.timeIntervalSince(speed.at)) < 5 { measuredRate = max(measuredRate ?? rate, rate) }
                guard !measurement else { continue }
                if reading.activityState == .input { input = true }
                if let at = reading.lastOutputAt, (reading.lastOutputDelta ?? 0) > 0 { newestOutputAt = max(newestOutputAt ?? at, at) }
                if let at = reading.lastActivity { newestActivityAt = max(newestActivityAt ?? at, at) }
            }
        }
    }
}

/// State → plan. Cadences are fixed per state (AI activity) or follow CPU / a measured rate; never token or session counts.
struct RunnerDirector {
    static let burst: TimeInterval = 1.2, sleepAfter: TimeInterval = 600, easing: TimeInterval = 1.5
    /// A burst that starts this soon after the previous run ended continues that run (no dwell, no frame 0) (K-5).
    static let burstMerge: TimeInterval = 1.0
    /// CPU gait with hysteresis (K-4): sit below 4 % (leaves above 6 %), walk to 20 %, run above 20 % (back below 15 %).
    enum Gait: Equatable { case rest, walk, run }
    private(set) var burstUntil: Date?
    private var burstEventAt: Date?
    private(set) var cpuGait = Gait.rest
    private var lastLiveAt: Date?

    static func walkFPS(_ fraction: Double) -> Double { 5 + 3 * min(1, max(0, fraction)) }
    static func runFPS(_ fraction: Double) -> Double { 8 + 6 * min(1, max(0, fraction)) }
    /// Walk 6–20 % → 5–8 fps, run 20–100 % → 8–14 fps, linear.
    static func fps(cpu: Double, gait: Gait) -> Double { gait == .run ? runFPS((cpu - 20) / 80) : walkFPS((cpu - 6) / 14) }
    /// Measured: below 40 tok/s walk 5–8 fps over 0–40; from 40 run 8–14 fps over 40–200.
    static func measuredPlan(_ rate: Double) -> RunnerPlan {
        rate < 40 ? RunnerPlan(pose: .walk, fps: walkFPS(rate / 40), smooth: true)
            : RunnerPlan(pose: .run, fps: runFPS((rate - 40) / 160), smooth: true)
    }

    /// Called once per publish. A burst is keyed by the output event's own time, so refreshes never retrigger it.
    /// Every newer event runs (or keeps running) for `burst`; the animator joins a run that ended under `burstMerge` ago.
    mutating func observe(_ activity: RunnerActivity, now: Date) {
        if activity.input || activity.running || activity.waiting { lastLiveAt = now }
        if let at = activity.newestOutputAt, at > (burstEventAt ?? .distantPast), abs(now.timeIntervalSince(at)) <= 5 {
            burstEventAt = at
            burstUntil = now.addingTimeInterval(Self.burst)
        }
        if let cpu = activity.cpu {
            switch cpuGait {
            case .rest: if cpu > 6 { cpuGait = cpu > 20 ? .run : .walk }
            case .walk: if cpu < 4 { cpuGait = .rest } else if cpu > 20 { cpuGait = .run }
            case .run: if cpu < 4 { cpuGait = .rest } else if cpu < 15 { cpuGait = .walk }
            }
        }
    }

    /// When the cat's 10 minutes of quiet start: the last live moment or the newest activity. The popover header uses the same time.
    func quietSince(_ activity: RunnerActivity) -> Date? { [lastLiveAt, activity.newestActivityAt].compactMap { $0 }.max() }

    func plan(_ motion: RunnerMotion, activity: RunnerActivity, now: Date, reduceMotion: Bool) -> RunnerPlan {
        var plan: RunnerPlan
        switch motion {
        case .still:
            plan = RunnerPlan(pose: .sit, still: true)
        case .cpu:
            if let cpu = activity.cpu, cpuGait != .rest {
                plan = RunnerPlan(pose: cpuGait == .run ? .run : .walk, fps: Self.fps(cpu: cpu, gait: cpuGait), smooth: true)
            } else { plan = RunnerPlan(pose: .sit) }
        case .measured:
            plan = activity.measuredRate.map(Self.measuredPlan) ?? RunnerPlan(pose: .sit)
        case .activity:
            if !activity.known { plan = RunnerPlan(pose: .sit) }
            else if activity.input { plan = RunnerPlan(pose: .alert) }
            else if let until = burstUntil, now < until { plan = RunnerPlan(pose: .run, until: until) }
            else if activity.running { plan = RunnerPlan(pose: .walk) }
            else if activity.waiting { plan = RunnerPlan(pose: .sit) }
            else {
                plan = RunnerPlan(pose: quietSince(activity).map { now.timeIntervalSince($0) < Self.sleepAfter } == true ? .sit : .sleep)
            }
        }
        if reduceMotion {
            plan.fps = 0
            plan.smooth = false
            plan.still = true
        }
        return plan
    }
}

/// Plays the director's plan with one one-shot timer to the next change; nothing runs while the pose is held or the cat
/// cannot be seen. Frame timing comes only from `Runner.timing` (K-6); the effect layer from `Runner.fxMask` (K-2).
/// - Sit and alert hold frame 0 (sit cycles `holdSequence`) and blink frame 1; every `doubleEvery`-th blink is double.
/// - Sleep breathes A (frame 0) → B (frame 1, small z) → C (frame 0, large z) on 1.6 s steps, then after
///   `deepSleepAfter` holds frame 0 with the large z and no timer (K-3).
/// - Leaving sleep plays the yawn once; a confirmed turn end while sitting plays `content` once (K-5).
/// - walk ↔ run waits until the shown loop has run `dwell`; input interrupts at once; an output burst within
///   `RunnerDirector.burstMerge` after a run ended continues that run's stride at once (K-5).
/// - Nothing one-shot plays while paused: a yawn or `content` is dropped, not replayed later.
final class RunnerAnimator {
    static let dwell: TimeInterval = 1.0
    static let deepSleepAfter: TimeInterval = 1_200
    /// The open gap inside a double blink (closed · open · closed).
    static let doubleBlinkGap: TimeInterval = 0.15
    /// Wake-up tolerance for the 1.6 s breath steps.
    static let breathTolerance: TimeInterval = 0.4
    /// `Runner.fxMask` steps for the sleep z, as the manifest numbers them (0 no z, 1 zS, 2 zL).
    static let smallZ = 1, largeZ = 2
    /// The effect step a held frame shows: a still or deep sleep keeps only the large z.
    static func stillFX(_ pose: RunnerPose) -> Int? { pose == .sleep ? largeZ : nil }

    var render: (RunnerPose, Int, Int?) -> Void = { _, _, _ in }
    var replan: () -> Void = {}
    /// Injected by checks; the app uses the wall clock.
    var clock: () -> Date = Date.init
    var timing: (RunnerPose) -> RunnerTiming = Runner.timing
    private(set) var plan = RunnerPlan(pose: .sit)
    /// What is drawn; differs from `plan` during a one-shot or a dwell hold.
    private(set) var shown = RunnerPlan(pose: .sit)
    private(set) var frame = 0
    private(set) var fx: Int?
    /// Seconds until the pending timer fires; nil when nothing is scheduled.
    private(set) var scheduledDelay: TimeInterval?
    private var fps = 5.0
    private var lastTick: Date?
    private var shownSince = Date.distantPast
    private var sleepSince: Date?
    private var breath = 0
    private var holds = 0
    private var blinks = 0
    private var doubling = 0
    /// Remaining steps of the yawn or content one-shot: (frame, seconds).
    private var oneShot: [(frame: Int, seconds: TimeInterval)] = []
    private var dwellUntil: Date?
    /// When the last run left the screen and its frame, so a burst right after it continues the stride.
    private var runEndedAt: Date?
    private var runFrame = 0
    private var timer: Timer?
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused, !oneShot.isEmpty {
                oneShot = []
                show(plan, now: clock())
            }
            schedule()
        }
    }
    var isTimerRunning: Bool { timer != nil }
    var isDeepSleep: Bool { shown.pose == .sleep && oneShot.isEmpty && sleepSince.map { clock().timeIntervalSince($0) >= Self.deepSleepAfter } == true }
    var isPlayingOneShot: Bool { !oneShot.isEmpty }

    func apply(_ next: RunnerPlan) {
        guard next != plan else { if timer == nil { schedule() }; return }
        let previous = plan
        plan = next
        // Only the cadence or the burst end moved: keep the frame; the running timer eases toward it.
        if next.pose == previous.pose && next.still == previous.still && oneShot.isEmpty && dwellUntil == nil && shown.pose == next.pose {
            if next.smooth && !previous.smooth { fps = 5 }
            shown = next
            if timer == nil { schedule() }
            return
        }
        transition()
    }

    /// Plays `content` once (K-5) when the plan is a moving sit; the caller dedupes by signal id and event time.
    @discardableResult
    func playContent() -> Bool {
        guard !paused, plan.pose == .sit, !plan.still, shown.pose == .sit, oneShot.isEmpty, dwellUntil == nil else { return false }
        startOneShot(.content)
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scheduledDelay = nil
    }

    /// Chooses what to show for `plan`: dwell hold, wake yawn, one-shot cancel, or the plan itself.
    private func transition() {
        let now = clock()
        let urgent = plan.pose == .alert || plan.pose == .run
        if !oneShot.isEmpty {
            guard urgent else { if timer == nil { schedule() }; return }   // the one-shot finishes first
            oneShot = []
        }
        if plan.pose == shown.pose && plan.still == shown.still {
            // A deferred change was taken back: keep the frame.
            dwellUntil = nil
            shown = plan
            schedule()
            return
        }
        if plan.pose == .run, plan.until != nil, !plan.still, shown.pose != .run, let ended = runEndedAt,
           now.timeIntervalSince(ended) < RunnerDirector.burstMerge {
            dwellUntil = nil
            let frames = max(1, timing(.run).durations.count)
            show(plan, now: now, frame: (runFrame + 1) % frames)
            return
        }
        let loops: Set<RunnerPose> = [.walk, .run]
        if plan.pose != .alert, loops.contains(shown.pose), loops.contains(plan.pose), shown.pose != plan.pose,
           now.timeIntervalSince(shownSince) < Self.dwell {
            dwellUntil = shownSince.addingTimeInterval(Self.dwell)
            schedule()
            return
        }
        dwellUntil = nil
        if !paused && shown.pose == .sleep && plan.pose != .sleep && !plan.still && !urgent {
            startOneShot(.yawn)
            return
        }
        show(plan, now: now)
    }

    private func show(_ next: RunnerPlan, now: Date, frame start: Int = 0) {
        let wasSmooth = shown.smooth && shown.fps > 0
        if shown.pose == .run && next.pose != .run {
            runEndedAt = now
            runFrame = frame
        }
        shown = next
        shownSince = now
        frame = start
        holds = 0
        doubling = 0
        breath = 0
        if next.smooth && !wasSmooth { fps = 5 }
        if next.pose == .sleep { sleepSince = sleepSince ?? now } else { sleepSince = nil }
        fx = next.pose == .sleep && (next.still || isDeepSleep) ? Self.largeZ : nil
        lastTick = now
        render(shown.pose, frame, fx)
        schedule()
    }

    private func startOneShot(_ pose: RunnerPose) {
        let timing = timing(pose)
        let count = max(1, timing.durations.count)
        func hold(_ index: Int) -> TimeInterval {
            timing.holdSequence.isEmpty ? (timing.durations.first ?? 0.5) : timing.holdSequence[index % timing.holdSequence.count]
        }
        var steps: [(frame: Int, seconds: TimeInterval)] = [(0, hold(0))]
        for index in 1..<count { steps.append((index, timing.durations[index])) }
        if count > 1 { steps.append((0, hold(1))) }
        oneShot = steps
        shown = RunnerPlan(pose: pose)
        shownSince = clock()
        sleepSince = nil
        frame = steps[0].frame
        fx = nil
        render(pose, frame, fx)
        schedule()
    }

    /// The next frame's delay for what is shown; nil holds the frame.
    private func frameDelay(now: Date) -> TimeInterval? {
        if let step = oneShot.first { return step.seconds }
        if shown.still { return nil }
        let timing = timing(shown.pose)
        let frames = max(1, timing.durations.count)
        if shown.fps > 0 { return frames > 1 ? 1 / max(0.5, shown.smooth ? fps : shown.fps) : nil }
        if shown.pose == .sleep {
            guard frames > 1, !isDeepSleep else { return nil }
            return timing.durations[breath == 1 ? 1 : 0]
        }
        guard frames > 1 else { return nil }
        if frame == 0 {
            if doubling == 2 { return timing.doubleGap ?? Self.doubleBlinkGap }
            return timing.holdSequence.isEmpty ? timing.durations[0] : timing.holdSequence[holds % timing.holdSequence.count]
        }
        return timing.durations[min(frame, frames - 1)]
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        scheduledDelay = nil
        guard !paused else { return }
        let now = clock()
        if isDeepSleep && (frame != 0 || fx != Self.largeZ) {
            frame = 0
            fx = Self.largeZ
            render(shown.pose, frame, fx)
        }
        var delay = frameDelay(now: now)
        if let until = plan.until, until > now { delay = min(delay ?? .greatestFiniteMagnitude, max(0.02, until.timeIntervalSince(now))) }
        if let held = dwellUntil { delay = min(delay ?? .greatestFiniteMagnitude, max(0.02, held.timeIntervalSince(now))) }
        guard let delay else { return }
        scheduledDelay = delay
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.advance() }
        next.tolerance = shown.pose == .sleep && oneShot.isEmpty ? Self.breathTolerance : delay * 0.1
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    /// The timer's action; checks call it directly with an injected clock.
    func advance() {
        timer?.invalidate()
        timer = nil
        let now = clock()
        if let until = plan.until, now >= until {
            replan()
            if timer == nil { schedule() }
            return
        }
        if let held = dwellUntil, now >= held {
            dwellUntil = nil
            transition()
            return
        }
        if !oneShot.isEmpty {
            oneShot.removeFirst()
            guard let step = oneShot.first else {
                show(plan, now: now)
                return
            }
            frame = step.frame
            render(shown.pose, frame, fx)
            schedule()
            return
        }
        if shown.smooth {
            let elapsed = now.timeIntervalSince(lastTick ?? now)
            fps += (shown.fps - fps) * (1 - exp(-elapsed / RunnerDirector.easing))
        }
        lastTick = now
        let timing = timing(shown.pose)
        let frames = max(1, timing.durations.count)
        if shown.fps > 0 {
            frame = (frame + 1) % frames
        } else if shown.pose == .sleep {
            if isDeepSleep { breath = 0 } else { breath = (breath + 1) % 3 }
            frame = breath == 1 ? 1 : 0
            fx = isDeepSleep ? Self.largeZ : [nil, Self.smallZ, Self.largeZ][breath]
        } else if frames == 2 {
            // Blink: hold → closed; every `doubleEvery`-th blink adds open gap → closed again.
            if frame == 0 {
                frame = 1
                if doubling == 0 { blinks += 1 }
                if doubling == 2 { doubling = 3 }
            } else {
                frame = 0
                if doubling == 0, let every = timing.doubleEvery, every > 0, blinks % every == 0 { doubling = 2 }
                else {
                    doubling = 0
                    holds += 1
                }
            }
        } else {
            if frame == 0 { holds += 1 }
            frame = (frame + 1) % frames
        }
        render(shown.pose, frame, fx)
        schedule()
    }
}
