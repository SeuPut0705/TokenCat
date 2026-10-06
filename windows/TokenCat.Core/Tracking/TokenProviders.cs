using System.Security;

namespace TokenCat;

/// The provider registry: one entry per client TokenCat recognises, in `TokenSource` order.
/// Adding a client takes one parser file (a `TokenLogFormat` whose `Open` returns an `ITokenLogReader`) and its `Format` here.
/// - `Roots`: the client's data folders, environment overrides first. A client counts as detected when one exists; only
///   existing roots are listed, and `TokenTracker.WatchedDirectories` names the roots of clients that have a format.
/// - `Format` null: detected, never read — no rows, counts or speeds. Allowed only while that client's parser is pending.
/// Telemetry setup covers `TokenSource.TelemetryClients`; live limits and the status line bridge stay with
/// `TokenSource.DefaultClients` (Codex and Claude Code).
/// Mirrors the mac's `TokenProvider.all` (TokenProviders.swift). `Roots` takes the home folder and an environment lookup.
public sealed record TokenProvider(TokenSource Source, Func<string, Func<string, string?>, IReadOnlyList<string>> Roots, TokenLogFormat? Format)
{
    /// VS Code family editors whose globalStorage may hold Cline, Roo Code or Kilo Code tasks.
    static readonly string[] Editors = ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf"];
    static readonly string[] VSCodeExtensions = ["saoudrizwan.claude-dev", "rooveterinaryinc.roo-cline", "kilocode.kilo-code"];

    public static readonly IReadOnlyList<TokenProvider> All =
    [
        new(TokenSource.Codex, (home, _) => [AppPaths.CodexSessions(home)], TokenLogFormat.Codex),
        new(TokenSource.Claude, (home, _) => [AppPaths.ClaudeProjects(home)], TokenLogFormat.Claude),
        new(TokenSource.OpenCode, (home, env) =>
            [.. OpenCodeDatabasePath(home, env) is { } db && Path.GetDirectoryName(db) is { } folder ? [folder] : Array.Empty<string>(),
             Path.Combine(DataHome(home, env), "opencode")], TokenLogFormat.OpenCode),
        new(TokenSource.Gemini, (home, env) => [Path.Combine(EnvPath(home, env, "GEMINI_CLI_HOME") ?? home, ".gemini", "tmp")], TokenLogFormat.Gemini),
        // Qwen keeps sessions under its runtime dir: QWEN_RUNTIME_DIR, else QWEN_HOME, else ~\.qwen.
        new(TokenSource.Qwen, (home, env) =>
            [.. new[] { EnvPath(home, env, "QWEN_RUNTIME_DIR"), EnvPath(home, env, "QWEN_HOME"), Path.Combine(home, ".qwen") }
                .OfType<string>().Select(folder => Path.Combine(folder, "projects"))], TokenLogFormat.Qwen),
        new(TokenSource.Copilot, (home, env) =>
            [Path.Combine(EnvPath(home, env, "COPILOT_HOME") ?? Path.Combine(home, ".copilot"), "session-state")], TokenLogFormat.Copilot),
        // AMP_DATA_DIR (a parser convention, not an Amp setting) names the folder that holds threads\.
        new(TokenSource.Amp, (home, env) =>
            [.. new[] { EnvPath(home, env, "AMP_DATA_DIR"), Path.Combine(DataHome(home, env), "amp") }
                .OfType<string>().Select(folder => Path.Combine(folder, "threads"))], TokenLogFormat.Amp),
        new(TokenSource.Cline, (home, env) =>
        {
            var appData = EnvPath(home, env, "APPDATA") ?? Path.Combine(home, "AppData", "Roaming");
            return [.. Editors.SelectMany(editor => VSCodeExtensions.Select(extension =>
                        Path.Combine(appData, editor, "User", "globalStorage", extension, "tasks"))),
                    Path.Combine(home, ".cline", "data", "sessions")];
        }, TokenLogFormat.Cline),
        // omp and Pi both move their agent folder to PI_CODING_AGENT_DIR; sessions live in its `sessions`.
        new(TokenSource.Omp, (home, env) =>
            [.. new[] { EnvPath(home, env, "PI_CODING_AGENT_DIR"), Path.Combine(home, ".omp", "agent"), Path.Combine(home, ".pi", "agent") }
                .OfType<string>().Select(folder => Path.Combine(folder, "sessions"))], TokenLogFormat.Omp),
        new(TokenSource.Droid, (home, _) => [Path.Combine(home, ".factory", "sessions")], TokenLogFormat.Droid),
    ];

