using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using static TokenCat.Lang;
using static TokenCat.TokenSource;

namespace TokenCat;

// TelemetrySetup.swift (DESIGN §7.4). Windows v1 differences: backups and the bridge live in `supportDirectory`; the bridge is
// a PowerShell script added only when settings have no `statusLine` (an existing one is kept, note `StatusLineKept`), so
// there is never an original command to run or record; POSIX modes are not applied (the manifest keeps the field).

public sealed record TelemetrySetupResult(IReadOnlyList<string> ChangedFiles, IReadOnlyList<TokenSource> RestartRequired, string Message)
{
    /// What the CLI message says about the Claude Code status line, for the app to show without reading the message.
    public IReadOnlyList<TelemetrySetupNote> Notes { get; init; } = [];
    /// Claude Code settings run the status line bridge after this call.
    public bool Bridged { get; init; }
}

/// Swift's three notes plus `StatusLineKept` (Windows v1 keeps an existing statusLine untouched, §7.4).
public enum TelemetrySetupNote { StatusLineSkipped, OriginalUnknown, OriginalRecreated, StatusLineKept }

public static class TelemetrySetupNoteText
{
    extension(TelemetrySetupNote note)
    {
        /// The sentence the CLI message carries.
        public string Text => note switch
        {
            TelemetrySetupNote.StatusLineSkipped => Loc("Claude Code statusLine 형식이 예상과 달라 사용량 한도 연결은 건너뛰었습니다.",
                "Claude Code's statusLine isn't in the expected format, so the usage limit connection was skipped."),
            TelemetrySetupNote.OriginalUnknown => Loc("Claude Code 상태 표시줄이 TokenCat 브리지를 가리키지만 원래 명령을 찾을 수 없어 상태 표시줄이 비어 보입니다. settings.json의 statusLine을 직접 고쳐 주세요.",
                "The Claude Code status line runs the TokenCat bridge, but its original command can't be found, so the status line shows nothing. Edit statusLine in settings.json to fix it."),
            TelemetrySetupNote.OriginalRecreated => Loc("Claude Code 상태 표시줄의 원래 명령을 백업 기록에서 다시 만들었습니다.",
                "Recreated the Claude Code status line's original command from the backup record."),
            _ => Loc("Claude Code 상태 표시줄을 그대로 두었습니다. 사용 한도는 Claude 데스크톱 앱 기록에서 읽습니다.",
                "Kept your Claude Code status line; usage limits come from the Claude desktop app's history."),
        };
    }
}

/// What the UI says about a failed automatic connection, without reading message text.
public abstract record TelemetrySetupFailure
{
    public sealed record Conflict : TelemetrySetupFailure;
    public sealed record Invalid : TelemetrySetupFailure;
    public sealed record Unavailable : TelemetrySetupFailure;
    public sealed record WriteFailed(bool Restored) : TelemetrySetupFailure;
}

/// Swift's TelemetrySetupError: the reason (conflict/invalid) or the write-failure text as Message.
public sealed class TelemetrySetupError(TelemetrySetupFailure failure, string message) : Exception(message)
{
    public TelemetrySetupFailure Failure { get; } = failure;
}

/// Owns only the opt-in, loopback telemetry settings. It does not restart either client.
public sealed class TelemetrySetup
{
    public const int Port = TelemetryCollector.DefaultPort;
    /// Set by `--disconnect-telemetry` (even when it refuses) and cleared by `--connect-telemetry`; the app does not
    /// connect automatically while it is set.
    public const string OptOutKey = "telemetryDisconnected";
    public const string StatusLineScriptName = "claude-statusline.ps1";
    /// The Claude Code settings right before the bridge was added to an existing connection.
    public const string PreBridgeBackupName = "claude-settings-before-statusline.json";

