import Foundation
import CommonCrypto

/// Subscription identity lives only in memory. A workspace's members remain separate accounts.
struct LimitAccount: Hashable {
    let id: String
    let email: String?
    let organizationName: String?
    let key: String
    let storageKey: String

    init(id: String, email: String? = nil, organizationName: String? = nil) {
        self.id = Self.normalized(id)
        self.email = email.map(Self.normalized).flatMap { $0.isEmpty ? nil : $0 }
        self.organizationName = organizationName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        self.key = self.id + "|" + (self.email ?? "")
        self.storageKey = String(Self.sha256(self.key).prefix(16))
    }

    static func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var label: String { email ?? loc("계정 …\(id.suffix(4))", "Account …\(id.suffix(4))") }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.email == rhs.email }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(email) }

    static func sha256(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Pin hashes deliberately use the client's original strings, not canonical account values.
    static func credentialPinHash(provider: String, accountID: String?, email: String?, organizationID: String?, projectID: String?) -> String {
        sha256([provider, accountID ?? "", email ?? "", organizationID ?? "", projectID ?? ""].joined(separator: "\u{0}"))
    }
}

struct LimitSlot: Hashable {
    var provider: TokenSource
    var account: LimitAccount?
}

/// Reads selected identity metadata only. Auth tokens are neither decoded nor retained; credentials never leave SQLite.
final class LimitAccountReader {
    static let maximumConfigBytes = 16 << 20
    static let credentialQuery = """
        SELECT provider, json_extract(data, '$.accountId'), json_extract(data, '$.email'),
               json_extract(data, '$.orgId'), json_extract(data, '$.projectId'), json_extract(data, '$.orgName')
        FROM auth_credentials WHERE provider IN ('anthropic', 'openai-codex') AND credential_type = 'oauth'
        """

