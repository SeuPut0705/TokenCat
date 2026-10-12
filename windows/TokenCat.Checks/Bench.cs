using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace TokenCat;

/// `--bench-sample [home] [--synthetic] [--iterations N]`: times LiveMonitor's per-sample pipeline (tracker sample, account
/// refresh, limit records, speed apply, presentation rebuild) without telemetry or settings writes. Read-only on `home`.
/// `--synthetic` writes a large temp home first (500 logs, multi-MB tails, subagents) and deletes it afterwards.
/// File-system call counts appear when a `tokencat_io_counts` interposer is preloaded (DYLD_INSERT_LIBRARIES/LD_PRELOAD).
static class Bench
{
    delegate void IoCounts(long[] counts);

    public static int Run(string[] args)
    {
        var synthetic = args.Contains("--synthetic");
        var iterations = args.SkipWhile(arg => arg != "--iterations").Skip(1).Select(int.Parse).FirstOrDefault(60);
        var home = args.FirstOrDefault(arg => !arg.StartsWith("--", StringComparison.Ordinal) && !int.TryParse(arg, out _)) ?? AppPaths.Home;
        string? temp = null;
        var now = DateTimeOffset.UtcNow;
        if (synthetic)
        {
            temp = home = Path.Combine(Path.GetTempPath(), "tokencat-bench-" + Guid.NewGuid().ToString("N")[..8]);
            var written = Synthetic.Write(home, now);
            Console.WriteLine($"synthetic home: {written / 1_048_576.0:F0} MB in {Synthetic.Logs.Count} logs");
        }
        try { return Measure(home, iterations, synthetic); }
        finally { if (temp is not null) Directory.Delete(temp, true); }
    }

    /// One phase of one sample: wall time, bytes allocated on this thread, and open/stat/opendir calls.
    readonly record struct Cost(double Ms, long Bytes, long Opens, long Stats, long Dirs)
    {
        public static Cost operator +(Cost a, Cost b) => new(a.Ms + b.Ms, a.Bytes + b.Bytes, a.Opens + b.Opens, a.Stats + b.Stats, a.Dirs + b.Dirs);
    }

    static readonly string[] Phases = ["tracker", "accounts", "limit records", "presentation"];

