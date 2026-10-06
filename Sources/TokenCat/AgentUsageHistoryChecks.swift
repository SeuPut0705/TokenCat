import Foundation
import SQLite3

/// omp's and Pi's usage history (synthetic rows, no e-mail kept): the window mapping, Claude Code's account gate, WAL
/// writes picked up, the merge with live reads and records, the "omp" labels, and the model → subscription cadence.
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
    check(counts.limitSources == [.claude] && codexOnly.limitSources == [.codex] && counts.running[.omp] == 1,
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
             _ recorded: TimeInterval, _ reset: TimeInterval?) {
        func text(_ value: String?) -> String { value.map { "'\($0)'" } ?? "NULL" }
        run("""
            INSERT INTO usage_history (recorded_at, provider, account_key, email, account_id, limit_id, label, window_label, used_fraction, status, resets_at)
            VALUES (\(ms(recorded)), '\(provider)', '\(account)', 'person@example.com', \(text(accountID)), '\(limit)', 'label', \(text(label)),
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
    let mine = AgentUsageHistory.limits(rows, claudeAccount: "acct-a", recorder: "omp")
    let newest = AgentUsageHistory.limits(rows, claudeAccount: nil, recorder: "omp")
    check(rows.count == 6 && !rows.contains { $0.provider == "google" }
          && mine.claude == ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: 4, resetsAt: at(15_000), receivedAt: at(-240), recordedBy: "omp"),
                                              sevenDay: ClaudeLimitWindow(usedPercent: 2, resetsAt: at(500_000), receivedAt: at(-240), recordedBy: "omp"))
          && newest.claude.fiveHour?.usedPercent == 77 && newest.claude.sevenDay == nil
          && AgentUsageHistory.limits(rows, claudeAccount: "acct-x", recorder: "omp").claude.isEmpty
          && mine.codex == [TokenRateLimit(usedPercent: 47, windowMinutes: 10_080, resetsAt: at(300_000), recordedAt: at(-180), recordedBy: "omp")],
          "omp usage history: newest row per window, Claude Code's account only, model weeks and extra meters left out (\(mine))")

    // The reader: Claude Code's account from ~/.claude.json, Pi named by its folder, a WAL write picked up without a checkpoint.
    try? Data(#"{"projects":{"/tmp/x":{"history":[]}},"oauthAccount":{"accountUuid":"acct-a","emailAddress":"person@example.com"}}"#.utf8)
        .write(to: home.appendingPathComponent(".claude.json"))
    let reader = AgentUsageHistoryReader(home: home, environment: [:])
    let first = reader.read()
    row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", 0.06, -30, 15_000)
    let second = reader.read()
    check(first.claude.fiveHour?.usedPercent == 4 && second.claude.fiveHour?.usedPercent == 6 && second.claude.fiveHour?.receivedAt == at(-30)
          && FileManager.default.fileExists(atPath: path + "-wal")
          && AgentUsageHistory.recorder(URL(fileURLWithPath: "/Users/x/.pi/agent/agent.db")) == "Pi"
          && AgentUsageHistory.databases(home: home, environment: ["PI_CODING_AGENT_DIR": agent.path]).count == 2,
          "the omp usage reader misses a WAL write, the account gate, or Pi's folder")

    // Merge and labels: an omp record is a record, never live; a newer one wins over the bridge, an older one doesn't.
    let bridge = ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: 3, resetsAt: at(15_000), receivedAt: at(-900)))
    let merged = bridge.merged(mine.claude)
    let claude = SessionPresentation.claudeUsageLimit(merged, now: now)
    check(merged.fiveHour?.recordedBy == "omp" && ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: 9, resetsAt: at(15_000), receivedAt: at(-10)))
            .merged(mine.claude).fiveHour?.usedPercent == 9
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
}
