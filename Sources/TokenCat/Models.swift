import Foundation

struct SystemSnapshot: Codable {
    var cpuPercent: Double? = nil
    var memoryUsedBytes: UInt64? = nil
    var memoryTotalBytes: UInt64? = nil
    var diskUsedBytes: UInt64? = nil
    var diskTotalBytes: UInt64? = nil
    var uploadBytesPerSecond: Double? = nil
    var downloadBytesPerSecond: Double? = nil
    var localIPs: [String] = []
    var batteryPercent: Double? = nil
    var isCharging: Bool? = nil
    var powerSource: String? = nil
    var batteryPresent: Bool = false
    var sampledAt: Date = Date()
}

enum TokenSource: String, Codable, CaseIterable {
    case codex, claude
    var title: String { self == .codex ? "Codex" : "Claude Code" }
}

/// `stale`: an open turn past its liveness horizon (tool or model wait) but logged within
/// 30 minutes. `unfinished`: an open turn with no log for longer; it is not shown as waiting.
enum TokenActivityState: String, Codable {
    case idle, working, tool, output, complete, interrupted, stale, unfinished
}

/// One log-recorded output increment. `at` is the log write time, not a streaming time.
struct TokenOutputEvent: Codable, Equatable {
    var at: Date
    var tokens: Int
}

struct TokenReading: Codable, Identifiable {
    var id: String
    var source: TokenSource
    var sessionID: String? = nil
    /// Exact identifier of the session a subagent belongs to (Claude: shared sessionId,
    /// Codex: root thread). Nil for main sessions. Used only for grouping.
    var parentSessionID: String? = nil
    var agentID: String? = nil
    var project: String? = nil
    var model: String? = nil
    var measurementModel: String? = nil
    var isSubagent: Bool = false
    var turnAverageTokensPerSecond: Double? = nil
    var speedMeasurement: TokenSpeedMeasurement? = nil
    var lastOutputTokens: Int? = nil
    var active: Bool = false
    var activityState: TokenActivityState = .idle
    var currentTurnStartedAt: Date? = nil
    var currentTurnOutputTokens: Int? = nil
    var lastOutputAt: Date? = nil
    var lastOutputDelta: Int? = nil
    var recentOutputs: [TokenOutputEvent] = []
    var sampledAt: Date? = nil
    var lastActivity: Date? = nil
    /// Newest timestamp of any record in the log; liveness only, not shown as activity.
    var lastLogAt: Date? = nil
    var measurementAt: Date? = nil
    var sessionCount: Int = 0
    var quality: String = "완료된 턴 평균 · 도구·대기 포함"
    var status: String = "기록 대기"

    init(source: TokenSource, id: String? = nil,
         sessionID: String? = nil, agentID: String? = nil, project: String? = nil,
         model: String? = nil, measurementModel: String? = nil, isSubagent: Bool = false,
         turnAverageTokensPerSecond: Double? = nil, lastOutputTokens: Int? = nil,
         active: Bool = false, lastActivity: Date? = nil, measurementAt: Date? = nil,
         activityState: TokenActivityState = .idle, currentTurnStartedAt: Date? = nil,
         currentTurnOutputTokens: Int? = nil, lastOutputAt: Date? = nil,
         lastOutputDelta: Int? = nil, sampledAt: Date? = nil,
         sessionCount: Int = 0, quality: String = "완료된 턴 평균 · 도구·대기 포함",
         status: String = "기록 대기") {
        self.source = source
        self.id = id ?? source.rawValue
        self.sessionID = sessionID
        self.agentID = agentID
        self.project = project
        self.model = model
        self.measurementModel = measurementModel
        self.isSubagent = isSubagent
        self.turnAverageTokensPerSecond = turnAverageTokensPerSecond
        self.lastOutputTokens = lastOutputTokens
        self.active = active
        self.activityState = activityState
        self.currentTurnStartedAt = currentTurnStartedAt
        self.currentTurnOutputTokens = currentTurnOutputTokens
        self.lastOutputAt = lastOutputAt
        self.lastOutputDelta = lastOutputDelta
        self.sampledAt = sampledAt
        self.lastActivity = lastActivity
        self.measurementAt = measurementAt
        self.sessionCount = sessionCount
        self.quality = quality
        self.status = status
    }
}
