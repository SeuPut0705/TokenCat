using System.Globalization;
using TokenCat;

// Swift's interpolation and String(format:) ignore the user's locale; culture-specific text names its culture
// (Lang.Culture, ko-KR). The App's Main does the same.
CultureInfo.DefaultThreadCurrentCulture = CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

// dotnet run --project windows/TokenCat.Checks -c Release [-- --diagnose-tokens [home] | -- --telemetry-lifecycle-checks [port] | -- --live-limits]
if (args is ["--diagnose-tokens", .. var home]) return TokenDiagnostics.Run(home is [var path, ..] ? path : AppPaths.Home);
// Read-only: the real live limit sources (codex on PATH, Claude Code's credentials file) through LiveMonitor with a dashboard
// "open", for up to 15 s. Prints the limit rows only; nothing is written outside a temp folder.
if (args is ["--live-limits"])
{
    var support = Directory.CreateTempSubdirectory("tokencat-live-limits-");
    var monitor = new LiveMonitor(new MonitorOptions(AppPaths.Home, support.FullName, () => new SystemSnapshot { SampledAt = DateTimeOffset.UtcNow },
        ReadLimits: new LiveLimits(AppPaths.Home, Updater.CurrentVersion).Read));
    try
    {
        monitor.Start();
        monitor.WatchLimits(true, true);
        static bool Answered(MonitorState state) => state.Sessions.UsageLimit?.Live == true && SessionPresentation.ClaudeUsageLimit(state.ClaudeLimits, state.Now)?.Live == true;
        for (var waited = 0; waited < 30 && !Answered(monitor.Current); waited++) Thread.Sleep(500);
        var state = monitor.Current;
        foreach (var limit in new[] { state.Sessions.UsageLimit, SessionPresentation.ClaudeUsageLimit(state.ClaudeLimits, state.Now) })
            Console.WriteLine(limit is null ? "—" : $"{limit.Title}: {limit.Value(state.Now)} · {limit.Details(state.Now)[0]} · live={limit.Live}");
        // omp's and Pi's own usage records, with their age (the monitor reads them only with telemetry).
        static string Describe(IEnumerable<(double Percent, int? Minutes, DateTimeOffset? Reset)> windows) => string.Join(", ", windows.Select(window =>
            $"{Math.Round(window.Percent, MidpointRounding.AwayFromZero)}% of {(window.Minutes is { } minutes ? $"{minutes} min" : "?")} · resets {window.Reset?.ToString("O") ?? "—"}"));
        var recorded = new AgentUsageHistoryReader(AppPaths.Home, Environment.GetEnvironmentVariable).Read();
        string Age(IEnumerable<DateTimeOffset> dates) =>
            dates.Any() ? $" · recorded {(DateTimeOffset.UtcNow - dates.Max()).TotalMinutes:F0} min ago" : "";
        var claudeWindows = new[] { (recorded.Claude.FiveHour, 300), (recorded.Claude.SevenDay, 10_080) }
            .Where(pair => pair.Item1 is not null).Select(pair => (pair.Item1!.UsedPercent, (int?)pair.Item2, pair.Item1.ResetsAt)).ToList();
        Console.WriteLine("omp/Pi records, Claude: " + (claudeWindows.Count == 0 ? "none" : Describe(claudeWindows))
            + Age(new[] { recorded.Claude.FiveHour, recorded.Claude.SevenDay }.OfType<ClaudeLimitWindow>().Select(window => window.ReceivedAt)));
        Console.WriteLine("omp/Pi records, Codex: " + (recorded.Codex.Count == 0 ? "none" : Describe(recorded.Codex.Select(limit => (limit.UsedPercent, limit.WindowMinutes, limit.ResetsAt))))
            + Age(recorded.Codex.Select(limit => limit.RecordedAt)));
        return 0;
    }
    finally
    {
        monitor.Stop();
        support.Delete(true);
    }
}
if (args is ["--telemetry-lifecycle-checks", .. var port])
    return Suites.Report(TelemetryLifecycleChecks.Run(port is [var text, ..] && int.TryParse(text, out var value) ? value : null));
return Suites.Report(Suites.RunAll());
