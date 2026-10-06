import Foundation
import SwiftUI

/// What a row shows. Derived only from the tracker's enum and exact timestamps, never re-guessed.
enum SessionDisplayState: String, CaseIterable {
    case input, retrying, tool, working, waiting, complete, interrupted, unfinished, idle, measurement

    /// A retry notice stays this long after its record.
    static let retryLimit: TimeInterval = 600
    /// The one urgency order: input > API retry > tool > progress > waiting for a log.
    /// Group state, the header sentence, the flow-card caption and the menu-bar phase (`SessionCounts.phase`) all use it.
    /// A fresh output record is an event (`lastOutputAt`), never a state, so it has no place here.
    static let liveOrder: [SessionDisplayState] = [.input, .retrying, .tool, .working, .waiting]

    /// The most urgent live state among `states`; nil when none is live.
    static func mostUrgent<S: Sequence>(_ states: S) -> SessionDisplayState? where S.Element == SessionDisplayState {
        let present = Set(states)
        return liveOrder.first(where: present.contains)
    }

    /// Shown as live in the list (includes waiting for a log).
    var isLive: Bool { isRunning || self == .waiting }
    /// Counted as running in the menu bar. A turn waiting for the person is still open.
    var isRunning: Bool {
        switch self {
        case .input, .retrying, .tool, .working: return true
        default: return false
        }
    }
    /// A generation could be under way, so a missing measured speed is worth a "—". Waiting for the person or a log is not.
    var expectsSpeed: Bool { self == .retrying || self == .tool || self == .working }

    var title: String {
        switch self {
        case .input: return loc("입력 필요", "Input needed")
        case .retrying: return loc("API 재시도", "API retry")
        case .tool: return loc("도구 실행", "Running tool")
        case .working: return loc("진행", "Working")
        case .waiting: return loc("로그 대기", "Waiting for log")
        case .complete: return loc("완료", "Complete")
        case .interrupted: return loc("중단", "Interrupted")
        case .unfinished: return loc("종료 기록 없음", "No end record")
        case .idle: return loc("최근 활동 없음", "No recent activity")
        case .measurement: return loc("실측", "Measured")
        }
    }

    /// The glyph's colour token (A0-3); yellow is reserved for input.
    var color: Color { StateGlyph.Kind(self).map(StateGlyph.color) ?? TCColor.idle }
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
        return SessionDisplayState.mostUrgent(members.map(\.state)) ?? .idle
    }

    var lastActivity: Date {
        members.compactMap { $0.reading.lastActivity ?? $0.reading.measurementAt }.max() ?? .distantPast
    }
}

struct SessionCounts: Equatable {
    var input = 0, retrying = 0, tool = 0, working = 0, waiting = 0
    var groups = 0, readings = 0, runningSubagents = 0
    /// Readings running a tool, counted per member like the menu-bar tint.
    var toolMembers = 0
    /// Tool members by category; an unknown category counts as `.other`.
    var toolCategories: [ToolCategory: Int] = [:]
    /// The newest retry among retrying members, for the header and the flow-card caption.
    var retry: TokenRetryState?
    /// Every member waiting for input is a plan approval, so the copy says "승인".
    var inputPlansOnly = false
    var running: [TokenSource: Int] = [:]
    /// Newest record among waiting rows, for "N분째 새 기록 없음".
    var waitingSince: Date?
    /// Newest activity of any session group (telemetry rows excluded), for "마지막 활동 2시간 전".
    var newestActivity: Date?
    /// Menu-bar phase from the same order as the group state (`SessionDisplayState.mostUrgent` over every member):
    /// input > API retry > tool > working > waiting > idle. The menu bar has no retry mark, so a retry reads as working.
    var phase: TokenActivityState = .idle

    var runningGroups: Int { input + retrying + tool + working }
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
            case .tool: tool += 1
            case .working: working += 1
            case .waiting: waiting += 1
            default: break
            }
            if group.state.isRunning { running[group.lead.reading.source, default: 0] += 1 }
            if group.state != .measurement, group.lastActivity != .distantPast {
                newestActivity = max(newestActivity ?? group.lastActivity, group.lastActivity)
            }
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
        phase = Self.phase(SessionDisplayState.mostUrgent(memberStates))
    }

    /// Menu-bar phase for the most urgent live state.
    static func phase(_ state: SessionDisplayState?) -> TokenActivityState {
        switch state {
        case .input: return .input
        case .tool: return .tool
        case .retrying, .working: return .working
        case .waiting: return .stale
        default: return .idle
        }
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

/// The menu bar's "평균 속도": the mean of every fresh per-session rate and the clients that contributed one, fastest
/// first (each client's own mean, descending; ties in `TokenSource` order), so the leading glyph is the fastest client.
struct AverageSpeed: Equatable {
    var rate: Double
    var sources: [TokenSource]
}

/// The flow card's "지금 속도": one measured rate from one visible live session, never a sum or an average.
struct SpeedHeadline: Equatable {
    var value: String
    var kind: String?
    /// The measured session's project, shown when it fits.
    var project: String?
    var help: String
    var spoken: String
    var known: Bool { kind != nil }
}

/// Context occupied by the latest request: a percentage only when the client logged the window size.
struct ContextSlot: Equatable {
    var text: String
    /// The narrow form for a tight third line: "61%" or "730k".
    var short: String
    /// 0…1 fill for the meter; nil when the window size is unknown (Claude Code).
    var fraction: Double?
    var warning: Bool
    /// "압축 3분 전" for 30 minutes after a compaction record; shown instead of the value.
    var compacted: String?
    var help: String
    var spoken: String
}

/// An account usage-limit window as last recorded: Codex from its logs, Claude from Claude Code's status line
/// (`recordedAt` is then TokenCat's receipt) or the Claude desktop app's usage history (no reset time), or either from a
/// live read (`recordedAt` is the read time). Never projected forward.
struct UsageLimitSummary: Equatable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
    var recordedAt: Date
    var source: TokenSource = .codex
    /// Claude only: the other live window, named in help and VoiceOver.
    var other: OtherWindow?
    /// From a live read (실시간 한도 확인), not a record.
    var live = false
    struct OtherWindow: Equatable {
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date
    }

    /// When the window resets; without a logged reset time, one full window after the record.
    var resetDate: Date? {
        if let resetsAt { return resetsAt }
        guard let windowMinutes, windowMinutes > 0 else { return nil }
        return recordedAt.addingTimeInterval(Double(windowMinutes) * 60)
    }
    func expired(now: Date) -> Bool { resetDate.map { $0 <= now } ?? false }
    /// A reset window stays on screen for one day to say "초기화됨", then the row goes away.
    func isShown(now: Date) -> Bool { !expired(now: now) || now.timeIntervalSince(resetDate ?? .distantPast) < 86_400 }
    /// "Claude", not "Claude Code": the window belongs to the Claude account, whichever app used it.
    var title: String {
        let name = source.shortTitle, window = SessionPresentation.windowLabel(windowMinutes)
        return loc("\(name) \(window) 한도", "\(name) \(window) limit")
    }
    /// The number alone ("28"); "%" and " 사용" are drawn smaller beside it. "사용" because Codex's own UI counts what is left.
    var percentText: String { "\(Int(usedPercent.rounded()))" }
    func value(now: Date) -> String { expired(now: now) ? "—" : loc("\(percentText)% 사용", "\(percentText)% used") }
    /// More than 10 minutes since the client reported it: the value is shown weaker.
    func isOld(now: Date) -> Bool { now.timeIntervalSince(recordedAt) > 600 }
    private var waitingText: String {
        let name = source.shortTitle
        return loc("초기화됨 · 다음 \(name) 기록 대기", "Reset · waiting for a \(name) record")
    }
    /// A live read under 2 minutes old: "실시간" replaces the record age.
    func isLive(now: Date) -> Bool { live && now.timeIntervalSince(recordedAt) < LiveLimits.freshness }
    /// Help and VoiceOver wording.
    func detail(now: Date, spoken: Bool = false) -> String {
        if expired(now: now) { return waitingText }
        let age = SessionPresentation.helpAge(recordedAt, now: now, spoken: spoken), live = isLive(now: now)
        guard let resetsAt else { return live ? loc("실시간", "Live") : loc("\(age) 기록 기준", "As of \(age)") }
        let reset = SessionPresentation.countdown(to: resetsAt, now: now, spoken: spoken)
        return loc("\(reset) 후 초기화 · ", "Resets in \(reset) · ") + (live ? loc("실시간", "live") : loc("\(age) 기록 기준", "as of \(age)"))
    }
    /// On-screen variants, widest first; the reset countdown is never the part that is dropped.
    func details(now: Date) -> [String] {
        if expired(now: now) { return [waitingText] }
        let age = SessionPresentation.helpAge(recordedAt, now: now), live = isLive(now: now)
        guard let resetsAt else { return [live ? loc("실시간", "Live") : loc("\(age) 기록", "Recorded \(age)")] }
        let countdown = SessionPresentation.countdown(to: resetsAt, now: now)
        let reset = loc("\(countdown) 후 초기화", "Resets in \(countdown)")
        return [reset + " · " + (live ? loc("실시간", "live") : loc("\(age) 기록", "recorded \(age)")), reset]
    }
    /// "주간 한도 31% 사용 · 3일 4시간 후 초기화" while the other window has not reset.
    func otherText(now: Date, spoken: Bool = false) -> String? {
        guard let other, other.resetsAt > now else { return nil }
        let window = SessionPresentation.windowLabel(other.windowMinutes), percent = Int(other.usedPercent.rounded())
        let reset = SessionPresentation.countdown(to: other.resetsAt, now: now, spoken: spoken)
        return loc("\(window) 한도 \(percent)% 사용 · \(reset) 후 초기화",
                   "\(window.prefix(1).uppercased() + window.dropFirst()) limit \(percent)% used · resets in \(reset)")
    }
    func spoken(now: Date) -> String {
        let main = expired(now: now) ? waitingText.replacingOccurrences(of: " · ", with: ", ")
            : loc("\(percentText)퍼센트 사용", "\(percentText) percent used") + ", " + detail(now: now, spoken: true).replacingOccurrences(of: " · ", with: ", ")
        return main + (otherText(now: now, spoken: true).map { ", " + $0.replacingOccurrences(of: "%", with: loc("퍼센트", " percent")).replacingOccurrences(of: " · ", with: ", ") } ?? "")
    }
    func help(now: Date) -> String {
        let basis = live ? (source == .codex
            ? loc("Codex에 저장된 로그인으로 OpenAI에서 확인한 계정 사용량입니다.", "Account usage checked with OpenAI using Codex's saved sign-in.")
            : loc("Claude Code에 저장된 로그인으로 Anthropic에서 확인한 계정 사용량입니다.", "Account usage checked with Anthropic using Claude Code's saved sign-in."))
            + loc(" 세션이 실행 중이거나 창이 열려 있으면 1분마다, 그 밖에는 10분마다 확인합니다.",
                  " It's checked every minute while a session runs or this window is open, otherwise every 10 minutes.")
            : source == .codex ? loc("Codex 로그에 마지막으로 기록된 계정 사용량입니다. 실시간 잔여량이 아니며 Codex를 사용할 때만 갱신됩니다.",
                                           "The last account usage recorded in the Codex logs. It isn't a live balance and updates only while you use Codex.")
            : loc("Claude Code가 상태 표시줄로 보냈거나 Claude 데스크톱 앱이 기록한 마지막 Claude 계정 사용량입니다. 실시간 잔여량이 아니며 Claude를 사용할 때만 갱신됩니다.",
                  "The last Claude account usage sent by Claude Code to its status line or recorded by the Claude desktop app. It isn't a live balance and updates only while you use Claude.")
        return basis + loc(" 소진 시점을 예측하지 않습니다.", " TokenCat doesn't predict when you'll reach it.") + (otherText(now: now).map { "\n" + $0 } ?? "")
    }
}

