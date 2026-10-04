import Foundation
import SwiftUI

/// What a row shows. Derived only from the tracker's enum and exact timestamps, never re-guessed.
enum SessionDisplayState: String, CaseIterable {
    case input, retrying, output, tool, working, waiting, complete, interrupted, unfinished, idle, measurement

    /// A retry notice stays this long after its record.
    static let retryLimit: TimeInterval = 600
    /// Most urgent first: chips, group state and the flow-card notice follow this order.
    static let liveOrder: [SessionDisplayState] = [.input, .retrying, .output, .tool, .working, .waiting]

    /// Shown as live in the list (includes waiting for a log).
    var isLive: Bool { isRunning || self == .waiting }
    /// Counted as running in the menu bar. A turn waiting for the person is still open.
    var isRunning: Bool {
        switch self {
        case .input, .retrying, .output, .tool, .working: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .input: return "입력 필요"
        case .retrying: return "API 재시도"
        case .output: return "출력 기록"
        case .tool: return "도구 실행"
        case .working: return "진행"
        case .waiting: return "로그 대기"
        case .complete: return "완료"
        case .interrupted: return "중단"
        case .unfinished: return "종료 기록 없음"
        case .idle: return "최근 활동 없음"
        case .measurement: return "실측"
        }
    }

    var chipTitle: String {
        switch self {
        case .input: return "입력"
        case .retrying: return "재시도"
        case .output: return "출력"
        case .tool: return "도구"
        case .working: return "진행"
        default: return title
        }
    }

    /// Yellow is reserved for input: pink would collide with purple and red in dark mode.
    var color: Color {
        switch self {
        case .input: return .yellow
        case .retrying, .waiting: return .orange
        case .output: return .green
        case .tool: return .blue
        case .working: return .purple
        default: return Color.primary.opacity(0.25)
        }
    }
}

struct SessionMember {
    var reading: TokenReading
    var state: SessionDisplayState
}

/// A top-level row with the subagents that belong to it by exact session identity.
struct SessionGroup: Identifiable {
    var lead: SessionMember
    var children: [SessionMember] = []
    var id: String { lead.reading.id }
    var members: [SessionMember] { [lead] + children }
    var isOrphan: Bool { lead.reading.isSubagent }

    var state: SessionDisplayState {
        if lead.state == .measurement { return .measurement }
        let states = Set(members.map(\.state))
        return SessionDisplayState.liveOrder.first(where: states.contains) ?? .idle
    }

    var lastActivity: Date {
        members.compactMap { $0.reading.lastActivity ?? $0.reading.measurementAt }.max() ?? .distantPast
    }
}

struct SessionCounts: Equatable {
    var input = 0, retrying = 0, output = 0, tool = 0, working = 0, waiting = 0
    var groups = 0, readings = 0, runningSubagents = 0
    /// Readings running a tool, counted per member like the menu-bar tint.
    var toolMembers = 0
    /// Tool members by category; an unknown category counts as `.other`.
    var toolCategories: [ToolCategory: Int] = [:]
    /// The newest retry among retrying members, for the flow-card notice.
    var retry: TokenRetryState?
    /// Every member waiting for input is a plan approval, so the notice says "승인".
    var inputPlansOnly = false
    var running: [TokenSource: Int] = [:]
    /// Newest record among waiting rows, for "N분 동안 새 기록 없음".
    var waitingSince: Date?
    /// Menu-bar phase: input > tool > output > working (API retries included) > waiting > idle.
    var phase: TokenActivityState = .idle

    var runningGroups: Int { input + retrying + output + tool + working }
    func count(_ state: SessionDisplayState) -> Int {
        switch state {
        case .input: return input
        case .retrying: return retrying
        case .output: return output
        case .tool: return tool
        case .working: return working
        case .waiting: return waiting
        default: return 0
        }
    }
    var liveGroups: Int { runningGroups + waiting }

    init() {}
    init(_ groups: [SessionGroup]) {
        self.groups = groups.count
        var memberStates = Set<SessionDisplayState>()
        var inputMembers = 0, planMembers = 0
        for group in groups {
            readings += group.members.count
            switch group.state {
            case .input: input += 1
            case .retrying: retrying += 1
            case .output: output += 1
            case .tool: tool += 1
            case .working: working += 1
            case .waiting: waiting += 1
            default: break
            }
            if group.state.isRunning { running[group.lead.reading.source, default: 0] += 1 }
            for member in group.members {
                memberStates.insert(member.state)
                if member.reading.isSubagent && member.state.isRunning { runningSubagents += 1 }
                if member.state == .tool {
                    toolMembers += 1
                    toolCategories[member.reading.toolCategory ?? .other, default: 0] += 1
                }
                if member.state == .input {
                    inputMembers += 1
                    if SessionPresentation.isPlanApproval(member.reading) { planMembers += 1 }
                }
                if member.state == .retrying, let value = member.reading.retry, value.at >= (retry?.at ?? .distantPast) { retry = value }
                if member.state == .waiting, let at = SessionPresentation.liveAt(member.reading) { waitingSince = max(waitingSince ?? at, at) }
            }
        }
        inputPlansOnly = inputMembers > 0 && planMembers == inputMembers
        if memberStates.contains(.input) { phase = .input }
        else if memberStates.contains(.tool) { phase = .tool }
        else if memberStates.contains(.output) { phase = .output }
        else if memberStates.contains(.working) || memberStates.contains(.retrying) { phase = .working }
        else if memberStates.contains(.waiting) { phase = .stale }
    }

