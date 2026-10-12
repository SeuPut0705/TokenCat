using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// SessionTitle.swift: a session's title as its client generated or the person renamed it: Claude Code
/// `custom-title`/`ai-title`/`summary`, Codex thread names, OpenCode/Kilo Code/MiMo Code `session.title`, omp
/// `title_change`/Pi `session_info`, Gemini CLI `summary`, Qwen Code `custom_title`, Copilot CLI `name`/`summary`, Amp thread
/// `title`, a generated or renamed Droid `session_start.title`, the Cursor composer `name`, Grok `generated_title`, a Hermes
/// `title` from the model or the person, the OpenClaw `label`/`displayName`, a generated, recipe or renamed Goose `name`, a
/// generated or custom Kimi Code `title`. Never a prompt: a client that only copies the first message (Cline, Roo Code, Kilo
/// Code's extension, Zoo Code, IBM Bob, kimi-cli, a Droid title not yet generated, a Hermes `derived` title, MiMo `fallback`
/// titles, a Grok title copying the first prompt, a Goose session on a CLI or ACP agent provider) has none. Kept in memory on
/// the reading only; never stored, logged or sent.
public static class SessionTitle
{
    /// Longer titles end in "…" at this many characters (grapheme clusters); the rows truncate further to fit.
    public const int MaximumLength = 80;

    /// The same for a JSON value: anything but a string is no title.
    public static string? Clean(JsonElement? value) => Clean(value?.Text);

    /// One line of at most `MaximumLength` characters: control characters and line breaks become spaces, invisible format
    /// characters (bidi overrides, BOM) are dropped, runs of white space collapse. Null when nothing is left.
    public static string? Clean(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        var raw = value;
        // A hostile value never costs more than a few kilobytes of work.
        if (Encoding.UTF8.GetByteCount(raw) > 4_096) raw = Prefix(raw, 1_024);
        var text = new StringBuilder(raw.Length);
        var gap = false;
        foreach (var rune in raw.EnumerateRunes())
        {
            switch (Rune.GetUnicodeCategory(rune))
            {
                case UnicodeCategory.Control or UnicodeCategory.SpaceSeparator or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator:
                    gap = true;
                    continue;
                // The zero-width joiner holds emoji sequences together; other format characters only reorder or hide text.
                case UnicodeCategory.Format when rune.Value != 0x200D:
                    continue;
            }
            if (gap && text.Length > 0) text.Append(' ');
            gap = false;
            text.Append(rune.ToString());
        }
        if (text.Length == 0) return null;
        var cleaned = text.ToString();
        if (new StringInfo(cleaned).LengthInTextElements <= MaximumLength) return cleaned;
        return Prefix(cleaned, MaximumLength - 1).TrimEnd(' ') + "…";
    }

    /// The first `count` characters (grapheme clusters), as Swift's `String.prefix`.
    static string Prefix(string text, int count)
    {
        var elements = StringInfo.GetTextElementEnumerator(text);
        var length = 0;
        for (var taken = 0; taken < count && elements.MoveNext(); taken++)
            length = elements.ElementIndex + ((string)elements.Current).Length;
        return text[..length];
    }
}

/// CodexThreadNames (SessionTitle.swift): `<CODEX_HOME>\session_index.jsonl`, append-only `{id, thread_name, updated_at}`
/// lines written on every rename or generated name (the rollout's `thread_name_updated` event is not persisted). The newest
/// non-empty name of an id wins, as in Codex's own lookup; a rewrite that removes names (the file shrinks or is replaced) is
/// read again. One index per file, shared by every rollout reader of that Codex home; the tracker refreshes each once a sample.
/// Names are held for threads asked about since the previous sweep (every `PruneInterval`), plus the 2,048 newest unasked
/// ones. A miss once a name was evicted is resolved at the next refresh, together with every other such miss, in one scan of
/// the index's last 4 MB: a cold start with hundreds of rollouts scans once, not once per thread.
public sealed class CodexThreadNames
{
    public const double PruneInterval = 600;
    internal const int UnaskedLimit = 2_048;
    const int TailLimit = 4_194_304;
    static readonly object Gate = new();
    static readonly Dictionary<string, CodexThreadNames> Indexes = [];
    readonly string path;
    readonly LogLineTail tail;
    /// A null value remembers that no name has been recorded for a thread yet.
    readonly Dictionary<string, string?> asked = new(StringComparer.Ordinal);
    readonly HashSet<string> askedSinceSweep = new(StringComparer.Ordinal);
    readonly RecentKeys<string> unasked = new(UnaskedLimit);
    /// Threads asked about after an eviction whose name the next refresh looks up (at most the threads asked in one sample).
    readonly HashSet<string> pending = new(StringComparer.Ordinal);
    bool evicted;
    long sweptAt = Environment.TickCount64;
    CodexThreadNames(string path)
    {
        this.path = path;
        tail = new LogLineTail(path);
    }