/// Why the footer warns about telemetry; copy stays short enough for the 388 pt footer.
struct TelemetryNotice: Equatable {
    enum Kind { case portBusy, busy, collector, conflict, failed, off, expired, restart }
    var kind: Kind
    var text: String
    var help: String
    var isProblem: Bool { kind != .restart }
    /// The collector itself is not running, so no client config was touched.
    var collectorDown: Bool { [.portBusy, .busy, .collector, .off].contains(kind) }
}

/// The popover header sentence (H-2): the one place that summarises session state.
struct HeaderStatus: Equatable {
    var sentence: String
    var suffix: String
    var glyph: StateGlyph.Kind?
    /// "기록 확인 중": the sentence itself is secondary.
    var muted = false
    var head: RunnerHead = .normal
    var help: String
    var spoken: String { sentence + suffix }
}

/// The flow card's caption slot above the last-record value (F-2).
struct FlowCaption: Equatable {
    var text: String
    var glyph: StateGlyph.Kind?
    /// Input and retry captions are primary; the rest stay secondary.
    var emphasized = false
    var help: String
}

/// The footer's single leading item (9), by priority.
struct FooterStatus: Equatable {
    enum Kind: Equatable { case loading, aiDelay, systemDelay, notice, live }
    var kind: Kind
    var text: String
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
        // A fresh output record is an event shown by the hero dot, the row's last-record line and the cat's run.
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
        // Sorting indices moves Ints, not whole TokenReadings.
        let sorted = tokens.indices.sorted { tokens[$0].id < tokens[$1].id }.map { tokens[$0] }
        for reading in sorted where isTelemetry(reading) || !reading.isSubagent {
            groups.append(SessionGroup(lead: SessionMember(reading: reading, state: displayState(reading, now: now))))
            guard !isTelemetry(reading), let key = key(reading.source, reading.sessionID) else { continue }
            if let existing = parentIndex[key],
               (groups[existing].lead.reading.lastActivity ?? .distantPast) >= (reading.lastActivity ?? .distantPast) { continue }
            parentIndex[key] = groups.count - 1
        }
        for reading in sorted where !isTelemetry(reading) && reading.isSubagent {
            let member = SessionMember(reading: reading, state: displayState(reading, now: now))
            if let key = key(reading.source, reading.parentSessionID ?? reading.sessionID), let index = parentIndex[key] {
                groups[index].children.append(member)
            } else {
                groups.append(SessionGroup(lead: member))
            }
        }
        // A lead quiet past its allowance while a subagent still runs is waiting on that subagent (a long Agent call).
        for i in groups.indices where [.waiting, .unfinished].contains(groups[i].lead.state)
            && groups[i].children.contains(where: { $0.state.isRunning }) {
            groups[i].lead.state = .tool
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
        return ["guardian", "guardian_review"].contains(role) ? loc("자동 검토", "Auto review") : role
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

    /// A live row's second line, one text with one separator: "Claude Code · claude-opus-5-5 · xhigh".
    static func clientLine(_ reading: TokenReading) -> String {
        [reading.clientTitle, reading.model ?? loc("모델 기록 대기", "waiting for model"), effortLabel(reading)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Raw client value, lowercased and never translated.
    static func effortLabel(_ reading: TokenReading) -> String? {
        guard let effort = reading.effort?.trimmingCharacters(in: .whitespaces), !effort.isEmpty else { return nil }
        return effort.lowercased()
    }

    static func toolTitle(_ category: ToolCategory?) -> String {
        switch category {
        case .command: return loc("명령 실행", "Running command")
        case .file: return loc("파일 작업", "File operation")
        case .web: return loc("웹 조회", "Web lookup")
        case .agent: return loc("하위 에이전트 대기", "Waiting for subagent")
        case .mcp: return loc("MCP 도구 실행", "MCP tool")
        case .question: return loc("입력 요청", "Input request")
        case .other, nil: return loc("도구 실행", "Running tool")
        }
    }

    /// The tool category replaces the generic "도구 실행".
    static func stateTitle(_ state: SessionDisplayState, _ reading: TokenReading) -> String {
        state == .tool ? toolTitle(reading.toolCategory) : state.title
    }

    /// A live row's chip: tool category, input kind, or the state. Retry progress stays on line 2.
    static func chipText(_ state: SessionDisplayState, _ reading: TokenReading) -> String {
        state == .input ? inputTitle(reading) : stateTitle(state, reading)
    }

    static func isPlanApproval(_ reading: TokenReading) -> Bool { reading.toolName == "ExitPlanMode" }

    static func inputTitle(_ reading: TokenReading) -> String {
        isPlanApproval(reading) ? loc("계획 승인 대기", "Waiting for plan approval") : loc("질문 답변 대기", "Waiting for an answer")
    }

    /// An idle lead row standing in for its live children.
    static func childGroupText(_ state: SessionDisplayState, count: Int) -> String {
        let children = plural(count, "subagent")
        switch state {
        case .input: return loc("하위 \(count)개 입력 필요", "\(children) \(count == 1 ? "needs" : "need") input")
        case .retrying: return loc("하위 \(count)개 API 재시도", "\(children) in API retry")
        default: return loc("하위 \(count)개 \(state.isRunning ? "진행 중" : "로그 대기")", "\(children) \(state.isRunning ? "working" : "waiting for log")")
        }
    }

    /// VoiceOver row label (P-3): "<상태>, <프로젝트>, <클라이언트> <모델>"; subagents "하위 에이전트 <제목>, <상태>".
    static func spokenLabel(_ reading: TokenReading, state: SessionDisplayState) -> String {
        let word = stateTitle(state, reading)
        if reading.isSubagent { return loc("하위 에이전트 \(childTitle(reading).title), \(word)", "Subagent \(childTitle(reading).title), \(word)") }
        return "\(word), \(reading.project ?? loc("프로젝트 미확인", "Unknown project")), \(reading.clientTitle) \(reading.model ?? loc("모델 미확인", "unknown model"))"
    }

    /// "재시도 2/10 · 4초 후" / "Retry 2/10 · in 4s"; `api` starts it "API 재시도" / "API retry".
    static func retryText(_ retry: TokenRetryState, now: Date, api: Bool = false, spoken: Bool = false) -> String {
        let attempts = retry.maxAttempts.map { "\(retry.attempt)/\($0)" } ?? loc("\(retry.attempt)회째", "#\(retry.attempt)")
        let head = (api ? loc("API 재시도", "API retry") : loc("재시도", "Retry")) + " \(attempts) · "
        if retry.networkDown { return head + loc("네트워크 끊김", "network down") }
        guard let at = retry.retryAt, at > now else { return head + loc("재요청 중", "retrying now") }
        let seconds = Int(ceil(at.timeIntervalSince(now)))
        return head + Format.later(seconds >= 60 ? Format.span(seconds / 60, .minute, spoken: spoken) : Format.span(seconds, .second, spoken: spoken))
    }

    /// Shared with the views, which mark a record this fresh.
    static var justNow: String { loc("방금", "just now") }
    /// The flow card's default caption; the views compare against it.
    static var lastRecordCaption: String { loc("마지막 기록", "Last record") }

    /// Output ages on rows and the flow card: "방금" / "just now" under 10 s, then 10 s steps, then `Format.age`.
    static func recordAge(_ date: Date, now: Date, spoken: Bool = false) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return justNow }
        if seconds < 60 { return Format.ago(Format.span(seconds / 10 * 10, .second, spoken: spoken)) }
        return Format.age(date, now: now, spoken: spoken)
    }

    /// The current turn's last output record for a row's third line; nil when it belongs to an earlier turn.
    static func lastRecord(_ reading: TokenReading) -> TokenOutputEvent? {
        guard let at = reading.lastOutputAt, let tokens = reading.lastOutputDelta, tokens > 0 else { return nil }
        if let start = reading.currentTurnStartedAt, at < start { return nil }
        return TokenOutputEvent(at: at, tokens: tokens)
    }

    static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -FlowSeries.futureTolerance && age <= FlowSeries.freshSeconds
    }

