import Foundation

func runSessionPresentationChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ passed: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !passed() { failures.append("Session presentation: \(name)") }
    }
    // 1_000_003 s: the newest 5 s bucket starts at 1_000_000.
    let now = Date(timeIntervalSince1970: 1_000_003)
    func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }
    func reading(_ id: String, _ source: TokenSource = .claude, session: String? = nil, agent: String? = nil,
                 project: String? = nil, subagent: Bool = false, parent: String? = nil, active: Bool = false,
                 state: TokenActivityState = .idle, last: TimeInterval = -60) -> TokenReading {
        var value = TokenReading(source: source, id: id, sessionID: session, agentID: agent, project: project,
                                 isSubagent: subagent, active: active, lastActivity: at(last), activityState: state)
        value.parentSessionID = parent
        return value
    }

    // Display state maps the tracker enum; it never re-derives stale/unfinished from timestamps.
    func state(_ value: TokenReading) -> SessionDisplayState { SessionPresentation.displayState(value, now: now) }
    var output = reading("o", active: true, state: .output)
    output.lastOutputAt = at(-4)
    output.lastOutputDelta = 30
    var future = output
    future.lastOutputAt = at(4)
    var old = output
    old.lastOutputAt = at(-6)
    var tooFuture = output
    tooFuture.lastOutputAt = at(6)
    check(state(reading("s", state: .stale, last: -3_000)) == .waiting, "stale maps to waiting regardless of age")
    check(state(reading("u", state: .unfinished, last: -60)) == .unfinished, "unfinished maps to unfinished")
    check(state(reading("c", state: .complete)) == .complete && state(reading("i", state: .interrupted)) == .interrupted
          && state(reading("n")) == .idle, "inactive complete, interrupted and idle")
    check(state(reading("t", active: true, state: .tool)) == .tool, "open tool turn")
    check(state(output) == .output && state(future) == .output, "output recorded within 5 s, including clock skew")
    check(state(old) == .working && state(tooFuture) == .working, "older output falls back to working")
    check(state(reading("telemetry:codex:model", .codex)) == .measurement, "telemetry rows are measurements")
    check(!SessionDisplayState.waiting.isRunning && SessionDisplayState.waiting.isLive && !SessionDisplayState.unfinished.isLive,
          "waiting is live but not running; unfinished is neither")

    // Grouping is by exact (source, session) identity.
    let claudeParent = reading("claude:p", session: "S1", project: "TokenCat", active: true, state: .working, last: -2)
    let claudeChild = reading("claude:p/agent-b", session: "S1", agent: "b1234567890", project: "TokenCat", subagent: true,
                              active: true, state: .tool, last: -1)
    let codexParent = reading("codex:root", .codex, session: "R1", project: "TokenCat", state: .complete, last: -30)
    let codexChild = reading("codex:child", .codex, session: "C1", agent: "/root/actual_claude_speed", project: "new-chat",
                             subagent: true, parent: "R1", active: true, state: .working, last: -3)
    let orphan = reading("claude:orphan", session: "S9", agent: "a9", project: "Elsewhere", subagent: true,
                         state: .complete, last: -400)
    let crossSource = reading("codex:cross", .codex, session: "S1", agent: "x", subagent: true, state: .complete, last: -500)
    let telemetry = reading("telemetry:claude:S1", session: "S1", state: .complete, last: -10)
    let groups = SessionPresentation.groups([orphan, codexChild, claudeChild, telemetry, crossSource, codexParent, claudeParent], now: now)
    func group(_ id: String) -> SessionGroup? { groups.first { $0.id == id } }
    check(group("claude:p")?.children.map(\.reading.id) == ["claude:p/agent-b"], "Claude agent folds under its session")
    check(group("codex:root")?.children.map(\.reading.id) == ["codex:child"], "Codex child folds by parentSessionID")
    check(group("claude:orphan")?.isOrphan == true && group("codex:cross") != nil, "orphans and other-source children stay top-level")
    check(group("telemetry:claude:S1")?.children.isEmpty == true && groups.count == 5, "telemetry never groups")
    check(group("codex:root")?.state == .working && group("claude:p")?.state == .tool, "group state follows its most active member")
    check(SessionPresentation.agentLabel(codexChild) == "actual_claude_speed" && SessionPresentation.agentLabel(claudeChild) == "b1234567",
          "agent labels")
    check(SessionPresentation.childProjectSuffix(codexChild, parent: codexParent) == "new-chat"
          && SessionPresentation.childProjectSuffix(claudeChild, parent: claudeParent) == nil, "child shows a differing project")
    check(SessionPresentation.shortID(codexParent) == "R1" && SessionPresentation.identity(orphan, children: 0) == "Elsewhere · a9 · 하위",
          "short identity")
    let counts = SessionCounts(groups)
    check(counts.runningGroups == 2 && counts.tool == 1 && counts.working == 1 && counts.runningSubagents == 2
          && counts.phase == .tool && counts.readings == 7 && counts.toolMembers == 1, "counts are per group")
    var outputChild = reading("claude:p/agent-o", session: "S1", agent: "o1", subagent: true, active: true, state: .output, last: -1)
    outputChild.lastOutputAt = at(-1)
    outputChild.lastOutputDelta = 12
    let mixedCounts = SessionCounts(SessionPresentation.groups([claudeParent, claudeChild, outputChild], now: now))
    check(mixedCounts.output == 1 && mixedCounts.tool == 0 && mixedCounts.toolMembers == 1 && mixedCounts.phase == .tool,
          "a tool member stays countable when its group shows output")

    // Stable ordering: running groups by project then session, unaffected by activity time.
    let beta = reading("claude:beta", session: "B", project: "beta", active: true, state: .working, last: -1)
    var alpha = reading("claude:alpha", session: "A", project: "Alpha", active: true, state: .working, last: -50)
    let waiting = reading("claude:wait", session: "W", project: "aaa", state: .stale, last: -200)
    let idle = (0..<8).map { reading("claude:idle\($0)", session: "I\($0)", project: "idle", state: .complete, last: Double(-100 - $0)) }
    var measured = reading("telemetry:codex:model:gpt", .codex, state: .complete, last: -10)
    var measurement = TokenSpeedMeasurement(TelemetryReading(provider: .codex, at: at(-10)))
    measurement.outputTokens = 100
    measurement.requestDurationMs = 1_000
    measured.speedMeasurement = measurement
    var input = [beta, alpha, waiting, measured] + idle
    let first = SessionListModel.make(tokens: input, now: now, expanded: false, flow: .empty)
    alpha.lastActivity = at(0)
    input[1] = alpha
    let second = SessionListModel.make(tokens: input, now: now, expanded: false, flow: .empty)
    let expectedOrder = ["claude:alpha", "claude:beta", "claude:wait", "telemetry:codex:model:gpt", "claude:idle0", "claude:idle1"]
    check(first.blocks.map(\.id) == expectedOrder && second.blocks.map(\.id) == expectedOrder,
          "running, waiting, measured, then recent idle; stable when activity changes")
    check(first.hiddenGroups == 6 && first.hiddenChildren == 0 && first.counts.groups == 12, "collapsed list fills to six rows")
    check(first.contentHeight == 62 * 3 + 28 * 3 + 5, "fixed row heights give a deterministic content height")
    let expanded = SessionListModel.make(tokens: input, now: now, expanded: true, flow: .empty)
    check(expanded.blocks.count == 12 && expanded.hiddenGroups == 0 && expanded.hiddenChildren == 0, "expanded shows every group")
    let family = SessionListModel.make(tokens: [codexParent, codexChild, reading("codex:done", .codex, session: "C2", agent: "/root/done",
                                                subagent: true, parent: "R1", state: .complete, last: -20)],
                                       now: now, expanded: false, flow: .empty)
    check(family.blocks.first?.lead.kind == .idle && family.blocks.first?.children.map(\.id) == ["codex:child"]
          && family.blocks.first?.childCount == 2 && family.hiddenGroups == 0 && family.hiddenChildren == 1,
          "collapsed groups show only live children")
    // A flood of children waiting for a log never pushes a running child out of the collapsed viewport.
    let floodParent = reading("claude:S1", session: "S1", project: "TokenCat", state: .complete, last: -600)
    let flood = (0..<9).map { reading("claude:S1/a\($0)", session: "S1", agent: "a0\($0)xxxxx", subagent: true, state: .stale, last: -100) }
        + [reading("claude:S1/z", session: "S1", agent: "zz-tool", subagent: true, active: true, state: .tool, last: -1)]
    let floodCollapsed = SessionListModel.make(tokens: [floodParent] + flood, now: now, expanded: false, flow: .empty)
    let floodBlock = floodCollapsed.blocks.first
    check(floodBlock?.children.map(\.id) == ["claude:S1/z", "claude:S1/a0", "claude:S1/a1"]
          && floodBlock?.state == .tool && floodBlock?.runningChildren == 1 && floodBlock?.waitingChildren == 9,
          "collapsed children put running first and fill three rows with waiting ones")
    check(floodBlock?.moreCount == 7 && floodBlock?.moreText == "+7 하위 로그 대기"
          && floodCollapsed.hiddenGroups == 0 && floodCollapsed.hiddenChildren == 7
          && floodCollapsed.contentHeight == 28 + 24 * 3 + 24, "cut children are summarised in one row")
    // The cap trims only children waiting for a log; every running child stays visible.
    let busy = (0..<4).map { reading("claude:S1/r\($0)", session: "S1", agent: "r0\($0)xxxxx", subagent: true, active: true,
                                     state: $0 == 3 ? .tool : .working, last: -1) }
    let busyBlock = SessionListModel.make(tokens: [floodParent] + busy + flood.dropLast(), now: now, expanded: false, flow: .empty).blocks.first
    check(busyBlock?.children.map(\.id) == busy.map(\.id) && busyBlock?.moreCount == 9 && busyBlock?.moreText == "+9 하위 로그 대기",
          "running children are never cut by the collapsed cap")
    let floodExpanded = SessionListModel.make(tokens: [floodParent] + flood, now: now, expanded: true, flow: .empty)
    check(floodExpanded.blocks.first?.children.count == 10 && floodExpanded.blocks.first?.moreCount == 0
          && floodExpanded.blocks.first?.children.first?.id == "claude:S1/z", "expanded shows every child, running first")

    // Wall-clock buckets: the newest starts at floor(now / 5) * 5, future records clamp, old records drop.
    var flowReading = reading("codex:flow", .codex)
    flowReading.recentOutputs = [
        TokenOutputEvent(at: Date(timeIntervalSince1970: 1_000_000.5), tokens: 10),
        TokenOutputEvent(at: Date(timeIntervalSince1970: 999_999.9), tokens: 20),
        TokenOutputEvent(at: Date(timeIntervalSince1970: 1_000_007), tokens: 40),
        TokenOutputEvent(at: Date(timeIntervalSince1970: 1_000_009), tokens: 80),
        TokenOutputEvent(at: Date(timeIntervalSince1970: 999_705), tokens: 160),
        TokenOutputEvent(at: Date(timeIntervalSince1970: 999_700), tokens: 320)
    ]
    var claudeFlow = reading("claude:flow")
    claudeFlow.recentOutputs = [TokenOutputEvent(at: Date(timeIntervalSince1970: 999_990), tokens: 5)]
    var telemetryFlow = reading("telemetry:x")
    telemetryFlow.recentOutputs = [TokenOutputEvent(at: now, tokens: 1_000)]
    let flow = FlowSeries.make([flowReading, claudeFlow, telemetryFlow], now: now)
    check(flow.newest == Date(timeIntervalSince1970: 1_000_000) && flow.hero.count == 60, "newest bucket is wall-clock aligned")
    check(flow.hero[59] == 50 && flow.hero[58] == 20 && flow.hero[0] == 160 && flow.hero[57] == 5 && flow.total == 235,
          "records land in aligned buckets; >5 s future and out-of-window records drop")
    check(flow.fresh[59] && flow.fresh[58] && !flow.fresh[57], "fresh marks buckets holding a record from the last 5 s")
    check(flow.byProvider[.codex] == 230 && flow.byProvider[.claude] == 5 && flow.last?.tokens == 40
          && flow.last?.at == Date(timeIntervalSince1970: 1_000_007), "provider totals and last record")
    check(flow.rows["codex:flow"]?.buckets.count == 24 && flow.rows["codex:flow"]?.buckets[23] == 50
          && flow.rows["telemetry:x"] == nil, "rows keep 2 minutes per reading; telemetry contributes nothing")
    let shifted = FlowSeries.make([flowReading], now: Date(timeIntervalSince1970: 1_000_004.9))
    let next = FlowSeries.make([flowReading], now: Date(timeIntervalSince1970: 1_000_005))
    check(shifted.newest == flow.newest && shifted.hero[58] == 20 && shifted.hero[0] == 160
          && next.hero[57] == 20 && next.hero[58] == 10, "buckets stay put within an interval and shift on the boundary")
    check(niceMax(200) == 200 && niceMax(201) == 500 && niceMax(786) == 1_000 && niceMax(1_001) == 2_000 && niceMax(5_000) == 5_000,
          "nice scale rounds to 1/2/5 × 10ⁿ")

    // Formats and honest speed.
    check(Format.tokens(786) == "786" && Format.tokens(12_480) == "12,480" && Format.tokens(123_400) == "123.4k"
          && Format.tokens(1_234_567) == "1.23M" && Format.tokens(999_960) == "1.00M", "token format")
    check(Format.compactTokens(786) == "786" && Format.compactTokens(8_100) == "8.1k" && Format.compactTokens(1_000) == "1k"
          && Format.compactTokens(1_200_000) == "1.2M", "compact token format")
    check(Format.age(at(-3), now: now) == "3초 전" && Format.age(at(-200), now: now) == "3분 전" && Format.age(at(5), now: now) == "0초 전",
          "ages use the model clock")
    let unknown = SessionPresentation.speed(claudeParent, now: now)
    check(unknown.value == "—" && !unknown.known, "unknown speed is a dash")
    var previous = reading("claude:prev")
    previous.model = "claude-opus-5-5"
    var previousMeasurement = TokenSpeedMeasurement(TelemetryReading(provider: .claude, at: at(-30)))
    previousMeasurement.model = "claude-haiku"
    previousMeasurement.outputTokens = 441
    previousMeasurement.requestDurationMs = 10_000
    previous.speedMeasurement = previousMeasurement
    let previousSlot = SessionPresentation.speed(previous, now: now)
    check(previousSlot.prefix == "이전" && previousSlot.value == "44.1" && !previousSlot.recent, "previous-model measurement is labelled")
    previous.model = "claude-haiku"
    let currentSlot = SessionPresentation.speed(previous, now: now)
    check(currentSlot.prefix == nil && currentSlot.recent && currentSlot.kind == "요청 tok/s", "current-model measurement")

    print("Session presentation checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
