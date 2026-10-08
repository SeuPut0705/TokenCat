using System.Diagnostics;
using System.Net;
using System.Text;

namespace TokenCat;

/// LiveLimits: the Codex JSON-RPC exchange through the real spawn path (a fake app-server script: `.cmd` on Windows, /bin/sh
/// elsewhere), both Claude response shapes, the expiring-token skip and 401 handling (a stub handler, no network), the poll
/// cadence, and which value the limit row shows with which label. Temp folders only.
public static class LiveLimitChecks
{
    const string Read = "<read>";

    sealed class Stub(Func<HttpResponseMessage> answer) : HttpMessageHandler
    {
        public readonly List<HttpRequestMessage> Requests = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Requests.Add(request);
            return Task.FromResult(answer());
        }
    }

    public static List<string> Run()
    {
        var c = new Check("Live limits", "Live limits: ");
        void check(bool valid, string description) => c.That(valid, description);
        var folder = Directory.CreateTempSubdirectory("tokencat-live-limits-");
        try
        {
            Codex(folder.FullName, check);
            Claude(folder.FullName, check);
        }
        finally { folder.Delete(true); }
        Rows(check);
        return c.Done();
    }

    /// A script that prints each line and reads one stdin line at each `Read`.
    static string FakeAppServer(string folder, string name, params string[] steps)
    {
        var windows = OperatingSystem.IsWindows();
        var path = Path.Combine(folder, name + (windows ? ".cmd" : ".sh"));
        var lines = steps.Select(step => step == Read ? (windows ? "set /p line=" : "read -r line") : windows ? "echo " + step : $"printf '%s\\n' '{step}'");
        File.WriteAllText(path, string.Join(windows ? "\r\n" : "\n", [windows ? "@echo off" : "#!/bin/sh", .. lines]) + "\n");
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return path;
    }

    static void Codex(string folder, Action<bool, string> check)
    {
        LiveLimitResult Run(string path, double timeout = 10) =>
            LiveLimits.ReadCodex(path, "0.0.0", TimeSpan.FromSeconds(timeout), CancellationToken.None).GetAwaiter().GetResult();
        // Notifications before and between the answers, a server request reusing id 2 and a non-JSON line are all skipped.
        var talkative = FakeAppServer(folder, "talkative",
            """{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{"status":"off"}}""", Read,
            """{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}""", Read,
            """{"jsonrpc":"2.0","method":"account/updated","params":{"authMode":"chatgpt"}}""",
            """{"jsonrpc":"2.0","id":2,"method":"item/tool/requestUserInput","params":{}}""",
            "not json",
            """{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1791580427},"secondary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1791500000},"credits":{"hasCredits":false},"planType":"pro","rateLimitReachedType":null}}}""");
        var before = DateTimeOffset.UtcNow;
        var read = Run(talkative);
        check(!read.Failed && read.Codex is [{ UsedPercent: 31, WindowMinutes: 10_080 } weekly, { UsedPercent: 12.5, WindowMinutes: 300 }]
              && weekly.ResetsAt == DateTimeOffset.FromUnixTimeSeconds(1_791_580_427) && weekly.RecordedAt >= before,
              "codex app-server windows are not read past interleaved notifications and a server request with the same id");
        var refused = FakeAppServer(folder, "refused", Read, """{"jsonrpc":"2.0","id":1,"result":{}}""", Read,
            """{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"not signed in"}}""");
        var other = FakeAppServer(folder, "other", Read, """{"jsonrpc":"2.0","id":1,"result":{}}""", Read,
            """{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"other","primary":{"usedPercent":90}}}}""");
        check(Run(refused) is { Failed: true, Codex: null } && Run(other) is { Failed: true, Codex: null }
              && Run(Path.Combine(folder, "missing")) is { Failed: true }, "a JSON-RPC error, another limit or a missing executable reads as an answer");
        // Never answers: ended at the timeout instead of waiting for it.
        var silent = FakeAppServer(folder, "silent", Read, Read, Read);
        var watch = Stopwatch.StartNew();
        check(Run(silent, timeout: 1) is { Failed: true } && watch.Elapsed < TimeSpan.FromSeconds(6), "a silent app-server is not ended at the timeout");
    }

    static void Claude(string folder, Action<bool, string> check)
    {
        var at = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        // Claude Code's schema: session → 5-hour, weekly_all → 7-day, weekly_scoped ignored, resets_at ISO 8601 or null.
        var current = LiveLimits.DecodeClaude("""
            {"limits":[{"kind":"weekly_scoped","group":"weekly","percent":99,"resets_at":"2026-10-08T00:00:00Z","scope":{"model":{"display_name":"Opus"}},"severity":"warning","is_active":true},
            {"kind":"session","group":"session","percent":42,"resets_at":"2026-10-06T17:13:30.5+00:00","scope":null,"severity":"normal","is_active":true},
            {"kind":"weekly_all","group":"weekly","percent":31,"resets_at":null,"scope":null,"severity":"normal","is_active":true}],"extra_usage":{"is_enabled":false}}
            """u8, at);
        var older = LiveLimits.DecodeClaude("""{"five_hour":{"utilization":7.5,"resets_at":"2026-10-06T18:00:00Z"},"seven_day":{"utilization":64,"resets_at":"2026-10-10T09:00:00Z"}}"""u8, at);
        check(current?.FiveHour is { UsedPercent: 42, Live: true } fiveHour && fiveHour.ResetsAt == new DateTimeOffset(2026, 10, 6, 17, 13, 30, 500, TimeSpan.Zero)
              && fiveHour.ReceivedAt == at && current.SevenDay is { UsedPercent: 31, ResetsAt: null, Live: true }
              && older?.FiveHour is { UsedPercent: 7.5 } && older.SevenDay?.ResetsAt == new DateTimeOffset(2026, 10, 10, 9, 0, 0, TimeSpan.Zero)
              && LiveLimits.DecodeClaude("""{"limits":[{"kind":"weekly_scoped","percent":99}]}"""u8, at) == null && LiveLimits.DecodeClaude("[]"u8, at) == null,
              "Claude usage is not read from both response shapes, or a scoped limit becomes a row");

        // The reader with Claude Code's credentials file: skipped while the token expires within a minute, then a 401 parks
        // that token until another is stored.
        var status = HttpStatusCode.OK;
        var stub = new Stub(() => new HttpResponseMessage(status)
            { Content = new StringContent("""{"limits":[{"kind":"session","percent":55,"resets_at":"2026-10-06T18:00:00Z"}]}""") });
        var reader = new LiveLimits(folder, "0.0.0", stub);
        var credentials = Path.Combine(folder, ".claude", ".credentials.json");
        Directory.CreateDirectory(Path.GetDirectoryName(credentials)!);
        void Store(string token, double expiresIn) => File.WriteAllText(credentials,
            $$$"""{"claudeAiOauth":{"accessToken":"{{{token}}}","refreshToken":"r","expiresAt":{{{DateTimeOffset.UtcNow.AddSeconds(expiresIn).ToUnixTimeMilliseconds()}}}}}""");
        LiveLimitResult Claude() => reader.ReadClaude(CancellationToken.None).GetAwaiter().GetResult();
        Store("t1", 30);
        var expiring = Claude();
        Store("t1", 3_600);
        var answered = Claude();
        var request = stub.Requests.LastOrDefault();
        check(expiring is { Claude: null, Failed: false } && stub.Requests.Count == 1 && answered.Claude?.FiveHour is { UsedPercent: 55, Live: true }
              && request?.RequestUri == LiveLimits.ClaudeEndpoint && request.Method == HttpMethod.Get
              && request.Headers.Authorization?.ToString() == "Bearer t1" && request.Headers.GetValues("anthropic-beta").Single() == "oauth-2025-04-20"
              && request.Headers.UserAgent.ToString() == "TokenCat/0.0.0",
              "an expiring Claude token is sent, or the usage request isn't the documented GET");
        status = HttpStatusCode.Unauthorized;
        var refused = Claude();
        var parked = Claude();
        Store("t2", 3_600);
        status = HttpStatusCode.TooManyRequests;
        var limited = Claude();
        check(refused is { Claude: null, Failed: false } && parked is { Claude: null, Failed: false } && limited.Failed && stub.Requests.Count == 3
              && stub.Requests[^1].Headers.Authorization?.ToString() == "Bearer t2",
              "a token refused with 401 is sent again before Claude Code stores another, or 429 doesn't back off");
        // No expiry counts as expired; 403 parks the token like 401.
        File.WriteAllText(credentials, """{"claudeAiOauth":{"accessToken":"t3"}}""");
        status = HttpStatusCode.Forbidden;
        var undated = Claude();
        Store("t4", 3_600);
        var forbidden = Claude();
        var forbiddenAgain = Claude();
        check(undated is { Claude: null, Failed: false } && forbidden is { Claude: null, Failed: false } && forbiddenAgain is { Claude: null, Failed: false }
              && stub.Requests.Count == 4, "a token without an expiry is sent, or one refused with 403 is sent again");
        File.Delete(credentials);
        check(Claude() is { Claude: null, Failed: false } && stub.Requests.Count == 4, "no Claude sign-in still sends a request");
        // omp's and Pi's saved Anthropic sign-in: read from agent.db, offered after Claude Code's, only for Claude Code's account.
        var agentDb = Path.Combine(folder, ".omp", "agent", "agent.db");
        Directory.CreateDirectory(Path.GetDirectoryName(agentDb)!);
        var expiry = DateTimeOffset.UtcNow.AddSeconds(3_600).ToUnixTimeMilliseconds();
        using (var database = OpenCodeDatabase.Open(agentDb, create: true))
        {
            database?.Query("CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT)", [], _ => { });
            foreach (var (data, cause) in new (string, string?)[]
            {
                ($$"""{"access":"omp-token","refresh":"r","expires":{{expiry}},"accountId":"acct-a","email":"PRIVATE"}""", null),
                ($$"""{"access":"disabled-token","expires":{{expiry}},"accountId":"acct-a"}""", "revoked"),
            })
                database?.Query("INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause) VALUES ('anthropic', 'oauth', ?, ?)", [data, cause], _ => { });
        }
        var agents = LiveLimits.AgentCredentials([agentDb, Path.Combine(folder, "missing", "agent.db")]);
        File.WriteAllText(Path.Combine(folder, ".claude.json"), """{"oauthAccount":{"accountUuid":"acct-a"}}""");
        Store("cc-expired", -10);
        status = HttpStatusCode.OK;
        var fallback = Claude();
        check(agents.Select(agent => agent.Access).SequenceEqual(["omp-token"]) && agents[0].Account == "acct-a"
              && fallback.Claude is not null && stub.Requests[^1].Headers.Authorization?.ToString() == "Bearer omp-token"
              && LiveLimits.ClaudeCandidates(("cc", 1), agents, "acct-b").Select(candidate => candidate.Access).SequenceEqual(["cc"])
              && LiveLimits.ClaudeCandidates(null, agents, null).Select(candidate => candidate.Access).SequenceEqual(["omp-token"]),
              "omp's or Pi's Anthropic sign-in is not used when Claude Code's has expired, or is used for another account");
    }

    static void Rows(Action<bool, string> check)
    {
        // Cadence: 60 s while active, 10 min idle, a dashboard that opens after 15 s, failures doubling to 30 min.
        check(LiveLimits.Due(null, 0, false, false) && !LiveLimits.Due(59, 0, true, false) && LiveLimits.Due(60, 0, true, false)
              && !LiveLimits.Due(599, 0, false, false) && LiveLimits.Due(600, 0, false, false)
              && !LiveLimits.Due(14, 0, false, true) && LiveLimits.Due(15, 0, false, true) && !LiveLimits.Due(15, 1, false, true)
              && !LiveLimits.Due(119, 1, true, false) && LiveLimits.Due(120, 1, true, false)
              && !LiveLimits.Due(1_799, 9, true, false) && LiveLimits.Due(1_800, 30, false, false),
              "live limit polls don't follow 60 s active / 10 min idle / 15 s on open / doubling backoff");

        var now = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        DateTimeOffset at(double seconds) => now.AddSeconds(seconds);
        var reset = at(2 * 3_600 + 13 * 60 + 30);
        // Codex: the poll overrides older log records of its window (even higher ones); a later record of the same value keeps
        // "실시간", a higher one wins with its age.
        TokenReading Log(double percent, double recorded) => new(TokenSource.Codex) { RateLimit = new TokenRateLimit(percent, 300, reset, at(recorded)) };
        TokenRateLimit[] polled = [new(42, 300, reset, at(-10)) { Live = true }, new(31, 10_080, at(3 * 86_400), at(-10)) { Live = true }];
        var live = SessionPresentation.UsageLimit([Log(45, -300)], now, polled);
        var repeated = SessionPresentation.UsageLimit([Log(42, -5)], now, polled);
        var higher = SessionPresentation.UsageLimit([Log(44, -5)], now, polled);
        var staleTie = SessionPresentation.UsageLimit([Log(42, -5)], now, [polled[0] with { RecordedAt = at(-300) }]);
        check(live is { UsedPercent: 42, Live: true, WindowMinutes: 300 } && live.Details(now).SequenceEqual(["2시간 13분 후 초기화 · 실시간", "2시간 13분 후 초기화"])
              && live.Spoken(now) == "42퍼센트 사용, 2시간 13분 후 초기화, 실시간, 주간 한도 31퍼센트 사용, 3일 후 초기화"
              && live.ShortTitle == "Codex · 5시간" && live.OtherSummary(now) is { UsedPercent: 31, WindowMinutes: 10_080, Live: true, Source: TokenSource.Codex } weekly
              && weekly.ShortTitle == "Codex · 주간" && weekly.RecordedAt == at(-10) && weekly.Details(now)[0] == "3일 후 초기화 · 실시간"
              && live.OtherSummary(at(3 * 86_400)) == null
              && repeated is { UsedPercent: 42, Live: true } && higher is { UsedPercent: 44, Live: false } && higher.Details(now)[0] == "2시간 13분 후 초기화 · 1분 이내 기록"
              && staleTie is { Live: false } && staleTie.Details(now)[0] == "2시간 13분 후 초기화 · 1분 이내 기록"
              && SessionPresentation.UsageLimit([], now, []) == null && SessionPresentation.UsageLimit([Log(45, -300)], now) is { UsedPercent: 45, Live: false },
              "a live Codex poll doesn't override older records of its window, loses a tie to a later record while fresh (or wins it when stale), or beats a higher one; or the other live window isn't its own row");
        // After 2 minutes the same value reads as a record again; values from logs never say "실시간".
        check(live is not null && live.Details(at(110)).SequenceEqual(["2시간 11분 후 초기화 · 2분 전 기록", "2시간 11분 후 초기화"])
              && new UsageLimitSummary(20, 300, reset, at(-300)).Details(now)[0] == "2시간 13분 후 초기화 · 5분 전 기록"
              && live.Help(now).StartsWith("Codex에 저장된 로그인으로 OpenAI", StringComparison.Ordinal)
              && Lang.With(AppLanguage.En, () => live.Details(now)[0]) == "Resets in 2h 13m · live",
              "the live label outlasts 2 minutes, or a logged value is labelled live");

        // Claude: per window the newer receipt wins, except that a record repeating a live poll within 2 minutes keeps it.
        var bridge = new ClaudeUsageLimits(new ClaudeLimitWindow(40, reset, at(-300)), new ClaudeLimitWindow(30, at(86_400), at(-300)));
        var poll = new ClaudeUsageLimits(new ClaudeLimitWindow(42, reset, at(-10)) { Live = true }, new ClaudeLimitWindow(31, at(86_400), at(-10)) { Live = true });
        var shown = SessionPresentation.ClaudeUsageLimit(ClaudeUsage.Merged(bridge, poll), now);
        var bridgedLater = SessionPresentation.ClaudeUsageLimit(ClaudeUsage.Merged(poll, bridge with { FiveHour = bridge.FiveHour! with { UsedPercent = 43, ReceivedAt = at(-5) } }), now);
        var echoed = ClaudeUsage.Merged(poll, new ClaudeUsageLimits(new ClaudeLimitWindow(42, reset, at(-5)), new ClaudeLimitWindow(31, null, at(-5))));
        var noReset = SessionPresentation.ClaudeUsageLimit(new ClaudeUsageLimits(SevenDay: new ClaudeLimitWindow(31, null, at(-10)) { Live = true }), now);
        check(shown is { UsedPercent: 42, Live: true, Source: TokenSource.Claude } && shown.Details(now)[0] == "2시간 13분 후 초기화 · 실시간"
              && bridgedLater is { UsedPercent: 43, Live: false } && bridgedLater.Details(now)[0] == "2시간 13분 후 초기화 · 1분 이내 기록"
              && echoed == poll && ClaudeUsage.Merged(poll, new ClaudeUsageLimits(new ClaudeLimitWindow(42, reset, at(115)))).FiveHour is { Live: false }
              && noReset is { ResetsAt: null } && noReset.Details(now).SequenceEqual(["실시간"])
              && System.Text.Json.JsonSerializer.Serialize(poll, Json.Options) is var stored && !stored.Contains("live", StringComparison.OrdinalIgnoreCase),
              "a fresher Claude source doesn't win per window, an equal record ends 실시간 early, a live label is invented, or the live mark is stored");
    }
}