    /// The tool category most members are running; ties go to the declaration order.
    var leadingToolCategory: ToolCategory? {
        let order: [ToolCategory] = [.command, .file, .web, .agent, .mcp, .question, .other]
        return order.filter { toolCategories[$0, default: 0] > 0 }.max { toolCategories[$0, default: 0] < toolCategories[$1, default: 0] }
    }
}

struct SpeedSlot: Equatable {
    /// "이전" when the measurement belongs to a model the session no longer reports.
    var prefix: String?
    var value: String
    var kind: String?
    var recent: Bool
    var help: String
    var spoken: String
    var known: Bool { kind != nil }
}

/// Context occupied by the latest request: a percentage only when the client logged the window size.
struct ContextSlot: Equatable {
    var text: String
    /// 0…1 fill for the bar; nil when the window size is unknown (Claude Code).
    var fraction: Double?
    var warning: Bool
    var help: String
    var spoken: String
}

/// The Codex usage-limit window as last written to a log. Never projected forward.
struct UsageLimitSummary: Equatable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
    var recordedAt: Date

    /// When the window resets; without a logged reset time, one full window after the record.
    var resetDate: Date? {
        if let resetsAt { return resetsAt }
        guard let windowMinutes, windowMinutes > 0 else { return nil }
        return recordedAt.addingTimeInterval(Double(windowMinutes) * 60)
    }
    func expired(now: Date) -> Bool { resetDate.map { $0 <= now } ?? false }
    /// A reset window stays on screen for one day to say "초기화됨", then the card goes away.
    func isShown(now: Date) -> Bool { !expired(now: now) || now.timeIntervalSince(resetDate ?? .distantPast) < 86_400 }
    var title: String { "Codex \(SessionPresentation.windowLabel(windowMinutes)) 한도" }
    /// "사용" because Codex's own UI counts what is left; this is what was used.
    func value(now: Date) -> String { expired(now: now) ? "—" : "\(Int(usedPercent.rounded()))% 사용" }
    /// More than 10 minutes since Codex wrote it: the value is shown weaker.
    func isOld(now: Date) -> Bool { now.timeIntervalSince(recordedAt) > 600 }
    func detail(now: Date) -> String {
        if expired(now: now) { return "초기화됨 · 다음 Codex 기록 대기" }
        let basis = "\(SessionPresentation.helpAge(recordedAt, now: now)) 기록 기준"
        guard let resetsAt else { return basis }
        return "\(SessionPresentation.countdown(to: resetsAt, now: now)) 후 초기화 · \(basis)"
    }
    func spoken(now: Date) -> String {
        expired(now: now) ? "초기화됨, 다음 Codex 기록 대기"
            : "\(Int(usedPercent.rounded()))퍼센트 사용, \(detail(now: now).replacingOccurrences(of: " · ", with: ", "))"
    }
    static let help = "Codex 로그에 마지막으로 기록된 계정 사용량입니다. 실시간 잔여량이 아니며 Codex를 사용할 때만 갱신됩니다. 소진 시점을 예측하지 않습니다. Claude Code는 로그에 한도를 남기지 않아 표시하지 않습니다."
}

/// Why the footer warns about telemetry; copy stays short enough for the 392pt footer.
struct TelemetryNotice: Equatable {
    enum Kind { case portBusy, busy, collector, conflict, failed, off, expired, restart }
    var kind: Kind
    var text: String
    var help: String
    var isProblem: Bool { kind != .restart }
    /// The collector itself is not running, so no client config was touched.
    var collectorDown: Bool { [.portBusy, .busy, .collector, .off].contains(kind) }
}

enum SessionPresentation {
    static func isTelemetry(_ reading: TokenReading) -> Bool { reading.id.hasPrefix("telemetry:") }

    /// Newest record of any kind: liveness only.
    static func liveAt(_ reading: TokenReading) -> Date? { [reading.lastActivity, reading.lastLogAt].compactMap { $0 }.max() }

    static func isRetrying(_ reading: TokenReading, now: Date) -> Bool {
        guard let retry = reading.retry else { return false }
        let age = now.timeIntervalSince(retry.at)
        return age >= -5 && age <= SessionDisplayState.retryLimit
    }

