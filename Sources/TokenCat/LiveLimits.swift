import Foundation

/// "실시간 한도 확인": account usage read live instead of waiting for a log or status line record.
/// Codex through its own `codex app-server` (TokenCat never reads OpenAI tokens); Claude through Anthropic's OAuth usage
/// endpoint with the sign-in Claude Code saved, or, when that is missing or expired, omp's or Pi's saved Anthropic sign-in
/// (`agent.db` `auth_credentials`) for the same account. A token lives in memory for one request only: never logged, stored,
/// put in process arguments or refreshed (refresh tokens rotate, so a refresh would sign the owning client out).
enum LiveLimits {
    /// While a provider's session runs or the dashboard is open; otherwise the idle interval.
    static let activeInterval: TimeInterval = 60
    static let idleInterval: TimeInterval = 600
    /// Opening the dashboard reads again when the last read is at least this old.
    static let openedInterval: TimeInterval = 15
    /// A live read counts as "실시간" this long.
    static let freshness: TimeInterval = 120
    static let claudeUsage = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Whether a provider is due. A clock set back reads at once instead of stalling.
    static func due(last: Date?, retryAt: Date?, now: Date, live: Bool, open: Bool, opened: Bool) -> Bool {
        if let retryAt, now < retryAt { return false }
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age >= (opened ? openedInterval : live || open ? activeInterval : idleInterval)
    }

    // MARK: Codex

