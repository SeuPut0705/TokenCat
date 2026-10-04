import Foundation
import SwiftUI

/// What a row shows. Derived only from the tracker's enum and exact timestamps, never re-guessed.
enum SessionDisplayState: String, CaseIterable {
    case output, tool, working, waiting, complete, interrupted, unfinished, idle, measurement

    /// Shown as live in the list (includes waiting for a log).
    var isLive: Bool { self == .output || self == .tool || self == .working || self == .waiting }
    /// Counted as running in the menu bar.
    var isRunning: Bool { self == .output || self == .tool || self == .working }

    var title: String {
        switch self {
        case .output: return "출력 기록"
        case .tool: return "도구 실행"
        case .working: return "진행"
        case .waiting: return "로그 대기"
        case .complete: return "완료"
        case .interrupted: return "중단"
        case .unfinished: return "종료 기록 없음"
        case .idle: return "기록 대기"
        case .measurement: return "실측"
        }
    }

    var chipTitle: String {
        switch self {
        case .output: return "출력"
        case .tool: return "도구"
        case .working: return "진행"
        default: return title
        }
    }

    var color: Color {
        switch self {
        case .output: return .green
        case .tool: return .blue
        case .working: return .purple
        case .waiting: return .orange
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
        for state in [SessionDisplayState.output, .tool, .working, .waiting] where states.contains(state) { return state }
        return .idle
    }

    var lastActivity: Date {
        members.compactMap { $0.reading.lastActivity ?? $0.reading.measurementAt }.max() ?? .distantPast
    }
}

struct SessionCounts: Equatable {
    var output = 0, tool = 0, working = 0, waiting = 0
    var groups = 0, readings = 0, runningSubagents = 0
    /// Readings running a tool, counted per member like the menu-bar tint.
    var toolMembers = 0
    var running: [TokenSource: Int] = [:]
    /// Newest activity among waiting rows, for "N분 동안 새 기록 없음".
    var waitingSince: Date?
    /// Menu-bar phase: tool > output > working > waiting > idle.
    var phase: TokenActivityState = .idle

