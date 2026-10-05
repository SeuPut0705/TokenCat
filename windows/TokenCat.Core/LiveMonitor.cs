using System.Diagnostics;
using System.Threading.Channels;
using static TokenCat.Lang;

namespace TokenCat;

// App.swift's DashboardModel and TelemetryRestartState (DESIGN §6.1, rule 10). GCD queues and generation counters become two
// loops over one CancellationToken: the system loop owns the single 1 s PeriodicTimer and wakes the token loop each tick;
// log-watcher paths wake it too, at most every 0.25 s. Named LiveMonitor because System.Threading.Monitor is an implicit using.

/// `SampleSystem` is the App's Windows sampler (called on a worker thread, at most once at a time). Without `Telemetry` (checks)
/// the collector reads as stopped and no Claude desktop history is read, as on the mac's verification path.
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

/// Clients whose config TokenCat changed and that have not sent a reading since.
/// After 24 h without one the notice changes, since that client may never emit the metric.
public sealed record TelemetryRestartState
{
    public const double Window = 86_400;
    public IReadOnlyDictionary<TokenSource, DateTimeOffset> Pending { get; init; } = new Dictionary<TokenSource, DateTimeOffset>();
    public IReadOnlySet<TokenSource> Needed { get; init; } = new HashSet<TokenSource>();
    public IReadOnlySet<TokenSource> Expired { get; init; } = new HashSet<TokenSource>();

    /// `ran` is the newest log activity per client. A client never used since its config changed is not reported as
    /// failing; it stays quietly pending after the window.
    public static TelemetryRestartState Resolve(IReadOnlyDictionary<TokenSource, DateTimeOffset> pending,
        IReadOnlyDictionary<TokenSource, DateTimeOffset> received, DateTimeOffset now, IReadOnlyDictionary<TokenSource, DateTimeOffset>? ran = null)
    {
        var (kept, needed, expired) = (new Dictionary<TokenSource, DateTimeOffset>(), new HashSet<TokenSource>(), new HashSet<TokenSource>());
        foreach (var (source, connectedAt) in pending)
        {
            if (received.TryGetValue(source, out var at) && at > connectedAt) continue;
            kept[source] = connectedAt;
            if ((now - connectedAt).TotalSeconds < Window) needed.Add(source);
            else if (ran?.TryGetValue(source, out var used) == true && used > connectedAt) expired.Add(source);
        }
        return new TelemetryRestartState { Pending = kept, Needed = needed, Expired = expired };
    }
}

public sealed class LiveMonitor : IDisposable
{
    public const double SamplingInterval = 1, FolderCheckInterval = 5;
    /// File events can arrive many times per second while a client streams tool output.
    public const double MinimumTokenInterval = 0.25;
    const string PendingRestartKey = "telemetryPendingRestart";
    static readonly string[] Tick = [];

    readonly MonitorOptions options;
    readonly Func<DateTimeOffset> clock;
    readonly SettingsStore store;
    readonly TokenTracker tracker;
    readonly ClaudeUsage.DesktopReader? desktop;
    readonly object gate = new();

    // Everything below is guarded by `gate`.
    SystemSnapshot system = new();
    bool hasSample, sessionsExpanded, logFoldersFound = true;
    readonly List<double> cpuHistory = [];
    IReadOnlyList<TokenReading> tokens = [];
    DateTimeOffset? tokensSampledAt, nextRetryAt;
    TelemetryCollectorState telemetryState = TelemetryCollectorState.Waiting;
    string telemetryStatus = Loc("실측 수신 대기", "Waiting for telemetry");
    Dictionary<TokenSource, DateTimeOffset> pendingRestart = [];
    readonly Dictionary<TokenSource, DateTimeOffset> lastReceived = [], batches = [];
    TelemetryRestartState restart = new();
    ClaudeUsageLimits claudeLimits;
    MonitorState current;
    CancellationTokenSource? running;
    Channel<string[]>? wake;
    LogWatcher? watcher;

