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
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func reading(_ id: String, _ source: TokenSource = .claude, session: String? = nil, agent: String? = nil,
                 project: String? = nil, subagent: Bool = false, parent: String? = nil, active: Bool = false,
                 state: TokenActivityState = .idle, last: TimeInterval = -60) -> TokenReading {
        var value = TokenReading(source: source, id: id, sessionID: session, agentID: agent, project: project,
                                 isSubagent: subagent, active: active, lastActivity: at(last), activityState: state)
        value.parentSessionID = parent
        return value
    }
    func make(_ tokens: [TokenReading], expanded: Bool = false, flow: FlowSeries = .empty) -> SessionListModel {
        SessionListModel.make(tokens: tokens, now: now, expanded: expanded, flow: flow, calendar: utc)
    }

    // Display state maps the tracker enum; stale is "로그 대기" only for 10 minutes after the newest record.
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
    var loggedLater = reading("s3", state: .stale, last: -900)
    loggedLater.lastLogAt = at(-300)
    check(state(reading("s", state: .stale, last: -540)) == .waiting && state(reading("s2", state: .stale, last: -1_500)) == .waiting
          && state(loggedLater) == .waiting, "stale maps to waiting; the tracker decides when it becomes unfinished")
    check(state(reading("u", state: .unfinished, last: -60)) == .unfinished, "unfinished maps to unfinished")
    check(state(reading("c", state: .complete)) == .complete && state(reading("i", state: .interrupted)) == .interrupted
          && state(reading("n")) == .idle && SessionDisplayState.idle.title == "최근 활동 없음", "inactive complete, interrupted and idle")
    check(state(reading("t", active: true, state: .tool)) == .tool, "open tool turn")
    check(state(output) == .output && state(future) == .output, "output recorded within 5 s, including clock skew")
    check(state(old) == .working && state(tooFuture) == .working, "older output falls back to working")
    check(state(reading("telemetry:codex:model", .codex)) == .measurement, "telemetry rows are measurements")
    check(!SessionDisplayState.waiting.isRunning && SessionDisplayState.waiting.isLive && !SessionDisplayState.unfinished.isLive
          && SessionDisplayState.input.isRunning && SessionDisplayState.retrying.isRunning,
          "waiting is live but not running; unfinished is neither; input and retry are running")

    // Input: a pending question or plan approval, shown even when the turn is no longer marked active.
    var question = reading("claude:q", session: "Q", project: "zeta", state: .input, last: -192)
    question.toolCategory = .question
    question.toolName = "AskUserQuestion"
    var plan = question
    plan.toolName = "ExitPlanMode"
    check(state(question) == .input && SessionPresentation.inputTitle(question) == "질문 답변 대기"
          && SessionPresentation.inputTitle(plan) == "계획 승인 대기", "input state and its kind")
    check(SessionDisplayState.input.color != SessionDisplayState.waiting.color && SessionDisplayState.input.title == "입력 필요",
          "input has its own colour and title")

    // API retry: counts and delays only, for 10 minutes after the record.
    var retrying = reading("claude:r", session: "R", project: "beta", active: true, state: .working, last: -3)
    retrying.retry = TokenRetryState(attempt: 2, maxAttempts: 10, retryAt: at(4), networkDown: false, at: at(-3))
    var oldRetry = retrying
    oldRetry.retry?.at = at(-700)
    check(state(retrying) == .retrying && state(oldRetry) == .working, "a recent retry shows; an old one falls back")
    check(SessionPresentation.retryText(retrying.retry!, now: now) == "재시도 2/10 · 4초 후"
          && SessionPresentation.retryText(TokenRetryState(attempt: 7, maxAttempts: 10, retryAt: at(20), networkDown: true, at: now), now: now)
            == "재시도 7/10 · 네트워크 끊김"
          && SessionPresentation.retryText(TokenRetryState(attempt: 3, maxAttempts: nil, retryAt: nil, networkDown: false, at: now), now: now)
            == "재시도 3회째 · 재요청 중", "retry copy")

    // Tool categories replace the generic chip text; raw names never appear in it.
    var command = reading("codex:cmd", .codex, session: "C", project: "alpha", active: true, state: .tool, last: -40)
    command.toolCategory = .command
    command.toolName = "exec"
    check(SessionPresentation.stateTitle(.tool, command) == "명령 실행"
          && SessionPresentation.stateTitle(.tool, reading("x", active: true, state: .tool)) == "도구 실행"
          && SessionPresentation.toolTitle(.agent) == "하위 에이전트 대기" && SessionPresentation.toolTitle(.mcp) == "MCP 도구",
          "tool category titles")

    // Grouping is by exact (source, session) identity.
    let claudeParent = reading("claude:p", session: "S1", project: "TokenCat", active: true, state: .working, last: -2)
    let claudeChild = reading("claude:p/agent-b", session: "S1", agent: "b1234567890", project: "TokenCat", subagent: true,
                              active: true, state: .tool, last: -1)
    let codexParent = reading("codex:root", .codex, session: "R1", project: "TokenCat", state: .complete, last: -30)
    let codexChild = reading("codex:child", .codex, session: "C1", agent: "/root/sample_runner", project: "sample-chat",
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
    check(SessionPresentation.agentLabel(codexChild) == "sample_runner" && SessionPresentation.agentLabel(claudeChild) == "b1234567",
          "agent labels")
    check(SessionPresentation.childProjectSuffix(codexChild, parent: codexParent) == "sample-chat"
          && SessionPresentation.childProjectSuffix(claudeChild, parent: claudeParent) == nil, "child shows a differing project")
    check(SessionPresentation.shortID(codexParent) == "R1" && SessionPresentation.identity(orphan, children: 0) == "Elsewhere · a9 · 하위",
          "short identity")
    var roleChild = claudeChild
    roleChild.agentRole = "Explore"
    var reviewChild = codexChild
    reviewChild.agentRole = "guardian"
    check(SessionPresentation.childTitle(roleChild) == ("Explore", "b1234567") && SessionPresentation.childTitle(claudeChild) == ("b1234567", nil)
          && SessionPresentation.childTitle(reviewChild) == ("sample_runner", "자동 검토"), "subagent role labels keep the ID")
    var workflowChild = claudeChild
    workflowChild.agentID = "a1111111e1"
    workflowChild.agentRole = "workflow-subagent"
    var generalChild = workflowChild
    generalChild.agentRole = " general-purpose "
    check(SessionPresentation.childTitle(workflowChild) == ("a1111111", nil) && SessionPresentation.childTitle(generalChild) == ("a1111111", nil)
          && SessionPresentation.roleLabel(workflowChild.agentRole) == "workflow-subagent"
          && SessionPresentation.roleLabel(reviewChild.agentRole) == "자동 검토" && SessionPresentation.roleLabel("  ") == nil,
          "shared roles leave the ID as the title; help keeps the role")
    let counts = SessionCounts(groups)
    check(counts.runningGroups == 2 && counts.tool == 1 && counts.working == 1 && counts.runningSubagents == 2
          && counts.phase == .tool && counts.readings == 7 && counts.toolMembers == 1 && counts.toolCategories[.other] == 1,
          "counts are per group")
    var outputChild = reading("claude:p/agent-o", session: "S1", agent: "o1", subagent: true, active: true, state: .output, last: -1)
    outputChild.lastOutputAt = at(-1)
    outputChild.lastOutputDelta = 12
    let mixedCounts = SessionCounts(SessionPresentation.groups([claudeParent, claudeChild, outputChild], now: now))
    check(mixedCounts.output == 1 && mixedCounts.tool == 0 && mixedCounts.toolMembers == 1 && mixedCounts.phase == .tool,
          "a tool member stays countable when its group shows output")
    var inputChild = reading("claude:p/agent-q", session: "S1", agent: "q1", subagent: true, state: .input, last: -5)
    inputChild.toolCategory = .question
    let inputCounts = SessionCounts(SessionPresentation.groups([claudeParent, claudeChild, inputChild, retrying], now: now))
    check(inputCounts.input == 1 && inputCounts.tool == 0 && inputCounts.retrying == 1 && inputCounts.runningGroups == 2
          && inputCounts.phase == .input && inputCounts.retry?.attempt == 2, "input outranks tool for the group and the menu-bar phase")
    check(SessionPresentation.childGroupText(.input, count: 1) == "하위 1개 입력 필요"
          && SessionPresentation.childGroupText(.retrying, count: 2) == "하위 2개 API 재시도"
          && SessionPresentation.childGroupText(.tool, count: 3) == "하위 3개 진행 중"
          && SessionPresentation.childGroupText(.waiting, count: 4) == "하위 4개 로그 대기", "an idle lead names its children's state")
    check(SessionCounts(SessionPresentation.groups([retrying], now: now)).phase == .working, "a retry alone keeps the neutral phase")

    // The flow-card capsule: input > retry > tool category > progress > waiting.
    var noticeCounts = SessionCounts(SessionPresentation.groups([command, reading("claude:w", session: "W", state: .stale, last: -200)], now: now))
    check(SessionPresentation.flowNotice(counts: noticeCounts, last: at(-40), now: now) == "명령 실행 중 · 응답이 끝나면 토큰이 기록됩니다"
          && SessionPresentation.flowNotice(counts: noticeCounts, last: at(-10), now: now) == nil, "tool category notice after 30 s")
    noticeCounts.tool = 0
    check(SessionPresentation.flowNotice(counts: noticeCounts, last: nil, now: now) == "로그 대기 · 3분 동안 새 기록 없음", "waiting notice")
    let urgent = SessionCounts(SessionPresentation.groups([command, retrying, question], now: now))
    let retryOnly = SessionCounts(SessionPresentation.groups([command, retrying], now: now))
    check(SessionPresentation.flowNotice(counts: urgent, last: at(-2), now: now) == "입력 필요 · 답변하면 계속됩니다"
          && SessionPresentation.flowNotice(counts: retryOnly, last: at(-2), now: now) == "API 재시도 2/10 · 4초 후",
          "input and retry notices show even right after a record")
    var plan2 = plan
    plan2.id = "claude:q2"
    plan2.sessionID = "Q2"
    var question3 = question
    question3.id = "claude:q3"
    question3.sessionID = "Q3"
    let plans = SessionCounts(SessionPresentation.groups([plan, plan2, command], now: now))
    let mixedInput = SessionCounts(SessionPresentation.groups([plan, question3], now: now))
    check(plans.inputPlansOnly && SessionPresentation.flowNotice(counts: plans, last: nil, now: now) == "계획 승인 대기 2개 · 승인하면 계속됩니다"
          && !mixedInput.inputPlansOnly && SessionPresentation.flowNotice(counts: mixedInput, last: nil, now: now) == "입력 필요 2개 · 답변하면 계속됩니다",
          "plan approvals say 승인; a mix keeps the general copy")

    // Stable ordering: input first, then running groups by project and session, unaffected by activity time.
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
    let first = make(input)
    alpha.lastActivity = at(0)
    input[1] = alpha
    let second = make(input)
    let expectedOrder = ["claude:alpha", "claude:beta", "claude:wait", "telemetry:codex:model:gpt", "claude:idle0", "claude:idle1"]
    check(first.blocks.map(\.id) == expectedOrder && second.blocks.map(\.id) == expectedOrder,
          "running, waiting, measured, then recent idle; stable when activity changes")
    check(make(input + [question]).blocks.first?.id == "claude:q", "a turn waiting for input goes first")
    check(first.hiddenGroups == 6 && first.hiddenChildren == 0 && first.counts.groups == 12, "collapsed list fills to six rows")
    check(first.contentHeight == 44 * 3 + 28 * 3 + 5, "quiet live rows fold to 44pt; heights stay deterministic")
    var flowing = alpha
    flowing.recentOutputs = [TokenOutputEvent(at: at(-20), tokens: 40)]
    let withBars = make([flowing], flow: FlowSeries.make([flowing], now: now))
    var withContext = beta
    withContext.context = TokenContextUsage(usedTokens: 1_000, windowTokens: nil, recordedAt: at(-1))
    check(withBars.blocks.first?.lead.height == 62 && make([withContext]).blocks.first?.lead.height == 62,
          "bars or context keep the third line")
    let expanded = make(input, expanded: true)
    check(expanded.blocks.count == 12 && expanded.hiddenGroups == 0 && expanded.hiddenChildren == 0, "expanded shows every group")
    let family = make([codexParent, codexChild, reading("codex:done", .codex, session: "C2", agent: "/root/done",
                                                         subagent: true, parent: "R1", state: .complete, last: -20)])
    check(family.blocks.first?.lead.kind == .idle && family.blocks.first?.children.map(\.id) == ["codex:child"]
          && family.blocks.first?.childCount == 2 && family.hiddenGroups == 0 && family.hiddenChildren == 1,
          "collapsed groups show only live children")
    // While a child runs, children waiting for a log stay in the summary row only.
    let floodParent = reading("claude:S1", session: "S1", project: "TokenCat", state: .complete, last: -600)
    let flood = (0..<9).map { reading("claude:S1/a\($0)", session: "S1", agent: "a0\($0)xxxxx", subagent: true, state: .stale, last: -100) }
        + [reading("claude:S1/z", session: "S1", agent: "zz-tool", subagent: true, active: true, state: .tool, last: -1)]
    let floodCollapsed = make([floodParent] + flood)
    let floodBlock = floodCollapsed.blocks.first
    check(floodBlock?.children.map(\.id) == ["claude:S1/z"] && floodBlock?.state == .tool
          && floodBlock?.runningChildren == 1 && floodBlock?.waitingChildren == 9,
          "waiting children take no slot while a child runs")
    check(floodBlock?.moreCount == 9 && floodBlock?.moreText == "+9 하위 로그 대기 · 마지막 1분 전"
          && floodCollapsed.hiddenGroups == 0 && floodCollapsed.hiddenChildren == 9
          && floodCollapsed.contentHeight == 28 + 24 + 24, "cut children are summarised with their newest record")
    let quietBlock = make([floodParent] + flood.dropLast()).blocks.first
    check(quietBlock?.children.map(\.id) == ["claude:S1/a0", "claude:S1/a1", "claude:S1/a2"] && quietBlock?.moreCount == 6,
          "with nothing running, up to three waiting children show")
    let busy = (0..<4).map { reading("claude:S1/r\($0)", session: "S1", agent: "r0\($0)xxxxx", subagent: true, active: true,
                                     state: $0 == 3 ? .tool : .working, last: -1) }
    let busyBlock = make([floodParent] + busy + flood.dropLast()).blocks.first
    check(busyBlock?.children.map(\.id) == busy.map(\.id) && busyBlock?.moreCount == 9,
          "running children are never cut by the collapsed cap")
    let floodExpanded = make([floodParent] + flood, expanded: true)
    check(floodExpanded.blocks.first?.children.count == 10 && floodExpanded.blocks.first?.moreCount == 0
          && floodExpanded.blocks.first?.children.first?.id == "claude:S1/z", "expanded shows every child, running first")

    // Expanded date captions come from the model clock; "이전" folds behind one row.
    let day: TimeInterval = 86_400
    // 1_000_003 s is Monday 1970-01-12 13:46:43 UTC.
    check(SessionPresentation.daySection(at(-600), now: now, calendar: utc) == "오늘"
          && SessionPresentation.daySection(at(-day), now: now, calendar: utc) == "어제"
          && SessionPresentation.daySection(at(-3 * day), now: now, calendar: utc) == "이전"
          && SessionPresentation.daySection(at(30), now: now, calendar: utc) == "오늘", "day sections")
    var weekCalendar = utc
    weekCalendar.firstWeekday = 2
    let thursday = Date(timeIntervalSince1970: 1_000_003 + 3 * day)
    check(SessionPresentation.daySection(thursday.addingTimeInterval(-3 * day), now: thursday, calendar: weekCalendar) == "이번 주"
          && SessionPresentation.daySection(thursday.addingTimeInterval(-4 * day), now: thursday, calendar: weekCalendar) == "이전",
          "this week follows the calendar week")
    let dated = [reading("claude:d0", session: "D0", state: .complete, last: -600), reading("claude:d1", session: "D1", state: .complete, last: -day),
                 reading("claude:d2", session: "D2", state: .complete, last: -5 * day), reading("claude:d3", session: "D3", state: .complete, last: -9 * day)]
    let datedList = make([beta] + dated, expanded: true)
    let datedIDs = ["claude:beta", "caption:오늘", "claude:d0", "caption:어제", "claude:d1", "divider:older", "older"]
    let foldedHeight: CGFloat = 44 + 32 + 56 + 1 + 24, openHeight: CGFloat = 44 + 48 + 112 + 1
    check(datedList.blocks.map(\.caption) == [nil, "오늘", "어제", "이전", nil] && datedList.olderCount == 2
          && datedList.entries(showOlder: false).map(\.id) == datedIDs
          && datedList.contentHeight == foldedHeight && datedList.olderContentHeight == openHeight,
          "captions, folded older section and both heights")

    // The viewport cut lands at least 12pt inside a row and hides at least 6pt of it.
    let long = make((0..<12).map { reading("claude:L\($0)", session: "L\($0)", active: true, state: .working, last: -1) })
    let cut = long.viewport(showOlder: false)
    let tops = (0..<12).map { CGFloat($0) * 45 }
    check(long.contentHeight > SessionListModel.maxViewport && cut <= SessionListModel.maxViewport
          && tops.contains { cut - $0 >= 12 && $0 + 44 - cut >= 6 }, "viewport snaps inside a row")
    check(make([beta]).viewport(showOlder: false) == 44, "short lists are not snapped")

    // Context: Codex percentage from the logged window, Claude absolute only.
    var codexContext = command
    codexContext.context = TokenContextUsage(usedTokens: 158_204, windowTokens: 258_400, recordedAt: at(-45))
    var nearlyFull = codexContext
    nearlyFull.context?.usedTokens = 235_100
    var claudeContext = question
    claudeContext.context = TokenContextUsage(usedTokens: 182_331, windowTokens: nil, recordedAt: at(-120), compactedAt: at(-300))
    let codexSlot = SessionPresentation.context(codexContext, now: now)
    let claudeSlot = SessionPresentation.context(claudeContext, now: now)
    check(codexSlot?.text == "컨텍스트 61% 사용" && codexSlot?.spoken == "컨텍스트 61퍼센트 사용" && codexSlot?.warning == false && SessionPresentation.context(nearlyFull, now: now)?.warning == true
          && claudeSlot?.text == "컨텍스트 182k" && claudeSlot?.fraction == nil && claudeSlot?.help.contains("압축 완료 기록 5분 전") == true
          && SessionPresentation.context(command, now: now) == nil, "context slots never infer a window")

    // Codex usage limit: newest reset window, highest value inside it, always with its record age.
    var limited = command
    limited.rateLimit = TokenRateLimit(usedPercent: 28, windowMinutes: 10_080, resetsAt: at(5 * day + 11 * 3_600 + 30), recordedAt: at(-720))
    var lower = limited
    lower.rateLimit?.usedPercent = 21
    lower.rateLimit?.recordedAt = at(-60)
    var replayed = limited
    replayed.rateLimit = TokenRateLimit(usedPercent: 95, windowMinutes: 10_080, resetsAt: at(-day), recordedAt: at(-5))
    var claudeLimit = question
    claudeLimit.rateLimit = TokenRateLimit(usedPercent: 99, windowMinutes: 300, resetsAt: at(10 * day), recordedAt: now)
    let usage = SessionPresentation.usageLimit([limited, lower, replayed, claudeLimit])
    check(usage?.usedPercent == 28 && usage?.recordedAt == at(-60) && usage?.title == "Codex 주간 한도" && usage?.value(now: now) == "28% 사용"
          && usage?.detail(now: now) == "5일 11시간 후 초기화 · 1분 전 기록 기준", "usage limit is replay-proof and never Claude")
    let expired = UsageLimitSummary(usedPercent: 64, windowMinutes: 300, resetsAt: at(-10), recordedAt: at(-7_000))
    check(expired.value(now: now) == "—" && expired.detail(now: now) == "초기화됨 · 다음 Codex 기록 대기" && expired.isOld(now: now)
          && SessionPresentation.usageLimit([question]) == nil && SessionPresentation.windowLabel(300) == "5시간"
          && SessionPresentation.windowLabel(2_880) == "2일" && SessionPresentation.countdown(to: at(42 * 60), now: now) == "42분",
          "expired windows, labels and countdowns")
    check(!UsageLimitSummary.help.contains("예상") && !(usage?.detail(now: now).contains("소진") ?? true), "no forecast in limit copy")
    // Old Codex logs carry no reset time: different weeks cannot be told apart, so only the newest record counts.
    var undatedOld = command
    undatedOld.rateLimit = TokenRateLimit(usedPercent: 97, windowMinutes: 10_080, resetsAt: nil, recordedAt: at(-3 * day))
    var undatedNew = command
    undatedNew.rateLimit = TokenRateLimit(usedPercent: 12, windowMinutes: 10_080, resetsAt: nil, recordedAt: at(-600))
    let undated = SessionPresentation.usageLimit([undatedOld, undatedNew])
    check(undated?.usedPercent == 12 && undated?.recordedAt == at(-600) && undated?.resetsAt == nil
          && undated?.detail(now: now) == "10분 전 기록 기준" && undated?.isShown(now: now) == true,
          "without reset times the newest record wins, not the highest")
    let staleUndated = UsageLimitSummary(usedPercent: 40, windowMinutes: 300, resetsAt: nil, recordedAt: at(-6 * 3_600))
    check(staleUndated.expired(now: now) && staleUndated.value(now: now) == "—" && staleUndated.isShown(now: now)
          && !UsageLimitSummary(usedPercent: 40, windowMinutes: 300, resetsAt: nil, recordedAt: at(-2 * day)).isShown(now: now),
          "an undated record expires one window after it was written")
    // A reset window says "초기화됨" for one day, then the card goes away.
    check(expired.isShown(now: now) && !UsageLimitSummary(usedPercent: 64, windowMinutes: 300, resetsAt: at(-day - 1), recordedAt: at(-2 * day)).isShown(now: now)
          && usage?.isShown(now: now) == true, "expired windows hide after a day")

    // Effort, last turn and help ages.
    var effort = command
    effort.effort = "XHigh"
    check(SessionPresentation.effortLabel(effort) == "xhigh" && SessionPresentation.effortLabel(command) == nil, "effort is raw lowercase")
    var finished = reading("claude:f", state: .complete)
    finished.lastOutputTokens = 7_493
    let partial = finished
    finished.lastTurnDurationSeconds = 252
    check(SessionPresentation.lastTurnSummary(finished) == "마지막 완료 턴 출력 7,493 tok · 소요 4:12"
          && SessionPresentation.lastTurnSummary(partial) == "마지막 출력 기록 7,493 tok"
          && SessionPresentation.lastTurnSummary(finished)?.contains("/s") == false, "turn output and duration are never divided")
    check(SessionPresentation.helpAge(at(-45), now: now) == "1분 이내" && SessionPresentation.helpAge(at(-200), now: now) == "3분 전"
          && SessionPresentation.helpAge(nil, now: now) == "기록 없음", "help ages are minute-granular")

    // Footer telemetry notice by cause.
    let port = SessionPresentation.telemetryNotice(ready: false, status: "실측 꺼짐 · 다른 앱이 포트 16493 사용 중", note: nil, restart: [])
    let conflict = SessionPresentation.telemetryNotice(ready: true, status: "실측 수신 대기",
                                                       note: "실측 연결: Codex otel 키가 중복되거나 여러 줄 형식이어서 변경하지 않았습니다.",
                                                       failure: .conflict, restart: [.claude])
    let failed = SessionPresentation.telemetryNotice(ready: true, status: "실측 수신 대기", note: "설정 저장 중 일부 파일이 변경됐습니다.", failure: .writeFailed(restored: false), restart: [])
    let restart = SessionPresentation.telemetryNotice(ready: true, status: "실측 연결됨", note: nil, restart: [.claude, .codex])
    let otherTokenCat = SessionPresentation.telemetryNotice(ready: false, status: "실측 꺼짐 · 다른 TokenCat이 수집 중", note: nil, restart: [])
    let otherApp = SessionPresentation.telemetryNotice(ready: false, status: "실측 꺼짐 · 다른 앱이 포트 16493 사용 중", note: nil, restart: [])
    let broken = SessionPresentation.telemetryNotice(ready: false, status: "실측 꺼짐 · 수집기를 시작하지 못함", note: nil, restart: [.claude])
    let expiredNotice = SessionPresentation.telemetryNotice(ready: true, status: "실측 수신 대기", note: nil, restart: [.claude], expired: [.codex])
    check(otherTokenCat?.kind == .busy && otherTokenCat?.text == "실측 꺼짐 · 다른 TokenCat" && otherApp?.kind == .portBusy
          && broken?.kind == .collector && broken?.text == "실측 꺼짐 · 수집기 오류" && broken?.help.hasPrefix("실측 꺼짐 · 수집기를 시작하지 못함") == true
          && [otherTokenCat, otherApp, broken].allSatisfy { $0?.collectorDown == true } && conflict?.collectorDown == false,
          "collector states keep their cause")
    check(expiredNotice?.kind == .expired && expiredNotice?.text == "실측 미수신 · 확인 필요" && expiredNotice?.isProblem == true
          && expiredNotice?.help.hasPrefix("Codex: 이 버전에서 실측을 받지 못했습니다") == true, "a day without a receipt asks for a check")
    check(port?.kind == .portBusy && port?.text == "실측 꺼짐 · 포트 사용 중" && conflict?.text == "실측 꺼짐 · 설정 충돌"
          && failed?.kind == .failed && restart?.text == "재시작 후 실측 표시" && restart?.isProblem == false
          && restart?.help.hasPrefix("Codex · Claude Code를 새로 실행하면") == true, "telemetry notice causes")
    check(SessionPresentation.telemetryNotice(ready: true, status: "실측 수신 중", note: nil, restart: []) == nil
          && SessionPresentation.telemetryNotice(ready: false, status: "실측 준비 중", note: nil, restart: []) == nil
          && SessionPresentation.telemetryNotice(ready: false, status: "실측 연결 중지됨", note: nil, restart: [])?.kind == .off
          && [port, conflict, failed, restart, otherTokenCat, broken, expiredNotice].allSatisfy { ($0?.text.filter { $0 != " " }.count ?? 0) <= 15 },
          "no notice while healthy; copy stays short")
    let restartSlot = SessionPresentation.speed(question, now: now, restartNeeded: true)
    check(restartSlot.value == "—" && restartSlot.help == "실측 연결됨 · Claude Code를 새로 실행하면 속도가 표시됩니다",
          "restart-needed speed help")
    var codexMeasured = command
    var codexMeasurement = TokenSpeedMeasurement(TelemetryReading(provider: .codex, at: at(-130)))
    codexMeasurement.serverTokenIntervalMs = 20
    codexMeasured.speedMeasurement = codexMeasurement
    check(SessionPresentation.telemetryReceipt(SessionPresentation.measuredAt([codexMeasured, question]), now: now)
            == "실측 수신: Codex 2분 전 · Claude Code 기록 없음"
          && SessionPresentation.telemetryReceipt([.claude: at(-30)], now: now) == "실측 수신: Codex 기록 없음 · Claude Code 1분 이내",
          "telemetry receipt per provider")

    // Row actions copy or reveal; the log path comes from the reading id.
    var located = claudeParent
    located.id = "claude:.claude/projects/-work-TokenCat/S1.jsonl"
    located.projectPath = "/work/TokenCat"
    let home = URL(fileURLWithPath: "/Users/example")
    let actions = SessionPresentation.rowActions(located, home: home)
    check(actions.map(\.title) == ["세션 ID 복사", "기록 파일 Finder에서 보기", "프로젝트 폴더 Finder에서 보기"]
          && actions[1].kind == .reveal(home.appendingPathComponent(".claude/projects/-work-TokenCat/S1.jsonl"))
          && SessionPresentation.logFileURL(located, home: home)?.path == "/Users/example/.claude/projects/-work-TokenCat/S1.jsonl"
          && SessionPresentation.rowActions(claudeChild, home: home).map(\.title) == ["세션 ID 복사", "에이전트 ID 복사"]
          && SessionPresentation.rowActions(telemetry, home: home).map(\.title) == ["세션 ID 복사"], "row actions")

    // System and header mappings.
    check(MemoryPressure(1) == .normal && MemoryPressure(2) == .warning && MemoryPressure(4) == .critical && MemoryPressure(nil) == .unknown
          && MemoryPressure(4).title == "위험", "memory pressure levels")
    check(SessionsHeader.compactChips(4) && !SessionsHeader.compactChips(3), "chips shrink before they overflow")

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
    let speck = FlowBars(values: [0, 1], scale: 1_000, minHeight: 3, minWidth: 1.5).path(in: CGRect(x: 0, y: 0, width: 4, height: 8))
    check(speck.boundingRect.height == 3 && speck.boundingRect.width >= 1.5, "child bars have a readable minimum size")

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
    check(previousSlot.prefix == "이전" && previousSlot.value == "44.1" && !previousSlot.recent
          && previousSlot.help == "이전 실측 모델 claude-haiku · 측정 1분 이내", "previous-model measurement is labelled, minute-granular")
    previous.model = "claude-haiku"
    let currentSlot = SessionPresentation.speed(previous, now: now)
    check(currentSlot.prefix == nil && currentSlot.recent && currentSlot.kind == "요청 tok/s", "current-model measurement")

    // Fixture PNGs carry only visibly fake identifiers.
    let fixtureReadings = SnapshotFixtures.fixtures().flatMap(\.tokens)
    func synthetic(_ agent: String) -> Bool {
        let digits = Array(agent.dropFirst().prefix(7))
        return agent.hasPrefix("a") && digits.count == 7 && digits.allSatisfy { $0 == digits[0] && $0.isNumber }
    }
    check(!fixtureReadings.isEmpty
          && fixtureReadings.allSatisfy { $0.sessionID?.hasPrefix(SnapshotFixtures.sessionPrefix) ?? true }
          && fixtureReadings.filter { $0.source == .claude && $0.isSubagent }.allSatisfy { $0.agentID.map(synthetic) ?? false },
          "fixture IDs are synthetic")

    print("Session presentation checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
