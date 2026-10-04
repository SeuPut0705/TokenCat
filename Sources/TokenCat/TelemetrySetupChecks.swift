import CryptoKit
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
    let support = "Library/Application Support/TokenCat"
    let script = support + "/" + TelemetrySetup.statusLineScriptName
    let sidecar = support + "/" + TelemetrySetup.statusLineOriginalName
    func object(_ home: URL, _ relative: String) -> [String: Any]? {
        data(home, relative).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    func statusLine(_ home: URL) -> [String: Any]? { object(home, ".claude/settings.json")?["statusLine"] as? [String: Any] }

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
        check(statusLine(home).map { NSDictionary(dictionary: $0).isEqual(to: ["type": "command", "command": TelemetrySetup.statusLineCommand]) } == true
              && data(home, sidecar) == nil && data(home, script) == Data(TelemetrySetup.statusLineScript.utf8),
              "Settings without a status line did not get a bridge that prints nothing")
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
        check(data(home, script) == nil && data(home, sidecar) == nil, "Disconnect left the status line bridge behind")
        let repeatedDisconnect = try setup.disconnect()
        check(repeatedDisconnect.changedFiles.isEmpty, "Repeated disconnect modified already-restored settings")

        let emptyHome = try fixture("empty")
        let emptySetup = TelemetrySetup(home: emptyHome)
        _ = try emptySetup.connect()
        check(mode(emptyHome, ".codex/config.toml") == 0o600 && mode(emptyHome, ".claude/settings.json") == 0o600,
              "New configurations were not created with private permissions")
        _ = try emptySetup.disconnect()
        check(data(emptyHome, ".codex/config.toml") == nil && data(emptyHome, ".claude/settings.json") == nil && data(emptyHome, script) == nil,
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

        // A Codex edit (Codex writes trust levels itself) refuses both whole-file restores; only the status line TokenCat
        // added goes, and an unchanged Claude entry stays restorable once the Codex edit is undone.
        let editedHome = try fixture("user-edit", codex: originalCodex, claude: originalClaude)
        let editedSetup = TelemetrySetup(home: editedHome)
        _ = try editedSetup.connect()
        let connectedCodex = data(editedHome, ".codex/config.toml")!
        let connectedClaude = data(editedHome, ".claude/settings.json")!
        let userEdit = connectedCodex + Data("\n[projects.\"/work/sample\"]\ntrust_level = \"trusted\"\n".utf8)
        try userEdit.write(to: editedHome.appendingPathComponent(".codex/config.toml"))
        var codexRefusal = ""
        do { _ = try editedSetup.disconnect() } catch { codexRefusal = error.localizedDescription }
        var withoutLine = (try JSONSerialization.jsonObject(with: connectedClaude) as? [String: Any]) ?? [:]
        withoutLine["statusLine"] = nil
        let afterRefusal = data(editedHome, ".claude/settings.json")
        check(codexRefusal.hasPrefix("연결 후 Codex 설정이 수정됐습니다") && codexRefusal.contains("TokenCat이 추가한 Claude Code 상태 표시줄은 지웠습니다")
              && data(editedHome, ".codex/config.toml") == userEdit
              && afterRefusal.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }?.isEqual(to: withoutLine) == true
              && data(editedHome, script) == nil, "A Codex edit overwrote the edit, touched more than the status line, or left the bridge named")
        let restoreBackups = (try? files.contentsOfDirectory(atPath: editedHome.appendingPathComponent(support + "/telemetry-backups").path))?
            .flatMap { folder in ((try? files.contentsOfDirectory(atPath: editedHome.appendingPathComponent(support + "/telemetry-backups/" + folder).path)) ?? [])
                .filter { $0.hasPrefix("claude-settings-before-statusline-restore-") }.map { support + "/telemetry-backups/" + folder + "/" + $0 } } ?? []
        check(restoreBackups.count == 1 && data(editedHome, restoreBackups[0]) == connectedClaude && mode(editedHome, restoreBackups[0]) == 0o600,
              "The settings were not backed up privately before the status line was put back")
        try connectedCodex.write(to: editedHome.appendingPathComponent(".codex/config.toml"))
        _ = try editedSetup.disconnect()
        check(data(editedHome, ".codex/config.toml") == Data(originalCodex.utf8) && data(editedHome, ".claude/settings.json") == Data(originalClaude.utf8),
              "After the Codex edit was undone, disconnect did not restore both exact originals")

        let failedHome = try fixture("write-failure", codex: originalCodex, claude: originalClaude)
        let restricted = failedHome.appendingPathComponent(".claude")
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restricted.path)
        let didFail = rejected { _ = try TelemetrySetup(home: failedHome).connect() }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        check(didFail && data(failedHome, ".codex/config.toml") == Data(originalCodex.utf8)
              && data(failedHome, ".claude/settings.json") == Data(originalClaude.utf8), "Real second-file write failure did not roll back the first configuration")
        check(data(failedHome, script) == nil, "A rolled-back connection left an unreferenced status line bridge")

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

        // Claude Code status line: wrapped with every other field kept, recorded, restored exactly and cleaned up.
        let originalCommand = #"/bin/sh "$HOME/.claude/statusline-ccusage.sh""#
        let lineClaude = #"{"statusLine":{"type":"command","command":"/bin/sh \"$HOME/.claude/statusline-ccusage.sh\"","padding":0},"theme":"dark"}"#
        let lineHome = try fixture("statusline", codex: originalCodex, claude: lineClaude)
        let lineSetup = TelemetrySetup(home: lineHome)
        let lineResult = try lineSetup.connect()
        let wrapped = statusLine(lineHome)
        check(wrapped?["command"] as? String == TelemetrySetup.statusLineCommand && wrapped?["padding"] as? Int == 0
              && wrapped?["type"] as? String == "command" && object(lineHome, ".claude/settings.json")?["theme"] as? String == "dark"
              && lineResult.restartRequired == [.codex, .claude] && lineResult.bridged && lineResult.notes.isEmpty,
              "Status line was not wrapped with its other fields kept")
        check(data(lineHome, sidecar) == Data(originalCommand.utf8) && data(lineHome, script) == Data(TelemetrySetup.statusLineScript.utf8)
              && mode(lineHome, script) == 0o700 && mode(lineHome, sidecar) == 0o600, "Bridge script or original command was not saved privately")
        let recorded = ((object(lineHome, support + "/telemetry-connection.json")?["statusLine"] as? [String: Any])?["original"] as? String)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
        check(recorded?.isEqual(to: ["type": "command", "command": originalCommand, "padding": 0]) == true,
              "The replaced status line object was not recorded with the backups")
        check(TelemetrySetup.statusLineScript.contains("http://127.0.0.1:\(TelemetrySetup.port)/v1/claude/status")
              && TelemetrySetup.statusLineScript.contains("</dev/null >/dev/null 2>&1 &") && TelemetrySetup.statusLineScript.contains("--noproxy '*'")
              && TelemetrySetup.statusLineScript.contains("/usr/bin/curl -q ")
              && TelemetrySetup.statusLineCommand == #"/bin/sh "$HOME/Library/Application Support/TokenCat/claude-statusline.sh""#,
              "Bridge script lost its loopback-only, detached forwarding")
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntax.arguments = ["-n", lineHome.appendingPathComponent(script).path]
        try syntax.run()
        syntax.waitUntilExit()
        check(syntax.terminationStatus == 0, "Bridge script is not valid sh")
        let lineBytes = data(lineHome, ".claude/settings.json")
        let lineAgain = try lineSetup.connect()
        check(lineAgain.changedFiles.isEmpty && data(lineHome, ".claude/settings.json") == lineBytes && data(lineHome, sidecar) == Data(originalCommand.utf8),
              "Repeated connection wrapped the bridge again or replaced its original command")
        _ = try lineSetup.disconnect()
        check(data(lineHome, ".claude/settings.json") == Data(lineClaude.utf8) && data(lineHome, script) == nil && data(lineHome, sidecar) == nil,
              "Disconnect did not restore the exact status line or left the bridge behind")

        // An unexpected shape is left alone with a note; the OTLP connection itself still applies.
        for (index, odd) in [#"{"statusLine":"echo hi"}"#, #"{"statusLine":{"type":"static","text":"hi"}}"#,
                             #"{"statusLine":{"type":"command","command":" "}}"#, #"{"statusLine":null}"#].enumerated() {
            let oddHome = try fixture("statusline-odd-\(index)", codex: originalCodex, claude: odd)
            let oddResult = try TelemetrySetup(home: oddHome).connect()
            let before = (try? JSONSerialization.jsonObject(with: Data(odd.utf8)) as? NSDictionary)?["statusLine"] as? NSObject
            let after = object(oddHome, ".claude/settings.json")
            check(oddResult.message.contains("statusLine 형식이 예상과 달라") && oddResult.notes == [.statusLineSkipped] && !oddResult.bridged
                  && (after?["env"] as? [String: Any])?["OTEL_LOGS_EXPORTER"] as? String == "otlp"
                  && (after?["statusLine"] as? NSObject).map { before?.isEqual($0) == true } == true && data(oddHome, script) == nil,
                  "An unexpected status line shape was changed or blocked the connection")
        }

        // A status line the person changed after the bridge is theirs: no restore over it, no second wrap.
        let changedHome = try fixture("statusline-user", codex: originalCodex, claude: lineClaude)
        let changedSetup = TelemetrySetup(home: changedHome)
        _ = try changedSetup.connect()
        var changedSettings = object(changedHome, ".claude/settings.json") ?? [:]
        changedSettings["statusLine"] = ["type": "command", "command": "echo mine"]
        let userLine = try JSONSerialization.data(withJSONObject: changedSettings, options: [.sortedKeys])
        try userLine.write(to: changedHome.appendingPathComponent(".claude/settings.json"))
        var said = false
        do { _ = try changedSetup.disconnect() } catch { said = error.localizedDescription.contains("상태 표시줄도 지금 설정 그대로 두었습니다") }
        let changedAgain = try changedSetup.connect()
        check(said && data(changedHome, ".claude/settings.json") == userLine && changedAgain.changedFiles.isEmpty
              && statusLine(changedHome)?["command"] as? String == "echo mine",
              "A status line changed by the person was restored over, wrapped again, or not reported")

        // Settings Claude Code rewrote after the connection (its own formatting, a new key): the whole-file restore is
        // refused, yet the status line still running the bridge goes back to the original command, byte for byte, with
        // the env and the new key kept, the bridge removed, and no second wrap at the next launch.
        func literal(_ string: String) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
        }
        func javaScriptStyle(_ object: [String: Any], prefix: String = "") throws -> Data {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]), as: UTF8.self)
            return Data(("{\n" + prefix + text.dropFirst(2)).replacingOccurrences(of: "\" : ", with: "\": ").utf8)
        }
        let ownHome = try fixture("statusline-own", codex: originalCodex, claude: lineClaude)
        let ownSetup = TelemetrySetup(home: ownHome)
        _ = try ownSetup.connect()
        var rewritten = object(ownHome, ".claude/settings.json") ?? [:]
        rewritten["enabledPlugins"] = ["sample@market": true]
        let claudeEdit = try javaScriptStyle(rewritten, prefix: "  \"someFloat\": 0.1,\n")
        try claudeEdit.write(to: ownHome.appendingPathComponent(".claude/settings.json"))
        var ownRefusal = ""
        do { _ = try ownSetup.disconnect() } catch { ownRefusal = error.localizedDescription }
        let putBack = String(decoding: claudeEdit, as: UTF8.self).replacingOccurrences(of: literal(TelemetrySetup.statusLineCommand), with: literal(originalCommand))
        check(ownRefusal.hasPrefix("연결 후 Claude Code 설정이 수정됐습니다") && ownRefusal.contains("Claude Code 상태 표시줄은 원래 명령으로 되돌렸습니다")
              && data(ownHome, ".claude/settings.json") == Data(putBack.utf8) && (object(ownHome, ".claude/settings.json")?["env"] as? [String: Any])?["OTEL_LOGS_EXPORTER"] as? String == "otlp"
              && data(ownHome, script) == nil && data(ownHome, sidecar) == nil,
              "An edited file kept the bridge, changed more than the status line command, or left the bridge behind")
        let ownAgain = try ownSetup.connect()
        check(ownAgain.changedFiles.isEmpty && data(ownHome, ".claude/settings.json") == Data(putBack.utf8) && data(ownHome, script) == nil,
              "The next launch wrapped a restored status line again")

        // A bridge without its original command: recreated from the record when the sidecar went missing; settings copied
        // from another Mac (bridge named, nothing recorded here) or another spelling of the bridge are reported, never wrapped.
        let sidecarHome = try fixture("statusline-sidecar", codex: originalCodex, claude: lineClaude)
        _ = try TelemetrySetup(home: sidecarHome).connect()
        try files.removeItem(at: sidecarHome.appendingPathComponent(sidecar))
        let recreated = try TelemetrySetup(home: sidecarHome).connect()
        check(recreated.changedFiles.isEmpty && recreated.message.contains("원래 명령을 백업 기록에서 다시 만들었습니다")
              && recreated.notes == [.originalRecreated] && recreated.bridged
              && data(sidecarHome, sidecar) == Data(originalCommand.utf8) && mode(sidecarHome, sidecar) == 0o600,
              "A missing original command was not recreated from the record")
        let syncedHome = try fixture("statusline-synced", codex: String(decoding: data(sidecarHome, ".codex/config.toml") ?? Data(), as: UTF8.self),
                                     claude: String(decoding: data(sidecarHome, ".claude/settings.json") ?? Data(), as: UTF8.self))
        let syncedBytes = data(syncedHome, ".claude/settings.json")
        let synced = try TelemetrySetup(home: syncedHome).connect()
        check(synced.changedFiles.isEmpty && synced.message.contains("원래 명령을 찾을 수 없어") && synced.notes == [.originalUnknown] && synced.bridged
              && data(syncedHome, ".claude/settings.json") == syncedBytes
              && data(syncedHome, script) != nil && data(syncedHome, sidecar) == nil,
              "Settings naming the bridge without a record here said 'already applied' or were changed")
        let spelled = #"{"statusLine":{"type":"command","command":"/bin/sh '/Users/sample/Library/Application Support/TokenCat/claude-statusline.sh'"}}"#
        let spelledHome = try fixture("statusline-spelled", codex: originalCodex, claude: spelled)
        let spelledResult = try TelemetrySetup(home: spelledHome).connect()
        check(statusLine(spelledHome)?["command"] as? String == "/bin/sh '/Users/sample/Library/Application Support/TokenCat/claude-statusline.sh'"
              && data(spelledHome, sidecar) == nil && spelledResult.message.contains("원래 명령을 찾을 수 없어") && spelledResult.notes == [.originalUnknown]
              && (object(spelledHome, support + "/telemetry-connection.json")?["statusLine"]) == nil,
              "Another spelling of the bridge was wrapped as its own original")

        // Connections made before the bridge (0.8.0: env connected, status line untouched, no record) get it at launch.
        func legacy(_ name: String, claudeEntry: Bool = true) throws -> URL {
            let home = try fixture(name, codex: originalCodex, claude: lineClaude)
            _ = try TelemetrySetup(home: home).connect()
            var settings = object(home, ".claude/settings.json") ?? [:]
            settings["statusLine"] = (try JSONSerialization.jsonObject(with: Data(lineClaude.utf8)) as? [String: Any])?["statusLine"]
            let envOnly = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
            try envOnly.write(to: home.appendingPathComponent(".claude/settings.json"))
            var manifest = object(home, support + "/telemetry-connection.json") ?? [:]
            manifest["statusLine"] = nil
            var entries = manifest["entries"] as? [[String: Any]] ?? []
            let backups = home.appendingPathComponent(support + "/telemetry-backups/\(manifest["backupDirectory"] as? String ?? "")")
            if claudeEntry {
                let digest = SHA256.hash(data: envOnly).map { String(format: "%02x", $0) }.joined()
                entries = entries.map { $0["source"] as? String == "claude" ? $0.merging(["connectedSHA256": digest]) { $1 } : $0 }
            } else {
                entries.removeAll { $0["source"] as? String == "claude" }
                try files.removeItem(at: backups.appendingPathComponent("claude-settings.json"))
            }
            manifest["entries"] = entries
            let manifestData = try JSONSerialization.data(withJSONObject: manifest)
            try manifestData.write(to: home.appendingPathComponent(support + "/telemetry-connection.json"))
            try manifestData.write(to: backups.appendingPathComponent("manifest.json"))
            try files.removeItem(at: home.appendingPathComponent(script))
            try files.removeItem(at: home.appendingPathComponent(sidecar))
            return home
        }
        let oldHome = try legacy("legacy")
        let migrated = try TelemetrySetup(home: oldHome).connect()
        check(migrated.changedFiles == [oldHome.appendingPathComponent(".claude/settings.json").path] && migrated.restartRequired.isEmpty
              && statusLine(oldHome)?["command"] as? String == TelemetrySetup.statusLineCommand && statusLine(oldHome)?["padding"] as? Int == 0
              && data(oldHome, sidecar) == Data(originalCommand.utf8) && data(oldHome, script) != nil
              && data(oldHome, ".codex/config.toml") != Data(originalCodex.utf8)
              && (object(oldHome, support + "/telemetry-connection.json")?["statusLine"] as? [String: Any])?["original"] is String,
              "An existing connection did not get the status line bridge with its record")
        let migratedBytes = data(oldHome, ".claude/settings.json")
        let migratedAgain = try TelemetrySetup(home: oldHome).connect()
        check(migratedAgain.changedFiles.isEmpty && data(oldHome, ".claude/settings.json") == migratedBytes,
              "The migration was not idempotent")
        _ = try TelemetrySetup(home: oldHome).disconnect()
        check(data(oldHome, ".claude/settings.json") == Data(lineClaude.utf8) && data(oldHome, ".codex/config.toml") == Data(originalCodex.utf8)
              && data(oldHome, script) == nil && data(oldHome, sidecar) == nil,
              "A migrated connection did not restore the exact pre-connection settings and status line")
        // Edited after the 0.8.0 connection (the user's case; that whole-file restore already refuses): the file is backed
        // up as it is, only the command literal changes (its formatting and `0.1` stay), and disconnect puts those exact
        // pre-bridge bytes back while refusing the whole-file restore.
        let editedOldHome = try legacy("legacy-edited")
        var edited = object(editedOldHome, ".claude/settings.json") ?? [:]
        edited["theme"] = "light"
        let editedBytes = try javaScriptStyle(edited, prefix: "  \"someFloat\": 0.1,\n")
        try editedBytes.write(to: editedOldHome.appendingPathComponent(".claude/settings.json"))
        _ = try TelemetrySetup(home: editedOldHome).connect()
        let editedBridged = String(decoding: editedBytes, as: UTF8.self).replacingOccurrences(of: literal(originalCommand), with: literal(TelemetrySetup.statusLineCommand))
        let backupFolder = object(editedOldHome, support + "/telemetry-connection.json")?["backupDirectory"] as? String ?? ""
        let editedPreBridge = data(editedOldHome, support + "/telemetry-backups/\(backupFolder)/" + TelemetrySetup.preBridgeBackupName)
        check(data(editedOldHome, ".claude/settings.json") == Data(editedBridged.utf8) && editedPreBridge == editedBytes,
              "The bridge migration reformatted an edited file or did not back it up first")
        var oldRefusal = ""
        do { _ = try TelemetrySetup(home: editedOldHome).disconnect() } catch { oldRefusal = error.localizedDescription }
        check(oldRefusal.contains("Claude Code 상태 표시줄은 원래 명령으로 되돌렸습니다") && data(editedOldHome, ".claude/settings.json") == editedBytes
              && data(editedOldHome, script) == nil && data(editedOldHome, sidecar) == nil,
              "An edited 0.8.0 connection did not get its exact pre-bridge settings back or kept the bridge")
        // Without a Claude entry (its env was already there), the pre-bridge file becomes the entry's exact backup.
        let entrylessHome = try legacy("legacy-entryless", claudeEntry: false)
        let preBridge = data(entrylessHome, ".claude/settings.json")
        _ = try TelemetrySetup(home: entrylessHome).connect()
        _ = try TelemetrySetup(home: entrylessHome).disconnect()
        check(data(entrylessHome, ".claude/settings.json") == preBridge && data(entrylessHome, ".codex/config.toml") == Data(originalCodex.utf8)
              && data(entrylessHome, script) == nil, "A connection without a Claude entry did not restore its pre-bridge settings")
        // Any other change since the connection keeps the existing refusal.
        let driftedHome = try legacy("legacy-drifted")
        var drifted = object(driftedHome, ".claude/settings.json") ?? [:]
        var driftedEnv = drifted["env"] as? [String: Any] ?? [:]
        driftedEnv["OTEL_LOGS_EXPORTER"] = nil
        drifted["env"] = driftedEnv
        let driftedBytes = try JSONSerialization.data(withJSONObject: drifted, options: [.sortedKeys])
        try driftedBytes.write(to: driftedHome.appendingPathComponent(".claude/settings.json"))
        check(rejected { _ = try TelemetrySetup(home: driftedHome).connect() } && data(driftedHome, ".claude/settings.json") == driftedBytes
              && data(driftedHome, script) == nil, "A connection changed in another way was migrated or overwritten")
    } catch {
        checks += 1
        failures.append("Telemetry setup fixture failed: \(error.localizedDescription)")
    }
    print("Telemetry setup checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