    static int Measure(string home, int iterations, bool synthetic)
    {
        // The preloaded interposer: already mapped, so loading it by path returns the same image and its counters.
        var preload = Environment.GetEnvironmentVariable("DYLD_INSERT_LIBRARIES") ?? Environment.GetEnvironmentVariable("LD_PRELOAD");
        var counts = preload is { Length: > 0 } && NativeLibrary.TryLoad(preload, out var library)
            && NativeLibrary.TryGetExport(library, "tokencat_io_counts", out var export) ? Marshal.GetDelegateForFunctionPointer<IoCounts>(export) : null;
        var io = new long[3];
        Cost Timed(Action action)
        {
            counts?.Invoke(io);
            var (opens, stats, dirs) = (io[0], io[1], io[2]);
            var bytes = GC.GetAllocatedBytesForCurrentThread();
            var start = Stopwatch.GetTimestamp();
            action();
            var ms = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
            var allocated = GC.GetAllocatedBytesForCurrentThread() - bytes;
            counts?.Invoke(io);
            return new(ms, allocated, io[0] - opens, io[1] - stats, io[2] - dirs);
        }

        var pipeline = new Pipeline(home, Timed, synthetic);
        var peak = 0L;
        Cost[] Once(Action? between = null)
        {
            between?.Invoke();
            var phases = pipeline.Sample();
            peak = Math.Max(peak, Environment.WorkingSet);
            return phases;
        }

        var cold = Once();
        Console.WriteLine($"rows: {pipeline.Rows}");
        Report("cold (discovery + tails)", [cold], counts is not null);
        for (var i = 0; i < 3; i++) Once(); // JIT warm-up of steady paths
        var gc = (GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2));
        Report("steady (no changes)", [.. Enumerable.Range(0, iterations).Select(_ => Once())], counts is not null);
        Console.WriteLine($"  gc during steady: gen0 {GC.CollectionCount(0) - gc.Item1}, gen1 {GC.CollectionCount(1) - gc.Item2}, gen2 {GC.CollectionCount(2) - gc.Item3}");
        if (synthetic)
        {
            var appendTargets = Synthetic.Logs.Take(20).ToArray();
            var n = 0;
            Report("append (20 logs grow 1 line each)", [.. Enumerable.Range(0, iterations).Select(_ => Once(() =>
            {
                foreach (var path in appendTargets) File.AppendAllText(path, Synthetic.AppendLine(path, DateTimeOffset.UtcNow, n++));
                pipeline.NoteChanged(appendTargets);
            }))], counts is not null);
        }
        Report("discovery each sample", [.. Enumerable.Range(0, Math.Max(5, iterations / 6)).Select(_ => Once(pipeline.Rediscover))], counts is not null);
        Console.WriteLine($"peak working set: {peak / 1_048_576.0:F1} MB, managed heap: {GC.GetTotalMemory(false) / 1_048_576.0:F1} MB");
        return 0;
    }

    static void Report(string name, IReadOnlyList<Cost[]> runs, bool io)
    {
        string Line(IReadOnlyList<Cost> costs)
        {
            var ms = costs.Select(cost => cost.Ms).Order().ToArray();
            var text = $"mean {ms.Average():F2} ms, p50 {ms[ms.Length / 2]:F2}, max {ms[^1]:F2}; alloc {costs.Average(cost => cost.Bytes) / 1024:F0} KB";
            return io ? text + $"; open {costs.Average(cost => cost.Opens):F1}, stat {costs.Average(cost => cost.Stats):F1}, opendir {costs.Average(cost => cost.Dirs):F1}" : text;
        }
        Console.WriteLine($"{name}, n={runs.Count}: {Line([.. runs.Select(run => run.Aggregate((a, b) => a + b))])}");
        for (var phase = 0; phase < Phases.Length; phase++) Console.WriteLine($"    {Phases[phase],-14}{Line([.. runs.Select(run => run[phase])])}");
    }

    /// LiveMonitor.SampleTokens and Publish, with no telemetry collector and no settings store. Like the monitor, the limit
    /// rows and the omp/Pi records use the tracker's account reader, which the tracker refreshes once a sample. A synthetic
    /// home is measured alone: no environment variable (CODEX_HOME, CLAUDE_CONFIG_DIR, XDG_*) or Claude desktop history adds
    /// the real logs or limits.
    sealed class Pipeline
    {
        readonly TokenTracker tracker;
        readonly LimitAccountReader limitAccounts;
        readonly AgentUsageHistoryReader agentUsage;
        readonly ClaudeUsage.DesktopReader desktop;
        readonly Func<Action, Cost> timed;

        public Pipeline(string home, Func<Action, Cost> timed, bool synthetic)
        {
            this.timed = timed;
            Func<string, string?> environment = synthetic ? _ => null : Environment.GetEnvironmentVariable;
            tracker = new(home, environment: environment);
            limitAccounts = tracker.AccountReader;
            agentUsage = new(home, environment, limitAccounts);
            desktop = new(synthetic ? [] : AppPaths.ClaudeDesktopHistory());
        }
        public int Rows { get; private set; }
        public void Rediscover() => tracker.Rediscover();
        public void NoteChanged(IEnumerable<string> paths) => tracker.NoteChanged(paths);

        /// The cost of each of `Phases`.
        public Cost[] Sample()
        {
            List<TokenReading> logs = [];
            Dictionary<TokenSource, LimitAccount> defaults = [];
            Dictionary<TokenSource, IReadOnlyList<LimitAccount>> known = [];
            AgentUsageHistory.Limits agent = AgentUsageHistory.Limits.Empty;
            var claude = new Dictionary<string, ClaudeUsageLimits>() as IReadOnlyDictionary<string, ClaudeUsageLimits>;
            var tracking = timed(() => logs = tracker.Sample());
            var accounts = timed(() =>
            {
                // Refreshed by tracker.Sample().
                defaults = TokenSource.DefaultClients.Where(source => limitAccounts.DefaultAccount(source) is not null)
                    .ToDictionary(source => source, source => limitAccounts.DefaultAccount(source)!);
                known = TokenSource.DefaultClients.ToDictionary(source => source, source => limitAccounts.KnownAccounts(source));
            });
            var records = timed(() =>
            {
                agent = agentUsage.Read();
                foreach (var (provider, values) in agent.Accounts)
                    known[provider] = known.GetValueOrDefault(provider, []).Concat(values).Distinct().OrderBy(account => account.Key, StringComparer.Ordinal).ToArray();
                var desktopLimits = desktop.Read(limitAccounts.DefaultClaudeOrganizationID);
                claude = ClaudeLimitsByAccount.Merged(new Dictionary<string, ClaudeUsageLimits>(), agent.Claude);
                if (!desktopLimits.IsEmpty)
                    claude = ClaudeLimitsByAccount.Merged(claude, new Dictionary<string, ClaudeUsageLimits> { [ClaudeLimitsByAccount.LegacyKey] = desktopLimits });
            });
            var presentation = timed(() =>
            {
                var readings = TokenSpeed.Apply(logs, []);
                var now = DateTimeOffset.UtcNow;
                _ = SessionPresentation.UsageLimits(readings, agent.Codex, claude, defaults, known, now);
                _ = FlowSeries.Make(readings, now);
                var groups = SessionPresentation.Groups(readings, now);
                _ = SessionListModel.Make(readings, now, false, new HashSet<TokenSource>(), groups: groups);
                _ = readings.Where(reading => !SessionPresentation.IsTelemetry(reading)).Select(reading => reading.LastOutputAt).Max();
                Rows = readings.Count;
            });
            return [tracking, accounts, records, presentation];
        }
    }

    /// A temp home shaped like a heavy user's: Claude main sessions and subagents, Codex rollouts; a tenth are multi-MB.
    static class Synthetic
    {
        static string Ts(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        static readonly string Filler = string.Concat(Enumerable.Repeat("lorem ipsum dolor sit amet consectetur ", 600));
        /// Every log written, in order: the first ones are the most recently active Claude sessions.
        public static List<string> Logs { get; } = [];

        public static long Write(string home, DateTimeOffset now)
        {
            long total = 0;
            var random = new Random(7);
            for (var i = 0; i < 500; i++)
            {
                var large = i % 10 == 0;
                var target = large ? 3_000_000 + random.Next(2_000_000) : 40_000 + random.Next(160_000);
                var end = now.AddSeconds(-random.Next(i < 150 ? 1_800 : 86_400));
                string path;
                Func<int, DateTimeOffset, string> line;
                if (i < 300)
                {
                    var session = Guid.NewGuid().ToString();
                    var project = Path.Combine(home, ".claude", "projects", $"-Users-bench-proj{i % 40}");
                    path = Path.Combine(project, session + ".jsonl");
                    line = (n, at) => Claude(session, $"/Users/bench/proj{i % 40}", n, at, random);
                    if (i % 3 == 0)
                    {
                        // Subagents of this session.
                        for (var s = 0; s < 2; s++)
                        {
                            var agent = Path.Combine(project, session, "subagents", $"agent-a{i:x4}{s}.jsonl");
                            total += Fill(agent, 30_000 + random.Next(300_000), end, (n, at) => Claude(session, $"/Users/bench/proj{i % 40}", n, at, random, sidechain: true));
                        }
                    }
                }
                else
                {
                    var session = Guid.NewGuid().ToString();
                    var day = end.UtcDateTime;
                    path = Path.Combine(home, ".codex", "sessions", day.ToString("yyyy", CultureInfo.InvariantCulture), day.ToString("MM", CultureInfo.InvariantCulture),
                        day.ToString("dd", CultureInfo.InvariantCulture), $"rollout-{day:yyyy-MM-dd'T'HH-mm-ss}-{session}.jsonl");
                    File.WriteAllText(EnsureDirectory(path), T("""{"timestamp":"@0@","type":"session_meta","payload":{"id":"@1@","timestamp":"@0@","cwd":"/Users/bench/codex@2@","originator":"codex_cli_rs","cli_version":"0.50.0","instructions":"@3@"}}""",
                        Ts(end.AddHours(-2)), session, i % 30, Filler[..4000]) + "\n");
                    line = (n, at) => Codex(n, at, random);
                }
                total += Fill(path, target, end, line);
            }
            return total;
        }

        static string EnsureDirectory(string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            return path;
        }

        static long Fill(string path, int target, DateTimeOffset end, Func<int, DateTimeOffset, string> line)
        {
            Logs.Add(path);
            var lines = new List<string>();
            var size = 0;
            for (var n = 0; size < target; n++)
            {
                var text = line(n, default);
                lines.Add(text);
                size += text.Length + 1;
            }
            // Timestamps run up to `end`, a second apart, newest last.
            var builder = new StringBuilder(size + lines.Count * 4);
            for (var n = 0; n < lines.Count; n++) builder.Append(lines[n].Replace("@TS@", Ts(end.AddSeconds(n - lines.Count + 1)))).Append('\n');
            using (var writer = new StreamWriter(EnsureDirectory(path), append: true)) writer.Write(builder);
            File.SetLastWriteTimeUtc(path, end.UtcDateTime);
            return new FileInfo(path).Length;
        }

        /// `@0@`, `@1@`… replaced by the arguments.
        static string T(string template, params object[] values)
        {
            for (var i = 0; i < values.Length; i++) template = template.Replace($"@{i}@", Convert.ToString(values[i], CultureInfo.InvariantCulture));
            return template;
        }

        static string Claude(string session, string cwd, int n, DateTimeOffset _, Random random, bool sidechain = false)
        {
            var head = T("""{"parentUuid":"u@0@","isSidechain":@1@,"userType":"external","cwd":"@2@","sessionId":"@3@","version":"2.0.14","gitBranch":"main",""",
                n - 1, sidechain ? "true" : "false", cwd, session) + "\"";
            return head + ((n % 3) switch
            {
                0 when n % 30 == 0 => T("""type":"user","message":{"role":"user","content":"@0@"},"uuid":"u@1@","timestamp":"@TS@"}""", Filler[..300], n),
                0 => T("""type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_@0@","type":"tool_result","content":"@1@","is_error":false}]},"uuid":"u@2@","timestamp":"@TS@","toolUseResult":{"stdout":"@3@","stderr":"","interrupted":false}}""",
                    n - 1, Filler[..random.Next(1_000, 20_000)], n, Filler[..random.Next(500, 8_000)]),
                1 => T("""message":{"id":"msg_@0@","type":"message","role":"assistant","model":"claude-opus-4-1","content":[{"type":"thinking","thinking":"@1@","signature":"sig"}],"stop_reason":null,"usage":{"input_tokens":4,"cache_creation_input_tokens":1200,"cache_read_input_tokens":54000,"output_tokens":@2@,"service_tier":"standard"}},"requestId":"req_@0@","type":"assistant","uuid":"u@0@","timestamp":"@TS@"}""",
                    n, Filler[..random.Next(200, 3_000)], random.Next(10, 900)),
                _ => T("""message":{"id":"msg_@0@","type":"message","role":"assistant","model":"claude-opus-4-1","content":[{"type":"tool_use","id":"toolu_@1@","name":"Bash","input":{"command":"@2@"}}],"stop_reason":"tool_use","usage":{"input_tokens":4,"cache_creation_input_tokens":1200,"cache_read_input_tokens":54000,"output_tokens":@3@,"service_tier":"standard"}},"requestId":"req_@0@","type":"assistant","uuid":"u@1@","timestamp":"@TS@"}""",
                    n - 1, n, Filler[..random.Next(80, 600)], random.Next(10, 900)),
            });
        }

        static string Codex(int n, DateTimeOffset _, Random random) => (n % 6) switch
        {
            0 when n % 60 == 0 => T("""{"timestamp":"@TS@","type":"turn_context","payload":{"turn_id":"t@0@","cwd":"/Users/bench/codex","approval_policy":"on-request","model":"gpt-5-codex","effort":"high","summary":"auto"}}""", n),
            0 => T("""{"timestamp":"@TS@","type":"event_msg","payload":{"type":"agent_reasoning","text":"@0@"}}""", Filler[..random.Next(100, 900)]),
            1 => T("""{"timestamp":"@TS@","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"@0@","call_id":"call_@1@"}}""", Filler[..random.Next(80, 600)], n),
            2 => T("""{"timestamp":"@TS@","type":"response_item","payload":{"type":"function_call_output","call_id":"call_@0@","output":"@1@"}}""", n - 1, Filler[..random.Next(1_000, 20_000)]),
            3 => T("""{"timestamp":"@TS@","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":@0@,"cached_input_tokens":@1@,"output_tokens":@2@,"reasoning_output_tokens":@3@,"total_tokens":@4@},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":1040},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_in_seconds":4000},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_in_seconds":300000}}}}""",
                n * 1000, n * 900, n * 40, n * 10, n * 1040),
            4 => T("""{"timestamp":"@TS@","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"@0@"}],"encrypted_content":"@1@"}}""", Filler[..random.Next(100, 900)], Filler[..random.Next(500, 4_000)]),
            _ => T("""{"timestamp":"@TS@","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"@0@"}]}}""", Filler[..random.Next(100, 2_000)]),
        };

        public static string AppendLine(string path, DateTimeOffset at, int n) =>
            (path.Replace('\\', '/').Contains("/.codex/", StringComparison.Ordinal)
                ? T("""{"timestamp":"@TS@","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"output_tokens":@0@},"last_token_usage":{"output_tokens":40}}}}""", 1_000_000 + n * 40)
                : T("""{"type":"assistant","isSidechain":false,"timestamp":"@TS@","uuid":"append@0@","message":{"id":"append@0@","model":"claude-opus-4-1","content":[{"type":"text","text":"x"}],"usage":{"output_tokens":@1@}}}""", n, 30 + n % 50))
            .Replace("@TS@", Ts(at)) + "\n";
    }
}
