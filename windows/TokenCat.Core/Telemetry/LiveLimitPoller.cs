namespace TokenCat;

/// Independent per-account cadence, in-flight exclusion and failure backoff. The reader owns rejected token hashes.
public sealed class LiveLimitPoller(Func<LimitSlot, CancellationToken, Task<LiveLimitResult>> read)
{
    sealed class State
    {
        public DateTimeOffset? Last, RetryAt;
        public int Failures;
        public bool InFlight;
    }
    readonly object gate = new();
    readonly Dictionary<LimitSlot, State> states = [];
    bool wasOpen;

    public Task Tick(DateTimeOffset now, bool open, IReadOnlySet<LimitSlot> slots, Func<LimitSlot, bool> live,
        Action<LiveLimitResult> deliver, CancellationToken token = default)
    {
        var started = new List<LimitSlot>();
        lock (gate)
        {
            var opened = open && !wasOpen;
            wasOpen = open;
            foreach (var slot in slots)
            {
                if (!states.TryGetValue(slot, out var state)) states[slot] = state = new();
                if (state.InFlight || !LiveLimits.Due(state.Last, state.RetryAt, now, live(slot), open, opened)) continue;
                state.Last = now;
                state.InFlight = true;
                started.Add(slot);
            }
        }
        return Task.WhenAll(started.Select(slot => Finish(slot, token, deliver)));
    }

    async Task Finish(LimitSlot slot, CancellationToken token, Action<LiveLimitResult> deliver)
    {
        LiveLimitResult result;
        try { result = await read(slot, token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { result = new(Failed: true); }
        lock (gate)
        {
            var state = states[slot];
            state.InFlight = false;
            state.Failures = result.Failed ? Math.Min(state.Failures + 1, 30) : 0;
            state.RetryAt = result.Failed ? state.Last?.AddSeconds(60 * Math.Pow(2, Math.Min(state.Failures, 5) - 1)) : null;
        }
        if (!token.IsCancellationRequested && (result.Codex is not null || result.Claude is not null))
            deliver(result with { Slot = slot });
    }
}
