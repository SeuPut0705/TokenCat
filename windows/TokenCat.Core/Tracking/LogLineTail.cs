using System.Buffers;
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
    /// Creation time, size and write time from the latest `Read`'s stat (null when the file was missing), for a reader that
    /// needs the same file's stamp in the same sample.
    public (long Identity, long Length, long Written)? Stamp { get; private set; }
    long offset;
    long identity;
    bool initialized;
    readonly LogLineAssembler lines = new();
    const FileShare Sharing = FileShare.ReadWrite | FileShare.Delete; // never block the writer's appends or renames

    /// Reads what was appended since the last call. `reset` runs before a replaced or truncated file is read again;
    /// `line` gets each complete new line without its newline (valid only during the call). `header` gets the file's first line
    /// (within 64 KB) before the tail when the first read starts past it. False when the file is missing.
    public bool Read(int tailLimit, Action reset, Action<ReadOnlySpan<byte>> line, Action<ReadOnlySpan<byte>>? header = null)
    {
        // A fresh attribute query every tick; the creation time stands in for the mac's dev-ino, as in TokenFileCursor.
        var info = new FileInfo(Path);
        if (!info.Exists)
        {
            Stamp = null;
            return false;
        }
        var size = info.Length;
        var currentIdentity = info.CreationTimeUtc.Ticks;
        Modified = new DateTimeOffset(info.LastWriteTimeUtc);
        Stamp = (currentIdentity, size, info.LastWriteTimeUtc.Ticks);
        if (initialized && (identity != currentIdentity || size < offset))
        {
            offset = 0;
            initialized = false;
            SkippedHead = false;
            lines.Restart(dropFirst: false);
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
                    if (header is not null)
                    {
                        var head = new byte[65_536];
                        var read = ReadAt(handle, 0, head);
                        if (head.AsSpan(0, read).IndexOf((byte)10) is var newline and >= 0) header(head.AsSpan(0, newline));
                    }
                    offset = size - limit;
                    SkippedHead = true;
                    lines.Restart(dropFirst: true);
                }
                identity = currentIdentity;
                initialized = true;
            }
            ReadForward(handle, ref offset, size, tailLimit, lines, line);
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
            var head = new byte[(int)Math.Min(limit, handle.Length)];
            var read = ReadAt(handle, 0, head);
            var newline = head.AsSpan(0, read).IndexOf((byte)10);
            return newline < 0 ? null : head[..newline];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// Up to `buffer.Length` bytes at `position`; fewer only at the end of the file.
    internal static int ReadAt(FileStream handle, long position, Span<byte> buffer)
    {
        handle.Position = position;
        return handle.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
    }

    /// Reads `offset..size` in 1 MB chunks through one pooled buffer, so a burst (large tool outputs, the initial turn replay)
    /// is caught up within one sample (16 MB past the tail) without a large-object allocation per chunk.
    internal static void ReadForward(FileStream handle, ref long offset, long size, int tailLimit, LogLineAssembler lines,
        Action<ReadOnlySpan<byte>> line, Action<ReadOnlySpan<byte>>? oversized = null)
    {
        if (offset >= size) return;
        var buffer = ArrayPool<byte>.Shared.Rent((int)Math.Min(1_048_576, size - offset));
        try
        {
            long budget = 16_777_216 + tailLimit;
            while (offset < size && budget > 0)
            {
                var read = ReadAt(handle, offset, buffer.AsSpan(0, (int)Math.Min(Math.Min(1_048_576, size - offset), buffer.Length)));
                if (read == 0) break;
                offset += read;
                budget -= read;
                lines.Consume(buffer.AsSpan(0, read), line, oversized);
            }
        }
        finally { ArrayPool<byte>.Shared.Return(buffer); }
    }
}

/// Splits appended bytes into complete lines (LogLineTail.swift's line assembly, shared with TokenFileCursor). A line inside
/// one chunk is handed over in place; only a line that spans chunks is copied. Lines over 1 MB are skipped, and one long
/// line must not pin up to 1 MB per reader for good: the buffer is released after a line over 64 KB.
public sealed class LogLineAssembler
{
    public const int MaximumLineBytes = 1_048_576;
    /// How much of a skipped oversized line `oversized` gets.
    public const int OversizedPrefixBytes = 16_384;
    MemoryStream pending = new();
    bool dropping;

    /// Bytes of an unfinished line kept for the next chunk, and the buffer holding them: the retention C1 bounds.
    internal (long Length, long Capacity) Pending => (pending.Length, pending.Capacity);

    /// Forgets a partial line; `dropFirst` skips the first (partial) line, as when a read starts mid-file.
    public void Restart(bool dropFirst)
    {
        pending = new();
        dropping = dropFirst;
    }

    /// `line` gets each complete, non-empty line within the limit; `oversized` the first 16 KB of a skipped one.
    public void Consume(ReadOnlySpan<byte> data, Action<ReadOnlySpan<byte>> line, Action<ReadOnlySpan<byte>>? oversized = null)
    {
        while (data.Length > 0)
        {
            var found = data.IndexOf((byte)10);
            var piece = found < 0 ? data : data[..found];
            if (!dropping && found >= 0 && pending.Length == 0)
            {
                if (piece.Length > MaximumLineBytes) oversized?.Invoke(piece[..OversizedPrefixBytes]);
                else if (piece.Length > 0) line(piece);
                data = data[(found + 1)..];
                continue;
            }
            if (!dropping)
            {
                if (pending.Length + piece.Length <= MaximumLineBytes) pending.Write(piece);
                else
                {
                    if (oversized is not null)
                    {
                        var head = pending.GetBuffer().AsSpan(0, (int)Math.Min(pending.Length, OversizedPrefixBytes));
                        oversized([.. head, .. piece[..Math.Min(piece.Length, OversizedPrefixBytes - head.Length)]]);
                    }
                    pending = new();
                    dropping = true;
                }
            }
            if (found < 0) break;
            if (!dropping && pending.Length > 0) line(pending.GetBuffer().AsSpan(0, (int)pending.Length));
            if (pending.Length > 65_536) pending = new();
            else pending.SetLength(0);
            dropping = false;
            data = data[(found + 1)..];
        }
    }
}

/// LogFields (LogLineTail.swift): field parsing shared by the provider readers. Values that do not parse are null, never zero.
public static class LogFields
{
    /// An ISO 8601 string as ISO8601DateFormatter reads it (TokenLogParser's rule 4): seconds, an optional fraction kept
    /// to milliseconds, Z or ±hh:mm.
    public static DateTimeOffset? Date(JsonElement? value) => Date(value?.Text);

    /// The same for a string already read (OmpRecordHead's head fields).
    public static DateTimeOffset? Date(string? text)
    {
        if (text is null || IsoDate.Match(text) is not { Success: true } match
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

    /// `a + b` for counts, held at int.MaxValue: C# `+` wraps and LINQ's `Sum` throws, where Swift's 64-bit Int does neither.
    public static int Add(int a, int b) => (int)Math.Min((long)a + b, int.MaxValue);

    /// A non-empty string.
    public static string? Text(JsonElement? value) => value?.Text is { Length: > 0 } text ? text : null;

    /// The elements of an array that are objects; empty for anything else.
    public static List<JsonElement> Objects(JsonElement? value) =>
        value is { ValueKind: JsonValueKind.Array } array ? [.. array.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.Object)] : [];
}
