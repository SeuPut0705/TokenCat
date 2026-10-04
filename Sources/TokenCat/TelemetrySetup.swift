import Foundation
import CryptoKit
import Darwin

struct TelemetrySetupResult {
    var changedFiles: [String]
    var restartRequired: [TokenSource]
    var message: String
    /// What the CLI message says about the Claude Code status line, for the app to show without reading the message.
    var notes: [TelemetrySetupNote] = []
    /// Claude Code settings run the status line bridge after this call.
    var bridged = false
}

/// A status line outcome beside a successful connection; `text` is the sentence the CLI message carries.
enum TelemetrySetupNote: Equatable {
    /// `statusLine` is not a command: the usage-limit bridge was not added.
    case statusLineSkipped
    /// Settings run the bridge, but no original command is known here: the status line prints nothing.
    case originalUnknown
    /// The bridge's missing original command was written again from the connection record.
    case originalRecreated

    var text: String {
        switch self {
        case .statusLineSkipped: return loc("Claude Code statusLine 형식이 예상과 달라 사용량 한도 연결은 건너뛰었습니다.",
                                            "Claude Code's statusLine isn't in the expected format, so the usage limit connection was skipped.")
        case .originalUnknown: return loc("Claude Code 상태 표시줄이 TokenCat 브리지를 가리키지만 원래 명령을 찾을 수 없어 상태 표시줄이 비어 보입니다. settings.json의 statusLine을 직접 고쳐 주세요.",
                                          "The Claude Code status line runs the TokenCat bridge, but its original command can't be found, so the status line shows nothing. Edit statusLine in settings.json to fix it.")
        case .originalRecreated: return loc("Claude Code 상태 표시줄의 원래 명령을 백업 기록에서 다시 만들었습니다.",
                                            "Recreated the Claude Code status line's original command from the backup record.")
        }
    }
}

/// What the UI says about a failed automatic connection, without reading message text.
enum TelemetrySetupFailure: Equatable {
    case conflict, invalid, unavailable
    case writeFailed(restored: Bool)
}

enum TelemetrySetupError: LocalizedError {
    case conflict(String)
    case invalid(String)
    case writeFailed(restored: Bool)

    var errorDescription: String? {
        switch self {
        case .conflict(let reason), .invalid(let reason): return reason
        case .writeFailed(let restored):
            return restored ? loc("설정 저장에 실패하여 원래 설정으로 복구했습니다.", "Couldn't save the settings, so the original settings were restored.")
                : loc("설정 저장 중 일부 파일이 변경됐습니다. 사용자 변경을 보존했으며 백업에서 개별 확인이 필요합니다.",
                      "Some files changed while the settings were being saved. Your changes were kept; check each file against its backup.")
        }
    }
}

extension TelemetrySetupError {
    var failure: TelemetrySetupFailure {
        switch self {
        case .conflict: return .conflict
        case .invalid: return .invalid
        case .writeFailed(let restored): return .writeFailed(restored: restored)
        }
    }
}

