namespace TokenCat;

/// Every Core suite, registered once by WP0. A package fills its own `<Suite>Checks.Run()` file; this list does not change.
/// Called by `TokenCat.Checks` and by the App's `--self-test` (which appends its own App checks before `Report`).
public static class Suites
{
    static readonly Func<List<string>>[] All =
    [
        LocalizationChecks.Run, CoreChecks.Run,                                                      // WP0
        TrackerChecks.Run, TokenSpeedChecks.Run,                                                     // WP1
        TelemetryChecks.Run, TelemetrySetupChecks.Run,                                               // WP2
        SessionPresentationChecks.Run, PreferenceChecks.Run, ShellChecks.Run, StatusSummaryChecks.Run,
        MonitorChecks.Run,                                                                           // WP3
        RunnerChecks.Run, UpdaterChecks.Run,                                                         // WP4
    ];

    /// Runs every suite in Korean, as the mac `--self-test` does. A suite that throws counts as one failure.
    public static List<string> RunAll() => Lang.With(AppLanguage.Ko, () =>
    {
        var failures = new List<string>();
        foreach (var run in All)
        {
            try { failures.AddRange(run()); }
            catch (Exception error) { failures.Add($"{run.Method.DeclaringType!.Name} threw {error.GetType().Name}: {error.Message}"); }
        }
        return failures;
    });

    /// Prints FAIL lines or "TokenCat checks: PASS" and returns the process exit code.
    public static int Report(IReadOnlyCollection<string> failures)
    {
        foreach (var failure in failures) Console.WriteLine($"FAIL: {failure}");
        if (failures.Count == 0) Console.WriteLine("TokenCat checks: PASS");
        return failures.Count == 0 ? 0 : 1;
    }
}
