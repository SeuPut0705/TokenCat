namespace TokenCat;

/// Independent per-account cadence, in-flight exclusion and failure backoff. The reader owns rejected token hashes.
/// Ineligible slots keep their cadence for one hour after the last read; an in-flight read or pending backoff also keeps them.
public sealed class LiveLimitPoller
{
    sealed class State
    {
        public DateTimeOffset? Last, PreviousLast, RetryAt;
        public int Failures;
        public bool InFlight;
    }
    readonly object gate;
    readonly Func<LimitSlot, CancellationToken, Task<LiveLimitResult>> read;
    readonly Action<LimitSlot>? forget;
    readonly Dictionary<LimitSlot, State> states = [];
    bool wasOpen;
    int generation;
    public const double Retention = 3_600;

    public LiveLimitPoller(Func<LimitSlot, CancellationToken, Task<LiveLimitResult>> read, Action<LimitSlot>? forget = null)
        : this(read, forget, new object()) { }

    /// The monitor shares its lock so cancellation and publication are atomic without an inverted lock order.
    internal LiveLimitPoller(Func<LimitSlot, CancellationToken, Task<LiveLimitResult>> read, Action<LimitSlot>? forget, object gate)
    {
        this.read = read;
        this.forget = forget;
        this.gate = gate;
    }

    /// Slots with a cadence or backoff held (the bound C4d checks).
    internal int Held { get { lock (gate) return states.Count; } }
    internal IReadOnlySet<LimitSlot> TrackedSlots { get { lock (gate) return states.Keys.ToHashSet(); } }

    /// An already-running read finishes quietly without changing its cadence/backoff or delivering its answer.
    public void Cancel() { lock (gate) generation = unchecked(generation + 1); }

    public Task Tick(DateTimeOffset now, bool open, IReadOnlySet<LimitSlot> slots, Func<LimitSlot, bool> live,
        Action<LiveLimitResult> deliver, CancellationToken token = default)
    {
        var started = new List<LimitSlot>();
        int epoch;
        lock (gate)
        {
            epoch = generation;
            foreach (var (slot, state) in states)
                if (!slots.Contains(slot) && !state.InFlight && (state.Last is null || (now - state.Last.Value).TotalSeconds >= Retention)
                    && (state.RetryAt is null || state.RetryAt <= now))
                {
                    states.Remove(slot);
                    forget?.Invoke(slot);
                }
            var opened = open && !wasOpen;
            wasOpen = open;
            foreach (var slot in slots)
            {
                if (!states.TryGetValue(slot, out var state)) states[slot] = state = new();
                if (state.InFlight || !LiveLimits.Due(state.Last, state.RetryAt, now, live(slot), open, opened)) continue;
                state.PreviousLast = state.Last;
                state.Last = now;
                state.InFlight = true;
                started.Add(slot);
            }
        }
        return Task.WhenAll(started.Select(slot => Finish(slot, epoch, token, deliver)));
    }

    async Task Finish(LimitSlot slot, int epoch, CancellationToken token, Action<LiveLimitResult> deliver)
    {
        LiveLimitResult result;
        try { result = await read(slot, token).ConfigureAwait(false); }
        catch (Exception) { result = new(Failed: true); }
        lock (gate)
        {
            var state = states[slot];
            state.InFlight = false;
            if (epoch != generation || token.IsCancellationRequested)
            {
                state.Last = state.PreviousLast;
                return;
            }
            state.Failures = result.Failed ? Math.Min(state.Failures + 1, 30) : 0;
            state.RetryAt = result.Failed ? state.Last?.AddSeconds(60 * Math.Pow(2, Math.Min(state.Failures, 5) - 1)) : null;
            if (result.Codex is not null || result.Claude is not null) deliver(result with { Slot = slot });
        }
    }
}
