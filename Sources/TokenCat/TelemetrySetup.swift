import Foundation
import CryptoKit
import Darwin

struct TelemetrySetupResult {
    var changedFiles: [String]
    var restartRequired: [TokenSource]
    var message: String
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
            return restored ? "설정 저장에 실패하여 원래 설정으로 복구했습니다."
                : "설정 저장 중 일부 파일이 변경됐습니다. 사용자 변경을 보존했으며 백업에서 개별 확인이 필요합니다."
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
    static let port = 16493
    private static let mutationLock = NSLock()
    private let home: URL
    private let files = FileManager.default
    private var support: URL { home.appendingPathComponent("Library/Application Support/TokenCat", isDirectory: true) }
    private var activeManifest: URL { support.appendingPathComponent("telemetry-connection.json") }

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
        struct Entry: Codable {
            var source: TokenSource
            var existed: Bool
            var permissions: Int
            var originalSHA256: String?
            var connectedSHA256: String
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
        let codexAfter = try codexConfiguration(codex)
        let claudeAfter = try claudeConfiguration(claude)
        let candidates = [Change(source: .codex, url: codexURL, original: codex,
                                 replacement: codexAfter, permissions: try permissions(codexURL)),
                          Change(source: .claude, url: claudeURL, original: claude,
                                 replacement: claudeAfter, permissions: try permissions(claudeURL))]
        let changes = candidates.filter { $0.original != $0.replacement }
        guard !changes.isEmpty else {
            return TelemetrySetupResult(changedFiles: [], restartRequired: [], message: "로컬 실측 연결 설정이 이미 적용돼 있습니다.")
        }
        guard !files.fileExists(atPath: activeManifest.path) else {
            throw TelemetrySetupError.conflict("연결 이후 실측 설정이 변경됐습니다. 기존 백업을 보존하기 위해 다시 덮어쓰지 않았습니다.")
        }

        let backupName = "\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString)"
        let backupDirectory = support.appendingPathComponent("telemetry-backups/\(backupName)", isDirectory: true)
        try createPrivateDirectory(backupDirectory)
        let manifest = Manifest(backupDirectory: backupName, entries: changes.map {
            Manifest.Entry(source: $0.source, existed: $0.original != nil, permissions: $0.permissions,
                           originalSHA256: $0.original.map(hash), connectedSHA256: hash($0.replacement))
        })
        for change in changes {
            if let original = change.original {
                try atomicWrite(original, to: backupURL(change.source, directory: backupDirectory), permissions: 0o600)
            }
        }
        let manifestData = try JSONEncoder().encode(manifest)
        try atomicWrite(manifestData, to: backupDirectory.appendingPathComponent("manifest.json"), permissions: 0o600)

        var written: [Change] = []
        do {
            for change in changes {
                guard try read(change.url) == change.original else {
                    throw TelemetrySetupError.conflict("설정이 다른 프로그램에서 변경돼 연결을 중단했습니다.")
                }
                try atomicWrite(change.replacement, to: change.url, permissions: change.permissions)
                written.append(change)
            }
            try atomicWrite(manifestData, to: activeManifest, permissions: 0o600)
        } catch {
            let restored = rollback(written)
            // A config changed by another program mid-write is a conflict once the rollback succeeded.
            if restored, let setupError = error as? TelemetrySetupError, case .conflict = setupError { throw setupError }
            throw TelemetrySetupError.writeFailed(restored: restored)
        }
        return TelemetrySetupResult(changedFiles: changes.map { $0.url.path }, restartRequired: changes.map(\.source),
            message: "로컬 실측을 연결했습니다. 실행 중인 클라이언트는 재시작 후 적용됩니다.")
    }

