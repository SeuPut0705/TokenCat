using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace TokenCat;

/// TelemetryChecks.swift `runTelemetryLifecycleChecks`: real loopback listeners on `port` and `port + 1` (a free pair when
/// null, never the app's port), so it stays out of Suites.RunAll: `TokenCat.Checks -- --telemetry-lifecycle-checks [port]`
/// and the App's `--telemetry-lifecycle-checks`. On Windows it also runs the exact statusLine command TelemetrySetup writes
/// through Git Bash and Windows PowerShell (DESIGN §7.4), as Claude Code would.
public static class TelemetryLifecycleChecks
{
    public static List<string> Run(int? port)
    {
        if ((port ?? TestPort()) is not { } chosen || chosen is <= 0 or >= 65_535
            || chosen == TelemetryCollector.DefaultPort || chosen + 1 == TelemetryCollector.DefaultPort)
            return ["no free loopback test port"];
        Console.WriteLine($"Telemetry lifecycle ports {chosen}, {chosen + 1}");
        return Run(chosen);
    }

    static List<string> Run(int port)
    {
        var c = new Check("Telemetry lifecycle");
        void check(bool valid, string description) => c.That(valid, description);
        var collector = new TelemetryCollector(port);
        var blocked = new TelemetryCollector(port, [0.05, 0.1]);
        var callbacks = new CallbackProbe();
        try
        {
            collector.Start(() => callbacks.DidReady(collector.IsRunning));
            collector.Start(callbacks.DidDuplicate);
            check(Until(() => callbacks.ReadyCount == 1), "Listener readiness did not deliver its callback");
            check(callbacks.OnlyReadyCallbacks && collector.IsRunning, "The ready callback preceded listener readiness");
            // The status line bridge's route over a real loopback socket: limits are kept, a browser Origin is refused.
            const string limited = """{"cwd":"/tmp/project","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1790007980}}}""";
            check(PostStatus(port, limited, origin: "null") == 403 && collector.ClaudeLimits.IsEmpty
                  && PostStatus(port, limited) == 200 && Until(() => collector.ClaudeLimits.FiveHour?.UsedPercent == 12),
                  "The status line route did not keep limits over loopback or accepted a browser Origin");
            if (OperatingSystem.IsWindows()) BridgeChecks(port, collector, c);
            else { c.Skip(); c.Skip(); } // the Git Bash and PowerShell bridge runs
            collector.Start(callbacks.DidDuplicate);
            Thread.Sleep(50);
            check(callbacks.ReadyCount == 1 && callbacks.DuplicateCount == 0, "A duplicate start delivered or replaced a callback");

            blocked.Start(callbacks.DidRetry);
            check(Until(() => blocked.State == TelemetryCollectorState.BusyTokenCat), "A port held by another TokenCat was not identified by its /health");
            check(Until(() => blocked.NextRetryAt != null) && !blocked.IsRunning && callbacks.RetryCount == 0,
                  "A failed listener delivered a ready callback or scheduled no retry");
            // Past the schedule the last delay repeats, so a port freed minutes later is still taken over.
            Thread.Sleep(600);
            check(Until(() => blocked.NextRetryAt != null && blocked.State == TelemetryCollectorState.BusyTokenCat) && !blocked.IsRunning,
                  "Retrying stopped after the last scheduled delay");
            collector.Stop();
            check(Until(() => callbacks.RetryCount == 1) && blocked.IsRunning && blocked.State == TelemetryCollectorState.Waiting,
                  "A retry did not take over the port once it was released");
            blocked.Stop();
            check(blocked.State == TelemetryCollectorState.Stopped && blocked.NextRetryAt == null, "Stopping did not cancel the retry state");

            // A port held by a non-TokenCat process (no /health answer) is reported as another app.
            using (var other = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
            {
                var bound = true;
                try
                {
                    other.Bind(new IPEndPoint(IPAddress.Loopback, port + 1));
                    other.Listen(1);
                }
                catch (SocketException) { bound = false; }
                var squatted = new TelemetryCollector(port + 1, []);
                squatted.Start(callbacks.DidDuplicate);
                check(bound && Until(() => squatted.State == TelemetryCollectorState.BusyOtherApp) && !squatted.IsRunning && squatted.NextRetryAt == null,
                      "A port held by another app was not reported as such, or retried past its schedule");
                squatted.Stop();
            }

            var stoppedCount = callbacks.ReadyCount;
            Thread.Sleep(50);
            check(!collector.IsRunning && callbacks.ReadyCount == stoppedCount, "A stopped listener delivered a late callback");
            collector.Start(() => callbacks.DidReady(collector.IsRunning));
            check(Until(() => callbacks.ReadyCount == 2) && callbacks.DuplicateCount == 0, "A restart reused an old generation's callback");

            collector.Stop();
            collector.Start(() => callbacks.DidReady(collector.IsRunning));
            collector.Stop();
            var cancelledCount = callbacks.ReadyCount;
            Thread.Sleep(50);
            check(!collector.IsRunning && callbacks.ReadyCount == cancelledCount, "A cancelled pending start delivered a callback after stop");

            collector.Start(() =>
            {
                collector.Stop();
                callbacks.DidCloseFromCallback();
            });
            check(Until(() => callbacks.ClosedCount == 1) && !collector.IsRunning, "Stopping from the ready callback deadlocked or left the listener running");

            // RetryNow while a retry waits: one listener starts at once and the pending retry is cancelled. The retry waits 5 s,
            // so a slow release of the port still leaves time to start before it.
            var holder = new TelemetryCollector(port);
            var retrying = new TelemetryCollector(port, [5]);
            var retryCallbacks = new CallbackProbe();
            try
            {
                holder.Start();
                check(Until(() => holder.IsRunning), "retryNow: the holder did not take the test port");
                retrying.Start(() => retryCallbacks.DidReady(retrying.IsRunning));
                check(Until(() => retrying.NextRetryAt != null) && !retrying.IsRunning && retrying.State == TelemetryCollectorState.BusyTokenCat,
                      "retryNow: no retry was scheduled behind a busy port");
                var scheduled = retrying.NextRetryAt ?? DateTimeOffset.UtcNow;
                var releaseStart = DateTimeOffset.UtcNow;
                holder.Stop();
                var released = Until(() => IsFree(port), timeout: 5);
                var releaseMs = (int)(DateTimeOffset.UtcNow - releaseStart).TotalMilliseconds;
                check(released, $"retryNow: the holder did not release the test port within 5 s ({releaseMs} ms)");
                var retryStart = DateTimeOffset.UtcNow;
                retrying.RetryNow();
                var startedEarly = Until(() => retrying.IsRunning, deadline: scheduled);
                var startMs = (int)(DateTimeOffset.UtcNow - retryStart).TotalMilliseconds;
                check(startedEarly && retrying.State == TelemetryCollectorState.Waiting && retrying.NextRetryAt == null,
                      $"retryNow did not start the listener before the scheduled retry (release {releaseMs} ms, start {startMs} ms, retry due {(int)(scheduled - retryStart).TotalMilliseconds} ms)");
                retrying.RetryNow();
                // Past the cancelled deadline a stale attempt would open a second listener, fail on the port and drop the first.
                var wait = scheduled.AddSeconds(0.4) - DateTimeOffset.UtcNow;
                if (wait > TimeSpan.Zero) Thread.Sleep(wait);
                check(retrying.IsRunning && retrying.State == TelemetryCollectorState.Waiting && retrying.NextRetryAt == null
                      && retryCallbacks.ReadyCount == 1 && retryCallbacks.OnlyReadyCallbacks,
                      "retryNow while waiting left more than one listener or did not cancel the pending retry");
            }
            finally
            {
                holder.Stop();
                retrying.Stop();
            }
        }
        finally
        {
            blocked.Stop();
            collector.Stop();
        }
        return c.Done();
    }

    /// The exact `statusLine.command` from settings TelemetrySetup wrote, run through Git Bash (`bash -c`) and Windows
    /// PowerShell (`-Command`) with a status JSON holding Korean on stdin, against `collector` on `port` (the generated
    /// script is rewritten for that port). Both must deliver the limits and print nothing.
    static void BridgeChecks(int port, TelemetryCollector collector, Check c)
    {
        var home = Directory.CreateTempSubdirectory("tokencat-bridge-checks-");
        try
        {
            var support = Path.Combine(home.FullName, "AppData", "Local", "TokenCat");
            new TelemetrySetup(home.FullName, support).Connect();
            File.WriteAllText(Path.Combine(support, TelemetrySetup.StatusLineScriptName), TelemetrySetup.StatusLineScript(port), Encoding.ASCII);
            var settings = Json.ParseNode(File.ReadAllBytes(AppPaths.ClaudeSettings(home.FullName)));
            var command = settings?["statusLine"]?["command"]?.GetValue<string>() ?? "";
            var gitBash = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "bin", "bash.exe");
            (string Name, string File, string[] Arguments)[] shells =
                [("Git Bash", gitBash, ["-c", command]), ("Windows PowerShell", "powershell.exe", ["-NoProfile", "-Command", command])];
            var percent = 20;
            foreach (var (name, file, arguments) in shells)
            {
                if (name == "Git Bash" && !File.Exists(gitBash))
                {
                    Console.WriteLine($"Telemetry lifecycle: no Git Bash at {gitBash}; the bash route was not run");
                    c.Skip();
                    continue;
                }
                percent++;
                var input = Encoding.UTF8.GetBytes("""{"cwd":"C:\\Users\\홍길동\\프로젝트","rate_limits":{"five_hour":{"used_percentage":"""
                    + percent + ""","resets_at":1790007980}}}""");
                var output = RunProcess(file, arguments, input);
                c.That(output == "" && Until(() => collector.ClaudeLimits.FiveHour?.UsedPercent == percent, timeout: 5),
                       $"The status line bridge command did not deliver the limits through {name}, or printed something");
            }
        }
        finally
        {
            try { home.Delete(true); }
            catch (IOException) { }
        }
    }

