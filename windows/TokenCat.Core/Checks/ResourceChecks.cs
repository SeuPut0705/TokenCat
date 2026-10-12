using System.Text;

namespace TokenCat;

/// Bounds and invariants of the per-sample caches (TrackerChecks runs these): saturating totals, line buffers that do not pin
/// memory, the bounded wake queue and poller states, and the single-copy JSON parse accepting exactly what JsonDocument does.
static class ResourceChecks
{
    public static void Run(Action<bool, string> check)
    {
        // C3: two valid large counts never wrap negative or throw.
        var at = DateTimeOffset.Parse("2026-10-04T03:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        TokenReading Huge(string id) => new(TokenSource.Codex, id) { RecentOutputs = [new TokenOutputEvent(at, int.MaxValue)] };
        var flow = FlowSeries.Make([Huge("codex:a"), Huge("codex:b")], at);
        var parser = new TokenLogParser(TokenSource.Claude);
        foreach (var line in new[]
        {
            """{"type":"user","uuid":"h","timestamp":"2026-10-04T03:00:00Z","message":{"content":[{"type":"text"}]}}""",
            """{"type":"assistant","uuid":"a1","timestamp":"2026-10-04T03:00:01Z","message":{"id":"m1","model":"fixture-model","usage":{"output_tokens":2000000000}}}""",
            """{"type":"assistant","uuid":"a2","timestamp":"2026-10-04T03:00:02Z","message":{"id":"m2","model":"fixture-model","usage":{"output_tokens":2000000000}}}""",
        }) parser.Consume(Encoding.UTF8.GetBytes(line));
        check(flow.Total == int.MaxValue && flow.Hero[^1] == int.MaxValue && flow.ByProvider[TokenSource.Codex] == int.MaxValue
              && flow.Last?.Tokens == int.MaxValue && parser.CurrentTurnOutputTokens == int.MaxValue,
              "token totals saturate instead of wrapping or throwing");

        // C2: the omp/Pi window label multiplies without overflowing.
        check(AgentUsageHistory.WindowMinutes("9223372036854775807 hours") is null && AgentUsageHistory.WindowMinutes($"{int.MaxValue} days") is null
              && AgentUsageHistory.WindowMinutes("5 hours") == 300,
              "omp usage history: an overflowing window label is ignored, not a crash");

        // C1: a long line spanning chunks is delivered whole, and its buffer is released afterwards.
        var assembler = new LogLineAssembler();
        var lines = new List<int>();
        var longLine = new byte[300_000];
        Array.Fill(longLine, (byte)'x');
        assembler.Consume(longLine.AsSpan(0, 200_000), line => lines.Add(line.Length));
        assembler.Consume([.. longLine.AsSpan(200_000), (byte)'\n', (byte)'y', (byte)'\n'], line => lines.Add(line.Length));
        check(lines.SequenceEqual([300_000, 1]) && assembler.Pending.Capacity <= 65_536,
              "a long log line kept its buffer after it was read, or was not delivered whole");

        // The single-copy parse accepts exactly one JSON value with surrounding whitespace, a BOM and 512 levels.
        check(Json.Parse(" {\"a\":1} \r"u8) is { } value && value.Field("a")?.Number == 1 && Json.Parse("{} {}"u8) is null && Json.Parse(""u8) is null
              && Json.Parse([0xEF, 0xBB, 0xBF, (byte)'{', (byte)'}']) is not null && Json.Parse("{\"a\":1,}"u8) is null
              && Json.Parse(Encoding.UTF8.GetBytes(new string('[', 512) + new string(']', 512))) is not null
              && Json.Parse(Encoding.UTF8.GetBytes(new string('[', 513) + new string(']', 513))) is null,
              "Json.Parse accepted trailing values or rejected a BOM, whitespace or 512 levels");

        // C9: the wake queue holds at most 256 paths; more asks for a rescan instead.
        var wake = new SampleWake();
        wake.Add(Enumerable.Range(0, SampleWake.MaximumPaths + 10).Select(index => $"/logs/{index}.jsonl"));
        var (paths, rediscover) = wake.Take();
        wake.Overflow();
        var (_, overflowed) = wake.Take();
        check(paths.Count == SampleWake.MaximumPaths && rediscover && overflowed && wake.Take() is { Paths.Count: 0, Rediscover: false },
              "the token wake queue grew past its bound or lost a rescan request");

        // C4d: a slot that stayed ineligible past the idle interval is forgotten; an eligible one keeps its state.
        var poller = new LiveLimitPoller((slot, _) => Task.FromResult(new LiveLimitResult(Failed: true)));
        var kept = new LimitSlot(TokenSource.Codex, new LimitAccount("kept"));
        var dropped = new LimitSlot(TokenSource.Claude, new LimitAccount("dropped"));
        poller.Tick(at, false, new HashSet<LimitSlot> { kept, dropped }, _ => false, _ => { }).Wait();
        poller.Tick(at.AddSeconds(LiveLimits.IdleInterval + 1), false, new HashSet<LimitSlot> { kept }, _ => false, _ => { }).Wait();
        check(poller.Held == 1, "live limit polling kept the state of an account that is no longer eligible");
    }
}
