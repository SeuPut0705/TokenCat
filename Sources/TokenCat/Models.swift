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
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var memoryPressure: Int? = nil
    var sampledAt: Date = Date()
}

/// Every client TokenCat recognises; `TokenProvider.all` (TokenProviders.swift) says where each keeps its logs and which are read.
enum TokenSource: String, Codable, CaseIterable {
    case codex, claude, opencode, gemini, qwen, copilot, amp, cline, omp, droid
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen Code"
        case .copilot: return "Copilot CLI"
        case .amp: return "Amp"
        case .cline: return "Cline"
        case .omp: return "omp"
        case .droid: return "Droid"
        }
    }
    /// The vendor name alone, before a word like "한도" ("Claude 5시간 한도").
    var shortTitle: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .qwen: return "Qwen"
        case .copilot: return "Copilot"
        default: return title
        }
    }
    /// The command that resumes a session when followed by its ID; nil where none is known.
    var resumeCommand: String? {
        switch self {
        case .codex: return "codex resume"
        case .claude: return "claude --resume"
        case .opencode: return "opencode --session"
        case .gemini: return "gemini --resume"
        case .copilot: return "copilot --resume"
        case .amp: return "amp threads continue"
        case .qwen, .cline, .omp, .droid: return nil
        }
    }
    /// The clients telemetry setup connects to TokenCat's collector: Codex and Claude Code always, Gemini CLI and Qwen Code
    /// while their folder (~/.gemini, ~/.qwen) exists.
    static let telemetryClients: [TokenSource] = [.codex, .claude, .gemini, .qwen]
    /// Codex and Claude Code: always listed, and the only clients whose usage limits TokenCat reads (live and the status
    /// line bridge).
    static let defaultClients: [TokenSource] = [.codex, .claude]
    /// Sources a list names: the default clients always (a Codex and Claude Code user sees no change), any other
    /// once its data folder is detected or a reading carries it.
    static func listed(detected: Set<TokenSource>, readings: [TokenReading]) -> [TokenSource] {
        let seen = Set(readings.map(\.source))
        return allCases.filter { defaultClients.contains($0) || detected.contains($0) || seen.contains($0) }
    }
}

/// `stale`: an open turn past its liveness horizon (tool or model wait) but logged within
/// 30 minutes. `unfinished`: an open turn with no log for longer; it is not shown as waiting.
/// `input`: the turn waits for the person (a question or plan approval tool is pending).
enum TokenActivityState: String, Codable {
    case idle, working, tool, output, complete, interrupted, stale, unfinished, input
}

/// Category of the running tool, derived from the tool name only (never its input).
enum ToolCategory: String, Codable {
    case command, file, web, agent, mcp, question, other
}

/// Claude Code API retry progress from system/api_error records (counts and delays only).
struct TokenRetryState: Codable, Equatable {
    var attempt: Int
    var maxAttempts: Int?
    var retryAt: Date?
    var networkDown: Bool
    var at: Date
}

/// Codex usage limit window as last written by the client. `recordedAt` is the log time.
struct TokenRateLimit: Codable, Equatable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
    var recordedAt: Date
    /// From a live read (`LiveLimits`), not a log; `recordedAt` is then the read time.
    var live: Bool? = nil
}

/// Context occupied by the latest request. Codex reports the window size; Claude does not,
/// so `windowTokens` stays nil there and the size must not be inferred from the model name.
struct TokenContextUsage: Codable, Equatable {
    var usedTokens: Int
    var windowTokens: Int?
    var recordedAt: Date
    var compactedAt: Date?
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
    /// Full working directory, used only for the "Finder에서 보기" action; never displayed.
    var projectPath: String? = nil
    var model: String? = nil
    var isSubagent: Bool = false
    /// Duration of the last completed turn as reported by the client (never divided into a rate).
    var lastTurnDurationSeconds: Double? = nil
    var toolCategory: ToolCategory? = nil
    /// Raw tool name for help text only (e.g. "Bash"); inputs are never read.
    var toolName: String? = nil
    var retry: TokenRetryState? = nil
    var rateLimit: TokenRateLimit? = nil
    var context: TokenContextUsage? = nil
    /// Codex reasoning effort / service tier as written in turn_context.
    var effort: String? = nil
    /// Subagent role or nickname (Codex agent_nickname/role, Claude agentType).
    var agentRole: String? = nil
    /// The product that wrote the log when one source covers several ("Roo Code", "Kilo Code", "Pi"); nil means `source`.
    var clientName: String? = nil
    var clientTitle: String { clientName ?? source.title }
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
    /// Claude: request IDs of the responses in this log (at most 256), matched against telemetry; never shown.
    var requestIDs: Set<String> = []

    init(source: TokenSource, id: String? = nil,
         sessionID: String? = nil, agentID: String? = nil, project: String? = nil,
         model: String? = nil, isSubagent: Bool = false,
         lastOutputTokens: Int? = nil,
         active: Bool = false, lastActivity: Date? = nil, measurementAt: Date? = nil,
         activityState: TokenActivityState = .idle, currentTurnStartedAt: Date? = nil,
         currentTurnOutputTokens: Int? = nil, lastOutputAt: Date? = nil,
         lastOutputDelta: Int? = nil, sampledAt: Date? = nil) {
        self.source = source
        self.id = id ?? source.rawValue
        self.sessionID = sessionID
        self.agentID = agentID
        self.project = project
        self.model = model
        self.isSubagent = isSubagent
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
    }
}
