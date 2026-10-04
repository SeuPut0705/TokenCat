import Foundation

func runTelemetrySetupChecks() -> [String] {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("TokenCat-setup-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    var failures: [String] = []
    var checks = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append(description) }
    }
    func fixture(_ name: String, codex: String? = nil, claude: String? = nil) throws -> URL {
        let home = root.appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        for (relative, contents) in [(".codex/config.toml", codex), (".claude/settings.json", claude)] {
            if let contents {
                let url = home.appendingPathComponent(relative)
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
                try files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
            }
        }
        return home
    }
    func data(_ home: URL, _ relative: String) -> Data? { try? Data(contentsOf: home.appendingPathComponent(relative)) }
    func mode(_ home: URL, _ relative: String) -> Int? {
        (try? files.attributesOfItem(atPath: home.appendingPathComponent(relative).path)[.posixPermissions] as? NSNumber)?.intValue
    }
    func rejected(_ action: () throws -> Void) -> Bool {
        do { try action(); return false } catch { return true }
    }

    do {
        let originalCodex = """
        # Keep this comment and unrelated section.
        model = "existing-model"
        [otel] # keep table comment
        environment = "private # label"
        exporter = "none" # keep exporter comment
        metrics_exporter = "statsig"
        log_user_prompt = true
        log_agent_responses = true
        [features]
        custom_feature = true

        """
        let originalClaude = """
        {"env":{"ANTHROPIC_MODEL":"existing-model","CUSTOM_SECRET":"fixture-only","OTEL_LOG_USER_PROMPTS":"true","OTEL_LOG_RAW_API_BODIES":"file:fixture"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-hook"}]}]},"permissions":{"defaultMode":"default"}}
        """
        let home = try fixture("normal", codex: originalCodex, claude: originalClaude)
        let setup = TelemetrySetup(home: home)
        let result = try setup.connect()
        let codex = String(data: data(home, ".codex/config.toml")!, encoding: .utf8)!
        let claude = try JSONSerialization.jsonObject(with: data(home, ".claude/settings.json")!) as! [String: Any]
        let env = claude["env"] as! [String: Any]
        check(result.changedFiles.count == 2 && result.restartRequired == [.codex, .claude], "Connection did not report both real configuration files and required restarts")
        check(codex.contains("# Keep this comment") && codex.contains("[features]\ncustom_feature = true")
              && codex.contains("environment = \"private # label\"") && codex.contains("# keep exporter comment"), "Codex comments or unrelated fields changed")
        check(codex.contains("/v1/logs\", protocol = \"json\"") && codex.contains("/v1/metrics\", protocol = \"json\"")
              && codex.contains("/v1/traces\", protocol = \"json\""), "Codex did not connect every required JSON signal to loopback")
        check(codex.contains("log_user_prompt = false") && codex.contains("log_agent_responses = false"), "Codex connection would export already-enabled raw content")
        check(env["ANTHROPIC_MODEL"] as? String == "existing-model" && env["CUSTOM_SECRET"] as? String == "fixture-only"
              && claude["hooks"] != nil && claude["permissions"] != nil, "Claude model, authentication-adjacent env or hooks were lost")
        check(env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] as? String == "http://127.0.0.1:16493/v1/logs"
              && env["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"] as? String == "http/json"
              && env["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"] as? String == "1", "Claude API request logs and traces were not connected")
        check(env["OTEL_LOG_USER_PROMPTS"] as? String == "0" && env["OTEL_LOG_RAW_API_BODIES"] as? String == "0"
              && env["OTEL_LOG_TOOL_CONTENT"] == nil, "Claude privacy settings enabled content collection or added an unnecessary content key")
        check(mode(home, ".codex/config.toml") == 0o640 && mode(home, ".claude/settings.json") == 0o640, "Existing configuration permissions changed")
        let beforeCodex = data(home, ".codex/config.toml")
        let beforeClaude = data(home, ".claude/settings.json")
        let repeated = try setup.connect()
        check(repeated.changedFiles.isEmpty && repeated.restartRequired.isEmpty
              && data(home, ".codex/config.toml") == beforeCodex && data(home, ".claude/settings.json") == beforeClaude,
              "Repeated connection rewrote or duplicated telemetry settings")
        let backupRoot = home.appendingPathComponent("Library/Application Support/TokenCat/telemetry-backups")
        let backups = try files.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        check(backups.count == 1 && (try? Data(contentsOf: backups[0].appendingPathComponent("codex-config.toml"))) == Data(originalCodex.utf8)
              && mode(home, "Library/Application Support/TokenCat/telemetry-connection.json") == 0o600, "Exact original backup or private manifest was not saved")
        let disconnected = try setup.disconnect()
        check(disconnected.changedFiles.count == 2 && data(home, ".codex/config.toml") == Data(originalCodex.utf8)
              && data(home, ".claude/settings.json") == Data(originalClaude.utf8), "Disconnect did not restore exact original bytes")
        let repeatedDisconnect = try setup.disconnect()
        check(repeatedDisconnect.changedFiles.isEmpty, "Repeated disconnect modified already-restored settings")

        let emptyHome = try fixture("empty")
        let emptySetup = TelemetrySetup(home: emptyHome)
        _ = try emptySetup.connect()
        check(mode(emptyHome, ".codex/config.toml") == 0o600 && mode(emptyHome, ".claude/settings.json") == 0o600,
              "New configurations were not created with private permissions")
        _ = try emptySetup.disconnect()
        check(data(emptyHome, ".codex/config.toml") == nil && data(emptyHome, ".claude/settings.json") == nil,
              "Disconnect did not remove settings that TokenCat created")

        let externalCodex = "[otel]\nexporter = { otlp-http = { endpoint = \"https://existing.example/v1/logs\", protocol = \"json\" } }\n"
        let conflictHome = try fixture("codex-conflict", codex: externalCodex, claude: originalClaude)
        check(rejected { _ = try TelemetrySetup(home: conflictHome).connect() }
              && data(conflictHome, ".codex/config.toml") == Data(externalCodex.utf8)
              && data(conflictHome, ".claude/settings.json") == Data(originalClaude.utf8), "External Codex exporter conflict changed either source file")
        let externalClaude = "{\"env\":{\"OTEL_EXPORTER_OTLP_ENDPOINT\":\"https://existing.example\"}}"
        let claudeConflict = try fixture("claude-conflict", codex: originalCodex, claude: externalClaude)
        check(rejected { _ = try TelemetrySetup(home: claudeConflict).connect() }
              && data(claudeConflict, ".codex/config.toml") == Data(originalCodex.utf8)
              && data(claudeConflict, ".claude/settings.json") == Data(externalClaude.utf8), "External Claude endpoint conflict changed either source file")
        let nestedCodex = "[otel.exporter.otlp-http]\nendpoint = \"http://127.0.0.1:4318/v1/logs\"\n"
        let nestedHome = try fixture("nested-conflict", codex: nestedCodex, claude: originalClaude)
        check(rejected { _ = try TelemetrySetup(home: nestedHome).connect() } && data(nestedHome, ".claude/settings.json") == Data(originalClaude.utf8),
              "Complex nested Codex TOML was overwritten")
        for (index, complex) in ["otel = { exporter = 'none' }\n", "[otel . exporter . otlp-http]\nendpoint = 'http://existing.example'\n",
                                 "[otel]\n\"exporter\" . otlp-http = { endpoint = 'http://existing.example' }\n", "\"otel\" . exporter = 'none'\n"].enumerated() {
            let complexHome = try fixture("complex-\(index)", codex: complex, claude: originalClaude)
            check(rejected { _ = try TelemetrySetup(home: complexHome).connect() }
                  && data(complexHome, ".codex/config.toml") == Data(complex.utf8)
                  && data(complexHome, ".claude/settings.json") == Data(originalClaude.utf8), "Quoted, inline or spaced TOML telemetry syntax was overwritten")
        }
        let invalidHome = try fixture("invalid-json", codex: originalCodex, claude: "{ invalid")
        check(rejected { _ = try TelemetrySetup(home: invalidHome).connect() } && data(invalidHome, ".codex/config.toml") == Data(originalCodex.utf8),
              "Invalid Claude JSON caused a partial Codex connection")
        let duplicateCodex = "[otel]\nexporter = 'none'\nexporter = 'none'\n"
        let duplicateHome = try fixture("duplicate-key", codex: duplicateCodex, claude: originalClaude)
        check(rejected { _ = try TelemetrySetup(home: duplicateHome).connect() } && data(duplicateHome, ".claude/settings.json") == Data(originalClaude.utf8),
              "Duplicate Codex exporter keys caused a partial connection")
        let headerClaude = "{\"env\":{\"OTEL_EXPORTER_OTLP_HEADERS\":{\"authorization\":\"fixture-only\"}}}"
        let headerHome = try fixture("invalid-headers", codex: originalCodex, claude: headerClaude)
        check(rejected { _ = try TelemetrySetup(home: headerHome).connect() } && data(headerHome, ".codex/config.toml") == Data(originalCodex.utf8),
              "Malformed existing exporter authentication was ignored")
        let symlinkHome = try fixture("symlink", claude: originalClaude)
        try files.createDirectory(at: symlinkHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let linkedTarget = symlinkHome.appendingPathComponent("original.toml")
        try Data(originalCodex.utf8).write(to: linkedTarget)
        try files.createSymbolicLink(at: symlinkHome.appendingPathComponent(".codex/config.toml"), withDestinationURL: linkedTarget)
        check(rejected { _ = try TelemetrySetup(home: symlinkHome).connect() }
              && (try? Data(contentsOf: linkedTarget)) == Data(originalCodex.utf8)
              && data(symlinkHome, ".claude/settings.json") == Data(originalClaude.utf8), "Configuration symlink was replaced or caused a partial connection")

        let editedHome = try fixture("user-edit", codex: originalCodex, claude: originalClaude)
        let editedSetup = TelemetrySetup(home: editedHome)
        _ = try editedSetup.connect()
        let connectedClaude = data(editedHome, ".claude/settings.json")
        let userEdit = data(editedHome, ".codex/config.toml")! + Data("\n# User edit after connection\n".utf8)
        try userEdit.write(to: editedHome.appendingPathComponent(".codex/config.toml"))
        check(rejected { _ = try editedSetup.disconnect() } && data(editedHome, ".codex/config.toml") == userEdit
              && data(editedHome, ".claude/settings.json") == connectedClaude, "Disconnect overwrote an intervening user edit or partially restored the other client")

        let failedHome = try fixture("write-failure", codex: originalCodex, claude: originalClaude)
        let restricted = failedHome.appendingPathComponent(".claude")
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restricted.path)
        let didFail = rejected { _ = try TelemetrySetup(home: failedHome).connect() }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        check(didFail && data(failedHome, ".codex/config.toml") == Data(originalCodex.utf8)
              && data(failedHome, ".claude/settings.json") == Data(originalClaude.utf8), "Real second-file write failure did not roll back the first configuration")

        let multilineCodex = "policy = '''\n[otel]\nnot_a_real_table = true\n'''\n[features]\ncustom_feature = true\n"
        let multilineHome = try fixture("multiline", codex: multilineCodex, claude: "{}")
        _ = try TelemetrySetup(home: multilineHome).connect()
        let multilineAfter = String(data: data(multilineHome, ".codex/config.toml")!, encoding: .utf8)!
        check(multilineAfter.hasPrefix(multilineCodex) && multilineAfter.contains("\n[otel]\nexporter ="),
              "TOML multiline string contents were mistaken for a telemetry table")
        let crlfCodex = originalCodex.replacingOccurrences(of: "\n", with: "\r\n")
        let crlfHome = try fixture("crlf", codex: crlfCodex, claude: "{}")
        _ = try TelemetrySetup(home: crlfHome).connect()
        let crlfAfter = String(data: data(crlfHome, ".codex/config.toml")!, encoding: .utf8)!
        check(!crlfAfter.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "Codex CRLF line endings were normalized")
    } catch {
        checks += 1
        failures.append("Telemetry setup fixture failed: \(error.localizedDescription)")
    }
    print("Telemetry setup checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
