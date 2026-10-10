using System.Diagnostics;
using System.Threading.Channels;
using static TokenCat.Lang;

namespace TokenCat;

// App.swift's DashboardModel and TelemetryRestartState (DESIGN §6.1, rule 10). GCD queues and generation counters become two
// loops over one CancellationToken: the system loop owns the single 1 s PeriodicTimer and wakes the token loop each tick;
// log-watcher paths wake it too, at most every 0.25 s. Named LiveMonitor because System.Threading.Monitor is an implicit using.

/// `SampleSystem` is the App's Windows sampler (called on a worker thread, at most once at a time). Without `Telemetry`
/// the collector reads as stopped; passive desktop and omp/Pi records still work. Without `ReadLimits` nothing goes online.
public sealed record MonitorOptions(string Home, string SupportDirectory, Func<SystemSnapshot> SampleSystem,
    TelemetryCollector? Telemetry = null, Func<DateTimeOffset>? Clock = null,
    Func<LimitSlot, CancellationToken, Task<LiveLimitResult>>? ReadLimits = null);

/// DashboardModel's published state, immutable per publish. Fixtures construct it directly (WP5 snapshots).
/// `DetectedSources`: clients whose data folder exists (`TokenTracker.DetectedSources`), refreshed with the folder check.
public sealed record MonitorState(
    DateTimeOffset Now, SystemSnapshot System, bool HasSample, IReadOnlyList<double> CpuHistory,
    IReadOnlyList<TokenReading> Tokens, DateTimeOffset? TokensSampledAt, IReadOnlyList<SessionGroup> Groups,
    SessionListModel Sessions, FlowSeries Flow, DateTimeOffset? NewestOutputAt,
    TelemetryCollectorState TelemetryState, string TelemetryStatus, DateTimeOffset? TelemetryNextRetryAt,
    IReadOnlySet<TokenSource> TelemetryRestartNeeded, IReadOnlySet<TokenSource> TelemetryRestartExpired,
    IReadOnlyDictionary<TokenSource, DateTimeOffset> TelemetryLastReceived, IReadOnlyDictionary<string, ClaudeUsageLimits> ClaudeLimits, bool LogFoldersFound,
    IReadOnlySet<TokenSource> DetectedSources)
{
    /// Sources UI lists name: the telemetry clients, detected clients and any a reading carries (`TokenSource.Listed`).
    public IReadOnlyList<TokenSource> ListedSources => TokenSource.Listed(DetectedSources, Tokens);
    public IReadOnlyList<UsageLimitSummary> UsageLimits { get; init; } = [];
    public IReadOnlyDictionary<TokenSource, LimitAccount> DefaultLimitAccounts { get; init; } = new Dictionary<TokenSource, LimitAccount>();
    public IReadOnlyDictionary<TokenSource, IReadOnlyList<LimitAccount>> KnownLimitAccounts { get; init; } = new Dictionary<TokenSource, IReadOnlyList<LimitAccount>>();
    public ClaudeUsageLimits ShownClaudeLimits => UsageLimits.FirstOrDefault(row => row.Source == TokenSource.Claude) is { } first
        ? ClaudeLimits.GetValueOrDefault(first.Account?.StorageKey ?? ClaudeLimitsByAccount.LegacyKey) ?? ClaudeUsageLimits.Empty
        : ClaudeUsageLimits.Empty;
}

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
    readonly ClaudeUsage.DesktopReader desktop;
    readonly AgentUsageHistoryReader agentUsage;
    readonly LimitAccountReader limitAccounts;
    readonly object gate = new();

    // Everything below is guarded by `gate`.
    SystemSnapshot system = new();
    bool hasSample, sessionsExpanded, logFoldersFound = true;
    IReadOnlySet<TokenSource> detectedSources = new HashSet<TokenSource>();
    readonly List<double> cpuHistory = [];
    IReadOnlyList<TokenReading> tokens = [];
    DateTimeOffset? tokensSampledAt, nextRetryAt;
    TelemetryCollectorState telemetryState = TelemetryCollectorState.Waiting;
    string telemetryStatus = Loc("실측 수신 대기", "Waiting for telemetry");
    Dictionary<TokenSource, DateTimeOffset> pendingRestart = [];
    readonly Dictionary<TokenSource, DateTimeOffset> lastReceived = [], batches = [];
    TelemetryRestartState restart = new();
    IReadOnlyDictionary<string, ClaudeUsageLimits> claudeLimits;
    IReadOnlyDictionary<TokenSource, LimitAccount> defaultLimitAccounts = new Dictionary<TokenSource, LimitAccount>();
    IReadOnlyDictionary<TokenSource, IReadOnlyList<LimitAccount>> knownLimitAccounts = new Dictionary<TokenSource, IReadOnlyList<LimitAccount>>();
    // Live usage limits: the setting, a dashboard on screen, one that just opened, each provider's poll, Codex's last answer
    // (Claude's merges into `claudeLimits`).
    bool limitsEnabled, limitsWatched;
    readonly LiveLimitPoller? livePoller;
    IReadOnlyList<TokenRateLimit> codexLive = [];
    /// Codex windows omp or Pi recorded from their own usage checks (`AgentUsageHistory`), weighed like log records.
    IReadOnlyList<TokenRateLimit> codexRecorded = [];
    IReadOnlyList<UsageLimitSummary> usageLimits = [];
    MonitorState current;
    CancellationTokenSource? running;
    Channel<string[]>? wake;
    LogWatcher? watcher;

    public LiveMonitor(MonitorOptions options)
    {
        this.options = options;
        if (options.ReadLimits is { } read) livePoller = new LiveLimitPoller(read);
        clock = options.Clock ?? (() => DateTimeOffset.UtcNow);
        store = new SettingsStore(Path.Combine(options.SupportDirectory, "settings.json"));
        tracker = new TokenTracker(options.Home, clock);
        limitAccounts = new LimitAccountReader(options.Home, Environment.GetEnvironmentVariable);
        limitAccounts.Refresh();
        defaultLimitAccounts = DefaultAccounts();
        knownLimitAccounts = KnownAccounts();
        desktop = new ClaudeUsage.DesktopReader(AppPaths.ClaudeDesktopHistory());
        agentUsage = new AgentUsageHistoryReader(options.Home, Environment.GetEnvironmentVariable);
        foreach (var (id, seconds) in store.Get<Dictionary<string, double>>(PendingRestartKey) ?? new Dictionary<string, double>())
            foreach (var source in TokenSource.TelemetryClients.Where(value => value.Id == id))
                pendingRestart[source] = DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1_000));
        claudeLimits = ClaudeLimitsByAccount.Load(store, defaultLimitAccounts.GetValueOrDefault(TokenSource.Claude));
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
            // Filtered on the watcher's thread: the watched roots also hold tool output, lock files and OpenCode's snapshot
            // git store, whose bursts would otherwise wake a full sample each. The 1 s tick covers the rest.
            watcher = new LogWatcher(paths =>
            {
                var logs = Array.FindAll(paths, tracker.WakesSampling);
                if (logs.Length > 0) channel.Writer.TryWrite(logs);
            });
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

    /// Live usage limits: `enabled` is the setting while the PC is awake with a screen on, `watched` a dashboard on screen. Polls
    /// start from the 1 s tick, so a dashboard that opens is answered within about a second plus the request.
    public void WatchLimits(bool enabled, bool watched)
    {
        lock (gate)
        {
            (limitsEnabled, limitsWatched) = (enabled, watched);
        }
    }
    IReadOnlyDictionary<TokenSource, LimitAccount> DefaultAccounts() =>
        TokenSource.DefaultClients.Where(source => limitAccounts.DefaultAccount(source) is not null)
            .ToDictionary(source => source, source => limitAccounts.DefaultAccount(source)!);

    IReadOnlyDictionary<TokenSource, IReadOnlyList<LimitAccount>> KnownAccounts() =>
        TokenSource.DefaultClients.ToDictionary(source => source, source => limitAccounts.KnownAccounts(source));

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
                        PublishSystem();
                    }
                }
                // A failed sample keeps the previous values; the footer's collection delay shows it.
                catch (Exception error) when (error is not OperationCanceledException) { }
                lock (gate) PollLimits(token);
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
                while (reader.TryRead(out var batch)) paths.AddRange(batch.Take(64));
                if (paths.Count > 256) paths.RemoveRange(0, paths.Count - 256);
                lastStart = Stopwatch.GetTimestamp();
                try
                {
                    bool? found = null;
                    IReadOnlySet<TokenSource>? detected = null;
                    if (lastFolderCheck == 0 || Stopwatch.GetElapsedTime(lastFolderCheck).TotalSeconds >= FolderCheckInterval)
                    {
                        lastFolderCheck = lastStart;
                        var existing = tracker.WatchedDirectories.Where(Directory.Exists).ToHashSet();
                        found = existing.Count > 0;
                        detected = tracker.DetectedSources();
                        // A folder created after the watcher started (first Codex or Claude Code run): watch it, list it and read it now.
                        if (foldersSeen is not null && !existing.IsSubsetOf(foldersSeen))
                        {
                            lock (gate) if (!token.IsCancellationRequested) watcher?.Start(tracker.WatchedDirectories);
                            tracker.Rediscover();
                        }
                        foldersSeen = existing;
                    }
                    SampleTokens(paths, found, detected, token);
                }
                // A failed sample keeps the previous values; the footer's collection delay shows it.
                catch (Exception error) when (error is not OperationCanceledException) { }
            }
        }
        catch (OperationCanceledException) { }
    }

    void SampleTokens(List<string> paths, bool? foldersFound, IReadOnlySet<TokenSource>? detected, CancellationToken token)
    {
        tracker.NoteChanged(paths);
        var logs = tracker.Sample();
        limitAccounts.Refresh();
        var defaults = DefaultAccounts();
        var known = new Dictionary<TokenSource, IReadOnlyList<LimitAccount>>(KnownAccounts());
        var telemetry = options.Telemetry;
        var measurements = telemetry?.Snapshot() ?? [];
        var readings = TokenSpeed.Apply(logs, measurements);
        var received = new Dictionary<TokenSource, DateTimeOffset>();
        foreach (var measurement in measurements) Later(received, measurement.Provider, measurement.At);
        // Any batch from a restarted client clears its notice, even one TokenCat cannot decode yet.
        var batchAt = telemetry?.LastBatchAt ?? new Dictionary<TokenSource, DateTimeOffset>();
        var agent = agentUsage.Read();
        foreach (var (provider, accounts) in agent.Accounts)
            known[provider] = known.GetValueOrDefault(provider, []).Concat(accounts).Distinct().OrderBy(account => account.Key, StringComparer.Ordinal).ToArray();
        var defaultClaude = defaults.GetValueOrDefault(TokenSource.Claude);
        var desktopLimits = desktop.Read(limitAccounts.DefaultClaudeOrganizationID);
        IReadOnlyDictionary<string, ClaudeUsageLimits> desktopStore = desktopLimits.IsEmpty
            ? new Dictionary<string, ClaudeUsageLimits>()
            : new Dictionary<string, ClaudeUsageLimits> { [defaultClaude?.StorageKey ?? ClaudeLimitsByAccount.LegacyKey] = desktopLimits };
        var statusLimits = telemetry?.ClaudeLimitsForSessions(readings) ?? new Dictionary<string, ClaudeUsageLimits>();
        var limits = ClaudeLimitsByAccount.Merged(ClaudeLimitsByAccount.Merged(statusLimits, desktopStore), agent.Claude);
        var state = telemetry?.State ?? TelemetryCollectorState.Stopped;
        var status = telemetry?.Status ?? Loc("실측 꺼짐 · 실행 중인 TokenCat 수집기 없음", "Telemetry off · no TokenCat collector running");
        var retryAt = telemetry?.NextRetryAt;
        var measuredAt = clock();
        lock (gate)
        {
            if (token.IsCancellationRequested) return;
            tokens = readings;
            defaultLimitAccounts = defaults;
            knownLimitAccounts = known;
            tokensSampledAt = measuredAt;
            (telemetryState, telemetryStatus, nextRetryAt) = (state, status, retryAt);
            if (foldersFound is { } found) logFoldersFound = found;
            if (detected is not null) detectedSources = detected;
            foreach (var (source, at) in received) Later(lastReceived, source, at);
            foreach (var (source, at) in batchAt) Later(batches, source, at);
            codexRecorded = agent.Codex;
            var merged = ClaudeLimitsByAccount.Merged(claudeLimits, limits);
            if (!merged.Count.Equals(claudeLimits.Count) || merged.Any(pair => claudeLimits.GetValueOrDefault(pair.Key) != pair.Value))
            {
                claudeLimits = merged;
                ClaudeLimitsByAccount.Save(store, merged);
            }
            UpdateRestartState(measuredAt);
            Publish();
        }
    }

    /// Polls the shown and running Claude accounts and only the default Codex CLI account. Caller holds `gate`.
    void PollLimits(CancellationToken token)
    {
        if (livePoller is not { } poller || !limitsEnabled || token.IsCancellationRequested) return;
        var active = current.Sessions.Counts.LimitSources;
        var slots = active.Where(slot => slot.Provider == TokenSource.Claude && slot.Account is not null).ToHashSet();
        foreach (var row in current.UsageLimits.Where(row => row.Source == TokenSource.Claude && row.Account is not null))
            slots.Add(new LimitSlot(TokenSource.Claude, row.Account));
        if (!slots.Any(slot => slot.Provider == TokenSource.Claude) && defaultLimitAccounts.GetValueOrDefault(TokenSource.Claude) is { } claudeAccount)
            slots.Add(new LimitSlot(TokenSource.Claude, claudeAccount));
        if (defaultLimitAccounts.GetValueOrDefault(TokenSource.Codex) is { } codexAccount)
            slots.Add(new LimitSlot(TokenSource.Codex, codexAccount));
        _ = poller.Tick(clock(), limitsWatched, slots, active.Contains, result =>
        {
            lock (gate)
            {
                if (token.IsCancellationRequested) return;
                if (result.Codex is { } codex) codexLive = codex;
                if (result.Claude is { } claude)
                {
                    claudeLimits = ClaudeLimitsByAccount.Merge(claudeLimits, claude, result.Slot?.Account);
                    ClaudeLimitsByAccount.Save(store, claudeLimits);
                }
                Publish();
            }
        }, token);
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
        new Dictionary<TokenSource, DateTimeOffset>(lastReceived), claudeLimits, logFoldersFound, detectedSources)
        {
            DefaultLimitAccounts = defaultLimitAccounts,
            KnownLimitAccounts = knownLimitAccounts,
            UsageLimits = usageLimits,
        };

    /// Rebuilds the presentation on the shared clock and raises Updated while running. Caller holds `gate`.
    void Publish()
    {
        var now = tokensSampledAt is { } sampled && sampled > system.SampledAt ? sampled : system.SampledAt;
        usageLimits = SessionPresentation.UsageLimits(tokens, [.. codexLive, .. codexRecorded], claudeLimits, defaultLimitAccounts, knownLimitAccounts, now);
        current = State(now, FlowSeries.Make(tokens, now), SessionPresentation.Groups(tokens, now),
                        SessionListModel.Make(tokens, now, sessionsExpanded, restart.Needed));
        if (running is { IsCancellationRequested: false }) Updated?.Invoke(current);
    }

    /// The system sample's publish. The token sample of the same tick rebuilds the sessions, so this one only swaps in the
    /// system values, unless that sample is slow or stalled and the clocks need this one. Caller holds `gate`.
    void PublishSystem()
    {
        if (tokensSampledAt is not { } sampled || (system.SampledAt - sampled).TotalSeconds >= 2 * SamplingInterval)
        {
            Publish();
            return;
        }
        current = State(current.Now, current.Flow, current.Groups, current.Sessions);
        if (running is { IsCancellationRequested: false }) Updated?.Invoke(current);
    }
}
