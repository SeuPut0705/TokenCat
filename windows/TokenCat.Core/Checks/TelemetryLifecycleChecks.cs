namespace TokenCat;

// WP2 stub. Opens real loopback listeners on `port` and `port + 1` (a free pair when null), so it stays out of Suites.RunAll:
// `TokenCat.Checks -- --telemetry-lifecycle-checks [port]` and the App's `--telemetry-lifecycle-checks`. WP2 owns this file.
public static class TelemetryLifecycleChecks
{
    public static List<string> Run(int? port) => [];
}