    static func displayState(_ reading: TokenReading, now: Date) -> SessionDisplayState {
        if isTelemetry(reading) { return .measurement }
        switch reading.activityState {
        case .input: return .input
        case .unfinished: return .unfinished
        // The tracker ends "로그 대기" 30 minutes after the newest record (then .unfinished);
        // its horizon depends on what the turn waits for, so the UI does not re-time it.
        case .stale: return .waiting
        default: break
        }
        if !reading.active {
            switch reading.activityState {
            case .complete: return .complete
            case .interrupted: return .interrupted
            default: return .idle
            }
        }
        if isRetrying(reading, now: now) { return .retrying }
        if reading.activityState == .tool { return .tool }
        if let at = reading.lastOutputAt, let delta = reading.lastOutputDelta, delta > 0,
           abs(now.timeIntervalSince(at)) <= 5 { return .output }
        return .working
    }

    /// Subagents fold under the main row with the same source and exact session identity.
    /// Model, project and time never establish a group; telemetry rows never group.
    static func groups(_ tokens: [TokenReading], now: Date) -> [SessionGroup] {
        func key(_ source: TokenSource, _ session: String?) -> String? {
            session.map { source.rawValue + "\u{1f}" + $0 }
        }
        var groups: [SessionGroup] = []
        var parentIndex: [String: Int] = [:]
        for reading in tokens.sorted(by: { $0.id < $1.id }) where isTelemetry(reading) || !reading.isSubagent {
            groups.append(SessionGroup(lead: SessionMember(reading: reading, state: displayState(reading, now: now))))
            guard !isTelemetry(reading), let key = key(reading.source, reading.sessionID) else { continue }
            if let existing = parentIndex[key],
               (groups[existing].lead.reading.lastActivity ?? .distantPast) >= (reading.lastActivity ?? .distantPast) { continue }
            parentIndex[key] = groups.count - 1
        }
        for reading in tokens.sorted(by: { $0.id < $1.id }) where !isTelemetry(reading) && reading.isSubagent {
            let member = SessionMember(reading: reading, state: displayState(reading, now: now))
            if let key = key(reading.source, reading.parentSessionID ?? reading.sessionID), let index = parentIndex[key] {
                groups[index].children.append(member)
            } else {
                groups.append(SessionGroup(lead: member))
            }
        }
        return groups
    }

    static func agentLabel(_ reading: TokenReading) -> String {
        if let agent = reading.agentID, !agent.isEmpty {
            return agent.contains("/") ? URL(fileURLWithPath: agent).lastPathComponent : String(agent.prefix(8))
        }
        return String((reading.sessionID ?? URL(fileURLWithPath: reading.id).deletingPathExtension().lastPathComponent).suffix(8))
    }

    /// The client's role name for help and VoiceOver; only known internal names are translated.
    static func roleLabel(_ role: String?) -> String? {
        guard let role = role?.trimmingCharacters(in: .whitespaces), !role.isEmpty else { return nil }
        return ["guardian", "guardian_review"].contains(role) ? "자동 검토" : role
    }

    /// Roles nearly every Claude Code subagent shares; as a title they would hide the only distinguishing ID.
    static let opaqueRoles: Set<String> = ["workflow-subagent", "general-purpose"]

    /// A distinguishing role or nickname first; the ID follows in the detail slot. Shared roles leave the ID as the title.
    static func childTitle(_ reading: TokenReading) -> (title: String, detail: String?) {
        let role = roleLabel(reading.agentRole).flatMap { opaqueRoles.contains($0) ? nil : $0 }
        if let agent = reading.agentID, agent.contains("/") {
            let name = URL(fileURLWithPath: agent).lastPathComponent
            return (name, role == name ? nil : role)
        }
        if let role { return (role, agentLabel(reading)) }
        return (agentLabel(reading), nil)
    }

    /// UUIDv7 prefixes are timestamps shared by conversations created together, so use the suffix.
    static func shortID(_ reading: TokenReading) -> String {
        if reading.isSubagent { return agentLabel(reading) }
        if let session = reading.sessionID, !session.isEmpty { return String(session.suffix(8)) }
        if isTelemetry(reading) { return "" }
        return String(URL(fileURLWithPath: reading.id).deletingPathExtension().lastPathComponent.suffix(8))
    }

    /// A child shows its own project when it differs from the parent's.
    static func childProjectSuffix(_ child: TokenReading, parent: TokenReading) -> String? {
        guard let project = child.project, !project.isEmpty, project != parent.project else { return nil }
        return project
    }

