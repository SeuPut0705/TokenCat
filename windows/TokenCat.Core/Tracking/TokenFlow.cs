namespace TokenCat;

// WP1 stub (DESIGN §11): TokenFlow.swift's FlowSeries fields and constants. WP1 adds Make, content equality (rule 2) and
// owns this file.
public sealed record FlowSeries(DateTimeOffset Newest, IReadOnlyList<int> Hero, IReadOnlyList<bool> Fresh,
    IReadOnlyDictionary<TokenSource, int> ByProvider, TokenOutputEvent? Last)
{
    public const double BucketSeconds = 5, FreshSeconds = 5, FutureTolerance = 5;
    public const int HeroCount = 60;

    public static FlowSeries Empty { get; } = new(DateTimeOffset.MinValue, new int[HeroCount], new bool[HeroCount],
        new Dictionary<TokenSource, int>(), null);

    public int Total => Hero.Sum();

    public static FlowSeries Make(IReadOnlyList<TokenReading> readings, DateTimeOffset now) => throw new NotImplementedException();
}

public static class FlowMath
{
    public static double NiceMax(double value) => throw new NotImplementedException();
}
