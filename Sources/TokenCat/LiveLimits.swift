import Foundation

/// "실시간 한도 확인": account usage read live instead of waiting for a log or status line record.
/// Codex through its own `codex app-server` (TokenCat never reads OpenAI tokens); Claude through Anthropic's OAuth usage
/// endpoint with the sign-in Claude Code saved, or, when that is missing or expired, omp's or Pi's saved Anthropic sign-in
/// (`agent.db` `auth_credentials`) for the same account. Tokens live in memory for one read only: never logged, stored,
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
    static func claudeUsable(_ credential: ClaudeCredential, rejected: Set<Int>, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt, expiresAt.timeIntervalSince(now) > 60 else { return false }
        return !rejected.contains(credential.token.hashValue)
    }

    /// The saved sign-in: macOS keychain through /usr/bin/security (so one "Always Allow" covers every TokenCat build),
    /// then ~/.claude/.credentials.json. A config-specific directory reads only its own file, never the generic keychain.
    /// `refused`: the keychain read was denied, cancelled or left unanswered for 60 s;
    /// exit 44 is only "not found", and an unreadable value is read again next time.
    static func readClaudeCredential(keychain: Bool, configDirectory: URL? = nil) -> (credential: ClaudeCredential?, refused: Bool) {
        var refused = false
        if keychain && configDirectory == nil {
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
        let file = (configDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
            .appendingPathComponent(".credentials.json")
        return ((try? Data(contentsOf: file)).flatMap(claudeCredential), refused)
    }

    /// The existing live path is the only reader of saved tokens. Metadata binds each token to its canonical account.
    static let agentCredentialQuery = """
        SELECT json_extract(data, '$.access'), json_extract(data, '$.expires'), json_extract(data, '$.accountId'),
               json_extract(data, '$.email'), json_extract(data, '$.orgName') FROM auth_credentials
        WHERE provider = 'anthropic' AND credential_type = 'oauth' AND disabled_cause IS NULL
        """

    static func agentCredentials(_ databases: [URL], accounts: LimitAccountReader) -> [(credential: ClaudeCredential, account: LimitAccount?)] {
        databases.flatMap { database -> [(credential: ClaudeCredential, account: LimitAccount?)] in
            guard FileManager.default.fileExists(atPath: database.path), let connection = OpenCodeDatabase(path: database.path) else { return [] }
            var found: [(credential: ClaudeCredential, account: LimitAccount?)] = []
            _ = connection.query(agentCredentialQuery) { row in
                guard let token = row.text(0), !token.isEmpty else { return }
                let account = accounts.resolve(provider: .claude, id: row.text(2), email: row.text(3), organizationName: row.text(4))
                found.append((ClaudeCredential(token: token, expiresAt: row.double(1).map { Date(timeIntervalSince1970: $0 / 1_000) }), account))
            }
            return found
        }
    }

    /// Claude Code's token is eligible only for its account, as are the agent tokens. Nil is a distinct legacy slot.
    static func claudeCandidates(claudeCode: ClaudeCredential?, claudeAccount: LimitAccount?,
                                 agents: [(credential: ClaudeCredential, account: LimitAccount?)], target: LimitAccount?) -> [ClaudeCredential] {
        var seen = Set<String>()
        let code = claudeAccount == target ? [claudeCode].compactMap { $0 } : []
        return (code + agents.filter { $0.account == target }.map(\.credential)).filter { seen.insert($0.token).inserted }
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
        var slot: LimitSlot?
        var codex: [TokenRateLimit]?
        var claude: ClaudeUsageLimits?
        var failed = false
        /// In memory only: refused tokens' per-process hashes, retained independently for each account slot.
        var rejected: Set<Int> = []
        var keychainRefused = false
        /// Why nothing was read, for `--live-limits` only.
        var note: String?
    }

    static func read(_ slot: LimitSlot, rejected: Set<Int>, keychain: Bool) -> Outcome {
        let accounts = LimitAccountReader()
        accounts.refresh()
        var outcome = Outcome(slot: slot)
        if slot.provider == .codex {
            guard slot.account == accounts.defaultAccount(.codex) else {
                outcome.note = "live Codex limits are available only for the default CLI account"
                return outcome
            }
            guard let executable = codexExecutable() else { outcome.note = "codex not found"; return outcome }
            outcome.codex = readCodex(executable: executable)?.map {
                var limit = $0
                limit.account = slot.account
                return limit
            }
            outcome.failed = outcome.codex == nil
            if outcome.failed { outcome.note = "codex app-server gave no limits" }
            return outcome
        }
        guard slot.provider == .claude else { outcome.note = "no live limits for \(slot.provider.title)"; return outcome }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDirectory = home.appendingPathComponent(".claude")
        let codeAccount = accounts.claudeAccount(configDirectory: defaultDirectory)
        let saved: (credential: ClaudeCredential?, refused: Bool) = slot.account == codeAccount
            ? readClaudeCredential(keychain: keychain) : (nil, false)
        outcome.keychainRefused = saved.refused
        var agents = agentCredentials(AgentUsageHistory.databases(home: FileManager.default.homeDirectoryForCurrentUser,
                                                                  environment: environment), accounts: accounts)
        for config in TokenProvider.claudeConfigDirectories(home, environment)
            where config.standardizedFileURL != defaultDirectory.standardizedFileURL {
            let account = accounts.claudeAccount(configDirectory: config)
            if slot.account == account, let credential = readClaudeCredential(keychain: false, configDirectory: config).credential {
                agents.insert((credential, account), at: 0)
            }
        }
        let candidates = claudeCandidates(claudeCode: saved.credential, claudeAccount: codeAccount, agents: agents, target: slot.account)
        guard !candidates.isEmpty else { outcome.note = "no Claude Code, omp or Pi sign-in found for this account"; return outcome }
        let usable = candidates.filter { claudeUsable($0, rejected: rejected, now: Date()) }
        guard !usable.isEmpty else {
            outcome.note = candidates.contains { rejected.contains($0.token.hashValue) } ? "token refused before"
                : "token expired · Claude Code, omp or Pi refresh it when they run"
            return outcome
        }
        for credential in usable {
            let fetched = fetchClaude(token: credential.token)
            switch fetched.answer {
            case .limits(let limits):
                outcome.claude = limits
                outcome.note = nil
                return outcome
            case .rejected:
                outcome.rejected.insert(credential.token.hashValue)
            case .retry:
                outcome.failed = true
            }
            outcome.note = "HTTP \(fetched.status.map(String.init) ?? "no response")"
            if outcome.failed { return outcome }
        }
        return outcome
    }

    /// `--live-limits`: one combined live/record row per account. Only the last four id characters are printed.
    /// Codex live reads are restricted to the default CLI account; other accounts use their own agent records.
    static func commandLineCheck() -> Int32 {
        let accounts = LimitAccountReader()
        accounts.refresh()
        var combined = AgentUsageHistoryReader().read()
        var received = !combined.claude.isEmpty || !combined.codex.isEmpty
        let providers: [TokenSource] = [.codex, .claude]
        var known = Dictionary(uniqueKeysWithValues: providers.map { ($0, accounts.knownAccounts($0)) })
        var defaults: [TokenSource: LimitAccount] = [:]
        var slots = Set<LimitSlot>()
        for provider in providers {
            if let account = accounts.defaultAccount(provider) { defaults[provider] = account }
            for account in known[provider] ?? [] { slots.insert(LimitSlot(provider: provider, account: account)) }
            slots.insert(LimitSlot(provider: provider, account: defaults[provider]))
        }
        for (provider, historyAccounts) in combined.accounts {
            for account in historyAccounts {
                slots.insert(LimitSlot(provider: provider, account: account))
                if !(known[provider] ?? []).contains(account) { known[provider, default: []].append(account) }
            }
        }
        if combined.claude["legacy"] != nil { slots.insert(LimitSlot(provider: .claude, account: nil)) }
        if combined.codex.contains(where: { $0.account == nil }) { slots.insert(LimitSlot(provider: .codex, account: nil)) }
        var notes: [LimitSlot: String] = [:]
        var keychain = true
        for slot in slots.sorted(by: {
            $0.provider.rawValue == $1.provider.rawValue ? ($0.account?.key ?? "") < ($1.account?.key ?? "") : $0.provider.rawValue < $1.provider.rawValue
        }) {
            guard slot.provider == .claude || slot.account == defaults[.codex] else { continue }
            let outcome = Self.read(slot, rejected: [], keychain: keychain)
            if outcome.codex != nil || outcome.claude != nil { received = true }
            if outcome.keychainRefused { keychain = false }
            if let codex = outcome.codex { combined.codex += codex }
            if let claude = outcome.claude {
                let key = slot.account?.storageKey ?? "legacy"
                combined.claude[key] = (combined.claude[key] ?? ClaudeUsageLimits()).merged(claude)
            }
            notes[slot] = outcome.note
        }
        let now = Date()
        // Preserve a successful empty live response's exit status even when it has no dashboard window.
        AppLanguage.with(.en) {
            for slot in slots.sorted(by: {
                $0.provider.rawValue == $1.provider.rawValue ? ($0.account?.key ?? "") < ($1.account?.key ?? "") : $0.provider.rawValue < $1.provider.rawValue
            }) {
                let key = slot.account?.storageKey ?? "legacy"
                let claude: ClaudeLimitsByAccount = slot.provider == .claude ? combined.claude[key].map { [key: $0] } ?? [:] : [:]
                let codex = slot.provider == .codex ? combined.codex.filter { $0.account == slot.account } : []
                let rowDefaults = slot.account.map { [slot.provider: $0] } ?? [:]
                let rows = SessionPresentation.usageLimits(tokens: [], codexReads: codex, claudeLimits: claude,
                                                         defaults: rowDefaults, known: known, now: now)
                let label = slot.account.map { "account …\($0.id.suffix(4))" } ?? "legacy account"
                let text = rows.first.map {
                    return "\($0.value(now: now)) · \($0.details(now: now).first ?? "")"
                        + ($0.otherText(now: now).map { " (\($0))" } ?? "")
                } ?? "no window"
                print("\(slot.provider.title), \(label): \(text)" + (notes[slot].map { " · \($0)" } ?? ""))
            }
        }
        return received ? 0 : 1
    }
}

/// Reads each account slot on its own cadence, one read per slot at a time, with error backoff. Main thread only.
final class LiveLimitPoller {
    private struct State {
        var last: Date?
        var retryAt: Date?
        var failures = 0
        var inFlight = false
        var rejected: Set<Int> = []
    }
    private var states: [LimitSlot: State] = [:]
    private var wasOpen = false
    private var keychainRefused = false
    private let read: (LimitSlot, Set<Int>, Bool) -> LiveLimits.Outcome

    /// `read` is replaced only by the self-test.
    init(read: @escaping (LimitSlot, Set<Int>, Bool) -> LiveLimits.Outcome = LiveLimits.read) { self.read = read }

    /// `live`: whether the account has a running session. `deliver` gets each successful read on the main thread.
    func tick(now: Date, open: Bool, slots: Set<LimitSlot>, live: (LimitSlot) -> Bool, deliver: @escaping (LiveLimits.Outcome) -> Void) {
        let opened = open && !wasOpen
        wasOpen = open
        for accountSlot in slots {
            var state = states[accountSlot] ?? State()
            guard !state.inFlight, LiveLimits.due(last: state.last, retryAt: state.retryAt, now: now, live: live(accountSlot), open: open, opened: opened)
            else { continue }
            state.last = now
            state.inFlight = true
            states[accountSlot] = state
            let rejected = state.rejected, keychain = !keychainRefused, read = read
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let outcome = read(accountSlot, rejected, keychain)
                DispatchQueue.main.async { self?.finish(accountSlot, outcome, deliver) }
            }
        }
    }

    private func finish(_ accountSlot: LimitSlot, _ result: LiveLimits.Outcome, _ deliver: (LiveLimits.Outcome) -> Void) {
        var state = states[accountSlot] ?? State()
        state.inFlight = false
        state.failures = result.failed ? state.failures + 1 : 0
        // Counted from the read's start, on the clock `tick` was given.
        state.retryAt = result.failed ? (state.last ?? Date()).addingTimeInterval(UpdateThrottle.backoff(state.failures)) : nil
        state.rejected.formUnion(result.rejected)
        states[accountSlot] = state
        if result.keychainRefused { keychainRefused = true }
        if result.codex != nil || result.claude != nil {
            var outcome = result
            outcome.slot = accountSlot
            deliver(outcome)
        }
    }
}