    static func identity(_ reading: TokenReading, children: Int) -> String {
        [reading.project, shortID(reading), children > 0 ? "하위 \(children)" : nil, reading.isSubagent ? "하위" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Raw client value, lowercased and never translated.
    static func effortLabel(_ reading: TokenReading) -> String? {
        guard let effort = reading.effort?.trimmingCharacters(in: .whitespaces), !effort.isEmpty else { return nil }
        return effort.lowercased()
    }

    static func toolTitle(_ category: ToolCategory?) -> String {
        switch category {
        case .command: return "명령 실행"
        case .file: return "파일 작업"
        case .web: return "웹 조회"
        case .agent: return "하위 에이전트 대기"
        case .mcp: return "MCP 도구"
        case .question: return "입력 요청"
        case .other, nil: return "도구 실행"
        }
    }

    /// Chip text: the tool category replaces the generic "도구 실행".
    static func stateTitle(_ state: SessionDisplayState, _ reading: TokenReading) -> String {
        state == .tool ? toolTitle(reading.toolCategory) : state.title
    }

    static func isPlanApproval(_ reading: TokenReading) -> Bool { reading.toolName == "ExitPlanMode" }

    static func inputTitle(_ reading: TokenReading) -> String { isPlanApproval(reading) ? "계획 승인 대기" : "질문 답변 대기" }

    /// An idle lead row standing in for its live children.
    static func childGroupText(_ state: SessionDisplayState, count: Int) -> String {
        switch state {
        case .input: return "하위 \(count)개 입력 필요"
        case .retrying: return "하위 \(count)개 API 재시도"
        default: return "하위 \(count)개 \(state.isRunning ? "진행 중" : "로그 대기")"
        }
    }

    static func retryText(_ retry: TokenRetryState, now: Date) -> String {
        let attempts = retry.maxAttempts.map { "\(retry.attempt)/\($0)" } ?? "\(retry.attempt)회째"
        if retry.networkDown { return "재시도 \(attempts) · 네트워크 끊김" }
        guard let at = retry.retryAt, at > now else { return "재시도 \(attempts) · 재요청 중" }
        let seconds = Int(ceil(at.timeIntervalSince(now)))
        return "재시도 \(attempts) · " + (seconds >= 60 ? "\(seconds / 60)분 후" : "\(seconds)초 후")
    }

    static func context(_ reading: TokenReading, now: Date) -> ContextSlot? {
        guard let context = reading.context, context.usedTokens > 0 else { return nil }
        let source = reading.source.title
        var help: String
        let slot: (text: String, fraction: Double?, warning: Bool, spoken: String)
        if let window = context.windowTokens, window > 0 {
            let percent = Double(context.usedTokens) / Double(window) * 100
            slot = ("컨텍스트 \(Int(percent.rounded()))% 사용", min(1, percent / 100), percent >= 85, "컨텍스트 \(Int(percent.rounded()))퍼센트 사용")
            help = "마지막 요청 입력 \(Format.tokens(context.usedTokens)) / 모델 컨텍스트 \(Format.tokens(window)) tok (\(source) 기록)"
        } else {
            let used = context.usedTokens
            let short = used < 1_000 ? String(used) : (used < 999_500 ? "\(Int((Double(used) / 1_000).rounded()))k" : Format.compactTokens(used))
            slot = ("컨텍스트 \(short)", nil, false, "컨텍스트 \(used) 토큰")
            help = "마지막 요청 입력 \(Format.tokens(context.usedTokens)) tok (입력·캐시 합계)\n\(source)는 컨텍스트 창 크기를 기록하지 않아 비율을 표시하지 않습니다"
        }
        help += "\n출력 토큰 제외 · \(helpAge(context.recordedAt, now: now)) 기록"
        if let compacted = context.compactedAt { help += "\n압축 완료 기록 \(helpAge(compacted, now: now))" }
        return ContextSlot(text: slot.text, fraction: slot.fraction, warning: slot.warning, help: help, spoken: slot.spoken)
    }

    /// A completed turn's output and the client's own duration, side by side and never divided.
    static func lastTurnSummary(_ reading: TokenReading) -> String? {
        guard let output = reading.lastOutputTokens else { return nil }
        guard let seconds = reading.lastTurnDurationSeconds, seconds.isFinite, seconds >= 0 else {
            return "마지막 출력 기록 \(Format.tokens(output)) tok"
        }
        return "마지막 완료 턴 출력 \(Format.tokens(output)) tok · 소요 \(clock(Int(seconds.rounded())))"
    }

    static func clock(_ seconds: Int) -> String {
        seconds >= 3_600 ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Minute-granular age for help text, so tooltips do not change every second.
    static func helpAge(_ date: Date?, now: Date) -> String {
        guard let date else { return "기록 없음" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "1분 이내" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3_600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }

    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now)) / 60)
        if minutes >= 1_440 { return minutes % 1_440 / 60 > 0 ? "\(minutes / 1_440)일 \(minutes % 1_440 / 60)시간" : "\(minutes / 1_440)일" }
        if minutes >= 60 { return minutes % 60 > 0 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes / 60)시간" }
        return minutes > 0 ? "\(minutes)분" : "1분 이내"
    }

