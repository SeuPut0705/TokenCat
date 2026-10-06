import Foundation

/// omp and Pi save every subscription usage check they make (their own Claude and ChatGPT sign-ins) as rows of
/// `usage_history` in `<agent folder>/agent.db`: `recorded_at` ms, `provider`, `account_key`, `account_id`, `limit_id`,
/// `window_label`, `used_fraction` 0–1, `resets_at` ms. The newest row per window is read as a record, never as live:
/// `anthropic:5h`/`anthropic:7d` → Claude's 5-hour and 7-day windows, `openai-codex:primary`/`:secondary` → Codex's windows
/// (length from `window_label`). Model-scoped weeks (`anthropic:7d:<model>`) and extra Codex meters (`openai-codex:<slug>:…`)
/// are left out. Only numbers and times leave the read; e-mail, account ids and labels are never kept.
enum AgentUsageHistory {
    struct Row: Equatable {
        var provider: String
        /// `account_key`, for grouping one account's windows only.
        var account: String
        var accountID: String?
        var limitID: String
        var windowLabel: String?
        var usedFraction: Double
        var recordedAt: Date
        var resetsAt: Date?
    }

    struct Limits: Equatable {
        var claude = ClaudeUsageLimits()
        var codex: [TokenRateLimit] = []
    }

    /// The same agent folders the omp provider reads: `$PI_CODING_AGENT_DIR`, ~/.omp/agent and ~/.pi/agent.
    static func databases(home: URL, environment: [String: String]) -> [URL] {
        var seen = Set<String>()
        return [environment.path("PI_CODING_AGENT_DIR"), home.appendingPathComponent(".omp/agent"), home.appendingPathComponent(".pi/agent")]
            .compactMap { $0?.appendingPathComponent("agent.db") }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The client named as the record's source, as `OmpLog` names its sessions.
    static func recorder(_ database: URL) -> String { database.path.contains("/.pi/agent/") ? "Pi" : "omp" }

    /// "5 Hour", "7 Day", "7 days", "5 hours" (omp's labels) → minutes; nil for any other label.
    static func windowMinutes(_ label: String?) -> Int? {
        let words = (label ?? "").lowercased().split(separator: " ")
        guard words.count == 2, let count = Int(words[0]), count > 0 else { return nil }
        switch words[1] {
        case "hour", "hours": return count * 60
        case "day", "days": return count * 1_440
        default: return nil
        }
    }

    static let query = """
        SELECT provider, account_key, account_id, limit_id, window_label, used_fraction, max(recorded_at), resets_at FROM usage_history
        WHERE provider IN ('anthropic', 'openai-codex') AND used_fraction IS NOT NULL GROUP BY provider, account_key, limit_id
        """

    /// The newest row per account and window; nil when the database or table cannot be read.
    static func rows(_ database: URL) -> [Row]? {
        guard let connection = OpenCodeDatabase(path: database.path) else { return nil }
        var rows: [Row] = []
        let read = connection.query(query) { row in
            guard let provider = row.text(0), let account = row.text(1), let limit = row.text(3), let used = row.double(5),
                  let recorded = row.date(6) else { return }
            rows.append(Row(provider: provider, account: account, accountID: row.text(2), limitID: limit, windowLabel: row.text(4),
                            usedFraction: used, recordedAt: recorded, resetsAt: row.date(7)))
        }
        return read ? rows : nil
    }

    /// One account per provider, the one checked last. omp's Anthropic rows are left out when they name an account other than
    /// Claude Code's (`claudeAccount`, its signed-in `accountUuid`): those limits belong to another subscription.
    static func limits(_ rows: [Row], claudeAccount: String?, recorder: String) -> Limits {
        func newestAccount(_ provider: String, _ ids: Set<String>, _ accepts: (Row) -> Bool = { _ in true }) -> [Row] {
            let usable = rows.filter { $0.provider == provider && ids.contains($0.limitID) && $0.usedFraction.isFinite
                && (0...10).contains($0.usedFraction) && accepts($0) }
            guard let account = usable.max(by: { $0.recordedAt < $1.recordedAt })?.account else { return [] }
            return usable.filter { $0.account == account }
        }
        let claudeRows = newestAccount("anthropic", ["anthropic:5h", "anthropic:7d"]) { row in
            claudeAccount == nil || row.accountID == nil || row.accountID == claudeAccount
        }
        func claude(_ id: String) -> ClaudeLimitWindow? {
            claudeRows.first { $0.limitID == id }.map {
                ClaudeLimitWindow(usedPercent: $0.usedFraction * 100, resetsAt: $0.resetsAt, receivedAt: $0.recordedAt, recordedBy: recorder)
            }
        }
        let codex = newestAccount("openai-codex", ["openai-codex:primary", "openai-codex:secondary"]).map {
            TokenRateLimit(usedPercent: $0.usedFraction * 100, windowMinutes: windowMinutes($0.windowLabel), resetsAt: $0.resetsAt,
                           recordedAt: $0.recordedAt, recordedBy: recorder)
        }.sorted { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
        return Limits(claude: ClaudeUsageLimits(fiveHour: claude("anthropic:5h"), sevenDay: claude("anthropic:7d")), codex: codex)
    }

    /// Claude Code's signed-in account (`oauthAccount.accountUuid` in ~/.claude.json); nothing else in that file is kept.
    static func claudeAccount(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = (root["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, !account.isEmpty else { return nil }
        return account
    }
}

/// Reads the agent databases on the token queue only: each is queried again only when it or its WAL changes, and
/// ~/.claude.json only when its size or modification time changes.
final class AgentUsageHistoryReader {
    private let databases: [URL]
    private let claudeConfig: URL
    private var cache: [URL: (stamp: [Int64], rows: [AgentUsageHistory.Row])] = [:]
    private var configStamp: [Int64]?
    private var account: String?
    /// Above this ~/.claude.json is not parsed (it holds per-project history too); the account then counts as unknown.
    static let maximumConfigBytes = 16 << 20

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) {
        databases = AgentUsageHistory.databases(home: home, environment: environment)
        claudeConfig = home.appendingPathComponent(".claude.json")
    }

    func read() -> AgentUsageHistory.Limits {
        let account = claudeAccount()
        var merged = AgentUsageHistory.Limits()
        for database in databases {
            guard let stamp = OpenCodeDatabase.signature(database.path) else { cache[database] = nil; continue }
            if cache[database]?.stamp != stamp {
                // A refused read (a write in progress past the busy timeout) is tried again on the next sample.
                guard let rows = AgentUsageHistory.rows(database) else { continue }
                cache[database] = (stamp, rows)
            }
            let limits = AgentUsageHistory.limits(cache[database]?.rows ?? [], claudeAccount: account, recorder: AgentUsageHistory.recorder(database))
            merged.claude = merged.claude.merged(limits.claude)
            merged.codex += limits.codex
        }
        return merged
    }

    private func claudeAccount() -> String? {
        var info = stat()
        guard stat(claudeConfig.path, &info) == 0, Int(info.st_size) <= Self.maximumConfigBytes else { configStamp = nil; account = nil; return nil }
        let stamp = [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
        if stamp != configStamp {
            configStamp = stamp
            account = (try? Data(contentsOf: claudeConfig)).flatMap(AgentUsageHistory.claudeAccount)
        }
        return account
    }
}
