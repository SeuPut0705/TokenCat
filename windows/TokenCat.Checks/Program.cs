using System.Globalization;
using TokenCat;

// Swift's interpolation and String(format:) ignore the user's locale; culture-specific text names its culture
// (Lang.Culture, ko-KR). The App's Main does the same.
CultureInfo.DefaultThreadCurrentCulture = CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

// dotnet run --project windows/TokenCat.Checks -c Release [-- --diagnose-tokens [home] | -- --telemetry-lifecycle-checks [port] | -- --live-limits]
if (args is ["--diagnose-tokens", .. var home]) return TokenDiagnostics.Run(home is [var path, ..] ? path : AppPaths.Home);
// Read-only: account-scoped live sources and omp/Pi records. Only redacted account suffixes and numeric windows are printed.
if (args is ["--live-limits"])
{
    var accounts = new LimitAccountReader(AppPaths.Home, Environment.GetEnvironmentVariable);
    accounts.Refresh();
    var records = new AgentUsageHistoryReader(AppPaths.Home, Environment.GetEnvironmentVariable).Read();
    var claude = records.Claude;
    var codex = records.Codex.ToList();
    var known = TokenSource.DefaultClients.ToDictionary(provider => provider,
        provider => (IReadOnlyList<LimitAccount>)accounts.KnownAccounts(provider)
            .Concat(records.Accounts.GetValueOrDefault(provider, [])).Distinct().OrderBy(account => account.Key, StringComparer.Ordinal).ToArray());
    var slots = known.SelectMany(pair => pair.Value.Select(account => new LimitSlot(pair.Key, account))).ToHashSet();
    foreach (var provider in TokenSource.DefaultClients)
        if (accounts.DefaultAccount(provider) is { } account) slots.Add(new LimitSlot(provider, account));
    if (claude.ContainsKey(ClaudeLimitsByAccount.LegacyKey)) slots.Add(new LimitSlot(TokenSource.Claude, null));
    if (codex.Any(window => window.Account is null)) slots.Add(new LimitSlot(TokenSource.Codex, null));
    var reader = new LiveLimits(AppPaths.Home, Updater.CurrentVersion, accounts: accounts);
    var received = claude.Count > 0 || codex.Count > 0;
    foreach (var slot in slots.Where(slot => slot.Provider == TokenSource.Claude || slot.Account == accounts.DefaultAccount(TokenSource.Codex)))
    {
        var outcome = await reader.Read(slot, CancellationToken.None);
        received |= outcome.Claude is not null || outcome.Codex is not null;
        if (outcome.Claude is { } limits) claude = ClaudeLimitsByAccount.Merge(claude, limits, slot.Account);
        if (outcome.Codex is { } windows) codex.AddRange(windows);
    }
    foreach (var slot in slots.OrderBy(slot => slot.Provider.Id, StringComparer.Ordinal).ThenBy(slot => slot.Account?.Key, StringComparer.Ordinal))
    {
        var key = slot.Account?.StorageKey ?? ClaudeLimitsByAccount.LegacyKey;
        IReadOnlyDictionary<string, ClaudeUsageLimits> selectedClaude = slot.Provider == TokenSource.Claude && claude.TryGetValue(key, out var limits)
            ? new Dictionary<string, ClaudeUsageLimits> { [key] = limits } : new Dictionary<string, ClaudeUsageLimits>();
        IReadOnlyDictionary<TokenSource, LimitAccount> defaults = slot.Account is { } account
            ? new Dictionary<TokenSource, LimitAccount> { [slot.Provider] = account } : new Dictionary<TokenSource, LimitAccount>();
        var rows = SessionPresentation.UsageLimits([], codex.Where(window => window.Account == slot.Account).ToArray(),
            selectedClaude, defaults, known, DateTimeOffset.UtcNow);
        var label = slot.Account is { } identity ? $"account …{identity.Id[^Math.Min(4, identity.Id.Length)..]}" : "legacy account";
        if (slot.Account is { } member)
        {
            var sameId = known[slot.Provider].Where(account => account.Id == member.Id).ToArray();
            if (sameId.Length > 1) label += $" (member {Array.IndexOf(sameId, member) + 1})";
        }
        static string Window(UsageLimitSummary row) =>
            $"{row.WindowMinutes?.ToString(CultureInfo.InvariantCulture) ?? "?"} min {row.PercentText}% {(row.Live ? "live" : row.RecordedBy is { } by ? by + " record" : "record")}";
        var text = rows.FirstOrDefault() is { } row
            ? Window(row) + (row.OtherSummary(DateTimeOffset.UtcNow) is { } other ? $" ({Window(other)})" : "") : "no window";
        Console.WriteLine($"{slot.Provider.ShortTitle}, {label}: {text}");
    }
    return received ? 0 : 1;
}
if (args is ["--telemetry-lifecycle-checks", .. var port])
    return Suites.Report(TelemetryLifecycleChecks.Run(port is [var text, ..] && int.TryParse(text, out var value) ? value : null));
return Suites.Report(Suites.RunAll());
