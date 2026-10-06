using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TokenCat;

/// LogLineTail.swift: a bounded JSONL tail for provider readers. The first read starts `tailLimit` bytes before the end
/// (its partial first line is dropped), later reads continue at the offset. A truncated or replaced file is read again
/// from the top after `reset`. Lines over 1 MB are skipped; an unterminated last line waits for its newline.
public sealed class LogLineTail(string path)
{
    public string Path { get; } = path;
    /// Whether the first read skipped the head of the file, so records before the tail were never seen.
    public bool SkippedHead { get; private set; }
    /// Modification time from the latest `Read`.
    public DateTimeOffset? Modified { get; private set; }
    long offset;
    long identity;
    bool initialized;
    MemoryStream pending = new();
    bool dropping;
    const int MaximumLineBytes = 1_048_576;
    const FileShare Sharing = FileShare.ReadWrite | FileShare.Delete; // never block the writer's appends or renames

    /// Reads what was appended since the last call. `reset` runs before a replaced or truncated file is read again;
    /// `line` gets each complete new line without its newline. False when the file is missing.
    public bool Read(int tailLimit, Action reset, Action<byte[]> line)
    {
        // A fresh attribute query every tick; the creation time stands in for the mac's dev-ino, as in TokenFileCursor.
        var info = new FileInfo(Path);
        if (!info.Exists) return false;
        var size = info.Length;
        var currentIdentity = info.CreationTimeUtc.Ticks;
        Modified = new DateTimeOffset(info.LastWriteTimeUtc);
        if (initialized && (identity != currentIdentity || size < offset))
        {
            offset = 0;
            initialized = false;
            SkippedHead = false;
            pending = new();
            dropping = false;
            reset();
        }
        if (initialized && size == offset) return true;
        try
        {
            using var handle = new FileStream(Path, FileMode.Open, FileAccess.Read, Sharing, bufferSize: 0);
            if (!initialized)
            {
                var limit = Math.Max(128, tailLimit);
                if (size > limit)
                {
                    offset = size - limit;
                    SkippedHead = true;
                    dropping = true;
                }
                identity = currentIdentity;
                initialized = true;
            }
            // Bursts are caught up within one sample.
            long budget = 16_777_216 + tailLimit;
            while (offset < size && budget > 0)
            {
                var data = ReadAt(handle, offset, (int)Math.Min(1_048_576, size - offset));
                if (data.Length == 0) break;
                offset += data.Length;
                budget -= data.Length;
                Consume(data, line);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return true;
    }

    /// The file's first line when it is at most `limit` bytes: the session header a skipped head would lose.
    public byte[]? FirstLine(int limit = 65_536)
    {
        try
        {
            using var handle = new FileStream(Path, FileMode.Open, FileAccess.Read, Sharing, bufferSize: 0);
            var head = ReadAt(handle, 0, (int)Math.Min(limit, handle.Length));
            var newline = Array.IndexOf(head, (byte)10);
            return newline < 0 ? null : head[..newline];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    static byte[] ReadAt(FileStream handle, long position, int count)
    {
        var buffer = new byte[count];
        handle.Position = position;
        var read = handle.ReadAtLeast(buffer, count, throwOnEndOfStream: false);
        return read == count ? buffer : buffer[..read];
    }

    void Consume(byte[] data, Action<byte[]> line)
    {
        var start = 0;
        while (start < data.Length)
        {
            var found = data.AsSpan(start).IndexOf((byte)10);
            var end = found < 0 ? data.Length : start + found;
            if (!dropping)
            {
                if (pending.Length + end - start <= MaximumLineBytes) pending.Write(data, start, end - start);
                else
                {
                    pending = new();
                    dropping = true;
                }
            }
            if (found < 0) break;
            if (!dropping && pending.Length > 0) line(pending.ToArray());
            pending.SetLength(0);
            dropping = false;
            start = end + 1;
        }
    }
}

/// LogFields (LogLineTail.swift): field parsing shared by the provider readers. Values that do not parse are null, never zero.
public static class LogFields
{
    /// An ISO 8601 string as ISO8601DateFormatter reads it (TokenLogParser's rule 4): seconds, an optional fraction kept
    /// to milliseconds, Z or ±hh:mm.
    public static DateTimeOffset? Date(JsonElement? value)
    {
        if (value?.Text is not { } text || IsoDate.Match(text) is not { Success: true } match
            || !DateTimeOffset.TryParseExact(match.Groups[1].Value + (match.Groups[3].Value == "Z" ? "+00:00" : match.Groups[3].Value),
                "yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)) return null;
        var milliseconds = match.Groups[2].Success ? int.Parse(match.Groups[2].Value.PadRight(3, '0'), CultureInfo.InvariantCulture) : 0;
        var at = parsed.ToUniversalTime().AddMilliseconds(milliseconds);
        return at.Year is > 1 and < 9999 ? at : null;
    }

    static readonly Regex IsoDate =
        new(@"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]{1,3})[0-9]*)?(Z|[+-][0-9]{2}:[0-9]{2})$", RegexOptions.CultureInvariant);

    /// Epoch milliseconds.
    public static DateTimeOffset? Milliseconds(JsonElement? value) =>
        value?.Number is { } ms && ms > 0 && ms < 253_370_764_800_000 ? DateTimeOffset.UnixEpoch.AddTicks((long)(ms * TimeSpan.TicksPerMillisecond)) : null;

    /// A non-negative whole count; booleans, strings and fractions are not counts.
    public static int? Count(JsonElement? value) =>
        value?.Number is { } number && number >= 0 && number <= int.MaxValue && Math.Truncate(number) == number ? (int)number : null;

    /// A non-empty string.
    public static string? Text(JsonElement? value) => value?.Text is { Length: > 0 } text ? text : null;

    /// The elements of an array that are objects; empty for anything else.
    public static List<JsonElement> Objects(JsonElement? value) =>
        value is { ValueKind: JsonValueKind.Array } array ? [.. array.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.Object)] : [];
}
