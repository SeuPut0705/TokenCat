using System.Globalization;

namespace TokenCat;

/// omp's and Pi's usage history (synthetic rows, no e-mail kept): the window mapping, Claude Code's account gate, WAL
/// writes picked up, the merge with live reads and records, the "omp" labels, and the model → subscription cadence.
/// Mirrors the mac's AgentUsageHistoryChecks.swift. Temp folders only.
public static class AgentUsageHistoryChecks
{
    public static List<string> Run()
    {
        var c = new Check("Agent usage history", "Live limits: ");
        void check(bool valid, string description) => c.That(valid, description);
        var folder = Directory.CreateTempSubdirectory("tokencat-agent-usage-");
        try { Checks(folder.FullName, check); }
        finally { folder.Delete(true); }
        return c.Done();
    }

    static void Checks(string folder, Action<bool, string> check)
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        DateTimeOffset at(double seconds) => now.AddSeconds(seconds);
        long ms(double seconds) => at(seconds).ToUnixTimeMilliseconds();

        check(AgentUsageHistory.WindowMinutes("5 Hour") == 300 && AgentUsageHistory.WindowMinutes("7 Day") == 10_080
              && AgentUsageHistory.WindowMinutes("7 days") == 10_080 && AgentUsageHistory.WindowMinutes("1 hour") == 60
              && AgentUsageHistory.WindowMinutes("Primary window") == null && AgentUsageHistory.WindowMinutes(null) == null,
              "omp window labels are not turned into minutes");
        check(TokenSource.LimitProvider("claude-opus-5-5") == TokenSource.Claude && TokenSource.LimitProvider("anthropic/claude-sonnet-5") == TokenSource.Claude
              && TokenSource.LimitProvider("gpt-6.1-sol") == TokenSource.Codex && TokenSource.LimitProvider("openai-codex/gpt-5.5") == TokenSource.Codex
              && TokenSource.LimitProvider("o3") == TokenSource.Codex && TokenSource.LimitProvider("gemini-3-pro") == null
              && TokenSource.LimitProvider("glm-4.6") == null && TokenSource.LimitProvider(null) == null,
              "a model is not mapped to the subscription it uses");

        // Cadence: an omp session running a Claude model makes Claude active; an idle one on GPT does not make Codex active.
        TokenReading Session(string id, TokenSource source, string model, bool running) => new(source, id)
        {
            SessionID = id, Project = "demo", Model = model, Active = running, LastActivity = at(-2),
            ActivityState = running ? TokenActivityState.Working : TokenActivityState.Complete, SampledAt = now,
        };
        var counts = new SessionCounts(SessionPresentation.Groups([Session("omp:a", TokenSource.Omp, "claude-opus-5-5", true),
                                                                   Session("omp:b", TokenSource.Omp, "gpt-6.1-sol", false)], now));
        var codexOnly = new SessionCounts(SessionPresentation.Groups([Session("codex:c", TokenSource.Codex, "unknown-model", true)], now));
        check(counts.LimitSources.SetEquals([TokenSource.Claude]) && codexOnly.LimitSources.SetEquals([TokenSource.Codex])
              && counts.Running.GetValueOrDefault(TokenSource.Omp) == 1,
              $"a running session on a Claude or OpenAI model does not make that subscription active ({string.Join(",", counts.LimitSources)})");

        // A WAL-mode agent.db written while TokenCat reads it.
        var home = Path.Combine(folder, "agent-home");
        var agent = Path.Combine(home, ".omp", "agent");
        Directory.CreateDirectory(agent);
        var path = Path.Combine(agent, "agent.db");
        using var database = OpenCodeDatabase.Open(path, create: true);
        if (database is null)
        {
            check(false, "omp usage fixture: database not created");
            return;
        }
        var failed = false;
        void Row(string provider, string account, string? accountId, string limit, string? label, double? used, double recorded, double? reset) =>
            failed |= !database.Query(
                "INSERT INTO usage_history (recorded_at, provider, account_key, email, account_id, limit_id, label, window_label, used_fraction, status, resets_at) "
                + $"VALUES (?, ?, ?, 'person@example.com', ?, ?, 'label', ?, {(used is { } value ? value.ToString("R", CultureInfo.InvariantCulture) : "NULL")}, 'ok', ?)",
                [ms(recorded), provider, account, accountId, limit, label, reset is { } r ? ms(r) : null], _ => { });
        failed |= !database.Query("PRAGMA journal_mode=WAL", [], _ => { });
        failed |= !database.Execute("""
            CREATE TABLE usage_history (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at INTEGER NOT NULL, provider TEXT NOT NULL,
                account_key TEXT NOT NULL, email TEXT, account_id TEXT, limit_id TEXT NOT NULL, label TEXT NOT NULL, window_label TEXT,
                used_fraction REAL, status TEXT, resets_at INTEGER)
            """);
        Row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", 0.13, -3_600, 600);
        Row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", 0.04, -240, 15_000);
        Row("anthropic", "account:a", "acct-a", "anthropic:7d", "7 Day", 0.02, -240, 500_000);
        Row("anthropic", "account:a", "acct-a", "anthropic:7d:fable", "7 Day", 0.9, -240, 500_000);
        Row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", null, -100, 15_000);
        Row("anthropic", "account:b", "acct-b", "anthropic:5h", "5 Hour", 0.77, -60, 9_000);
        Row("openai-codex", "account:c", "acct-c", "openai-codex:primary", "7 days", 0.47, -180, 300_000);
        Row("openai-codex", "account:c", "acct-c", "openai-codex:spark:primary", "5 hours", 0.99, -180, 9_000);
        Row("google", "account:d", null, "google:daily", "Daily", 0.5, -10, 9_000);
        check(!failed, "omp usage fixture rows were not written");

