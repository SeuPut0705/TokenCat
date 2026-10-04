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
            return "고양이 움직임은 상태만 나타내며 속도가 아닙니다. 진행 중이면 걷고, 출력이 기록되면 잠깐 달리고, 입력이 필요하면 멈춰서 돌아봅니다. 활동이 없으면 앉아 있다가 10분 뒤 잠듭니다."
        case .cpu: return "CPU 사용률이 높을수록 빨리 달립니다. 4% 아래에서는 앉아 쉽니다."
        case .measured: return "최근 5초 안에 받은 실측 속도에만 반응합니다. 실측이 없으면 앉아서 기다립니다."
        case .still: return "고양이가 앉은 자세로 멈춰 있습니다."
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

/// fps 0 is a still pose; `until` asks for a re-plan (end of an output burst).
struct RunnerPlan: Equatable {
    var pose: RunnerPose
    var fps: Double = 0
    /// Still poses show their second frame briefly every `blinkEvery` seconds when the art has one.
    var blinkEvery: TimeInterval? = nil
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

/// Fixed cadences per state; never scaled by token counts or session counts.
struct RunnerDirector {
    static let walkFPS = 8.0, runFPS = 14.0, minimumFPS = 6.0, maximumFPS = 14.0
    static let burst: TimeInterval = 1.2, sleepAfter: TimeInterval = 600, easing: TimeInterval = 1.5
    private(set) var burstUntil: Date?
    private var burstEventAt: Date?
    private var cpuResting = true
    private var lastLiveAt: Date?

    static func fps(cpu: Double) -> Double { minimumFPS + (min(100, max(5, cpu)) - 5) / 95 * (maximumFPS - minimumFPS) }
    static func fps(rate: Double) -> Double { minimumFPS + min(200, max(0, rate)) / 200 * (maximumFPS - minimumFPS) }

    /// Called once per publish. A burst is keyed by the output event's own time, so refreshes never retrigger it.
    mutating func observe(_ activity: RunnerActivity, now: Date) {
        if activity.input || activity.running || activity.waiting { lastLiveAt = now }
        if let at = activity.newestOutputAt, at > (burstEventAt ?? .distantPast), abs(now.timeIntervalSince(at)) <= 5 {
            burstEventAt = at
            burstUntil = now.addingTimeInterval(Self.burst)
        }
        if let cpu = activity.cpu {
            if cpu < 4 { cpuResting = true } else if cpu > 6 { cpuResting = false }
        }
    }

    func plan(_ motion: RunnerMotion, activity: RunnerActivity, now: Date, reduceMotion: Bool) -> RunnerPlan {
        let sit = RunnerPlan(pose: .sit, blinkEvery: 5)
        var plan: RunnerPlan
        switch motion {
        case .still:
            plan = RunnerPlan(pose: .sit)
        case .cpu:
            if cpuResting || activity.cpu == nil { plan = sit } else {
                plan = RunnerPlan(pose: .run, fps: Self.fps(cpu: activity.cpu ?? 0), smooth: true)
            }
        case .measured:
            plan = activity.measuredRate.map { RunnerPlan(pose: .run, fps: Self.fps(rate: $0), smooth: true) } ?? sit
        case .activity:
            if activity.input { plan = RunnerPlan(pose: .alert, blinkEvery: 2) }
            else if let until = burstUntil, now < until { plan = RunnerPlan(pose: .run, fps: Self.runFPS, until: until) }
            else if activity.running { plan = RunnerPlan(pose: .walk, fps: Self.walkFPS) }
            else if activity.waiting { plan = sit }
            else {
                let quiet = [lastLiveAt, activity.newestActivityAt].compactMap { $0 }.max()
                // Sleep is the most common state, so it is a still pose: no timer runs at all.
                plan = quiet.map { now.timeIntervalSince($0) < Self.sleepAfter } == true ? sit : RunnerPlan(pose: .sleep)
            }
        }
        if reduceMotion {
            plan.fps = 0
            plan.blinkEvery = nil
            plan.smooth = false
        }
        return plan
    }
}

/// One-shot timer to the next frame only; nothing runs while the pose is still or the cat cannot be seen.
final class RunnerAnimator {
    var render: (RunnerPose, Int) -> Void = { _, _ in }
    var replan: () -> Void = {}
    private(set) var plan = RunnerPlan(pose: .sit)
    private(set) var frame = 0
    private var fps = RunnerDirector.minimumFPS
    private var lastTick: Date?
    private var timer: Timer?
    var paused = false { didSet { if paused != oldValue { schedule() } } }
    var isTimerRunning: Bool { timer != nil }

    func apply(_ next: RunnerPlan) {
        guard next != plan else { if timer == nil { schedule() }; return }
        let previous = plan
        plan = next
        if next.pose == previous.pose && next.smooth && previous.smooth && next.until == previous.until && next.fps > 0 && previous.fps > 0 {
            return // Only the target cadence moved; the running timer eases toward it.
        }
        if next.pose != previous.pose || next.fps == 0 { frame = 0 }
        if next.smooth && !(previous.smooth && previous.fps > 0) { fps = RunnerDirector.minimumFPS }
        lastTick = Date()
        render(plan.pose, frame)
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !paused else { return }
        let frames = Runner.frames(plan.pose)
        var delay: TimeInterval?
        if plan.fps > 0 && frames > 1 { delay = 1 / max(0.5, plan.smooth ? fps : plan.fps) }
        else if let every = plan.blinkEvery, frames > 1 { delay = frame == 0 ? every : 0.15 }
        if let until = plan.until, until > Date() { delay = min(delay ?? .greatestFiniteMagnitude, max(0.02, until.timeIntervalSinceNow)) }
        guard let delay else { return }
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tick() }
        next.tolerance = delay * 0.1
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        timer = nil
        let now = Date()
        if let until = plan.until, now >= until {
            replan()
            if timer == nil { schedule() }
            return
        }
        if plan.smooth {
            let elapsed = now.timeIntervalSince(lastTick ?? now)
            fps += (plan.fps - fps) * (1 - exp(-elapsed / RunnerDirector.easing))
        }
        lastTick = now
        let frames = max(1, Runner.frames(plan.pose))
        frame = plan.fps > 0 ? (frame + 1) % frames : (frame == 0 ? min(1, frames - 1) : 0)
        render(plan.pose, frame)
        schedule()
    }
}
