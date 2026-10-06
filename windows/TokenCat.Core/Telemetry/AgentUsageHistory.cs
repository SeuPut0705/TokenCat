using System.Text.Json;

namespace TokenCat;

/// omp and Pi save every subscription usage check they make (their own Claude and ChatGPT sign-ins) as rows of
/// `usage_history` in `<agent folder>\agent.db`: `recorded_at` ms, `provider`, `account_key`, `account_id`, `limit_id`,
/// `window_label`, `used_fraction` 0–1, `resets_at` ms. The newest row per window is read as a record, never as live:
/// `anthropic:5h`/`anthropic:7d` → Claude's 5-hour and 7-day windows, `openai-codex:primary`/`:secondary` → Codex's windows
/// (length from `window_label`). Model-scoped weeks (`anthropic:7d:<model>`) and extra Codex meters (`openai-codex:<slug>:…`)
/// are left out. Only numbers and times leave the read; e-mail, account ids and labels are never kept.
/// Mirrors the mac's AgentUsageHistory.swift.
public static class AgentUsageHistory
{
    public sealed record Row(string Provider, string Account, string? AccountId, string LimitId, string? WindowLabel,
                             double UsedFraction, DateTimeOffset RecordedAt, DateTimeOffset? ResetsAt);

    public sealed record Limits(ClaudeUsageLimits Claude, IReadOnlyList<TokenRateLimit> Codex)
    {
        public static Limits Empty { get; } = new(ClaudeUsageLimits.Empty, []);
    }

    /// The same agent folders the omp provider reads: `PI_CODING_AGENT_DIR`, ~\.omp\agent and ~\.pi\agent.
    public static IReadOnlyList<string> Databases(string home, Func<string, string?> env)
    {
        var seen = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        return [.. new[] { TokenProvider.EnvPath(home, env, "PI_CODING_AGENT_DIR"), Path.Combine(home, ".omp", "agent"), Path.Combine(home, ".pi", "agent") }
            .OfType<string>().Select(folder => Path.GetFullPath(Path.Combine(folder, "agent.db"))).Where(seen.Add)];
    }

    /// The client named as the record's source, as `OmpLog` names its sessions.
    public static string Recorder(string database) =>
        database.Replace('\\', '/').Contains("/.pi/agent/", StringComparison.OrdinalIgnoreCase) ? "Pi" : "omp";

    /// "5 Hour", "7 Day", "7 days", "5 hours" (omp's labels) → minutes; null for any other label.
    public static int? WindowMinutes(string? label)
    {
        var words = (label ?? "").ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length != 2 || !int.TryParse(words[0], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var count)
            || count <= 0) return null;
        return words[1] switch
        {
            "hour" or "hours" => count * 60,
            "day" or "days" => count * 1_440,
            _ => null,
        };
    }

    const string Query = """
        SELECT provider, account_key, account_id, limit_id, window_label, used_fraction, max(recorded_at), resets_at FROM usage_history
        WHERE provider IN ('anthropic', 'openai-codex') AND used_fraction IS NOT NULL GROUP BY provider, account_key, limit_id
        """;

    /// The newest row per account and window; null when the database or table cannot be read.
    public static IReadOnlyList<Row>? Rows(string database)
    {
        using var connection = OpenCodeDatabase.Open(database);
        if (connection is null) return null;
        var rows = new List<Row>();
        var read = connection.Query(Query, [], row =>
        {
            if (row.Text(0) is not { } provider || row.Text(1) is not { } account || row.Text(3) is not { } limit
                || row.Double(5) is not { } used || row.Date(6) is not { } recorded) return;
            rows.Add(new Row(provider, account, row.Text(2), limit, row.Text(4), used, recorded, row.Date(7)));
        });
        return read ? rows : null;
    }

    /// One account per provider, the one checked last. omp's Anthropic rows are left out when they name an account other than
    /// Claude Code's (`claudeAccount`, its signed-in `accountUuid`): those limits belong to another subscription.
    public static Limits FromRows(IReadOnlyList<Row> rows, string? claudeAccount, string recorder)
    {
        List<Row> NewestAccount(string provider, string[] ids, Func<Row, bool>? accepts = null)
        {
            var usable = rows.Where(row => row.Provider == provider && ids.Contains(row.LimitId) && double.IsFinite(row.UsedFraction)
                && row.UsedFraction is >= 0 and <= 10 && (accepts?.Invoke(row) ?? true)).ToList();
            if (usable.MaxBy(row => row.RecordedAt) is not { } newest) return [];
            return [.. usable.Where(row => row.Account == newest.Account)];
        }
        var claudeRows = NewestAccount("anthropic", ["anthropic:5h", "anthropic:7d"],
            row => claudeAccount is null || row.AccountId is null || row.AccountId == claudeAccount);
        ClaudeLimitWindow? Claude(string id) => claudeRows.FirstOrDefault(row => row.LimitId == id) is { } row
            ? new ClaudeLimitWindow(row.UsedFraction * 100, row.ResetsAt, row.RecordedAt) { RecordedBy = recorder } : null;
        var codex = NewestAccount("openai-codex", ["openai-codex:primary", "openai-codex:secondary"])
            .Select(row => new TokenRateLimit(row.UsedFraction * 100, WindowMinutes(row.WindowLabel), row.ResetsAt, row.RecordedAt) { RecordedBy = recorder })
            .OrderBy(limit => limit.WindowMinutes ?? 0).ToList();
        return new Limits(new ClaudeUsageLimits(Claude("anthropic:5h"), Claude("anthropic:7d")), codex);
    }

    /// Claude Code's signed-in account (`oauthAccount.accountUuid` in ~\.claude.json); nothing else in that file is kept.
    public static string? ClaudeAccount(byte[] data)
    {
        try
        {
            using var document = JsonDocument.Parse(data);
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("oauthAccount", out var account) && account.ValueKind == JsonValueKind.Object
                && account.TryGetProperty("accountUuid", out var id) && id.ValueKind == JsonValueKind.String && id.GetString() is { Length: > 0 } value
                ? value : null;
        }
        catch (JsonException) { return null; }
    }
}

