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
    /// Cline-format VS Code extensions and the product each one is (null: Cline itself).
    public static readonly (string Id, string? Client)[] VSCodeExtensions =
    [
        ("saoudrizwan.claude-dev", null), ("rooveterinaryinc.roo-cline", "Roo Code"), ("kilocode.kilo-code", "Kilo Code"),
        ("zoocodeorganization.zoo-code", "Zoo Code"), ("ibm.bob-code", "IBM Bob"),
    ];

    public static readonly IReadOnlyList<TokenProvider> All =
    [
        // CODEX_HOME moves Codex's state; ~\.codex stays a fallback for a session that lacks the shell's variable.
        new(TokenSource.Codex, (home, env) =>
            [.. EnvPath(home, env, "CODEX_HOME") is { } codexHome ? [Path.Combine(codexHome, "sessions")] : Array.Empty<string>(),
             AppPaths.CodexSessions(home), .. TokenClientRoots.RootsOf(TokenSource.Codex, home, env)], TokenLogFormat.Codex),
        new(TokenSource.Claude, (home, env) =>
            [.. ClaudeConfigDirectories(home, env).Select(folder => Path.Combine(folder, "projects")),
             .. TokenClientRoots.RootsOf(TokenSource.Claude, home, env)], TokenLogFormat.Claude),
        // OpenCode and the apps built on its store (Kilo Code, MiMo Code): each app's data folder and its `<APP>_DB` file's.
        new(TokenSource.OpenCode, (home, env) =>
            [.. OpenCodeApp.All.SelectMany(app => new[] { app.DatabasePath(home, env) is { } db ? Path.GetDirectoryName(db) : null, app.DataFolder(home, env) })
                .OfType<string>()], TokenLogFormat.OpenCode),
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
        // Cline-format extensions in any VS Code family editor, then Cline's shared store (CLINE_DIR → ~\.cline,
        // CLINE_DATA_DIR → <it>\data): `tasks` from the extension and JetBrains, `sessions` (CLINE_SESSION_DATA_DIR) from the CLI.
        new(TokenSource.Cline, (home, env) =>
        {
            var data = EnvPath(home, env, "CLINE_DATA_DIR") ?? Path.Combine(EnvPath(home, env, "CLINE_DIR") ?? Path.Combine(home, ".cline"), "data");
            var defaultData = Path.Combine(home, ".cline", "data");
            return [.. ExtensionTaskRoots(EnvPath(home, env, "APPDATA") ?? Path.Combine(home, "AppData", "Roaming")),
                    EnvPath(home, env, "CLINE_SESSION_DATA_DIR") ?? Path.Combine(data, "sessions"), Path.Combine(data, "tasks"),
                    Path.Combine(defaultData, "sessions"), Path.Combine(defaultData, "tasks")];
        }, TokenLogFormat.Cline),
        // omp and Pi both move their agent folder to PI_CODING_AGENT_DIR; sessions live in its `sessions`. omp names its folder
        // ~\<PI_CONFIG_DIR> (default .omp) and keeps named profiles in <it>\profiles\<name>\agent (its XDG layout is mac/Linux only).
        new(TokenSource.Omp, (home, env) =>
        {
            string[] configs = env("PI_CONFIG_DIR") is { Length: > 0 } configName
                ? [Path.Combine(home, configName), Path.Combine(home, ".omp")] : [Path.Combine(home, ".omp")];
            return [.. new[] { EnvPath(home, env, "PI_CODING_AGENT_DIR") }.OfType<string>()
                        .Concat(configs.Select(config => Path.Combine(config, "agent")))
                        .Append(Path.Combine(home, ".pi", "agent"))
                        .Concat(configs.SelectMany(config => Subfolders(Path.Combine(config, "profiles")).Select(profile => Path.Combine(profile, "agent"))))
                        .Select(folder => Path.Combine(folder, "sessions")),
                    .. TokenClientRoots.RootsOf(TokenSource.Omp, home, env)];
        }, TokenLogFormat.Omp),
        // FACTORY_HOME_OVERRIDE replaces the home folder for droid's own session store.
        new(TokenSource.Droid, (home, env) =>
            [.. new[] { EnvPath(home, env, "FACTORY_HOME_OVERRIDE"), home }.OfType<string>().Select(folder => Path.Combine(folder, ".factory", "sessions"))],
            TokenLogFormat.Droid),
        // Cursor agent transcripts (IDE and cursor-agent CLI). CURSOR_CONFIG_DIR moves the CLI's config folder; %USERPROFILE%\.cursor
        // stays the IDE's, so both are listed.
        new(TokenSource.Cursor, (home, env) =>
            [.. new[] { EnvPath(home, env, "CURSOR_CONFIG_DIR"), Path.Combine(home, ".cursor") }
                .OfType<string>().Select(folder => Path.Combine(folder, "projects"))], TokenLogFormat.Cursor),
        // Grok Build keeps sessions under GROK_HOME (default %USERPROFILE%\.grok); its logs\unified.jsonl is read beside them.
        new(TokenSource.Grok, (home, env) => [Path.Combine(EnvPath(home, env, "GROK_HOME") ?? Path.Combine(home, ".grok"), "sessions")],
            TokenLogFormat.Grok),
        // HERMES_HOME may name a profile (<root>\profiles\<name>); the root lists every profile's state.db. Native Windows
        // Hermes lives in %LOCALAPPDATA%\hermes.
        new(TokenSource.Hermes, (home, env) =>
            [.. new[] { EnvPath(home, env, "HERMES_HOME") is { } custom ? HermesLog.Root(custom) : null,
                        Path.Combine(EnvPath(home, env, "LOCALAPPDATA") ?? Path.Combine(home, "AppData", "Local"), "hermes") }
                .OfType<string>()], TokenLogFormat.Hermes),
        // OpenClaw's state dir: OPENCLAW_STATE_DIR, else `.openclaw` (`.openclaw-<name>` for a named OPENCLAW_PROFILE) in
        // OPENCLAW_HOME or %USERPROFILE%. Before the rename it was ~\.clawdbot (until v2026.3.22 also ~\.moltbot).
        new(TokenSource.OpenClaw, (home, env) =>
        {
            var root = EnvPath(home, env, "OPENCLAW_HOME") ?? home;
            var profile = env("OPENCLAW_PROFILE") is { Length: > 0 } name && !name.Equals("default", StringComparison.OrdinalIgnoreCase)
                && name.All(character => char.IsLetterOrDigit(character) || character is '-' or '_') ? Path.Combine(root, $".openclaw-{name}") : null;
            return [.. new[] { EnvPath(home, env, "OPENCLAW_STATE_DIR"), profile, Path.Combine(root, ".openclaw"), Path.Combine(home, ".openclaw"),
                               Path.Combine(home, ".clawdbot"), Path.Combine(home, ".moltbot") }
                .OfType<string>().Select(folder => Path.Combine(folder, "agents"))];
        }, TokenLogFormat.OpenClaw),
        // Goose (etcetera's Windows strategy): GOOSE_PATH_ROOT\data, else %APPDATA%\Block\goose\data.
        new(TokenSource.Goose, (home, env) =>
            [.. new[] { EnvPath(home, env, "GOOSE_PATH_ROOT") is { } root ? Path.Combine(root, "data") : null,
                        Path.Combine(EnvPath(home, env, "APPDATA") ?? Path.Combine(home, "AppData", "Roaming"), "Block", "goose", "data") }
                .OfType<string>().Select(folder => Path.Combine(folder, "sessions"))], TokenLogFormat.Goose),
        // Kimi Code (KIMI_CODE_HOME), the Kimi desktop app's embedded Kimi Code (Kimi Work) under %APPDATA%, then the archived
        // kimi-cli (KIMI_SHARE_DIR); each keeps its sessions in `sessions`.
        new(TokenSource.Kimi, (home, env) =>
            [.. new[] { EnvPath(home, env, "KIMI_CODE_HOME") ?? Path.Combine(home, ".kimi-code"),
                        Path.Combine(EnvPath(home, env, "APPDATA") ?? Path.Combine(home, "AppData", "Roaming"),
                                     "kimi-desktop", "daimon-share", "daimon", "runtime", "kimi-code", "home"),
                        EnvPath(home, env, "KIMI_SHARE_DIR") ?? Path.Combine(home, ".kimi") }
                .Select(folder => Path.Combine(folder, "sessions"))], TokenLogFormat.Kimi),
    ];

    /// `<editor>\User\globalStorage\<extension>\tasks` for every VS Code family editor in `appData` (Code, Cursor, Windsurf,
    /// Antigravity, Kiro, IBM Bob, …): one listing plus one probe per folder, so no list of editor names goes stale.
    public static IEnumerable<string> ExtensionTaskRoots(string appData) =>
        Subfolders(appData).Select(app => Path.Combine(app, "User", "globalStorage")).Where(Directory.Exists)
            .SelectMany(storage => VSCodeExtensions.Select(extension => Path.Combine(storage, extension.Id, "tasks")));

    /// Claude Code's config folders: `CLAUDE_CONFIG_DIR` (one folder; a comma-separated list as ccusage reads it), then
    /// `XDG_CONFIG_HOME\claude` (default ~\.config\claude, ccusage's legacy location) and ~\.claude.
    public static IEnumerable<string> ClaudeConfigDirectories(string home, Func<string, string?> env) =>
        [.. EnvPaths(home, env, "CLAUDE_CONFIG_DIR"), Path.Combine(EnvPath(home, env, "XDG_CONFIG_HOME") ?? Path.Combine(home, ".config"), "claude"),
         Path.Combine(home, ".claude")];

    /// Subfolders of `directory`, by ordinal name; empty when it is missing or unreadable.
    internal static IEnumerable<string> Subfolders(string directory)
    {
        try { return Directory.GetDirectories(directory).Order(StringComparer.Ordinal); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or SecurityException) { return []; }
    }

    /// `XDG_DATA_HOME`, else ~\.local\share (OpenCode and Amp use it on Windows too).
    internal static string DataHome(string home, Func<string, string?> env) =>
        EnvPath(home, env, "XDG_DATA_HOME") ?? Path.Combine(home, ".local", "share");

    /// A non-empty environment value as a full path; a leading `~` names `home`.
    internal static string? EnvPath(string home, Func<string, string?> env, string key)
    {
        if (env(key) is not { Length: > 0 } value) return null;
        if (value == "~" || value.StartsWith("~/", StringComparison.Ordinal) || value.StartsWith(@"~\", StringComparison.Ordinal))
            value = home + value[1..];
        try { return Path.GetFullPath(value); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException or SecurityException) { return null; }
    }

    /// A comma-separated list of folders (blank entries skipped), each as `EnvPath` reads one.
    internal static IEnumerable<string> EnvPaths(string home, Func<string, string?> env, string key) =>
        (env(key) ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(value => EnvPath(home, _ => value, key)).OfType<string>();

    public IReadOnlyList<string> ExistingRoots(string home, Func<string, string?> env)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return [.. Roots(home, env).Where(root => seen.Add(root) && Directory.Exists(root))];
    }
}

/// Folders where another product writes a read source's log format. They join that source's roots, and the tracker labels
/// rows read under them with `ClientName` (the reader's own label wins). A clone's account limits are not the source's
/// subscription, so the tracker drops them; telemetry still matches by session ID, which is unique per log.
/// Mirrors `TokenClientRoots` (TokenProviders.swift).
public sealed record TokenClientRoots(TokenSource Source, string ClientName, Func<string, Func<string, string?>, IReadOnlyList<string>> Roots)
{
    public static readonly IReadOnlyList<TokenClientRoots> All =
    [
        // TRAE CLI (TraeX), a codex-rs fork: Codex rollouts in ~\.trae\cli\sessions\YYYY\MM\DD. TRAEX_SESSIONS_DIR is
        // agentsview's convention, not a TRAE setting.
        new(TokenSource.Codex, "TRAE CLI", (home, env) =>
            [.. new[] { TokenProvider.EnvPath(home, env, "TRAEX_SESSIONS_DIR"), Path.Combine(home, ".trae", "cli", "sessions") }.OfType<string>()]),
        // OpenClaude, a Claude Code fork with its own config folder (OPENCLAUDE_CONFIG_DIR; ~\.openclaude kept as fallback).
        new(TokenSource.Claude, "OpenClaude", (home, env) =>
            [.. new[] { TokenProvider.EnvPath(home, env, "OPENCLAUDE_CONFIG_DIR"), Path.Combine(home, ".openclaude") }.OfType<string>()
                .Select(folder => Path.Combine(folder, "projects"))]),
        // Qoder writes Claude Code transcripts: ~\.qoder (CLI), ~\.qoder-cn (China build), the IDE's SharedClientCache.
        new(TokenSource.Claude, "Qoder", (home, env) =>
            [Path.Combine(home, ".qoder", "projects"), Path.Combine(home, ".qoder-cn", "projects"),
             Path.Combine(TokenProvider.EnvPath(home, env, "APPDATA") ?? Path.Combine(home, "AppData", "Roaming"), "Qoder", "SharedClientCache", "cli", "projects")]),
        // Pi's own sessions folder override (omp has none); logs in ~\.pi\agent are labelled by the omp reader.
        new(TokenSource.Omp, "Pi", (home, env) => [.. new[] { TokenProvider.EnvPath(home, env, "PI_CODING_AGENT_SESSION_DIR") }.OfType<string>()]),
    ];

    public static IEnumerable<string> RootsOf(TokenSource source, string home, Func<string, string?> env) =>
        All.Where(clone => clone.Source == source).SelectMany(clone => clone.Roots(home, env));
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
