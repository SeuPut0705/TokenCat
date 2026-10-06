using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// SessionTitle.swift: a session's title as its client generated or the person renamed it: Claude Code
/// `custom-title`/`ai-title`/`summary`, Codex thread names, OpenCode `session.title`, omp `title_change`/Pi `session_info`,
/// Gemini CLI `summary`, Qwen Code `custom_title`, Copilot CLI `name`/`summary`, Amp thread `title`, a generated or renamed
/// Droid `session_start.title`. Never a prompt: a client that only copies the first message (Cline, Roo Code, Kilo Code, a
/// Droid title not yet generated) has none. Kept in memory on the reading only; never stored, logged or sent.
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
/// read again. One index per file, shared by every rollout reader of that Codex home.
public sealed class CodexThreadNames
{
    static readonly object Gate = new();
    static readonly Dictionary<string, CodexThreadNames> Indexes = [];
    readonly LogLineTail tail;
    readonly Dictionary<string, string> names = [];

    CodexThreadNames(string path) => tail = new LogLineTail(path);

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

    /// Reads lines appended since the last call; a stat when nothing changed.
    public void Refresh()
    {
        lock (Gate)
        {
            tail.Read(4_194_304, names.Clear, line =>
            {
                if (Json.Parse(line) is not { ValueKind: JsonValueKind.Object } record || LogFields.Text(record.Field("id")) is not { } id
                    || SessionTitle.Clean(record.Field("thread_name")) is not { } name) return;
                names[id.ToLowerInvariant()] = name;
            });
        }
    }

    public string? Name(string? thread)
    {
        if (thread is null) return null;
        lock (Gate) return names.GetValueOrDefault(thread.ToLowerInvariant());
    }
}
