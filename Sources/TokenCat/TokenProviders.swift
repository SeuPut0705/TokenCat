import Foundation

/// The provider registry: one entry per client TokenCat recognises, in `TokenSource` order.
/// Adding a client takes one parser file (a `TokenLogFormat` whose `open` returns a `TokenLogReader`) and its `format:` here.
/// - `roots`: the client's data folders, environment overrides first. A client counts as detected when one exists; only
///   existing roots are listed, and `TokenTracker.watchedDirectories` names the roots of clients that have a format.
/// - `format` nil: detected, never read — no rows, counts or speeds. Allowed only while that client's parser is pending.
/// Telemetry setup covers `TokenSource.telemetryClients`; live limits and the status line bridge stay with
/// `TokenSource.defaultClients` (Codex and Claude Code).
/// Windows mirrors this as `TokenProvider.All` (TokenProviders.cs).
struct TokenProvider {
    let source: TokenSource
    let roots: (_ home: URL, _ environment: [String: String]) -> [URL]
    let format: TokenLogFormat?

    static let all: [TokenProvider] = [
        // CODEX_HOME moves Codex's state; ~/.codex stays a fallback for a GUI session that lacks the shell's variable.
        TokenProvider(source: .codex, roots: { home, env in
            [env.path("CODEX_HOME"), home.appendingPathComponent(".codex")].compactMap { $0?.appendingPathComponent("sessions") }
                + TokenClientRoots.roots(of: .codex, home, env)
        }, format: .codex),
        TokenProvider(source: .claude, roots: { home, env in
            claudeConfigDirectories(home, env).map { $0.appendingPathComponent("projects") } + TokenClientRoots.roots(of: .claude, home, env)
        }, format: .claude),
        // OpenCode and the apps built on its store (Kilo Code, MiMo Code): each app's data folder and its `<APP>_DB` file's.
        TokenProvider(source: .opencode, roots: { home, env in
            OpenCodeApp.all.flatMap { [$0.databasePath(home, env)?.deletingLastPathComponent(), $0.dataFolder(home, env)] }.compactMap { $0 }
        }, format: .opencode),
        // GEMINI_CLI_HOME replaces home; under the macOS Seatbelt sandbox (SANDBOX=sandbox-exec) Gemini CLI keeps its
        // runtime files in ~/.cache/.gemini instead.
        TokenProvider(source: .gemini, roots: { home, env in
            let base = env.path("GEMINI_CLI_HOME") ?? home
            return [base.appendingPathComponent(".gemini/tmp"), base.appendingPathComponent(".cache/.gemini/tmp")]
        }, format: .gemini),
        // Qwen keeps sessions under its runtime dir: $QWEN_RUNTIME_DIR, else $QWEN_HOME, else ~/.qwen.
        TokenProvider(source: .qwen, roots: { home, env in
            [env.path("QWEN_RUNTIME_DIR"), env.path("QWEN_HOME"), home.appendingPathComponent(".qwen")]
                .compactMap { $0?.appendingPathComponent("projects") }
        }, format: .qwen),
        TokenProvider(source: .copilot, roots: { home, env in
            [(env.path("COPILOT_HOME") ?? home.appendingPathComponent(".copilot")).appendingPathComponent("session-state")]
        }, format: .copilot),
        // AMP_DATA_DIR (a parser convention, not an Amp setting) names the folder that holds threads/.
        TokenProvider(source: .amp, roots: { home, env in
            [env.path("AMP_DATA_DIR"), dataHome(home, env).appendingPathComponent("amp")].compactMap { $0?.appendingPathComponent("threads") }
        }, format: .amp),
        // Cline-format extensions in any VS Code family editor, then Cline's shared store (CLINE_DIR → ~/.cline,
        // CLINE_DATA_DIR → <it>/data): `tasks` from the extension and JetBrains, `sessions` (CLINE_SESSION_DATA_DIR) from the CLI.
        TokenProvider(source: .cline, roots: { home, env in
            let data = env.path("CLINE_DATA_DIR") ?? (env.path("CLINE_DIR") ?? home.appendingPathComponent(".cline")).appendingPathComponent("data")
            let defaultData = home.appendingPathComponent(".cline/data")
            return extensionTaskRoots(in: home.appendingPathComponent("Library/Application Support"))
                + [env.path("CLINE_SESSION_DATA_DIR") ?? data.appendingPathComponent("sessions"), data.appendingPathComponent("tasks"),
                   defaultData.appendingPathComponent("sessions"), defaultData.appendingPathComponent("tasks")]
        }, format: .cline),
        // omp and Pi both move their agent folder to $PI_CODING_AGENT_DIR; sessions live in its `sessions`. omp names its
        // folder ~/$PI_CONFIG_DIR (default .omp), keeps named profiles in <it>/profiles/<name>/agent, and with $XDG_DATA_HOME/omp
        // present (after `omp config migrate`) writes sessions to $XDG_DATA_HOME/omp[/profiles/<name>]/sessions.
        TokenProvider(source: .omp, roots: { home, env in
            let configs = [env["PI_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : home.appendingPathComponent($0) }, home.appendingPathComponent(".omp")]
                .compactMap { $0 }
            let xdg = env.path("XDG_DATA_HOME")?.appendingPathComponent("omp")
            let profiles: [URL] = configs.flatMap { subfolders($0.appendingPathComponent("profiles")).map { $0.appendingPathComponent("agent") } }
            let agents: [URL] = [env.path("PI_CODING_AGENT_DIR")].compactMap { $0 } + configs.map { $0.appendingPathComponent("agent") }
                + [home.appendingPathComponent(".pi/agent")] + profiles
            let xdgData: [URL] = xdg.map { [$0] + subfolders($0.appendingPathComponent("profiles")) } ?? []
            return (agents + xdgData).map { $0.appendingPathComponent("sessions") } + TokenClientRoots.roots(of: .omp, home, env)
        }, format: .omp),
        // FACTORY_HOME_OVERRIDE replaces the home folder for droid's own session store.
        TokenProvider(source: .droid, roots: { home, env in
            [env.path("FACTORY_HOME_OVERRIDE"), home].compactMap { $0?.appendingPathComponent(".factory/sessions") }
        }, format: .droid),
        // Cursor agent transcripts (IDE and cursor-agent CLI). CURSOR_CONFIG_DIR moves the CLI's config folder; ~/.cursor stays
        // the IDE's, so both are listed.
        TokenProvider(source: .cursor, roots: { home, env in
            [env.path("CURSOR_CONFIG_DIR"), home.appendingPathComponent(".cursor")].compactMap { $0?.appendingPathComponent("projects") }
        }, format: .cursor),
        // Grok Build keeps sessions under $GROK_HOME (default ~/.grok); its logs/unified.jsonl is read beside them.
        TokenProvider(source: .grok, roots: { home, env in
            [(env.path("GROK_HOME") ?? home.appendingPathComponent(".grok")).appendingPathComponent("sessions")]
        }, format: .grok),
        // HERMES_HOME may name a profile (<root>/profiles/<name>); the root lists every profile's state.db.
        TokenProvider(source: .hermes, roots: { home, env in
            [env.path("HERMES_HOME").map(HermesLog.root), home.appendingPathComponent(".hermes")].compactMap { $0 }
        }, format: .hermes),
        // OpenClaw's state dir: $OPENCLAW_STATE_DIR, else `.openclaw` (`.openclaw-<name>` for a named $OPENCLAW_PROFILE) in
        // $OPENCLAW_HOME or home. Before the rename it was ~/.clawdbot (until v2026.3.22 also ~/.moltbot).
        TokenProvider(source: .openclaw, roots: { home, env in
            let base = env.path("OPENCLAW_HOME") ?? home
            let profile = env["OPENCLAW_PROFILE"].flatMap { name -> URL? in
                guard !name.isEmpty, name.lowercased() != "default",
                      name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else { return nil }
                return base.appendingPathComponent(".openclaw-\(name)")
            }
            return [env.path("OPENCLAW_STATE_DIR"), profile, base.appendingPathComponent(".openclaw"), home.appendingPathComponent(".openclaw"),
                    home.appendingPathComponent(".clawdbot"), home.appendingPathComponent(".moltbot")].compactMap { $0?.appendingPathComponent("agents") }
        }, format: .openclaw),
        // Goose (etcetera's XDG strategy on macOS too): $GOOSE_PATH_ROOT/data, else $XDG_DATA_HOME/goose or ~/.local/share/goose.
        TokenProvider(source: .goose, roots: { home, env in
            [env.path("GOOSE_PATH_ROOT")?.appendingPathComponent("data"), dataHome(home, env).appendingPathComponent("goose")]
                .compactMap { $0?.appendingPathComponent("sessions") }
        }, format: .goose),
        // Kimi Code ($KIMI_CODE_HOME), the Kimi desktop app's embedded Kimi Code (Kimi Work), then the archived kimi-cli
        // ($KIMI_SHARE_DIR); each keeps its sessions in `sessions`.
        TokenProvider(source: .kimi, roots: { home, env in
            [env.path("KIMI_CODE_HOME") ?? home.appendingPathComponent(".kimi-code"),
             home.appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home"),
             env.path("KIMI_SHARE_DIR") ?? home.appendingPathComponent(".kimi")]
                .map { $0.appendingPathComponent("sessions") }
        }, format: .kimi),
    ]

    /// Cline-format VS Code extensions and the product each one is (nil: Cline itself).
    static let vscodeExtensions: [(id: String, client: String?)] = [
        ("saoudrizwan.claude-dev", nil), ("rooveterinaryinc.roo-cline", "Roo Code"), ("kilocode.kilo-code", "Kilo Code"),
        ("zoocodeorganization.zoo-code", "Zoo Code"), ("ibm.bob-code", "IBM Bob"),
    ]

    /// `<editor>/User/globalStorage/<extension>/tasks` for every VS Code family editor in `support` (Code, Cursor, Windsurf,
    /// Antigravity, Kiro, IBM Bob, …): one listing plus one stat per folder, so no list of editor names goes stale.
    static func extensionTaskRoots(in support: URL) -> [URL] {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        return apps.sorted().flatMap { app -> [URL] in
            let storage = support.appendingPathComponent(app).appendingPathComponent("User/globalStorage")
            guard FileManager.default.fileExists(atPath: storage.path) else { return [] }
            return vscodeExtensions.map { storage.appendingPathComponent($0.id).appendingPathComponent("tasks") }
        }
    }

    /// Claude Code's config folders: `CLAUDE_CONFIG_DIR` (one folder; a comma-separated list as ccusage reads it), then
    /// `$XDG_CONFIG_HOME/claude` (default ~/.config/claude, ccusage's legacy location) and ~/.claude.
    static func claudeConfigDirectories(_ home: URL, _ environment: [String: String]) -> [URL] {
        let configured = environment.paths("CLAUDE_CONFIG_DIR")
        return configured + [(environment.path("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")).appendingPathComponent("claude"),
                             home.appendingPathComponent(".claude")]
    }

    /// Visible subfolders of `directory`, by name; empty when it is missing.
    static func subfolders(_ directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `$XDG_DATA_HOME`, else ~/.local/share (OpenCode and Amp use it on macOS too).
    static func dataHome(_ home: URL, _ environment: [String: String]) -> URL {
        environment.path("XDG_DATA_HOME") ?? home.appendingPathComponent(".local/share")
    }

    func existingRoots(home: URL, environment: [String: String]) -> [URL] {
        var seen = Set<String>()
        return roots(home, environment).filter { seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Clients whose logs TokenCat reads, in registry order.
    static var readSources: [TokenSource] { all.filter { $0.format != nil }.map(\.source) }

    /// Their default roots with "~" for home: "~/.codex/sessions · ~/.claude/projects".
    static func readRootsText(home: URL) -> String {
        let prefix = home.path + "/"
        return all.filter { $0.format != nil }.flatMap { $0.roots(home, [:]) }
            .map { $0.path.hasPrefix(prefix) ? "~/" + $0.path.dropFirst(prefix.count) : $0.path }.joined(separator: " · ")
    }
}

/// Folders where another product writes a read source's log format. They join that source's roots, and the tracker labels
/// rows read under them with `clientName` (the reader's own label wins). A clone's account limits are not the source's
/// subscription, so the tracker drops them; telemetry still matches by session ID, which is unique per log.
struct TokenClientRoots {
    let source: TokenSource
    let clientName: String
    let roots: (_ home: URL, _ environment: [String: String]) -> [URL]

    static let all: [TokenClientRoots] = [
        // TRAE CLI (TraeX), a codex-rs fork: Codex rollouts in ~/.trae/cli/sessions/YYYY/MM/DD. TRAEX_SESSIONS_DIR is
        // agentsview's convention, not a TRAE setting.
        TokenClientRoots(source: .codex, clientName: "TRAE CLI", roots: { home, env in
            [env.path("TRAEX_SESSIONS_DIR"), home.appendingPathComponent(".trae/cli/sessions")].compactMap { $0 }
        }),
        // OpenClaude, a Claude Code fork with its own config folder ($OPENCLAUDE_CONFIG_DIR; ~/.openclaude kept as fallback).
        TokenClientRoots(source: .claude, clientName: "OpenClaude", roots: { home, env in
            [env.path("OPENCLAUDE_CONFIG_DIR"), home.appendingPathComponent(".openclaude")].compactMap { $0?.appendingPathComponent("projects") }
        }),
        // Qoder writes Claude Code transcripts: ~/.qoder (CLI), ~/.qoder-cn (China build), the IDE's SharedClientCache.
        TokenClientRoots(source: .claude, clientName: "Qoder", roots: { home, _ in
            [".qoder/projects", ".qoder-cn/projects", "Library/Application Support/Qoder/SharedClientCache/cli/projects"]
                .map { home.appendingPathComponent($0) }
        }),
        // Pi's own sessions folder override (omp has none); logs in ~/.pi/agent are labelled by the omp reader.
        TokenClientRoots(source: .omp, clientName: "Pi", roots: { _, env in [env.path("PI_CODING_AGENT_SESSION_DIR")].compactMap { $0 } }),
    ]

    static func roots(of source: TokenSource, _ home: URL, _ environment: [String: String]) -> [URL] {
        all.filter { $0.source == source }.flatMap { $0.roots(home, environment) }
    }
}

/// How a client's logs are listed and read. Every closure runs on the tracker's queue.
struct TokenLogFormat {
    /// Logs worth tracking under the client's existing `roots`. Rank and cap them with `discovery.recent`, so every listed
    /// path is also `known` (a write to a log the caps left out then opens it directly instead of forcing a rescan).
    let files: (_ roots: [URL], _ discovery: TokenDiscovery) -> [URL]
    /// Whether a path from a file event is a log `files` would list; an untracked one triggers discovery on the next sample.
    let isLog: (_ path: String) -> Bool
    /// The reader for one listed log, kept while discovery lists it or `isRecent` holds.
    let open: (_ url: URL) -> TokenLogReader
}

/// Reads one tracked log (a file or a database) and reports its sessions. Never stores transcript text.
protocol TokenLogReader: AnyObject {
    /// Called once per sample: read what changed since the last call. `tailLimit` bounds the first read of a large log.
    func read(tailLimit: Int, now: Date)
    /// The log's sessions now; empty until something countable was read. `id` is the stable row id
    /// ("<source>:<path relative to home>"); a log holding several sessions appends "#<session>" for each row.
    func readings(id: String, now: Date) -> [TokenReading]
    /// Keeps the reader past the discovery caps: an open turn, or a log written within the hour.
    func isRecent(at now: Date) -> Bool
}

/// Discovery helpers shared by every format; one per discovery pass.
final class TokenDiscovery {
    let now: Date
    /// Every log the caps were applied to, inside them or not.
    private(set) var known = Set<String>()

    init(now: Date) { self.now = now }

    /// Visible entries of `directory`; empty when it is missing or unreadable.
    func children(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    /// Whether a `children` entry is a folder (its type was fetched with the listing). Folder names may hold dots
    /// (a Droid slug of `~/my.project`), so the extension tells nothing.
    func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == false
    }

    /// The 32 newest, plus up to 32 more modified since `cutoff` (the retention hour), so a cold start opens them too.
    func recent(_ urls: [URL], keepingSince cutoff: Date = .distantFuture) -> [URL] {
        let dated: [(url: URL, modified: Date)] = urls
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        known.formUnion(dated.map(\.url.path))
        return dated.sorted { $0.modified > $1.modified }.enumerated()
            .filter { $0.offset < 32 || ($0.offset < 64 && $0.element.modified >= cutoff) }.map { $0.element.url }
    }
}

extension Dictionary where Key == String, Value == String {
    /// A non-empty environment value as a file URL.
    func path(_ key: String) -> URL? {
        self[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// A comma-separated list of folders (blank entries skipped), each as `path` reads one.
    func paths(_ key: String) -> [URL] {
        (self[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}
