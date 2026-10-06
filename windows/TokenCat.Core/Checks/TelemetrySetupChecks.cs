using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenCat;

/// TelemetrySetupChecks.swift on temp homes only. Windows v1 adaptations (DESIGN §7.4): the bridge is a PowerShell script added
/// only when settings have no statusLine, so the Swift wrap/sidecar cases check that an existing status line stays untouched
/// (note `StatusLineKept`), and the 0.8.0 migration cases become "a kept status line was later removed". POSIX modes are
/// not applied on Windows, so those halves are counted as skips.
public static class TelemetrySetupChecks
{
    public static List<string> Run()
    {
        var c = new Check("Telemetry setup");
        void check(bool valid, string description) => c.That(valid, description);
        var root = Directory.CreateTempSubdirectory("tokencat-setup-checks-");
        const string support = "AppData/Local/TokenCat", claudeFile = ".claude/settings.json", codexFile = ".codex/config.toml";
        const string script = support + "/" + TelemetrySetup.StatusLineScriptName, manifestFile = support + "/telemetry-connection.json";
        string Fixture(string name, string? codex = null, string? claude = null)
        {
            var home = Directory.CreateDirectory(Path.Combine(root.FullName, name)).FullName;
            foreach (var (relative, contents) in new[] { (codexFile, codex), (claudeFile, claude) })
            {
                if (contents is null) continue;
                Directory.CreateDirectory(Path.GetDirectoryName(Path.Combine(home, relative))!);
                File.WriteAllBytes(Path.Combine(home, relative), Encoding.UTF8.GetBytes(contents));
            }
            return home;
        }
        static TelemetrySetup Setup(string home) => new(home, Path.Combine(home, support));
        static byte[]? Data(string home, string relative) => File.Exists(Path.Combine(home, relative)) ? File.ReadAllBytes(Path.Combine(home, relative)) : null;
        static bool Same(byte[]? a, byte[]? b) => a is null ? b is null : b is not null && a.AsSpan().SequenceEqual(b);
        static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);
        static void Put(string home, string relative, byte[] data) => File.WriteAllBytes(Path.Combine(home, relative), data);
        static JsonObject? Object(string home, string relative) => Data(home, relative) is { } data ? Json.ParseNode(data) as JsonObject : null;
        static JsonObject? StatusLine(string home) => Object(home, claudeFile)?["statusLine"] as JsonObject;
        static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue(out string? text) ? text : null;
        static bool Rejected(Action action)
        {
            try { action(); return false; }
            catch (Exception) { return true; }
        }
        static string Refusal(Action action)
        {
            try { action(); return ""; }
            catch (Exception error) { return error.Message; }
        }
        List<string> BackupFiles(string home, string prefix)
        {
            var backups = Path.Combine(home, support, "telemetry-backups");
            return Directory.Exists(backups)
                ? [.. Directory.GetDirectories(backups).SelectMany(folder => Directory.GetFiles(folder))
                    .Where(file => Path.GetFileName(file).StartsWith(prefix, StringComparison.Ordinal)).Select(file => Path.GetRelativePath(home, file))]
                : [];
        }
        // Claude Code's own formatting (JSON.stringify(…, null, 2)): insertion order, `": "`, LF.
        static byte[] JavaScriptStyle(JsonObject value, string prefix = "") => Bytes("{\n" + prefix + value.ToJsonString(new JsonSerializerOptions
            { WriteIndented = true, NewLine = "\n", Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping })[2..]);