    static let compactionWindow: TimeInterval = 1_800

    static func context(_ reading: TokenReading, now: Date) -> ContextSlot? {
        guard let context = reading.context, context.usedTokens > 0 else { return nil }
        let source = reading.clientTitle
        var help: String
        let slot: (text: String, short: String, fraction: Double?, warning: Bool, spoken: String)
        if let window = context.windowTokens, window > 0 {
            let percent = Int((Double(context.usedTokens) / Double(window) * 100).rounded())
            slot = (loc("컨텍스트 \(percent)% 사용", "Context \(percent)% used"), "\(percent)%", min(1, Double(context.usedTokens) / Double(window)),
                    percent >= 85, loc("컨텍스트 \(percent)퍼센트 사용", "Context \(percent) percent used"))
            help = loc("마지막 요청 입력 \(Format.tokens(context.usedTokens)) / 모델 컨텍스트 \(Format.tokens(window)) tok (\(source) 기록)",
                       "Last request input \(Format.tokens(context.usedTokens)) / model context \(Format.tokens(window)) tok (recorded by \(source))")
        } else {
            let used = context.usedTokens
            let short = used < 1_000 ? String(used) : (used < 999_500 ? "\(Int((Double(used) / 1_000).rounded()))k" : Format.compactTokens(used))
            slot = (loc("컨텍스트 \(short)", "Context \(short)"), short, nil, false, loc("컨텍스트 \(used) 토큰", "Context \(used) tokens"))
            help = loc("마지막 요청 입력 \(Format.tokens(context.usedTokens)) tok (입력·캐시 합계)\n\(source)는 컨텍스트 창 크기를 기록하지 않아 비율을 표시하지 않습니다",
                       "Last request input \(Format.tokens(context.usedTokens)) tok (input and cache)\n\(source) doesn't record the context window size, so no percentage is shown")
        }
        help += loc("\n출력 토큰 제외 · \(helpAge(context.recordedAt, now: now)) 기록", "\nExcludes output tokens · recorded \(helpAge(context.recordedAt, now: now))")
        var compacted: String?
        if let at = context.compactedAt {
            help += loc("\n압축 완료 기록 \(helpAge(at, now: now))", "\nCompaction recorded \(helpAge(at, now: now))")
            let age = now.timeIntervalSince(at)
            if age >= -FlowSeries.futureTolerance && age < compactionWindow { compacted = loc("압축 \(Format.age(at, now: now))", "Compacted \(Format.age(at, now: now))") }
        }
        return ContextSlot(text: slot.text, short: slot.short, fraction: slot.fraction, warning: slot.warning, compacted: compacted,
                           help: help, spoken: slot.spoken)
    }

    /// A completed turn's output and the client's own duration, side by side and never divided.
    static func lastTurnSummary(_ reading: TokenReading) -> String? {
        guard let output = reading.lastOutputTokens else { return nil }
        guard let seconds = reading.lastTurnDurationSeconds, seconds.isFinite, seconds >= 0 else {
            return loc("마지막 출력 기록 \(Format.tokens(output)) tok", "Last output record: \(Format.tokens(output)) tok")
        }
        let took = clock(Int(seconds.rounded()))
        return loc("마지막 완료 턴 출력 \(Format.tokens(output)) tok · 소요 \(took)", "Last completed turn: \(Format.tokens(output)) tok · took \(took)")
    }