    static func windowLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "사용" }
        switch minutes {
        case 300: return "5시간"
        case 10_080: return "주간"
        case 43_200, 43_800: return "월간"
        default:
            if minutes % 1_440 == 0 { return "\(minutes / 1_440)일" }
            return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes)분"
        }
    }

    /// Replay-proof: the newest reset window wins, then the highest percentage inside it.
    /// Without any reset time the windows cannot be told apart, so only the newest record counts.
    static func usageLimit(_ tokens: [TokenReading]) -> UsageLimitSummary? {
        let limits = tokens.filter { $0.source == .codex }.compactMap(\.rateLimit).filter { $0.usedPercent.isFinite }
        guard let newest = limits.map({ $0.resetsAt ?? .distantPast }).max() else { return nil }
        if newest == .distantPast, let last = limits.max(by: { $0.recordedAt < $1.recordedAt }) {
            return UsageLimitSummary(usedPercent: last.usedPercent, windowMinutes: last.windowMinutes, resetsAt: nil, recordedAt: last.recordedAt)
        }
        let window = limits.filter { abs(($0.resetsAt ?? .distantPast).timeIntervalSince(newest)) <= 60 }
        guard let top = window.max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
        return UsageLimitSummary(usedPercent: top.usedPercent, windowMinutes: top.windowMinutes, resetsAt: top.resetsAt,
                                 recordedAt: window.map(\.recordedAt).max() ?? top.recordedAt)
    }

    /// Only exact-identity telemetry; never a speed derived from log timing.
    static func speed(_ reading: TokenReading, now: Date, restartNeeded: Bool = false) -> SpeedSlot {
        guard let measurement = reading.speedMeasurement, let rate = measurement.tokensPerSecond else {
            let help = restartNeeded ? "실측 연결됨 · \(reading.source.title)를 새로 실행하면 속도가 표시됩니다"
                : "실측 속도 없음 · 로그 시각으로 추정하지 않습니다"
            return SpeedSlot(prefix: nil, value: "—", kind: nil, recent: false, help: help, spoken: "속도 실측 없음")
        }
        let kind = measurement.kind?.title ?? "tok/s"
        let spokenKind: String
        switch measurement.kind {
        case .serverGeneration: spokenKind = "생성 속도"
        case .serverAggregate: spokenKind = "모델 평균 속도"
        default: spokenKind = "요청 처리 속도"
        }
        let spoken = "\(spokenKind) 초당 \(Format.tps(rate)) 토큰"
        if measurement.model != reading.model {
            return SpeedSlot(prefix: "이전", value: Format.tps(rate), kind: kind, recent: false,
                             help: "이전 실측 모델 \(measurement.model ?? "미확인") · 측정 \(helpAge(measurement.at, now: now))",
                             spoken: "이전 모델 " + spoken)
        }
        let age = now.timeIntervalSince(measurement.at)
        return SpeedSlot(prefix: nil, value: Format.tps(rate), kind: kind, recent: age >= -5 && age < 120,
                         help: measurement.details, spoken: spoken)
    }

    static func spokenDuration(_ start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3_600 { return "\(seconds / 3_600)시간 \(seconds / 60 % 60)분" }
        return seconds >= 60 ? "\(seconds / 60)분 \(seconds % 60)초" : "\(seconds)초"
    }

    /// The flow-card capsule: input > API retry > tool category > progress > waiting for a log.
    /// Input and retries show even right after a record; the rest only after 30 s without one.
    static func flowNotice(counts: SessionCounts, last: Date?, now: Date) -> String? {
        if counts.input > 0 {
            let number = counts.input > 1 ? " \(counts.input)개" : ""
            return counts.inputPlansOnly ? "계획 승인 대기\(number) · 승인하면 계속됩니다" : "입력 필요\(number) · 답변하면 계속됩니다"
        }
        if counts.retrying > 0 {
            guard let retry = counts.retry else { return "API 재시도 중" }
            return retry.networkDown ? "API 재시도 중 · 네트워크 연결을 확인하세요" : "API " + retryText(retry, now: now)
        }
        guard counts.liveGroups > 0 else { return nil }
        if let last, now.timeIntervalSince(last) <= 30 { return nil }
        if counts.tool > 0 { return "\(toolTitle(counts.leadingToolCategory)) 중 · 응답이 끝나면 토큰이 기록됩니다" }
        if counts.working > 0 || counts.output > 0 { return "진행 중 · 응답이 끝나면 토큰이 기록됩니다" }
        let minutes = counts.waitingSince.map { max(1, Int(now.timeIntervalSince($0)) / 60) } ?? 1
        return "로그 대기 · \(minutes)분 동안 새 기록 없음"
    }

    /// Cause-specific copy from the collector status, the setup note and pending or expired restarts.
    /// The status strings are the collector's; switch on its state enum once the model exposes it.
    static func telemetryNotice(ready: Bool, status: String, note: String?, failure: TelemetrySetupFailure? = nil,
                                restart: Set<TokenSource>, expired: Set<TokenSource> = []) -> TelemetryNotice? {
        let open = "\n누르면 설정을 엽니다"
        func names(_ sources: Set<TokenSource>) -> String { TokenSource.allCases.filter(sources.contains).map(\.title).joined(separator: " · ") }
        if status.contains("TokenCat") {
            return TelemetryNotice(kind: .busy, text: "실측 꺼짐 · 다른 TokenCat",
                                   help: "다른 TokenCat이 이미 실측을 수집하고 있어 이 TokenCat은 실측을 받지 않습니다. 하나만 실행하세요." + open)
        }
        if status.contains("포트") {
            return TelemetryNotice(kind: .portBusy, text: "실측 꺼짐 · 포트 사용 중",
                                   help: "로컬 실측 수집기가 127.0.0.1:\(TelemetrySetup.port) 포트를 열지 못했습니다. 다른 앱이 포트를 쓰고 있을 수 있습니다." + open)
        }
        if status.contains("시작하지") {
            return TelemetryNotice(kind: .collector, text: "실측 꺼짐 · 수집기 오류", help: status + open)
        }
        if let note {
            let conflict = failure == .conflict
            return TelemetryNotice(kind: conflict ? .conflict : .failed, text: conflict ? "실측 꺼짐 · 설정 충돌" : "실측 꺼짐 · 연결 실패",
                                   help: note + open)
        }
        let pending = ["준비", "대기", "수신", "연결됨"].contains(where: status.contains)
        if ["중지", "꺼짐", "실패"].contains(where: status.contains) || (!ready && !pending) {
            return TelemetryNotice(kind: .off, text: "실측 꺼짐", help: status + open)
        }
        if !expired.isEmpty {
            return TelemetryNotice(kind: .expired, text: "실측 미수신 · 확인 필요",
                                   help: "\(names(expired)): 이 버전에서 실측을 받지 못했습니다. 새로 실행한 뒤에도 그대로면 설정에서 연결 상태를 확인하세요." + open)
        }
        guard !restart.isEmpty else { return nil }
        return TelemetryNotice(kind: .restart, text: "재시작 후 실측 표시",
                               help: "\(names(restart))를 새로 실행하면 속도가 표시됩니다. 진행 중인 작업은 재시작하지 않습니다." + open)
    }

    /// "실측 수신: Codex 기록 없음 · Claude Code 2분 전", minute-granular for a stable tooltip.
    static func telemetryReceipt(_ lastReceived: [TokenSource: Date], now: Date) -> String {
        "실측 수신: " + TokenSource.allCases.map { "\($0.title) \(helpAge(lastReceived[$0], now: now))" }.joined(separator: " · ")
    }

    /// Newest measurement per client from the readings, for a model that does not track receipts itself.
    static func measuredAt(_ tokens: [TokenReading]) -> [TokenSource: Date] {
        tokens.reduce(into: [:]) { result, reading in
            guard let at = reading.speedMeasurement?.at else { return }
            result[reading.source] = max(result[reading.source] ?? at, at)
        }
    }

    /// Expanded-list date captions from the model clock.
    static func daySection(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) || date > now { return "오늘" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "어제" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "이번 주" }
        return olderSection
    }
    static let olderSection = "이전"

    /// The log file the reading came from: its id is "<source>:<path relative to home>".
    static func logFileURL(_ reading: TokenReading, home: URL) -> URL? {
        guard !isTelemetry(reading), let colon = reading.id.firstIndex(of: ":") else { return nil }
        let path = String(reading.id[reading.id.index(after: colon)...])
        guard path.hasSuffix(".jsonl"), !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
    }

    struct RowAction: Identifiable, Equatable {
        enum Kind: Equatable { case copy(String), reveal(URL) }
        var title: String
        var kind: Kind
        var id: String { title }
    }

    /// Copy and reveal only; file contents are never opened.
    static func rowActions(_ reading: TokenReading, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [RowAction] {
        var actions: [RowAction] = []
        if let session = reading.sessionID, !session.isEmpty { actions.append(RowAction(title: "세션 ID 복사", kind: .copy(session))) }
        if let agent = reading.agentID, !agent.isEmpty { actions.append(RowAction(title: "에이전트 ID 복사", kind: .copy(agent))) }
        if let log = logFileURL(reading, home: home) { actions.append(RowAction(title: "기록 파일 Finder에서 보기", kind: .reveal(log))) }
        if let path = reading.projectPath, path.hasPrefix("/") {
            actions.append(RowAction(title: "프로젝트 폴더 Finder에서 보기", kind: .reveal(URL(fileURLWithPath: path, isDirectory: true))))
        }
        return actions
    }
}

