namespace TokenCat;

// WP2 stub (DESIGN §11, §7.3): loopback OTLP/HTTP-JSON collector. WP2 replaces the bodies and owns this file.
public sealed class TelemetryCollector : IDisposable
{
    public const int DefaultPort = 16493;

    public TelemetryCollector(int port = DefaultPort, double[]? retryDelays = null) => throw new NotImplementedException();

    public void Start(Action? onReady = null) => throw new NotImplementedException();
    public void Stop() => throw new NotImplementedException();
    public void RetryNow() => throw new NotImplementedException();
    public TelemetryCollectorState State => throw new NotImplementedException();
    public string Status => throw new NotImplementedException();
    public DateTimeOffset? NextRetryAt => throw new NotImplementedException();
    public IReadOnlyDictionary<TokenSource, DateTimeOffset> LastBatchAt => throw new NotImplementedException();
    public ClaudeUsageLimits ClaudeLimits => throw new NotImplementedException();
    public List<TelemetryReading> Snapshot() => throw new NotImplementedException();
    public void Dispose() => Stop();

    /// GET /health on the default port: another TokenCat already collects.
    public static bool IsOwnCollectorRunning(TimeSpan timeout) => throw new NotImplementedException();
    /// GET /v1/readings from the running app (CLI, `--diagnose`).
    public static List<TelemetryReading> FetchSnapshot(TimeSpan timeout) => throw new NotImplementedException();
}

public static class TelemetryCollectorStateText
{
    extension(TelemetryCollectorState state)
    {
        /// Telemetry.swift `TelemetryCollectorState.status`.
        public string Status => throw new NotImplementedException();
    }
}
