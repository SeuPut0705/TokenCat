namespace TokenCat;

/// Numeric subscription windows from omp/Pi, independently attributed to every canonical account.
/// Identity metadata remains in memory; Claude persistence stores only one-way account hashes.
public static class AgentUsageHistory
{
    public sealed record Row(string Provider, string Account, string? AccountId, string LimitId, string? WindowLabel,
                             double UsedFraction, DateTimeOffset RecordedAt, DateTimeOffset? ResetsAt, string? Email = null);

    public sealed record Limits(IReadOnlyDictionary<string, ClaudeUsageLimits> Claude, IReadOnlyList<TokenRateLimit> Codex,
                               IReadOnlyDictionary<TokenSource, IReadOnlyList<LimitAccount>> Accounts)
    {
        public static Limits Empty { get; } = new(new Dictionary<string, ClaudeUsageLimits>(), [], new Dictionary<TokenSource, IReadOnlyList<LimitAccount>>());
    }

    public static IReadOnlyList<string> Databases(string home, Func<string, string?> env)
    {
        var seen = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        var overrideRoot = TokenProvider.EnvPath(home, env, "PI_CODING_AGENT_SESSION_DIR");
        var agentFolders = TokenProvider.All.First(provider => provider.Source == TokenSource.Omp).Roots(home, env)
            .Select(root => overrideRoot is not null && string.Equals(Path.GetFullPath(root), Path.GetFullPath(overrideRoot),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)
                ? TokenProvider.EnvPath(home, env, "PI_CODING_AGENT_DIR") ?? Path.Combine(home, ".pi", "agent")
                : Path.GetDirectoryName(Path.GetFullPath(root))!)
            .Concat(new[] { Path.Combine(home, ".omp", "agent"), Path.Combine(home, ".pi", "agent") });
        return [.. agentFolders.Select(folder => Path.GetFullPath(Path.Combine(folder, "agent.db"))).Where(seen.Add)];
    }

    public static string Recorder(string database) =>
        database.Replace('\\', '/').Contains("/.pi/agent/", StringComparison.OrdinalIgnoreCase) ? "Pi" : "omp";

    public static int? WindowMinutes(string? label)
    {
        var words = (label ?? "").ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length != 2 || !int.TryParse(words[0], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var count)
            || count <= 0) return null;
        return words[1] switch
        {
            "hour" or "hours" when count <= int.MaxValue / 60 => count * 60,
            "day" or "days" when count <= int.MaxValue / 1_440 => count * 1_440,
            _ => null,
        };
    }

    const string Query = """
        SELECT provider, account_key, account_id, limit_id, window_label, used_fraction, max(recorded_at), resets_at, email FROM usage_history
        WHERE provider IN ('anthropic', 'openai-codex') AND used_fraction IS NOT NULL GROUP BY provider, account_key, account_id, email, limit_id
        """;

    public static IReadOnlyList<Row>? Rows(string database)
    {
        using var connection = OpenCodeDatabase.Open(database);
        if (connection is null) return null;
        var rows = new List<Row>();
        var read = connection.Query(Query, [], row =>
        {
            if (row.Text(0) is not { } provider || row.Text(1) is not { } account || row.Text(3) is not { } limit
                || row.Double(5) is not { } used || row.Date(6) is not { } recorded) return;
            rows.Add(new(provider, account, row.Text(2), limit, row.Text(4), used, recorded, row.Date(7), row.Text(8)));
        });
        return read ? rows : null;
    }

    public static Limits FromRows(IReadOnlyList<Row> rows, LimitAccountReader accounts, string recorder)
    {
        IReadOnlyDictionary<string, ClaudeUsageLimits> claude = new Dictionary<string, ClaudeUsageLimits>();
        var codex = new List<TokenRateLimit>();
        var known = new Dictionary<TokenSource, List<LimitAccount>>();
        void Remember(TokenSource provider, LimitAccount? account)
        {
            if (account is null) return;
            if (!known.TryGetValue(provider, out var list)) known[provider] = list = [];
            if (!list.Contains(account)) list.Add(account);
        }
        foreach (var row in rows)
        {
            if (!double.IsFinite(row.UsedFraction) || row.UsedFraction is < 0 or > 10) continue;
            if (row.Provider == "anthropic" && row.LimitId is "anthropic:5h" or "anthropic:7d")
            {
                var account = accounts.Resolve(TokenSource.Claude, row.AccountId, row.Email);
                Remember(TokenSource.Claude, account);
                var window = new ClaudeLimitWindow(row.UsedFraction * 100, row.ResetsAt, row.RecordedAt) { RecordedBy = recorder };
                claude = ClaudeLimitsByAccount.Merge(claude, row.LimitId == "anthropic:5h" ? new(FiveHour: window) : new(SevenDay: window), account);
            }
            else if (row.Provider == "openai-codex" && row.LimitId is "openai-codex:primary" or "openai-codex:secondary")
            {
                var account = accounts.Resolve(TokenSource.Codex, row.AccountId, row.Email);
                Remember(TokenSource.Codex, account);
                codex.Add(new(row.UsedFraction * 100, WindowMinutes(row.WindowLabel), row.ResetsAt, row.RecordedAt) { RecordedBy = recorder, Account = account });
            }
        }
        codex.Sort((a, b) => (a.WindowMinutes ?? 0).CompareTo(b.WindowMinutes ?? 0));
        return new(claude, codex, known.ToDictionary(pair => pair.Key, pair => (IReadOnlyList<LimitAccount>)pair.Value));
    }
}

/// Database and WAL signatures cache numeric rows, while refreshed credential metadata resolves missing emails each read.
public sealed class AgentUsageHistoryReader
{
    public const int MaximumConfigBytes = 16 << 20;
    readonly IReadOnlyList<string> databases;
    readonly LimitAccountReader accounts;
    readonly Dictionary<string, (long[] Stamp, IReadOnlyList<AgentUsageHistory.Row> Rows)> cache = [];

    public AgentUsageHistoryReader(string home, Func<string, string?> env)
    {
        databases = AgentUsageHistory.Databases(home, env);
        accounts = new(home, env);
    }

    public AgentUsageHistory.Limits Read()
    {
        accounts.Refresh();
        IReadOnlyDictionary<string, ClaudeUsageLimits> claude = new Dictionary<string, ClaudeUsageLimits>();
        var codex = new List<TokenRateLimit>();
        var identities = new Dictionary<TokenSource, List<LimitAccount>>();
        foreach (var database in databases)
        {
            if (OpenCodeDatabase.Signature(database) is not { } stamp) { cache.Remove(database); continue; }
            if (!cache.TryGetValue(database, out var known) || !known.Stamp.SequenceEqual(stamp))
            {
                if (AgentUsageHistory.Rows(database) is not { } rows) continue;
                cache[database] = known = (stamp, rows);
            }
            var limits = AgentUsageHistory.FromRows(known.Rows, accounts, AgentUsageHistory.Recorder(database));
            claude = ClaudeLimitsByAccount.Merged(claude, limits.Claude);
            codex.AddRange(limits.Codex);
            foreach (var (provider, members) in limits.Accounts)
            {
                if (!identities.TryGetValue(provider, out var list)) identities[provider] = list = [];
                foreach (var member in members) if (!list.Contains(member)) list.Add(member);
            }
        }
        return new(claude, codex, identities.ToDictionary(pair => pair.Key, pair => (IReadOnlyList<LimitAccount>)pair.Value));
    }
}