    static func clock(_ seconds: Int) -> String {
        seconds >= 3_600 ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Minute-granular age for help text, so tooltips do not change every second.
    static func helpAge(_ date: Date?, now: Date, spoken: Bool = false) -> String {
        guard let date, now.timeIntervalSince(date) < 60 else { return Format.age(date, now: now, spoken: spoken) }
        return loc("1분 이내", spoken ? "less than a minute ago" : "<1m ago")
    }

    /// Time left, minute-granular: "2시간 13분" / "2h 13m", "5일 11시간" / "5d 11h", "1분 이내" / "<1m".
    static func countdown(to date: Date, now: Date, spoken: Bool = false) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now)) / 60)
        func pair(_ big: Int, _ bigUnit: Format.TimeUnit, _ small: Int, _ smallUnit: Format.TimeUnit) -> String {
            Format.span(big, bigUnit, spoken: spoken) + (small > 0 ? " " + Format.span(small, smallUnit, spoken: spoken) : "")
        }
        if minutes >= 1_440 { return pair(minutes / 1_440, .day, minutes % 1_440 / 60, .hour) }
        if minutes >= 60 { return pair(minutes / 60, .hour, minutes % 60, .minute) }
        return minutes > 0 ? Format.span(minutes, .minute, spoken: spoken) : loc("1분 이내", spoken ? "less than a minute" : "<1m")
    }

    static func windowLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return loc("사용", "usage") }
        switch minutes {
        case 300: return loc("5시간", "5-hour")
        case 10_080: return loc("주간", "weekly")
        case 43_200, 43_800: return loc("월간", "monthly")
        default:
            if minutes % 1_440 == 0 { return loc("\(minutes / 1_440)일", "\(minutes / 1_440)-day") }
            return minutes % 60 == 0 ? loc("\(minutes / 60)시간", "\(minutes / 60)-hour") : loc("\(minutes)분", "\(minutes)-minute")
        }
    }

    /// Replay-proof per window length: the newest reset wins, then the highest percentage inside it. Across windows (each
    /// session logs only its fuller one), the higher use among those not reset wins like Claude's; all reset, the latest.
    /// Without any reset time the windows cannot be told apart, so only the newest record counts.
    /// `live`: the windows of the newest live read, weighed with the log records like one more session.
    static func usageLimit(_ tokens: [TokenReading], live reads: [TokenRateLimit] = [], now: Date) -> UsageLimitSummary? {
        // Live reads last: past 2 minutes old they lose a tie to a later record of the same value.
        let limits = (tokens.filter { $0.source == .codex }.compactMap(\.rateLimit) + reads).filter { $0.usedPercent.isFinite }
        guard let newest = limits.map({ $0.resetsAt ?? .distantPast }).max() else { return nil }
        if newest == .distantPast, let last = limits.max(by: { $0.recordedAt < $1.recordedAt }) {
            return UsageLimitSummary(usedPercent: last.usedPercent, windowMinutes: last.windowMinutes, resetsAt: nil, recordedAt: last.recordedAt,
                                     live: last.live == true)
        }
        // A live read overrides older records of its window; under 2 minutes old it also wins a tie with a later record
        // of the same value, so the row keeps "실시간".
        func fresh(_ limit: TokenRateLimit) -> Int { limit.live == true && now.timeIntervalSince(limit.recordedAt) < LiveLimits.freshness ? 1 : 0 }
        let windows = Dictionary(grouping: limits.filter { $0.resetsAt != nil }, by: \.windowMinutes).values.compactMap { group -> UsageLimitSummary? in
            guard let newest = group.compactMap(\.resetsAt).max() else { return nil }
            var window = group.filter { abs(($0.resetsAt ?? .distantPast).timeIntervalSince(newest)) <= 60 }
            if let read = window.filter({ $0.live == true }).map(\.recordedAt).max() { window = window.filter { $0.recordedAt >= read } }
            guard let top = window.max(by: { ($0.usedPercent, fresh($0)) < ($1.usedPercent, fresh($1)) }) else { return nil }
            let recordedAt = top.live == true ? top.recordedAt : window.map(\.recordedAt).max() ?? top.recordedAt
            return UsageLimitSummary(usedPercent: top.usedPercent, windowMinutes: top.windowMinutes, resetsAt: top.resetsAt,
                                     recordedAt: recordedAt, live: top.live == true)
        }
        let live = windows.filter { ($0.resetsAt ?? .distantPast) > now }
        return live.max { ($0.usedPercent, $0.windowMinutes ?? 0) < ($1.usedPercent, $1.windowMinutes ?? 0) }
            ?? windows.max { ($0.resetsAt ?? .distantPast, $0.windowMinutes ?? 0) < ($1.resetsAt ?? .distantPast, $1.windowMinutes ?? 0) }
    }

    /// Claude's two windows reduced like Codex's: the higher use among windows that have not reset (a tie goes to the
    /// longer window), the other one named in help; when both have reset, the latest reset reads "초기화됨" for a day.
    static func claudeUsageLimit(_ limits: ClaudeUsageLimits, now: Date) -> UsageLimitSummary? {
        let windows = [(limits.fiveHour, 300), (limits.sevenDay, 10_080)].compactMap { window, minutes in window.map { ($0, minutes) } }
        // Without a reset time (the desktop app), one full window after the record, as `UsageLimitSummary.resetDate`.
        func reset(_ window: (ClaudeLimitWindow, Int)) -> Date { window.0.resetsAt ?? window.0.receivedAt.addingTimeInterval(Double(window.1) * 60) }
        let live = windows.filter { reset($0) > now }
        let top = live.max { ($0.0.usedPercent, $0.1) < ($1.0.usedPercent, $1.1) } ?? windows.max { reset($0) < reset($1) }
        guard let top else { return nil }
        let other = live.first { $0.1 != top.1 }.flatMap { window in
            window.0.resetsAt.map { UsageLimitSummary.OtherWindow(usedPercent: window.0.usedPercent, windowMinutes: window.1, resetsAt: $0) }
        }
        return UsageLimitSummary(usedPercent: top.0.usedPercent, windowMinutes: top.1, resetsAt: top.0.resetsAt,
                                 recordedAt: top.0.receivedAt, source: .claude, other: other, live: top.0.live == true)
    }

    /// The flow card's "지금 속도": the newest measurement under 2 minutes old among visible live rows (leads and
    /// subagents), on the row's current model and from a client not waiting for a restart; one session's own value,
    /// never summed or averaged. Without one it is "—" while a turn is in progress (API retry, tool or working: a rate
    /// could be expected and its absence is the news), and nil while sessions only wait for the person or a log, or
    /// nothing runs (no generation to measure, so no placeholder).
    static func speedHeadline(_ list: SessionListModel, now: Date, restart: Set<TokenSource>) -> SpeedHeadline? {
        let rows = speedRows(list)
        guard let newest = currentSpeed(list, now: now, restart: restart) else {
            guard rows.contains(where: { $0.state.expectsSpeed }) else { return nil }
            let sources = TokenSource.allCases.filter { source in rows.contains { $0.reading.source == source } }
            let waiting = sources.filter(restart.contains)
            let names = waiting.map(\.title).joined(separator: loc("·", " and "))
            // A fresh measurement left out only for its model says so, rather than that none arrived.
            let previous = rows.compactMap { row -> TokenSpeedMeasurement? in
                guard !restart.contains(row.reading.source), let measurement = row.reading.speedMeasurement, measurement.tokensPerSecond != nil,
                      measurement.model != row.reading.model else { return nil }
                let age = now.timeIntervalSince(measurement.at)
                return age >= -5 && age < 120 ? measurement : nil
            }.max { $0.at < $1.at }
            let reason = previous.map { measurement in
                loc("최근 실측은 이전 모델\(measurement.model.map { "(\($0))" } ?? "") 기준이라 지금 속도로 쓰지 않습니다",
                    "The latest measurement is from the previous model\(measurement.model.map { " (\($0))" } ?? ""), so it isn't used as the current speed")
            } ?? loc("진행 중인 세션의 최근 2분 실측 없음 · 로그 시각으로 추정하지 않습니다",
                     "No measurement from active sessions in the last 2 min · not estimated from log times")
            let help = waiting.count == sources.count ? loc("실측 연결됨 · \(names)를 새로 실행하면 속도가 표시됩니다", "Telemetry connected · restart \(names) to show speed")
                : reason + (waiting.isEmpty ? "" : loc("\n\(names)를 새로 실행하면 속도가 표시됩니다", "\nRestart \(names) to show speed"))
            return SpeedHeadline(value: "—", kind: nil, project: nil, help: help, spoken: loc("속도 실측 없음", "No measured speed"))
        }
        let reading = newest.row.reading
        let project = reading.project ?? loc("프로젝트 미확인", "Unknown project")
        let session = [project, reading.isSubagent ? loc("하위 ", "subagent ") + childTitle(reading).title : nil,
                       reading.clientTitle + (reading.model.map { " " + $0 } ?? "")].compactMap { $0 }.joined(separator: " · ")
        let value = Format.tps(newest.rate), age = helpAge(newest.measurement.at, now: now)
        return SpeedHeadline(value: value, kind: newest.measurement.kind?.title ?? "tok/s", project: project,
                             help: loc("\(session) · 측정 \(age)\n\(newest.measurement.details)\n가장 최근 실측 한 건이며 세션끼리 합치거나 평균내지 않습니다",
                                       "\(session) · measured \(age)\n\(newest.measurement.details)\nThe single latest measurement; sessions are never summed or averaged"),
                             spoken: loc("\(spokenKind(newest.measurement.kind)) 초당 \(value) 토큰, \(project)",
                                         "\(spokenKind(newest.measurement.kind)) \(value) tokens per second, \(project)"))
    }

    /// Visible live rows: leads and subagents.
    private static func speedRows(_ list: SessionListModel) -> [SessionRowItem] {
        list.blocks.flatMap { block in (block.lead.kind == .live ? [block.lead] : []) + block.children.filter { $0.state.isLive } }
    }

    /// Measured rates fresh enough to call current: telemetry for the row's own model, from the last 2 minutes, and not
    /// from a client that must restart to report it.
    private static func freshSpeeds(_ list: SessionListModel, now: Date, restart: Set<TokenSource>)
        -> [(row: SessionRowItem, measurement: TokenSpeedMeasurement, rate: Double)] {
        speedRows(list).compactMap { row in
            guard !restart.contains(row.reading.source),
                  let measurement = row.reading.speedMeasurement, let rate = measurement.tokensPerSecond,
                  measurement.model == row.reading.model else { return nil }
            let age = now.timeIntervalSince(measurement.at)
            return age >= -5 && age < 120 ? (row, measurement, rate) : nil
        }
    }

    /// "지금 속도"'s pick (`speedHeadline`).
    static func currentSpeed(_ list: SessionListModel, now: Date, restart: Set<TokenSource>)
        -> (row: SessionRowItem, measurement: TokenSpeedMeasurement, rate: Double)? {
        freshSpeeds(list, now: now, restart: restart)
            .max { a, b in a.measurement.at != b.measurement.at ? a.measurement.at < b.measurement.at : a.row.id > b.row.id }
    }

    /// The menu bar's opt-in "평균 속도": the arithmetic mean of every client's fresh per-session rates (same rule as
    /// `currentSpeed`) and the clients they came from, nil without one. Only measured rates are averaged; nothing is estimated.
    static func averageSpeed(_ list: SessionListModel, now: Date, restart: Set<TokenSource>) -> AverageSpeed? {
        let fresh = freshSpeeds(list, now: now, restart: restart)
        guard !fresh.isEmpty else { return nil }
        let bySource = Dictionary(grouping: fresh, by: { $0.row.reading.source }).mapValues { rows in
            rows.map(\.rate).reduce(0, +) / Double(rows.count)
        }
        let order = TokenSource.allCases
        let sources = bySource.sorted { a, b in
            a.value != b.value ? a.value > b.value : order.firstIndex(of: a.key)! < order.firstIndex(of: b.key)!
        }.map(\.key)
        return AverageSpeed(rate: fresh.map(\.rate).reduce(0, +) / Double(fresh.count), sources: sources)
    }

    static func spokenKind(_ kind: TokenRateKind?) -> String {
        switch kind {
        case .serverGeneration: return loc("생성 속도", "Generation speed")
        case .serverAggregate: return loc("모델 평균 속도", "Model average speed")
        default: return loc("요청 처리 속도", "Request processing rate")
        }
    }

    /// Only exact-identity telemetry; never a speed derived from log timing.
    static func speed(_ reading: TokenReading, now: Date, restartNeeded: Bool = false) -> SpeedSlot {
        guard let measurement = reading.speedMeasurement, let rate = measurement.tokensPerSecond else {
            let help = restartNeeded ? loc("실측 연결됨 · \(reading.source.title)를 새로 실행하면 속도가 표시됩니다",
                                           "Telemetry connected · restart \(reading.source.title) to show speed")
                : loc("속도 실측 없음 · 로그 시각으로 추정하지 않습니다", "No measured speed · not estimated from log times")
            return SpeedSlot(prefix: nil, value: "—", kind: nil, recent: false, help: help, spoken: loc("속도 실측 없음", "No measured speed"))
        }
        let kind = measurement.kind?.title ?? "tok/s"
        let spoken = loc("\(spokenKind(measurement.kind)) 초당 \(Format.tps(rate)) 토큰", "\(spokenKind(measurement.kind)) \(Format.tps(rate)) tokens per second")
        if measurement.model != reading.model {
            let model = measurement.model ?? loc("미확인", "unknown"), age = helpAge(measurement.at, now: now)
            return SpeedSlot(prefix: loc("이전", "previous"), value: Format.tps(rate), kind: kind, recent: false,
                             help: loc("이전 실측 모델 \(model) · 측정 \(age)", "Previously measured model \(model) · measured \(age)"),
                             spoken: loc("이전 모델 ", "Previous model, ") + spoken)
        }
        let age = now.timeIntervalSince(measurement.at)
        return SpeedSlot(prefix: nil, value: Format.tps(rate), kind: kind, recent: age >= -5 && age < 120,
                         help: measurement.details, spoken: spoken)
    }

    /// A live row's speed cell: none without a speed column or while its client waits for a restart, and "—" only where
    /// a speed is expected (working, tool, API retry): a row waiting for the person or a log shows a measured value or
    /// nothing. The row's VoiceOver value says "속도 실측 없음" by the same state rule.
    static func speedCell(_ reading: TokenReading, state: SessionDisplayState, now: Date, showsColumn: Bool,
                          restart: Set<TokenSource>) -> SpeedSlot? {
        guard showsColumn, !restart.contains(reading.source) else { return nil }
        let slot = speed(reading, now: now)
        return slot.known || state.expectsSpeed ? slot : nil
    }

    /// Spoken elapsed time: seconds under a minute, then minutes ("4분"), then hours and minutes.
    /// VoiceOver: "1시간 5분" / "1 hour 5 minutes".
    static func spokenDuration(_ start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3_600 { return Format.span(seconds / 3_600, .hour, spoken: true) + " " + Format.span(seconds / 60 % 60, .minute, spoken: true) }
        return seconds >= 60 ? Format.span(seconds / 60, .minute, spoken: true) : Format.span(seconds, .second, spoken: true)
    }

    // MARK: Header, flow caption, footer

    /// Minutes of quiet after which the header head sleeps.
    static let sleepAfter: TimeInterval = 600

    /// The header sentence (H-2) and head echo (H-3) from the shared counts.
    /// `quietSince` is the menu-bar cat's quiet reference (`RunnerDirector.quietSince`); without it the newest activity is used.
    /// `spoken` spells English spans out for VoiceOver.
    static func headerStatus(counts: SessionCounts, loading: Bool, now: Date, quietSince: Date? = nil, spoken: Bool = false) -> HeaderStatus {
        if loading {
            return HeaderStatus(sentence: loc("기록 확인 중", "Reading records"), suffix: "", glyph: nil, muted: true,
                                help: loc("코딩 에이전트 기록을 읽고 있습니다", "Reading coding agent records"))
        }
        let tools = [ToolCategory.command, .file, .web, .agent, .mcp, .question, .other].compactMap { category -> String? in
            guard let n = counts.toolCategories[category], n > 0 else { return nil }
            return "\(toolTitle(category)) \(n)"
        }
        let breakdown = tools.isEmpty ? "" : loc("\n하위 에이전트 포함 ", "\nIncluding subagents: ") + tools.joined(separator: " · ")
        let others = counts.runningGroups - counts.input
        if counts.input > 0 {
            let plans = counts.inputPlansOnly, n = counts.input
            return HeaderStatus(sentence: loc((plans ? "계획 승인 대기 " : "입력 필요 ") + "\(n)개",
                                              plans ? "\(plural(n, "plan")) awaiting approval" : "\(plural(n, "session")) \(n == 1 ? "needs" : "need") input"),
                                suffix: others > 0 ? loc(" · 진행 \(others)개", " · \(others) working")
                                    : (plans ? loc(" · 승인하면 계속됩니다", " · approve to continue") : loc(" · 답변하면 계속됩니다", " · reply to continue")),
                                glyph: .input, head: .alert,
                                help: loc("질문이나 계획 승인을 기다립니다. 권한 확인 요청은 로그에 남지 않아 표시하지 않습니다",
                                          "Waiting for an answer or plan approval. Permission prompts aren't logged, so they aren't shown") + breakdown)
        }
        if counts.retrying > 0 {
            return HeaderStatus(sentence: loc("API 재시도 \(counts.retrying)개", "\(plural(counts.retrying, "session")) retrying"),
                                suffix: counts.retry.map { " · " + retryText($0, now: now, spoken: spoken) } ?? "",
                                glyph: .retry, help: loc("API 재시도 기록 · 오류 내용은 저장하지 않습니다", "API retry recorded · error details aren't stored") + breakdown)
        }
        if counts.tool + counts.working > 0 {
            let parts = [counts.toolMembers > 0 ? loc("도구 실행 \(counts.toolMembers)", plural(counts.toolMembers, "tool")) : nil,
                         counts.runningSubagents > 0 ? loc("하위 \(counts.runningSubagents)", plural(counts.runningSubagents, "subagent")) : nil].compactMap { $0 }
            return HeaderStatus(sentence: loc("세션 \(counts.runningGroups)개 진행 중", "\(plural(counts.runningGroups, "session")) working"),
                                suffix: parts.map { " · " + $0 }.joined(),
                                glyph: counts.tool > 0 ? .tool : .working,
                                help: loc("진행 중인 세션 \(counts.runningGroups)개 · 하위 에이전트 \(counts.runningSubagents)개 실행 중",
                                          "\(plural(counts.runningGroups, "active session")) · \(plural(counts.runningSubagents, "subagent")) running") + breakdown)
        }
        if counts.waiting > 0 {
            let minutes = counts.waitingSince.map { max(1, Int(now.timeIntervalSince($0)) / 60) } ?? 1
            return HeaderStatus(sentence: loc("로그 대기 \(counts.waiting)개", "\(plural(counts.waiting, "session")) waiting for log"),
                                suffix: loc(" · \(minutes)분째 새 기록 없음", " · no record for \(Format.span(minutes, .minute, spoken: spoken))"), glyph: .waiting,
                                help: loc("턴이 열려 있지만 새 기록이 없습니다. 도구나 모델 응답을 기다리는 중일 수 있습니다",
                                          "The turn is open but nothing new has been recorded. It may be waiting for a tool or the model"))
        }
        let quiet = (quietSince ?? counts.newestActivity).map { now.timeIntervalSince($0) >= sleepAfter } ?? true
        return HeaderStatus(sentence: loc("진행 중인 세션 없음", "No active sessions"),
                            suffix: counts.newestActivity.map { loc(" · 마지막 활동 ", " · last activity ") + helpAge($0, now: now, spoken: spoken) } ?? "",
                            glyph: nil, head: quiet ? .sleep : .normal, help: loc("진행 중인 코딩 에이전트 세션이 없습니다", "No active coding agent sessions"))
    }

    /// The flow card's per-client split, widest first: "Claude Code 6.6k · Codex 1.2k · OpenCode 300", then the smallest
    /// folding into "+N" down to the largest alone; one client is its name only (never the hero number again). The card
    /// shows the first candidate that fits beside "지금 속도", so four or more clients never spill past it.
    static func providerSplits(_ byProvider: [TokenSource: Int]) -> [String] {
        let parts = TokenSource.allCases.compactMap { source -> (TokenSource, Int)? in
            guard let value = byProvider[source], value > 0 else { return nil }
            return (source, value)
        }.sorted { $0.1 > $1.1 }
        guard parts.count > 1 else { return [parts.first?.0.title ?? ""] }
        return (1...parts.count).reversed().map { shown in
            parts.prefix(shown).map { "\($0.0.title) \(Format.compactTokens($0.1))" }.joined(separator: " · ")
                + (shown < parts.count ? " · +\(parts.count - shown)" : "")
        }
    }

    /// The caption over the last-record value (F-2): why nothing new is recorded, after 30 s without a record.
    static func flowCaption(counts: SessionCounts, last: Date?, now: Date, spoken: Bool = false) -> FlowCaption {
        let base = FlowCaption(text: lastRecordCaption, help: loc("최근 5분 안에 로그에 기록된 마지막 출력입니다", "The latest output recorded in the logs within the last 5 min"))
        guard counts.liveGroups > 0 else { return base }
        if let last, now.timeIntervalSince(last) <= 30 { return base }
        let help = loc("응답이 끝나면 토큰이 기록됩니다. 코딩 에이전트는 응답이나 메시지가 끝날 때 기록하므로 생성 중인 토큰은 아직 포함되지 않습니다",
                       "Tokens are recorded when a response ends. Coding agents record at the end of a response or message, so tokens still being generated aren't included yet")
        if counts.input > 0 {
            return FlowCaption(text: counts.inputPlansOnly ? loc("계획 승인 대기 · 승인하면 계속 기록", "Plan approval · approve to resume")
                                   : loc("입력 대기 · 답변하면 계속 기록", "Waiting for input · reply to resume"),
                               glyph: .input, emphasized: true, help: help)
        }
        if counts.retrying > 0 {
            let text = counts.retry.map { $0.networkDown ? loc("API 재시도 · 네트워크 끊김", "API retry · network down") : retryText($0, now: now, api: true, spoken: spoken) }
                ?? loc("API 재시도", "API retry")
            return FlowCaption(text: text, glyph: .retry, emphasized: true, help: help)
        }
        if counts.tool > 0 {
            let tool = toolTitle(counts.leadingToolCategory)
            return FlowCaption(text: loc("\(tool) 중 · 응답 후 기록", "\(tool) · logged after reply"), help: help)
        }
        if counts.working > 0 { return FlowCaption(text: loc("진행 중 · 응답 후 기록", "Working · logged after reply"), help: help) }
        let minutes = counts.waitingSince.map { max(1, Int(now.timeIntervalSince($0)) / 60) } ?? 1
        return FlowCaption(text: loc("로그 대기 · \(minutes)분째 기록 없음", "Waiting for log · no record for \(Format.span(minutes, .minute, spoken: spoken))"), help: help)
    }

    /// Cause-specific copy from the collector state, the setup note and pending or expired restarts.
    /// `status` is the collector's own sentence, used only as help text.
    static func telemetryNotice(state: TelemetryCollectorState, status: String? = nil, note: String?, failure: TelemetrySetupFailure? = nil,
                                restart: Set<TokenSource>, expired: Set<TokenSource> = []) -> TelemetryNotice? {
        let open = loc("\n누르면 설정을 엽니다", "\nClick to open Settings")
        func names(_ sources: Set<TokenSource>) -> String { TokenSource.allCases.filter(sources.contains).map(\.title).joined(separator: loc("·", " and ")) }
        switch state {
        case .busyTokenCat:
            return TelemetryNotice(kind: .busy, text: loc("실측 꺼짐 · 다른 TokenCat", "Telemetry off · another TokenCat"),
                                   help: loc("다른 TokenCat이 이미 실측을 수집하고 있어 이 TokenCat은 실측을 받지 않습니다. 하나만 실행하세요.",
                                             "Another TokenCat is already collecting telemetry, so this one doesn't receive it. Run only one.") + open)
        case .busyOtherApp:
            return TelemetryNotice(kind: .portBusy, text: loc("실측 꺼짐 · 포트 사용 중", "Telemetry off · port in use"),
                                   help: loc("로컬 실측 수집기가 127.0.0.1:\(TelemetrySetup.port) 포트를 열지 못했습니다. 다른 앱이 포트를 쓰고 있을 수 있습니다.",
                                             "The local telemetry collector couldn't open port 127.0.0.1:\(TelemetrySetup.port). Another app may be using it.") + open)
        case .failed:
            return TelemetryNotice(kind: .collector, text: loc("실측 꺼짐 · 수집기 오류", "Telemetry off · collector error"), help: (status ?? state.status) + open)
        case .stopped:
            return TelemetryNotice(kind: .off, text: loc("실측 꺼짐", "Telemetry off"), help: (status ?? state.status) + open)
        case .starting, .waiting, .receiving:
            break
        }
        if let note {
            let conflict = failure == .conflict
            return TelemetryNotice(kind: conflict ? .conflict : .failed,
                                   text: conflict ? loc("실측 꺼짐 · 설정 충돌", "Telemetry off · config conflict") : loc("실측 꺼짐 · 연결 실패", "Telemetry off · connection failed"),
                                   help: note + open)
        }
        if !expired.isEmpty {
            return TelemetryNotice(kind: .expired, text: loc("실측 미수신 · 확인 필요", "No telemetry · check needed"),
                                   help: loc("\(names(expired)): 이 버전에서 실측을 받지 못했습니다. 새로 실행한 뒤에도 그대로면 설정에서 연결 상태를 확인하세요.",
                                             "\(names(expired)): no telemetry received with this version. If it's still missing after a restart, check the connection in Settings.") + open)
        }
        guard !restart.isEmpty else { return nil }
        return TelemetryNotice(kind: .restart, text: loc("\(names(restart)) 재시작 후 속도 표시", "Restart \(names(restart)) for speed"),
                               help: loc("\(names(restart))를 새로 실행하면 속도가 표시됩니다. 진행 중인 작업은 재시작하지 않습니다.",
                                         "Restart \(names(restart)) to show speed. TokenCat doesn't restart running work.") + open)
    }

    /// One footer item: collection delay first, then the telemetry notice, then "실시간".
    static func footerStatus(loading: Bool, tokenDelay: Int, systemDelay: Int, notice: TelemetryNotice?) -> FooterStatus {
        if loading { return FooterStatus(kind: .loading, text: loc("준비 중", "Preparing")) }
        if tokenDelay > 3 {
            return FooterStatus(kind: .aiDelay, text: loc("AI 수집 지연 \(tokenDelay)초", "AI collection delayed \(Format.span(tokenDelay, .second))"))
        }
        if systemDelay > 3 {
            return FooterStatus(kind: .systemDelay, text: loc("시스템 수집 지연 \(systemDelay)초", "System collection delayed \(Format.span(systemDelay, .second))"))
        }
        if let notice { return FooterStatus(kind: .notice, text: notice.text) }
        return FooterStatus(kind: .live, text: loc("실시간", "Live"))
    }

    /// "실측 수신: Codex 기록 없음 · Claude Code 2분 전", minute-granular for a stable tooltip. Gemini CLI and Qwen Code join
    /// once they have sent something.
    static func telemetryReceipt(_ lastReceived: [TokenSource: Date], now: Date) -> String {
        loc("실측 수신: ", "Telemetry received: ") + TokenSource.telemetryClients
            .filter { TokenSource.defaultClients.contains($0) || lastReceived[$0] != nil }
            .map { "\($0.title) \(helpAge(lastReceived[$0], now: now))" }.joined(separator: " · ")
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
        if calendar.isDate(date, inSameDayAs: now) || date > now { return loc("오늘", "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return loc("어제", "Yesterday") }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return loc("이번 주", "This week") }
        return olderSection
    }
    static var olderSection: String { loc("이전", "Earlier") }

    // MARK: Detail and row actions

    struct DetailItem: Identifiable, Equatable {
        var label: String
        var value: String
        /// Text the copy button puts on the pasteboard; nil draws no button.
        var copy: String?
        var id: String { label }
    }

    /// The inline detail under a clicked row (S-6). Metadata only; nothing from the conversation.
    static func detailItems(_ reading: TokenReading, state: SessionDisplayState) -> [DetailItem] {
        let unknown = loc("미확인", "Unknown")
        var items = [DetailItem(label: loc("세션 ID", "Session ID"), value: reading.sessionID ?? unknown, copy: reading.sessionID)]
        if reading.isSubagent { items.append(DetailItem(label: loc("에이전트", "Agent"), value: reading.agentID ?? unknown, copy: reading.agentID)) }
        if let model = reading.model { items.append(DetailItem(label: loc("모델", "Model"), value: model + (effortLabel(reading).map { " · \($0)" } ?? ""))) }
        if state == .tool {
            items.append(DetailItem(label: loc("도구", "Tool"), value: toolTitle(reading.toolCategory) + (reading.toolName.map { " · \($0)" } ?? "")))
        }
        if let output = reading.lastOutputTokens {
            let seconds = reading.lastTurnDurationSeconds.flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded()) : nil }
            items.append(DetailItem(label: loc("마지막 완료 턴", "Last turn"), value: "\(Format.tokens(output)) tok" + (seconds.map { " · \(clock($0))" } ?? "")))
        }
        let codex = reading.source == .codex
        items.append(DetailItem(label: loc("기록 시점", "Recorded"),
                                value: loc("\(reading.clientTitle)는 \(codex ? "응답" : "메시지") 완료 시 기록",
                                           "When a \(reading.clientTitle) \(codex ? "response" : "message") ends")))
        return items
    }

    /// 8 + 15 per line + 8, plus the 0.5 pt rule above it.
    static func detailHeight(_ reading: TokenReading, state: SessionDisplayState) -> CGFloat {
        16 + 15 * CGFloat(detailItems(reading, state: state).count) + 0.5
    }

    /// The log file the reading came from: its id is "<source>:<path relative to home>", and a log holding several
    /// sessions (OpenCode's database) appends "#<session>". JSONL logs, JSON snapshots (Amp, Cline, legacy Gemini) and
    /// databases are revealed.
    static func logFileURL(_ reading: TokenReading, home: URL) -> URL? {
        guard !isTelemetry(reading), let colon = reading.id.firstIndex(of: ":") else { return nil }
        let id = reading.id[reading.id.index(after: colon)...]
        let fragment = id.lastIndex(of: "#")
        let path = String(id[..<(fragment ?? id.endIndex)])
        guard !path.isEmpty, fragment != nil || [".jsonl", ".json", ".db"].contains(where: { path.hasSuffix($0) }) else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
    }

    /// POSIX single quoting: `'` becomes `'\''`.
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// "cd '<project>' && <`TokenSource.resumeCommand`> <id>"; nil for subagents, without an ID or folder, or for a client
    /// with no known resume command.
    /// Backslashes (fish reads `\'` inside single quotes) and control characters (keystrokes on paste) are refused.
    static func resumeCommand(_ reading: TokenReading) -> String? {
        let unsafe: (String) -> Bool = { $0.unicodeScalars.contains { $0 == "\\" || $0.properties.generalCategory == .control } }
        guard !reading.isSubagent, !isTelemetry(reading), let command = reading.source.resumeCommand,
              let session = reading.sessionID, !session.isEmpty,
              let path = reading.projectPath, path.hasPrefix("/"), !unsafe(path), !unsafe(session) else { return nil }
        let plain = session.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        let id = plain ? session : shellQuote(session)
        return "cd \(shellQuote(path)) && \(command) \(id)"
    }

    struct RowAction: Identifiable, Equatable {
        enum Kind: Equatable { case copy(String), reveal(URL) }
        var title: String
        var symbol: String
        var kind: Kind
        var id: String { title }
        var isReveal: Bool { if case .reveal = kind { return true } else { return false } }
    }

    /// Copy and reveal only; file contents are never opened. Copies first, then Finder reveals.
    static func rowActions(_ reading: TokenReading, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [RowAction] {
        var actions: [RowAction] = []
        if let session = reading.sessionID, !session.isEmpty {
            actions.append(RowAction(title: loc("세션 ID 복사", "Copy Session ID"), symbol: "doc.on.doc", kind: .copy(session)))
        }
        if let agent = reading.agentID, !agent.isEmpty {
            actions.append(RowAction(title: loc("에이전트 ID 복사", "Copy Agent ID"), symbol: "doc.on.doc", kind: .copy(agent)))
        }
        if let command = resumeCommand(reading) {
            actions.append(RowAction(title: loc("재개 명령 복사", "Copy Resume Command"), symbol: "terminal", kind: .copy(command)))
        }
        if let path = reading.projectPath, path.hasPrefix("/") {
            actions.append(RowAction(title: loc("프로젝트 폴더 Finder에서 보기", "Show Project Folder in Finder"), symbol: "folder",
                                     kind: .reveal(URL(fileURLWithPath: path, isDirectory: true))))
        }
        if let log = logFileURL(reading, home: home) {
            actions.append(RowAction(title: loc("기록 파일 Finder에서 보기", "Show Log File in Finder"), symbol: "doc.text.magnifyingglass", kind: .reveal(log)))
        }
        return actions
    }
}