/// Owns only the opt-in, loopback telemetry settings. It does not restart either client.
final class TelemetrySetup {
    static let port = Int(LocalTelemetryCollector.port)
    /// Set by `--disconnect-telemetry` (even when it refuses) and cleared by `--connect-telemetry`; the app does not
    /// connect automatically while it is set.
    static let optOutKey = "telemetryDisconnected"
    /// The Claude Code env values TokenCat sets. Disconnecting an edited file reverts only keys that still hold them.
    private static let claudeEnv: [String: String] = {
        let endpoint = "http://127.0.0.1:\(port)"
        return ["CLAUDE_CODE_ENABLE_TELEMETRY": "1", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
                "OTEL_LOGS_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
                "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "\(endpoint)/v1/logs", "OTEL_LOGS_EXPORT_INTERVAL": "1000",
                "OTEL_TRACES_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json",
                "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "\(endpoint)/v1/traces", "OTEL_TRACES_EXPORT_INTERVAL": "1000"]
    }()
    /// Content-logging switches; TokenCat sets an enabled one to "0".
    private static let claudeLogKeys = ["OTEL_LOG_USER_PROMPTS", "OTEL_LOG_ASSISTANT_RESPONSES", "OTEL_LOG_TOOL_DETAILS",
                                        "OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_RAW_API_BODIES"]
    /// The Codex `[otel]` exporters TokenCat writes, in the order it appends them.
    private static let codexExporters: [(key: String, value: String)] = [("exporter", "logs"), ("metrics_exporter", "metrics"),
                                                                          ("trace_exporter", "traces")].map {
        ($0.0, "{ otlp-http = { endpoint = \"http://127.0.0.1:\(port)/v1/\($0.1)\", protocol = \"json\" } }")
    }
    private static let mutationLock = NSLock()
    private let home: URL
    private let files = FileManager.default
    private var support: URL { home.appendingPathComponent("Library/Application Support/TokenCat", isDirectory: true) }
    private var activeManifest: URL { support.appendingPathComponent("telemetry-connection.json") }
    private var bridgeScript: URL { support.appendingPathComponent(Self.statusLineScriptName) }
    private var bridgeOriginal: URL { support.appendingPathComponent(Self.statusLineOriginalName) }

    /// Claude Code writes its usage limits only to the JSON it pipes to a statusLine command, so TokenCat wraps that
    /// command: the bridge forwards a copy to the loopback collector and runs the original command on the same input.
    static let statusLineScriptName = "claude-statusline.sh"
    /// The original statusLine command as raw bytes, read by the bridge; absent when there was none.
    static let statusLineOriginalName = "claude-statusline-command"
    /// `$HOME` keeps the account's home path out of settings.json; Claude Code runs the command through a shell. The script
    /// and the original command live only in this Mac's Application Support, so a copy of settings.json on another Mac (or
    /// after that folder is deleted) runs nothing useful until TokenCat writes them there.
    static let statusLineCommand = "/bin/sh \"$HOME/Library/Application Support/TokenCat/\(statusLineScriptName)\""
    /// Any spelling of a command that runs the bridge script (an expanded home, other quoting): never wrapped again, and the
    /// script stays while one names it.
    static func runsBridge(_ command: String) -> Bool { command.contains("/Library/Application Support/TokenCat/\(statusLineScriptName)") }
    /// Migration only: the Claude Code settings right before the bridge was added to an existing connection.
    static let preBridgeBackupName = "claude-settings-before-statusline.json"
    /// The copy runs detached with every descriptor on /dev/null, so Claude Code's pipe closes when the original
    /// command ends, whether TokenCat is absent or slow. `-q` skips ~/.curlrc and `--noproxy` keeps it on loopback.
    static let statusLineScript = """
        #!/bin/sh
        # TokenCat: Claude Code status line bridge. TokenCat --disconnect-telemetry puts the previous status line back while settings.json still runs this script; if it cannot, the original command stays in \(statusLineOriginalName) beside this file.
        # Sends Claude Code's status JSON to TokenCat on 127.0.0.1 only (TokenCat keeps the usage limits, nothing else),
        # then runs the original status line command with the same input; its output and exit status pass through.
        [ -n "${TOKENCAT_STATUSLINE_BRIDGE:-}" ] && exit 0
        input=$(cat; printf x)
        input=${input%x}
        { printf '%s' "$input" | /usr/bin/curl -q -s -o /dev/null --noproxy '*' --connect-timeout 1 --max-time 2 \\
            -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:\(port)\(LocalTelemetryCollector.claudeStatusPath); } \\
            </dev/null >/dev/null 2>&1 &
        sidecar="${0%/*}/\(statusLineOriginalName)"
        [ -s "$sidecar" ] || exit 0
        original=$(cat "$sidecar") || exit 0
        TOKENCAT_STATUSLINE_BRIDGE=1
        export TOKENCAT_STATUSLINE_BRIDGE
        printf '%s' "$input" | /bin/sh -c "$original"

        """

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    private struct Change {
        let source: TokenSource
        let url: URL
        let original: Data?
        let replacement: Data
        let permissions: Int
    }

    private struct Manifest: Codable {
        var version: Int = 1
        var backupDirectory: String
        var entries: [Entry]
        /// Present once TokenCat wrapped the Claude Code status line; manifests from before the bridge have none.
        var statusLine: StatusLine?
        struct Entry: Codable {
            var source: TokenSource
            var existed: Bool
            var permissions: Int
            var originalSHA256: String?
            var connectedSHA256: String
        }
        struct StatusLine: Codable {
            /// The replaced `statusLine` object as JSON text; nil when settings had none.
            var original: String?
            /// Migration only: the settings before the bridge (backed up as `preBridgeBackupName`) and the bridged result.
            /// While the file is still exactly the bridged result, a refused whole-file restore puts those bytes back.
            var preBridgeSHA256: String? = nil
            var bridgedSHA256: String? = nil
        }
    }

    func connect() throws -> TelemetrySetupResult {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        // Validate both clients before touching either configuration.
        let codexURL = configURL(.codex)
        let claudeURL = configURL(.claude)
        let codex = try read(codexURL)
        let claude = try read(claudeURL)
        let connected = files.fileExists(atPath: activeManifest.path)
        let manifest = connected ? (try? read(activeManifest)).flatMap(validated) : nil
        let codexAfter = try codexConfiguration(codex)
        let plan = try claudeConfiguration(claude, bridgedBefore: manifest?.statusLine != nil)
        let candidates = [Change(source: .codex, url: codexURL, original: codex,
                                 replacement: codexAfter, permissions: try permissions(codexURL)),
                          Change(source: .claude, url: claudeURL, original: claude,
                                 replacement: plan.data, permissions: try permissions(claudeURL))]
        let changes = candidates.filter { $0.original != $0.replacement }
        // Settings that already run the bridge (not wrapped now) need its original command beside it.
        let bridgeNote = plan.bridged && !plan.wraps ? bridgeOriginalNote(manifest) : nil
        let notes = [plan.note, bridgeNote].compactMap { $0 }
        let note = notes.map { " " + $0.text }.joined()
        guard !changes.isEmpty else {
            // A bridge in use is kept current; a failed refresh leaves the working one.
            if plan.bridged { try? writeBridgeScript() }
            return TelemetrySetupResult(changedFiles: [], restartRequired: [],
                                        message: loc("로컬 실측 연결 설정이 이미 적용돼 있습니다.", "Local telemetry is already connected.") + note,
                                        notes: notes, bridged: plan.bridged)
        }
        if connected {
            // A connection made before the status line bridge existed gets only the bridge, under the same backups.
            guard let manifest, let claude, plan.wraps, codexAfter == codex, plan.envOnly == claude else {
                throw TelemetrySetupError.conflict(loc("연결 이후 실측 설정이 변경됐습니다. 기존 백업을 보존하기 위해 다시 덮어쓰지 않았습니다.",
                                                       "The telemetry settings changed after they were connected. TokenCat didn't overwrite them, to keep the existing backup."))
            }
            return try addStatusLineBridge(to: manifest, claude: claude, plan: plan)
        }

        let backupName = "\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString)"
        let backupDirectory = support.appendingPathComponent("telemetry-backups/\(backupName)", isDirectory: true)
        try createPrivateDirectory(backupDirectory)
        var manifestRecord = Manifest(backupDirectory: backupName, entries: changes.map {
            Manifest.Entry(source: $0.source, existed: $0.original != nil, permissions: $0.permissions,
                           originalSHA256: $0.original.map(hash), connectedSHA256: hash($0.replacement))
        })
        if plan.wraps { manifestRecord.statusLine = Manifest.StatusLine(original: plan.originalStatusLine) }
        for change in changes {
            if let original = change.original {
                try atomicWrite(original, to: backupURL(change.source, directory: backupDirectory), permissions: 0o600)
            }
        }
        let manifestData = try JSONEncoder().encode(manifestRecord)
        try atomicWrite(manifestData, to: backupDirectory.appendingPathComponent("manifest.json"), permissions: 0o600)
        // The bridge exists before settings name it.
        if plan.wraps { try writeBridge(originalCommand: plan.originalCommand) } else if plan.bridged { try? writeBridgeScript() }

        var written: [Change] = []
        do {
            for change in changes {
                guard try read(change.url) == change.original else {
                    throw TelemetrySetupError.conflict(loc("설정이 다른 프로그램에서 변경돼 연결을 중단했습니다.",
                                                           "Another program changed the settings, so TokenCat stopped connecting."))
                }
                try atomicWrite(change.replacement, to: change.url, permissions: change.permissions)
                written.append(change)
            }
            try atomicWrite(manifestData, to: activeManifest, permissions: 0o600)
        } catch {
            let restored = rollback(written)
            if restored && plan.wraps { removeBridgeIfUnused() }
            // A config changed by another program mid-write is a conflict once the rollback succeeded.
            if restored, let setupError = error as? TelemetrySetupError, case .conflict = setupError { throw setupError }
            throw TelemetrySetupError.writeFailed(restored: restored)
        }
        return TelemetrySetupResult(changedFiles: changes.map { $0.url.path }, restartRequired: changes.map(\.source),
            message: loc("로컬 실측을 연결했습니다. 실행 중인 클라이언트는 재시작 후 적용됩니다.",
                         "Connected local telemetry. Restart running clients to apply it.") + note, notes: notes, bridged: plan.bridged)
    }

    /// Migration for a connection without the bridge (env already connected, status line untouched). The current file is
    /// backed up first (`preBridgeBackupName`) and the replaced status line is recorded in the manifest. The whole-file
    /// restore keeps covering it: an entry unchanged since the connection moves its connected hash to the bridged file
    /// (its backup predates the bridge); a missing entry is added with the current file as its backup; an entry edited
    /// after the connection refuses a whole-file restore, and disconnecting then puts the pre-bridge bytes back.
    private func addStatusLineBridge(to manifest: Manifest, claude: Data, plan: ClaudePlan) throws -> TelemetrySetupResult {
        let url = configURL(.claude)
        let mode = try permissions(url)
        let directory = support.appendingPathComponent("telemetry-backups/\(manifest.backupDirectory)", isDirectory: true)
        try atomicWrite(claude, to: directory.appendingPathComponent(Self.preBridgeBackupName), permissions: 0o600)
        var updated = manifest
        updated.statusLine = Manifest.StatusLine(original: plan.originalStatusLine, preBridgeSHA256: hash(claude), bridgedSHA256: hash(plan.data))
        if let index = updated.entries.firstIndex(where: { $0.source == .claude }) {
            if updated.entries[index].connectedSHA256 == hash(claude) { updated.entries[index].connectedSHA256 = hash(plan.data) }
        } else {
            try atomicWrite(claude, to: backupURL(.claude, directory: directory), permissions: 0o600)
            updated.entries.append(Manifest.Entry(source: .claude, existed: true, permissions: mode,
                                                  originalSHA256: hash(claude), connectedSHA256: hash(plan.data)))
        }
        let manifestData = try JSONEncoder().encode(updated)
        try writeBridge(originalCommand: plan.originalCommand)
        let record = directory.appendingPathComponent("manifest.json")
        let previousRecord = try read(record)
        do {
            guard try read(url) == claude else {
                throw TelemetrySetupError.conflict(loc("설정이 다른 프로그램에서 변경돼 연결을 중단했습니다.",
                                                       "Another program changed the settings, so TokenCat stopped connecting."))
            }
            try atomicWrite(plan.data, to: url, permissions: mode)
            try atomicWrite(manifestData, to: record, permissions: 0o600)
            try atomicWrite(manifestData, to: activeManifest, permissions: 0o600)
        } catch {
            let restored = rollback([Change(source: .claude, url: url, original: claude, replacement: plan.data, permissions: mode)])
            if let previousRecord { try? atomicWrite(previousRecord, to: record, permissions: 0o600) }
            if restored { removeBridgeIfUnused() }
            if restored, let setupError = error as? TelemetrySetupError, case .conflict = setupError { throw setupError }
            throw TelemetrySetupError.writeFailed(restored: restored)
        }
        // The OTLP connection is unchanged, so no restart notice: until a running Claude Code reloads its settings,
        // its limits are simply not shown yet.
        return TelemetrySetupResult(changedFiles: [url.path], restartRequired: [],
            message: loc("Claude Code 상태 표시줄에 사용량 한도 연결을 추가했습니다. 기존 상태 표시줄 출력은 그대로입니다.",
                         "Added the usage limit connection to the Claude Code status line. Its output stays the same."), bridged: true)
    }

    func disconnect() throws -> TelemetrySetupResult {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        guard let data = try read(activeManifest) else {
            return TelemetrySetupResult(changedFiles: [], restartRequired: [],
                                        message: loc("복구할 TokenCat 실측 연결이 없습니다.", "There's no TokenCat telemetry connection to remove."))
        }
        guard let manifest = validated(data) else {
            throw TelemetrySetupError.invalid(loc("실측 백업 정보가 올바르지 않아 설정을 변경하지 않았습니다.",
                                                  "The telemetry backup record isn't valid, so the settings weren't changed."))
        }
        let directory = support.appendingPathComponent("telemetry-backups/\(manifest.backupDirectory)", isDirectory: true)
        // A file unchanged since the connection gets its exact original bytes back. One edited since (Codex and Claude Code
        // rewrite their own settings) loses only what TokenCat added; a TokenCat key that now holds another value refuses
        // the whole restore, and then only the status line still goes back, since it runs a script from this folder.
        var restored: [(entry: Manifest.Entry, current: Data, replacement: Data?)] = []
        var refused: [TokenSource] = []
        var statusLine: String?
        for entry in manifest.entries {
            let url = configURL(entry.source)
            let backup = entry.existed ? try read(backupURL(entry.source, directory: directory)) : nil
            guard !entry.existed || backup.map(hash) == entry.originalSHA256 else {
                throw TelemetrySetupError.invalid(loc("원본 실측 백업이 없거나 변경돼 설정을 복구하지 않았습니다.",
                                                      "The original telemetry backup is missing or changed, so the settings weren't restored."))
            }
            if let current = try read(url), hash(current) == entry.connectedSHA256 {
                restored.append((entry, current, backup))
                continue
            }
            if entry.source == .claude { statusLine = restoreStatusLine(manifest, directory: directory) }
            guard let current = try read(url) else { continue }
            guard let reverted = entry.source == .claude ? revertClaude(current, backup: backup, bridged: manifest.statusLine != nil)
                                                         : revertCodex(current, backup: backup) else {
                refused.append(entry.source)
                continue
            }
            if reverted != current { restored.append((entry, current, reverted)) }
        }
        guard refused.isEmpty else {
            let names = refused.map(\.title).joined(separator: ", ")
            throw TelemetrySetupError.conflict(loc("연결 후 \(names) 설정이 수정돼 TokenCat 항목만 따로 되돌릴 수 없습니다. 사용자 변경을 보존하기 위해 자동 복구하지 않았습니다.",
                                                   "\(names) settings changed after the connection, and TokenCat's entries can't be reverted on their own. Nothing was restored automatically, to keep your changes.")
                                               + (statusLine ?? restoreStatusLine(manifest, directory: directory)))
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        var completed: [(entry: Manifest.Entry, current: Data, replacement: Data?)] = []
        do {
            for item in restored {
                let url = configURL(item.entry.source)
                guard try read(url) == item.current else {
                    throw TelemetrySetupError.conflict(loc("복구 중 설정이 변경됐습니다.", "The settings changed during the restore."))
                }
                if hash(item.current) != item.entry.connectedSHA256 {
                    let name = "before-disconnect-\(stamp)-" + backupURL(item.entry.source, directory: directory).lastPathComponent
                    try atomicWrite(item.current, to: directory.appendingPathComponent(name), permissions: 0o600)
                }
                if let replacement = item.replacement { try atomicWrite(replacement, to: url, permissions: item.entry.permissions) }
                else { try files.removeItem(at: url) }
                completed.append(item)
            }
            try files.removeItem(at: activeManifest)
        } catch {
            var rolledBack = true
            for item in completed.reversed() {
                do {
                    let url = configURL(item.entry.source)
                    guard try read(url) == item.replacement else { rolledBack = false; continue }
                    try atomicWrite(item.current, to: url, permissions: item.entry.permissions)
                } catch { rolledBack = false }
            }
            throw TelemetrySetupError.writeFailed(restored: rolledBack)
        }
        // The restored settings hold the original status line, so the bridge goes too unless something still names it.
        if manifest.statusLine != nil { removeBridgeIfUnused() }
        // Any entry not put back whole (reverted by key, or with nothing of TokenCat's left) was edited.
        let edited = restored.filter { hash($0.current) == $0.entry.connectedSHA256 }.count != manifest.entries.count
        return TelemetrySetupResult(changedFiles: restored.map { configURL($0.entry.source).path },
            restartRequired: restored.map { $0.entry.source },
            message: (edited ? loc("TokenCat이 추가한 실측 설정만 되돌리고 연결 후 바뀐 다른 설정은 그대로 두었습니다. 클라이언트 재시작 후 적용됩니다.",
                                   "Removed only the telemetry settings TokenCat added and kept every other change made since. Restart the clients to apply.")
                      : loc("TokenCat 실측 연결 전의 설정으로 복구했습니다. 클라이언트 재시작 후 적용됩니다.",
                            "Restored the settings from before the TokenCat telemetry connection. Restart the clients to apply.")) + (statusLine ?? ""))
    }

    /// Edited Claude Code settings without TokenCat's env: a key still holding TokenCat's value gets the backup's value back
    /// (or goes when the backup had none), and a content-logging switch TokenCat set to "0" gets its backed-up value back.
    /// Every other key stays. Nil when one of TokenCat's keys now holds a value that is neither TokenCat's nor the backup's,
    /// or when the status line TokenCat wrapped (`bridged`) still runs the bridge in any spelling: its record must outlive
    /// this attempt.
    private func revertClaude(_ current: Data, backup: Data?, bridged: Bool) -> Data? {
        guard var settings = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any],
              !bridged || !(((settings["statusLine"] as? [String: Any])?["command"] as? String).map(Self.runsBridge) ?? false) else { return nil }
        guard settings["env"] != nil else { return current }
        guard var env = settings["env"] as? [String: Any] else { return nil }
        let before = backup.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["env"] as? [String: Any]
        for (key, value) in Self.claudeEnv where env[key] != nil {
            if env[key] as? String == value { env[key] = before?[key] }
            else if (env[key] as? NSObject) != (before?[key] as? NSObject) { return nil }
        }
        for key in Self.claudeLogKeys where env[key] as? String == "0" {
            if let original = before?[key] { env[key] = original }
        }
        settings["env"] = env.isEmpty && before == nil ? nil : env
        return try? settingsData(settings, original: current)
    }

    /// Edited Codex config without the `[otel]` table connect() appended: removed with its blank line when it is still
    /// exactly as written and holds nothing else. The file as it is once TokenCat's lines are gone. Nil when the original
    /// had its own `[otel]` table (TokenCat's keys are mixed into it) or TokenCat's lines changed.
    private func revertCodex(_ current: Data, backup: Data?) -> Data? {
        if current == backup { return current }
        guard let text = String(data: current, encoding: .utf8) else { return nil }
        let endpoint = "127.0.0.1:\(Self.port)"
        let original = backup.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard !original.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[otel]") })
        else { return nil }
        let suffix = text.contains("\r\n") ? "\r" : ""
        let block = (["[otel]"] + Self.codexExporters.map { "\($0.key) = \($0.value)" }).map { $0 + suffix }
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.indices.first(where: { lines[$0...].starts(with: block) }) else {
            return text.contains(endpoint) ? nil : current
        }
        let end = start + block.count
        let next = lines[end...].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard next.map({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? true else { return nil }
        lines.removeSubrange((start > 0 && lines[start - 1] == suffix ? start - 1 : start)..<end)
        let reverted = lines.joined(separator: "\n")
        return reverted.contains(endpoint) ? nil : Data(reverted.utf8)
    }

    private func validated(_ data: Data) -> Manifest? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1,
              !manifest.entries.isEmpty, Set(manifest.entries.map(\.source)).count == manifest.entries.count,
              manifest.entries.allSatisfy({ (0...0o7777).contains($0.permissions) }),
              manifest.backupDirectory.range(of: #"^[0-9]+-[A-Fa-f0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        return manifest
    }

    /// A whole-file restore was refused. While Claude Code settings still run the bridge exactly as TokenCat wrote it, the
    /// status line alone goes back: the exact pre-bridge bytes when the file is still the migration's result, otherwise the
    /// recorded original object (or no `statusLine` when there was none) with every other key as it is now. The current
    /// bytes are backed up first, and an unchanged Claude entry moves its connected hash so a later whole-file restore
    /// still applies. Returns the sentence for the refusal message ("" without a bridge record).
    private func restoreStatusLine(_ manifest: Manifest, directory: URL) -> String {
        guard let record = manifest.statusLine else { return "" }
        let url = configURL(.claude)
        let kept = loc(" 상태 표시줄도 지금 설정 그대로 두었습니다.", " The status line was also left as it is.")
        let failed = loc(" Claude Code 상태 표시줄은 되돌리지 못했습니다.", " Couldn't restore the Claude Code status line.")
            + (files.fileExists(atPath: bridgeOriginal.path) ? loc(" 원래 명령은 ~/Library/Application Support/TokenCat/\(Self.statusLineOriginalName)에 있습니다.",
                                                                   " The original command is in ~/Library/Application Support/TokenCat/\(Self.statusLineOriginalName).") : "")
        guard let current = try? read(url),
              let settings = try? JSONSerialization.jsonObject(with: current) as? [String: Any] else { return kept }
        guard (settings["statusLine"] as? [String: Any])?["command"] as? String == Self.statusLineCommand else {
            removeBridgeIfUnused()
            return kept
        }
        var replacement: Data?
        if let bridged = record.bridgedSHA256, hash(current) == bridged, let pre = record.preBridgeSHA256,
           let bytes = try? read(directory.appendingPathComponent(Self.preBridgeBackupName)), hash(bytes) == pre {
            replacement = bytes
        } else if let text = record.original {
            guard let original = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let command = original["command"] as? String, !Self.runsBridge(command) else { return failed }
            var target = settings
            target["statusLine"] = original
            replacement = Self.replacingLiteral(Self.statusLineCommand, with: command, in: current, expecting: target)
                ?? (try? settingsData(target, original: current))
        } else {
            var target = settings
            target["statusLine"] = nil
            replacement = Self.removingMember("statusLine", in: current, expecting: target) ?? (try? settingsData(target, original: current))
        }
        guard let replacement else { return failed }
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        do {
            try atomicWrite(current, to: directory.appendingPathComponent("claude-settings-before-statusline-restore-\(stamp).json"), permissions: 0o600)
            guard try read(url) == current else { return failed }
            try atomicWrite(replacement, to: url, permissions: try permissions(url))
        } catch { return failed }
        var updated = manifest
        if let index = updated.entries.firstIndex(where: { $0.source == .claude && $0.connectedSHA256 == hash(current) }) {
            updated.entries[index].connectedSHA256 = hash(replacement)
            if let data = try? JSONEncoder().encode(updated) {
                try? atomicWrite(data, to: directory.appendingPathComponent("manifest.json"), permissions: 0o600)
                try? atomicWrite(data, to: activeManifest, permissions: 0o600)
            }
        }
        removeBridgeIfUnused()
        let restoredLine = (try? JSONSerialization.jsonObject(with: replacement) as? [String: Any])?["statusLine"] != nil
        return restoredLine ? loc(" Claude Code 상태 표시줄은 원래 명령으로 되돌렸습니다.", " Restored the Claude Code status line to its original command.")
            : loc(" TokenCat이 추가한 Claude Code 상태 표시줄은 지웠습니다.", " Removed the Claude Code status line TokenCat added.")
    }

    /// Settings already run the bridge but this connection did not wrap them now. A missing sidecar is recreated from the
    /// record; without a record (a settings.json copied from another Mac, or the folder deleted) the original command is
    /// unknown, which the note says instead of "already applied". Nil when nothing needs saying.
    private func bridgeOriginalNote(_ manifest: Manifest?) -> TelemetrySetupNote? {
        guard !files.fileExists(atPath: bridgeOriginal.path) else { return nil }
        let unknown = TelemetrySetupNote.originalUnknown
        guard let record = manifest?.statusLine else { return unknown }
        // There was no status line: the bridge only forwards and prints nothing, as intended.
        guard let text = record.original else { return nil }
        guard let original = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let command = original["command"] as? String, !Self.runsBridge(command) else { return unknown }
        do { try atomicWrite(Data(command.utf8), to: bridgeOriginal, permissions: 0o600) } catch { return unknown }
        return .originalRecreated
    }

    /// `data` with one occurrence of the JSON string literal for `old` swapped for `new`, when that swap alone turns it into
    /// `expected`: Claude Code's own formatting and number spelling stay. Nil when no single swap does.
    static func replacingLiteral(_ old: String, with new: String, in data: Data, expecting expected: [String: Any]) -> Data? {
        guard let text = String(data: data, encoding: .utf8), let replacement = jsonLiterals(new).first else { return nil }
        for literal in jsonLiterals(old) {
            var start = text.startIndex
            while let range = text.range(of: literal, range: start..<text.endIndex) {
                let candidate = Data(text.replacingCharacters(in: range, with: replacement).utf8)
                if parses(candidate, to: expected) { return candidate }
                start = range.upperBound
            }
        }
        return nil
    }

    /// `data` without the member `key` (a flat object value) and one adjacent comma, when that alone turns it into `expected`.
    static func removingMember(_ key: String, in data: Data, expecting expected: [String: Any]) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let member = NSRegularExpression.escapedPattern(for: "\"\(key)\"") + #"\s*:\s*\{[^{}]*\}"#
        for pattern in [member + #"\s*,\s*"#, #"\s*,\s*"# + member, member] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let candidate = Data(text.replacingCharacters(in: range, with: "").utf8)
                if parses(candidate, to: expected) { return candidate }
            }
        }
        return nil
    }

    /// The ways a JSON writer spells `string`: slashes plain (JavaScript, TokenCat) and escaped.
    private static func jsonLiterals(_ string: String) -> [String] {
        guard let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let plain = String(data: data, encoding: .utf8) else { return [] }
        let escaped = plain.replacingOccurrences(of: "/", with: "\\/")
        return escaped == plain ? [plain] : [plain, escaped]
    }

    private static func parses(_ data: Data, to expected: [String: Any]) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? NSDictionary)?.isEqual(to: expected) == true
    }

    /// The sidecar goes first, so the script never pairs with a stale original command.
    private func writeBridge(originalCommand: String?) throws {
        if let originalCommand { try atomicWrite(Data(originalCommand.utf8), to: bridgeOriginal, permissions: 0o600) }
        else if files.fileExists(atPath: bridgeOriginal.path) { try files.removeItem(at: bridgeOriginal) }
        try writeBridgeScript()
    }

    private func writeBridgeScript() throws {
        let script = Data(Self.statusLineScript.utf8)
        guard (try? Data(contentsOf: bridgeScript)) != script else { return }
        try atomicWrite(script, to: bridgeScript, permissions: 0o700)
    }

    /// Leaves the bridge in place while Claude Code settings still run it (an edited file that was not restored).
    private func removeBridgeIfUnused() {
        let current: Data?
        do { current = try read(configURL(.claude)) } catch { return }
        let settings = current.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard !(((settings?["statusLine"] as? [String: Any])?["command"] as? String).map(Self.runsBridge) ?? false) else { return }
        try? files.removeItem(at: bridgeOriginal)
        try? files.removeItem(at: bridgeScript)
    }

    private func configURL(_ source: TokenSource) -> URL {
        home.appendingPathComponent(source == .codex ? ".codex/config.toml" : ".claude/settings.json")
    }

    private func backupURL(_ source: TokenSource, directory: URL) -> URL {
        directory.appendingPathComponent(source == .codex ? "codex-config.toml" : "claude-settings.json")
    }

    private func read(_ url: URL) throws -> Data? {
        guard files.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TelemetrySetupError.invalid(loc("설정 경로가 일반 파일이 아니어서 변경하지 않았습니다: \(url.lastPathComponent)",
                                                  "A settings path isn't a regular file, so it wasn't changed: \(url.lastPathComponent)"))
        }
        return try Data(contentsOf: url)
    }

    private func permissions(_ url: URL) throws -> Int {
        guard files.fileExists(atPath: url.path) else { return 0o600 }
        return (try files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func createPrivateDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tokencat-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: temporary) }
        // Source configurations may contain credentials: private mode is set before writing bytes.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func rollback(_ written: [Change]) -> Bool {
        var restored = true
        for change in written.reversed() {
            do {
                guard try read(change.url) == change.replacement else { restored = false; continue }
                if let original = change.original { try atomicWrite(original, to: change.url, permissions: change.permissions) }
                else { try files.removeItem(at: change.url) }
            } catch { restored = false }
        }
        return restored
    }

    private struct ClaudePlan {
        var data: Data
        /// The same settings without the status line change, to recognise a connection made before the bridge.
        var envOnly: Data
        /// This plan wraps the status line: `originalStatusLine` is the replaced object as JSON text, nil when none.
        var wraps = false
        var originalStatusLine: String?
        var originalCommand: String?
        /// The planned settings run the bridge.
        var bridged = false
        var note: TelemetrySetupNote?
    }

    /// `bridgedBefore`: the active connection already wrapped the status line once, so a status line that no longer
    /// runs the bridge is the person's choice and stays as it is.
    private func claudeConfiguration(_ original: Data?, bridgedBefore: Bool) throws -> ClaudePlan {
        var object: [String: Any] = [:]
        if let original {
            guard let decoded = try? JSONSerialization.jsonObject(with: original), let dictionary = decoded as? [String: Any] else {
                throw TelemetrySetupError.invalid(loc("Claude Code settings.json 형식이 올바르지 않아 변경하지 않았습니다.",
                                                      "Claude Code settings.json isn't in a valid format, so it wasn't changed."))
            }
            object = dictionary
        }
        guard object["env"] == nil || object["env"] is [String: Any] else {
            throw TelemetrySetupError.invalid(loc("Claude Code env 설정이 객체가 아니어서 변경하지 않았습니다.",
                                                  "The Claude Code env setting isn't an object, so it wasn't changed."))
        }
        var env = object["env"] as? [String: Any] ?? [:]
        let endpoint = "http://127.0.0.1:\(Self.port)"
        let requested = Self.claudeEnv
        // A pre-existing global exporter endpoint/headers can redirect or authenticate every signal.
        for key in ["OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] {
            guard let value = env[key] else { continue }
            let expected = key == "OTEL_EXPORTER_OTLP_ENDPOINT" ? endpoint : requested[key]!
            guard value as? String == expected else {
                throw TelemetrySetupError.conflict(loc("Claude Code에 기존 OTLP 전송 대상이 있어 덮어쓰지 않았습니다.",
                                                       "Claude Code already has an OTLP destination, so it wasn't overwritten."))
            }
        }
        for key in ["OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_LOGS_HEADERS", "OTEL_EXPORTER_OTLP_TRACES_HEADERS"] {
            if let value = env[key], value as? String != "" {
                throw TelemetrySetupError.conflict(loc("Claude Code에 기존 OTLP 인증 헤더가 있어 덮어쓰지 않았습니다.",
                                                       "Claude Code already has OTLP auth headers, so they weren't overwritten."))
            }
        }
        for key in ["OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER"] {
            if let value = env[key], !["none", "otlp", ""].contains(value as? String ?? "invalid") {
                throw TelemetrySetupError.conflict(loc("Claude Code에 기존 실측 exporter가 있어 덮어쓰지 않았습니다.",
                                                       "Claude Code already has a telemetry exporter, so it wasn't overwritten."))
            }
            let signal = key == "OTEL_LOGS_EXPORTER" ? "LOGS" : "TRACES"
            if env[key] as? String == "otlp", env["OTEL_EXPORTER_OTLP_\(signal)_ENDPOINT"] == nil,
               env["OTEL_EXPORTER_OTLP_ENDPOINT"] as? String != endpoint {
                throw TelemetrySetupError.conflict(loc("Claude Code가 기존 OTLP 기본 대상에 연결돼 있어 덮어쓰지 않았습니다.",
                                                       "Claude Code already sends to a default OTLP destination, so it wasn't overwritten."))
            }
        }
        for (key, value) in requested { env[key] = value }
        for key in Self.claudeLogKeys {
            guard let existing = env[key] else { continue }
            let value = (existing as? String ?? String(describing: existing)).lowercased().trimmingCharacters(in: .whitespaces)
            if !["", "0", "false", "no", "off"].contains(value) { env[key] = "0" }
        }
        object["env"] = env
        let envOnly = try settingsData(object, original: original)
        var plan = ClaudePlan(data: envOnly, envOnly: envOnly)
        if object["statusLine"] == nil {
            // Without an original the bridge prints nothing after forwarding. A bridge the person removed stays removed.
            guard !bridgedBefore else { return plan }
            object["statusLine"] = ["type": "command", "command": Self.statusLineCommand]
        } else if let line = object["statusLine"] as? [String: Any], line["type"] as? String == "command",
                  let command = line["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if Self.runsBridge(command) { plan.bridged = true; return plan }
            guard !bridgedBefore else { return plan }
            // Every other field (padding and any future key) is kept; only the command runs through the bridge.
            var wrapped = line
            wrapped["command"] = Self.statusLineCommand
            object["statusLine"] = wrapped
            plan.originalCommand = command
            plan.originalStatusLine = String(decoding: try JSONSerialization.data(withJSONObject: line,
                options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        } else {
            plan.note = .statusLineSkipped
            return plan
        }
        plan.wraps = true
        plan.bridged = true
        // Swapping only the command keeps the file's own formatting; a new status line rewrites it.
        plan.data = try plan.originalCommand.flatMap { Self.replacingLiteral($0, with: Self.statusLineCommand, in: envOnly, expecting: object) }
            ?? settingsData(object, original: original)
        return plan
    }

    /// The original bytes when nothing changed, so an applied connection is never rewritten.
    private func settingsData(_ object: [String: Any], original: Data?) throws -> Data {
        if let original, let prior = try? JSONSerialization.jsonObject(with: original) as? NSDictionary,
           prior.isEqual(to: object) { return original }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
    }

    private func codexConfiguration(_ original: Data?) throws -> Data {
        guard let text = original.flatMap({ String(data: $0, encoding: .utf8) }) ?? (original == nil ? "" : nil) else {
            throw TelemetrySetupError.invalid(loc("Codex config.toml이 UTF-8 형식이 아니어서 변경하지 않았습니다.",
                                                  "Codex config.toml isn't UTF-8, so it wasn't changed."))
        }
        let suffix = text.contains("\r\n") ? "\r" : ""
        var lines = text.components(separatedBy: "\n")
        var section: String? = nil
        var sectionStart: Int? = nil
        var sectionEnd = lines.count
        var multiline: String? = nil
        var replacements: [Int: String] = [:]
        var found = Set<String>()
        let requested = Dictionary(uniqueKeysWithValues: Self.codexExporters.map { ($0.key, $0.value) })
        for index in lines.indices {
            let line = lines[index].hasSuffix("\r") ? String(lines[index].dropLast()) : lines[index]
            let wasMultiline = multiline != nil
            let visible = scanTOML(line, multiline: &multiline)
            if wasMultiline { continue }
            let trimmed = visible.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else {
                    throw TelemetrySetupError.invalid(loc("Codex TOML 테이블 형식이 올바르지 않습니다.", "A Codex TOML table header isn't valid."))
                }
                let raw = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                let normalized = compactTOML(raw).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                if section == "otel" { sectionEnd = index }
                section = normalized
                if normalized == "otel" {
                    guard raw == "otel", sectionStart == nil else {
                        throw TelemetrySetupError.conflict(loc("Codex otel 테이블이 중복되거나 복잡한 형식이어서 덮어쓰지 않았습니다.",
                                                               "The Codex otel table is repeated or too complex, so it wasn't overwritten."))
                    }
                    sectionStart = index
                } else if normalized.hasPrefix("otel.") || normalized.hasPrefix("[otel") {
                    throw TelemetrySetupError.conflict(loc("Codex에 기존 중첩 OTLP 설정이 있어 덮어쓰지 않았습니다.",
                                                           "Codex already has nested OTLP settings, so they weren't overwritten."))
                }
                continue
            }
            if let equals = visible.firstIndex(of: "=") {
                let rootKey = compactTOML(String(visible[..<equals])).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                if rootKey.hasPrefix("otel.") || (section == nil && rootKey == "otel") {
                    throw TelemetrySetupError.conflict(loc("Codex에 기존 dotted 또는 inline otel 설정이 있어 덮어쓰지 않았습니다.",
                                                           "Codex already has dotted or inline otel settings, so they weren't overwritten."))
                }
            }
            guard section == "otel", let equals = visible.firstIndex(of: "=") else { continue }
            let key = String(visible[..<equals]).trimmingCharacters(in: .whitespaces)
            let bareKey = compactTOML(key).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            if bareKey.contains(".") && ["exporter.", "metrics_exporter.", "trace_exporter."].contains(where: bareKey.hasPrefix) {
                throw TelemetrySetupError.conflict(loc("Codex에 기존 dotted OTLP 설정이 있어 덮어쓰지 않았습니다.",
                                                       "Codex already has dotted OTLP settings, so they weren't overwritten."))
            }
            guard requested[bareKey] != nil || ["log_user_prompt", "log_agent_responses"].contains(bareKey) else { continue }
            guard key == bareKey, !found.contains(bareKey), multiline == nil else {
                throw TelemetrySetupError.conflict(loc("Codex otel 키가 중복되거나 여러 줄 형식이어서 변경하지 않았습니다.",
                                                       "A Codex otel key is repeated or spans several lines, so it wasn't changed."))
            }
            found.insert(bareKey)
            let value = String(visible[visible.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let after: String
            if let desired = requested[bareKey] {
                let allowed = bareKey == "metrics_exporter" ? ["\"none\"", "'none'", "\"statsig\"", "'statsig'"] : ["\"none\"", "'none'"]
                guard allowed.contains(value) || compactTOML(value) == compactTOML(desired) else {
                    throw TelemetrySetupError.conflict(loc("Codex에 기존 \(bareKey) 전송 설정이 있어 덮어쓰지 않았습니다.",
                                                           "Codex already has a \(bareKey) setting, so it wasn't overwritten."))
                }
                after = desired
            } else {
                guard ["true", "false"].contains(value) else {
                    throw TelemetrySetupError.invalid(loc("Codex 실측 개인정보 옵션이 올바르지 않습니다.", "A Codex telemetry privacy option isn't valid."))
                }
                after = "false"
            }
            let prefix = String(line[...equals])
            let comment = line.dropFirst(visible.count).trimmingCharacters(in: .whitespaces)
            replacements[index] = prefix + " " + after + (comment.isEmpty ? "" : " " + comment) + suffix
        }
        guard multiline == nil else { throw TelemetrySetupError.invalid(loc("Codex TOML 문자열이 닫히지 않아 변경하지 않았습니다.",
                                                                            "A Codex TOML string isn't closed, so it wasn't changed.")) }
        for (index, replacement) in replacements { lines[index] = replacement }
        let missing = Self.codexExporters.filter { !found.contains($0.key) }.map { "\($0.key) = \($0.value)\(suffix)" }
        if sectionStart != nil {
            let insertion = sectionEnd == lines.count && lines.last == "" ? sectionEnd - 1 : sectionEnd
            lines.insert(contentsOf: missing, at: insertion)
        } else {
            if lines.last == "" { lines.removeLast() }
            if !text.isEmpty { lines.append(suffix) }
            lines.append("[otel]\(suffix)")
            lines.append(contentsOf: missing)
            lines.append("")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Returns text before an unquoted comment and tracks multiline strings in unrelated sections.
    private func scanTOML(_ line: String, multiline: inout String?) -> String {
        let characters = Array(line)
        var index = 0
        var quote: Character? = nil
        while index < characters.count {
            if let delimiter = multiline {
                if index + 2 < characters.count, String(characters[index...index + 2]) == delimiter {
                    multiline = nil; index += 3
                } else { index += 1 }
                continue
            }
            let character = characters[index]
            if let current = quote {
                if current == "\"", character == "\\" { index += 2; continue }
                if character == current { quote = nil }
                index += 1; continue
            }
            if character == "#" { return String(characters[..<index]) }
            if character == "\"" || character == "'" {
                if index + 2 < characters.count, characters[index + 1] == character, characters[index + 2] == character {
                    multiline = String(repeating: String(character), count: 3); index += 3
                } else { quote = character; index += 1 }
            } else { index += 1 }
        }
        return line
    }

    private func compactTOML(_ value: String) -> String {
        var result = ""
        var quote: Character? = nil
        var escaped = false
        for character in value {
            if let current = quote {
                result.append(character)
                if escaped { escaped = false }
                else if current == "\"", character == "\\" { escaped = true }
                else if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character; result.append(character) }
            else if !character.isWhitespace { result.append(character) }
        }
        return result
    }
}
