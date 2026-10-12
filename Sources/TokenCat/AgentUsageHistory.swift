import Foundation

/// omp and Pi save every subscription usage check they make (their own Claude and ChatGPT sign-ins) as rows of
/// `usage_history` in `<agent folder>/agent.db`: numeric windows plus account id and e-mail metadata. Identity stays in
/// memory only; Claude's store uses one-way account hashes. The newest row per account and window is a record, never live.
/// Model-scoped weeks (`anthropic:7d:<model>`) and extra Codex meters (`openai-codex:<slug>:…`) are left out.
enum AgentUsageHistory {
    struct Row: Equatable {
        var provider: String
        /// `account_key`, for grouping one account's windows only.
        var account: String
        var accountID: String?
        var email: String? = nil
        var limitID: String
        var windowLabel: String?
        var usedFraction: Double
        var recordedAt: Date
        var resetsAt: Date?
    }

    struct Limits: Equatable {
        var claude: ClaudeLimitsByAccount = [:]
        var codex: [TokenRateLimit] = []
        var accounts: [TokenSource: [LimitAccount]] = [:]
    }

    /// The agent folders of the omp provider's roots (`$PI_CODING_AGENT_DIR`, `$PI_CONFIG_DIR`, ~/.omp/agent and its named
    /// profiles, `$XDG_DATA_HOME/omp[/profiles/*]`, ~/.pi/agent): each sessions root's parent, except Pi's
    /// `$PI_CODING_AGENT_SESSION_DIR`, which moves only the sessions, so its agent.db stays in the agent folder.
    static func databases(home: URL, environment: [String: String]) -> [URL] {
        var seen = Set<String>()
        let piSessions = environment.path("PI_CODING_AGENT_SESSION_DIR")?.standardizedFileURL
        let roots = TokenProvider.all.first { $0.source == .omp }?.roots(home, environment) ?? []
        let folders = roots.map { root -> URL in
            root.standardizedFileURL == piSessions
                ? environment.path("PI_CODING_AGENT_DIR") ?? home.appendingPathComponent(".pi/agent") : root.deletingLastPathComponent()
        } + [home.appendingPathComponent(".omp/agent"), home.appendingPathComponent(".pi/agent")]
        return folders.map { $0.appendingPathComponent("agent.db") }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The client named as the record's source, as `OmpLog` names its sessions.
    static func recorder(_ database: URL) -> String { database.path.contains("/.pi/agent/") ? "Pi" : "omp" }

    /// "5 Hour", "7 Day", "7 days", "5 hours" (omp's labels) → minutes; nil for any other label or one past `Int`.
    static func windowMinutes(_ label: String?) -> Int? {
        let words = (label ?? "").lowercased().split(separator: " ")
        guard words.count == 2, let count = Int(words[0]), count > 0 else { return nil }
        let minutes: (partialValue: Int, overflow: Bool)
        switch words[1] {
        case "hour", "hours": minutes = count.multipliedReportingOverflow(by: 60)
        case "day", "days": minutes = count.multipliedReportingOverflow(by: 1_440)
        default: return nil
        }
        return minutes.overflow ? nil : minutes.partialValue
    }

    static let query = """
        SELECT provider, account_key, account_id, limit_id, window_label, used_fraction, max(recorded_at), resets_at, email FROM usage_history
        WHERE provider IN ('anthropic', 'openai-codex') AND used_fraction IS NOT NULL GROUP BY provider, account_key, account_id, email, limit_id
        """

    /// The newest row per account and window; nil when the database or table cannot be read.
    static func rows(_ database: URL) -> [Row]? {
        guard let connection = OpenCodeDatabase(path: database.path) else { return nil }
        var rows: [Row] = []
        let read = connection.query(query) { row in
            guard let provider = row.text(0), let account = row.text(1), let limit = row.text(3), let used = row.double(5),
                  let recorded = row.date(6) else { return }
            rows.append(Row(provider: provider, account: account, accountID: row.text(2), email: row.text(8),
                            limitID: limit, windowLabel: row.text(4), usedFraction: used, recordedAt: recorded, resetsAt: row.date(7)))
        }
        return read ? rows : nil
    }

    /// Every account's valid windows are reduced independently. A row without an id is legacy data only.
    static func limits(_ rows: [Row], accounts: LimitAccountReader, recorder: String) -> Limits {
        var result = Limits()
        for row in rows {
            guard row.usedFraction.isFinite, (0...10).contains(row.usedFraction) else { continue }
            if row.provider == "anthropic", ["anthropic:5h", "anthropic:7d"].contains(row.limitID) {
                let account = accounts.resolve(provider: .claude, id: row.accountID, email: row.email)
                if let account, !(result.accounts[.claude] ?? []).contains(account) { result.accounts[.claude, default: []].append(account) }
                let key = account?.storageKey ?? "legacy"
                let window = ClaudeLimitWindow(usedPercent: row.usedFraction * 100, resetsAt: row.resetsAt,
                                               receivedAt: row.recordedAt, recordedBy: recorder)
                let limits = row.limitID == "anthropic:5h" ? ClaudeUsageLimits(fiveHour: window) : ClaudeUsageLimits(sevenDay: window)
                result.claude[key] = (result.claude[key] ?? ClaudeUsageLimits()).merged(limits)
            } else if row.provider == "openai-codex", ["openai-codex:primary", "openai-codex:secondary"].contains(row.limitID) {
                var limit = TokenRateLimit(usedPercent: row.usedFraction * 100, windowMinutes: windowMinutes(row.windowLabel),
                                           resetsAt: row.resetsAt, recordedAt: row.recordedAt, recordedBy: recorder)
                limit.account = accounts.resolve(provider: .codex, id: row.accountID, email: row.email)
                if let account = limit.account, !(result.accounts[.codex] ?? []).contains(account) { result.accounts[.codex, default: []].append(account) }
                result.codex.append(limit)
            }
        }
        result.codex.sort { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
        return result
    }
}

/// Reads metadata on the token queue; each database is queried again only when it or its WAL changes.
final class AgentUsageHistoryReader {
    private let databases: [URL]
    private let accounts: LimitAccountReader
    private var cache: [URL: (stamp: [Int64], rows: [AgentUsageHistory.Row])] = [:]

    /// `accounts` may be shared with the tracker (same home and environment); its refresh is stat-gated, so calling it
    /// again here costs a few stats.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment,
         accounts: LimitAccountReader? = nil) {
        databases = AgentUsageHistory.databases(home: home, environment: environment)
        self.accounts = accounts ?? LimitAccountReader(home: home, environment: environment)
    }

    func read() -> AgentUsageHistory.Limits {
        accounts.refresh()
        var merged = AgentUsageHistory.Limits()
        for database in databases {
            guard let stamp = OpenCodeDatabase.signature(database.path) else { cache[database] = nil; continue }
            if cache[database]?.stamp != stamp {
                // A refused read (a write in progress past the busy timeout) is tried again on the next sample.
                guard let rows = AgentUsageHistory.rows(database) else { continue }
                cache[database] = (stamp, rows)
            }
            let limits = AgentUsageHistory.limits(cache[database]?.rows ?? [], accounts: accounts, recorder: AgentUsageHistory.recorder(database))
            merged.claude = merged.claude.merged(limits.claude)
            merged.codex += limits.codex
            for (provider, accounts) in limits.accounts {
                for account in accounts where !(merged.accounts[provider] ?? []).contains(account) {
                    merged.accounts[provider, default: []].append(account)
                }
            }
        }
        return merged
    }

}