    /// GUI apps get a minimal PATH, so the usual install folders are searched too.
    static func searchPath(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
               "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin"]
    }

    static func codexExecutable() -> URL? {
        searchPath().lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `result.rateLimits` of `account/rateLimits/read`: `primary`/`secondary` `{usedPercent, windowDurationMins, resetsAt}`.
    /// Nil for another shape or limit id; empty when the account reports no window.
    static func codexLimits(_ result: [String: Any], at: Date) -> [TokenRateLimit]? {
        guard let limits = result["rateLimits"] as? [String: Any], (limits["limitId"] as? String).map({ $0 == "codex" }) ?? true else { return nil }
        return ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any], let used = ClaudeUsageLimits.number(window["usedPercent"]),
                  (0...1_000).contains(used) else { return nil }
            return TokenRateLimit(usedPercent: used, windowMinutes: ClaudeUsageLimits.number(window["windowDurationMins"]).flatMap { Int(exactly: $0.rounded()) },
                                  resetsAt: ClaudeUsageLimits.number(window["resetsAt"]).flatMap { (1e9...1e10).contains($0) ? Date(timeIntervalSince1970: $0) : nil },
                                  recordedAt: at, live: true)
        }
    }

    /// One `codex app-server` per read (it holds ~120 MB): initialize, initialized, `account/rateLimits/read`, then the
    /// server is ended, at the latest after `timeout`. Notifications in between are skipped. Nil on any failure.
    static func readCodex(executable: URL, timeout: TimeInterval = 10) -> [TokenRateLimit]? {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        // An npm install is a node script, so the child gets the searched folders too.
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": searchPath().joined(separator: ":")]) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A server that exits early must not SIGPIPE TokenCat on the next write.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { return nil }
        defer { stop(process) }
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var buffer = Data(), result: [TokenRateLimit]?, finished = false
        func send(_ message: [String: Any]) {
            guard var line = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return }
            line.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: line)
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                // Notifications and server requests carry a method; only our two responses matter.
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], message["method"] == nil,
                      let id = (message["id"] as? NSNumber)?.intValue else { continue }
                if id == 1, message["result"] != nil {
                    send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
                    send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [String: Any]()])
                    continue
                }
                result = (message["result"] as? [String: Any]).flatMap { codexLimits($0, at: Date()) }
                handle.readabilityHandler = nil
                done.signal()
                return
            }
            if chunk.isEmpty || buffer.count > 1 << 20 { handle.readabilityHandler = nil; done.signal() }
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tokencat", "version": AppInfo.version]]])
        _ = done.wait(timeout: .now() + timeout)
        // Under the lock, so a late handler neither writes to the closed input nor changes the result.
        lock.lock()
        defer { lock.unlock() }
        finished = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        return result
    }

    /// SIGTERM, SIGKILL after a second, then the exit is awaited so no server outlives its read.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    // MARK: Claude

    struct ClaudeCredential {
        var token: String
        var expiresAt: Date?
    }

    /// `{"claudeAiOauth":{"accessToken":…,"expiresAt":ms,…}}` as Claude Code saves it; other fields are not read.
    static func claudeCredential(_ data: Data) -> ClaudeCredential? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return ClaudeCredential(token: token, expiresAt: ClaudeUsageLimits.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) })
    }

    /// Sent only before its expiry (60 s margin; none known counts as expired) and if Anthropic has not refused it (401/403).
    static func claudeUsable(_ credential: ClaudeCredential, rejected: Int?, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt, expiresAt.timeIntervalSince(now) > 60 else { return false }
        return credential.token.hashValue != rejected
    }

    /// The saved sign-in: macOS keychain through /usr/bin/security (so one "Always Allow" covers every TokenCat build),
    /// then ~/.claude/.credentials.json. `refused`: the keychain read was denied, cancelled or left unanswered for 60 s;
    /// exit 44 is only "not found", and an unreadable value is read again next time.
    static func readClaudeCredential(keychain: Bool) -> (credential: ClaudeCredential?, refused: Bool) {
        var refused = false
        if keychain {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let timer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let exited = process.terminationReason == .exit
                if exited && process.terminationStatus == 0, let credential = claudeCredential(data) { return (credential, false) }
                refused = !(exited && [0, 44].contains(process.terminationStatus))
            }
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return ((try? Data(contentsOf: file)).flatMap(claudeCredential), refused)
    }

    /// omp's and Pi's saved Anthropic sign-in (`auth_credentials` in their `agent.db`, an `oauth` row not disabled): only the
    /// access token, its expiry (ms) and account id leave SQLite. These clients refresh their own token while they run, so it
    /// stays usable when Claude Code's has expired. Used only for Claude Code's own account (or when that is unknown), and never
    /// refreshed, stored or logged, like Claude Code's.
    static let agentCredentialQuery = """
        SELECT json_extract(data, '$.access'), json_extract(data, '$.expires'), json_extract(data, '$.accountId') FROM auth_credentials
        WHERE provider = 'anthropic' AND credential_type = 'oauth' AND disabled_cause IS NULL
        """

    static func agentCredentials(_ databases: [URL]) -> [(credential: ClaudeCredential, account: String?)] {
        databases.flatMap { database -> [(credential: ClaudeCredential, account: String?)] in
            guard FileManager.default.fileExists(atPath: database.path), let connection = OpenCodeDatabase(path: database.path) else { return [] }
            var found: [(credential: ClaudeCredential, account: String?)] = []
            _ = connection.query(agentCredentialQuery) { row in
                guard let token = row.text(0), !token.isEmpty else { return }
                found.append((ClaudeCredential(token: token, expiresAt: row.double(1).map { Date(timeIntervalSince1970: $0 / 1_000) }), row.text(2)))
            }
            return found
        }
    }

    /// Claude Code's sign-in first; then omp's or Pi's for the same account (any account when Claude Code's is unknown).
    /// The first one still usable is sent.
    static func claudeCandidates(claudeCode: ClaudeCredential?, agents: [(credential: ClaudeCredential, account: String?)],
                                 claudeAccount: String?) -> [ClaudeCredential] {
        [claudeCode].compactMap { $0 }
            + agents.filter { claudeAccount == nil || $0.account == nil || $0.account == claudeAccount }.map(\.credential)
    }

    static func claudeCodeAccount(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let config = home.appendingPathComponent(".claude.json")
        var info = stat()
        guard stat(config.path, &info) == 0, Int(info.st_size) <= AgentUsageHistoryReader.maximumConfigBytes else { return nil }
        return (try? Data(contentsOf: config)).flatMap(AgentUsageHistory.claudeAccount)
    }

    /// `GET /api/oauth/usage`: `limits[]` (`kind` "session" → 5-hour, "weekly_all" → 7-day; model-scoped weeks are left out)
    /// or the older `five_hour`/`seven_day` `{utilization, resets_at}`. Nil when the body is not a JSON object.
    static func claudeUsage(_ data: Data, receivedAt: Date) -> ClaudeUsageLimits? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ percent: Any?, _ reset: Any?) -> ClaudeLimitWindow? {
            guard let used = ClaudeUsageLimits.number(percent), (0...1_000).contains(used) else { return nil }
            return ClaudeLimitWindow(usedPercent: used, resetsAt: date(reset), receivedAt: receivedAt, live: true)
        }
        if let limits = (root["limits"] as? [Any])?.compactMap({ $0 as? [String: Any] }) {
            func kind(_ name: String) -> ClaudeLimitWindow? {
                limits.first { $0["kind"] as? String == name }.flatMap { window($0["percent"], $0["resets_at"]) }
            }
            return ClaudeUsageLimits(fiveHour: kind("session"), sevenDay: kind("weekly_all"))
        }
        func legacy(_ key: String) -> ClaudeLimitWindow? { (root[key] as? [String: Any]).flatMap { window($0["utilization"], $0["resets_at"]) } }
        return ClaudeUsageLimits(fiveHour: legacy("five_hour"), sevenDay: legacy("seven_day"))
    }

    /// ISO 8601 with or without fractional seconds, or Unix seconds.
    private static func date(_ value: Any?) -> Date? {
        if let seconds = ClaudeUsageLimits.number(value) { return (1e9...1e10).contains(seconds) ? Date(timeIntervalSince1970: seconds) : nil }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    enum ClaudeAnswer: Equatable {
        case limits(ClaudeUsageLimits), rejected, retry
    }

    /// 401/403: this token is not sent again until the stored one changes. Anything else but usable limits backs off.
    static func claudeAnswer(status: Int, body: Data, at: Date) -> ClaudeAnswer {
        if status == 401 || status == 403 { return .rejected }
        guard status == 200, let limits = claudeUsage(body, receivedAt: at), !limits.isEmpty else { return .retry }
        return .limits(limits)
    }

    /// Ephemeral, no redirects: the token goes to api.anthropic.com and nowhere else.
    private static let session = URLSession(configuration: UpdateClient.configuration(), delegate: NoRedirect(), delegateQueue: nil)
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    static func fetchClaude(token: String) -> (answer: ClaudeAnswer, status: Int?) {
        var request = URLRequest(url: claudeUsage)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        UpdateClient.identify(&request, version: AppInfo.version)
        var answer = (ClaudeAnswer.retry, nil as Int?)
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                answer = (claudeAnswer(status: http.statusCode, body: data ?? Data(), at: Date()), http.statusCode)
            }
            done.signal()
        }.resume()
        done.wait()
        return answer
    }

    // MARK: One read

    struct Outcome {
        var codex: [TokenRateLimit]?
        var claude: ClaudeUsageLimits?
        var failed = false
        /// In memory only: the refused token's per-process hash.
        var rejected: Int?
        var keychainRefused = false
        /// Why nothing was read, for `--live-limits` only.
        var note: String?
    }

    static func read(_ source: TokenSource, rejected: Int?, keychain: Bool) -> Outcome {
        var outcome = Outcome()
        if source == .codex {
            guard let executable = codexExecutable() else { outcome.note = "codex not found"; return outcome }
            outcome.codex = readCodex(executable: executable)
            outcome.failed = outcome.codex == nil
            if outcome.failed { outcome.note = "codex app-server gave no limits" }
            return outcome
        }
        guard source == .claude else { outcome.note = "no live limits for \(source.title)"; return outcome }
        let saved = readClaudeCredential(keychain: keychain)
        outcome.keychainRefused = saved.refused
        let agents = agentCredentials(AgentUsageHistory.databases(home: FileManager.default.homeDirectoryForCurrentUser,
                                                                  environment: ProcessInfo.processInfo.environment))
        let candidates = claudeCandidates(claudeCode: saved.credential, agents: agents, claudeAccount: claudeCodeAccount())
        guard !candidates.isEmpty else { outcome.note = "no Claude Code, omp or Pi sign-in found"; return outcome }
        guard let credential = candidates.first(where: { claudeUsable($0, rejected: rejected, now: Date()) }) else {
            outcome.note = candidates.contains { $0.token.hashValue == rejected } ? "token refused before"
                : "token expired · Claude Code, omp or Pi refresh it when they run"
            return outcome
        }
        let fetched = fetchClaude(token: credential.token)
        switch fetched.answer {
        case .limits(let limits): outcome.claude = limits
        case .rejected: outcome.rejected = credential.token.hashValue
        case .retry: outcome.failed = true
        }
        if outcome.claude == nil { outcome.note = "HTTP \(fetched.status.map(String.init) ?? "no response")" }
        return outcome
    }

    /// `--live-limits`: one read per provider, printed as numbers only; a token is never printed. omp's and Pi's own usage
    /// records follow with their age, then the limit rows both give the dashboard (status line and log records aside).
    /// Exit 1 when neither reads nor any record exists.
    static func commandLineCheck() -> Int32 {
        var read = 0
        func describe(_ windows: [(Double, Int?, Date?)]) -> String {
            windows.map { "\(Int($0.0.rounded()))% of \($0.1.map { "\($0) min" } ?? "?") · resets \($0.2.map { ISO8601DateFormatter().string(from: $0) } ?? "—")" }
                .joined(separator: ", ")
        }
        func claudeWindows(_ limits: ClaudeUsageLimits?) -> [(Double, Int?, Date?)] {
            [(limits?.fiveHour, 300), (limits?.sevenDay, 10_080)].compactMap { window, minutes in window.map { ($0.usedPercent, minutes, $0.resetsAt) } }
        }
        var live = Outcome()
        for source in TokenSource.defaultClients {
            let started = Date()
            let outcome = Self.read(source, rejected: nil, keychain: true)
            live.codex = live.codex ?? outcome.codex
            live.claude = live.claude ?? outcome.claude
            let text = describe(outcome.codex?.map { ($0.usedPercent, $0.windowMinutes, $0.resetsAt) } ?? claudeWindows(outcome.claude))
            if outcome.codex != nil || outcome.claude != nil { read += 1 }
            print("\(source.title): " + (text.isEmpty ? "no window" : text)
                  + (outcome.note.map { " · \($0)" } ?? "") + String(format: " (%.1f s)", Date().timeIntervalSince(started)))
        }
        let recorded = AgentUsageHistoryReader().read(), now = Date()
        func age(_ dates: [Date]) -> String { dates.max().map { " · recorded \(Int(now.timeIntervalSince($0)) / 60) min ago" } ?? "" }
        let claude = claudeWindows(recorded.claude), codex = recorded.codex.map { ($0.usedPercent, $0.windowMinutes, $0.resetsAt) }
        print("omp/Pi records, Claude: " + (claude.isEmpty ? "none" : describe(claude))
              + age([recorded.claude.fiveHour?.receivedAt, recorded.claude.sevenDay?.receivedAt].compactMap { $0 }))
        print("omp/Pi records, Codex: " + (codex.isEmpty ? "none" : describe(codex)) + age(recorded.codex.map(\.recordedAt)))
        if !claude.isEmpty || !codex.isEmpty { read += 1 }
        let rows = [SessionPresentation.usageLimit([], reads: (live.codex ?? []) + recorded.codex, now: now),
                    SessionPresentation.claudeUsageLimit((live.claude ?? ClaudeUsageLimits()).merged(recorded.claude), now: now)]
        AppLanguage.with(.en) {
            for row in rows.compactMap({ $0 }) {
                print("Dashboard row, \(row.title): \(row.value(now: now)) · \(row.details(now: now).first ?? "")"
                      + (row.otherText(now: now).map { " (\($0))" } ?? ""))
            }
        }
        return read > 0 ? 0 : 1
    }
}