    public LiveMonitor(MonitorOptions options)
    {
        this.options = options;
        clock = options.Clock ?? (() => DateTimeOffset.UtcNow);
        store = new SettingsStore(Path.Combine(options.SupportDirectory, "settings.json"));
        tracker = new TokenTracker(options.Home, clock);
        if (options.Telemetry is not null) desktop = new ClaudeUsage.DesktopReader(AppPaths.ClaudeDesktopHistory());
        foreach (var (id, seconds) in store.Get<Dictionary<string, double>>(PendingRestartKey) ?? new Dictionary<string, double>())
            foreach (var source in Enum.GetValues<TokenSource>().Where(value => value.Id == id))
                pendingRestart[source] = DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1_000));
        claudeLimits = LoadClaudeLimits(store);
        UpdateRestartState(clock());
        // The mac model's initial published values: nothing sampled, an empty flow and list.
        current = State(clock(), FlowSeries.Empty, [], SessionListModel.Empty);
    }

    /// Raised under the monitor's lock, never after Stop() returns: from the sampling loops (worker threads), or from the caller
    /// of SessionsExpanded / NoteTelemetryConnected. Marshal with Dispatcher.BeginInvoke (a blocking Invoke would deadlock
    /// against a Stop() called on the UI thread).
    public event Action<MonitorState>? Updated;

    public MonitorState Current { get { lock (gate) return current; } }

    /// The flyout's expanded session list; a change republishes at once.
    public bool SessionsExpanded
    {
        get { lock (gate) return sessionsExpanded; }
        set
        {
            lock (gate)
            {
                if (sessionsExpanded == value) return;
                sessionsExpanded = value;
                Publish();
            }
        }
    }

    public void Start()
    {
        lock (gate)
        {
            if (running is not null) return;
            running = new CancellationTokenSource();
            var token = running.Token;
            var channel = wake = Channel.CreateUnbounded<string[]>(new UnboundedChannelOptions { SingleReader = true });
            watcher = new LogWatcher(paths => channel.Writer.TryWrite(paths));
            watcher.Start(tracker.WatchedDirectories);
            _ = Task.Run(() => SystemLoop(channel.Writer, token));
            _ = Task.Run(() => TokenLoop(channel.Reader, token));
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            if (running is null) return;
            running.Cancel();
            running = null;
            wake?.Writer.TryComplete();
            wake = null;
            watcher?.Stop();
            watcher = null;
        }
    }

    public void Dispose() => Stop();

    /// Samples the logs now instead of at the next tick; the system keeps its 1 s cadence.
    public void Refresh()
    {
        lock (gate) wake?.Writer.TryWrite(Tick);
    }

    /// "지금 다시 시도" (T-3): the collector's scheduled retry runs now; the new state shows on the next publish.
    public void RetryTelemetryNow()
    {
        if (options.Telemetry is not { } telemetry) return;
        telemetry.RetryNow();
        _ = Task.Delay(300).ContinueWith(_ => Refresh(), TaskScheduler.Default);
    }

    /// After TokenCat changed a client's config: it needs a new launch until its first reading arrives.
    public void NoteTelemetryConnected(IEnumerable<TokenSource> sources)
    {
        lock (gate)
        {
            var now = clock();
            var changed = false;
            foreach (var source in sources) { pendingRestart[source] = now; changed = true; }
            if (!changed) return;
            SavePendingRestart();
            UpdateRestartState(now);
            Publish();
        }
    }

    public static ClaudeUsageLimits LoadClaudeLimits(SettingsStore store) =>
        store.Get<ClaudeUsageLimits>(ClaudeUsageLimits.DefaultsKey) ?? ClaudeUsageLimits.Empty;

    /// Numbers and times only; empty limits clear the stored value.
    public static void SaveClaudeLimits(SettingsStore store, ClaudeUsageLimits limits)
    {
        if (limits.IsEmpty) store.Remove(ClaudeUsageLimits.DefaultsKey);
        else store.Set(ClaudeUsageLimits.DefaultsKey, limits);
    }

    async Task SystemLoop(ChannelWriter<string[]> wakeTokens, CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(SamplingInterval));
        try
        {
            do
            {
                wakeTokens.TryWrite(Tick);
                try
                {
                    var sample = options.SampleSystem();
                    lock (gate)
                    {
                        if (token.IsCancellationRequested) return;
                        system = sample;
                        hasSample = true;
                        if (sample.CpuPercent is { } cpu)
                        {
                            cpuHistory.Add(cpu);
                            if (cpuHistory.Count > 90) cpuHistory.RemoveRange(0, cpuHistory.Count - 90);
                        }
                        Publish();
                    }
                }
                // A failed sample keeps the previous values; the footer's collection delay shows it.
                catch (Exception error) when (error is not OperationCanceledException) { }
            }
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) { }
    }

    async Task TokenLoop(ChannelReader<string[]> reader, CancellationToken token)
    {
        long lastStart = 0, lastFolderCheck = 0;
        HashSet<string>? foldersSeen = null;
        try
        {
            while (await reader.WaitToReadAsync(token).ConfigureAwait(false))
            {
                var wait = MinimumTokenInterval - Stopwatch.GetElapsedTime(lastStart).TotalSeconds;
                if (wait > 0) await Task.Delay(TimeSpan.FromSeconds(wait), token).ConfigureAwait(false);
                var paths = new List<string>();
                while (reader.TryRead(out var batch)) paths.AddRange(batch.Where(path => path.EndsWith(".jsonl", StringComparison.Ordinal)).Take(64));
                if (paths.Count > 256) paths.RemoveRange(0, paths.Count - 256);
                lastStart = Stopwatch.GetTimestamp();
                try
                {
                    bool? found = null;
                    if (lastFolderCheck == 0 || Stopwatch.GetElapsedTime(lastFolderCheck).TotalSeconds >= FolderCheckInterval)
                    {
                        lastFolderCheck = lastStart;
                        var existing = tracker.WatchedDirectories.Where(Directory.Exists).ToHashSet();
                        found = existing.Count > 0;
                        // A folder created after the watcher started (first Codex or Claude Code run): watch it and read it now.
                        if (foldersSeen is not null && !existing.IsSubsetOf(foldersSeen))
                            lock (gate) if (!token.IsCancellationRequested) watcher?.Start(tracker.WatchedDirectories);
                        foldersSeen = existing;
                    }
                    SampleTokens(paths, found, token);
                }
                // A failed sample keeps the previous values; the footer's collection delay shows it.
                catch (Exception error) when (error is not OperationCanceledException) { }
            }
        }
        catch (OperationCanceledException) { }
    }

    void SampleTokens(List<string> paths, bool? foldersFound, CancellationToken token)
    {
        tracker.NoteChanged(paths);
        var logs = tracker.Sample();
        var telemetry = options.Telemetry;
        var measurements = telemetry?.Snapshot() ?? [];
        var readings = TokenSpeed.Apply(logs, measurements);
        var received = new Dictionary<TokenSource, DateTimeOffset>();
        foreach (var measurement in measurements) Later(received, measurement.Provider, measurement.At);
        // Any batch from a restarted client clears its notice, even one TokenCat cannot decode yet.
        var batchAt = telemetry?.LastBatchAt ?? new Dictionary<TokenSource, DateTimeOffset>();
        var limits = telemetry is null ? ClaudeUsageLimits.Empty : ClaudeUsage.Merged(telemetry.ClaudeLimits, desktop!.Read());
        var state = telemetry?.State ?? TelemetryCollectorState.Stopped;
        var status = telemetry?.Status ?? Loc("실측 꺼짐 · 실행 중인 TokenCat 수집기 없음", "Telemetry off · no TokenCat collector running");
        var retryAt = telemetry?.NextRetryAt;
        var measuredAt = clock();
        lock (gate)
        {
            if (token.IsCancellationRequested) return;
            tokens = readings;
            tokensSampledAt = measuredAt;
            (telemetryState, telemetryStatus, nextRetryAt) = (state, status, retryAt);
            if (foldersFound is { } found) logFoldersFound = found;
            foreach (var (source, at) in received) Later(lastReceived, source, at);
            foreach (var (source, at) in batchAt) Later(batches, source, at);
            var merged = limits.IsEmpty ? claudeLimits : ClaudeUsage.Merged(claudeLimits, limits);
            if (merged != claudeLimits)
            {
                claudeLimits = merged;
                SaveClaudeLimits(store, merged);
            }
            UpdateRestartState(measuredAt);
            Publish();
        }
    }

    static void Later(Dictionary<TokenSource, DateTimeOffset> times, TokenSource source, DateTimeOffset at)
    {
        if (!times.TryGetValue(source, out var known) || at > known) times[source] = at;
    }

    void UpdateRestartState(DateTimeOffset now)
    {
        var ran = new Dictionary<TokenSource, DateTimeOffset>();
        foreach (var reading in tokens)
            if (!SessionPresentation.IsTelemetry(reading) && SessionPresentation.LiveAt(reading) is { } at) Later(ran, reading.Source, at);
        var received = new Dictionary<TokenSource, DateTimeOffset>(lastReceived);
        foreach (var (source, at) in batches) Later(received, source, at);
        restart = TelemetryRestartState.Resolve(pendingRestart, received, now, ran);
        if (restart.Pending.Count == pendingRestart.Count && restart.Pending.All(pair => pendingRestart.GetValueOrDefault(pair.Key) == pair.Value)) return;
        pendingRestart = new Dictionary<TokenSource, DateTimeOffset>(restart.Pending);
        SavePendingRestart();
    }

    void SavePendingRestart()
    {
        if (pendingRestart.Count == 0) store.Remove(PendingRestartKey);
        else store.Set(PendingRestartKey, pendingRestart.ToDictionary(pair => pair.Key.Id, pair => pair.Value.ToUnixTimeMilliseconds() / 1_000.0));
    }

    MonitorState State(DateTimeOffset now, FlowSeries flow, IReadOnlyList<SessionGroup> groups, SessionListModel sessions) => new(
        now, system, hasSample, cpuHistory.ToArray(), tokens, tokensSampledAt, groups, sessions, flow,
        tokens.Where(reading => !SessionPresentation.IsTelemetry(reading)).Select(reading => reading.LastOutputAt).Max(),
        telemetryState, telemetryStatus, nextRetryAt, restart.Needed, restart.Expired,
        new Dictionary<TokenSource, DateTimeOffset>(lastReceived), claudeLimits, logFoldersFound);

    /// Rebuilds the presentation on the shared clock and raises Updated while running. Caller holds `gate`.
    void Publish()
    {
        var now = tokensSampledAt is { } sampled && sampled > system.SampledAt ? sampled : system.SampledAt;
        current = State(now, FlowSeries.Make(tokens, now), SessionPresentation.Groups(tokens, now),
                        SessionListModel.Make(tokens, now, sessionsExpanded, restart.Needed));
        if (running is { IsCancellationRequested: false }) Updated?.Invoke(current);
    }
}