    /// The Claude Code env values TokenCat sets. Disconnecting an edited file reverts only keys that still hold them.
    static readonly Dictionary<string, string> ClaudeEnv = new()
    {
        ["CLAUDE_CODE_ENABLE_TELEMETRY"] = "1", ["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"] = "1",
        ["OTEL_LOGS_EXPORTER"] = "otlp", ["OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"] = "http/json",
        ["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] = $"{Endpoint}/v1/logs", ["OTEL_LOGS_EXPORT_INTERVAL"] = "1000",
        ["OTEL_TRACES_EXPORTER"] = "otlp", ["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"] = "http/json",
        ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = $"{Endpoint}/v1/traces", ["OTEL_TRACES_EXPORT_INTERVAL"] = "1000",
    };
    const string Endpoint = "http://127.0.0.1:16493";
    /// Content-logging switches; TokenCat sets an enabled one to "0".
    static readonly string[] ClaudeLogKeys = ["OTEL_LOG_USER_PROMPTS", "OTEL_LOG_ASSISTANT_RESPONSES", "OTEL_LOG_TOOL_DETAILS",
        "OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_RAW_API_BODIES"];
    /// The Codex `[otel]` exporters TokenCat writes, in the order it appends them.
    static readonly (string Key, string Value)[] CodexExporters = [.. new[] { ("exporter", "logs"), ("metrics_exporter", "metrics"), ("trace_exporter", "traces") }
        .Select(pair => (pair.Item1, $"{{ otlp-http = {{ endpoint = \"{Endpoint}/v1/{pair.Item2}\", protocol = \"json\" }} }}"))];
    /// POSIX mode recorded in the manifest (format parity with the mac); not applied on Windows, where %LOCALAPPDATA% is private.
    const int Permissions = 384;
    static readonly Lock MutationLock = new();
    static readonly UTF8Encoding StrictUtf8 = new(false, true);
    static readonly JsonSerializerOptions ManifestOptions = new(Json.Options) { RespectRequiredConstructorParameters = true, RespectNullableAnnotations = true };

    readonly string home, support;

    public TelemetrySetup(string home, string supportDirectory)
    {
        this.home = home;
        support = Path.GetFullPath(supportDirectory);
        StatusLineCommand = $"powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{BridgeScript.Replace('\\', '/')}\"";
    }

    /// Claude Code runs this through Git Bash when installed, else PowerShell: one unquoted first token and an absolute
    /// forward-slash path work in both (DESIGN §2.3). The script lives only in this PC's support folder.
    public string StatusLineCommand { get; }

    /// Any spelling of a command that runs the bridge script: never replaced, and the script stays while one names it.
    public static bool RunsBridge(string command) =>
        command.Replace('\\', '/').Contains("/TokenCat/" + StatusLineScriptName, StringComparison.OrdinalIgnoreCase);

    /// Sends Claude Code's status JSON as raw bytes to 127.0.0.1 only and prints nothing (an absent original prints nothing
    /// either). ASCII only: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page. The 300 ms connect cap
    /// matters: Windows retries a refused loopback SYN for about 2 s. `port` lets the Windows check use a free test port.
    public static string StatusLineScript(int port = Port) => $$"""
        # TokenCat: Claude Code status line bridge. Sends Claude Code's status JSON to TokenCat on 127.0.0.1 only and prints nothing.
        # TokenCat --disconnect-telemetry removes it from settings.json.
        $ErrorActionPreference = 'SilentlyContinue'
        $buffer = New-Object IO.MemoryStream; [Console]::OpenStandardInput().CopyTo($buffer); $body = $buffer.ToArray()
        $client = New-Object Net.Sockets.TcpClient
        if ($client.ConnectAsync('127.0.0.1', {{port}}).Wait(300)) {
          $stream = $client.GetStream(); $stream.ReadTimeout = 1000
          $head = [Text.Encoding]::ASCII.GetBytes("POST {{TelemetryHttp.ClaudeStatusPath}} HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
          $stream.Write($head, 0, $head.Length); $stream.Write($body, 0, $body.Length); [void]$stream.Read((New-Object byte[] 64), 0, 64)
        }
        $client.Close()

        """;

    string ActiveManifest => Path.Combine(support, "telemetry-connection.json");
    string BridgeScript => Path.Combine(support, StatusLineScriptName);
    // Telemetry setup covers `TokenSource.TelemetryClients` (Codex, Claude Code) only.
    string ConfigPath(TokenSource source) => source switch
    {
        Codex => AppPaths.CodexConfig(home),
        Claude => AppPaths.ClaudeSettings(home),
        _ => throw new ArgumentOutOfRangeException(nameof(source)),
    };
    string BackupDirectory(Manifest manifest) => Path.Combine(support, "telemetry-backups", manifest.BackupDirectory);
    static string BackupPath(TokenSource source, string directory) => Path.Combine(directory, source switch
    {
        Codex => "codex-config.toml",
        Claude => "claude-settings.json",
        _ => throw new ArgumentOutOfRangeException(nameof(source)),
    });

    sealed record Change(TokenSource Source, string Path, byte[]? Original, byte[] Replacement);

    sealed record Manifest(int Version, string BackupDirectory, IReadOnlyList<ManifestEntry> Entries, ManifestStatusLine? StatusLine = null);

    sealed record ManifestEntry(TokenSource Source, bool Existed, int Permissions, string ConnectedSHA256, string? OriginalSHA256 = null);

    /// Present once TokenCat added the bridge. `Original` is always null on Windows v1 (only an absent statusLine is bridged).
    /// `PreBridgeSHA256`/`BridgedSHA256`: the bridge was added to an existing connection; while the file is still exactly the
    /// bridged result, a refused whole-file restore puts the pre-bridge bytes back.
    sealed record ManifestStatusLine(string? Original = null, string? PreBridgeSHA256 = null, string? BridgedSHA256 = null);

    sealed record ClaudePlan(byte[] Data, byte[] EnvOnly, bool Wraps = false, bool Bridged = false, TelemetrySetupNote? Note = null);

    /// Throws TelemetrySetupError, or the IOException/UnauthorizedAccessException of an unreadable config (callers map any
    /// other exception to WriteFailed(true), as the mac app does).
    public TelemetrySetupResult Connect()
    {
        lock (MutationLock)
        {
            // Validate both clients before touching either configuration.
            string codexPath = ConfigPath(Codex), claudePath = ConfigPath(Claude);
            var codex = Read(codexPath);
            var claude = Read(claudePath);
            var connected = File.Exists(ActiveManifest);
            var manifest = connected ? Validated(TryRead(ActiveManifest)) : null;
            var codexAfter = CodexConfiguration(codex);
            var plan = ClaudeConfiguration(claude, bridgedBefore: manifest?.StatusLine is not null);
            Change[] changes = [.. new Change[] { new(Codex, codexPath, codex, codexAfter), new(Claude, claudePath, claude, plan.Data) }
                .Where(change => !Same(change.Original, change.Replacement))];
            TelemetrySetupNote[] notes = plan.Note is { } planNote ? [planNote] : [];
            var note = string.Concat(notes.Select(item => " " + item.Text));
            if (changes.Length == 0)
            {
                // A bridge in use is kept current; a failed refresh leaves the working one.
                if (plan.Bridged) TryWriteBridgeScript();
                return new([], [], Loc("로컬 실측 연결 설정이 이미 적용돼 있습니다.", "Local telemetry is already connected.") + note)
                    { Notes = notes, Bridged = plan.Bridged };
            }
            if (connected)
            {
                // A connection without the bridge (its status line was kept, then removed) gets only the bridge, under the same backups.
                if (manifest is null || claude is null || !plan.Wraps || !Same(codexAfter, codex) || !Same(plan.EnvOnly, claude))
                    throw Conflict(Loc("연결 이후 실측 설정이 변경됐습니다. 기존 백업을 보존하기 위해 다시 덮어쓰지 않았습니다.",
                        "The telemetry settings changed after they were connected. TokenCat didn't overwrite them, to keep the existing backup."));
                return AddStatusLineBridge(manifest, claude, plan);
            }

            var backupName = $"{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}-{Guid.NewGuid()}";
            var backupDirectory = Path.Combine(support, "telemetry-backups", backupName);
            Directory.CreateDirectory(backupDirectory);
            var record = new Manifest(1, backupName,
                [.. changes.Select(change => new ManifestEntry(change.Source, change.Original is not null, Permissions, Hash(change.Replacement),
                    change.Original is null ? null : Hash(change.Original)))],
                plan.Wraps ? new ManifestStatusLine() : null);
            foreach (var change in changes)
                if (change.Original is { } original) Write(BackupPath(change.Source, backupDirectory), original);
            var manifestData = Json.Serialize(record);
            Write(Path.Combine(backupDirectory, "manifest.json"), manifestData);
            // The bridge exists before settings name it.
            if (plan.Wraps) WriteBridgeScript();
            else if (plan.Bridged) TryWriteBridgeScript();

            var written = new List<Change>();
            try
            {
                foreach (var change in changes)
                {
                    if (!Same(Read(change.Path), change.Original)) throw Conflict(ChangedByOther);
                    Write(change.Path, change.Replacement);
                    written.Add(change);
                }
                Write(ActiveManifest, manifestData);
            }
            catch (Exception error)
            {
                var restored = Rollback(written);
                if (restored && plan.Wraps) RemoveBridgeIfUnused();
                // A config changed by another program mid-write is a conflict once the rollback succeeded.
                if (restored && error is TelemetrySetupError { Failure: TelemetrySetupFailure.Conflict }) throw;
                throw WriteFailed(restored);
            }
            return new([.. changes.Select(change => change.Path)], [.. changes.Select(change => change.Source)],
                Loc("로컬 실측을 연결했습니다. 실행 중인 클라이언트는 재시작 후 적용됩니다.", "Connected local telemetry. Restart running clients to apply it.") + note)
                { Notes = notes, Bridged = plan.Bridged };
        }
    }

    static string ChangedByOther => Loc("설정이 다른 프로그램에서 변경돼 연결을 중단했습니다.", "Another program changed the settings, so TokenCat stopped connecting.");

    /// Adds the bridge to an existing connection (env connected, status line absent, no bridge record). The current file is
    /// backed up first (`PreBridgeBackupName`) and recorded in the manifest. The whole-file restore keeps covering it: an
    /// entry unchanged since the connection moves its connected hash to the bridged file (its backup predates the bridge);
    /// a missing entry is added with the current file as its backup; an entry edited after the connection refuses a
    /// whole-file restore, and disconnecting then puts the pre-bridge bytes back.
    TelemetrySetupResult AddStatusLineBridge(Manifest manifest, byte[] claude, ClaudePlan plan)
    {
        var path = ConfigPath(Claude);
        var directory = BackupDirectory(manifest);
        Write(Path.Combine(directory, PreBridgeBackupName), claude);
        var entries = manifest.Entries.ToList();
        var index = entries.FindIndex(entry => entry.Source == Claude);
        if (index < 0)
        {
            Write(BackupPath(Claude, directory), claude);
            entries.Add(new(Claude, true, Permissions, Hash(plan.Data), Hash(claude)));
        }
        else if (entries[index].ConnectedSHA256 == Hash(claude)) entries[index] = entries[index] with { ConnectedSHA256 = Hash(plan.Data) };
        var manifestData = Json.Serialize(manifest with { Entries = entries, StatusLine = new(null, Hash(claude), Hash(plan.Data)) });
        WriteBridgeScript();
        var record = Path.Combine(directory, "manifest.json");
        var previousRecord = Read(record);
        try
        {
            if (!Same(Read(path), claude)) throw Conflict(ChangedByOther);
            Write(path, plan.Data);
            Write(record, manifestData);
            Write(ActiveManifest, manifestData);
        }
        catch (Exception error)
        {
            var restored = Rollback([new(Claude, path, claude, plan.Data)]);
            if (previousRecord is not null) TryWrite(record, previousRecord);
            if (restored) RemoveBridgeIfUnused();
            if (restored && error is TelemetrySetupError { Failure: TelemetrySetupFailure.Conflict }) throw;
            throw WriteFailed(restored);
        }
        // The OTLP connection is unchanged, so no restart notice: until a running Claude Code reloads its settings,
        // its limits are simply not shown yet.
        return new([path], [], Loc("Claude Code 상태 표시줄에 사용량 한도 연결을 추가했습니다. 기존 상태 표시줄 출력은 그대로입니다.",
            "Added the usage limit connection to the Claude Code status line. Its output stays the same.")) { Bridged = true };
    }

    /// Throws TelemetrySetupError (or an IO exception reading a config, as Connect).
    public TelemetrySetupResult Disconnect()
    {
        lock (MutationLock)
        {
            if (Read(ActiveManifest) is not { } data)
                return new([], [], Loc("복구할 TokenCat 실측 연결이 없습니다.", "There's no TokenCat telemetry connection to remove."));
            if (Validated(data) is not { } manifest)
                throw Invalid(Loc("실측 백업 정보가 올바르지 않아 설정을 변경하지 않았습니다.", "The telemetry backup record isn't valid, so the settings weren't changed."));
            var directory = BackupDirectory(manifest);
            // A file unchanged since the connection gets its exact original bytes back. One edited since (Codex and Claude Code
            // rewrite their own settings) loses only what TokenCat added; a TokenCat key that now holds another value refuses
            // the whole restore, and then only the status line still goes back, since it runs a script from this folder.
            var restored = new List<(ManifestEntry Entry, byte[] Current, byte[]? Replacement)>();
            var refused = new List<TokenSource>();
            string? statusLine = null;
            foreach (var entry in manifest.Entries)
            {
                var path = ConfigPath(entry.Source);
                var backup = entry.Existed ? Read(BackupPath(entry.Source, directory)) : null;
                // Stricter than the mac: a missing backup never passes as "no hash recorded", so nothing is deleted on its word.
                if (entry.Existed && (backup is null || Hash(backup) != entry.OriginalSHA256))
                    throw Invalid(Loc("원본 실측 백업이 없거나 변경돼 설정을 복구하지 않았습니다.",
                        "The original telemetry backup is missing or changed, so the settings weren't restored."));
                if (Read(path) is { } unchanged && Hash(unchanged) == entry.ConnectedSHA256)
                {
                    restored.Add((entry, unchanged, backup));
                    continue;
                }
                if (entry.Source == Claude) statusLine = RestoreStatusLine(manifest, directory);
                if (Read(path) is not { } current) continue;
                if ((entry.Source switch
                    {
                        Claude => RevertClaude(current, backup, bridged: manifest.StatusLine is not null),
                        Codex => RevertCodex(current, backup),
                        _ => null,
                    }) is not { } reverted)
                {
                    refused.Add(entry.Source);
                    continue;
                }
                if (!Same(reverted, current)) restored.Add((entry, current, reverted));
            }
            if (refused.Count > 0)
            {
                var names = string.Join(", ", refused.Select(source => source.Title));
                throw Conflict(Loc($"연결 후 {names} 설정이 수정돼 TokenCat 항목만 따로 되돌릴 수 없습니다. 사용자 변경을 보존하기 위해 자동 복구하지 않았습니다.",
                                   $"{names} settings changed after the connection, and TokenCat's entries can't be reverted on their own. Nothing was restored automatically, to keep your changes.")
                               + (statusLine ?? RestoreStatusLine(manifest, directory)));
            }
            var stamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var completed = new List<(ManifestEntry Entry, byte[] Current, byte[]? Replacement)>();
            try
            {
                foreach (var item in restored)
                {
                    var path = ConfigPath(item.Entry.Source);
                    if (!Same(Read(path), item.Current)) throw Conflict(Loc("복구 중 설정이 변경됐습니다.", "The settings changed during the restore."));
                    if (Hash(item.Current) != item.Entry.ConnectedSHA256)
                        Write(Path.Combine(directory, $"before-disconnect-{stamp}-" + Path.GetFileName(BackupPath(item.Entry.Source, directory))), item.Current);
                    if (item.Replacement is { } replacement) Write(path, replacement);
                    else File.Delete(path);
                    completed.Add(item);
                }
                File.Delete(ActiveManifest);
            }
            catch (Exception)
            {
                var rolledBack = true;
                for (var i = completed.Count - 1; i >= 0; i--)
                {
                    try
                    {
                        var path = ConfigPath(completed[i].Entry.Source);
                        if (!Same(Read(path), completed[i].Replacement)) { rolledBack = false; continue; }
                        Write(path, completed[i].Current);
                    }
                    catch (Exception) { rolledBack = false; }
                }
                throw WriteFailed(rolledBack);
            }
            // The restored settings hold the original status line, so the bridge goes too unless something still names it.
            if (manifest.StatusLine is not null) RemoveBridgeIfUnused();
            // Any entry not put back whole (reverted by key, or with nothing of TokenCat's left) was edited.
            var edited = restored.Count(item => Hash(item.Current) == item.Entry.ConnectedSHA256) != manifest.Entries.Count;
            return new([.. restored.Select(item => ConfigPath(item.Entry.Source))], [.. restored.Select(item => item.Entry.Source)],
                (edited ? Loc("TokenCat이 추가한 실측 설정만 되돌리고 연결 후 바뀐 다른 설정은 그대로 두었습니다. 클라이언트 재시작 후 적용됩니다.",
                              "Removed only the telemetry settings TokenCat added and kept every other change made since. Restart the clients to apply.")
                        : Loc("TokenCat 실측 연결 전의 설정으로 복구했습니다. 클라이언트 재시작 후 적용됩니다.",
                              "Restored the settings from before the TokenCat telemetry connection. Restart the clients to apply.")) + (statusLine ?? ""));
        }
    }

    /// Edited Claude Code settings without TokenCat's env: a key still holding TokenCat's value gets the backup's value back
    /// (or goes when the backup had none), and a content-logging switch TokenCat set to "0" gets its backed-up value back.
    /// Every other key stays. Null when one of TokenCat's keys now holds a value that is neither TokenCat's nor the backup's,
    /// or when the status line TokenCat bridged (`bridged`) still runs the bridge in any spelling: its record must outlive
    /// this attempt.
    static byte[]? RevertClaude(byte[] current, byte[]? backup, bool bridged)
    {
        if (Json.ParseNode(current) is not JsonObject settings || bridged && CommandOf(settings) is { } command && RunsBridge(command)) return null;
        if (!settings.ContainsKey("env")) return current;
        if (settings["env"] is not JsonObject env) return null;
        var before = (backup is null ? null : Json.ParseNode(backup) as JsonObject)?["env"] as JsonObject;
        foreach (var (key, value) in ClaudeEnv)
        {
            if (!env.ContainsKey(key)) continue;
            if (Text(env[key]) == value)
            {
                if (before?.ContainsKey(key) == true) env[key] = before[key]?.DeepClone();
                else env.Remove(key);
            }
            else if (before?.ContainsKey(key) != true || !JsonNode.DeepEquals(env[key], before[key])) return null;
        }
        foreach (var key in ClaudeLogKeys)
            if (Text(env[key]) == "0" && before?.ContainsKey(key) == true) env[key] = before[key]?.DeepClone();
        if (env.Count == 0 && before is null) settings.Remove("env");
        return SettingsData(settings, current);
    }

    /// Edited Codex config without the `[otel]` table Connect() appended: removed with its blank line when it is still
    /// exactly as written and holds nothing else. The file as it is once TokenCat's lines are gone. Null when the original
    /// had its own `[otel]` table (TokenCat's keys are mixed into it) or TokenCat's lines changed.
    static byte[]? RevertCodex(byte[] current, byte[]? backup)
    {
        if (Same(current, backup)) return current;
        if (Utf8(current) is not var (text, bom)) return null;
        var endpoint = $"127.0.0.1:{Port}";
        var original = backup is null ? "" : Utf8(backup)?.Text ?? "";
        if (original.Split('\n').Any(line => line.Trim().StartsWith("[otel]", StringComparison.Ordinal))) return null;
        var suffix = text.Contains("\r\n") ? "\r" : "";
        var block = CodexExporters.Select(exporter => $"{exporter.Key} = {exporter.Value}").Prepend("[otel]").Select(line => line + suffix).ToArray();
        var lines = text.Split('\n').ToList();
        var start = Enumerable.Range(0, lines.Count).FirstOrDefault(index => lines.Skip(index).Take(block.Length).SequenceEqual(block), -1);
        if (start < 0) return text.Contains(endpoint) ? null : current;
        var end = start + block.Length;
        var next = lines.Skip(end).FirstOrDefault(line => line.Trim().Length > 0);
        if (next is not null && !next.Trim(' ', '\t').StartsWith('[')) return null;
        var from = start > 0 && lines[start - 1] == suffix ? start - 1 : start;
        lines.RemoveRange(from, end - from);
        var reverted = string.Join('\n', lines);
        return reverted.Contains(endpoint) ? null : Utf8Bytes(reverted, bom);
    }

    static Manifest? Validated(byte[]? data)
    {
        if (data is null) return null;
        Manifest? manifest;
        try { manifest = JsonSerializer.Deserialize<Manifest>(Json.StripBom(data), ManifestOptions); }
        catch (JsonException) { return null; }
        return manifest is { Version: 1, Entries.Count: > 0 }
               && manifest.Entries.All(entry => entry is { Permissions: >= 0 and <= 4095 })
               && manifest.Entries.Select(entry => entry.Source).Distinct().Count() == manifest.Entries.Count
               && Regex.IsMatch(manifest.BackupDirectory, @"^[0-9]+-[A-Fa-f0-9-]+\z") ? manifest : null;
    }

    /// A whole-file restore was refused. While Claude Code settings still run the bridge exactly as TokenCat wrote it, the
    /// status line alone goes: the exact pre-bridge bytes when the file is still the bridge step's result, otherwise no
    /// `statusLine` with every other key as it is now. The current bytes are backed up first, and an unchanged Claude entry
    /// moves its connected hash so a later whole-file restore still applies. Returns the sentence for the message ("" without
    /// a bridge record). (The mac's "recorded original command" branch has no Windows v1 counterpart.)
    string RestoreStatusLine(Manifest manifest, string directory)
    {
        if (manifest.StatusLine is not { } record) return "";
        var path = ConfigPath(Claude);
        var kept = Loc(" 상태 표시줄도 지금 설정 그대로 두었습니다.", " The status line was also left as it is.");
        var failed = Loc(" Claude Code 상태 표시줄은 되돌리지 못했습니다.", " Couldn't restore the Claude Code status line.");
        if (TryRead(path) is not { } current || Json.ParseNode(current) is not JsonObject settings) return kept;
        if (CommandOf(settings) != StatusLineCommand)
        {
            RemoveBridgeIfUnused();
            return kept;
        }
        byte[] replacement;
        if (record.BridgedSHA256 is { } bridged && Hash(current) == bridged && record.PreBridgeSHA256 is { } pre
            && TryRead(Path.Combine(directory, PreBridgeBackupName)) is { } bytes && Hash(bytes) == pre) replacement = bytes;
        else
        {
            var target = (JsonObject)settings.DeepClone();
            target.Remove("statusLine");
            replacement = RemovingMember("statusLine", current, target) ?? SettingsData(target, current);
        }
        try
        {
            Write(Path.Combine(directory, $"claude-settings-before-statusline-restore-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}.json"), current);
            if (!Same(Read(path), current)) return failed;
            Write(path, replacement);
        }
        catch (Exception) { return failed; }
        var entries = manifest.Entries.ToList();
        var index = entries.FindIndex(entry => entry.Source == Claude && entry.ConnectedSHA256 == Hash(current));
        if (index >= 0)
        {
            entries[index] = entries[index] with { ConnectedSHA256 = Hash(replacement) };
            var data = Json.Serialize(manifest with { Entries = entries });
            TryWrite(Path.Combine(directory, "manifest.json"), data);
            TryWrite(ActiveManifest, data);
        }
        RemoveBridgeIfUnused();
        return Json.ParseNode(replacement) is JsonObject restored && restored.ContainsKey("statusLine")
            ? Loc(" Claude Code 상태 표시줄은 원래 명령으로 되돌렸습니다.", " Restored the Claude Code status line to its original command.")
            : Loc(" TokenCat이 추가한 Claude Code 상태 표시줄은 지웠습니다.", " Removed the Claude Code status line TokenCat added.");
    }

    /// `data` without the member `key` (a flat object value) and one adjacent comma, when that alone turns it into `expected`:
    /// Claude Code's own formatting and number spelling stay. Null when no single removal does.
    static byte[]? RemovingMember(string key, byte[] data, JsonObject expected)
    {
        if (Utf8(data) is not var (text, bom)) return null;
        var member = Regex.Escape($"\"{key}\"") + @"\s*:\s*\{[^{}]*\}";
        foreach (var pattern in new[] { member + @"\s*,\s*", @"\s*,\s*" + member, member })
            foreach (Match match in Regex.Matches(text, pattern))
            {
                var candidate = Utf8Bytes(text.Remove(match.Index, match.Length), bom);
                if (Json.ParseNode(candidate) is JsonObject parsed && JsonNode.DeepEquals(parsed, expected)) return candidate;
            }
        return null;
    }

    void WriteBridgeScript()
    {
        var script = Encoding.ASCII.GetBytes(StatusLineScript());
        if (!Same(TryRead(BridgeScript), script)) Write(BridgeScript, script);
    }

    void TryWriteBridgeScript()
    {
        try { WriteBridgeScript(); }
        catch (Exception) { }
    }

    /// Leaves the bridge in place while Claude Code settings still run it (an edited file that was not restored).
    void RemoveBridgeIfUnused()
    {
        byte[]? current;
        try { current = Read(ConfigPath(Claude)); }
        catch (Exception) { return; }
        if (current is not null && Json.ParseNode(current) is JsonObject settings && CommandOf(settings) is { } command && RunsBridge(command)) return;
        try { File.Delete(BridgeScript); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    static bool Rollback(IReadOnlyList<Change> written)
    {
        var restored = true;
        for (var i = written.Count - 1; i >= 0; i--)
        {
            var change = written[i];
            try
            {
                if (!Same(Read(change.Path), change.Replacement)) { restored = false; continue; }
                if (change.Original is { } original) Write(change.Path, original);
                else File.Delete(change.Path);
            }
            catch (Exception) { restored = false; }
        }
        return restored;
    }

    /// `bridgedBefore`: the active connection already added the bridge once, so a status line that no longer runs the
    /// bridge (or none) is the person's choice and stays as it is.
    ClaudePlan ClaudeConfiguration(byte[]? original, bool bridgedBefore)
    {
        var settings = new JsonObject();
        if (original is not null)
            settings = Json.ParseNode(original) as JsonObject ?? throw Invalid(Loc("Claude Code settings.json 형식이 올바르지 않아 변경하지 않았습니다.",
                "Claude Code settings.json isn't in a valid format, so it wasn't changed."));
        if (settings.ContainsKey("env") && settings["env"] is not JsonObject)
            throw Invalid(Loc("Claude Code env 설정이 객체가 아니어서 변경하지 않았습니다.", "The Claude Code env setting isn't an object, so it wasn't changed."));
        var env = settings["env"] as JsonObject ?? [];
        // A pre-existing global exporter endpoint/headers can redirect or authenticate every signal.
        foreach (var key in new[] { "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" })
            if (env.ContainsKey(key) && Text(env[key]) != (key == "OTEL_EXPORTER_OTLP_ENDPOINT" ? Endpoint : ClaudeEnv[key]))
                throw Conflict(Loc("Claude Code에 기존 OTLP 전송 대상이 있어 덮어쓰지 않았습니다.", "Claude Code already has an OTLP destination, so it wasn't overwritten."));
        foreach (var key in new[] { "OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_LOGS_HEADERS", "OTEL_EXPORTER_OTLP_TRACES_HEADERS" })
            if (env.ContainsKey(key) && Text(env[key]) != "")
                throw Conflict(Loc("Claude Code에 기존 OTLP 인증 헤더가 있어 덮어쓰지 않았습니다.", "Claude Code already has OTLP auth headers, so they weren't overwritten."));
        foreach (var key in new[] { "OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER" })
        {
            if (env.ContainsKey(key) && (Text(env[key]) ?? "invalid") is not ("none" or "otlp" or ""))
                throw Conflict(Loc("Claude Code에 기존 실측 exporter가 있어 덮어쓰지 않았습니다.", "Claude Code already has a telemetry exporter, so it wasn't overwritten."));
            var signal = key == "OTEL_LOGS_EXPORTER" ? "LOGS" : "TRACES";
            if (Text(env[key]) == "otlp" && !env.ContainsKey($"OTEL_EXPORTER_OTLP_{signal}_ENDPOINT") && Text(env["OTEL_EXPORTER_OTLP_ENDPOINT"]) != Endpoint)
                throw Conflict(Loc("Claude Code가 기존 OTLP 기본 대상에 연결돼 있어 덮어쓰지 않았습니다.",
                    "Claude Code already sends to a default OTLP destination, so it wasn't overwritten."));
        }
        foreach (var (key, value) in ClaudeEnv) env[key] = value;
        foreach (var key in ClaudeLogKeys)
            if (env.ContainsKey(key) && !IsOff(env[key])) env[key] = "0";
        if (!settings.ContainsKey("env")) settings["env"] = env;
        var envOnly = SettingsData(settings, original);
        var plan = new ClaudePlan(envOnly, envOnly);
        if (!settings.ContainsKey("statusLine"))
        {
            // The bridge prints nothing after forwarding. A bridge the person removed stays removed.
            if (bridgedBefore) return plan;
            settings["statusLine"] = new JsonObject { ["type"] = "command", ["command"] = StatusLineCommand };
            return plan with { Data = SettingsData(settings, original), Wraps = true, Bridged = true };
        }
        if (settings["statusLine"] is JsonObject line && Text(line["type"]) == "command" && CommandOf(settings) is { } command
            && !string.IsNullOrWhiteSpace(command) && RunsBridge(command)) return plan with { Bridged = true };
        // Windows v1 never wraps a status line it can't re-run in the right shell (open question 2): any other one stays.
        return plan with { Note = TelemetrySetupNote.StatusLineKept };
    }

    /// `prettyPrinted + sortedKeys` through Json.Write; the original bytes when nothing changed, so an applied connection
    /// is never rewritten.
    static byte[] SettingsData(JsonObject settings, byte[]? original) =>
        original is not null && Json.ParseNode(original) is JsonObject prior && JsonNode.DeepEquals(prior, settings) ? original : Json.Write(settings);

    static string? CommandOf(JsonObject settings) => settings["statusLine"] is JsonObject line ? Text(line["command"]) : null;

    static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    /// Swift's `(value as? String ?? String(describing: value))` in ["", "0", "false", "no", "off"].
    static bool IsOff(JsonNode? node) => node switch
    {
        JsonValue value when value.TryGetValue(out string? text) => text.Trim(' ', '\t').ToLowerInvariant() is "" or "0" or "false" or "no" or "off",
        JsonValue value when value.TryGetValue(out bool flag) => !flag,
        JsonValue value when value.TryGetValue(out double number) => number == 0,
        _ => false,
    };

    byte[] CodexConfiguration(byte[]? original)
    {
        var (text, bom) = original is null ? ("", false)
            : Utf8(original) ?? throw Invalid(Loc("Codex config.toml이 UTF-8 형식이 아니어서 변경하지 않았습니다.", "Codex config.toml isn't UTF-8, so it wasn't changed."));
        var suffix = text.Contains("\r\n") ? "\r" : "";
        var lines = text.Split('\n').ToList();
        string? section = null, multiline = null;
        int? sectionStart = null;
        var sectionEnd = lines.Count;
        var replacements = new Dictionary<int, string>();
        var found = new HashSet<string>();
        var requested = CodexExporters.ToDictionary(exporter => exporter.Key, exporter => exporter.Value);
        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index].EndsWith('\r') ? lines[index][..^1] : lines[index];
            var wasMultiline = multiline is not null;
            var visible = ScanToml(line, ref multiline);
            if (wasMultiline) continue;
            var trimmed = visible.Trim(' ', '\t');
            if (trimmed.StartsWith('['))
            {
                if (!trimmed.EndsWith(']') || trimmed.Length < 2)
                    throw Invalid(Loc("Codex TOML 테이블 형식이 올바르지 않습니다.", "A Codex TOML table header isn't valid."));
                var raw = trimmed[1..^1].Trim(' ', '\t');
                var normalized = Bare(raw);
                if (section == "otel") sectionEnd = index;
                section = normalized;
                if (normalized == "otel")
                {
                    if (raw != "otel" || sectionStart is not null)
                        throw Conflict(Loc("Codex otel 테이블이 중복되거나 복잡한 형식이어서 덮어쓰지 않았습니다.",
                            "The Codex otel table is repeated or too complex, so it wasn't overwritten."));
                    sectionStart = index;
                }
                else if (normalized.StartsWith("otel.", StringComparison.Ordinal) || normalized.StartsWith("[otel", StringComparison.Ordinal))
                    throw Conflict(Loc("Codex에 기존 중첩 OTLP 설정이 있어 덮어쓰지 않았습니다.", "Codex already has nested OTLP settings, so they weren't overwritten."));
                continue;
            }
            var equals = visible.IndexOf('=');
            if (equals >= 0)
            {
                var rootKey = Bare(visible[..equals]);
                if (rootKey.StartsWith("otel.", StringComparison.Ordinal) || section is null && rootKey == "otel")
                    throw Conflict(Loc("Codex에 기존 dotted 또는 inline otel 설정이 있어 덮어쓰지 않았습니다.",
                        "Codex already has dotted or inline otel settings, so they weren't overwritten."));
            }
            if (section != "otel" || equals < 0) continue;
            var key = visible[..equals].Trim(' ', '\t');
            var bareKey = Bare(key);
            if (bareKey.Contains('.') && new[] { "exporter.", "metrics_exporter.", "trace_exporter." }.Any(prefix => bareKey.StartsWith(prefix, StringComparison.Ordinal)))
                throw Conflict(Loc("Codex에 기존 dotted OTLP 설정이 있어 덮어쓰지 않았습니다.", "Codex already has dotted OTLP settings, so they weren't overwritten."));
            if (!requested.ContainsKey(bareKey) && bareKey is not ("log_user_prompt" or "log_agent_responses")) continue;
            if (key != bareKey || found.Contains(bareKey) || multiline is not null)
                throw Conflict(Loc("Codex otel 키가 중복되거나 여러 줄 형식이어서 변경하지 않았습니다.", "A Codex otel key is repeated or spans several lines, so it wasn't changed."));
            found.Add(bareKey);
            var value = visible[(equals + 1)..].Trim(' ', '\t');
            string after;
            if (requested.TryGetValue(bareKey, out var desired))
            {
                string[] allowed = bareKey == "metrics_exporter" ? ["\"none\"", "'none'", "\"statsig\"", "'statsig'"] : ["\"none\"", "'none'"];
                if (!allowed.Contains(value) && CompactToml(value) != CompactToml(desired))
                    throw Conflict(Loc($"Codex에 기존 {bareKey} 전송 설정이 있어 덮어쓰지 않았습니다.", $"Codex already has a {bareKey} setting, so it wasn't overwritten."));
                after = desired;
            }
            else
            {
                if (value is not ("true" or "false"))
                    throw Invalid(Loc("Codex 실측 개인정보 옵션이 올바르지 않습니다.", "A Codex telemetry privacy option isn't valid."));
                after = "false";
            }
            var comment = line[visible.Length..].Trim(' ', '\t');
            replacements[index] = line[..(equals + 1)] + " " + after + (comment.Length == 0 ? "" : " " + comment) + suffix;
        }
        if (multiline is not null)
            throw Invalid(Loc("Codex TOML 문자열이 닫히지 않아 변경하지 않았습니다.", "A Codex TOML string isn't closed, so it wasn't changed."));
        foreach (var (index, replacement) in replacements) lines[index] = replacement;
        var missing = CodexExporters.Where(exporter => !found.Contains(exporter.Key)).Select(exporter => $"{exporter.Key} = {exporter.Value}{suffix}").ToList();
        if (sectionStart is not null) lines.InsertRange(sectionEnd == lines.Count && lines[^1] == "" ? sectionEnd - 1 : sectionEnd, missing);
        else
        {
            if (lines[^1] == "") lines.RemoveAt(lines.Count - 1);
            if (text.Length > 0) lines.Add(suffix);
            lines.Add("[otel]" + suffix);
            lines.AddRange(missing);
            lines.Add("");
        }
        return Utf8Bytes(string.Join('\n', lines), bom);
    }

    /// Returns text before an unquoted comment and tracks multiline strings in unrelated sections.
    static string ScanToml(string line, ref string? multiline)
    {
        var index = 0;
        char? quote = null;
        while (index < line.Length)
        {
            if (multiline is { } delimiter)
            {
                if (index + 2 < line.Length && line.Substring(index, 3) == delimiter)
                {
                    multiline = null;
                    index += 3;
                }
                else index++;
                continue;
            }
            var character = line[index];
            if (quote is { } current)
            {
                if (current == '"' && character == '\\') { index += 2; continue; }
                if (character == current) quote = null;
                index++;
                continue;
            }
            if (character == '#') return line[..index];
            if (character is '"' or '\'')
            {
                if (index + 2 < line.Length && line[index + 1] == character && line[index + 2] == character)
                {
                    multiline = new string(character, 3);
                    index += 3;
                }
                else
                {
                    quote = character;
                    index++;
                }
            }
            else index++;
        }
        return line;
    }

    static string CompactToml(string value)
    {
        var result = new StringBuilder();
        char? quote = null;
        var escaped = false;
        foreach (var character in value)
        {
            if (quote is { } current)
            {
                result.Append(character);
                if (escaped) escaped = false;
                else if (current == '"' && character == '\\') escaped = true;
                else if (character == current) quote = null;
            }
            else if (character is '"' or '\'')
            {
                quote = character;
                result.Append(character);
            }
            else if (!char.IsWhiteSpace(character)) result.Append(character);
        }
        return result.ToString();
    }

    static string Bare(string value) => CompactToml(value).Replace("\"", "").Replace("'", "");

    /// Strict UTF-8 with the BOM split off (rule 9): a BOM line would hide a first-line `[otel]`; it goes back on write.
    static (string Text, bool Bom)? Utf8(byte[] data)
    {
        string text;
        try { text = StrictUtf8.GetString(data); }
        catch (DecoderFallbackException) { return null; }
        return text.StartsWith('﻿') ? (text[1..], true) : (text, false);
    }

    static byte[] Utf8Bytes(string text, bool bom) => Encoding.UTF8.GetBytes(bom ? "﻿" + text : text);

    static bool Same(byte[]? a, byte[]? b) => a is null ? b is null : b is not null && a.AsSpan().SequenceEqual(b);

    static string Hash(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    /// Null when missing. A directory or a link is refused: TokenCat never writes through one.
    static byte[]? Read(string path)
    {
        var info = new FileInfo(path);
        if (Directory.Exists(path) || info.Exists && info.LinkTarget is not null)
            throw Invalid(Loc($"설정 경로가 일반 파일이 아니어서 변경하지 않았습니다: {info.Name}", $"A settings path isn't a regular file, so it wasn't changed: {info.Name}"));
        if (!info.Exists) return null;
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var bytes = new MemoryStream();
        file.CopyTo(bytes);
        return bytes.ToArray();
    }

    static byte[]? TryRead(string path)
    {
        try { return Read(path); }
        catch (Exception) { return null; }
    }

    static void Write(string path, byte[] data) => AppPaths.WriteAtomically(path, data);

    static void TryWrite(string path, byte[] data)
    {
        try { Write(path, data); }
        catch (Exception) { }
    }

    static TelemetrySetupError Conflict(string reason) => new(new TelemetrySetupFailure.Conflict(), reason);
    static TelemetrySetupError Invalid(string reason) => new(new TelemetrySetupFailure.Invalid(), reason);
    static TelemetrySetupError WriteFailed(bool restored) => new(new TelemetrySetupFailure.WriteFailed(restored), restored
        ? Loc("설정 저장에 실패하여 원래 설정으로 복구했습니다.", "Couldn't save the settings, so the original settings were restored.")
        : Loc("설정 저장 중 일부 파일이 변경됐습니다. 사용자 변경을 보존했으며 백업에서 개별 확인이 필요합니다.",
              "Some files changed while the settings were being saved. Your changes were kept; check each file against its backup."));
}