        var rows = AgentUsageHistory.Rows(path) ?? [];
        var mine = AgentUsageHistory.FromRows(rows, "acct-a", "omp");
        var newest = AgentUsageHistory.FromRows(rows, null, "omp");
        check(rows.Count == 6 && !rows.Any(row => row.Provider == "google")
              && mine.Claude == new ClaudeUsageLimits(new ClaudeLimitWindow(4, at(15_000), at(-240)) { RecordedBy = "omp" },
                                                      new ClaudeLimitWindow(2, at(500_000), at(-240)) { RecordedBy = "omp" })
              && newest.Claude.FiveHour?.UsedPercent == 77 && newest.Claude.SevenDay is null
              && AgentUsageHistory.FromRows(rows, "acct-x", "omp").Claude.IsEmpty
              && mine.Codex.SequenceEqual([new TokenRateLimit(47, 10_080, at(300_000), at(-180)) { RecordedBy = "omp" }]),
              $"omp usage history: newest row per window, Claude Code's account only, model weeks and extra meters left out ({mine})");

        // The reader: Claude Code's account from ~\.claude.json, Pi named by its folder, a WAL write picked up without a checkpoint.
        File.WriteAllText(Path.Combine(home, ".claude.json"),
            """{"projects":{"/tmp/x":{"history":[]}},"oauthAccount":{"accountUuid":"acct-a","emailAddress":"person@example.com"}}""");
        var reader = new AgentUsageHistoryReader(home, _ => null);
        var first = reader.Read();
        Row("anthropic", "account:a", "acct-a", "anthropic:5h", "5 Hour", 0.06, -30, 15_000);
        var second = reader.Read();
        check(first.Claude.FiveHour?.UsedPercent == 4 && second.Claude.FiveHour?.UsedPercent == 6 && second.Claude.FiveHour?.ReceivedAt == at(-30)
              && File.Exists(path + "-wal")
              && AgentUsageHistory.Recorder("/Users/x/.pi/agent/agent.db") == "Pi" && AgentUsageHistory.Recorder(@"C:\Users\x\.pi\agent\agent.db") == "Pi"
              && AgentUsageHistory.Recorder(@"C:\Users\x\.omp\agent\agent.db") == "omp"
              && AgentUsageHistory.Databases(home, key => key == "PI_CODING_AGENT_DIR" ? agent : null).Count == 2,
              "the omp usage reader misses a WAL write, the account gate, or Pi's folder");

        // Merge and labels: an omp record is a record, never live; a newer one wins over the bridge, an older one doesn't.
        var bridge = new ClaudeUsageLimits(new ClaudeLimitWindow(3, at(15_000), at(-900)));
        var merged = ClaudeUsage.Merged(bridge, mine.Claude);
        var claude = SessionPresentation.ClaudeUsageLimit(merged, now);
        check(merged.FiveHour?.RecordedBy == "omp"
              && ClaudeUsage.Merged(new ClaudeUsageLimits(new ClaudeLimitWindow(9, at(15_000), at(-10))), mine.Claude).FiveHour?.UsedPercent == 9
              && claude is { Live: false } && claude.Details(now).SequenceEqual(["4시간 10분 후 초기화 · omp 4분 전 기록", "4시간 10분 후 초기화 · 4분 전 기록", "4시간 10분 후 초기화"])
              && claude.Help(now).StartsWith("omp가 자체 사용량 확인으로 기록한 마지막 Claude 계정 사용량입니다.", StringComparison.Ordinal),
              $"an omp Claude record is not merged by recency or not labelled with omp and its age ({string.Join(" | ", claude?.Details(now) ?? [])})");
        var live = new TokenRateLimit(46, 10_080, at(300_000), at(-600)) { Live = true };
        var codex = SessionPresentation.UsageLimit([], now, [live, .. mine.Codex]);
        var olderOmp = SessionPresentation.UsageLimit([], now, [new TokenRateLimit(46, 10_080, at(300_000), at(-20)) { Live = true }, .. mine.Codex]);
        check(codex is { UsedPercent: 47, Live: false, RecordedBy: "omp" } && codex.Details(now)[0] == "3일 11시간 후 초기화 · omp 3분 전 기록"
              && codex.Help(now).Contains("omp", StringComparison.Ordinal) && olderOmp is { UsedPercent: 46, RecordedBy: null } && olderOmp.IsLive(now),
              $"a Codex window from omp does not merge with the live read by recency ({string.Join(" | ", codex?.Details(now) ?? [])})");
        Lang.With(AppLanguage.En, () =>
            check(claude?.Details(now)[0] == "Resets in 4h 10m · omp recorded 4m ago"
                  && claude.Detail(now) == "Resets in 4h 10m · as of omp's record 4m ago",
                  "English omp labels"));
        // The record label persists (numbers, times and "omp" only); the live mark does not.
        var stored = System.Text.Json.JsonSerializer.Serialize(mine.Claude, Json.Options);
        check(System.Text.Json.JsonSerializer.Deserialize<ClaudeUsageLimits>(stored, Json.Options) == mine.Claude && !stored.Contains("acct", StringComparison.Ordinal),
              "an omp Claude record does not keep its recorder across a relaunch");
    }
}