struct SessionRowItem: Identifiable {
    enum Kind { case live, idle, measurement, child }
    var reading: TokenReading
    var state: SessionDisplayState
    var kind: Kind
    /// Live rows show line 3 only when it holds the turn's last record, context or a measured speed.
    var showsDetail = true
    var id: String { reading.id }
    static let liveDetailHeight: CGFloat = 58
    var height: CGFloat {
        switch kind {
        case .live: return showsDetail ? Self.liveDetailHeight : 44
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
    var moreText = "", moreSpoken = ""
    /// Expanded list only: the date section of an unpinned block; captions are drawn where it changes.
    var section: String?
    var older: Bool { section == SessionPresentation.olderSection }
    var id: String { lead.id }
    /// The "+N 하위" row's navigation id.
    var moreID: String { "more:" + id }
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
    /// `caption`'s flag draws a full-width rule above every caption but the first.
    /// `anchor` is the following block's id, so a caption stays unique even when a frozen order repeats a section.
    case divider(String), caption(String, rule: Bool, anchor: String), block(SessionBlock), older(Int)
    var id: String {
        switch self {
        case .divider(let id): return "divider:" + id
        case .caption(_, _, let anchor): return "caption:" + anchor
        case .block(let block): return block.id
        case .older: return "older"
        }
    }
    var height: CGFloat {
        switch self {
        case .divider: return SessionListModel.dividerHeight
        case .caption: return SessionListModel.captionHeight
        case .block(let block): return block.height
        case .older: return SessionListModel.olderHeight
        }
    }
}

/// Computed once per publish; views never re-sort.
struct SessionListModel {
    static let maxViewport: CGFloat = 264
    static let dividerHeight: CGFloat = 1
    static let captionHeight: CGFloat = 24
    static let collapsedMinimum = 6
    static let collapsedChildren = 3
    /// The "+N 하위" summary row.
    static let moreHeight: CGFloat = 24
    /// "이전 기록 더 보기".
    static let olderHeight: CGFloat = 28
    static let olderID = "older"

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
    /// Some visible live lead row has a measured speed from a client not waiting for a restart (S-3); otherwise no row has
    /// a speed cell. Child rows (S-5) have no speed cell, so their measurements stay in the detail and VoiceOver and never
    /// open a column of "—". The column never adds a third line of its own (`SessionPresentation.speedCell`).
    var showsSpeedColumn = false
    /// Codex usage limit from the same publish.
    var usageLimit: UsageLimitSummary?
    private var viewports: (folded: CGFloat, open: CGFloat) = (0, 0)

    static let empty = SessionListModel()

    func entries(showOlder: Bool) -> [SessionListEntry] {
        var entries: [SessionListEntry] = []
        var folded = false
        var section: String?
        for block in blocks {
            if block.older && !showOlder {
                if !folded {
                    if !entries.isEmpty { entries.append(.divider(Self.olderID)) }
                    entries.append(.older(olderCount))
                    folded = true
                }
                continue
            }
            if let next = block.section, next != section {
                // Only a caption at the very top goes without a rule; one under a pinned live row keeps it.
                entries.append(.caption(next, rule: !entries.isEmpty, anchor: block.id))
                section = next
            } else if !entries.isEmpty {
                entries.append(.divider(block.id))
            }
            entries.append(.block(block))
        }
        return entries
    }

    func height(showOlder: Bool) -> CGFloat { olderCount > 0 && showOlder ? olderContentHeight : contentHeight }
    func viewport(showOlder: Bool) -> CGFloat { olderCount > 0 && showOlder ? viewports.open : viewports.folded }

    /// Selectable rows in visual order (P-2): leads, children, "+N 하위" and "이전 기록"; captions and dividers are skipped.
    func navigation(showOlder: Bool) -> [String] {
        entries(showOlder: showOlder).flatMap { entry -> [String] in
            switch entry {
            case .block(let block): return [block.id] + block.children.map(\.id) + (block.moreCount > 0 ? [block.moreID] : [])
            case .older: return [Self.olderID]
            default: return []
            }
        }
    }

    /// Projects on more than one visible top-level row; only those rows add a short ID. The folded "이전" part is not visible.
    func sharedProjects(showOlder: Bool) -> Set<String> {
        var counts: [String: Int] = [:]
        for block in blocks where (showOlder || !block.older) && block.lead.kind != .measurement {
            if let project = block.lead.reading.project, !project.isEmpty { counts[project, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Where keyboard selection starts: the first row waiting for input, else the first retry, else the first row.
    func startRow(showOlder: Bool) -> String? {
        let rows = blocks.flatMap { [$0.lead] + $0.children }
        let visible = Set(navigation(showOlder: showOlder))
        for state in [SessionDisplayState.input, .retrying] {
            if let row = rows.first(where: { $0.state == state && visible.contains($0.id) }) { return row.id }
        }
        return navigation(showOlder: showOlder).first
    }

    /// The row item for a navigation id, if it is a session row.
    func item(_ id: String) -> SessionRowItem? {
        for block in blocks {
            if block.lead.id == id { return block.lead }
            if let child = block.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    /// The same blocks in a frozen order (S-8): known blocks keep their place, new ones go to the end.
    func reordered(_ order: [String]) -> SessionListModel {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var copy = self
        copy.blocks = blocks.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        copy.measure()
        return copy
    }

    private mutating func measure() {
        let folded = entries(showOlder: false), open = entries(showOlder: true)
        contentHeight = folded.reduce(0) { $0 + $1.height }
        olderContentHeight = open.reduce(0) { $0 + $1.height }
        viewports = (Self.snappedViewport(folded), Self.snappedViewport(open))
    }

    /// The cut lands at least 12pt inside a row and hides at least 6pt of it, so a peek always reads as a row.
    static func snappedViewport(_ entries: [SessionListEntry]) -> CGFloat {
        let total = entries.reduce(0) { $0 + $1.height }
        guard total > maxViewport else { return total }
        var best: CGFloat = 0
        var y: CGFloat = 0
        for entry in entries {
            var frames: [(top: CGFloat, height: CGFloat)] = []
            if case .block(let block) = entry { frames = block.rowFrames } else if case .older = entry { frames = [(0, olderHeight)] }
            for frame in frames {
                let low = y + frame.top + 12, high = y + frame.top + frame.height - 6
                if low <= maxViewport { best = max(best, min(high, maxViewport)) }
            }
            y += entry.height
        }
        return best > 0 ? best : maxViewport
    }

    /// `flow` is no longer read (row bars were removed, S-2); the shell still passes it. `restart`: clients waiting for a
    /// relaunch, whose rows show no speed cell.
    static func make(tokens: [TokenReading], now: Date, expanded: Bool, flow: FlowSeries = .empty,
                     restart: Set<TokenSource> = [], codexLive: [TokenRateLimit] = [], calendar: Calendar = .current) -> SessionListModel {
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
        // Keys first: `lastActivity` scans every member, too slow to recompute per comparison on each sample.
        let unpinned = groups.filter { !pinned.contains($0.id) }
        let keys = unpinned.map { (at: $0.lastActivity, id: $0.id) }
        let rest = keys.indices.sorted { keys[$0].at != keys[$1].at ? keys[$0].at > keys[$1].at : keys[$0].id < keys[$1].id }.map { unpinned[$0] }
        let ordered = pinnedGroups + rest
        let shown = expanded ? ordered : Array(ordered.prefix(max(pinned.count, collapsedMinimum)))

        var model = SessionListModel()
        model.counts = SessionCounts(groups)
        model.usageLimit = SessionPresentation.usageLimit(tokens, live: codexLive, now: now)
        model.hiddenGroups = ordered.count - shown.count
        func measuredSpeed(_ reading: TokenReading) -> Bool {
            reading.speedMeasurement?.tokensPerSecond != nil && !restart.contains(reading.source)
        }
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
                leadItem.showsDetail = SessionPresentation.lastRecord(lead.reading) != nil || measuredSpeed(lead.reading)
                    || SessionPresentation.context(lead.reading, now: now) != nil
                if measuredSpeed(lead.reading) { model.showsSpeedColumn = true }
            }
            var block = SessionBlock(lead: leadItem,
                                     children: children.map { SessionRowItem(reading: $0.reading, state: $0.state, kind: .child) },
                                     childCount: group.children.count, state: group.state)
            block.runningChildren = running
            block.waitingChildren = live.count - running
            block.moreCount = cut.count
            if !cut.isEmpty {
                let newest = cut.compactMap { SessionPresentation.liveAt($0.reading) }.max()
                let more = { (spoken: Bool) in loc("+\(cut.count) 하위 \(SessionDisplayState.waiting.title)", "+\(plural(cut.count, "subagent")) waiting for log")
                    + (newest.map { loc(" · 마지막 ", " · last record ") + Format.age($0, now: now, spoken: spoken) } ?? "") }
                block.moreText = more(false)
                block.moreSpoken = more(true)
            }
            if expanded && !pinned.contains(group.id) {
                block.section = SessionPresentation.daySection(group.lastActivity, now: now, calendar: calendar)
                if block.older { model.olderCount += 1 }
            }
            model.blocks.append(block)
        }
        model.measure()
        return model
    }
}
