using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using static TokenCat.Lang;

namespace TokenCat;

/// Telemetry.swift `LocalTelemetryCollector` (DESIGN §7.3): loopback OTLP/HTTP-JSON collector on a `TcpListener` with
/// `ExclusiveAddressUse` (no URL ACL, no other socket can co-bind). One lock guards all state; GCD's serial queue and
/// generation counter become `gate` + `generation`, so a stale retry or connection never acts after Stop()/RetryNow().
public sealed class TelemetryCollector : IDisposable
{
    public const int DefaultPort = 16493;
    public const int MaximumConnections = 16, MaximumReadings = 256, MaximumDiagnostics = 64, MaximumDiagnosticKeys = 48;
    /// Newest reading per (provider, session, agent, model), kept beside the recent window so
    /// a burst of subagent requests cannot evict a quiet session's last measurement.
    public const int MaximumLatest = 128;
    /// Waits before retrying a listener that could not start (for example a busy port).
    public static readonly double[] DefaultRetryDelays = [5, 30, 120];

    static readonly byte[] EmptyObject = "{}"u8.ToArray();
    static readonly HttpClient Loopback = new(new SocketsHttpHandler { UseProxy = false, UseCookies = false, AllowAutoRedirect = false })
    {
        Timeout = Timeout.InfiniteTimeSpan,
    };

    readonly object gate = new();
    readonly int port;
    readonly double[] retryDelays;
    TcpListener? listener;
    readonly HashSet<Socket> connections = [];
    bool running, ready;
    int generation, attempt;
    Action? readyCallback;
    TelemetryCollectorState state = TelemetryCollectorState.Waiting;
    SocketError failure;
    DateTimeOffset? retryAt, receivedAt;
    readonly Dictionary<string, TelemetryRecord> stored = [];
    readonly Dictionary<string, (TelemetryRecord Record, ulong Touched)> latest = [];
    /// `Snapshot()` until the next ingest changes `stored` or `latest`; the app polls it every sample.
    List<TelemetryReading>? cachedSnapshot;
    ulong touches;
    readonly Dictionary<string, int> batchCounts = new() { ["logs"] = 0, ["metrics"] = 0, ["traces"] = 0 };
    readonly Dictionary<string, int> readingCounts = new() { ["logs"] = 0, ["metrics"] = 0, ["traces"] = 0 };
    readonly List<TelemetryDiagnosticEntry> diagnosticEntries = [];
    readonly Dictionary<TokenSource, DateTimeOffset> batches = [];
    ClaudeUsageLimits claudeStatus = ClaudeUsageLimits.Empty;

    public TelemetryCollector(int port = DefaultPort, double[]? retryDelays = null)
    {
        this.port = port;
        this.retryDelays = retryDelays ?? DefaultRetryDelays;
    }

    public TelemetryCollectorState State { get { lock (gate) return state; } }

    /// `State.Status`, except a bind refused with WSAEACCES (10013: Hyper-V/WSL/WinNAT reserved the port) names the netsh
    /// command that lists the reserved ranges.
    public string Status
    {
        get
        {
            lock (gate)
                return state == TelemetryCollectorState.Failed && failure == SocketError.AccessDenied
                    ? Loc($"실측 꺼짐 · 포트 {DefaultPort}이 Windows 예약 범위에 있음 (netsh int ipv4 show excludedportrange protocol=tcp)",
                          $"Telemetry off · port {DefaultPort} is in a Windows reserved range (netsh int ipv4 show excludedportrange protocol=tcp)")
                    : state.Status;
        }
    }

    /// When the next automatic start attempt runs after a failure; null when none is scheduled.
    public DateTimeOffset? NextRetryAt { get { lock (gate) return retryAt; } }
    public DateTimeOffset? LastReceivedAt { get { lock (gate) return receivedAt; } }
    /// Newest batch per client, decoded or not: proof that a restarted client exports here.
    public IReadOnlyDictionary<TokenSource, DateTimeOffset> LastBatchAt { get { lock (gate) return new Dictionary<TokenSource, DateTimeOffset>(batches); } }
    /// Newest Claude usage-limit windows received from the status line bridge in this process.
    public ClaudeUsageLimits ClaudeLimits { get { lock (gate) return claudeStatus; } }
    public bool IsRunning { get { lock (gate) return ready; } }

