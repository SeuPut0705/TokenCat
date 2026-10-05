namespace TokenCat;

// WP3 stub (DESIGN §11, rule 10): one async loop (1 s PeriodicTimer + watcher channel) instead of GCD queues. Named
// LiveMonitor because System.Threading.Monitor is an implicit using. WP3 replaces the bodies and owns this file.

public sealed record MonitorOptions(string Home, string SupportDirectory, Func<SystemSnapshot> SampleSystem,
    TelemetryCollector? Telemetry = null, Func<DateTimeOffset>? Clock = null);

/// DashboardModel's published state, immutable per publish. Fixtures construct it directly (WP5 snapshots).
public sealed record MonitorState(
    DateTimeOffset Now, SystemSnapshot System, bool HasSample, IReadOnlyList<double> CpuHistory,
    IReadOnlyList<TokenReading> Tokens, DateTimeOffset? TokensSampledAt, IReadOnlyList<SessionGroup> Groups,
    SessionListModel Sessions, FlowSeries Flow, DateTimeOffset? NewestOutputAt,
    TelemetryCollectorState TelemetryState, string TelemetryStatus, DateTimeOffset? TelemetryNextRetryAt,
    IReadOnlySet<TokenSource> TelemetryRestartNeeded, IReadOnlySet<TokenSource> TelemetryRestartExpired,
    IReadOnlyDictionary<TokenSource, DateTimeOffset> TelemetryLastReceived, ClaudeUsageLimits ClaudeLimits, bool LogFoldersFound);

public sealed class LiveMonitor : IDisposable
{
    public LiveMonitor(MonitorOptions options) => throw new NotImplementedException();

    /// Raised off the UI thread; never after Stop() returns.
    public event Action<MonitorState>? Updated
    {
        add => throw new NotImplementedException();
        remove => throw new NotImplementedException();
    }

    public MonitorState Current => throw new NotImplementedException();
    public void Start() => throw new NotImplementedException();
    public void Stop() => throw new NotImplementedException();
    public void Refresh() => throw new NotImplementedException();
    public void RetryTelemetryNow() => throw new NotImplementedException();
    public void NoteTelemetryConnected(IEnumerable<TokenSource> sources) => throw new NotImplementedException();
    public void Dispose() => Stop();
}
