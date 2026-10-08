import Foundation
import SQLite3

/// Live usage limits without the network: the real Codex read path against fake app-servers, Claude's credential gate
/// and both usage shapes, the cadence, and how live reads merge with records and label the row.
func runLiveLimitChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append("Live limits: " + message) }
    }
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    // Codex: fake app-servers (canned JSON lines) spawned by the real read; each writes its pid so the end can be checked.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenCat-live-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func server(_ name: String, _ body: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try? ("#!/bin/sh\necho $$ > \"$0.pid\"\n" + body).write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }
    func ended(_ url: URL) -> Bool {
        let pid = (try? String(contentsOfFile: url.path + ".pid", encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return pid.map { kill($0, 0) != 0 } ?? false
    }
    // The order of requests is enforced; notifications come before each response and one response arrives in two writes.
    let answering = server("app-server", #"""
        read -r line
        case "$line" in *'"initialize"'*) ;; *) exit 3 ;; esac
        echo '{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{"status":"off"}}'
        printf '%s' '{"jsonrpc":"2.0","id":1,'
        sleep 0.1
        printf '%s\n' '"result":{"userAgent":"fake/1.0"}}'
        read -r line
        case "$line" in *'"initialized"'*) ;; *) exit 4 ;; esac
        read -r line
        case "$line" in *'"id":2'*) ;; *) exit 5 ;; esac
        case "$line" in *'"account/rateLimits/read"'*) ;; *) exit 6 ;; esac
        echo '{"jsonrpc":"2.0","method":"account/updated","params":{"authMode":"chatgpt"}}'
        echo '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1791580427},"secondary":null,"credits":{"hasCredits":false},"planType":"pro","rateLimitReachedType":null}}}'
        exec sleep 30
        """#)
    var started = Date()
    let read = LiveLimits.readCodex(executable: answering, timeout: 5)
    check(read == [TokenRateLimit(usedPercent: 31, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1_791_580_427),
                                  recordedAt: read?.first?.recordedAt ?? .distantPast, live: true)]
          && Date().timeIntervalSince(started) < 4 && ended(answering),
          "the Codex app-server read skips notifications, joins split lines and ends the server (\(String(describing: read)))")
    let silent = server("silent-server", "exec sleep 30\n")
    started = Date()
    check(LiveLimits.readCodex(executable: silent, timeout: 0.5) == nil && Date().timeIntervalSince(started) < 3 && ended(silent),
          "a silent Codex app-server is not ended at the timeout")
    check(LiveLimits.codexLimits(["rateLimits": ["limitId": "other", "primary": ["usedPercent": 10]]], at: now) == nil
          && LiveLimits.codexLimits(["rateLimits": ["primary": NSNull(), "secondary": ["usedPercent": 12, "windowDurationMins": 300]]], at: now)
              == [TokenRateLimit(usedPercent: 12, windowMinutes: 300, resetsAt: nil, recordedAt: now, live: true)],
          "Codex windows: another limit id is ignored, a missing reset is not invented")

    // Claude: the saved credential, the expiry margin and a refused token; nothing here goes online.
    let credential = LiveLimits.claudeCredential(Data(#"{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"r","expiresAt":1790000600000}}"#.utf8))
    check(credential?.token == "test-token" && credential?.expiresAt == at(600) && LiveLimits.claudeCredential(Data("{}".utf8)) == nil,
          "Claude Code's saved credential is not read")
    if let credential {
        var soon = credential, unknown = credential, other = credential
        soon.expiresAt = at(30)
        unknown.expiresAt = nil
        other.token = "new-token"
        check(LiveLimits.claudeUsable(credential, rejected: nil, now: now) && !LiveLimits.claudeUsable(soon, rejected: nil, now: now)
              && !LiveLimits.claudeUsable(unknown, rejected: nil, now: now),
              "an expired (or nearly expired) Claude token would be sent")
        check(LiveLimits.claudeAnswer(status: 401, body: Data(), at: now) == .rejected && LiveLimits.claudeAnswer(status: 403, body: Data(), at: now) == .rejected
              && !LiveLimits.claudeUsable(credential, rejected: credential.token.hashValue, now: now)
              && LiveLimits.claudeUsable(other, rejected: credential.token.hashValue, now: now),
              "a 401 token is sent again, or a changed token stays blocked")
    }
    // omp's and Pi's saved Anthropic sign-in: read from agent.db, offered after Claude Code's, only for Claude Code's account.
    let agentDB = folder.appendingPathComponent("agent.db")
    var handle: OpaquePointer?
    if sqlite3_open(agentDB.path, &handle) == SQLITE_OK {
        sqlite3_exec(handle, """
            CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT);
            INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause) VALUES
              ('anthropic', 'oauth', '{"access":"omp-token","refresh":"r","expires":1790000600000,"accountId":"acct-a","email":"PRIVATE"}', NULL),
              ('anthropic', 'oauth', '{"access":"disabled-token","expires":1790000600000,"accountId":"acct-a"}', 'revoked'),
              ('openai-codex', 'oauth', '{"access":"codex-token","expires":1790000600000}', NULL);
            """, nil, nil, nil)
    }
    sqlite3_close(handle)
    let agents = LiveLimits.agentCredentials([agentDB, folder.appendingPathComponent("missing/agent.db")])
    let expired = LiveLimits.ClaudeCredential(token: "claude-code-token", expiresAt: at(-10))
    let picked = LiveLimits.claudeCandidates(claudeCode: expired, agents: agents, claudeAccount: "acct-a")
        .first { LiveLimits.claudeUsable($0, rejected: nil, now: now) }
    check(agents.map(\.credential.token) == ["omp-token"] && agents.first?.account == "acct-a" && agents.first?.credential.expiresAt == at(600)
          && picked?.token == "omp-token"
          && LiveLimits.claudeCandidates(claudeCode: expired, agents: agents, claudeAccount: "acct-b").map(\.token) == ["claude-code-token"]
          && LiveLimits.claudeCandidates(claudeCode: nil, agents: agents, claudeAccount: nil).map(\.token) == ["omp-token"],
          "omp's or Pi's Anthropic sign-in is not used when Claude Code's has expired, or is used for another account")
    let current = Data(#"{"limits":[{"kind":"session","group":"session","percent":42,"resets_at":"2026-09-21T14:13:20.000000+00:00","scope":null,"severity":"normal","is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":90,"resets_at":"2026-09-24T00:00:00Z","scope":{"model":{"display_name":"Opus"}}},{"kind":"weekly_all","group":"weekly","percent":31,"resets_at":null,"scope":null}],"extra_usage":{"is_enabled":false}}"#.utf8)
    let legacy = Data(#"{"five_hour":{"utilization":17.0,"resets_at":"2026-09-21T14:13:20Z"},"seven_day":{"utilization":5,"resets_at":"2026-09-24T00:00:00.5+00:00"},"seven_day_opus":null}"#.utf8)
    let reset = Date(timeIntervalSince1970: 1_790_000_000)
    check(LiveLimits.claudeUsage(current, receivedAt: now) == ClaudeUsageLimits(
            fiveHour: ClaudeLimitWindow(usedPercent: 42, resetsAt: reset, receivedAt: now, live: true),
            sevenDay: ClaudeLimitWindow(usedPercent: 31, resetsAt: nil, receivedAt: now, live: true)),
          "Claude usage limits[]: session → 5-hour, weekly_all → 7-day, scoped weeks ignored, no reset invented")
    check(LiveLimits.claudeUsage(legacy, receivedAt: now)?.fiveHour == ClaudeLimitWindow(usedPercent: 17, resetsAt: reset, receivedAt: now, live: true)
          && LiveLimits.claudeUsage(legacy, receivedAt: now)?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_790_208_000.5)
          && LiveLimits.claudeUsage(Data("[]".utf8), receivedAt: now) == nil,
          "the older five_hour/seven_day usage shape is not read")
    check(LiveLimits.claudeAnswer(status: 200, body: current, at: now) == LiveLimits.ClaudeAnswer.limits(LiveLimits.claudeUsage(current, receivedAt: now) ?? ClaudeUsageLimits())
          && LiveLimits.claudeAnswer(status: 200, body: Data("{}".utf8), at: now) == .retry
          && LiveLimits.claudeAnswer(status: 429, body: current, at: now) == .retry && LiveLimits.claudeAnswer(status: 503, body: current, at: now) == .retry,
          "Claude answers: limits, or backoff on an empty body, 429 and 5xx")

    // Cadence: 1 minute while live or open, 15 s on opening, 10 minutes otherwise; never inside a backoff.
    func due(_ age: TimeInterval?, live: Bool = false, open: Bool = false, opened: Bool = false, retry: TimeInterval? = nil) -> Bool {
        LiveLimits.due(last: age.map { at(-$0) }, retryAt: retry.map(at), now: now, live: live, open: open, opened: opened)
    }
    check(due(nil) && !due(300) && due(601) && !due(59, live: true) && due(61, live: true) && due(61, open: true)
          && due(16, open: true, opened: true) && !due(14, open: true, opened: true) && !due(nil, opened: true, retry: 30) && due(-5),
          "live limit cadence")
    // The poller: one read per provider in flight, a failure backs off, a 401'd token and a refused keychain carry over.
    let lock = NSLock()
    var calls: [String] = []
    // Codex always fails; Claude's first read is refused (401, keychain denied), later ones return limits.
    let poller = LiveLimitPoller { source, rejected, keychain in
        var outcome = LiveLimits.Outcome()
        lock.withLock { calls.append("\(source.rawValue) \(rejected.map(String.init) ?? "-") \(keychain)") }
        if source == .codex { outcome.failed = true } else if keychain { outcome.rejected = 7; outcome.keychainRefused = true } else { outcome.claude = ClaudeUsageLimits() }
        return outcome
    }
    var delivered = 0
    func tick(_ offset: TimeInterval, live: Bool = false, open: Bool = false, wait: Bool = true) {
        poller.tick(now: at(offset), open: open, live: { _ in live }) { _ in delivered += 1 }
        if wait { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    }
    tick(0, wait: false)
    tick(16, open: true)          // due on opening, but both reads are still in flight
    tick(61, live: true)          // Codex's first backoff (1 min) is over; Claude sends nothing refused
    tick(122, live: true)         // Codex waits out its second backoff (2 min)
    check(lock.withLock { calls.sorted() } == ["claude - true", "claude 7 false", "claude 7 false", "codex - true", "codex 7 false"] && delivered == 2,
          "live limit poller in-flight, backoff or 401 carry-over (\(lock.withLock { calls }), delivered \(delivered))")

    // Codex merge: a live read overrides older records of its window and keeps "실시간" against a later equal record.
    let reset5d = at(5 * 86_400 + 2 * 3_600 + 30)
    func codexLog(_ percent: Double, _ recorded: TimeInterval) -> TokenReading {
        var reading = TokenReading(source: .codex, id: "codex:\(percent):\(recorded)")
        reading.rateLimit = TokenRateLimit(usedPercent: percent, windowMinutes: 10_080, resetsAt: reset5d, recordedAt: at(recorded))
        return reading
    }
    func codexLive(_ percent: Double, _ recorded: TimeInterval) -> TokenRateLimit {
        TokenRateLimit(usedPercent: percent, windowMinutes: 10_080, resetsAt: reset5d, recordedAt: at(recorded), live: true)
    }
    let overridden = SessionPresentation.usageLimit([codexLog(40, -900)], reads: [codexLive(31, -20)], now: now)
    let repeated = SessionPresentation.usageLimit([codexLog(31, -5)], reads: [codexLive(31, -60)], now: now)
    let newer = SessionPresentation.usageLimit([codexLog(32, -5)], reads: [codexLive(31, -60)], now: now)
    let stale = SessionPresentation.usageLimit([], reads: [codexLive(33, -300)], now: now)
    let staleTie = SessionPresentation.usageLimit([codexLog(31, -5)], reads: [codexLive(31, -300)], now: now)
    check(overridden?.usedPercent == 31 && overridden?.details(now: now) == ["5일 2시간 후 초기화 · 실시간", "5일 2시간 후 초기화"]
          && overridden?.detail(now: now) == "5일 2시간 후 초기화 · 실시간" && overridden?.help(now: now).contains("OpenAI") == true,
          "a fresher Codex live read does not override the log or is not labelled 실시간")
    check(repeated?.isLive(now: now) == true && newer?.usedPercent == 32 && newer?.live == false
          && newer?.details(now: now).first == "5일 2시간 후 초기화 · 1분 이내 기록" && stale?.details(now: now).first == "5일 2시간 후 초기화 · 5분 전 기록"
          && staleTie?.live == false && staleTie?.details(now: now).first == "5일 2시간 후 초기화 · 1분 이내 기록",
          "Codex: an equal later record keeps 실시간 (only while the read is fresh), a higher one wins with its age, a 5-minute-old read shows its age")

    // Claude merge: the same rules over the bridge and desktop records; the Telemetry row names a live read.
    func window(_ percent: Double, _ received: TimeInterval, live: Bool = false, reset: Date? = at(7_830)) -> ClaudeLimitWindow {
        ClaudeLimitWindow(usedPercent: percent, resetsAt: reset, receivedAt: at(received), live: live ? true : nil)
    }
    let bridge = ClaudeUsageLimits(fiveHour: window(42, -50))
    let liveRead = ClaudeUsageLimits(fiveHour: window(44, -60, live: true))
    let liveSummary = SessionPresentation.claudeUsageLimit(bridge.merged(ClaudeUsageLimits(fiveHour: window(44, -10, live: true))), now: now)
    check(liveSummary?.usedPercent == 44 && liveSummary?.details(now: now).first == "2시간 10분 후 초기화 · 실시간"
          && liveSummary?.help(now: now).contains("Anthropic") == true,
          "a fresher Claude live read does not override the status line or is not labelled 실시간")
    check(liveRead.merged(ClaudeUsageLimits(fiveHour: window(44, -5))) == liveRead
          && liveRead.merged(ClaudeUsageLimits(fiveHour: window(44, -5, reset: nil))) == liveRead
          && liveRead.merged(ClaudeUsageLimits(fiveHour: window(45, -5))).fiveHour == window(45, -5)
          && liveRead.merged(ClaudeUsageLimits(fiveHour: window(44, 70))).fiveHour == window(44, 70),
          "Claude: an equal record within 2 minutes keeps the live read; a different or later one replaces it")
    check(TelemetryStatusRow.claudeLimits(notes: [], bridged: true, received: at(-20), live: true, now: now) == (.received, "실시간 확인 1분 이내", nil)
          && TelemetryStatusRow.claudeLimits(notes: [], bridged: false, received: at(-720), desktop: true, now: now).text == "Claude 데스크톱 앱 기록 · 12분 전",
          "the Telemetry row does not tell a live read from the desktop record")
    AppLanguage.with(.en) {
        check(overridden?.details(now: now).first == "Resets in 5d 2h · live" && stale?.details(now: now).first == "Resets in 5d 2h · recorded 5m ago"
              && SessionPresentation.usageLimit([], reads: [TokenRateLimit(usedPercent: 3, windowMinutes: 300, resetsAt: nil, recordedAt: at(-5), live: true)],
                                                now: now)?.details(now: now) == ["Live"]
              && TelemetryStatusRow.claudeLimits(notes: [], bridged: true, received: at(-20), live: true, now: now).text == "Checked live <1m ago",
              "English live labels")
    }

    runAgentUsageHistoryChecks(check, now: now, folder: folder)

    // The toggle: on by default, remembered, outside "기본값으로 되돌리기".
    if let scratch = ScratchDefaults("TokenCat-live") {
        let defaults = scratch.defaults
        let preferences = Preferences(defaults: defaults)
        let defaultOn = preferences.liveUsageLimits
        preferences.liveUsageLimits = false
        preferences.reset()
        check(defaultOn && !preferences.liveUsageLimits && !Preferences(defaults: defaults).liveUsageLimits,
              "live usage limits are not on by default, not remembered, or reset with the display defaults")
        scratch.discard()
    } else { check(false, "temporary defaults suite unavailable") }

    print("Live limit checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