    public List<TelemetryReading> Snapshot()
    {
        lock (gate)
        {
            if (cachedSnapshot is null)
            {
                var union = new Dictionary<string, TelemetryRecord>(stored);
                foreach (var (record, _) in latest.Values)
                {
                    // A request re-delivered after eviction keeps its measured version.
                    if (union.TryGetValue(record.Key, out var current) && (current.HasRate || !record.HasRate)) continue;
                    union[record.Key] = record;
                }
                cachedSnapshot = [.. Newest(union).Select(entry => entry.Value.Reading)];
            }
            return [.. cachedSnapshot];
        }
    }

    public TelemetryDiagnostics Diagnostics()
    {
        lock (gate) return new(new Dictionary<string, int>(batchCounts), new Dictionary<string, int>(readingCounts), [.. diagnosticEntries]);
    }

    /// Calls `onReady` once after this start owns the listening port: inline when the bind succeeds at once, otherwise on a
    /// thread-pool thread after a retry. Duplicate starts discard their callback; UI work must dispatch to the UI thread.
    public void Start(Action? onReady = null) => Listen(() =>
    {
        if (running) return false;
        running = true;
        readyCallback = onReady;
        attempt = 0;
        return true;
    });

    /// "지금 다시 시도": runs the scheduled retry now. Acts only while running with a retry scheduled after a failed start;
    /// ready or starting (no retry scheduled), it does nothing, so two listeners never exist. The pending attempt is
    /// invalidated by the generation and `attempt` is kept, so a further failure keeps the schedule.
    public void RetryNow() => Listen(() => running && listener is null && retryAt is not null);

    public void Stop()
    {
        lock (gate)
        {
            running = false;
            readyCallback = null;
            generation++;
            CloseListener();
            retryAt = null;
            state = TelemetryCollectorState.Stopped;
        }
    }

    public void Dispose() => Stop();

    /// One listening attempt when `allowed` (checked under the lock). The ready callback survives retries until a start
    /// succeeds.
    void Listen(Func<bool> allowed)
    {
        TcpListener? server = null;
        Action? callback = null;
        var error = SocketError.Success;
        int epoch;
        lock (gate)
        {
            if (!allowed()) return;
            epoch = ++generation;
            retryAt = null;
            // Retries keep showing why the port is unavailable until a listener is ready.
            if (attempt == 0) state = TelemetryCollectorState.Starting;
            var candidate = new TcpListener(IPAddress.Loopback, port) { ExclusiveAddressUse = true };
            try
            {
                candidate.Start();
                server = listener = candidate;
                attempt = 0;
                ready = true;
                state = receivedAt is null ? TelemetryCollectorState.Waiting : TelemetryCollectorState.Receiving;
                callback = readyCallback;
                readyCallback = null;
            }
            catch (SocketException bind)
            {
                candidate.Stop();
                error = bind.SocketErrorCode;
            }
        }
        if (server is null)
        {
            ListenFailed(error, epoch);
            return;
        }
        _ = Accept(server, epoch);
        callback?.Invoke();
    }

    /// Asks the port's current owner who it is, then schedules the next attempt (5 s, 30 s, then every 2 min until the port
    /// frees or Stop() runs). An empty delay list gives up at once; Start() may then be called again.
    void ListenFailed(SocketError error, int epoch) => _ = Task.Run(() =>
    {
        var tokenCat = VerifiedHealth(port, DateTimeOffset.UtcNow.AddSeconds(1));
        double delay;
        lock (gate)
        {
            if (!running || generation != epoch) return;
            state = tokenCat ? TelemetryCollectorState.BusyTokenCat
                : error == SocketError.AddressAlreadyInUse ? TelemetryCollectorState.BusyOtherApp : TelemetryCollectorState.Failed;
            failure = error;
            if (retryDelays.Length == 0)
            {
                running = false;
                readyCallback = null;
                return;
            }
            delay = retryDelays[Math.Min(attempt, retryDelays.Length - 1)];
            attempt = Math.Min(attempt + 1, retryDelays.Length);
            retryAt = DateTimeOffset.UtcNow.AddSeconds(delay);
        }
        _ = Task.Delay(TimeSpan.FromSeconds(delay)).ContinueWith(_ => Listen(() => running && generation == epoch), TaskScheduler.Default);
    });