    var runningGroups: Int { output + tool + working }
    func count(_ state: SessionDisplayState) -> Int {
        switch state {
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
        for group in groups {
            readings += group.members.count
            switch group.state {
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
                if member.state == .tool { toolMembers += 1 }
                if member.state == .waiting, let at = member.reading.lastActivity { waitingSince = max(waitingSince ?? at, at) }
            }
        }
        if memberStates.contains(.tool) { phase = .tool }
        else if memberStates.contains(.output) { phase = .output }
        else if memberStates.contains(.working) { phase = .working }
        else if memberStates.contains(.waiting) { phase = .stale }
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

enum SessionPresentation {
    static func isTelemetry(_ reading: TokenReading) -> Bool { reading.id.hasPrefix("telemetry:") }

    static func displayState(_ reading: TokenReading, now: Date) -> SessionDisplayState {
        if isTelemetry(reading) { return .measurement }
        switch reading.activityState {
        case .stale: return .waiting
        case .unfinished: return .unfinished
        default: break
        }
        if !reading.active {
            switch reading.activityState {
            case .complete: return .complete
            case .interrupted: return .interrupted
            default: return .idle
            }
        }
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

    /// Only exact-identity telemetry; never a speed derived from log timing.
    static func speed(_ reading: TokenReading, now: Date) -> SpeedSlot {
        guard let measurement = reading.speedMeasurement, let rate = measurement.tokensPerSecond else {
            return SpeedSlot(prefix: nil, value: "—", kind: nil, recent: false,
                             help: "실측 속도 없음 · 로그 시각으로 추정하지 않습니다", spoken: "속도 실측 없음")
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
                             help: "이전 측정 모델 \(measurement.model ?? "미확인") · \(Format.age(measurement.at, now: now))",
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
}

struct SessionRowItem: Identifiable {
    enum Kind { case live, idle, measurement, child }
    var reading: TokenReading
    var state: SessionDisplayState
    var kind: Kind
    var id: String { reading.id }
    var height: CGFloat {
        switch kind {
        case .live: return 62
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
    /// Children waiting for a log cut by the collapsed per-group cap; running children are never cut.
    var moreCount = 0
    var id: String { lead.id }
    var moreText: String { "+\(moreCount) 하위 \(SessionDisplayState.waiting.title)" }
    var height: CGFloat {
        children.reduce(lead.height) { $0 + $1.height } + (moreCount > 0 ? SessionListModel.moreHeight : 0)
    }
}

/// Computed once per publish; views never re-sort.
struct SessionListModel {
    static let maxViewport: CGFloat = 264
    static let dividerHeight: CGFloat = 1
    static let collapsedMinimum = 6
    static let collapsedChildren = 3
    static let moreHeight: CGFloat = 24

    var blocks: [SessionBlock] = []
    var counts = SessionCounts()
    /// Top-level groups and children of shown groups not visible while collapsed.
    var hiddenGroups = 0
    var hiddenChildren = 0
    var contentHeight: CGFloat = 0
    /// Shared scale for every visible mini bar strip.
    var rowScale: Double = 200

    static let empty = SessionListModel()

    static func make(tokens: [TokenReading], now: Date, expanded: Bool, flow: FlowSeries) -> SessionListModel {
        let groups = SessionPresentation.groups(tokens, now: now)
        func stable(_ a: SessionGroup, _ b: SessionGroup) -> Bool {
            let order = (a.lead.reading.project ?? "").localizedStandardCompare(b.lead.reading.project ?? "")
            if order != .orderedSame { return order == .orderedAscending }
            if a.lead.reading.sessionID != b.lead.reading.sessionID { return (a.lead.reading.sessionID ?? "") < (b.lead.reading.sessionID ?? "") }
            return a.id < b.id
        }
        let running = groups.filter { $0.state.isRunning }.sorted(by: stable)
        let waiting = groups.filter { $0.state == .waiting }.sorted(by: stable)
        let measured = groups.filter { group in
            guard group.state == .measurement, let at = group.lead.reading.speedMeasurement?.at else { return false }
            let age = now.timeIntervalSince(at)
            return age >= -5 && age < 120
        }.sorted { $0.id < $1.id }
        let pinned = Set((running + waiting + measured).map(\.id))
        let rest = groups.filter { !pinned.contains($0.id) }.sorted {
            $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id
        }
        let ordered = running + waiting + measured + rest
        let shown = expanded ? ordered : Array(ordered.prefix(max(pinned.count, collapsedMinimum)))

        var model = SessionListModel()
        model.counts = SessionCounts(groups)
        model.hiddenGroups = ordered.count - shown.count
        var peak = 0
        for group in shown {
            let lead = group.lead
            let kind: SessionRowItem.Kind = lead.state == .measurement ? .measurement : (lead.state.isLive ? .live : .idle)
            // Running children are always shown; the collapsed cap only trims children waiting for a log.
            let live = group.children.filter { $0.state.isLive }.sorted {
                if $0.state.isRunning != $1.state.isRunning { return $0.state.isRunning }
                let a = SessionPresentation.agentLabel($0.reading), b = SessionPresentation.agentLabel($1.reading)
                return a != b ? a.localizedStandardCompare(b) == .orderedAscending : $0.reading.id < $1.reading.id
            }
            let running = live.filter { $0.state.isRunning }.count
            let room = expanded ? live.count : max(running, collapsedChildren)
            var children = Array(live.prefix(room))
            if expanded {
                children += group.children.filter { !$0.state.isLive }.sorted {
                    let a = $0.reading.lastActivity ?? .distantPast, b = $1.reading.lastActivity ?? .distantPast
                    return a != b ? a > b : $0.reading.id < $1.reading.id
                }
            } else {
                model.hiddenChildren += group.children.count - children.count
            }
            var block = SessionBlock(lead: SessionRowItem(reading: lead.reading, state: lead.state, kind: kind),
                                     children: children.map { SessionRowItem(reading: $0.reading, state: $0.state, kind: .child) },
                                     childCount: group.children.count, state: group.state)
            block.runningChildren = running
            block.waitingChildren = live.count - running
            block.moreCount = max(0, live.count - room)
            for item in [block.lead] + block.children where item.kind == .live || (item.kind == .child && item.state.isLive) {
                peak = max(peak, flow.rows[item.id]?.peak ?? 0)
            }
            model.blocks.append(block)
        }
        model.contentHeight = model.blocks.reduce(0) { $0 + $1.height } + CGFloat(max(0, model.blocks.count - 1)) * dividerHeight
        model.rowScale = niceMax(Double(max(peak, 200)))
        return model
    }
}
