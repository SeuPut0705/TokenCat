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
public sealed record LiveLimitResult(IReadOnlyList<TokenRateLimit>? Codex = null, ClaudeUsageLimits? Claude = null, bool Failed = false);

/// "실시간 한도 확인" (on by default): account usage limits read as they are, instead of the last value a log, the status line
/// or the Claude desktop app recorded. Codex: a short-lived `codex app-server` (JSON-RPC 2.0, one JSON object per line on
/// stdio) asked `account/rateLimits/read`; TokenCat never reads OpenAI tokens. Claude: Anthropic's OAuth usage endpoint with
/// Claude Code's saved sign-in (`~\.claude\.credentials.json`). That access token lives only for its one request: never
/// stored, logged, passed as a process argument or refreshed (a refresh rotates Claude Code's own refresh token and signs it out).
/// Requests go only to the codex executable and api.anthropic.com.
public sealed class LiveLimits(string home, string version, HttpMessageHandler? handler = null)
{
    /// Seconds: the poll interval while a session of the provider runs or a dashboard shows, otherwise; a dashboard that opens
    /// polls at once when the last poll is this old; a value this recent reads "실시간"; the longest failure backoff.
    public const double ActiveInterval = 60, IdleInterval = 600, OpenedAfter = 15, LiveFor = 120, MaximumBackoff = 1_800;
    static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);
    public static readonly Uri ClaudeEndpoint = new("https://api.anthropic.com/api/oauth/usage");

    readonly string credentials = Path.Combine(home, ".claude", ".credentials.json");
    // No cookies, credentials or redirects: the bearer token goes to api.anthropic.com only.
    readonly HttpClient http = new(handler ?? Handler()) { Timeout = Timeout, MaxResponseContentBufferSize = 1 << 20 };
    /// SHA-256 of the access token refused with 401/403; that token is not sent again until Claude Code stores another.
    string? rejected;

    static SocketsHttpHandler Handler()
    {
        var value = UpdateClient.Handler();
        value.AllowAutoRedirect = false;
        return value;
    }

    /// Per provider, guarded by its owner (LiveMonitor): one poll in flight, when the last one started (Stopwatch), failures since
    /// the last answer.
    public sealed class Poll
    {
        public bool Running;
        public long? Started;
        public int Failures;
    }

    /// Every minute while one of the provider's sessions runs or a dashboard shows, else every 10 minutes; a dashboard that just
    /// opened polls when the last poll is 15 s old. Each failure doubles the wait, up to 30 minutes, and opening doesn't skip it.
    public static bool Due(double? sinceLast, int failures, bool active, bool opened)
    {
        if (sinceLast is not { } elapsed) return true;
        var wait = Math.Min(MaximumBackoff, (active ? ActiveInterval : IdleInterval) * Math.Pow(2, failures));
        return elapsed >= wait || (opened && failures == 0 && elapsed >= OpenedAfter);
    }

    /// The monitor's reader; one call per provider at a time.
    public Task<LiveLimitResult> Read(TokenSource source, CancellationToken token) => source == TokenSource.Claude ? ReadClaude(token)
        : FindCodex() is { } codex ? ReadCodex(codex, version, Timeout, token) : Task.FromResult(new LiveLimitResult());

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

    /// Skipped without a request when there is no sign-in, the token expires within a minute (or has no expiry), or it was
    /// refused before.
    public async Task<LiveLimitResult> ReadClaude(CancellationToken token)
    {
        JsonElement oauth;
        try
        {
            // Claude Code rewrites the file when it refreshes: share everything, as the desktop history reader does.
            using var stream = new FileStream(credentials, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > TelemetryHttp.MaximumBodyBytes) return new();
            using var bytes = new MemoryStream();
            await stream.CopyToAsync(bytes, token).ConfigureAwait(false);
            if (Json.Parse(bytes.ToArray())?.Field("claudeAiOauth") is not { ValueKind: JsonValueKind.Object } value) return new();
            oauth = value;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return new(); }
        if (oauth.Field("accessToken")?.Text is not { Length: > 0 } access
            || oauth.Field("expiresAt")?.Number is not { } expires || expires <= DateTimeOffset.UtcNow.AddSeconds(60).ToUnixTimeMilliseconds()) return new();
        var fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(access)));
        if (fingerprint == rejected) return new();
        using var request = new HttpRequestMessage(HttpMethod.Get, ClaudeEndpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
        request.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
        request.Headers.TryAddWithoutValidation("User-Agent", UpdateClient.UserAgent(version));
        try
        {
            using var response = await http.SendAsync(request, token).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                rejected = fingerprint;
                return new();
            }
            // 429, 5xx and anything unexpected back off.
            if (response.StatusCode != HttpStatusCode.OK) return new(Failed: true);
            var body = await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
            return DecodeClaude(body, DateTimeOffset.UtcNow) is { } limits ? new(Claude: limits) : new(Failed: true);
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or IOException) { return new(Failed: true); }
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
