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
            File.WriteAllText(log, $$$"""{"type":"user","uuid":"u1","sessionId":"s1","cwd":"C:\\work\\demo","timestamp":"{{{stamp(DateTimeOffset.UtcNow)}}}","message":{"content":[{"type":"text"}]}}""" + "\n");

            var watch = Stopwatch.StartNew();
            var sampled = new List<double>();
            SystemSnapshot sampler()
            {
                lock (sampled) sampled.Add(watch.Elapsed.TotalSeconds);
                return new SystemSnapshot { CpuPercent = 5, SampledAt = DateTimeOffset.UtcNow };
            }
            var published = new List<(double At, MonitorState State)>();
            monitor = new LiveMonitor(new MonitorOptions(home.FullName, support.FullName, sampler));
            monitor.Updated += state => { lock (published) published.Add((watch.Elapsed.TotalSeconds, state)); };
            monitor.Start();
            monitor.Start(); // Repeated starts must keep one sampling timer.
            Thread.Sleep(1_200);
            var written = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            var appendedAt = watch.Elapsed.TotalSeconds;
            File.AppendAllText(log, $$$$"""{"type":"assistant","uuid":"a1","sessionId":"s1","timestamp":"{{{{stamp(written)}}}}","message":{"id":"msg-1","model":"fixture-model","usage":{"output_tokens":42,"input_tokens":10}}}""" + "\n");
            Thread.Sleep(4_800);
            monitor.Stop();
            int stoppedSamples, stoppedPublishes;
            lock (sampled) stoppedSamples = sampled.Count;
            lock (published) stoppedPublishes = published.Count;
            monitor.NoteTelemetryConnected([TokenSource.Codex]);
            Thread.Sleep(400);

            var intervals = sampled.Zip(sampled.Skip(1), (a, b) => b - a).Order().ToList();
            var median = intervals.Count == 0 ? 0 : intervals[intervals.Count / 2];
            check(intervals.Count > 0 && Math.Abs(median - LiveMonitor.SamplingInterval) < Math.Max(0.2, LiveMonitor.SamplingInterval * 0.25),
                  $"the system sample cadence is not ~1 s (median {median:F2} s over {sampled.Count} samples)");
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
            var reopened = new LiveMonitor(new MonitorOptions(home.FullName, support.FullName, sampler));
            check(monitor.Current.TelemetryRestartNeeded.SetEquals([TokenSource.Codex])
                  && reopened.Current.TelemetryRestartNeeded.SetEquals([TokenSource.Codex]),
                  "a client connected for telemetry is not waiting for a restart, or the notice did not survive a relaunch");
        }
        finally
        {
            monitor?.Dispose();
            home.Delete(true);
            support.Delete(true);
        }
        return c.Done();
    }
}