struct SessionRowItem: Identifiable {
    enum Kind { case live, idle, measurement, child }
    var reading: TokenReading
    var state: SessionDisplayState
    var kind: Kind
    /// Live rows drop line 3 when it would hold no bars, no context and no measured speed.
    var showsDetail = true
    var id: String { reading.id }
    var height: CGFloat {
        switch kind {
        case .live: return showsDetail ? 62 : 44
        case .idle, .measurement: return 28
        case .child: return 24
        }
    }
}

struct SessionBlock: Identifiable {
    var lead: SessionRowItem
    var children: [SessionRowItem]
    var childCount: Int
    var state: SessionDisplayState
    /// Live children in the whole group, shown or not.
    var runningChildren = 0, waitingChildren = 0
    /// Children waiting for a log left out of the collapsed list; running children are never cut.
    var moreCount = 0
    var moreText = ""
    /// Expanded-list date caption drawn above this block, and whether it sits in the folded "이전" part.
    var caption: String?
    var older = false
    var id: String { lead.id }
    var height: CGFloat {
        children.reduce(lead.height) { $0 + $1.height } + (moreCount > 0 ? SessionListModel.moreHeight : 0)
    }
    /// Tops of the rows inside the block, relative to the block.
    var rowFrames: [(top: CGFloat, height: CGFloat)] {
        var frames = [(top: CGFloat(0), height: lead.height)]
        var y = lead.height
        for child in children { frames.append((y, child.height)); y += child.height }
        if moreCount > 0 { frames.append((y, SessionListModel.moreHeight)) }
        return frames
    }
}

