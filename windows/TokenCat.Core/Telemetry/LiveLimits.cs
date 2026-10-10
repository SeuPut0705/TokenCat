using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// One live poll: Codex's windows, Claude's windows, or neither. `Failed` (no answer, an error status, an unknown shape) backs
/// the next poll off; nothing to ask with (no codex, no sign-in, an expiring or refused token) is not a failure.
public sealed record LiveLimitResult(IReadOnlyList<TokenRateLimit>? Codex = null, ClaudeUsageLimits? Claude = null, bool Failed = false)
{
    public LimitSlot? Slot { get; init; }
    public IReadOnlySet<string> Rejected { get; init; } = new HashSet<string>(StringComparer.Ordinal);
}

/// "실시간 한도 확인" (on by default): account usage limits read as they are, instead of the last value a log, the status line
/// or the Claude desktop app recorded. Codex: a short-lived `codex app-server` (JSON-RPC 2.0, one JSON object per line on
/// stdio) asked `account/rateLimits/read`; TokenCat never reads OpenAI tokens. Claude: Anthropic's OAuth usage endpoint with
/// Claude Code's saved sign-in (`~\.claude\.credentials.json`), or, when that is missing or expired, omp's or Pi's saved
/// Anthropic sign-in (`agent.db` `auth_credentials`) for the same account. That access token lives only for its one request: never
/// stored, logged, passed as a process argument or refreshed (a refresh rotates the owning client's refresh token and signs it out).
/// Requests go only to the codex executable and api.anthropic.com.
public sealed class LiveLimits(string home, string version, HttpMessageHandler? handler = null,
    LimitAccountReader? accounts = null, Func<string, string?>? env = null)
{
    /// Seconds: the poll interval while a session of the provider runs or a dashboard shows, otherwise; a dashboard that opens
    /// polls at once when the last poll is this old; a value this recent reads "실시간"; the longest failure backoff.
    public const double ActiveInterval = 60, IdleInterval = 600, OpenedAfter = 15, LiveFor = 120;
    static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);
    public static readonly Uri ClaudeEndpoint = new("https://api.anthropic.com/api/oauth/usage");

    readonly Func<string, string?> environment = env ?? Environment.GetEnvironmentVariable;
    readonly LimitAccountReader accountReader = accounts ?? new(home, env ?? Environment.GetEnvironmentVariable);
    readonly object accountGate = new();
    // No cookies, credentials or redirects: the bearer token goes to api.anthropic.com only.
    readonly HttpClient http = new(handler ?? Handler()) { Timeout = Timeout, MaxResponseContentBufferSize = 1 << 20 };
    readonly Dictionary<LimitSlot, HashSet<string>> rejectedBySlot = [];

    static SocketsHttpHandler Handler()
    {
        var value = UpdateClient.Handler();
        value.AllowAutoRedirect = false;
        return value;
    }

    /// Clock rollback polls immediately; dashboard opening never skips an outstanding retry deadline.
    public static bool Due(DateTimeOffset? last, DateTimeOffset? retryAt, DateTimeOffset now, bool live, bool open, bool opened)
    {
        if (retryAt is { } retry && now < retry) return false;
        if (last is not { } previous) return true;
        var age = (now - previous).TotalSeconds;
        return age < 0 || age >= (opened ? OpenedAfter : live || open ? ActiveInterval : IdleInterval);
    }

    /// One read per account slot at a time, as guarded by the monitor or LiveLimitPoller.
    public async Task<LiveLimitResult> Read(LimitSlot slot, CancellationToken token)
    {
        if (slot.Provider == TokenSource.Claude) return await ReadClaude(slot, token).ConfigureAwait(false);
        if (slot.Provider != TokenSource.Codex) return new() { Slot = slot };
        LimitAccount? defaultCodex;
        lock (accountGate)
        {
            accountReader.Refresh();
            defaultCodex = accountReader.DefaultAccount(TokenSource.Codex);
        }
        if (slot.Account != defaultCodex || FindCodex() is not { } executable)
            return new() { Slot = slot };
        var result = await ReadCodex(executable, version, Timeout, token).ConfigureAwait(false);
        return result with { Slot = slot, Codex = result.Codex?.Select(value => value with { Account = slot.Account }).ToArray() };
    }

    // MARK: Codex

    /// `codex` on PATH (Windows: codex.exe, then npm's codex.cmd shim), then npm's global folder. A Windows GUI process inherits
    /// the user's PATH.
    public static string? FindCodex()
    {
        var windows = OperatingSystem.IsWindows();
        string[] names = windows ? ["codex.exe", "codex.cmd"] : ["codex"];
        var folders = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).ToList();
        if (windows) folders.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"));
        return folders.SelectMany(folder => names.Select(name => Path.Combine(folder.Trim('"'), name))).FirstOrDefault(File.Exists);
    }

    /// Spawned per poll (the server holds about 120 MB) and always ended: stdin closes when done (it exits on EOF), and the whole
    /// process tree (cmd → node → codex for the npm shim) is killed after `timeout` or when it doesn't exit within 2 s.
    /// Notifications and server requests are skipped; only a response carries an `id` without a `method`.
    public static async Task<LiveLimitResult> ReadCodex(string executable, string version, TimeSpan timeout, CancellationToken token)
    {
        var utf8 = new UTF8Encoding(false);
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo(executable, "app-server")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = utf8, StandardOutputEncoding = utf8, StandardErrorEncoding = utf8,
                // Not TokenCat's own folder (System32 when started at login): no project config is picked up.
                WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            },
        };
        try { process.Start(); }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException) { return new(Failed: true); }
        // Read and dropped, so a chatty stderr can't fill its pipe and stall the server.
        process.ErrorDataReceived += (_, _) => { };
        process.BeginErrorReadLine();
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(token);
        limit.CancelAfter(timeout);
        // Ending the process closes stdout, which ends a read that ignores cancellation.
        using var end = limit.Token.Register(() => Kill(process));
        try
        {
            var input = process.StandardInput;
            var client = JsonSerializer.Serialize(new { name = "tokencat", version });
            await input.WriteAsync($$$"""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{{{client}}}}}""" + "\n").ConfigureAwait(false);
            await input.FlushAsync(limit.Token).ConfigureAwait(false);
            if (await Response(process.StandardOutput, 1, limit.Token).ConfigureAwait(false) is not { } initialized || initialized.Field("result") is null)
                return new(Failed: true);
            // One write, so both lines are in the pipe before the server can answer and exit.
            await input.WriteAsync("""{"jsonrpc":"2.0","method":"initialized","params":{}}""" + "\n"
                + """{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}""" + "\n").ConfigureAwait(false);
            await input.FlushAsync(limit.Token).ConfigureAwait(false);
            var answer = await Response(process.StandardOutput, 2, limit.Token).ConfigureAwait(false);
            return DecodeCodex(answer?.Field("result")?.Field("rateLimits"), DateTimeOffset.UtcNow) is { } windows ? new(Codex: windows) : new(Failed: true);
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) { return new(Failed: true); }
        finally
        {
            try { process.StandardInput.Close(); }
            catch (IOException) { }
            using var exit = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            try { await process.WaitForExitAsync(exit.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { Kill(process); }
        }
    }

    static void Kill(Process process)
    {
        try { process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception or NotSupportedException) { }
    }

    /// The next JSON-RPC response with `id`; null when the output ends first.
    static async Task<JsonElement?> Response(StreamReader output, int id, CancellationToken token)
    {
        while (await output.ReadLineAsync(token).ConfigureAwait(false) is { } line)
            if (Json.Parse(Encoding.UTF8.GetBytes(line)) is { ValueKind: JsonValueKind.Object } message && message.Field("method") is null
                && message.Field("id")?.Number == id)
                return message;
        return null;
    }

    /// `result.rateLimits` → its primary and secondary windows (`usedPercent`, `windowDurationMins`, `resetsAt` in Unix seconds),
    /// the log parser's bounds; null without one or for another limit than "codex".
    public static IReadOnlyList<TokenRateLimit>? DecodeCodex(JsonElement? rateLimits, DateTimeOffset at)
    {
        if (rateLimits is not { ValueKind: JsonValueKind.Object } limits || limits.Field("limitId")?.Text is { } id && id != "codex") return null;
        var windows = new List<TokenRateLimit>();
        foreach (var key in (string[])["primary", "secondary"])
        {
            if (limits.Field(key) is not { ValueKind: JsonValueKind.Object } window || window.Field("usedPercent")?.Number is not { } used || used is < 0 or > 1_000) continue;
            int? minutes = window.Field("windowDurationMins")?.Number is { } m && m is > 0 and <= int.MaxValue && m == Math.Floor(m) ? (int)m : null;
            windows.Add(new(used, minutes, Reset(window.Field("resetsAt")), at) { Live = true });
        }
        return windows.Count > 0 ? windows : null;
    }

    // MARK: Claude

    /// Only tokens matching this exact canonical identity are eligible; nil is a distinct legacy slot.
    async Task<LiveLimitResult> ReadClaude(LimitSlot slot, CancellationToken token)
    {
        LimitAccount? codeAccount;
        IReadOnlyList<(string Access, double? Expires, LimitAccount? Account)> agents;
        IReadOnlyList<(string Directory, LimitAccount? Account)> configurations;
        HashSet<string> rejected;
        lock (accountGate)
        {
            accountReader.Refresh();
            codeAccount = accountReader.ClaudeAccount(Path.Combine(home, ".claude"));
            agents = AgentCredentials(AgentUsageHistory.Databases(home, environment), accountReader);
            configurations = TokenProvider.ClaudeConfigDirectories(home, environment)
                .Select(directory => (directory, accountReader.ClaudeAccount(directory))).ToArray();
            if (!rejectedBySlot.TryGetValue(slot, out rejected!)) rejectedBySlot[slot] = rejected = new(StringComparer.Ordinal);
        }
        var saved = slot.Account == codeAccount
            ? await ClaudeCodeCredential(Path.Combine(home, ".claude"), token).ConfigureAwait(false) : null;
        var candidatesFromConfigs = new List<(string Access, double? Expires, LimitAccount? Account)>();
        foreach (var (directory, account) in configurations)
        {
            if (Path.GetFullPath(directory) == Path.GetFullPath(Path.Combine(home, ".claude")) || account != slot.Account) continue;
            if (await ClaudeCodeCredential(directory, token).ConfigureAwait(false) is { } credential)
                candidatesFromConfigs.Add((credential.Access, credential.Expires, account));
        }
        candidatesFromConfigs.AddRange(agents);
        var candidates = ClaudeCandidates(saved, codeAccount, candidatesFromConfigs, slot.Account);
        var refused = new HashSet<string>(StringComparer.Ordinal);
        var usableAfter = DateTimeOffset.UtcNow.AddSeconds(60).ToUnixTimeMilliseconds();
        foreach (var (access, expires) in candidates)
        {
            if (expires is not { } expiry || expiry <= usableAfter) continue;
            var fingerprint = TokenHash(access);
            if (rejected.Contains(fingerprint)) continue;
            using var request = new HttpRequestMessage(HttpMethod.Get, ClaudeEndpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
            request.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
            request.Headers.TryAddWithoutValidation("User-Agent", UpdateClient.UserAgent(version));
            try
            {
                using var response = await http.SendAsync(request, token).ConfigureAwait(false);
                if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                {
                    rejected.Add(fingerprint);
                    refused.Add(fingerprint);
                    continue;
                }
                if (response.StatusCode != HttpStatusCode.OK) return new(Failed: true) { Slot = slot, Rejected = refused };
                var body = await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
                return DecodeClaude(body, DateTimeOffset.UtcNow) is { } limits
                    ? new(Claude: limits) { Slot = slot, Rejected = refused } : new(Failed: true) { Slot = slot, Rejected = refused };
            }
            catch (Exception error) when (error is HttpRequestException or OperationCanceledException or IOException)
            { return new(Failed: true) { Slot = slot, Rejected = refused }; }
        }
        return new() { Slot = slot, Rejected = refused };
    }

    public static string TokenHash(string access) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(access)));

    /// `{"claudeAiOauth":{"accessToken":…,"expiresAt":ms}}` from ~\.claude\.credentials.json; other fields are not read.
    public static async Task<(string Access, double? Expires)?> ClaudeCodeCredential(string configDirectory, CancellationToken token)
    {
        try
        {
            // Claude Code rewrites the file when it refreshes: share everything, as the desktop history reader does.
            using var stream = new FileStream(Path.Combine(configDirectory, ".credentials.json"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > TelemetryHttp.MaximumBodyBytes) return null;
            using var bytes = new MemoryStream();
            await stream.CopyToAsync(bytes, token).ConfigureAwait(false);
            return Json.Parse(bytes.ToArray())?.Field("claudeAiOauth") is { ValueKind: JsonValueKind.Object } oauth
                && oauth.Field("accessToken")?.Text is { Length: > 0 } access ? (access, oauth.Field("expiresAt")?.Number) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// omp's and Pi's saved Anthropic sign-in (`auth_credentials` in their `agent.db`, an `oauth` row not disabled): only the
    /// access token, its expiry (ms) and account id leave SQLite. These clients refresh their own token while they run, so it
    /// stays usable when Claude Code's has expired. Never refreshed, stored or logged, like Claude Code's.
    public const string AgentCredentialQuery = """
        SELECT json_extract(data, '$.access'), json_extract(data, '$.expires'), json_extract(data, '$.accountId'),
               json_extract(data, '$.email'), json_extract(data, '$.orgName') FROM auth_credentials
        WHERE provider = 'anthropic' AND credential_type = 'oauth' AND disabled_cause IS NULL
        """;

    public static IReadOnlyList<(string Access, double? Expires, LimitAccount? Account)> AgentCredentials(IEnumerable<string> databases, LimitAccountReader accounts)
    {
        var found = new List<(string, double?, LimitAccount?)>();
        foreach (var database in databases)
        {
            if (!File.Exists(database)) continue;
            using var connection = OpenCodeDatabase.Open(database);
            connection?.Query(AgentCredentialQuery, [], row =>
            {
                if (row.Text(0) is { Length: > 0 } access)
                    found.Add((access, row.Double(1), accounts.Resolve(TokenSource.Claude, row.Text(2), row.Text(3), row.Text(4))));
            });
        }
        return found;
    }

    public static IReadOnlyList<(string Access, double? Expires)> ClaudeCandidates((string Access, double? Expires)? claudeCode,
        LimitAccount? claudeAccount, IEnumerable<(string Access, double? Expires, LimitAccount? Account)> agents, LimitAccount? target)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        IEnumerable<(string Access, double? Expires)> own = claudeAccount == target && claudeCode is { } code ? [code] : [];
        return [.. own.Concat(agents.Where(agent => agent.Account == target).Select(agent => (agent.Access, agent.Expires)))
            .Where(candidate => seen.Add(candidate.Access))];
    }

    /// Claude Code's usage schema: `limits[]` with `kind` "session" (the 5-hour window) and "weekly_all" (7-day), `percent` and
    /// `resets_at` (ISO 8601 or null); "weekly_scoped" (one model or surface) isn't a row. Also the older
    /// `five_hour`/`seven_day` objects with `utilization`. Windows are marked live; null for any other shape.
    public static ClaudeUsageLimits? DecodeClaude(ReadOnlySpan<byte> json, DateTimeOffset at)
    {
        if (Json.Parse(json) is not { ValueKind: JsonValueKind.Object } root) return null;
        ClaudeLimitWindow? Window(JsonElement? item, string key) =>
            item is { ValueKind: JsonValueKind.Object } value && value.Field(key)?.Number is { } used && used is >= 0 and <= 1_000
                ? new(used, Reset(value.Field("resets_at")), at) { Live = true } : null;
        ClaudeUsageLimits listed = new();
        if (root.Field("limits") is { ValueKind: JsonValueKind.Array } list)
        {
            JsonElement? Kind(string kind) => list.EnumerateArray().Where(item => item.Field("kind")?.Text == kind).Select(item => (JsonElement?)item).FirstOrDefault();
            listed = new(Window(Kind("session"), "percent"), Window(Kind("weekly_all"), "percent"));
        }
        var limits = listed.IsEmpty ? new ClaudeUsageLimits(Window(root.Field("five_hour"), "utilization"), Window(root.Field("seven_day"), "utilization")) : listed;
        return limits.IsEmpty ? null : limits;
    }

    /// An ISO 8601 string or Unix seconds; null for anything else (no reset time is invented).
    static DateTimeOffset? Reset(JsonElement? value) =>
        value?.Text is { } text && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed
        : value?.Number is { } seconds && seconds is >= 1e9 and <= 1e10 ? DateTimeOffset.UnixEpoch.AddSeconds(seconds) : null;
}
