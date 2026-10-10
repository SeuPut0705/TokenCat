import Foundation
import SQLite3

/// omp's and Pi's account-attributed usage history: independent windows, canonical member identity, WAL writes,
/// live/record merges, the "omp" labels, and the model → subscription cadence. Identity remains in memory only.
/// Run from `runLiveLimitChecks`.
func runAgentUsageHistoryChecks(_ check: (@autoclosure () -> Bool, String) -> Void, now: Date, folder: URL) {
    func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }
    func ms(_ offset: TimeInterval) -> Int64 { Int64(at(offset).timeIntervalSince1970 * 1_000) }

    check(AgentUsageHistory.windowMinutes("5 Hour") == 300 && AgentUsageHistory.windowMinutes("7 Day") == 10_080
          && AgentUsageHistory.windowMinutes("7 days") == 10_080 && AgentUsageHistory.windowMinutes("1 hour") == 60
          && AgentUsageHistory.windowMinutes("Primary window") == nil && AgentUsageHistory.windowMinutes(nil) == nil,
          "omp window labels are not turned into minutes")
    check(TokenSource.limitProvider(model: "claude-opus-5-5") == .claude && TokenSource.limitProvider(model: "anthropic/claude-sonnet-5") == .claude
          && TokenSource.limitProvider(model: "gpt-6.1-sol") == .codex && TokenSource.limitProvider(model: "openai-codex/gpt-5.5") == .codex
          && TokenSource.limitProvider(model: "o3") == .codex && TokenSource.limitProvider(model: "gemini-3-pro") == nil
          && TokenSource.limitProvider(model: "glm-4.6") == nil && TokenSource.limitProvider(model: nil) == nil,
          "a model is not mapped to the subscription it uses")

    // Cadence: an omp session running a Claude model makes Claude active; an idle one on GPT does not make Codex active.
    func session(_ id: String, _ source: TokenSource, model: String, running: Bool) -> TokenReading {
        TokenReading(source: source, id: id, sessionID: id, project: "demo", model: model, active: running,
                     lastActivity: at(-2), activityState: running ? .working : .complete, sampledAt: now)
    }
    let counts = SessionCounts(SessionPresentation.groups([session("omp:a", .omp, model: "claude-opus-5-5", running: true),
                                                          session("omp:b", .omp, model: "gpt-6.1-sol", running: false)], now: now))
    let codexOnly = SessionCounts(SessionPresentation.groups([session("codex:c", .codex, model: "unknown-model", running: true)], now: now))
    check(counts.limitSources == [LimitSlot(provider: .claude, account: nil)]
          && codexOnly.limitSources == [LimitSlot(provider: .codex, account: nil)] && counts.running[.omp] == 1,
          "a running session on a Claude or OpenAI model does not make that subscription active (\(counts.limitSources))")

    // A WAL-mode agent.db written while TokenCat reads it.
    let home = folder.appendingPathComponent("agent-home", isDirectory: true)
    let agent = home.appendingPathComponent(".omp/agent", isDirectory: true)
    try? FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    let path = agent.appendingPathComponent("agent.db").path
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard sqlite3_open(path, &database) == SQLITE_OK else { return check(false, "omp usage fixture: database not created") }
    var failed = false
    func run(_ sql: String) { if sqlite3_exec(database, sql, nil, nil, nil) != SQLITE_OK { failed = true } }
    func row(_ provider: String, _ account: String, _ accountID: String?, _ limit: String, _ label: String?, _ used: Double?,
             _ recorded: TimeInterval, _ reset: TimeInterval?, email: String? = "person@example.com") {
        func text(_ value: String?) -> String { value.map { "'\($0)'" } ?? "NULL" }
        run("""
            INSERT INTO usage_history (recorded_at, provider, account_key, email, account_id, limit_id, label, window_label, used_fraction, status, resets_at)
            VALUES (\(ms(recorded)), '\(provider)', '\(account)', \(text(email)), \(text(accountID)), '\(limit)', 'label', \(text(label)),
                    \(used.map { "\($0)" } ?? "NULL"), 'ok', \(reset.map { "\(ms($0))" } ?? "NULL"))
            """)
    }
    run("PRAGMA journal_mode=WAL")
    run("""
        CREATE TABLE usage_history (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at INTEGER NOT NULL, provider TEXT NOT NULL,
            account_key TEXT NOT NULL, email TEXT, account_id TEXT, limit_id TEXT NOT NULL, label TEXT NOT NULL, window_label TEXT,
            used_fraction REAL, status TEXT, resets_at INTEGER)
        """)
    row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", 0.13, -3_600, 600)
    row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", 0.04, -240, 15_000)
    row("anthropic", "account:a", "acct-a", "anthropic:7d", "7 Day", 0.02, -240, 500_000)
    row("anthropic", "account:a", "acct-a", "anthropic:7d:fable", "7 Day", 0.9, -240, 500_000)
    row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", nil, -100, 15_000)
    row("anthropic", "account:b", "acct-b", "anthropic:5h", "5 Hour", 0.77, -60, 9_000)
    row("openai-codex", "account:c", "acct-c", "openai-codex:primary", "7 days", 0.47, -180, 300_000)
    row("openai-codex", "account:c", "acct-c", "openai-codex:spark:primary", "5 hours", 0.99, -180, 9_000)
    row("google", "account:d", nil, "google:daily", "Daily", 0.5, -10, 9_000)
    check(!failed, "omp usage fixture rows were not written")

    let rows = AgentUsageHistory.rows(URL(fileURLWithPath: path)) ?? []
    let accounts = LimitAccountReader(home: home, environment: [:])
    accounts.refresh()
    let mine = AgentUsageHistory.limits(rows, accounts: accounts, recorder: "omp")
    let accountA = LimitAccount(id: "acct-a", email: "person@example.com")
    let accountB = LimitAccount(id: "acct-b", email: "person@example.com")
    let accountC = LimitAccount(id: "acct-c", email: "person@example.com")
    let claudeA = mine.claude[accountA.storageKey] ?? ClaudeUsageLimits()
    var codexC = TokenRateLimit(usedPercent: 47, windowMinutes: 10_080, resetsAt: at(300_000), recordedAt: at(-180), recordedBy: "omp")
    codexC.account = accountC
    check(rows.count == 6 && !rows.contains { $0.provider == "google" } && rows.allSatisfy { $0.email == "person@example.com" }
          && claudeA == ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: 4, resetsAt: at(15_000), receivedAt: at(-240), recordedBy: "omp"),
                                         sevenDay: ClaudeLimitWindow(usedPercent: 2, resetsAt: at(500_000), receivedAt: at(-240), recordedBy: "omp"))
          && mine.claude[accountB.storageKey]?.fiveHour?.usedPercent == 77 && mine.claude[accountB.storageKey]?.sevenDay == nil
          && mine.claude.count == 2 && mine.codex == [codexC],
          "omp usage history: every account keeps its newest windows, email metadata, and no scoped meters")

    // Metadata reader: Claude Code config, Pi's folder, and a WAL write picked up without a checkpoint.
    try? Data(#"{"projects":{"/tmp/x":{"history":[]}},"oauthAccount":{"accountUuid":"acct-a","emailAddress":"person@example.com"}}"#.utf8)
        .write(to: home.appendingPathComponent(".claude.json"))
    let reader = AgentUsageHistoryReader(home: home, environment: [:])
    let first = reader.read()
    row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", 0.06, -30, 15_000)
    let second = reader.read()
    check(first.claude[accountA.storageKey]?.fiveHour?.usedPercent == 4 && second.claude[accountA.storageKey]?.fiveHour?.usedPercent == 6
          && second.claude[accountA.storageKey]?.fiveHour?.receivedAt == at(-30)
          && FileManager.default.fileExists(atPath: path + "-wal")
          && AgentUsageHistory.recorder(URL(fileURLWithPath: "/Users/x/.pi/agent/agent.db")) == "Pi"
          && AgentUsageHistory.databases(home: home, environment: ["PI_CODING_AGENT_DIR": agent.path]).count == 2,
          "the omp usage reader misses a WAL write, canonical attribution, or Pi's folder")

    // Merge and labels: an omp record is a record, never live; a newer one wins over the bridge, an older one doesn't.
    let bridge = ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: 3, resetsAt: at(15_000), receivedAt: at(-900)))
    let merged = bridge.merged(claudeA)
    let claude = SessionPresentation.claudeUsageLimit(merged, now: now)
    check(merged.fiveHour?.recordedBy == "omp" && ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: 9, resetsAt: at(15_000), receivedAt: at(-10)))
            .merged(claudeA).fiveHour?.usedPercent == 9
          && claude?.live == false && claude?.details(now: now) == ["4시간 10분 후 초기화 · omp 4분 전 기록", "4시간 10분 후 초기화 · 4분 전 기록", "4시간 10분 후 초기화"]
          && claude?.help(now: now).hasPrefix("omp가 자체 사용량 확인으로 기록한 마지막 Claude 계정 사용량입니다.") == true
          && TelemetryStatusRow.claudeLimits(notes: [], bridged: false, received: at(-240), recordedBy: "omp", now: now).text == "omp 기록 · 4분 전",
          "an omp Claude record is not merged by recency or not labelled with omp and its age (\(String(describing: claude?.details(now: now))))")
    let live = TokenRateLimit(usedPercent: 46, windowMinutes: 10_080, resetsAt: at(300_000), recordedAt: at(-600), live: true)
    let codex = SessionPresentation.usageLimit([], reads: [live] + mine.codex, now: now)
    let olderOmp = SessionPresentation.usageLimit([], reads: [TokenRateLimit(usedPercent: 46, windowMinutes: 10_080, resetsAt: at(300_000), recordedAt: at(-20), live: true)]
                                                    + mine.codex, now: now)
    check(codex?.usedPercent == 47 && codex?.live == false && codex?.recordedBy == "omp" && codex?.details(now: now).first == "3일 11시간 후 초기화 · omp 3분 전 기록"
          && codex?.help(now: now).contains("omp") == true && olderOmp?.usedPercent == 46 && olderOmp?.isLive(now: now) == true && olderOmp?.recordedBy == nil,
          "a Codex window from omp does not merge with the live read by recency (\(String(describing: codex?.details(now: now))))")
    AppLanguage.with(.en) {
        check(claude?.details(now: now).first == "Resets in 4h 10m · omp recorded 4m ago"
              && TelemetryStatusRow.claudeLimits(notes: [], bridged: false, received: at(-240), recordedBy: "Pi", now: now).text == "Pi · recorded 4m ago",
              "English omp labels")
    }

    // Two members share an id. Its missing-email identity must stay separate; a unique credential fills an email.
    run("""
        CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT);
        INSERT INTO auth_credentials (provider, credential_type, data) VALUES
          ('anthropic', 'oauth', '{"accountId":"workspace","email":"one@example.com"}'),
          ('anthropic', 'oauth', '{"accountId":"workspace","email":"two@example.com"}'),
          ('anthropic', 'oauth', '{"accountId":"unique","email":"only@example.com"}'),
          ('openai-codex', 'oauth', '{"accountId":"workspace","email":"one@example.com"}'),
          ('openai-codex', 'oauth', '{"accountId":"workspace","email":"two@example.com"}'),
          ('openai-codex', 'oauth', '{"accountId":"unique","email":"only@example.com"}');
        """)
    for (provider, limit, label) in [("anthropic", "anthropic:5h", "5 hours"), ("openai-codex", "openai-codex:primary", "7 days")] {
        // Deliberately use the same account_key: canonical id/email, not a client's key, separates member windows.
        row(provider, "shared", " WORKSPACE ", limit, label, 0.11, -50, 20_000, email: " ONE@EXAMPLE.COM ")
        row(provider, "shared", "workspace", limit, label, 0.22, -40, 20_000, email: "two@example.com")
        row(provider, "shared", "workspace", limit, label, 0.33, -30, 20_000, email: nil)
        row(provider, "unique", "unique", limit, label, 0.44, -20, 20_000, email: nil)
        row(provider, "legacy", nil, limit, label, 0.50, -10, 20_000, email: "one@example.com")
    }
    accounts.refresh()
    let all = AgentUsageHistory.limits(AgentUsageHistory.rows(URL(fileURLWithPath: path)) ?? [], accounts: accounts, recorder: "omp")
    let one = LimitAccount(id: "workspace", email: "one@example.com")
    let two = LimitAccount(id: "workspace", email: "two@example.com")
    let unspecified = LimitAccount(id: "workspace", email: nil)
    let unique = LimitAccount(id: "unique", email: "only@example.com")
    check(!failed && all.claude[one.storageKey]?.fiveHour?.usedPercent == 11
          && all.claude[two.storageKey]?.fiveHour?.usedPercent == 22 && all.claude[unspecified.storageKey]?.fiveHour?.usedPercent == 33
          && all.claude[unique.storageKey]?.fiveHour?.usedPercent == 44 && all.claude["legacy"]?.fiveHour?.usedPercent == 50,
          "Claude history mixes shared-workspace members, nil email, unique credential resolution, or legacy rows")
    check(all.codex.first { $0.account == one }?.usedPercent == 11 && all.codex.first { $0.account == two }?.usedPercent == 22
          && all.codex.first { $0.account == unspecified }?.usedPercent == 33 && all.codex.first { $0.account == unique }?.usedPercent == 44
          && all.codex.first { $0.account == nil }?.usedPercent == 50,
          "Codex history mixes shared-workspace members, nil email, unique credential resolution, or legacy rows")
    let refreshed = reader.read()
    check(refreshed.claude[one.storageKey]?.fiveHour?.usedPercent == 11
          && refreshed.claude[unique.storageKey]?.fiveHour?.usedPercent == 44 && refreshed.codex.first { $0.account == unique }?.usedPercent == 44,
          "history reader does not refresh credential metadata before resolving missing emails")
}