enum SessionListEntry: Identifiable {
    case divider(String), caption(String), block(SessionBlock), older(Int)
    var id: String {
        switch self {
        case .divider(let id): return "divider:" + id
        case .caption(let title): return "caption:" + title
        case .block(let block): return block.id
        case .older: return "older"
        }
    }
    var height: CGFloat {
        switch self {
        case .divider: return SessionListModel.dividerHeight
        case .caption: return SessionListModel.captionHeight
        case .block(let block): return block.height
        case .older: return SessionListModel.moreHeight
        }
    }
}

/// Computed once per publish; views never re-sort.
struct SessionListModel {
    static let maxViewport: CGFloat = 264
    static let dividerHeight: CGFloat = 1
    static let captionHeight: CGFloat = 16
    static let collapsedMinimum = 6
    static let collapsedChildren = 3
    static let moreHeight: CGFloat = 24

    var blocks: [SessionBlock] = []
    var counts = SessionCounts()
    /// Top-level groups and children of shown groups not visible while collapsed.
    var hiddenGroups = 0
    var hiddenChildren = 0
    /// Expanded only: blocks in the folded "이전" section.
    var olderCount = 0
    /// With "이전" folded.
    var contentHeight: CGFloat = 0
    var olderContentHeight: CGFloat = 0
    /// Shared scale for every visible mini bar strip.
    var rowScale: Double = 200
    /// Codex usage limit from the same publish.
    var usageLimit: UsageLimitSummary?
    private var viewports: (folded: CGFloat, open: CGFloat) = (0, 0)

    static let empty = SessionListModel()

    func entries(showOlder: Bool) -> [SessionListEntry] {
        var entries: [SessionListEntry] = []
        var folded = false
        for block in blocks {
            if block.older && !showOlder {
                if !folded {
                    if !entries.isEmpty { entries.append(.divider("older")) }
                    entries.append(.older(olderCount))
                    folded = true
                }
                continue
            }
            if let caption = block.caption { entries.append(.caption(caption)) }
            else if !entries.isEmpty { entries.append(.divider(block.id)) }
            entries.append(.block(block))
        }
        return entries
    }

    func height(showOlder: Bool) -> CGFloat { olderCount > 0 && showOlder ? olderContentHeight : contentHeight }
    func viewport(showOlder: Bool) -> CGFloat { olderCount > 0 && showOlder ? viewports.open : viewports.folded }

    /// The cut lands at least 12pt inside a row and hides at least 6pt of it, so a peek always reads as a row.
    static func snappedViewport(_ entries: [SessionListEntry]) -> CGFloat {
        let total = entries.reduce(0) { $0 + $1.height }
        guard total > maxViewport else { return total }
        var best: CGFloat = 0
        var y: CGFloat = 0
        for entry in entries {
            var frames: [(top: CGFloat, height: CGFloat)] = []
            if case .block(let block) = entry { frames = block.rowFrames } else if case .older = entry { frames = [(0, moreHeight)] }
            for frame in frames {
                let low = y + frame.top + 12, high = y + frame.top + frame.height - 6
                if low <= maxViewport { best = max(best, min(high, maxViewport)) }
            }
            y += entry.height
        }
        return best > 0 ? best : maxViewport
    }