    /// `XDG_DATA_HOME`, else ~\.local\share (OpenCode and Amp use it on Windows too).
    static string DataHome(string home, Func<string, string?> env) =>
        EnvPath(home, env, "XDG_DATA_HOME") ?? Path.Combine(home, ".local", "share");

    /// `OPENCODE_DB` as OpenCode resolves it: a rooted path, else a path inside its data folder; `:memory:` is no file.
    public static string? OpenCodeDatabasePath(string home, Func<string, string?> env)
    {
        if (env("OPENCODE_DB") is not { Length: > 0 } value || value == ":memory:") return null;
        try { return Path.GetFullPath(Path.IsPathRooted(value) ? value : Path.Combine(DataHome(home, env), "opencode", value)); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException or SecurityException) { return null; }
    }

    /// A non-empty environment value as a full path; a leading `~` names `home`.
    static string? EnvPath(string home, Func<string, string?> env, string key)
    {
        if (env(key) is not { Length: > 0 } value) return null;
        if (value == "~" || value.StartsWith("~/", StringComparison.Ordinal) || value.StartsWith(@"~\", StringComparison.Ordinal))
            value = home + value[1..];
        try { return Path.GetFullPath(value); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException or SecurityException) { return null; }
    }

    public IReadOnlyList<string> ExistingRoots(string home, Func<string, string?> env)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return [.. Roots(home, env).Where(root => seen.Add(root) && Directory.Exists(root))];
    }
}

/// How a client's logs are listed and read. Every delegate runs on the tracker's caller (one at a time).
/// - `Files`: logs worth tracking under the client's existing roots. Rank and cap them with `TokenDiscovery.Recent`, so every
///   listed path is also `Known` (a write to a log the caps left out then opens it directly instead of forcing a rescan).
/// - `IsLog`: whether a path from a file event is a log `Files` would list; an untracked one triggers discovery on the next sample.
/// - `Open`: the reader for one listed log, kept while discovery lists it or `IsRecent` holds.
public sealed partial record TokenLogFormat(
    Func<IReadOnlyList<string>, TokenDiscovery, IEnumerable<string>> Files,
    Func<string, bool> IsLog,
    Func<string, ITokenLogReader> Open);

/// Reads one tracked log (a file or a database) and reports its sessions. Never stores transcript text.
public interface ITokenLogReader
{
    /// Called once per sample: read what changed since the last call. `tailLimit` bounds the first read of a large log.
    void Read(int tailLimit, DateTimeOffset now);
    /// The log's sessions now; empty until something countable was read. `id` is the stable row id
    /// ("<source>:<path relative to home>"); a log holding several sessions appends "#<session>" for each row.
    IEnumerable<TokenReading> Readings(string id, DateTimeOffset now);
    /// Keeps the reader past the discovery caps: an open turn, or a log written within the hour.
    bool IsRecent(DateTimeOffset now);
}

/// Discovery helpers shared by every format; one per discovery pass.
public sealed class TokenDiscovery(DateTimeOffset now)
{
    public DateTimeOffset Now { get; } = now;
    /// Every log the caps were applied to, inside them or not.
    public HashSet<string> Known { get; } = new(StringComparer.Ordinal);

    /// `contentsOfDirectory(…, options: .skipsHiddenFiles)`; a missing folder or a file is empty.
    public static List<FileSystemInfo> Children(string directory)
    {
        try
        {
            return [.. new DirectoryInfo(directory).EnumerateFileSystemInfos()
                .Where(entry => !entry.Name.StartsWith('.') && !entry.Attributes.HasFlag(FileAttributes.Hidden))];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException) { return []; }
    }

    /// The 32 newest by the enumeration's modification time (discovery ranking only; reads use a fresh query, rule 8),
    /// plus up to 32 more modified since `since` (the retention hour), so a cold start opens them too.
    /// ponytail: NTFS may report a stale time for a log held open since before launch; tracked recent logs are retained,
    /// so it only matters with 32+ newer files.
    public List<string> Recent(IEnumerable<FileSystemInfo> entries, DateTime? since = null)
    {
        var logs = entries.ToList();
        Known.UnionWith(logs.Select(entry => entry.FullName));
        return [.. logs.OrderByDescending(entry => entry.LastWriteTimeUtc)
            .Where((entry, rank) => rank < 32 || (rank < 64 && entry.LastWriteTimeUtc >= since)).Select(entry => entry.FullName)];
    }
}