/// Reads each provider on its own cadence, one read per provider at a time, with error backoff. Main thread only.
final class LiveLimitPoller {
    private struct Slot {
        var last: Date?
        var retryAt: Date?
        var failures = 0
        var inFlight = false
    }
    private var slots: [TokenSource: Slot] = [:]
    private var wasOpen = false
    private var rejected: Int?
    private var keychainRefused = false
    private let read: (TokenSource, Int?, Bool) -> LiveLimits.Outcome

    /// `read` is replaced only by the self-test.
    init(read: @escaping (TokenSource, Int?, Bool) -> LiveLimits.Outcome = LiveLimits.read) { self.read = read }

    /// `live`: whether the provider has a running session. `deliver` gets each successful read on the main thread.
    func tick(now: Date, open: Bool, live: (TokenSource) -> Bool, deliver: @escaping (LiveLimits.Outcome) -> Void) {
        let opened = open && !wasOpen
        wasOpen = open
        for source in TokenSource.defaultClients {
            var slot = slots[source] ?? Slot()
            guard !slot.inFlight, LiveLimits.due(last: slot.last, retryAt: slot.retryAt, now: now, live: live(source), open: open, opened: opened)
            else { continue }
            slot.last = now
            slot.inFlight = true
            slots[source] = slot
            let rejected = rejected, keychain = !keychainRefused, read = read
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let outcome = read(source, rejected, keychain)
                DispatchQueue.main.async { self?.finish(source, outcome, deliver) }
            }
        }
    }

    private func finish(_ source: TokenSource, _ outcome: LiveLimits.Outcome, _ deliver: (LiveLimits.Outcome) -> Void) {
        var slot = slots[source] ?? Slot()
        slot.inFlight = false
        slot.failures = outcome.failed ? slot.failures + 1 : 0
        // Counted from the read's start, on the clock `tick` was given.
        slot.retryAt = outcome.failed ? (slot.last ?? Date()).addingTimeInterval(UpdateThrottle.backoff(slot.failures)) : nil
        slots[source] = slot
        if let token = outcome.rejected { rejected = token }
        if outcome.keychainRefused { keychainRefused = true }
        if outcome.codex != nil || outcome.claude != nil { deliver(outcome) }
    }
}
