using System.Text.Json;

namespace TokenCat;

/// Telemetry.swift's `ClaudeUsageLimits` statics (DESIGN §7.5). Named ClaudeUsage, not ClaudeLimits: the collector's
/// `ClaudeLimits` property would hide it. Persistence is `SettingsStore` under `ClaudeUsageLimits.DefaultsKey`.
public static class ClaudeUsage
{
    /// Per window, the newer receipt wins, except that a record repeating a live poll's value within 2 minutes keeps the
    /// poll (and its "실시간" label). A window missing from a receipt is kept: Claude Code drops a window once it
    /// resets, and the kept one then reads as reset by its own time.
    public static ClaudeUsageLimits Merged(ClaudeUsageLimits a, ClaudeUsageLimits b)
    {
        static ClaudeLimitWindow? Newer(ClaudeLimitWindow? a, ClaudeLimitWindow? b)
        {
            if (a is null || b is null) return a ?? b;
            var (old, recent) = b.ReceivedAt > a.ReceivedAt ? (a, b) : (b, a);
            var repeated = old.Live && !recent.Live && (recent.ReceivedAt - old.ReceivedAt).TotalSeconds < LiveLimits.LiveFor
                && SessionPresentation.Round(recent.UsedPercent) == SessionPresentation.Round(old.UsedPercent)
                && Math.Abs(((recent.ResetsAt ?? old.ResetsAt ?? DateTimeOffset.MinValue) - (old.ResetsAt ?? DateTimeOffset.MinValue)).TotalSeconds) <= 60;
            return repeated ? old : recent;
        }
        return new(Newer(a.FiveHour, b.FiveHour), Newer(a.SevenDay, b.SevenDay));
    }

    /// Status line JSON → limits; null when the body is not a JSON object. A window needs a 0–100 `used_percentage` and
    /// `resets_at` in Unix seconds. Everything else in that JSON (paths, model, cost, session) is dropped here.
    public static ClaudeUsageLimits? Decode(ReadOnlySpan<byte> statusJson, DateTimeOffset receivedAt)
    {
        if (Json.Parse(statusJson) is not { ValueKind: JsonValueKind.Object } root) return null;
        var limits = root.Field("rate_limits");
        ClaudeLimitWindow? Window(string key)
        {
            if (limits?.Field(key) is not { ValueKind: JsonValueKind.Object } value
                || value.Field("used_percentage")?.Number is not double used || used is < 0 or > 100
                || value.Field("resets_at")?.Number is not double reset || reset is < 1_000_000_000 or > 10_000_000_000) return null;
            return new(used, DateTimeOffset.UnixEpoch.AddSeconds(reset), receivedAt);
        }
        return new(Window("five_hour"), Window("seven_day"));
    }

    /// The Claude desktop app runs no statusLine; it records its own usage about every 15 min in plan-usage-history.json
    /// (`{"version":2,"samples":[{"t":ms,"org":…,"u":{"fh":%,"sd":%}}]}`). Only the last sample's time and the 5-hour (`fh`)
    /// and 7-day (`sd`) percentages are kept, with no reset time; null for any other shape.
    public static ClaudeUsageLimits? DecodeDesktopHistory(ReadOnlySpan<byte> json, string? defaultOrganization = null)
    {
        if (Json.Parse(json) is not { ValueKind: JsonValueKind.Object } root || root.Field("version")?.Number != 2
            || root.Field("samples") is not { ValueKind: JsonValueKind.Array } samples || samples.GetArrayLength() == 0
            || samples[samples.GetArrayLength() - 1] is not { ValueKind: JsonValueKind.Object } sample
            || sample.Field("u") is not { ValueKind: JsonValueKind.Object } usage
            || sample.Field("t")?.Number is not double time || time is < 1e12 or > 1e13) return null;
        if (sample.Field("org")?.Text is { } organization && organization != defaultOrganization) return null;
        var recorded = DateTimeOffset.UnixEpoch.AddMilliseconds(time);
        ClaudeLimitWindow? Window(string key) =>
            usage.Field(key)?.Number is double used && used is >= 0 and <= 100 ? new(used, null, recorded) : null;
        return new(Window("fh"), Window("sd"));
    }

    /// First existing candidate (`AppPaths.ClaudeDesktopHistory()`), re-read only on size/mtime change, ignored above 2 MB.
    /// A missing file means no desktop limits, never an error. One caller at a time (the monitor loop).
    public sealed class DesktopReader(IReadOnlyList<string> candidates)
    {
        (string Path, long Length, DateTime Written)? stamp;
        string? organization;
        ClaudeUsageLimits limits = ClaudeUsageLimits.Empty;

        public ClaudeUsageLimits Read(string? defaultOrganization = null)
        {
            var file = candidates.Select(path => new FileInfo(path)).FirstOrDefault(info => info.Exists);
            if (file is null || file.Length > TelemetryHttp.MaximumBodyBytes) return ClaudeUsageLimits.Empty;
            var current = (file.FullName, file.Length, file.LastWriteTimeUtc);
            if (stamp == current && organization == defaultOrganization) return limits;
            stamp = current;
            organization = defaultOrganization;
            try
            {
                // Electron writes it while we read: share everything.
                using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var bytes = new MemoryStream();
                stream.CopyTo(bytes);
                limits = DecodeDesktopHistory(bytes.ToArray(), defaultOrganization) ?? ClaudeUsageLimits.Empty;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { limits = ClaudeUsageLimits.Empty; }
            return limits;
        }
    }
}