    /// The index beside the `sessions` folder holding a rollout (`sessions\YYYY\MM\DD\rollout-….jsonl`).
    public static CodexThreadNames ForRollout(string rollout)
    {
        var home = rollout;
        for (var level = 0; level < 5; level++) home = Path.GetDirectoryName(home) ?? "";
        var path = Path.Combine(home, "session_index.jsonl");
        lock (Gate)
        {
            if (Indexes.TryGetValue(path, out var index)) return index;
            index = new CodexThreadNames(path);
            Indexes[path] = index;
            return index;
        }
    }

    /// Names held now, including threads whose name has not been recorded yet.
    internal int Count { get { lock (Gate) return asked.Count + unasked.Count; } }
    /// Scans of the index for evicted names so far.
    internal int LookUps { get { lock (Gate) return lookUps; } }
    int lookUps;

    /// Reads lines appended since the last call (a stat when nothing changed), then looks up the evicted names asked for since.
    public void Refresh()
    {
        lock (Gate)
        {
            var uptime = Environment.TickCount64;
            if (uptime - sweptAt >= PruneInterval * 1_000 || uptime < sweptAt) SweepLocked(uptime);
            tail.Read(TailLimit, () =>
            {
                foreach (var id in asked.Keys.ToArray()) asked[id] = null;
                unasked.Clear();
                evicted = false;
            }, line =>
            {
                if (Entry(line) is not { } entry) return;
                if (asked.ContainsKey(entry.Id)) asked[entry.Id] = entry.Name;
                else RememberUnasked(entry.Id, entry.Name);
            });
            if (pending.Count == 0) return;
            HashSet<string> missing = evicted ? [.. pending.Where(id => unasked[id] is null)] : [];
            var found = missing.Count > 0 ? LookUp(missing) : null;
            foreach (var id in pending) asked[id] = unasked[id] ?? found?.GetValueOrDefault(id);
            pending.Clear();
        }
    }

    /// Null while an evicted thread's name waits for the next refresh.
    public string? Name(string? thread)
    {
        if (thread is null) return null;
        var id = thread.ToLowerInvariant();
        lock (Gate)
        {
            askedSinceSweep.Add(id);
            if (asked.TryGetValue(id, out var known)) return known;
            var name = unasked[id];
            if (name is null && evicted)
            {
                pending.Add(id);
                return null;
            }
            asked[id] = name;
            return name;
        }
    }

    /// Threads no reader asked for since the previous sweep become unasked or are forgotten.
    internal void Sweep()
    {
        lock (Gate) SweepLocked(Environment.TickCount64);
    }

    void SweepLocked(long uptime)
    {
        foreach (var (id, name) in asked.ToArray())
        {
            if (askedSinceSweep.Contains(id)) continue;
            asked.Remove(id);
            if (name is not null) RememberUnasked(id, name);
        }
        askedSinceSweep.Clear();
        sweptAt = uptime;
    }

    void RememberUnasked(string id, string name)
    {
        if (unasked.Count >= UnaskedLimit && !unasked.Contains(id)) evicted = true;
        unasked.Set(id, name);
    }

    static (string Id, string Name)? Entry(ReadOnlySpan<byte> line)
    {
        if (Json.Parse(line) is not { ValueKind: JsonValueKind.Object } record || LogFields.Text(record.Field("id")) is not { } id
            || SessionTitle.Clean(record.Field("thread_name")) is not { } name) return null;
        return (id.ToLowerInvariant(), name);
    }

    /// The newest name of each id within the same bounded window as the initial read. Every line is parsed as that read
    /// parses it, so an id is matched whatever its case in the index.
    Dictionary<string, string>? LookUp(HashSet<string> ids)
    {
        lookUps++;
        try
        {
            using var handle = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, bufferSize: 0);
            var size = handle.Length;
            var offset = Math.Max(0, size - TailLimit);
            var lines = new LogLineAssembler();
            lines.Restart(dropFirst: offset > 0);
            var names = new Dictionary<string, string>(StringComparer.Ordinal);
            LogLineTail.ReadForward(handle, ref offset, size, TailLimit, lines, line =>
            {
                if (Entry(line) is { } entry && ids.Contains(entry.Id)) names[entry.Id] = entry.Name;
            });
            return names;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }
}