    /// Called under `gate`.
    void CloseListener()
    {
        ready = false;
        listener?.Stop();
        listener = null;
        foreach (var socket in connections) socket.Dispose();
        connections.Clear();
    }

    async Task Accept(TcpListener server, int epoch)
    {
        while (true)
        {
            Socket socket;
            try { socket = await server.AcceptSocketAsync().ConfigureAwait(false); }
            catch (Exception error) when (error is SocketException or ObjectDisposedException or InvalidOperationException)
            {
                bool current;
                lock (gate) current = running && generation == epoch && listener == server;
                // A client that gave up before its connection was accepted is not a listener failure.
                if (current && error is SocketException { SocketErrorCode: SocketError.ConnectionReset or SocketError.ConnectionAborted }) continue;
                lock (gate)
                {
                    current = running && generation == epoch && listener == server;
                    if (current) CloseListener();
                }
                if (current) ListenFailed((error as SocketException)?.SocketErrorCode ?? SocketError.SocketError, epoch);
                return;
            }
            bool accepted;
            lock (gate)
            {
                accepted = running && generation == epoch && connections.Count < MaximumConnections;
                if (accepted) connections.Add(socket);
            }
            if (accepted) _ = Serve(socket, epoch);
            else socket.Dispose();
        }
    }

    /// One request, 5 s in all, then a graceful close: shutdown, read to EOF. Microsoft documents that a port bound with
    /// SO_EXCLUSIVEADDRUSE cannot be bound again while a connection it accepted is still active after an abrupt close,
    /// which would turn a quick restart (update, relaunch) into "another app is using the port".
    async Task Serve(Socket socket, int epoch)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var chunk = new byte[65_536];
        try
        {
            var buffer = new MemoryStream();
            (int Code, byte[] Body) reply;
            while (true)
            {
                var read = await socket.ReceiveAsync(chunk, SocketFlags.None, deadline.Token).ConfigureAwait(false);
                buffer.Write(chunk, 0, read);
                var decision = TelemetryHttp.Parse(buffer.GetBuffer().AsSpan(0, (int)buffer.Length));
                if (decision is HttpDecision.Waiting)
                {
                    if (read == 0) return;
                    continue;
                }
                reply = decision is HttpDecision.Request request ? Handle(request.Path, request.Body, epoch)
                    : (((HttpDecision.Response)decision).Code, EmptyObject);
                break;
            }
            await socket.SendAsync(TelemetryHttp.Encode(reply.Code, reply.Body), SocketFlags.None, deadline.Token).ConfigureAwait(false);
            socket.Shutdown(SocketShutdown.Send);
            while (await socket.ReceiveAsync(chunk, SocketFlags.None, deadline.Token).ConfigureAwait(false) > 0) { }
        }
        catch (Exception error) when (error is OperationCanceledException or SocketException or ObjectDisposedException) { }
        finally
        {
            lock (gate) connections.Remove(socket);
            socket.Dispose();
        }
    }

    (int Code, byte[] Body) Handle(string path, byte[] body, int epoch)
    {
        lock (gate)
            if (!running || generation != epoch) return (400, EmptyObject);
        return path switch
        {
            "/v1/readings" => (200, JsonSerializer.SerializeToUtf8Bytes(Snapshot(), Json.Options)),
            "/v1/diagnostics" => (200, JsonSerializer.SerializeToUtf8Bytes(Diagnostics(), Json.Options)),
            "/health" => (200, HealthBody(port)),
            _ => (Ingest(body, path) ? 200 : 400, EmptyObject),
        };
    }

    /// What /health answers: proof that the port belongs to a TokenCat collector.
    internal static byte[] HealthBody(int port) => JsonSerializer.SerializeToUtf8Bytes(
        new { owner = "TokenCat", appIdentifier = "dev.seuput.TokenCat", schema = 1, port }, Json.Options);

    /// GET /health on the default port: another TokenCat already collects.
    public static bool IsOwnCollectorRunning(TimeSpan timeout) => VerifiedHealth(DefaultPort, Deadline(timeout));

    /// GET /v1/readings from the running app (CLI, `--diagnose`). Bounded in time and bytes; never follows a redirect.
    public static List<TelemetryReading> FetchSnapshot(TimeSpan timeout)
    {
        var deadline = Deadline(timeout);
        if (!VerifiedHealth(DefaultPort, deadline) || Fetch("/v1/readings", DefaultPort, deadline, 1_048_576) is not { } data) return [];
        try
        {
            return JsonSerializer.Deserialize<List<TelemetryReading>>(data, Json.Options) is { Count: <= MaximumReadings + MaximumLatest } readings
                   && readings.All(reading => reading is not null) ? readings : [];
        }
        catch (JsonException) { return []; }
    }

    static DateTimeOffset Deadline(TimeSpan timeout) => DateTimeOffset.UtcNow + (timeout > TimeSpan.FromMilliseconds(50) ? timeout : TimeSpan.FromMilliseconds(50));

    static bool VerifiedHealth(int port, DateTimeOffset deadline) =>
        Fetch("/health", port, deadline, 1024) is { } data && Json.Parse(data) is { } health
        && health.Field("owner")?.Text == "TokenCat" && health.Field("appIdentifier")?.Text == "dev.seuput.TokenCat"
        && health.Field("schema")?.Number == 1 && health.Field("port")?.Number == port;

    static byte[]? Fetch(string path, int port, DateTimeOffset deadline, int maximumBytes)
    {
        var remaining = deadline - DateTimeOffset.UtcNow;
        return remaining > TimeSpan.Zero ? FetchAsync(path, port, remaining, maximumBytes).GetAwaiter().GetResult() : null;
    }

    static async Task<byte[]?> FetchAsync(string path, int port, TimeSpan remaining, int maximumBytes)
    {
        using var cancel = new CancellationTokenSource(remaining);
        try
        {
            using var response = await Loopback.GetAsync($"http://127.0.0.1:{port}{path}", HttpCompletionOption.ResponseHeadersRead, cancel.Token)
                .ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK || response.Content.Headers.ContentLength > maximumBytes) return null;
            await using var stream = await response.Content.ReadAsStreamAsync(cancel.Token).ConfigureAwait(false);
            var body = new MemoryStream();
            var chunk = new byte[16_384];
            int read;
            while ((read = await stream.ReadAsync(chunk, cancel.Token).ConfigureAwait(false)) > 0)
            {
                if (body.Length + read > maximumBytes) return null;
                body.Write(chunk, 0, read);
            }
            return body.ToArray();
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or IOException) { return null; }
    }

    /// The decoder and limits without a port (checks call it directly). The status line copy is not an OTLP batch: it
    /// proves neither an export nor a restart, so only the limits change.
    internal bool Ingest(ReadOnlySpan<byte> data, string path)
    {
        if (path == TelemetryHttp.ClaudeStatusPath)
        {
            if (data.Length > TelemetryHttp.MaximumStatusBodyBytes || ClaudeUsage.Decode(data, DateTimeOffset.UtcNow) is not { } limits) return false;
            lock (gate) claudeStatus = ClaudeUsage.Merged(claudeStatus, limits);
            return true;
        }
        var signal = path switch { "/v1/logs" => "logs", "/v1/metrics" => "metrics", "/v1/traces" => "traces", _ => null };
        if (signal is null) return false;
        lock (gate) batchCounts[signal] = Math.Min(batchCounts[signal], int.MaxValue - 1) + 1;
        if (data.Length > TelemetryHttp.MaximumBodyBytes || Json.Parse(data) is not { ValueKind: JsonValueKind.Object } root
            || TelemetryDecoder.Decode(root, path) is not { } records) return false;
        var diagnostics = TelemetryDecoder.Diagnostics(root, path);
        var providers = TelemetryDecoder.Providers(root, path);
        lock (gate)
        {
            var now = DateTimeOffset.UtcNow;
            cachedSnapshot = null;
            foreach (var provider in providers) batches[provider] = now;
            readingCounts[signal] = Math.Min(readingCounts[signal], int.MaxValue - records.Count) + records.Count;
            foreach (var entry in diagnostics) TelemetryDecoder.Merge(entry, diagnosticEntries);
            foreach (var record in records)
            {
                var key = record.Key;
                if (stored.TryGetValue(key, out var previous))
                {
                    // A request ID cannot silently move to another agent or model.
                    if (previous.Reading.AgentID is { } a && record.Reading.AgentID is { } b && a != b) continue;
                    if (previous.Reading.Model is { } m && record.Reading.Model is { } n && m != n) continue;
                    stored[key] = previous.Merge(record);
                }
                else stored[key] = record;
                Remember(stored[key]);
            }
            if (stored.Count > MaximumReadings)
            {
                var keep = Newest(stored).Take(MaximumReadings).ToList();
                stored.Clear();
                foreach (var (key, record) in keep) stored[key] = record;
            }
            receivedAt = now;
            state = TelemetryCollectorState.Receiving;
        }
        return true;
    }

    static IOrderedEnumerable<KeyValuePair<string, TelemetryRecord>> Newest(Dictionary<string, TelemetryRecord> records) =>
        records.OrderByDescending(entry => entry.Value.Reading.At).ThenBy(entry => entry.Key, StringComparer.Ordinal);

    /// Keeps the newest reading per identity, preferring one that carries a rate, in a
    /// least-recently-updated store of `MaximumLatest` identities. Called under `gate`.
    void Remember(TelemetryRecord record)
    {
        var reading = record.Reading;
        var identity = string.Join('\u001f', reading.Provider.Id, reading.SessionID ?? "", reading.AgentID ?? "", reading.Model ?? "");
        touches++;
        var kept = record;
        if (latest.TryGetValue(identity, out var existing) && existing.Record.Key != record.Key
            && (existing.Record.HasRate && !record.HasRate || existing.Record.HasRate == record.HasRate && existing.Record.Reading.At > reading.At))
            kept = existing.Record;
        latest[identity] = (kept, touches);
        // Subagent identities go first, so a quiet main session keeps its last rate through a burst.
        if (latest.Count > MaximumLatest)
            latest.Remove(latest.MinBy(entry => (entry.Value.Record.Reading.AgentID is null ? 1 : 0, entry.Value.Touched)).Key);
    }
}

public static class TelemetryCollectorStateText
{
    extension(TelemetryCollectorState state)
    {
        /// Telemetry.swift `TelemetryCollectorState.status`.
        public string Status => state switch
        {
            TelemetryCollectorState.Starting => Loc("실측 준비 중", "Preparing telemetry"),
            TelemetryCollectorState.Waiting => Loc("실측 수신 대기", "Waiting for telemetry"),
            TelemetryCollectorState.Receiving => Loc("실측 수신 중", "Receiving telemetry"),
            TelemetryCollectorState.BusyTokenCat => Loc("실측 꺼짐 · 다른 TokenCat이 수집 중", "Telemetry off · another TokenCat is collecting"),
            TelemetryCollectorState.BusyOtherApp => Loc($"실측 꺼짐 · 다른 앱이 포트 {TelemetryCollector.DefaultPort} 사용 중",
                                                        $"Telemetry off · another app is using port {TelemetryCollector.DefaultPort}"),
            TelemetryCollectorState.Failed => Loc("실측 꺼짐 · 수집기를 시작하지 못함", "Telemetry off · couldn't start the collector"),
            _ => Loc("실측 꺼짐", "Telemetry off"),
        };
    }
}