    func disconnect() throws -> TelemetrySetupResult {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        guard let data = try read(activeManifest) else {
            return TelemetrySetupResult(changedFiles: [], restartRequired: [], message: "복구할 TokenCat 실측 연결이 없습니다.")
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1,
              !manifest.entries.isEmpty, Set(manifest.entries.map(\.source)).count == manifest.entries.count,
              manifest.entries.allSatisfy({ (0...0o7777).contains($0.permissions) }),
              manifest.backupDirectory.range(of: #"^[0-9]+-[A-Fa-f0-9-]+$"#, options: .regularExpression) != nil else {
            throw TelemetrySetupError.invalid("실측 백업 정보가 올바르지 않아 설정을 변경하지 않았습니다.")
        }
        let directory = support.appendingPathComponent("telemetry-backups/\(manifest.backupDirectory)", isDirectory: true)
        var restored: [(entry: Manifest.Entry, current: Data, original: Data?)] = []
        // Whole-file checks deliberately refuse to overwrite any intervening user edit.
        for entry in manifest.entries {
            guard let current = try read(configURL(entry.source)), hash(current) == entry.connectedSHA256 else {
                throw TelemetrySetupError.conflict("연결 후 \(entry.source.title) 설정이 수정됐습니다. 사용자 변경을 보존하기 위해 자동 복구하지 않았습니다.")
            }
            let original = entry.existed ? try read(backupURL(entry.source, directory: directory)) : nil
            guard !entry.existed || original.map(hash) == entry.originalSHA256 else {
                throw TelemetrySetupError.invalid("원본 실측 백업이 없거나 변경돼 설정을 복구하지 않았습니다.")
            }
            restored.append((entry, current, original))
        }
        var completed: [(entry: Manifest.Entry, current: Data, original: Data?)] = []
        do {
            for item in restored {
                let url = configURL(item.entry.source)
                guard try read(url) == item.current else { throw TelemetrySetupError.conflict("복구 중 설정이 변경됐습니다.") }
                if let original = item.original { try atomicWrite(original, to: url, permissions: item.entry.permissions) }
                else { try files.removeItem(at: url) }
                completed.append(item)
            }
            try files.removeItem(at: activeManifest)
        } catch {
            var rolledBack = true
            for item in completed.reversed() {
                do {
                    let url = configURL(item.entry.source)
                    guard try read(url) == item.original else { rolledBack = false; continue }
                    try atomicWrite(item.current, to: url, permissions: item.entry.permissions)
                } catch { rolledBack = false }
            }
            throw TelemetrySetupError.writeFailed(restored: rolledBack)
        }
        return TelemetrySetupResult(changedFiles: restored.map { configURL($0.entry.source).path },
            restartRequired: restored.map { $0.entry.source }, message: "TokenCat 실측 연결 전의 설정으로 복구했습니다. 클라이언트 재시작 후 적용됩니다.")
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
            throw TelemetrySetupError.invalid("설정 경로가 일반 파일이 아니어서 변경하지 않았습니다: \(url.lastPathComponent)")
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

    private func claudeConfiguration(_ original: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let original {
            guard let decoded = try? JSONSerialization.jsonObject(with: original), let dictionary = decoded as? [String: Any] else {
                throw TelemetrySetupError.invalid("Claude Code settings.json 형식이 올바르지 않아 변경하지 않았습니다.")
            }
            object = dictionary
        }
        guard object["env"] == nil || object["env"] is [String: Any] else {
            throw TelemetrySetupError.invalid("Claude Code env 설정이 객체가 아니어서 변경하지 않았습니다.")
        }
        var env = object["env"] as? [String: Any] ?? [:]
        let endpoint = "http://127.0.0.1:\(Self.port)"
        let requested: [String: String] = [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
            "OTEL_LOGS_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "\(endpoint)/v1/logs", "OTEL_LOGS_EXPORT_INTERVAL": "1000",
            "OTEL_TRACES_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "\(endpoint)/v1/traces", "OTEL_TRACES_EXPORT_INTERVAL": "1000"
        ]
        // A pre-existing global exporter endpoint/headers can redirect or authenticate every signal.
        for key in ["OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] {
            guard let value = env[key] else { continue }
            let expected = key == "OTEL_EXPORTER_OTLP_ENDPOINT" ? endpoint : requested[key]!
            guard value as? String == expected else {
                throw TelemetrySetupError.conflict("Claude Code에 기존 OTLP 전송 대상이 있어 덮어쓰지 않았습니다.")
            }
        }
        for key in ["OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_LOGS_HEADERS", "OTEL_EXPORTER_OTLP_TRACES_HEADERS"] {
            if let value = env[key], value as? String != "" {
                throw TelemetrySetupError.conflict("Claude Code에 기존 OTLP 인증 헤더가 있어 덮어쓰지 않았습니다.")
            }
        }
        for key in ["OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER"] {
            if let value = env[key], !["none", "otlp", ""].contains(value as? String ?? "invalid") {
                throw TelemetrySetupError.conflict("Claude Code에 기존 실측 exporter가 있어 덮어쓰지 않았습니다.")
            }
            let signal = key == "OTEL_LOGS_EXPORTER" ? "LOGS" : "TRACES"
            if env[key] as? String == "otlp", env["OTEL_EXPORTER_OTLP_\(signal)_ENDPOINT"] == nil,
               env["OTEL_EXPORTER_OTLP_ENDPOINT"] as? String != endpoint {
                throw TelemetrySetupError.conflict("Claude Code가 기존 OTLP 기본 대상에 연결돼 있어 덮어쓰지 않았습니다.")
            }
        }
        for (key, value) in requested { env[key] = value }
        for key in ["OTEL_LOG_USER_PROMPTS", "OTEL_LOG_ASSISTANT_RESPONSES", "OTEL_LOG_TOOL_DETAILS",
                    "OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_RAW_API_BODIES"] {
            guard let existing = env[key] else { continue }
            let value = (existing as? String ?? String(describing: existing)).lowercased().trimmingCharacters(in: .whitespaces)
            if !["", "0", "false", "no", "off"].contains(value) { env[key] = "0" }
        }
        object["env"] = env
        if let original, let prior = try? JSONSerialization.jsonObject(with: original) as? NSDictionary,
           prior.isEqual(to: object) { return original }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
    }

    private func codexConfiguration(_ original: Data?) throws -> Data {
        guard let text = original.flatMap({ String(data: $0, encoding: .utf8) }) ?? (original == nil ? "" : nil) else {
            throw TelemetrySetupError.invalid("Codex config.toml이 UTF-8 형식이 아니어서 변경하지 않았습니다.")
        }
        let suffix = text.contains("\r\n") ? "\r" : ""
        var lines = text.components(separatedBy: "\n")
        var section: String? = nil
        var sectionStart: Int? = nil
        var sectionEnd = lines.count
        var multiline: String? = nil
        var replacements: [Int: String] = [:]
        var found = Set<String>()
        let endpoint = "http://127.0.0.1:\(Self.port)/v1/"
        let requested = ["exporter": "{ otlp-http = { endpoint = \"\(endpoint)logs\", protocol = \"json\" } }",
                         "metrics_exporter": "{ otlp-http = { endpoint = \"\(endpoint)metrics\", protocol = \"json\" } }",
                         "trace_exporter": "{ otlp-http = { endpoint = \"\(endpoint)traces\", protocol = \"json\" } }"]
        for index in lines.indices {
            let line = lines[index].hasSuffix("\r") ? String(lines[index].dropLast()) : lines[index]
            let wasMultiline = multiline != nil
            let visible = scanTOML(line, multiline: &multiline)
            if wasMultiline { continue }
            let trimmed = visible.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else { throw TelemetrySetupError.invalid("Codex TOML 테이블 형식이 올바르지 않습니다.") }
                let raw = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                let normalized = compactTOML(raw).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                if section == "otel" { sectionEnd = index }
                section = normalized
                if normalized == "otel" {
                    guard raw == "otel", sectionStart == nil else {
                        throw TelemetrySetupError.conflict("Codex otel 테이블이 중복되거나 복잡한 형식이어서 덮어쓰지 않았습니다.")
                    }
                    sectionStart = index
                } else if normalized.hasPrefix("otel.") || normalized.hasPrefix("[otel") {
                    throw TelemetrySetupError.conflict("Codex에 기존 중첩 OTLP 설정이 있어 덮어쓰지 않았습니다.")
                }
                continue
            }
            if let equals = visible.firstIndex(of: "=") {
                let rootKey = compactTOML(String(visible[..<equals])).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                if rootKey.hasPrefix("otel.") || (section == nil && rootKey == "otel") {
                    throw TelemetrySetupError.conflict("Codex에 기존 dotted 또는 inline otel 설정이 있어 덮어쓰지 않았습니다.")
                }
            }
            guard section == "otel", let equals = visible.firstIndex(of: "=") else { continue }
            let key = String(visible[..<equals]).trimmingCharacters(in: .whitespaces)
            let bareKey = compactTOML(key).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            if bareKey.contains(".") && ["exporter.", "metrics_exporter.", "trace_exporter."].contains(where: bareKey.hasPrefix) {
                throw TelemetrySetupError.conflict("Codex에 기존 dotted OTLP 설정이 있어 덮어쓰지 않았습니다.")
            }
            guard requested[bareKey] != nil || ["log_user_prompt", "log_agent_responses"].contains(bareKey) else { continue }
            guard key == bareKey, !found.contains(bareKey), multiline == nil else {
                throw TelemetrySetupError.conflict("Codex otel 키가 중복되거나 여러 줄 형식이어서 변경하지 않았습니다.")
            }
            found.insert(bareKey)
            let value = String(visible[visible.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let after: String
            if let desired = requested[bareKey] {
                let allowed = bareKey == "metrics_exporter" ? ["\"none\"", "'none'", "\"statsig\"", "'statsig'"] : ["\"none\"", "'none'"]
                guard allowed.contains(value) || compactTOML(value) == compactTOML(desired) else {
                    throw TelemetrySetupError.conflict("Codex에 기존 \(bareKey) 전송 설정이 있어 덮어쓰지 않았습니다.")
                }
                after = desired
            } else {
                guard ["true", "false"].contains(value) else { throw TelemetrySetupError.invalid("Codex 실측 개인정보 옵션이 올바르지 않습니다.") }
                after = "false"
            }
            let prefix = String(line[...equals])
            let comment = line.dropFirst(visible.count).trimmingCharacters(in: .whitespaces)
            replacements[index] = prefix + " " + after + (comment.isEmpty ? "" : " " + comment) + suffix
        }
        guard multiline == nil else { throw TelemetrySetupError.invalid("Codex TOML 문자열이 닫히지 않아 변경하지 않았습니다.") }
        for (index, replacement) in replacements { lines[index] = replacement }
        let missing = ["exporter", "metrics_exporter", "trace_exporter"].filter { !found.contains($0) }.map { "\($0) = \(requested[$0]!)\(suffix)" }
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