        try
        {
            // A raw literal takes the checkout's line endings (CRLF on a Windows runner, core.autocrlf): LF like the mac fixture.
            var originalCodex = """
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

                """.ReplaceLineEndings("\n");
            const string originalClaude = """{"env":{"ANTHROPIC_MODEL":"existing-model","CUSTOM_SECRET":"fixture-only","OTEL_LOG_USER_PROMPTS":"true","OTEL_LOG_RAW_API_BODIES":"file:fixture"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-hook"}]}]},"permissions":{"defaultMode":"default"}}""";
            var home = Fixture("normal", originalCodex, originalClaude);
            var setup = Setup(home);
            var result = setup.Connect();
            var codex = Encoding.UTF8.GetString(Data(home, codexFile)!);
            var claude = Object(home, claudeFile)!;
            var env = claude["env"]!.AsObject();
            check(result.ChangedFiles.Count == 2 && result.RestartRequired.SequenceEqual([TokenSource.Codex, TokenSource.Claude]),
                  "Connection did not report both real configuration files and required restarts");
            check(codex.Contains("# Keep this comment") && codex.Contains("[features]\ncustom_feature = true")
                  && codex.Contains("environment = \"private # label\"") && codex.Contains("# keep exporter comment"), "Codex comments or unrelated fields changed");
            check(codex.Contains("/v1/logs\", protocol = \"json\"") && codex.Contains("/v1/metrics\", protocol = \"json\"")
                  && codex.Contains("/v1/traces\", protocol = \"json\""), "Codex did not connect every required JSON signal to loopback");
            check(codex.Contains("log_user_prompt = false") && codex.Contains("log_agent_responses = false"), "Codex connection would export already-enabled raw content");
            check(Text(env["ANTHROPIC_MODEL"]) == "existing-model" && Text(env["CUSTOM_SECRET"]) == "fixture-only"
                  && claude["hooks"] is not null && claude["permissions"] is not null, "Claude model, authentication-adjacent env or hooks were lost");
            check(Text(env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"]) == "http://127.0.0.1:16493/v1/logs" && Text(env["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"]) == "http/json"
                  && Text(env["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"]) == "1", "Claude API request logs and traces were not connected");
            check(Text(env["OTEL_LOG_USER_PROMPTS"]) == "0" && Text(env["OTEL_LOG_RAW_API_BODIES"]) == "0" && !env.ContainsKey("OTEL_LOG_TOOL_CONTENT"),
                  "Claude privacy settings enabled content collection or added an unnecessary content key");
            c.Skip(); // "Existing configuration permissions changed": POSIX modes are not applied on Windows (File.Replace keeps the ACL).
            check(JsonNode.DeepEquals(StatusLine(home), new JsonObject { ["type"] = "command", ["command"] = setup.StatusLineCommand })
                  && Same(Data(home, script), Encoding.ASCII.GetBytes(TelemetrySetup.StatusLineScript())) && result.Bridged,
                  "Settings without a status line did not get a bridge that prints nothing");
            var beforeCodex = Data(home, codexFile);
            var beforeClaude = Data(home, claudeFile);
            var repeated = setup.Connect();
            check(repeated.ChangedFiles.Count == 0 && repeated.RestartRequired.Count == 0
                  && Same(Data(home, codexFile), beforeCodex) && Same(Data(home, claudeFile), beforeClaude),
                  "Repeated connection rewrote or duplicated telemetry settings");
            var backups = Directory.GetDirectories(Path.Combine(home, support, "telemetry-backups"));
            check(backups.Length == 1 && Same(File.ReadAllBytes(Path.Combine(backups[0], "codex-config.toml")), Bytes(originalCodex))
                  && Data(home, manifestFile) is not null, "Exact original backup or private manifest was not saved");
            var disconnected = setup.Disconnect();
            check(disconnected.ChangedFiles.Count == 2 && Same(Data(home, codexFile), Bytes(originalCodex))
                  && Same(Data(home, claudeFile), Bytes(originalClaude)), "Disconnect did not restore exact original bytes");
            check(Data(home, script) is null, "Disconnect left the status line bridge behind");
            var repeatedDisconnect = setup.Disconnect();
            check(repeatedDisconnect.ChangedFiles.Count == 0, "Repeated disconnect modified already-restored settings");

            var emptyHome = Fixture("empty");
            var emptySetup = Setup(emptyHome);
            emptySetup.Connect();
            c.Skip(); // "New configurations were not created with private permissions": POSIX modes (see above).
            emptySetup.Disconnect();
            check(Data(emptyHome, codexFile) is null && Data(emptyHome, claudeFile) is null && Data(emptyHome, script) is null,
                  "Disconnect did not remove settings that TokenCat created");

            const string externalCodex = "[otel]\nexporter = { otlp-http = { endpoint = \"https://existing.example/v1/logs\", protocol = \"json\" } }\n";
            var conflictHome = Fixture("codex-conflict", externalCodex, originalClaude);
            check(Rejected(() => Setup(conflictHome).Connect()) && Same(Data(conflictHome, codexFile), Bytes(externalCodex))
                  && Same(Data(conflictHome, claudeFile), Bytes(originalClaude)), "External Codex exporter conflict changed either source file");
            const string externalClaude = """{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"https://existing.example"}}""";
            var claudeConflict = Fixture("claude-conflict", originalCodex, externalClaude);
            check(Rejected(() => Setup(claudeConflict).Connect()) && Same(Data(claudeConflict, codexFile), Bytes(originalCodex))
                  && Same(Data(claudeConflict, claudeFile), Bytes(externalClaude)), "External Claude endpoint conflict changed either source file");
            var nestedHome = Fixture("nested-conflict", "[otel.exporter.otlp-http]\nendpoint = \"http://127.0.0.1:4318/v1/logs\"\n", originalClaude);
            check(Rejected(() => Setup(nestedHome).Connect()) && Same(Data(nestedHome, claudeFile), Bytes(originalClaude)), "Complex nested Codex TOML was overwritten");
            string[] complexCodex = ["otel = { exporter = 'none' }\n", "[otel . exporter . otlp-http]\nendpoint = 'http://existing.example'\n",
                "[otel]\n\"exporter\" . otlp-http = { endpoint = 'http://existing.example' }\n", "\"otel\" . exporter = 'none'\n"];
            for (var index = 0; index < complexCodex.Length; index++)
            {
                var complexHome = Fixture($"complex-{index}", complexCodex[index], originalClaude);
                check(Rejected(() => Setup(complexHome).Connect()) && Same(Data(complexHome, codexFile), Bytes(complexCodex[index]))
                      && Same(Data(complexHome, claudeFile), Bytes(originalClaude)), "Quoted, inline or spaced TOML telemetry syntax was overwritten");
            }
            var invalidHome = Fixture("invalid-json", originalCodex, "{ invalid");
            check(Rejected(() => Setup(invalidHome).Connect()) && Same(Data(invalidHome, codexFile), Bytes(originalCodex)),
                  "Invalid Claude JSON caused a partial Codex connection");
            var duplicateHome = Fixture("duplicate-key", "[otel]\nexporter = 'none'\nexporter = 'none'\n", originalClaude);
            check(Rejected(() => Setup(duplicateHome).Connect()) && Same(Data(duplicateHome, claudeFile), Bytes(originalClaude)),
                  "Duplicate Codex exporter keys caused a partial connection");
            // Claude Code reads the last duplicate and JSONSerialization the first: a rewrite would drop the env in use.
            string[] duplicatedClaude = ["""{"env":{"OLD":"1"},"model":"opus","env":{"ANTHROPIC_BASE_URL":"http://in-use"}}""", """{"env":{"A":"1","A":"2"}}"""];
            for (var index = 0; index < duplicatedClaude.Length; index++)
            {
                var duplicateClaude = Fixture($"duplicate-json-{index}", originalCodex, duplicatedClaude[index]);
                check(Rejected(() => Setup(duplicateClaude).Connect()) && Same(Data(duplicateClaude, claudeFile), Bytes(duplicatedClaude[index]))
                      && Same(Data(duplicateClaude, codexFile), Bytes(originalCodex)),
                      "Duplicate Claude settings.json keys were rewritten to JSONSerialization's choice");
            }
            var headerHome = Fixture("invalid-headers", originalCodex, """{"env":{"OTEL_EXPORTER_OTLP_HEADERS":{"authorization":"fixture-only"}}}""");
            check(Rejected(() => Setup(headerHome).Connect()) && Same(Data(headerHome, codexFile), Bytes(originalCodex)),
                  "Malformed existing exporter authentication was ignored");
            var symlinkHome = Fixture("symlink", claude: originalClaude);
            Directory.CreateDirectory(Path.Combine(symlinkHome, ".codex"));
            var linkedTarget = Path.Combine(symlinkHome, "original.toml");
            File.WriteAllBytes(linkedTarget, Bytes(originalCodex));
            var linked = true;
            // Windows needs Developer Mode or elevation for a symbolic link (the CI runner is elevated).
            try { File.CreateSymbolicLink(Path.Combine(symlinkHome, codexFile), linkedTarget); }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException) { linked = false; }
            if (linked)
                check(Rejected(() => Setup(symlinkHome).Connect()) && Same(File.ReadAllBytes(linkedTarget), Bytes(originalCodex))
                      && Same(Data(symlinkHome, claudeFile), Bytes(originalClaude)), "Configuration symlink was replaced or caused a partial connection");
            else c.Skip();

            // A Codex edit when the original had its own [otel] table (TokenCat's keys are mixed into it) refuses the restore;
            // only the status line TokenCat added goes, and an unchanged Claude entry stays restorable once the edit is undone.
            var editedHome = Fixture("user-edit", originalCodex, originalClaude);
            var editedSetup = Setup(editedHome);
            editedSetup.Connect();
            var connectedCodex = Data(editedHome, codexFile)!;
            var connectedClaude = Data(editedHome, claudeFile)!;
            byte[] userEdit = [.. connectedCodex, .. Bytes("\n[projects.\"/work/sample\"]\ntrust_level = \"trusted\"\n")];
            Put(editedHome, codexFile, userEdit);
            var codexRefusal = Refusal(() => editedSetup.Disconnect());
            var withoutLine = (JsonObject)Json.ParseNode(connectedClaude)!;
            withoutLine.Remove("statusLine");
            check(codexRefusal.StartsWith("연결 후 Codex 설정이 수정돼 TokenCat 항목만 따로 되돌릴 수 없습니다", StringComparison.Ordinal)
                  && codexRefusal.Contains("TokenCat이 추가한 Claude Code 상태 표시줄은 지웠습니다") && Same(Data(editedHome, codexFile), userEdit)
                  && JsonNode.DeepEquals(Object(editedHome, claudeFile), withoutLine) && Data(editedHome, script) is null,
                  "A Codex edit overwrote the edit, touched more than the status line, or left the bridge named");
            var restoreBackups = BackupFiles(editedHome, "claude-settings-before-statusline-restore-");
            check(restoreBackups.Count == 1 && Same(Data(editedHome, restoreBackups[0]), connectedClaude),
                  "The settings were not backed up privately before the status line was put back");
            Put(editedHome, codexFile, connectedCodex);
            editedSetup.Disconnect();
            check(Same(Data(editedHome, codexFile), Bytes(originalCodex)) && Same(Data(editedHome, claudeFile), Bytes(originalClaude)),
                  "After the Codex edit was undone, disconnect did not restore both exact originals");

            // The usual case: both clients rewrote their files after the connection (a Codex trust level, a Claude plugin).
            // Only TokenCat's lines and keys go, every later change stays, a content-logging switch gets its value back, and
            // the edited bytes are backed up first.
            const string plainCodex = "model = \"existing-model\"\n", trust = "\n[projects.\"/work/sample\"]\ntrust_level = \"trusted\"\n";
            var keyHome = Fixture("key-level", plainCodex, originalClaude);
            Setup(keyHome).Connect();
            Put(keyHome, codexFile, [.. Data(keyHome, codexFile)!, .. Bytes(trust)]);
            var keySettings = Object(keyHome, claudeFile)!;
            keySettings["enabledPlugins"] = new JsonObject { ["sample@market"] = true };
            Put(keyHome, claudeFile, Bytes(keySettings.ToJsonString()));
            var keyResult = Setup(keyHome).Disconnect();
            var originalEnv = Json.ParseNode(Bytes(originalClaude))!["env"];
            check(keyResult.ChangedFiles.Count == 2 && keyResult.Message.Contains("연결 후 바뀐 다른 설정은 그대로 두었습니다")
                  && Same(Data(keyHome, codexFile), Bytes(plainCodex + trust)) && JsonNode.DeepEquals(Object(keyHome, claudeFile)?["env"], originalEnv)
                  && Object(keyHome, claudeFile)?["enabledPlugins"] is not null && StatusLine(keyHome) is null
                  && Data(keyHome, manifestFile) is null && Data(keyHome, script) is null && BackupFiles(keyHome, "before-disconnect-").Count == 2,
                  "Disconnecting edited files did not take out exactly TokenCat's lines and keys, or did not back them up first");
            // A TokenCat key the person set to another value refuses the restore; only the status line TokenCat added goes.
            var refusedHome = Fixture("key-level-refused", plainCodex, originalClaude);
            Setup(refusedHome).Connect();
            var refusedCodex = Data(refusedHome, codexFile);
            var refusedSettings = Object(refusedHome, claudeFile)!;
            refusedSettings["env"]!["OTEL_LOGS_EXPORTER"] = "none";
            Put(refusedHome, claudeFile, Bytes(refusedSettings.ToJsonString()));
            var keyRefusal = Refusal(() => Setup(refusedHome).Disconnect());
            check(keyRefusal.StartsWith("연결 후 Claude Code 설정이 수정돼", StringComparison.Ordinal) && Same(Data(refusedHome, codexFile), refusedCodex)
                  && Text(Object(refusedHome, claudeFile)?["env"]?["OTEL_LOGS_EXPORTER"]) == "none"
                  && StatusLine(refusedHome) is null && Data(refusedHome, manifestFile) is not null,
                  "A TokenCat key the person changed was reverted, or the refusal touched more than the status line");
            // A key repeated after the connection: Claude Code reads the last copy, so the restore is refused and the file stays.
            var repeatedHome = Fixture("key-level-repeated", plainCodex, originalClaude);
            Setup(repeatedHome).Connect();
            byte[] twice = [.. Data(repeatedHome, claudeFile)![..^2], .. Bytes(""","env":{"ANTHROPIC_BASE_URL":"http://in-use"}}""")];
            Put(repeatedHome, claudeFile, twice);
            check(Refusal(() => Setup(repeatedHome).Disconnect()).StartsWith("연결 후 Claude Code 설정이 수정돼", StringComparison.Ordinal)
                  && Same(Data(repeatedHome, claudeFile), twice),
                  "Disconnecting a settings.json with a repeated key rewrote it to JSONSerialization's choice");
            // An edited file whose status line could not go back still runs the bridge: the connection record stays for
            // another try instead of being deleted under it. (Swift breaks the record; here the settings write is refused.)
            var stuckHome = Fixture("key-level-stuck", plainCodex, originalClaude);
            Setup(stuckHome).Connect();
            var stuckBytes = Data(stuckHome, claudeFile)!;
            Put(stuckHome, claudeFile, [.. stuckBytes[..^2], .. Bytes(""","theme":"dark"}""")]);
            string stuck;
            var unblock = BlockWrites(Path.Combine(stuckHome, claudeFile));
            try { stuck = Refusal(() => Setup(stuckHome).Disconnect()); }
            finally { unblock(); }
            check(stuck.Contains("상태 표시줄은 되돌리지 못했습니다") && Text(StatusLine(stuckHome)?["command"]) == Setup(stuckHome).StatusLineCommand
                  && Data(stuckHome, manifestFile) is not null && Data(stuckHome, script) is not null,
                  "A status line that could not go back lost its connection record");
            // English: the refused client starts the sentence and the status line sentence follows it.
            var englishHome = Fixture("user-edit-en", originalCodex, originalClaude);
            Setup(englishHome).Connect();
            Put(englishHome, codexFile, [.. Data(englishHome, codexFile)!, .. Bytes(trust)]);
            var englishRefusal = Lang.With(AppLanguage.En, () => Refusal(() => Setup(englishHome).Disconnect()));
            check(englishRefusal == "Codex settings changed after the connection, and TokenCat's entries can't be reverted on their own."
                  + " Nothing was restored automatically, to keep your changes. Removed the Claude Code status line TokenCat added."
                  && Lang.With(AppLanguage.En, () => TelemetrySetupNote.StatusLineSkipped.Text)
                      == "Claude Code's statusLine isn't in the expected format, so the usage limit connection was skipped.",
                  "English disconnect refusal or status line note changed");

            var failedHome = Fixture("write-failure", originalCodex, originalClaude);
            bool didFail;
            unblock = BlockWrites(Path.Combine(failedHome, claudeFile));
            try { didFail = Rejected(() => Setup(failedHome).Connect()); }
            finally { unblock(); }
            check(didFail && Same(Data(failedHome, codexFile), Bytes(originalCodex)) && Same(Data(failedHome, claudeFile), Bytes(originalClaude)),
                  "Real second-file write failure did not roll back the first configuration");
            check(Data(failedHome, script) is null, "A rolled-back connection left an unreferenced status line bridge");

            const string multilineCodex = "policy = '''\n[otel]\nnot_a_real_table = true\n'''\n[features]\ncustom_feature = true\n";
            var multilineHome = Fixture("multiline", multilineCodex, "{}");
            Setup(multilineHome).Connect();
            var multilineAfter = Encoding.UTF8.GetString(Data(multilineHome, codexFile)!);
            check(multilineAfter.StartsWith(multilineCodex, StringComparison.Ordinal) && multilineAfter.Contains("\n[otel]\nexporter ="),
                  "TOML multiline string contents were mistaken for a telemetry table");
            var crlfHome = Fixture("crlf", originalCodex.Replace("\n", "\r\n"), "{}");
            Setup(crlfHome).Connect();
            check(!Encoding.UTF8.GetString(Data(crlfHome, codexFile)!).Replace("\r\n", "").Contains('\n'), "Codex CRLF line endings were normalized");
            // Windows editors and PowerShell 5.1 write a UTF-8 BOM (rule 9): a first-line [otel] is still that table, the BOM stays,
            // Korean text is written as is, and disconnect gives back the exact bytes.
            var bomCodex = "\uFEFF[otel]\nexporter = \"none\"\n";
            var bomClaude = "\uFEFF{\"env\":{\"USER_NAME\":\"홍길동\"}}";
            var bomHome = Fixture("bom", bomCodex, bomClaude);
            Setup(bomHome).Connect();
            var bomAfter = Encoding.UTF8.GetString(Data(bomHome, codexFile)!);
            var bomSettings = Encoding.UTF8.GetString(Data(bomHome, claudeFile)!);
            var bomRestored = Setup(bomHome).Disconnect();
            check(bomAfter.StartsWith("\uFEFF[otel]\nexporter = { otlp-http", StringComparison.Ordinal) && bomAfter.Split("[otel]").Length == 2
                  && bomSettings.Contains("\"USER_NAME\": \"홍길동\"") && bomRestored.ChangedFiles.Count == 2
                  && Same(Data(bomHome, codexFile), Bytes(bomCodex)) && Same(Data(bomHome, claudeFile), Bytes(bomClaude)),
                  "A UTF-8 BOM hid a first-line [otel] table or was dropped, or Korean text was escaped");

            // Windows v1 keeps an existing status line (it can't re-run it in the shell Claude Code picked; open question 2).
            const string originalCommand = "/bin/sh \"$HOME/.claude/statusline-ccusage.sh\"";
            const string lineClaude = """{"statusLine":{"type":"command","command":"/bin/sh \"$HOME/.claude/statusline-ccusage.sh\"","padding":0},"theme":"dark"}""";
            var lineHome = Fixture("statusline", originalCodex, lineClaude);
            var lineSetup = Setup(lineHome);
            var lineResult = lineSetup.Connect();
            var kept = StatusLine(lineHome);
            check(Text(kept?["command"]) == originalCommand && kept?["padding"]?.GetValue<int>() == 0 && Text(kept?["type"]) == "command"
                  && Text(Object(lineHome, claudeFile)?["theme"]) == "dark" && lineResult.RestartRequired.SequenceEqual([TokenSource.Codex, TokenSource.Claude])
                  && !lineResult.Bridged && lineResult.Notes.SequenceEqual([TelemetrySetupNote.StatusLineKept])
                  && lineResult.Message.Contains("Claude Code 상태 표시줄을 그대로 두었습니다"),
                  "An existing status line was changed, or the connection did not say it was kept");
            check(Data(lineHome, script) is null && Object(lineHome, manifestFile)?["statusLine"] is null,
                  "A kept status line got a bridge script or a bridge record");
            var bridge = TelemetrySetup.StatusLineScript();
            check(bridge.Contains($"ConnectAsync('127.0.0.1', {TelemetrySetup.Port}).Wait(300)") && bridge.Contains("POST /v1/claude/status HTTP/1.1")
                  && bridge.Contains("[Console]::OpenStandardInput().CopyTo(") && !bridge.Contains("Write-Output") && !bridge.Contains("Origin")
                  && bridge.All(char.IsAscii) && TelemetrySetup.StatusLineScript(40_001).Contains("'127.0.0.1', 40001")
                  && lineSetup.StatusLineCommand == $"powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{Path.GetFullPath(Path.Combine(lineHome, script)).Replace('\\', '/')}\""
                  && TelemetrySetup.RunsBridge(lineSetup.StatusLineCommand) && TelemetrySetup.RunsBridge(@"powershell -File C:\Users\me\AppData\Local\TokenCat\claude-statusline.ps1")
                  && !TelemetrySetup.RunsBridge("powershell -File C:/Users/me/claude-statusline.ps1"),
                  "Bridge script lost its loopback-only, detached forwarding");
            var lineBytes = Data(lineHome, claudeFile);
            var lineAgain = lineSetup.Connect();
            check(lineAgain.ChangedFiles.Count == 0 && Same(Data(lineHome, claudeFile), lineBytes) && lineAgain.Notes.SequenceEqual([TelemetrySetupNote.StatusLineKept]),
                  "Repeated connection wrapped the bridge again or replaced its original command");
            lineSetup.Disconnect();
            check(Same(Data(lineHome, claudeFile), Bytes(lineClaude)) && Data(lineHome, script) is null,
                  "Disconnect did not restore the exact status line or left the bridge behind");

            // An unexpected shape is left alone with a note; the OTLP connection itself still applies.
            string[] oddLines = ["""{"statusLine":"echo hi"}""", """{"statusLine":{"type":"static","text":"hi"}}""",
                """{"statusLine":{"type":"command","command":" "}}""", """{"statusLine":null}"""];
            for (var index = 0; index < oddLines.Length; index++)
            {
                var oddHome = Fixture($"statusline-odd-{index}", originalCodex, oddLines[index]);
                var oddResult = Setup(oddHome).Connect();
                var after = Object(oddHome, claudeFile);
                check(oddResult.Notes.SequenceEqual([TelemetrySetupNote.StatusLineKept]) && !oddResult.Bridged
                      && Text(after?["env"]?["OTEL_LOGS_EXPORTER"]) == "otlp" && after is not null && after.ContainsKey("statusLine")
                      && JsonNode.DeepEquals(after["statusLine"], Json.ParseNode(Bytes(oddLines[index]))!["statusLine"]) && Data(oddHome, script) is null,
                      "An unexpected status line shape was changed or blocked the connection");
            }

            // A status line the person set after the bridge is theirs: it stays, and only TokenCat's env goes.
            const string themeClaude = """{"theme":"dark"}""";
            var changedHome = Fixture("statusline-user", originalCodex, themeClaude);
            var changedSetup = Setup(changedHome);
            changedSetup.Connect();
            var changedSettings = Object(changedHome, claudeFile)!;
            changedSettings["statusLine"] = new JsonObject { ["type"] = "command", ["command"] = "echo mine" };
            Put(changedHome, claudeFile, Bytes(changedSettings.ToJsonString()));
            var changedResult = changedSetup.Disconnect();
            check(changedResult.Message.Contains("상태 표시줄도 지금 설정 그대로 두었습니다") && Text(StatusLine(changedHome)?["command"]) == "echo mine"
                  && Object(changedHome, claudeFile)?["env"] is null && Text(Object(changedHome, claudeFile)?["theme"]) == "dark"
                  && Same(Data(changedHome, codexFile), Bytes(originalCodex)) && Data(changedHome, script) is null,
                  "A status line changed by the person was restored over, TokenCat's env stayed, or the change was not reported");
            // A connected status line TokenCat added, then the settings were rewritten by Claude Code (its own formatting, a new key,
            // 0.1): only the statusLine member is cut from the text (backed up first), then TokenCat's env goes with every other
            // key kept, and the bridge is removed.
            var ownHome = Fixture("statusline-own", originalCodex, themeClaude);
            var ownSetup = Setup(ownHome);
            ownSetup.Connect();
            var rewritten = Object(ownHome, claudeFile)!;
            rewritten["enabledPlugins"] = new JsonObject { ["sample@market"] = true };
            var claudeEdit = JavaScriptStyle(rewritten, "  \"someFloat\": 0.1,\n");
            Put(ownHome, claudeFile, claudeEdit);
            var ownResult = ownSetup.Disconnect();
            rewritten.Remove("statusLine");
            var putBack = JavaScriptStyle(rewritten, "  \"someFloat\": 0.1,\n");
            var ownBackup = BackupFiles(ownHome, "before-disconnect-");
            var ownAfter = Object(ownHome, claudeFile);
            check(ownResult.Message.Contains("TokenCat이 추가한 Claude Code 상태 표시줄은 지웠습니다")
                  && ownResult.RestartRequired.SequenceEqual([TokenSource.Codex, TokenSource.Claude])
                  && ownBackup.Count == 1 && Same(Data(ownHome, ownBackup[0]), putBack) && StatusLine(ownHome) is null
                  && ownAfter?["env"] is null && ownAfter?["enabledPlugins"] is not null && ownAfter?["someFloat"]?.GetValue<double>() == 0.1
                  && Encoding.UTF8.GetString(Data(ownHome, claudeFile)!).Contains("\"someFloat\": 0.1,")
                  && Same(Data(ownHome, codexFile), Bytes(originalCodex)) && Data(ownHome, script) is null,
                  "An edited file kept TokenCat's env or the bridge, lost a key the client added, or the status line step was not exact");

            // Settings naming the bridge with no record here (copied from another PC, or the support folder deleted): kept as they
            // are, the script is written again, and no note (Windows v1 only bridges an absent status line, so nothing was lost).
            var sourceHome = Fixture("statusline-source", originalCodex, themeClaude);
            Setup(sourceHome).Connect();
            var syncedHome = Fixture("statusline-synced", Encoding.UTF8.GetString(Data(sourceHome, codexFile)!), Encoding.UTF8.GetString(Data(sourceHome, claudeFile)!));
            var syncedBytes = Data(syncedHome, claudeFile);
            var synced = new TelemetrySetup(syncedHome, Path.Combine(sourceHome, support)).Connect();
            check(synced.ChangedFiles.Count == 0 && synced.Bridged && synced.Notes.Count == 0 && Same(Data(syncedHome, claudeFile), syncedBytes)
                  && Data(sourceHome, script) is not null,
                  "Settings naming the bridge without a record here were changed or did not get the script");
            const string spelled = """{"statusLine":{"type":"command","command":"powershell -File C:\\Users\\sample\\AppData\\Local\\TokenCat\\claude-statusline.ps1"}}""";
            var spelledHome = Fixture("statusline-spelled", originalCodex, spelled);
            var spelledResult = Setup(spelledHome).Connect();
            check(Text(StatusLine(spelledHome)?["command"]) == @"powershell -File C:\Users\sample\AppData\Local\TokenCat\claude-statusline.ps1"
                  && spelledResult.Bridged && spelledResult.Notes.Count == 0 && Object(spelledHome, manifestFile)?["statusLine"] is null,
                  "Another spelling of the bridge was wrapped as its own original");

            // A connection whose status line was kept, later removed by the person (the Windows counterpart of the mac's 0.8.0
            // connections): the next connect adds only the bridge, recorded with the same backups.
            string Legacy(string name, bool claudeEntry = true)
            {
                var legacyHome = Fixture(name, originalCodex, lineClaude);
                Setup(legacyHome).Connect();
                var settings = Object(legacyHome, claudeFile)!;
                settings.Remove("statusLine");
                var envOnly = Json.Write(settings);
                Put(legacyHome, claudeFile, envOnly);
                var manifest = Object(legacyHome, manifestFile)!;
                var entries = manifest["entries"]!.AsArray();
                var folder = Path.Combine(legacyHome, support, "telemetry-backups", Text(manifest["backupDirectory"])!);
                foreach (var entry in entries.OfType<JsonObject>().Where(entry => Text(entry["source"]) == "claude").ToList())
                {
                    if (claudeEntry) entry["connectedSHA256"] = Convert.ToHexStringLower(SHA256.HashData(envOnly));
                    else entries.Remove(entry);
                }
                if (!claudeEntry) File.Delete(Path.Combine(folder, "claude-settings.json"));
                Put(legacyHome, manifestFile, Bytes(manifest.ToJsonString()));
                File.WriteAllBytes(Path.Combine(folder, "manifest.json"), Bytes(manifest.ToJsonString()));
                return legacyHome;
            }
            var oldHome = Legacy("legacy");
            var migrated = Setup(oldHome).Connect();
            check(migrated.ChangedFiles.SequenceEqual([Path.Combine(oldHome, ".claude", "settings.json")]) && migrated.RestartRequired.Count == 0 && migrated.Bridged
                  && Text(StatusLine(oldHome)?["command"]) == Setup(oldHome).StatusLineCommand && Data(oldHome, script) is not null
                  && !Same(Data(oldHome, codexFile), Bytes(originalCodex))
                  && Text(Object(oldHome, manifestFile)?["statusLine"]?["preBridgeSHA256"]) is not null,
                  "An existing connection did not get the status line bridge with its record");
            var migratedBytes = Data(oldHome, claudeFile);
            var migratedAgain = Setup(oldHome).Connect();
            check(migratedAgain.ChangedFiles.Count == 0 && Same(Data(oldHome, claudeFile), migratedBytes), "The migration was not idempotent");
            Setup(oldHome).Disconnect();
            check(Same(Data(oldHome, claudeFile), Bytes(lineClaude)) && Same(Data(oldHome, codexFile), Bytes(originalCodex)) && Data(oldHome, script) is null,
                  "A migrated connection did not restore the exact pre-connection settings and status line");
            // Edited after the connection: the bridge step backs the file up as it is; disconnect puts those exact pre-bridge
            // bytes back, then takes out TokenCat's env.
            var editedOldHome = Legacy("legacy-edited");
            var edited = Object(editedOldHome, claudeFile)!;
            edited["theme"] = "light";
            var editedBytes = JavaScriptStyle(edited, "  \"someFloat\": 0.1,\n");
            Put(editedOldHome, claudeFile, editedBytes);
            Setup(editedOldHome).Connect();
            var backupFolder = Text(Object(editedOldHome, manifestFile)?["backupDirectory"]) ?? "";
            var editedPreBridge = Data(editedOldHome, $"{support}/telemetry-backups/{backupFolder}/{TelemetrySetup.PreBridgeBackupName}");
            check(Text(StatusLine(editedOldHome)?["command"]) == Setup(editedOldHome).StatusLineCommand && Same(editedPreBridge, editedBytes),
                  "The bridge step on an edited file did not back it up first");
            var oldResult = Setup(editedOldHome).Disconnect();
            var oldBackup = BackupFiles(editedOldHome, "before-disconnect-");
            check(oldResult.Message.Contains("TokenCat이 추가한 Claude Code 상태 표시줄은 지웠습니다") && oldBackup.Count == 1
                  && Same(Data(editedOldHome, oldBackup[0]), editedBytes) && Object(editedOldHome, claudeFile)?["env"] is null
                  && Text(Object(editedOldHome, claudeFile)?["theme"]) == "light" && StatusLine(editedOldHome) is null && Data(editedOldHome, script) is null,
                  "An edited 0.8.0 connection did not get its exact pre-bridge settings back first, kept TokenCat's env, or kept the bridge");
            // Without a Claude entry (its env was already there), the pre-bridge file becomes the entry's exact backup.
            var entrylessHome = Legacy("legacy-entryless", claudeEntry: false);
            var preBridge = Data(entrylessHome, claudeFile);
            Setup(entrylessHome).Connect();
            Setup(entrylessHome).Disconnect();
            check(Same(Data(entrylessHome, claudeFile), preBridge) && Same(Data(entrylessHome, codexFile), Bytes(originalCodex)) && Data(entrylessHome, script) is null,
                  "A connection without a Claude entry did not restore its pre-bridge settings");
            // Any other change since the connection keeps the existing refusal.
            var driftedHome = Legacy("legacy-drifted");
            var drifted = Object(driftedHome, claudeFile)!;
            drifted["env"]!.AsObject().Remove("OTEL_LOGS_EXPORTER");
            var driftedBytes = Bytes(drifted.ToJsonString());
            Put(driftedHome, claudeFile, driftedBytes);
            check(Rejected(() => Setup(driftedHome).Connect()) && Same(Data(driftedHome, claudeFile), driftedBytes) && Data(driftedHome, script) is null,
                  "A connection changed in another way was migrated or overwritten");

            // Gemini CLI and Qwen Code: connected while their folder exists, every other key kept, skipped (never aborting) on a refusal.
            const string geminiFile = ".gemini/settings.json", qwenFile = ".qwen/settings.json";
            const string geminiOriginal = """{"theme":"Dracula","telemetry":{"logPrompts":true,"useCollector":false}}""";
            string ClientHome(string name, string? gemini, bool qwenFolder = true)
            {
                var clientHome = Fixture(name);
                if (gemini is not null)
                {
                    Directory.CreateDirectory(Path.Combine(clientHome, ".gemini"));
                    Put(clientHome, geminiFile, Bytes(gemini));
                }
                if (qwenFolder) Directory.CreateDirectory(Path.Combine(clientHome, ".qwen"));
                return clientHome;
            }
            static bool Connected(JsonObject? settings) => settings?["telemetry"] is JsonObject telemetry
                && telemetry["enabled"]?.GetValue<bool>() == true && Text(telemetry["target"]) == "local" && Text(telemetry["otlpEndpoint"]) == "http://127.0.0.1:16493"
                && Text(telemetry["otlpProtocol"]) == "http" && telemetry["logPrompts"]?.GetValue<bool>() == false;
            static bool Skipped(TelemetrySetupResult result, TokenSource source) =>
                result.Notes.OfType<TelemetrySetupNote.ClientSkipped>().Any(note => note.Source == source);
            var clientsHome = ClientHome("gemini-qwen", geminiOriginal);
            var clientsSetup = Setup(clientsHome);
            var clientsResult = clientsSetup.Connect();
            var geminiAfter = Object(clientsHome, geminiFile);
            var qwenAfter = Object(clientsHome, qwenFile);
            check(Connected(geminiAfter) && Text(geminiAfter?["theme"]) == "Dracula" && geminiAfter?["telemetry"]?["useCollector"]?.GetValue<bool>() == false
                  && Connected(qwenAfter) && qwenAfter?.Count == 1 && clientsResult.Notes.Count == 0
                  && clientsResult.RestartRequired.Contains(TokenSource.Gemini) && clientsResult.RestartRequired.Contains(TokenSource.Qwen),
                  "Gemini CLI / Qwen Code settings were not connected with their other keys kept, or did not ask for a restart");
            // The mac creates the Qwen Code file with mode 0600; Windows inherits the folder's ACL.
            c.Skip();
            check(clientsSetup.Connect().ChangedFiles.Count == 0, "A repeated connection changed Gemini CLI or Qwen Code settings again");
            clientsSetup.Disconnect();
            check(Same(Data(clientsHome, geminiFile), Bytes(geminiOriginal)) && Data(clientsHome, qwenFile) is null,
                  "Disconnecting did not restore the exact Gemini CLI settings or remove the created Qwen Code file");

            var editedClientHome = ClientHome("gemini-edited", geminiOriginal, qwenFolder: false);
            Setup(editedClientHome).Connect();
            var editedGemini = Object(editedClientHome, geminiFile)!;
            editedGemini["model"] = new JsonObject { ["name"] = "x" };
            Put(editedClientHome, geminiFile, Json.Write(editedGemini));
            Setup(editedClientHome).Disconnect();
            var revertedGemini = Object(editedClientHome, geminiFile);
            check(Text(revertedGemini?["model"]?["name"]) == "x" && Text(revertedGemini?["theme"]) == "Dracula"
                  && revertedGemini?["telemetry"] is JsonObject revertedTelemetry && revertedTelemetry.Count == 2
                  && revertedTelemetry["logPrompts"]?.GetValue<bool>() == true && revertedTelemetry["useCollector"]?.GetValue<bool>() == false,
                  "Disconnecting edited Gemini CLI settings lost the edit or kept TokenCat's telemetry keys");

            var absentHome = ClientHome("gemini-absent", null, qwenFolder: false);
            check(!Setup(absentHome).Connect().RestartRequired.Contains(TokenSource.Gemini) && !Directory.Exists(Path.Combine(absentHome, ".gemini"))
                  && !Directory.Exists(Path.Combine(absentHome, ".qwen")),
                  "Gemini CLI or Qwen Code settings were created without their folder");

            const string collectorGemini = """{"telemetry":{"enabled":true,"otlpEndpoint":"http://collector.example:4317"}}""";
            var collectorHome = ClientHome("gemini-collector", collectorGemini, qwenFolder: false);
            var collectorResult = Setup(collectorHome).Connect();
            check(Data(collectorHome, codexFile) is not null && Data(collectorHome, claudeFile) is not null
                  && Same(Data(collectorHome, geminiFile), Bytes(collectorGemini)) && Skipped(collectorResult, TokenSource.Gemini)
                  && !collectorResult.RestartRequired.Contains(TokenSource.Gemini) && collectorResult.Message.Contains("Gemini CLI 설정은 건너뛰었습니다: "),
                  "A Gemini CLI collector of its own was overwritten, or it stopped Codex and Claude Code from connecting");
            check(Lang.With(AppLanguage.En, () => new TelemetrySetupNote.ClientSkipped(TokenSource.Qwen, "Reason.").Text) == "Skipped Qwen Code: Reason.",
                  "English skipped-client note changed");
            var badGeminiHome = ClientHome("gemini-invalid", "{ bad", qwenFolder: false);
            check(Skipped(Setup(badGeminiHome).Connect(), TokenSource.Gemini) && Same(Data(badGeminiHome, geminiFile), Bytes("{ bad")),
                  "Unparseable Gemini CLI settings were changed or not reported as skipped");

            // Connected while ~/.gemini was absent; a later connection adds it to the same manifest, and disconnecting restores all three.
            var lateHome = ClientHome("gemini-late", null, qwenFolder: false);
            Setup(lateHome).Connect();
            Directory.CreateDirectory(Path.Combine(lateHome, ".gemini"));
            Put(lateHome, geminiFile, Bytes(geminiOriginal));
            var lateResult = Setup(lateHome).Connect();
            check(lateResult.RestartRequired.SequenceEqual([TokenSource.Gemini]) && lateResult.ChangedFiles.Count == 1 && Connected(Object(lateHome, geminiFile))
                  && Object(lateHome, manifestFile)?["entries"] is JsonArray lateEntries && lateEntries.Count == 3
                  && lateEntries.Any(entry => Text(entry?["source"]) == "gemini"),
                  "A Gemini CLI folder created after the connection was not added to it");
            Setup(lateHome).Disconnect();
            check(Same(Data(lateHome, geminiFile), Bytes(geminiOriginal)) && Data(lateHome, codexFile) is null && Data(lateHome, claudeFile) is null
                  && Data(lateHome, manifestFile) is null,
                  "Disconnecting did not restore the added Gemini CLI settings with Codex and Claude Code");

            // Edited after the connection in a way that needs writing again: skipped, never overwritten, never blocking the rest.
            var driftHome = ClientHome("gemini-drift", geminiOriginal, qwenFolder: false);
            Setup(driftHome).Connect();
            var driftGemini = Object(driftHome, geminiFile)!;
            driftGemini["telemetry"]!["logPrompts"] = true;
            var driftBytes = Json.Write(driftGemini);
            Put(driftHome, geminiFile, driftBytes);
            var driftResult = Setup(driftHome).Connect();
            check(Skipped(driftResult, TokenSource.Gemini) && Same(Data(driftHome, geminiFile), driftBytes) && driftResult.ChangedFiles.Count == 0,
                  "Gemini CLI settings edited after the connection were overwritten or blocked the connection");
        }
        catch (Exception error) { check(false, $"Telemetry setup fixture failed: {error.Message}"); }
        finally { root.Delete(true); }
        return c.Done();
    }

    /// A real write failure on `file` while it stays readable: Windows refuses File.Replace on a file held open without
    /// write/delete sharing; elsewhere the folder loses its write bit. Returns the undo.
    static Action BlockWrites(string file)
    {
        if (OperatingSystem.IsWindows()) return new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read).Dispose;
        var folder = Path.GetDirectoryName(file)!;
        SetWritable(folder, false);
        return () => SetWritable(folder, true);
    }

    static void SetWritable(string folder, bool writable)
    {
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(folder, UnixFileMode.UserRead | UnixFileMode.UserExecute | (writable ? UnixFileMode.UserWrite : UnixFileMode.None));
    }
}
