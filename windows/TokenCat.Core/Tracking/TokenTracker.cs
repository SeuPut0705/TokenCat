namespace TokenCat;

// WP1 stub (DESIGN §11): the public API other packages compile against. WP1 replaces the bodies and owns this file.
public sealed class TokenTracker
{
    public TokenTracker(string home, Func<DateTimeOffset>? now = null, int initialTailBytes = 1_048_576, double discoveryIntervalSeconds = 5) =>
        throw new NotImplementedException();

    /// Folders for `LogWatcher`.
    public IReadOnlyList<string> WatchedDirectories => throw new NotImplementedException();
    /// Watcher hints; a miss only means the next discovery finds it.
    public void NoteChanged(IEnumerable<string> paths) => throw new NotImplementedException();
    public List<TokenReading> Sample() => throw new NotImplementedException();
}