    private struct ClaudeConfig: Decodable {
        struct Account: Decodable {
            var accountUuid: String?
            var emailAddress: String?
            var organizationName: String?
            var organizationUuid: String?
        }
        var oauthAccount: Account?
    }
    private struct CodexConfig: Decodable {
        struct Metadata: Decodable { var account_id: String? }
        var tokens: Metadata?
    }
    private struct Config {
        var stamp: [Int64]
        var account: LimitAccount?
        var organizationID: String?
    }
    private struct Credential {
        var provider: TokenSource
        var hash: String
        var account: LimitAccount
    }
    private struct Root {
        var prefixes: [String]
        var source: TokenSource
        var metadata: URL
    }
    struct RootAccount {
        var account: LimitAccount?
        var switchedAt: Date?
    }
    private let home: URL
    private let environment: [String: String]
    private var roots: [Root] = []
    private var clones: [(source: TokenSource, prefixes: [String])] = []
    private var configs: [URL: Config] = [:]
    private var credentials: [URL: (stamp: [Int64], values: [Credential])] = [:]
    /// Observations survive metadata cache invalidation; identity and switch times are memory-only.
    private var observedRoots: [URL: RootAccount] = [:]
    private var defaults: [TokenSource: LimitAccount] = [:]
    private var accounts: [TokenSource: [LimitAccount]] = [:]
    private(set) var defaultClaudeOrganizationID: String?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    private static func prefixes(_ url: URL) -> [String] {
        Array(Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path])).map { $0 + "/" }
    }
    private func claudeConfig(_ directory: URL) -> URL {
        directory.standardizedFileURL == home.appendingPathComponent(".claude").standardizedFileURL
            ? home.appendingPathComponent(".claude.json") : directory.appendingPathComponent(".claude.json")
    }
    private var defaultClaudeConfig: URL {
        environment.paths("CLAUDE_CONFIG_DIR").first.map(claudeConfig) ?? home.appendingPathComponent(".claude.json")
    }
    private var defaultCodexConfig: URL {
        (environment.path("CODEX_HOME") ?? home.appendingPathComponent(".codex")).appendingPathComponent("auth.json")
    }

    func refresh(now: Date = Date()) {
        roots = TokenProvider.claudeConfigDirectories(home, environment).map {
            Root(prefixes: Self.prefixes($0.appendingPathComponent("projects")), source: .claude, metadata: claudeConfig($0))
        }
        roots += [environment.path("CODEX_HOME"), home.appendingPathComponent(".codex")].compactMap { $0 }.map {
            Root(prefixes: Self.prefixes($0.appendingPathComponent("sessions")), source: .codex, metadata: $0.appendingPathComponent("auth.json"))
        }
        let ompRoots = TokenProvider.all.first { $0.source == .omp }?.roots(home, environment) ?? []
        let piSessionRoot = environment.path("PI_CODING_AGENT_SESSION_DIR")
        roots += ompRoots.map {
            let agent = $0.standardizedFileURL == piSessionRoot?.standardizedFileURL
                ? (environment.path("PI_CODING_AGENT_DIR") ?? home.appendingPathComponent(".pi/agent")) : $0.deletingLastPathComponent()
            return Root(prefixes: Self.prefixes($0), source: .omp, metadata: agent.appendingPathComponent("agent.db"))
        }
        clones = TokenClientRoots.all.filter { $0.source != .omp }.flatMap { client in
            client.roots(home, environment).map { (client.source, Self.prefixes($0)) }
        }
        let configURLs = Set(roots.filter { $0.source != .omp }.map(\.metadata) + [defaultClaudeConfig, defaultCodexConfig, home.appendingPathComponent(".claude.json")])
        for url in configURLs { readConfig(url) }
        configs = configs.filter { configURLs.contains($0.key) }
        let databases = Set(roots.filter { $0.source == .omp }.map(\.metadata))
        credentials = credentials.filter { databases.contains($0.key) }
        for database in databases {
            guard let stamp = OpenCodeDatabase.signature(database.path) else { credentials[database] = nil; continue }
            guard credentials[database]?.stamp != stamp else { continue }
            guard let connection = OpenCodeDatabase(path: database.path) else { continue }
            var values: [Credential] = []
            guard connection.query(Self.credentialQuery, row: { row in
                guard let rawProvider = row.text(0), let id = row.text(1), !LimitAccount.normalized(id).isEmpty else { return }
                let provider: TokenSource = rawProvider == "anthropic" ? .claude : .codex
                let email = row.text(2)
                let hash = LimitAccount.credentialPinHash(provider: rawProvider, accountID: id, email: email,
                                                         organizationID: row.text(3), projectID: row.text(4))
                values.append(Credential(provider: provider, hash: hash, account: LimitAccount(id: id, email: email, organizationName: row.text(5))))
            }) else { continue }
            credentials[database] = (stamp, values)
        }
        accounts = [:]
        for credential in credentials.values.flatMap(\.values) { add(credential.account, provider: credential.provider) }
        let claude = (roots.filter { $0.source == .claude }.map(\.metadata) + [defaultClaudeConfig])
            .compactMap { configAccount($0, provider: .claude) }
        for account in claude where account.email != nil { add(account, provider: .claude) }
        // A partial config identity cannot count itself as another known member during resolution.
        let resolvedClaude = claude.compactMap {
            resolve(provider: .claude, id: $0.id, email: $0.email, organizationName: $0.organizationName)
        }
        for account in resolvedClaude { add(account, provider: .claude) }
        // Resolve missing e-mails before adding auth.json's partial identities to the known set.
        let codex = roots.filter { $0.source == .codex }.compactMap { root in
            configs[root.metadata]?.account.flatMap { resolve(provider: .codex, id: $0.id, email: $0.email) }
        }
        defaults = [:]
        defaults[.claude] = configAccount(defaultClaudeConfig, provider: .claude).flatMap {
            resolve(provider: .claude, id: $0.id, email: $0.email, organizationName: $0.organizationName)
        }
        defaults[.codex] = configs[defaultCodexConfig]?.account.flatMap { resolve(provider: .codex, id: $0.id, email: $0.email) }
        for account in codex { add(account, provider: .codex) }
        defaultClaudeOrganizationID = configMetadata(defaultClaudeConfig, provider: .claude)?.organizationID
        for provider in Array(accounts.keys) { accounts[provider]?.sort { $0.key < $1.key } }
        for root in roots where root.source == .claude || root.source == .codex {
            let key = root.metadata.standardizedFileURL
            let account = configAccount(root.metadata, provider: root.source).flatMap {
                resolve(provider: root.source, id: $0.id, email: $0.email, organizationName: $0.organizationName)
            }
            if var previous = observedRoots[key] {
                if previous.account != account {
                    previous.account = account
                    previous.switchedAt = now
                    observedRoots[key] = previous
                }
            } else {
                observedRoots[key] = RootAccount(account: account, switchedAt: nil)
            }
        }
    }

    private func add(_ account: LimitAccount, provider: TokenSource) {
        if !accounts[provider, default: []].contains(account) { accounts[provider, default: []].append(account) }
    }
    private func readConfig(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_size >= 0, info.st_size <= Int64(Self.maximumConfigBytes) else { configs[url] = nil; return }
        let stamp = [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
        guard configs[url]?.stamp != stamp else { return }
        var value = Config(stamp: stamp)
        if let data = try? Data(contentsOf: url) {
            if url.lastPathComponent == "auth.json" {
                if let id = (try? JSONDecoder().decode(CodexConfig.self, from: data))?.tokens?.account_id, !LimitAccount.normalized(id).isEmpty {
                    value.account = LimitAccount(id: id)
                }
            } else if let metadata = (try? JSONDecoder().decode(ClaudeConfig.self, from: data))?.oauthAccount {
                if let id = metadata.accountUuid, !LimitAccount.normalized(id).isEmpty {
                    value.account = LimitAccount(id: id, email: metadata.emailAddress, organizationName: metadata.organizationName)
                }
                value.organizationID = metadata.organizationUuid
            }
        }
        configs[url] = value
    }
    private func configMetadata(_ url: URL, provider: TokenSource) -> Config? {
        if let config = configs[url] { return config }
        let legacy = (environment.path("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")).appendingPathComponent("claude/.claude.json")
        if provider == .claude, url == legacy { return configs[home.appendingPathComponent(".claude.json")] }
        return nil
    }
    private func configAccount(_ url: URL, provider: TokenSource) -> LimitAccount? {
        configMetadata(url, provider: provider)?.account
    }
    func defaultAccount(_ provider: TokenSource) -> LimitAccount? { defaults[provider] }
    func knownAccounts(_ provider: TokenSource) -> [LimitAccount] { accounts[provider] ?? [] }

    func resolve(provider: TokenSource, id: String?, email: String?, organizationName: String? = nil) -> LimitAccount? {
        guard let id else { return nil }
        let normalizedID = LimitAccount.normalized(id)
        guard !normalizedID.isEmpty else { return nil }
        let normalizedEmail = email.map(LimitAccount.normalized).flatMap { $0.isEmpty ? nil : $0 }
        let matching = knownAccounts(provider).filter { $0.id == normalizedID }
        let known = normalizedEmail == nil && matching.count == 1 ? matching.first
            : matching.first { $0.email == normalizedEmail }
        if let known {
            if organizationName == nil || organizationName == known.organizationName { return known }
            return LimitAccount(id: known.id, email: known.email, organizationName: organizationName)
        }
        return LimitAccount(id: normalizedID, email: normalizedEmail, organizationName: organizationName)
    }
    private func root(source: TokenSource, path: String) -> Root? {
        let paths = [URL(fileURLWithPath: path).standardizedFileURL.path, URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path]
        if clones.contains(where: { clone in clone.source == source && clone.prefixes.contains { prefix in paths.contains { $0.hasPrefix(prefix) } } }) { return nil }
        return roots.filter { root in root.source == source && root.prefixes.contains { prefix in paths.contains { $0.hasPrefix(prefix) } } }
            .max { ($0.prefixes.map(\.count).max() ?? 0) < ($1.prefixes.map(\.count).max() ?? 0) }
    }
    func account(source: TokenSource, path: String) -> LimitAccount? {
        guard source == .claude || source == .codex, let root = root(source: source, path: path),
              let account = configAccount(root.metadata, provider: source) else { return nil }
        return resolve(provider: source, id: account.id, email: account.email, organizationName: account.organizationName)
    }
    func observedAccount(source: TokenSource, path: String) -> RootAccount? {
        guard source == .claude || source == .codex, let root = root(source: source, path: path) else { return nil }
        return observedRoots[root.metadata.standardizedFileURL]
    }
    func claudeAccount(configDirectory: URL) -> LimitAccount? {
        let directory = configDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let knownDirectory = TokenProvider.claudeConfigDirectories(home, environment).first {
            $0.standardizedFileURL.resolvingSymlinksInPath() == directory
        }
        guard let knownDirectory, let account = configAccount(claudeConfig(knownDirectory), provider: .claude) else { return nil }
        return resolve(provider: .claude, id: account.id, email: account.email, organizationName: account.organizationName)
    }
    func pinnedAccount(provider: TokenSource, hash: String, path: String) -> LimitAccount? {
        guard let root = root(source: .omp, path: path) else { return nil }
        let matches = credentials[root.metadata]?.values.filter { $0.provider == provider && $0.hash == hash } ?? []
        let distinct = Set(matches.map(\.account))
        return distinct.count == 1 ? matches.first?.account : nil
    }
}
