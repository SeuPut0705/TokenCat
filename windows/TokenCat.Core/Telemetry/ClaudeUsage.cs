namespace TokenCat;

// WP2 stub (DESIGN §11, §7.5). Named ClaudeUsage, not ClaudeLimits: the collector's `ClaudeLimits` property would hide it.
// WP2 replaces the bodies and owns this file.
public static class ClaudeUsage
{
    /// Per window, the newer receipt wins; a window missing from a receipt is kept.
    public static ClaudeUsageLimits Merged(ClaudeUsageLimits a, ClaudeUsageLimits b) => throw new NotImplementedException();
    /// Status line JSON → limits; null when the body is not a JSON object.
    public static ClaudeUsageLimits? Decode(ReadOnlySpan<byte> statusJson, DateTimeOffset receivedAt) => throw new NotImplementedException();
    /// plan-usage-history.json (version 2) → limits; null for any other shape.
    public static ClaudeUsageLimits? DecodeDesktopHistory(ReadOnlySpan<byte> json) => throw new NotImplementedException();

    /// First existing candidate (`AppPaths.ClaudeDesktopHistory()`), re-read only on size/mtime change, ignored above 2 MB.
    public sealed class DesktopReader
    {
        public DesktopReader(IReadOnlyList<string> candidates) => throw new NotImplementedException();
        public ClaudeUsageLimits Read() => throw new NotImplementedException();
    }
}