    /// Standard output, or null when the process did not end within 60 s (Windows PowerShell can start slowly on CI).
    static string? RunProcess(string file, string[] arguments, byte[] input)
    {
        var start = new ProcessStartInfo(file)
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        _ = process.StandardError.ReadToEndAsync();
        process.StandardInput.BaseStream.Write(input);
        process.StandardInput.Close();
        if (process.WaitForExit(60_000)) return output.Result;
        process.Kill(entireProcessTree: true);
        return null;
    }

    static int? PostStatus(int port, string body, string? origin = null)
    {
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(3) };
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}{TelemetryHttp.ClaudeStatusPath}")
        {
            Content = new ByteArrayContent(Encoding.UTF8.GetBytes(body)),
        };
        request.Content.Headers.ContentType = new("application/json");
        if (origin is not null) request.Headers.Add("Origin", origin);
        try
        {
            using var response = client.Send(request);
            return (int)response.StatusCode;
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException) { return null; }
    }

    /// `deadline` is a hard end (something is scheduled at it), so it gets no last look past it.
    static bool Until(Func<bool> condition, double timeout = 2, DateTimeOffset? deadline = null)
    {
        var end = deadline ?? DateTimeOffset.UtcNow.AddSeconds(timeout);
        while (DateTimeOffset.UtcNow < end)
        {
            if (condition()) return true;
            Thread.Sleep(10);
        }
        return deadline is null && condition();
    }

    /// True when the collector could bind `port` right now: the same exclusive loopback bind, closed again at once.
    static bool IsFree(int port)
    {
        var probe = new TcpListener(IPAddress.Loopback, port) { ExclusiveAddressUse = true };
        try
        {
            probe.Start();
            return true;
        }
        catch (SocketException) { return false; }
        finally { probe.Stop(); }
    }

    /// A free loopback port whose next port is free too; never the app's port. Below the ephemeral range (49152+), where a
    /// squatting socket was not seen as busy on macOS.
    static int? TestPort()
    {
        for (var attempt = 0; attempt < 64; attempt++)
        {
            var port = Random.Shared.Next(40_000, 48_001);
            if (port != TelemetryCollector.DefaultPort && port + 1 != TelemetryCollector.DefaultPort && IsFree(port) && IsFree(port + 1)) return port;
        }
        return null;
    }

    sealed class CallbackProbe
    {
        readonly Lock gate = new();
        int ready, duplicate, closed, retry;
        bool onlyReady = true;
        public int ReadyCount { get { lock (gate) return ready; } }
        public int DuplicateCount { get { lock (gate) return duplicate; } }
        public int ClosedCount { get { lock (gate) return closed; } }
        public int RetryCount { get { lock (gate) return retry; } }
        public bool OnlyReadyCallbacks { get { lock (gate) return onlyReady; } }
        public void DidRetry() { lock (gate) retry++; }
        public void DidReady(bool isRunning) { lock (gate) { ready++; onlyReady = onlyReady && isRunning; } }
        public void DidDuplicate() { lock (gate) duplicate++; }
        public void DidCloseFromCallback() { lock (gate) closed++; }
    }
}