    static func make(tokens: [TokenReading], now: Date, expanded: Bool, flow: FlowSeries,
                     calendar: Calendar = .current) -> SessionListModel {
        let groups = SessionPresentation.groups(tokens, now: now)
        func stable(_ a: SessionGroup, _ b: SessionGroup) -> Bool {
            let order = (a.lead.reading.project ?? "").localizedStandardCompare(b.lead.reading.project ?? "")
            if order != .orderedSame { return order == .orderedAscending }
            if a.lead.reading.sessionID != b.lead.reading.sessionID { return (a.lead.reading.sessionID ?? "") < (b.lead.reading.sessionID ?? "") }
            return a.id < b.id
        }
        // A turn waiting for the person goes first; the rest of the running set keeps a stable order.
        let input = groups.filter { $0.state == .input }.sorted(by: stable)
        let running = groups.filter { $0.state.isRunning && $0.state != .input }.sorted(by: stable)
        let waiting = groups.filter { $0.state == .waiting }.sorted(by: stable)
        let measured = groups.filter { group in
            guard group.state == .measurement, let at = group.lead.reading.speedMeasurement?.at else { return false }
            let age = now.timeIntervalSince(at)
            return age >= -5 && age < 120
        }.sorted { $0.id < $1.id }
        let pinnedGroups = input + running + waiting + measured
        let pinned = Set(pinnedGroups.map(\.id))
        let rest = groups.filter { !pinned.contains($0.id) }.sorted {
            $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id
        }
        let ordered = pinnedGroups + rest
        let shown = expanded ? ordered : Array(ordered.prefix(max(pinned.count, collapsedMinimum)))

        var model = SessionListModel()
        model.counts = SessionCounts(groups)
        model.usageLimit = SessionPresentation.usageLimit(tokens)
        model.hiddenGroups = ordered.count - shown.count
        var peak = 0
        var lastCaption: String?
        for group in shown {
            let lead = group.lead
            let kind: SessionRowItem.Kind = lead.state == .measurement ? .measurement : (lead.state.isLive ? .live : .idle)
            let live = group.children.filter { $0.state.isLive }.sorted {
                if $0.state.isRunning != $1.state.isRunning { return $0.state.isRunning }
                let a = SessionPresentation.agentLabel($0.reading), b = SessionPresentation.agentLabel($1.reading)
                return a != b ? a.localizedStandardCompare(b) == .orderedAscending : $0.reading.id < $1.reading.id
            }
            let running = live.filter { $0.state.isRunning }.count
            // Collapsed: every running child shows; children waiting for a log take slots only when none runs.
            let room = expanded ? live.count : (running > 0 ? running : min(live.count, collapsedChildren))
            var children = Array(live.prefix(room))
            let cut = Array(live.dropFirst(room))
            if expanded {
                children += group.children.filter { !$0.state.isLive }.sorted {
                    let a = $0.reading.lastActivity ?? .distantPast, b = $1.reading.lastActivity ?? .distantPast
                    return a != b ? a > b : $0.reading.id < $1.reading.id
                }
            } else {
                model.hiddenChildren += group.children.count - children.count
            }
            var leadItem = SessionRowItem(reading: lead.reading, state: lead.state, kind: kind)
            if kind == .live {
                leadItem.showsDetail = flow.rows[lead.reading.id] != nil || lead.reading.speedMeasurement?.tokensPerSecond != nil
                    || SessionPresentation.context(lead.reading, now: now) != nil
            }
            var block = SessionBlock(lead: leadItem,
                                     children: children.map { SessionRowItem(reading: $0.reading, state: $0.state, kind: .child) },
                                     childCount: group.children.count, state: group.state)
            block.runningChildren = running
            block.waitingChildren = live.count - running
            block.moreCount = cut.count
            if !cut.isEmpty {
                let newest = cut.compactMap { SessionPresentation.liveAt($0.reading) }.max()
                block.moreText = "+\(cut.count) 하위 \(SessionDisplayState.waiting.title)"
                    + (newest.map { " · 마지막 \(Format.age($0, now: now))" } ?? "")
            }
            if expanded && !pinned.contains(group.id) {
                let section = SessionPresentation.daySection(group.lastActivity, now: now, calendar: calendar)
                if section != lastCaption { block.caption = section; lastCaption = section }
                block.older = section == SessionPresentation.olderSection
                if block.older { model.olderCount += 1 }
            }
            for item in [block.lead] + block.children where item.kind == .live || (item.kind == .child && item.state.isLive) {
                peak = max(peak, flow.rows[item.id]?.peak ?? 0)
            }
            model.blocks.append(block)
        }
        let folded = model.entries(showOlder: false), open = model.entries(showOlder: true)
        model.contentHeight = folded.reduce(0) { $0 + $1.height }
        model.olderContentHeight = open.reduce(0) { $0 + $1.height }
        model.viewports = (snappedViewport(folded), snappedViewport(open))
        model.rowScale = niceMax(Double(max(peak, 200)))
        return model
    }
}
