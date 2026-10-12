using System.Diagnostics;
using System.Globalization;

namespace TokenCat;

/// Replaces the mac `--live-check` (DESIGN §11 WP3): a 6 s run on a temp home with a fake system sampler. One timer at ~1 s,
/// no publish after Stop(), and a JSONL append seen within 1.5 s (one tick plus margin; on Windows the watcher may lag and the
/// poll is what counts, rule 8). Also: a pending restart notice survives a relaunch through the settings file.
public static class MonitorChecks
{
    public static List<string> Run()
    {
        var c = new Check("Monitor", "Monitor: ");
        void check(bool valid, string description) => c.That(valid, description);
        var home = Directory.CreateTempSubdirectory("tokencat-monitor-home-");
        var support = Directory.CreateTempSubdirectory("tokencat-monitor-support-");
        LiveMonitor? monitor = null;
        try
        {
            var log = Path.Combine(home.FullName, ".claude", "projects", "C--work-demo", "s1.jsonl");
            Directory.CreateDirectory(Path.GetDirectoryName(log)!);
            static string stamp(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
            var initialStamp = stamp(DateTimeOffset.UtcNow);
            File.WriteAllText(log,
                $$$"""{"type":"user","uuid":"u1","sessionId":"s1","cwd":"C:\\work\\demo","timestamp":"{{{initialStamp}}}","message":{"content":[{"type":"text"}]}}""" + "\n"
                + $$$"""{"type":"system","subtype":"turn_duration","timestamp":"{{{initialStamp}}}","durationMs":1}""" + "\n");

            var watch = Stopwatch.StartNew();
            var sampled = new List<double>();
            SystemSnapshot sampler()
            {
                lock (sampled) sampled.Add(watch.Elapsed.TotalSeconds);
                return new SystemSnapshot { CpuPercent = 5, SampledAt = DateTimeOffset.UtcNow };
            }
            var published = new List<(double At, MonitorState State)>();
            monitor = new LiveMonitor(new MonitorOptions(home.FullName, support.FullName, sampler, Environment: _ => null));
            monitor.Updated += state => { lock (published) published.Add((watch.Elapsed.TotalSeconds, state)); };
            monitor.Start();
            monitor.Start(); // Repeated starts must keep one sampling timer.
            Thread.Sleep(1_200);
            var written = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            var appendedAt = watch.Elapsed.TotalSeconds;
            File.AppendAllText(log,
                $$$"""{"type":"user","uuid":"u2","sessionId":"s1","timestamp":"{{{stamp(written)}}}","message":{"content":[{"type":"text"}]}}""" + "\n"
                + $$$$"""{"type":"assistant","uuid":"a1","sessionId":"s1","timestamp":"{{{{stamp(written)}}}}","message":{"id":"msg-1","model":"fixture-model","usage":{"output_tokens":42,"input_tokens":10}}}""" + "\n");
            Thread.Sleep(4_800);
            monitor.Stop();
            int stoppedSamples, stoppedPublishes;
            lock (sampled) stoppedSamples = sampled.Count;
            lock (published) stoppedPublishes = published.Count;
            monitor.NoteTelemetryConnected([TokenSource.Codex]);
            Thread.Sleep(400);

            var intervals = sampled.Zip(sampled.Skip(1), (a, b) => b - a).Order().ToList();
            var median = intervals.Count == 0 ? 0 : intervals[intervals.Count / 2];
            var tokenTimes = published.Where(item => item.State.TokensSampledAt is not null)
                .DistinctBy(item => item.State.TokensSampledAt).ToArray();
            var quietBeforeWrite = tokenTimes.Count(item => item.At < appendedAt) == 1;
            var liveAfterWrite = tokenTimes.Count(item => item.At >= appendedAt) >= 4;
            check(intervals.Count > 0 && Math.Abs(median - LiveMonitor.SamplingInterval) < Math.Max(0.2, LiveMonitor.SamplingInterval * 0.25),
                  $"the system sample cadence is not ~1 s (median {median:F2} s over {sampled.Count} samples)");
            check(quietBeforeWrite && liveAfterWrite && VisibleCadence(home.FullName, support.FullName),
                  "token sampling does not idle while hidden or run each second while live or visible");
            check(sampled.Count <= (int)Math.Ceiling(6 / LiveMonitor.SamplingInterval) + 2,
                  $"repeated Start() runs more than one sampling timer ({sampled.Count} samples in 6 s)");
            check(sampled.Count == stoppedSamples && published.Count == stoppedPublishes,
                  "Updated was raised or the sampler ran after Stop() returned");
            var seen = published.FirstOrDefault(item => item.At >= appendedAt
                && item.State.Tokens.Any(reading => reading.Source == TokenSource.Claude && reading.LastOutputAt == written));
            check(seen.State is not null && seen.At - appendedAt <= 1.5,
                  $"a JSONL append did not produce a token sample within 1.5 s ({(seen.State is null ? "never" : $"{seen.At - appendedAt:F2} s")})");
            var last = published.LastOrDefault().State;
            check(last is not null && last.HasSample && last.TokensSampledAt is not null && last.LogFoldersFound && last.CpuHistory.Count > 0
                  && last.TelemetryState == TelemetryCollectorState.Stopped && last.Groups.Count == 1 && last.Sessions.Blocks.Count == 1,
                  "the published state lacks the system sample, the token sample, the log folders or the session list");
            using var reopened = new LiveMonitor(new MonitorOptions(home.FullName, support.FullName, sampler, Environment: _ => null));
            check(monitor.Current.TelemetryRestartNeeded.SetEquals([TokenSource.Codex])
                  && reopened.Current.TelemetryRestartNeeded.SetEquals([TokenSource.Codex]),
                  "a client connected for telemetry is not waiting for a restart, or the notice did not survive a relaunch");
            check(RestartAfterFault(home.FullName, support.FullName),
                  "a faulted previous loop prevents Stop and Start from restarting sampling");
            using var collector = new TelemetryCollector(port: 0);
            using var retryMonitor = new LiveMonitor(new MonitorOptions(home.FullName, support.FullName, sampler,
                Telemetry: collector, Environment: _ => null));
            var retryWake = new SampleWake();
            typeof(LiveMonitor).GetField("wake", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                .SetValue(retryMonitor, retryWake);
            retryMonitor.RetryTelemetryNow();
            var retrySignal = retryWake.WaitAsync(CancellationToken.None);
            check(retrySignal.IsCompletedSuccessfully && retrySignal.Result,
                  "a user-triggered telemetry retry does not wake token sampling immediately");
        }
        finally
        {
            monitor?.Dispose();
            home.Delete(true);
            support.Delete(true);
        }
        return c.Done();
    }

    static bool VisibleCadence(string home, string support)
    {
        var idleHome = Path.Combine(home, "idle-home");
        Directory.CreateDirectory(idleHome);
        using var monitor = new LiveMonitor(new MonitorOptions(idleHome, support,
            () => new SystemSnapshot { SampledAt = DateTimeOffset.UtcNow }, Environment: _ => null));
        var samples = new List<DateTimeOffset>();
        monitor.Updated += state =>
        {
            if (state.TokensSampledAt is { } at)
                lock (samples) if (samples.Count == 0 || samples[^1] != at) samples.Add(at);
        };
        monitor.Start();
        Thread.Sleep((int)(LiveMonitor.IdleTokenInterval * 2_000 + 1_000));
        DateTimeOffset[] idle;
        lock (samples) idle = samples.ToArray();
        monitor.SetDashboardVisible(true);
        Thread.Sleep(2_200);
        DateTimeOffset[] visible;
        lock (samples) visible = samples.Skip(idle.Length).ToArray();
        monitor.Stop();
        monitor.Stopped.GetAwaiter().GetResult();
        return idle.Length >= 2 && idle.Zip(idle.Skip(1), (a, b) => (b - a).TotalSeconds).All(gap => gap >= LiveMonitor.IdleTokenInterval - 0.5)
            && visible.Length >= 2 && (visible[^1] - visible[^2]).TotalSeconds <= 1.5;
    }

    static bool RestartAfterFault(string home, string support)
    {
        using var sampled = new ManualResetEventSlim();
        using var monitor = new LiveMonitor(new MonitorOptions(home, support,
            () => { sampled.Set(); return new SystemSnapshot(); }, Environment: _ => null));
        // A prior worker fault is the boundary Start must tolerate, irrespective of which reader threw.
        typeof(LiveMonitor).GetField("loops", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .SetValue(monitor, Task.FromException(new IOException("fixture previous loop failure")));
        monitor.Start();
        var restarted = sampled.Wait(TimeSpan.FromSeconds(3));
        monitor.Stop();
        monitor.Stopped.GetAwaiter().GetResult();
        sampled.Reset();
        monitor.Start();
        restarted &= sampled.Wait(TimeSpan.FromSeconds(3));
        monitor.Stop();
        monitor.Stopped.GetAwaiter().GetResult();
        return restarted;
    }
}
