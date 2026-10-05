namespace TokenCat;

/// Log-recorded output volume in 5 s wall-clock buckets. Counts only, never a rate:
/// `At` is when a client wrote the usage record, not when tokens streamed.
/// Rebuilt from scratch on every update; there is no incremental state. (`FlowBars` drawing is the App's.)
public sealed record FlowSeries(DateTimeOffset Newest, IReadOnlyList<int> Hero, IReadOnlyList<bool> Fresh,
    IReadOnlyDictionary<TokenSource, int> ByProvider, TokenOutputEvent? Last)
{
    /// Writers' clocks may run slightly ahead; such records land in the newest bucket (`FutureTolerance`).
    public const double BucketSeconds = 5, FreshSeconds = 5, FutureTolerance = 5;
    public const int HeroCount = 60;

    public static FlowSeries Empty { get; } = new(DateTimeOffset.MinValue, new int[HeroCount], new bool[HeroCount],
        new Dictionary<TokenSource, int>(), null);

    public int Total => Hero.Sum();

    /// Start of the newest bucket: `floor(now / 5) * 5`.
    public static DateTimeOffset BucketStart(DateTimeOffset now)
    {
        const long bucket = (long)(BucketSeconds * TimeSpan.TicksPerSecond);
        var ticks = (now - DateTimeOffset.UnixEpoch).Ticks;
        return DateTimeOffset.UnixEpoch.AddTicks(ticks - ((ticks % bucket) + bucket) % bucket);
    }

    /// Buckets back from the newest one (0 = newest), or null when the record is outside the window.
    public static int? Offset(DateTimeOffset at, DateTimeOffset now, DateTimeOffset newest, int count)
    {
        if ((at - now).TotalSeconds > FutureTolerance) return null;
        var behind = (newest - at).TotalSeconds;
        var offset = behind <= 0 ? 0 : Math.Ceiling(behind / BucketSeconds);
        return offset < count ? (int)offset : null;
    }

    public static FlowSeries Make(IReadOnlyList<TokenReading> readings, DateTimeOffset now)
    {
        var newest = BucketStart(now);
        var hero = new int[HeroCount];
        var fresh = new bool[HeroCount];
        var byProvider = new Dictionary<TokenSource, int>();
        TokenOutputEvent? last = null;
        foreach (var reading in readings)
        {
            if (reading.Id.StartsWith("telemetry:", StringComparison.Ordinal)) continue;
            foreach (var record in reading.RecentOutputs)
            {
                if (record.Tokens <= 0 || Offset(record.At, now, newest, HeroCount) is not { } offset) continue;
                hero[HeroCount - 1 - offset] += record.Tokens;
                if ((now - record.At).TotalSeconds <= FreshSeconds) fresh[HeroCount - 1 - offset] = true;
                byProvider[reading.Source] = byProvider.GetValueOrDefault(reading.Source) + record.Tokens;
                if (last is { } previous && previous.At >= record.At)
                {
                    if (previous.At == record.At) last = previous with { Tokens = previous.Tokens + record.Tokens };
                }
                else last = record;
            }
        }
        return new(newest, hero, fresh, byProvider, last);
    }

    /// Content equality (rule 2): record equality would compare the collections by reference.
    public bool Equals(FlowSeries? other) =>
        other is not null && Newest == other.Newest && Last == other.Last && Hero.SequenceEqual(other.Hero) && Fresh.SequenceEqual(other.Fresh)
        && ByProvider.Count == other.ByProvider.Count
        && ByProvider.All(pair => other.ByProvider.TryGetValue(pair.Key, out var value) && value == pair.Value);

    public override int GetHashCode() => HashCode.Combine(Newest, Total, Last);
}

public static class FlowMath
{
    /// Rounds up to {1, 1.5, 2, 3, 4, 5, 6, 8} × 10ⁿ, so the tallest bar always fills at least 2/3 of the plot.
    /// No hysteresis: the same data always draws the same scale (deterministic snapshots).
    public static double NiceMax(double value)
    {
        if (!double.IsFinite(value) || value <= 0) return 1;
        var magnitude = Math.Pow(10, Math.Floor(Math.Log10(value)));
        foreach (var step in (double[])[1, 1.5, 2, 3, 4, 5, 6, 8, 10])
            if (step * magnitude >= value * (1 - 1e-9)) return step * magnitude;
        return 10 * magnitude;
    }
}
