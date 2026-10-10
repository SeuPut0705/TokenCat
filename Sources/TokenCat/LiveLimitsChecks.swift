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
        check(LiveLimits.claudeUsable(credential, rejected: [], now: now) && !LiveLimits.claudeUsable(soon, rejected: [], now: now)
              && !LiveLimits.claudeUsable(unknown, rejected: [], now: now),
              "an expired (or nearly expired) Claude token would be sent")
        check(LiveLimits.claudeAnswer(status: 401, body: Data(), at: now) == .rejected && LiveLimits.claudeAnswer(status: 403, body: Data(), at: now) == .rejected
              && !LiveLimits.claudeUsable(credential, rejected: [credential.token.hashValue], now: now)
              && LiveLimits.claudeUsable(other, rejected: [credential.token.hashValue], now: now),
              "a 401 token is sent again, or a changed token stays blocked")
    }
    // The live token path binds credentials to exact identities; missing email does not match either workspace member.
    let agentDB = folder.appendingPathComponent("agent.db")
    var handle: OpaquePointer?
    if sqlite3_open(agentDB.path, &handle) == SQLITE_OK {
        sqlite3_exec(handle, """
            CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT);
            INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause) VALUES
              ('anthropic', 'oauth', '{"access":"omp-token","refresh":"r","expires":1790000600000,"accountId":"acct-a","email":"person@example.com"}', NULL),
              ('anthropic', 'oauth', '{"access":"disabled-token","expires":1790000600000,"accountId":"acct-a","email":"person@example.com"}', 'revoked'),
              ('anthropic', 'oauth', '{"access":"member-one","expires":1790000600000,"accountId":"workspace","email":"one@example.com"}', NULL),
              ('anthropic', 'oauth', '{"access":"member-two","expires":1790000600000,"accountId":"workspace","email":"two@example.com"}', NULL),
              ('anthropic', 'oauth', '{"access":"member-nil","expires":1790000600000,"accountId":"workspace"}', NULL),
              ('anthropic', 'oauth', '{"access":"legacy-token","expires":1790000600000}', NULL),
              ('openai-codex', 'oauth', '{"access":"codex-token","expires":1790000600000}', NULL);
            """, nil, nil, nil)
    }
    sqlite3_close(handle)
    let accounts = LimitAccountReader(home: folder, environment: ["PI_CODING_AGENT_DIR": folder.path])
    accounts.refresh()
    let agents = LiveLimits.agentCredentials([agentDB, folder.appendingPathComponent("missing/agent.db")], accounts: accounts)
    let expired = LiveLimits.ClaudeCredential(token: "claude-code-token", expiresAt: at(-10))
    let codeAccount = LimitAccount(id: "acct-a", email: "person@example.com")
    let picked = LiveLimits.claudeCandidates(claudeCode: expired, claudeAccount: codeAccount, agents: agents, target: codeAccount)
        .first { LiveLimits.claudeUsable($0, rejected: [], now: now) }
    check(agents.first?.account == codeAccount && agents.first?.credential.expiresAt == at(600)
          && !agents.contains { $0.credential.token == "disabled-token" || $0.credential.token == "codex-token" }
          && picked?.token == "omp-token"
          && LiveLimits.claudeCandidates(claudeCode: expired, claudeAccount: codeAccount, agents: agents,
                                       target: LimitAccount(id: "acct-b")).isEmpty,
          "Claude candidates do not use the matching agent token after expiry or include another account's token")
    let memberOne = LimitAccount(id: " WORKSPACE ", email: " ONE@EXAMPLE.COM ")
    let memberTwo = LimitAccount(id: "workspace", email: "two@example.com")
    let memberNil = LimitAccount(id: "workspace")
    check(LiveLimits.claudeCandidates(claudeCode: expired, claudeAccount: codeAccount, agents: agents, target: memberOne).map(\.token) == ["member-one"]
          && LiveLimits.claudeCandidates(claudeCode: expired, claudeAccount: codeAccount, agents: agents, target: memberTwo).map(\.token) == ["member-two"]
          && LiveLimits.claudeCandidates(claudeCode: expired, claudeAccount: codeAccount, agents: agents, target: memberNil).map(\.token) == ["member-nil"]
          && LiveLimits.claudeCandidates(claudeCode: expired, claudeAccount: codeAccount, agents: agents, target: nil).map(\.token) == ["legacy-token"],
          "Claude candidates mix shared-workspace members, nil email, or legacy tokens")
    let customConfig = folder.appendingPathComponent("custom-claude", isDirectory: true)
    try? FileManager.default.createDirectory(at: customConfig, withIntermediateDirectories: true)
    try? Data(#"{"claudeAiOauth":{"accessToken":"custom-token","expiresAt":1790000600000}}"#.utf8)
        .write(to: customConfig.appendingPathComponent(".credentials.json"))
    let custom = LiveLimits.readClaudeCredential(keychain: false, configDirectory: customConfig)
    check(custom.credential?.token == "custom-token" && !custom.refused,
          "the live credential path does not read a config-specific Claude credential file")
    try? Data(#"{"oauthAccount":{"accountUuid":"workspace","emailAddress":"one@example.com"}}"#.utf8)
        .write(to: customConfig.appendingPathComponent(".claude.json"))
    try? Data(#"{"oauthAccount":{"accountUuid":"acct-a","emailAddress":"person@example.com"}}"#.utf8)
        .write(to: folder.appendingPathComponent(".claude.json"))
    let configuredAccounts = LimitAccountReader(home: folder, environment: [
        "CLAUDE_CONFIG_DIR": customConfig.path, "PI_CODING_AGENT_DIR": folder.path])
    configuredAccounts.refresh()
    check(configuredAccounts.defaultAccount(.claude) == memberOne
          && configuredAccounts.claudeAccount(configDirectory: folder.appendingPathComponent(".claude")) == codeAccount
          && configuredAccounts.claudeAccount(configDirectory: customConfig) == memberOne
          && custom.credential.map {
              LiveLimits.claudeCandidates(claudeCode: expired, claudeAccount: codeAccount,
                                         agents: [($0, memberOne)], target: memberOne).map(\.token) == ["custom-token"]
          } == true,
          "a configured Claude account is paired with the default home credential instead of its own token")
    let validCode = LiveLimits.ClaudeCredential(token: "code-current", expiresAt: at(600))
    let matching = LiveLimits.claudeCandidates(claudeCode: validCode, claudeAccount: codeAccount, agents: agents, target: codeAccount)
    check(matching.filter { LiveLimits.claudeUsable($0, rejected: [validCode.token.hashValue], now: now) }.map(\.token) == ["omp-token"]
          && matching.filter { LiveLimits.claudeUsable($0, rejected: [validCode.token.hashValue, "omp-token".hashValue], now: now) }.isEmpty,
          "Claude candidate selection forgets individual token rejections within the same account")
    let otherCodex = LimitSlot(provider: .codex, account: LimitAccount(id: "fixture-not-the-cli-account", email: "fixture@example.com"))
    let refusedCodex = LiveLimits.read(otherCodex, rejected: [], keychain: false)
    check(refusedCodex.slot == otherCodex && refusedCodex.codex == nil
          && refusedCodex.note == "live Codex limits are available only for the default CLI account",
          "Codex live polling is not restricted to the default CLI account")
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
    // Independent account slots: in-flight exclusion, backoff, token rejections and a globally refused keychain.
    let lock = NSLock()
    var calls: [LimitSlot: [(Set<Int>, Bool)]] = [:]
    let codeSlot = LimitSlot(provider: .codex, account: codeAccount)
    let oneSlot = LimitSlot(provider: .claude, account: memberOne)
    let twoSlot = LimitSlot(provider: .claude, account: memberTwo)
    let nilSlot = LimitSlot(provider: .claude, account: memberNil)
    let pollSlots: Set<LimitSlot> = [codeSlot, oneSlot, twoSlot, nilSlot]
    let poller = LiveLimitPoller { slot, rejected, keychain in
        var outcome = LiveLimits.Outcome()
        let count = lock.withLock {
            calls[slot, default: []].append((rejected, keychain))
            return calls[slot]?.count ?? 0
        }
        if slot == codeSlot {
            outcome.failed = true
        } else if slot == oneSlot && count == 1 {
            outcome.rejected = [7, 8]
            outcome.keychainRefused = true
        } else {
            outcome.claude = ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(
                usedPercent: slot == oneSlot ? 11 : slot == twoSlot ? 22 : 33, resetsAt: at(300), receivedAt: now, live: true))
        }
        return outcome
    }
    var delivered: [LimitSlot: Double] = [:]
    var deliveryCount = 0
    func tick(_ offset: TimeInterval, live: Bool = false, open: Bool = false, wait: Bool = true) {
        poller.tick(now: at(offset), open: open, slots: pollSlots, live: { _ in live }) { outcome in
            if let slot = outcome.slot { delivered[slot] = outcome.claude?.fiveHour?.usedPercent }
            deliveryCount += 1
        }
        if wait { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    }
    tick(0, wait: false)
    tick(16, open: true)          // Opening cannot duplicate an in-flight read.
    tick(61, live: true)
    tick(122, live: true)         // Codex's second backoff has not elapsed.
    let snapshot = lock.withLock { calls }
    check(snapshot[codeSlot]?.count == 2 && snapshot[oneSlot]?.count == 3
          && snapshot[twoSlot]?.count == 3 && snapshot[nilSlot]?.count == 3 && deliveryCount == 8
          && snapshot[codeSlot]?.allSatisfy { $0.0.isEmpty } == true
          && snapshot[twoSlot]?.allSatisfy { $0.0.isEmpty } == true && snapshot[nilSlot]?.allSatisfy { $0.0.isEmpty } == true
          && snapshot[oneSlot]?.dropFirst().allSatisfy { $0.0 == [7, 8] && !$0.1 } == true
          && delivered[oneSlot] == 11 && delivered[twoSlot] == 22 && delivered[nilSlot] == 33,
          "live poller mixes account slots, per-token rejection sets, attributed numbers, or per-slot backoff")

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