/// Reads the agent databases on the token sampling path only: each is queried again only when it or its WAL changes
/// (`OpenCodeDatabase.Signature`), and ~\.claude.json only when its size or write time changes.
public sealed class AgentUsageHistoryReader
{
    /// Above this ~\.claude.json is not parsed (it holds per-project history too); the account then counts as unknown.
    public const int MaximumConfigBytes = 16 << 20;

    readonly IReadOnlyList<string> databases;
    readonly string claudeConfig;
    readonly Dictionary<string, (long[] Stamp, IReadOnlyList<AgentUsageHistory.Row> Rows)> cache = [];
    (long Length, DateTime Written)? configStamp;
    string? account;

    public AgentUsageHistoryReader(string home, Func<string, string?> env)
    {
        databases = AgentUsageHistory.Databases(home, env);
        claudeConfig = Path.Combine(home, ".claude.json");
    }

    public AgentUsageHistory.Limits Read()
    {
        var account = ClaudeAccount();
        var claude = ClaudeUsageLimits.Empty;
        var codex = new List<TokenRateLimit>();
        foreach (var database in databases)
        {
            if (OpenCodeDatabase.Signature(database) is not { } stamp) { cache.Remove(database); continue; }
            if (!cache.TryGetValue(database, out var known) || !known.Stamp.SequenceEqual(stamp))
            {
                // A refused read (a write in progress past the busy timeout) is tried again on the next sample.
                if (AgentUsageHistory.Rows(database) is not { } rows) continue;
                cache[database] = known = (stamp, rows);
            }
            var limits = AgentUsageHistory.FromRows(known.Rows, account, AgentUsageHistory.Recorder(database));
            claude = ClaudeUsage.Merged(claude, limits.Claude);
            codex.AddRange(limits.Codex);
        }
        return new AgentUsageHistory.Limits(claude, codex);
    }

    string? ClaudeAccount()
    {
        var info = new FileInfo(claudeConfig);
        if (!info.Exists || info.Length > MaximumConfigBytes) { (configStamp, account) = (null, null); return null; }
        var stamp = (info.Length, info.LastWriteTimeUtc);
        if (stamp == configStamp) return account;
        configStamp = stamp;
        try
        {
            using var stream = new FileStream(claudeConfig, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var bytes = new MemoryStream();
            stream.CopyTo(bytes);
            account = AgentUsageHistory.ClaudeAccount(bytes.ToArray());
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { account = null; }
        return account;
    }
}
